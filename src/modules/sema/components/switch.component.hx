/**
 * Imports
 */

import { hxTypePointer } from "@models/types.model";
import { hxZalloc } from "@components/memory.component";
import { record, hxBinopSpelling } from "@models/ast.model";
import { Ctx, HxU32Vec, Coverage } from "@structs/sema.struct";
import { TypeKind, AnyError } from "@constants/types.constant";
import { hxsPlaceRoot } from "@modules/sema/components/call.component";
import { hxsCheckThrow } from "@modules/sema/components/errors.component";
import { NodeKind, BinOp, FlagPointer, NoToken } from "@constants/ast.constant";
import { Text } from "@modules/sema/components/structs/switch-component.struct";
import { hxsCheckExpr, hxsCheckComptimeBlock } from "@modules/sema/components/expr.component";
import { hxsFindLoop, hxsPushLoop, hxsPopLoop } from "@modules/sema/components/stmt.component";
import { HxInfoField, HxSymLocal, HxMemberField, HxMemberEnumValue } from "@constants/sema.constant";
import { hxsCheckPlace, hxsTypeNameRef, hxsIsMutablePlace } from "@modules/sema/components/call.component";
import { tokenText, typeName, errorNode, errorToken, hint } from "@modules/sema/components/base.component";
import { hxsCheckForOf, hxsCollectNarrowing, hxsCheckLocal } from "@modules/sema/components/stmt.component";
import { hxsResolveAggregate, hxsFindMember, hxsMemberOf } from "@modules/sema/components/aggregate.component";
import { HxMemberError, HxInfoUnionInit, HxSymParam, HxValueBool, HxSymMutated } from "@constants/sema.constant";
import { astOf, nodeOf, typeOf, symbolOf, infoOf, extraOf, types } from "@modules/sema/components/base.component";
import { hxsCheckCondition, hxsCheckBlockContents, hxsCheckScoped } from "@modules/sema/components/stmt.component";
import { hxsUnsupported, hintf, hxsTokName, hxsValueOf, hxsCoerce } from "@modules/sema/components/base.component";
import { noteWrite, flushReads, saveUnset, restoreUnset, mergeUnset } from "@modules/sema/components/unset.component";
import { u32At, hxsDeclareLocal, hxsPushScope, hxsPopScope, pushU32 } from "@modules/sema/components/scope.component";
import { HxRange, HxCaseData, HxIfData, HxWhileData, HxForData, HxTernaryData } from "@models/structs/ast-model.struct";
import { hxsAggregateOf, hxsIsAggregate, hxsIsComptimeNumber, memberAt } from "@modules/sema/components/base.component";

/**
 * The C library function that releases the coverage table and the buffer of case values.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;

/**
 * Finds the local or parameter whose memory a returned value points into.
 *
 * @param c - The checker context
 * @param expr - The returned expression
 * @param at - The variable that receives the node that takes the view of the local
 * @returns The symbol of the local or parameter, or 0 when the value points into none that the checker can see
 *
 * @remarks
 * It recognizes `&x`, `&x.field`, `&arr[i]`, `arr[a..b]`, and an array `arr` that becomes a slice or pointer where
 * it is used, since that is a view of its storage.
 * It also looks inside a struct or array literal, a ternary, a cast, and an unwrap.
 * It does not follow a pointer stored in a variable first.
 * A parameter that is itself a pointer was dereferenced on the way,
 * so what it points at outlives the call and the function gives 0 for it.
 *
 * @since 1.0.0
 */

function escapingLocal(c: *Ctx, expr: u32, at: *u32): u32 {
    if (expr == 0) return 0;
    const n = nodeOf(c, expr);
    let root: u32 = 0;
    switch (n.kind) {
        case NodeKind.AddressOf: root = hxsPlaceRoot(c, n.a);
        case NodeKind.Slice: {
            if (infoOf(c, n.a).type != 0 && typeOf(c, infoOf(c, n.a).type).kind == TypeKind.Array) root = hxsPlaceRoot(c, n.a);
        }
        case NodeKind.Ident, NodeKind.FieldAccess, NodeKind.Index: {
            // an array that becomes a slice or pointer where it's used: a view of its storage
            const coerce = infoOf(c, expr).coerce;
            const own = infoOf(c, expr).type;
            if (coerce != 0 && own != 0 && typeOf(c, own).kind == TypeKind.Array) {
                const to = typeOf(c, coerce).kind;
                if (to == TypeKind.Slice || to == TypeKind.Pointer || to == TypeKind.ManyPointer) root = hxsPlaceRoot(c, expr);
            }
        }
        case NodeKind.Cast, NodeKind.Unwrap: return escapingLocal(c, n.a, at);
        case NodeKind.Ternary: {
            const data = record<HxTernaryData>(astOf(c), n.b);
            const first = escapingLocal(c, data.thenValue, at);
            if (first != 0) return first;
            return escapingLocal(c, data.elseValue, at);
        }
        case NodeKind.StructLiteral: {
            const inits = record<HxRange>(astOf(c), n.b);
            for (const i of inits.start..inits.end) {
                const found = escapingLocal(c, nodeOf(c, extraOf(c, i)).a, at);
                if (found != 0) return found;
            }
        }
        case NodeKind.ArrayLiteral: {
            for (const i of n.a..n.b) {
                const found = escapingLocal(c, extraOf(c, i), at);
                if (found != 0) return found;
            }
        }
        default: {}
    }
    if (root == 0) return 0;
    const kind = symbolOf(c, root).kind;
    if (kind != HxSymLocal as u8 && kind != HxSymParam as u8) return 0;
    // a parameter that is itself a pointer was dereferenced on the way: what it points at outlives the call
    if (typeOf(c, symbolOf(c, root).type).kind == TypeKind.Pointer) return 0;
    *at = expr;
    return root;
}

/**
 * Reports a returned value that points into a local, such as `return &local`.
 *
 * @param c - The checker context
 * @param value - The returned expression
 *
 * @remarks
 * The stack memory of the local is gone once the function returns.
 * The hint suggests returning the value itself,
 * or allocating it with `create<T>(allocator)` and returning that pointer.
 *
 * @since 1.0.0
 */

function checkEscape(c: *Ctx, value: u32): void {
    let at: u32 = 0;
    const sym = escapingLocal(c, value, &at);
    if (sym == 0) return;
    const name = tokenText(c, symbolOf(c, sym).token);
    const what = symbolOf(c, sym).kind == HxSymParam as u8 ? "parameter" : "local";
    const diag = errorNode(c, at, `this points into \`${name}\`, a ${what} that's gone once the function returns`);
    hint(c, diag, "return the value itself, or allocate it (`create<T>(allocator)`) and return that pointer");
}

/**
 * Finds the variant of a union that an expression such as `Event.click` or `.click` names.
 *
 * @param c - The checker context
 * @param expr - The expression that names the variant
 * @param unionType - The union type that the variant must belong to
 * @returns The member index of the variant, or -1 after reporting an error
 *
 * @remarks
 * A field access must name the union type itself before the dot, and an enum literal names the variant alone.
 * Any other expression, a different type before the dot, or a name that is not a field of the union is an error.
 *
 * @example
 * ```hx
 * // switch (event) { case Event.click: ... }
 * hxsVariantRef(c, expr, eventType); // the member index of click
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsVariantRef(c: *Ctx, expr: u32, unionType: u32): i32 {
    const e = nodeOf(c, expr);
    if ((e.kind == NodeKind.FieldAccess && hxsTypeNameRef(c, e.a) != unionType) ||
        (e.kind != NodeKind.EnumLiteral && e.kind != NodeKind.FieldAccess)) {
        void errorNode(c, expr, `expected a variant of \`${typeName(c, unionType)}\``);
        return -1;
    }
    const index = hxsFindMember(c, unionType, hxsTokName(c, e.token));
    if (index < 0 || hxsMemberOf(c, unionType, index).kind != HxMemberField as u8) {
        void errorNode(c, expr, `\`${typeName(c, unionType)}\` has no variant \`${tokenText(c, e.token)}\``);
        return -1;
    }
    return index;
}

/**
 * Checks whether a pattern matches every value of its type.
 *
 * @param c - The checker context
 * @param pat - The pattern node
 * @returns `true` for a binding, or for a struct pattern whose field patterns all match every value
 *
 * @remarks
 * A struct field without its own pattern binds the field, so it also matches every value.
 * An irrefutable pattern without a guard covers the whole case, which makes a switch exhaustive.
 *
 * @example
 * ```hx
 * // case { x, y }:   case r:   case Shape.circle(r):
 * hxsIrrefutable(c, pat); // true, true, false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIrrefutable(c: *Ctx, pat: u32): bool {
    const p = nodeOf(c, pat);
    if (p.kind == NodeKind.PatternBind) return true;
    if (p.kind != NodeKind.PatternStruct) return false;
    for (const i of p.a..p.b) {
        const sub = nodeOf(c, extraOf(c, i)).a;
        if (sub != 0 && !hxsIrrefutable(c, sub)) return false;
    }
    return true;
}

/**
 * Marks a member of the switch subject as handled.
 *
 * @param cov - The coverage table of the switch
 * @param index - The member index, or 0 and 1 for `false` and `true`
 * @param guarded - Whether the case has a guard, which leaves the member unhandled
 *
 * @remarks
 * A case with a guard may not match, so it never counts toward exhaustiveness.
 * An index past the end of the table, or a table without storage, is left alone.
 *
 * @example
 * ```hx
 * // case Color.red:
 * hxsCover(&cov, 0, false); // red is handled
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCover(cov: *Coverage, index: u32, guarded: bool): void {
    if (guarded || index >= cov.count) return;
    unsafe {
        if (const covered = @ptrCast(?bool[*], cov.covered)) covered[index] = true;
    }
}

/**
 * Makes a coverage table that tracks no members and has no catch-all.
 *
 * @returns The empty table
 *
 * @remarks
 * A switch over a type that is not an enum, a union, `bool`, or a closed error set keeps this table,
 * with no members to cover.
 * A nested pattern also starts from one, since its coverage does not count toward the outer switch.
 *
 * @since 1.0.0
 */

function emptyCoverage(): Coverage {
    return Coverage { covered: null, count: 0, catchAll: false };
}

/**
 * Checks one pattern of a `case` against the switch subject and records what it covers.
 *
 * @param c - The checker context
 * @param pat - The pattern node
 * @param subject - The type of the value that the pattern matches
 * @param mutableSubject - Whether the subject is a mutable place, which lets a `*name` binding write through
 * @param cov - The coverage table that receives the members the pattern handles
 * @param guarded - Whether the case has a guard
 *
 * @remarks
 * Each kind of pattern works this way:
 * - **Binding** - declares a local of the subject type, or a pointer to the subject for `*name`,
 *   which is readonly unless the subject is mutable. Without a guard it is a catch-all.
 * - **Value** - on a union, `Event.quit` matches the tag only. Otherwise the value must be known at compile time,
 *   and it covers a `bool` value or the matching members of an enum or error set.
 * - **Range** - matches integers only, and both bounds must be known at compile time.
 * - **Tag** - `Shape.circle(r)` matches a union variant that carries a value and checks the inner pattern against it.
 *   It covers the variant when the inner pattern matches every value.
 * - **Struct** - `{ x, y: 0 }` matches the fields of a struct.
 *   A field without a pattern binds it, and the whole pattern is a catch-all when every field pattern is irrefutable.
 *
 * Patterns nested inside a tag or struct pattern track their coverage in a table of their own,
 * and a struct field pattern always counts as guarded.
 *
 * @example
 * ```hx
 * // switch (shape) { case Shape.circle(r): ... }
 * hxsCheckPattern(c, pat, shapeType, false, &cov, false); // declares r, covers circle
 * ```
 *
 * @see hxsIrrefutable
 * @since 1.0.0
 */

export extern "C" function hxsCheckPattern(c: *Ctx, pat: u32, subject: u32, mutableSubject: bool, cov: *Coverage, guarded: bool): void {
    const p = nodeOf(c, pat);
    const kind = typeOf(c, subject).kind;
    infoOf(c, pat).type = subject;
    switch (p.kind) {
        case NodeKind.PatternBind: {
            let t = subject;
            if ((p.flags & FlagPointer) != 0) {
                t = hxTypePointer(types(c), TypeKind.Pointer as u32, subject, !mutableSubject);
                if (mutableSubject) c.pointerBinding = true;
            }
            infoOf(c, pat).symbol = hxsDeclareLocal(c, HxSymLocal, p.token, pat, t);
            infoOf(c, pat).type = t;
            if (!guarded) cov.catchAll = true;
        }
        case NodeKind.PatternValue: {
            if (kind == TypeKind.Union) {   // `Event.quit`: matches the tag only
                const index = hxsVariantRef(c, p.a, subject);
                if (index < 0) return;
                const m = hxsMemberOf(c, subject, index);
                infoOf(c, pat).flags |= HxInfoUnionInit;
                infoOf(c, pat).aux = m.index;
                hxsCover(cov, m.index, guarded);
                return;
            }
            const t = hxsCheckExpr(c, p.a, subject);
            const v = hxsValueOf(c, p.a);
            if (t != 0 && v == null) {
                void errorNode(c, p.a, "a case value must be known at compile time");
                return;
            }
            if (v == null) return;
            if (kind == TypeKind.Bool) hxsCover(cov, v.boolean ? 1 : 0, guarded);
            if ((kind == TypeKind.Enum || kind == TypeKind.ErrorSet) && hxsIsAggregate(c, subject)) {   // `Error` has no list
                const agg = *hxsAggregateOf(c, subject);
                for (const i of 0..agg.membersCount) {
                    const m = memberAt(c, agg.membersStart + i);
                    const valueMember = m.kind == HxMemberEnumValue as u8 || m.kind == HxMemberError as u8;
                    if (valueMember && m.value == v.integer) hxsCover(cov, m.index, guarded);
                }
            }
        }
        case NodeKind.PatternRange: {
            if (kind != TypeKind.Int) {
                void errorNode(c, pat, `ranges only match integers, not \`${typeName(c, subject)}\``);
                return;
            }
            void hxsCheckExpr(c, p.a, subject);
            void hxsCheckExpr(c, p.b, subject);
            if (hxsValueOf(c, p.a) == null || hxsValueOf(c, p.b) == null) void errorNode(c, pat, "range bounds must be known at compile time");
        }
        case NodeKind.PatternTag: {
            if (kind != TypeKind.Union) {
                void errorNode(c, pat, `\`${typeName(c, subject)}\` is not a union, so its cases carry no values`);
                return;
            }
            const index = hxsVariantRef(c, p.a, subject);
            if (index < 0) return;
            const m = hxsMemberOf(c, subject, index);
            infoOf(c, pat).aux = m.index;
            if (m.type == 0) {
                const name = tokenText(c, m.token);
                const diag = errorNode(c, pat, `\`${name}\` carries no value`);
                hintf(c, diag, `match it without parentheses: \`${typeName(c, subject)}.${name}\``);
                return;
            }
            let inner = emptyCoverage();
            hxsCheckPattern(c, p.b, m.type, mutableSubject, &inner, guarded);
            if (hxsIrrefutable(c, p.b)) hxsCover(cov, m.index, guarded);
        }
        case NodeKind.PatternStruct: {
            if (kind != TypeKind.Struct) {
                void errorNode(c, pat, `\`{ ... }\` patterns match structs, not \`${typeName(c, subject)}\``);
                return;
            }
            for (const i of p.a..p.b) {
                const fieldPat = extraOf(c, i);
                const fp = nodeOf(c, fieldPat);
                const index = hxsFindMember(c, subject, hxsTokName(c, fp.token));
                if (index < 0 || hxsMemberOf(c, subject, index).kind != HxMemberField as u8) {
                    void errorToken(c, fp.token, `\`${typeName(c, subject)}\` has no field \`${tokenText(c, fp.token)}\``);
                    continue;
                }
                const m = hxsMemberOf(c, subject, index);
                infoOf(c, fieldPat).aux = m.index;
                infoOf(c, fieldPat).type = m.type;
                if (fp.a != 0) {
                    let inner = emptyCoverage();
                    hxsCheckPattern(c, fp.a, m.type, mutableSubject, &inner, true);
                } else {
                    infoOf(c, fieldPat).symbol = hxsDeclareLocal(c, HxSymLocal, fp.token, fieldPat, m.type);
                }
            }
            if (hxsIrrefutable(c, pat) && !guarded) cov.catchAll = true;
        }
        default: void errorNode(c, pat, "expected a pattern");
    }
}

/**
 * Appends a string to a message buffer.
 *
 * @param t - The buffer to append to
 * @param s - The text to append
 *
 * @remarks
 * The bytes that would fill the last free byte or go past it are dropped.
 *
 * @since 1.0.0
 */

function appendText(t: *Text, s: string): void {
    for (const ch of s) {
        if (t.used + 1 >= 256) return;
        t.buf[t.used] = ch;
        t.used += 1;
    }
}

/**
 * Checks a `switch` statement or expression, with its patterns and exhaustiveness.
 *
 * @param c - The checker context
 * @param node - The switch node
 * @param expected - The type that the context expects of a switch expression, or 0
 * @param isExpr - Whether the switch produces a value
 * @returns The type of the value for an expression, and for a statement `noreturn` when it never goes on, else `void`
 *
 * @remarks
 * The subject may be an integer, `bool`, enum, union, error set, struct, or string.
 * A string literal subject becomes a `string`, and a literal number is an error because it has no concrete type.
 * Enums, unions, bools, and error sets with a list of their errors must handle every case or have a `default:`,
 * and the hint lists the missing cases.
 * The other subjects always need a `default` case.
 *
 * A statement switch merges what each case leaves without a value over the cases that go on after the switch.
 * A `case 1:` with an empty body falls into the next case, so it does not decide whether the switch ends.
 * A `*name` binding on a mutable subject marks the subject as mutated.
 *
 * An expression switch takes its type from `expected`, or else from the first case value with a runtime type.
 * When only literals remain, string literals give `string`, and numbers are an error that asks for a type.
 * When every case throws, returns, or panics, the type is `noreturn`.
 *
 * @example
 * ```hx
 * // const name = switch (color) { case Color.red: "red", default: "other" };
 * hxsCheckSwitch(c, node, 0, true); // the string type
 * ```
 *
 * @see hxsCheckPattern
 * @since 1.0.0
 */

export extern "C" function hxsCheckSwitch(c: *Ctx, node: u32, expected: u32, isExpr: bool): u32 {
    const n = nodeOf(c, node);
    const cases = record<HxRange>(astOf(c), n.b);
    const tys = types(c);
    let subject = hxsCheckExpr(c, n.a, 0);
    if (subject != 0 && typeOf(c, subject).kind == TypeKind.StringLiteral) {
        void hxsCoerce(c, n.a, tys.string);
        subject = tys.string;
    }
    if (subject != 0 && hxsIsComptimeNumber(c, subject)) {
        void errorNode(c, n.a, "switching on a literal needs a concrete type");
        subject = 0;
    }
    const kind = subject != 0 ? typeOf(c, subject).kind : TypeKind.Invalid;
    const isString = subject != 0 && kind == TypeKind.Slice && typeOf(c, subject).child == tys.u8;
    if (subject != 0 && !(kind == TypeKind.Int || kind == TypeKind.Bool || kind == TypeKind.Enum || kind == TypeKind.Union ||
                          kind == TypeKind.ErrorSet || kind == TypeKind.Struct || isString)) {
        void errorNode(c, n.a, `can't switch on \`${typeName(c, subject)}\``);
        subject = 0;
    }
    if (subject != 0) hxsResolveAggregate(c, subject);

    const exhaustible = kind == TypeKind.Enum || kind == TypeKind.Union || kind == TypeKind.Bool ||
                        (kind == TypeKind.ErrorSet && (typeOf(c, subject).flags & AnyError) == 0);
    let cov = emptyCoverage();
    if (subject != 0 && exhaustible) {
        cov.count = kind == TypeKind.Bool ? 2 : hxsAggregateOf(c, subject).fieldCount;
        unsafe {
            cov.covered = @ptrCast(?bool[*], hxZalloc((cov.count as usize) + 1));
        }
    }
    const subjectKind = nodeOf(c, n.a).kind;
    const place = subjectKind == NodeKind.Ident || subjectKind == NodeKind.Index || subjectKind == NodeKind.Deref ||
                  (subjectKind == NodeKind.FieldAccess && (infoOf(c, n.a).flags & HxInfoField) != 0);
    const mutableSubject = place && hxsIsMutablePlace(c, n.a, false);

    let result = isExpr ? expected : 0;
    let values = HxU32Vec { items: null, len: 0, cap: 0 };
    const savedPointerBinding = c.pointerBinding;
    c.pointerBinding = false;
    let allEnd = true;

    // what each case leaves without a value (unset.hx): merged over the cases that go on after the switch
    if (!isExpr) flushReads(c);
    const unsetBefore = saveUnset(c);
    let unsetAfter = unsetBefore;
    let unsetAny = false;
    for (const i of cases.start..cases.end) {
        const caseNode = extraOf(c, i);
        const cn = nodeOf(c, caseNode);
        if (!isExpr) restoreUnset(c, unsetBefore);
        hxsPushScope(c);
        let body: u32 = 0;
        if (cn.kind == NodeKind.DefaultCase) {
            cov.catchAll = true;
            body = cn.a;
        } else {
            const data = record<HxCaseData>(astOf(c), cn.a);
            for (const j of data.patternsStart..data.patternsEnd) {
                if (subject != 0) hxsCheckPattern(c, extraOf(c, j), subject, mutableSubject, &cov, data.guard != 0);
            }
            if (data.guard != 0) hxsCheckCondition(c, data.guard);
            body = data.body;
        }
        if (isExpr) {
            const t = hxsCheckExpr(c, body, result);
            if (t != tys.noreturnType) allEnd = false;
            if (result == 0 && t != 0 && t != tys.noreturnType && !hxsIsComptimeNumber(c, t) && typeOf(c, t).kind != TypeKind.StringLiteral) {
                result = t;
            }
            pushU32(&values, body);
        } else {
            // `case 1:` with an empty body falls into the next case, so it doesn't decide whether the switch ends
            const stacked = nodeOf(c, body).a == nodeOf(c, body).b && i + 1 < cases.end;
            const ends = hxsCheckStmt(c, body);
            if (!ends && !stacked) {
                allEnd = false;
                const here = saveUnset(c);
                if (unsetAny) mergeUnset(c, unsetBefore, unsetAfter, here);
                unsetAfter = saveUnset(c);
                unsetAny = true;
            }
        }
        hxsPopScope(c);
    }
    if (!isExpr) restoreUnset(c, unsetAny ? unsetAfter : unsetBefore);
    if (c.pointerBinding) {
        const root = hxsPlaceRoot(c, n.a);
        if (root != 0) symbolOf(c, root).flags |= HxSymMutated as u16;
    }
    c.pointerBinding = savedPointerBinding;

    let exhaustive = cov.catchAll;
    if (subject != 0 && !exhaustive && exhaustible) {
        let missing = Text { buf: undefined, used: 0 };
        let missingCount: u32 = 0;
        if (kind == TypeKind.Bool) {
            for (const b of 0..2) {
                let covered = false;
                unsafe {
                    covered = @ptrCast(bool[*], cov.covered!)[b];
                }
                if (covered) continue;
                if (missingCount > 0) appendText(&missing, ", ");
                appendText(&missing, b == 1 ? "true" : "false");
                missingCount += 1;
            }
        } else {
            const agg = *hxsAggregateOf(c, subject);
            for (const m of 0..agg.membersCount) {
                const mem = *memberAt(c, agg.membersStart + m);
                const counted = mem.kind == HxMemberField as u8 || mem.kind == HxMemberEnumValue as u8 || mem.kind == HxMemberError as u8;
                let covered = false;
                unsafe {
                    covered = @ptrCast(bool[*], cov.covered!)[mem.index];
                }
                if (!counted || covered) continue;
                if (missingCount > 0) appendText(&missing, ", ");
                appendText(&missing, typeName(c, subject));
                appendText(&missing, ".");
                appendText(&missing, tokenText(c, mem.token));
                missingCount += 1;
            }
        }
        if (missingCount == 0) {
            exhaustive = true;
        } else {
            const diag = errorNode(c, node, `switch on \`${typeName(c, subject)}\` doesn't handle every case`);
            const buf: *u8[256] = &missing.buf;
            hintf(c, diag, `missing ${buf[0..missing.used]} (or add \`default:\`)`);
        }
    } else if (subject != 0 && !exhaustive) {
        const diag = errorNode(c, node, `switch on \`${typeName(c, subject)}\` needs a \`default\` case`);
        hint(c, diag, "only enums, unions, error sets and bools can be covered case by case");
    }
    unsafe {
        free(@ptrCast(?u8[*], cov.covered));
    }

    if (!isExpr) {
        unsafe {
            free(@ptrCast(?u8[*], values.items));
        }
        return exhaustive && allEnd ? tys.noreturnType : tys.voidType;
    }
    if (result == 0) {
        for (const i of 0..values.len) {
            if (result != 0) break;
            const t = infoOf(c, u32At(&values, i)).type;
            if (t != 0 && typeOf(c, t).kind == TypeKind.StringLiteral) {
                result = tys.string;
            } else if (t != 0 && hxsIsComptimeNumber(c, t)) {
                const diag = errorNode(c, node, "can't tell which number type this switch produces");
                hint(c, diag, "give the variable a type: `const x: i32 = switch ...`");
                unsafe {
                    free(@ptrCast(?u8[*], values.items));
                }
                return 0;
            }
        }
        if (result == 0) result = tys.noreturnType;   // every case throws, returns or panics
    }
    for (const i of 0..values.len) void hxsCoerce(c, u32At(&values, i), result);
    unsafe {
        free(@ptrCast(?u8[*], values.items));
    }
    return result;
}

/**
 * Checks the condition of `if (const v = x)` or `while (const v = x)`, which must be an optional.
 *
 * @param c - The checker context
 * @param condition - The condition expression
 * @param what - The keyword for the error message, `if` or `while`
 * @returns The payload type of the optional, or 0 after an error
 *
 * @remarks
 * A condition that already failed to check reports nothing more and gives 0.
 * The caller binds the payload type to the captured name for the body.
 *
 * @since 1.0.0
 */

function capturedOptional(c: *Ctx, condition: u32, what: string): u32 {
    const t = hxsCheckExpr(c, condition, 0);
    if (t != 0 && typeOf(c, t).kind != TypeKind.Optional) {
        void errorNode(c, condition, `\`${what} (const ... = x)\` needs an optional, found \`${typeName(c, t)}\``);
        return 0;
    }
    return t != 0 ? typeOf(c, t).child : 0;
}

/**
 * Checks one statement of any kind.
 *
 * @param c - The checker context
 * @param node - The statement node, where 0 does nothing
 * @returns `true` when the statement never goes on, as after `return`, `throw`, `break`, or an endless loop
 *
 * @remarks
 * After the statement it reports the reads of locals without a value and applies the writes.
 * The caller uses the result to report unreachable code and to merge the branches of an `if` or `switch`.
 *
 * @example
 * ```hx
 * // return 1;
 * hxsCheckStmt(c, node); // true
 * ```
 *
 * @see flushReads
 * @since 1.0.0
 */

export extern "C" function hxsCheckStmt(c: *Ctx, node: u32): bool {
    const terminated = checkStmt(c, node);
    flushReads(c);
    return terminated;
}

/**
 * Dispatches a statement to the check for its kind.
 *
 * @param c - The checker context
 * @param node - The statement node, where 0 does nothing
 * @returns `true` when the statement never goes on
 *
 * @remarks
 * Among the rules it applies:
 * - An expression statement must not drop an error or a value. Discard a value on purpose with `void`.
 * - An assignment with an operator works on integers, and `+=`, `-=`, `*=`, and `/=` also work on floats.
 *   The checker does not support `??=`.
 * - `return` is an error inside a `defer`, takes no value in a `void` function, and checks that the value does
 *   not point into a local. `return SomeError.X` is allowed in a `void | E` function.
 * - A condition known at compile time rules out a branch, so a `@compileError` there does not fire.
 * - `if (x == null) return;` proves `x` non-null for the rest of the block.
 * - `while (true)` without a `break`, and a `for` without a condition and a `break`, never end.
 *   The body of a `while` counts as running, since loops usually fill buffers.
 * - A `break` with a bad label still marks the innermost loop as left, so the loop is not also called endless.
 * - `errdefer` is an error in a function that can't fail.
 * - A nested function is ignored, because the parser already reported it.
 *
 * @since 1.0.0
 */

function checkStmt(c: *Ctx, node: u32): bool {
    if (node == 0) return false;
    const n = nodeOf(c, node);
    const tys = types(c);
    switch (n.kind) {
        case NodeKind.Block: {
            hxsPushScope(c);
            const terminated = hxsCheckBlockContents(c, n.a, n.b);
            hxsPopScope(c);
            return terminated;
        }
        case NodeKind.UnsafeBlock: {
            c.unsafeDepth += 1;
            const terminated = hxsCheckStmt(c, n.a);
            c.unsafeDepth -= 1;
            return terminated;
        }
        case NodeKind.Const, NodeKind.Let: {
            void hxsCheckLocal(c, node, false);
            return infoOf(c, node).type == tys.noreturnType;
        }
        case NodeKind.ExprStmt: {
            if (nodeOf(c, n.a).kind == NodeKind.Switch) return hxsCheckSwitch(c, n.a, 0, false) == tys.noreturnType;
            const t = hxsCheckExpr(c, n.a, 0);
            const e = nodeOf(c, n.a);
            const hasCallee = e.kind == NodeKind.Call && (nodeOf(c, e.a).kind == NodeKind.Ident || nodeOf(c, e.a).kind == NodeKind.FieldAccess);
            const callee = hasCallee ? tokenText(c, nodeOf(c, e.a).token) : "";
            if (t != 0 && typeOf(c, t).kind == TypeKind.ErrorUnion) {
                const diag = hasCallee ? errorNode(c, n.a, `the error from \`${callee}\` is not handled`) : errorNode(c, n.a, "this error is not handled");
                hint(c, diag, "pass it on with `try`, or handle it: `... catch (e) { ... }`");
            } else if (t != 0 && t != tys.voidType && t != tys.noreturnType) {
                const diag = hasCallee ? errorNode(c, n.a, `the result of \`${callee}\` is unused`) : errorNode(c, n.a, "this value is unused");
                if (hasCallee) hintf(c, diag, `use it, or discard it on purpose: \`void ${callee}(...);\``);
                else hint(c, diag, "use it, or discard it on purpose with `void`");
            }
            return t == tys.noreturnType;
        }
        case NodeKind.Assign: {
            const op = @enumFromInt(BinOp, n.op);
            const target = hxsCheckExpr(c, n.a, 0);
            hxsCheckPlace(c, n.a);
            if (op == BinOp.None) noteWrite(c, n.a);
            if (target == 0) {
                void hxsCheckExpr(c, n.b, 0);
                return false;
            }
            if (op == BinOp.None) {
                void hxsCheckExpr(c, n.b, target);
                return false;
            }
            if (op == BinOp.Coalesce) {
                hxsUnsupported(c, node, "optionals (`??=`)");
                return false;
            }
            const floatOk = op == BinOp.Add || op == BinOp.Sub || op == BinOp.Mul || op == BinOp.Div;
            if (!(typeOf(c, target).kind == TypeKind.Int || (floatOk && typeOf(c, target).kind == TypeKind.Float))) {
                const spelling = hxBinopSpelling(n.op as u32);
                unsafe {
                    let len: usize = 0;
                    while (spelling[len] != 0) len += 1;
                    void errorNode(c, node, `\`${spelling[0..len]}=\` doesn't work on \`${typeName(c, target)}\``);
                }
                void hxsCheckExpr(c, n.b, 0);
                return false;
            }
            if (op == BinOp.Shl || op == BinOp.Shr) {
                const amount = hxsCheckExpr(c, n.b, 0);
                if (amount != 0 && hxsIsComptimeNumber(c, amount)) void hxsCoerce(c, n.b, target);
                else if (amount != 0 && typeOf(c, amount).kind != TypeKind.Int) void errorNode(c, n.b, "shift amounts are integers");
                return false;
            }
            void hxsCheckExpr(c, n.b, target);
            return false;
        }
        case NodeKind.Increment, NodeKind.Decrement: {
            const t = hxsCheckExpr(c, n.a, 0);
            hxsCheckPlace(c, n.a);
            if (t != 0 && typeOf(c, t).kind != TypeKind.Int) {
                void errorNode(c, node, `\`${n.kind == NodeKind.Increment ? "++" : "--"}\` needs an integer, found \`${typeName(c, t)}\``);
            }
            return false;
        }
        case NodeKind.Return: {
            if (c.inDefer) {
                const diag = errorNode(c, node, "`return` can't be used inside a `defer`");
                hint(c, diag, "a defer runs while the function is already returning");
                return true;
            }
            const ret = c.returnType;
            const payload = ret != 0 && typeOf(c, ret).kind == TypeKind.ErrorUnion ? typeOf(c, ret).child : ret;
            const returnsVoid = payload == tys.voidType;
            if (n.a != 0 && returnsVoid && ret != payload) {
                void hxsCheckExpr(c, n.a, ret);   // `return SomeError.X` in a `void | E` function
            } else if (n.a != 0) {
                if (returnsVoid) {
                    const diag = errorNode(c, n.a, "this function returns `void`, so `return` takes no value");
                    hint(c, diag, "remove the value, or declare a return type: `function f(): i32`");
                    void hxsCheckExpr(c, n.a, 0);
                } else {
                    void hxsCheckExpr(c, n.a, c.returnType);
                    checkEscape(c, n.a);
                }
            } else if (!returnsVoid && c.returnType != 0) {
                void errorNode(c, node, `missing return value of type \`${typeName(c, c.returnType)}\``);
            }
            return true;
        }
        case NodeKind.Break, NodeKind.Continue: {
            let index: u32 = 0;
            const loop = hxsFindLoop(c, node, n.a, n.kind == NodeKind.Break ? "break" : "continue", &index);
            if (loop == null) {
                // a `break` with a bad label still meant to leave a loop; don't also call the loop endless
                if (n.kind == NodeKind.Break && c.loopCount != 0) c.loops[c.loopCount - 1].hasBreak = true;
                return false;
            }
            if (n.kind == NodeKind.Break) loop.hasBreak = true;
            infoOf(c, node).symbol = loop.node;   // BREAK/CONTINUE: `symbol` holds the target loop node
            return true;
        }
        case NodeKind.If: {
            const data = record<HxIfData>(astOf(c), n.a);
            const mark = c.narrowed.len;
            if (data.captureToken != NoToken) {   // `if (const v = optional)`
                const payload = capturedOptional(c, data.condition, "if");
                hxsPushScope(c);
                infoOf(c, node).symbol = hxsDeclareLocal(c, HxSymLocal, data.captureToken, node, payload);
                flushReads(c);
                const before = saveUnset(c);
                const thenEnds = hxsCheckScoped(c, data.thenBranch);
                hxsPopScope(c);
                const afterThen = saveUnset(c);
                restoreUnset(c, before);
                const elseEnds = hxsCheckScoped(c, data.elseBranch);
                const afterElse = saveUnset(c);
                if (thenEnds) restoreUnset(c, afterElse);
                else if (elseEnds) restoreUnset(c, afterThen);
                else mergeUnset(c, before, afterThen, afterElse);
                return thenEnds && elseEnds;
            }
            hxsCheckCondition(c, data.condition);
            // a condition known while compiling rules a branch out: `@compileError` there doesn't fire
            const known = hxsValueOf(c, data.condition);
            const thenDead: u32 = known != null && known.kind == HxValueBool as u8 && !known.boolean ? 1 : 0;
            const elseDead: u32 = known != null && known.kind == HxValueBool as u8 && known.boolean ? 1 : 0;
            hxsCollectNarrowing(c, data.condition, true);
            flushReads(c);
            const before = saveUnset(c);
            c.deadDepth += thenDead;
            const thenEnds = hxsCheckScoped(c, data.thenBranch);
            c.deadDepth -= thenDead;
            const afterThen = saveUnset(c);
            restoreUnset(c, before);
            c.narrowed.len = mark;
            hxsCollectNarrowing(c, data.condition, false);
            c.deadDepth += elseDead;
            const elseEnds = hxsCheckScoped(c, data.elseBranch);
            c.deadDepth -= elseDead;
            const afterElse = saveUnset(c);
            if (thenEnds) restoreUnset(c, afterElse);
            else if (elseEnds) restoreUnset(c, afterThen);
            else mergeUnset(c, before, afterThen, afterElse);
            c.narrowed.len = mark;
            // `if (x == null) return;` proves `x` non-null for the rest of the block
            if (thenEnds && !elseEnds) hxsCollectNarrowing(c, data.condition, false);
            else if (elseEnds && !thenEnds) hxsCollectNarrowing(c, data.condition, true);
            return thenEnds && elseEnds;
        }
        case NodeKind.While: {
            const data = record<HxWhileData>(astOf(c), n.a);
            if (data.captureToken != NoToken) {   // `while (const item = it.next())`
                const payload = capturedOptional(c, data.condition, "while");
                hxsPushScope(c);
                infoOf(c, node).symbol = hxsDeclareLocal(c, HxSymLocal, data.captureToken, node, payload);
                hxsPushLoop(c, node, data.labelToken);
                flushReads(c);
                void hxsCheckScoped(c, data.body);
                void hxsPopLoop(c);
                hxsPopScope(c);
                return false;
            }
            hxsCheckCondition(c, data.condition);
            const mark = c.narrowed.len;
            hxsCollectNarrowing(c, data.condition, true);
            hxsPushLoop(c, node, data.labelToken);
            flushReads(c);
            void hxsCheckScoped(c, data.body);   // counted as running: buffers are usually filled in loops
            const v = hxsValueOf(c, data.condition);
            const hasBreak = hxsPopLoop(c);
            c.narrowed.len = mark;
            return v != null && v.boolean && !hasBreak;   // `while (true)` without `break` never ends
        }
        case NodeKind.For: {
            const data = record<HxForData>(astOf(c), n.a);
            hxsPushScope(c);
            if (data.init != 0) void hxsCheckStmt(c, data.init);
            if (data.condition != 0) hxsCheckCondition(c, data.condition);
            if (data.step != 0) void hxsCheckStmt(c, data.step);
            hxsPushLoop(c, node, data.labelToken);
            flushReads(c);
            void hxsCheckScoped(c, data.body);
            const hasBreak = hxsPopLoop(c);
            hxsPopScope(c);
            return data.condition == 0 && !hasBreak;
        }
        case NodeKind.ForOf: return hxsCheckForOf(c, node);
        case NodeKind.Defer: {
            const savedInDefer = c.inDefer;
            const savedFloor = c.deferFloor;
            c.inDefer = true;
            c.deferFloor = c.loopCount;
            void hxsCheckScoped(c, n.a);
            c.inDefer = savedInDefer;
            c.deferFloor = savedFloor;
            return false;
        }
        case NodeKind.Errdefer: {
            if (c.errorSet == 0) {
                const diag = errorNode(c, node, "`errdefer` never runs here, because this function can't fail");
                hint(c, diag, "use `defer`, or add errors to the return type");
            }
            const savedInDefer = c.inDefer;
            const savedFloor = c.deferFloor;
            c.inDefer = true;
            c.deferFloor = c.loopCount;
            hxsPushScope(c);
            if (n.b != NoToken) {
                infoOf(c, node).symbol = hxsDeclareLocal(c, HxSymLocal, n.b, node, c.errorSet != 0 ? c.errorSet : tys.anyError);
            }
            void hxsCheckScoped(c, n.a);
            hxsPopScope(c);
            c.inDefer = savedInDefer;
            c.deferFloor = savedFloor;
            return false;
        }
        case NodeKind.Throw: {
            void hxsCheckThrow(c, node);
            return true;
        }
        case NodeKind.Switch: return hxsCheckSwitch(c, node, 0, false) == tys.noreturnType;
        case NodeKind.ComptimeBlock: {
            hxsCheckComptimeBlock(c, node);
            return false;
        }
        case NodeKind.Function, NodeKind.Invalid: return false;   // nested functions are already reported by the parser
        default: {
            void hxsCheckExpr(c, node, 0);
            return false;
        }
    }
}
