/**
 * Imports
 */

import { Ctx } from "@structs/sema.struct";
import { hxBinopSpelling } from "@models/ast.model";
import { hxTypePointer } from "@models/types.model";
import { NodeKind, BinOp } from "@constants/ast.constant";
import { TypeKind, Signed } from "@constants/types.constant";
import { noteWrite } from "@modules/sema/components/unset.component";
import { hxsCheckArgs } from "@modules/sema/components/call.component";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { hxsIsWrapping } from "@modules/sema/components/scope.component";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { hxsModuleMember } from "@modules/sema/components/imports.component";
import { hxsCollectNarrowing } from "@modules/sema/components/stmt.component";
import { hxsCheckGenericCall } from "@modules/sema/components/generics.component";
import { hxsCheckPrint, hxsIndirectCall } from "@modules/sema/components/print.component";
import { hxsFindMember, hxsMemberOf } from "@modules/sema/components/aggregate.component";
import { hxsExpectParts, hxsCheckExpect } from "@modules/sema/components/expect.component";
import { HxSymGeneric, HxSymAddressed, HxValueBool, HxSymMutated } from "@constants/sema.constant";
import { symbolOf, infoOf, types, tokenText, typeName } from "@modules/sema/components/base.component";
import { hxsIsMutablePlace, hxsPlaceRoot, hxsCheckUnionInit } from "@modules/sema/components/call.component";
import { HxInfoField, HxValueFloat, HxSymLocal, HxMemberField, HxSymFunction } from "@constants/sema.constant";
import { hxsCheckMemberCall, hxsMarkUsed, hxsCheckArgsUnknown } from "@modules/sema/components/call.component";
import { hxsIsSaturating, hxsLookup, hxsFoldBinary, hxsFoldInt } from "@modules/sema/components/scope.component";
import { hxsIntValue, hxsBoolValue, hxsFloatValue, nodeOf, typeOf } from "@modules/sema/components/base.component";
import { hint, hintf, i128Text, hxsTokName, hxsValueOf, hxsIntFits } from "@modules/sema/components/base.component";
import { hxsWrapInt, hxsIsNumeric, hxsIsFloat, hxsIsComptimeNumber } from "@modules/sema/components/base.component";
import { hxsExpectedBase, hxsCoerce, hxsPeer, hxsIsInteger, errorNode } from "@modules/sema/components/base.component";

/**
 * Compares two strings byte by byte.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns `true` when both strings have the same length and the same bytes
 *
 * @remarks
 * The comparison is exact and case-sensitive, and it compares lengths first, so a prefix never matches.
 *
 * @since 1.0.0
 */

function sameText(a: string, b: string): bool {
    if (a.len != b.len) return false;
    for (const ch, i of a) {
        if (b[i] != ch) return false;
    }
    return true;
}

/**
 * Gives the source spelling of a binary operator, for the messages.
 *
 * @param op - The binary operator, as a `BinOp` number
 * @returns The spelling, such as `+` or `<<`, as a slice of the static text
 *
 * @remarks
 * The spelling comes from `hxBinopSpelling` as a NUL-terminated string,
 * and the slice points at that static text, so it never needs to be released.
 *
 * @since 1.0.0
 */

function spelling(op: u32): string {
    const text = hxBinopSpelling(op);
    unsafe {
        let n: usize = 0;
        while (text[n] != 0) n += 1;
        return text[0..n];
    }
}

/**
 * Checks a call and decides what kind of call it is.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param expected - The type that the context expects, or 0 when there is none
 * @returns The result type of the call, or 0 on an error
 *
 * @remarks
 * This file covers calls by name, and the operators: binary, unary, and `as`.
 * The callee decides the route:
 * - **Test assertion** - inside a test, `expect(...)` and `require(...)` chains go to the matcher checks.
 * - **Method** - a callee such as `x.f` is a member call.
 * - **Union variant** - `.click(point)` builds a variant of the union that `expected` names.
 * - **Generic call** - `max<i64>(a, b)` or `ns.max<i64>(a, b)` instantiates the generic function.
 * - **Name** - a function symbol is checked by {@link hxsCheckFunctionCall},
 *   and a variable is called through its value.
 * - **Print** - an unknown name that is `print`, `println`, `eprint`, or `eprintln` is a print.
 * - **Other** - any other expression is called through its value.
 *
 * An unknown `expect` or `require` outside a test gets a hint that they only work in tests and hooks.
 *
 * @example
 * ```hx
 * // missing(1);
 * hxsCheckCall(c, node, 0); // error: unknown function `missing`
 * ```
 *
 * @see hxsIndirectCall
 * @see hxsCheckFunctionCall
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckCall(c: *Ctx, node: u32, expected: u32): u32 {
    const n = nodeOf(c, node);
    const calleeKind = nodeOf(c, n.a).kind;
    if (c.inTest) {
        let subjectCall: u32 = 0;
        let matcher: u32 = 0;
        let negated = false;
        let isRequire = false;
        if (hxsExpectParts(c, node, &subjectCall, &matcher, &negated, &isRequire)) {
            return hxsCheckExpect(c, node, subjectCall, matcher, negated, isRequire);
        }
    }
    if (calleeKind == NodeKind.FieldAccess) return hxsCheckMemberCall(c, node, n.a, 0);
    const name = tokenText(c, nodeOf(c, n.a).token);

    if (calleeKind == NodeKind.EnumLiteral) {   // `.click(point)` where a union is expected
        const owner = hxsExpectedBase(c, expected);
        if (owner == 0 || typeOf(c, owner).kind != TypeKind.Union) {
            const diag = errorNode(c, n.a, `can't tell which union \`.${name}\` belongs to`);
            hintf(c, diag, `write the type: \`MyUnion.${name}(...)\``);
            hxsCheckArgsUnknown(c, node);
            return 0;
        }
        const index = hxsFindMember(c, owner, hxsTokName(c, nodeOf(c, n.a).token));
        if (index < 0 || hxsMemberOf(c, owner, index).kind != HxMemberField as u8) {
            void errorNode(c, n.a, `\`${typeName(c, owner)}\` has no variant \`${name}\``);
            hxsCheckArgsUnknown(c, node);
            return 0;
        }
        return hxsCheckUnionInit(c, node, owner, hxsMemberOf(c, owner, index), name.ptr, name.len as i32);
    }

    if (calleeKind == NodeKind.GenericInstance) {   // `max<i64>(a, b)` or `ns.max<i64>(a, b)`
        const base = nodeOf(c, n.a).a;
        let sym: u32 = 0;
        if (nodeOf(c, base).kind == NodeKind.Ident) sym = hxsLookup(c, hxsTokName(c, nodeOf(c, base).token));
        else if (nodeOf(c, base).kind == NodeKind.FieldAccess) sym = hxsModuleMember(c, nodeOf(c, base).a, nodeOf(c, base).token, true);
        if (sym == 0xFFFF_FFFF) {
            hxsCheckArgsUnknown(c, node);
            return 0;
        }
        if (sym != 0 && symbolOf(c, sym).kind == HxSymFunction as u8 && (symbolOf(c, sym).flags & (HxSymGeneric as u16)) != 0) {
            hxsMarkUsed(c, sym);
            const baseName = tokenText(c, nodeOf(c, base).token);
            return hxsCheckGenericCall(c, node, sym, n.a, baseName.ptr, baseName.len as i32);
        }
        if (sym == 0 && nodeOf(c, base).kind == NodeKind.FieldAccess) return hxsCheckMemberCall(c, node, base, n.a);   // a method
        void errorNode(c, n.a, "expected a generic function");
        hxsCheckArgsUnknown(c, node);
        return 0;
    }

    if (calleeKind != NodeKind.Ident) return hxsIndirectCall(c, node, n.a, hxsCheckExpr(c, n.a, 0));

    const sym = hxsLookup(c, hxsTokName(c, nodeOf(c, n.a).token));
    if (sym == 0) {
        const prints: string[4] = ["print", "println", "eprint", "eprintln"];
        for (const p, i of prints) {
            if (sameText(name, p)) return hxsCheckPrint(c, node, @truncate(u32, i), name.ptr, name.len as i32);
        }
        const diag = errorNode(c, n.a, `unknown function \`${name}\``);
        if (sameText(name, "expect") || sameText(name, "require")) {
            if (c.inTest) hintf(c, diag, `\`${name}\` needs a matcher: \`${name}(actual).toBe(expected)\``);
            else hintf(c, diag, `\`${name}\` works inside \`test\` blocks and hooks`);
        }
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    if (symbolOf(c, sym).kind != HxSymFunction as u8) return hxsIndirectCall(c, node, n.a, hxsCheckExpr(c, n.a, 0));   // a variable
    infoOf(c, n.a).symbol = sym;
    return hxsCheckFunctionCall(c, node, sym, name.ptr, name.len as i32);
}

/**
 * Checks a call to a named function symbol, plain or generic.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param sym - The symbol that the callee names
 * @param namePtr - The name of the callee, for the messages
 * @param len - The length of the name in bytes
 * @returns The result type of the function, or 0 on an error
 *
 * @remarks
 * A symbol that is not a function is an error.
 * The function is marked as used, a generic one is instantiated for the call,
 * and the arguments of a plain one are checked against its type.
 *
 * @example
 * ```hx
 * // function add(a: i32, b: i32): i32   add(1, 2);
 * hxsCheckFunctionCall(c, node, sym, name, 3); // the type i32
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckFunctionCall(c: *Ctx, node: u32, sym: u32, namePtr: readonly u8[*], len: i32): u32 {
    if (symbolOf(c, sym).kind != HxSymFunction as u8) {
        unsafe {
            void errorNode(c, nodeOf(c, node).a, `\`${namePtr[0..len as usize]}\` is not a function`);
        }
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    hxsMarkUsed(c, sym);
    if ((symbolOf(c, sym).flags & (HxSymGeneric as u16)) != 0) return hxsCheckGenericCall(c, node, sym, 0, namePtr, len);
    infoOf(c, node).symbol = sym;
    const fnType = symbolOf(c, sym).type;
    if (fnType == 0) {
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    hxsCheckArgs(c, node, fnType, 0, namePtr, len);
    return typeOf(c, fnType).child;
}

/**
 * Checks `a ?? b`, which supplies a fallback for a null optional.
 *
 * @param c - The checker context
 * @param node - The binary node
 * @returns The payload type of the optional, the optional type itself, or 0 on an error
 *
 * @remarks
 * The left side must be an optional, and the right side must convert to its payload.
 * When both sides have the same optional type, the result stays optional.
 *
 * @example
 * ```hx
 * // const n: ?i32 = null;   n ?? 0
 * hxsCheckCoalesce(c, node); // the type i32
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckCoalesce(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const left = hxsCheckExpr(c, n.a, 0);
    if (left == 0) {
        void hxsCheckExpr(c, n.b, 0);
        return 0;
    }
    if (typeOf(c, left).kind != TypeKind.Optional) {
        const diag = errorNode(c, n.a, `\`??\` needs an optional on the left, found \`${typeName(c, left)}\``);
        hint(c, diag, "`??` supplies a fallback for null, and this value is never null");
        void hxsCheckExpr(c, n.b, 0);
        return 0;
    }
    const payload = typeOf(c, left).child;
    const right = hxsCheckExpr(c, n.b, 0);
    if (right == 0) return 0;
    if (right == left) return left;   // `a ?? b` with both optional stays optional
    return hxsCoerce(c, n.b, payload) ? payload : 0;
}

/**
 * Checks a binary operator and folds it when both sides are known.
 *
 * @param c - The checker context
 * @param node - The binary node
 * @returns The result type, which is `bool` for a comparison or a logical operator, or 0 on an error
 *
 * @remarks
 * - **Logical** - `&&` and `||` take booleans,
 *   and the narrowing of the left side applies to the right side, as in `x != null && x.len > 0`.
 * - **Null comparison** - `null` compares with `==` or `!=` only, and only with an optional.
 * - **Shift** - both sides must be integers,
 *   and a literal shifted by a runtime amount needs a concrete type.
 * - **Comparison** - numbers compare with every operator.
 *   Booleans, pointers, enums, error sets, and functions compare with `==` and `!=`.
 *   Slices, strings, structs, and unions never compare,
 *   since `==` never compares memory implicitly.
 * - **Arithmetic** - integers take every operator, and floats take `+`, `-`, `*`, and `/`.
 *   The wrapping and saturating operators need a concrete integer type to know where to wrap.
 *
 * In a comparison, an enum literal on the right takes its type from the left, as in `role == .Admin`.
 *
 * @example
 * ```hx
 * // true + 1
 * hxsCheckBinary(c, node); // error: `+` doesn't work on `bool`
 * ```
 *
 * @see hxsCheckCoalesce
 * @since 1.0.0
 */

export extern "C" function hxsCheckBinary(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const op = @enumFromInt(BinOp, n.op);
    const opNumber = n.op as u32;
    const tys = types(c);
    const boolean = tys.boolType;
    if (op == BinOp.Coalesce) return hxsCheckCoalesce(c, node);

    if (op == BinOp.And || op == BinOp.Or) {
        void hxsCheckExpr(c, n.a, boolean);
        const mark = c.narrowed.len;
        hxsCollectNarrowing(c, n.a, op == BinOp.And);   // `x != null && x.len > 0`
        void hxsCheckExpr(c, n.b, boolean);
        c.narrowed.len = mark;
        hxsFoldBinary(c, node, opNumber, boolean);
        return boolean;
    }

    const compare = opNumber >= BinOp.Eq as u32 && opNumber <= BinOp.Ge as u32;
    const ta = hxsCheckExpr(c, n.a, 0);
    // `role == .Admin`: the right side takes its type from the left
    const contextual = compare && ta != 0 && nodeOf(c, n.b).kind == NodeKind.EnumLiteral;
    const tb = hxsCheckExpr(c, n.b, contextual ? ta : 0);
    if (ta == 0 || tb == 0) return 0;
    const shift = op == BinOp.Shl || op == BinOp.Shr;

    if (compare && (typeOf(c, ta).kind == TypeKind.Null || typeOf(c, tb).kind == TypeKind.Null)) {
        const other = typeOf(c, ta).kind == TypeKind.Null ? tb : ta;
        if (op != BinOp.Eq && op != BinOp.Ne) {
            void errorNode(c, node, "`null` can only be compared with `==` or `!=`");
            return 0;
        }
        if (typeOf(c, other).kind != TypeKind.Optional) {
            const diag = errorNode(c, node, `\`${typeName(c, other)}\` is never null`);
            hint(c, diag, "only optionals (`?T`) can be compared with `null`");
            return 0;
        }
        return boolean;
    }

    if (shift) {
        if (!hxsIsInteger(c, ta) || !hxsIsInteger(c, tb)) {
            void errorNode(c, node, `shifts need integers, found \`${typeName(c, ta)}\` and \`${typeName(c, tb)}\``);
            return 0;
        }
        if (hxsIsComptimeNumber(c, ta) && hxsValueOf(c, n.b) == null) {
            const diag = errorNode(c, n.a, "shifting a literal by a runtime amount needs a concrete type");
            hint(c, diag, "give it one: `(1 as u64) << n`");
            return 0;
        }
        if (hxsIsComptimeNumber(c, tb)) void hxsCoerce(c, n.b, typeOf(c, ta).kind == TypeKind.Int ? ta : tys.u32);
        hxsFoldBinary(c, node, opNumber, ta);
        return ta;
    }

    const common = hxsPeer(c, n.a, n.b, node);
    if (common == 0) return 0;
    const t = typeOf(c, common);
    if (compare) {
        const ordered = op != BinOp.Eq && op != BinOp.Ne;
        const equatable = t.kind == TypeKind.Bool || t.kind == TypeKind.Pointer || t.kind == TypeKind.ManyPointer ||
                          t.kind == TypeKind.Enum || t.kind == TypeKind.ErrorSet || t.kind == TypeKind.Function;
        if (!(hxsIsNumeric(c, common) || (!ordered && equatable))) {
            const diag = errorNode(c, node, `\`${typeName(c, common)}\` can't be compared with \`${spelling(opNumber)}\``);
            if (t.kind == TypeKind.Slice || t.kind == TypeKind.StringLiteral) {
                hint(c, diag, "compare the contents element by element; `==` never compares memory implicitly");
            } else if (t.kind == TypeKind.Struct || t.kind == TypeKind.Union) {
                hint(c, diag, "compare the fields you care about; `==` never compares memory implicitly");
            } else if (t.kind == TypeKind.Enum) {
                hint(c, diag, "enums only support `==` and `!=`; compare their numbers with `x as u32`");
            }
            return 0;
        }
        hxsFoldBinary(c, node, opNumber, common);
        return boolean;
    }

    const floatOk = op == BinOp.Add || op == BinOp.Sub || op == BinOp.Mul || op == BinOp.Div;
    if (!(hxsIsInteger(c, common) || (floatOk && hxsIsFloat(c, common)))) {
        const diag = errorNode(c, node, `\`${spelling(opNumber)}\` doesn't work on \`${typeName(c, common)}\``);
        if (t.kind == TypeKind.Bool) hint(c, diag, "use `&&`, `||` or `!` for booleans");
        return 0;
    }
    if ((hxsIsWrapping(opNumber) || hxsIsSaturating(opNumber)) && hxsIsComptimeNumber(c, common)) {
        const diag = errorNode(c, node, `\`${spelling(opNumber)}\` needs a concrete integer type to know where to wrap`);
        hintf(c, diag, `give one side a type, e.g. \`(x as u8) ${spelling(opNumber)} y\``);
        return 0;
    }
    hxsFoldBinary(c, node, opNumber, common);
    return common;
}

/**
 * Checks a prefix operator: `-`, `!`, `~`, `&`, `*`, or `void`.
 *
 * @param c - The checker context
 * @param node - The unary node
 * @returns The result type, or 0 on an error
 *
 * @remarks
 * - **Negation** - `-` needs a signed number and folds a known value.
 * - **Not** - `!` takes a boolean and folds a known value.
 * - **Bitwise not** - `~` needs a concrete integer type, so a bare literal is an error.
 * - **Address** - `&` needs a place, and it counts as a write of the place,
 *   since whoever gets the address may give it a value.
 *   A compile-time constant has no address, a local with a known value gets marked as addressed,
 *   and taking a mutable address marks the root of the place as mutated.
 *   The pointer is `readonly` when the place is not mutable.
 * - **Dereference** - `*` works on `*T` pointers only.
 * - **Discard** - `void` refuses a `void` value and an error union,
 *   and gives a literal a runtime type.
 *
 * @example
 * ```hx
 * // const x: u32 = 1;   -x
 * hxsCheckUnary(c, node); // error: can't negate unsigned `u32`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckUnary(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const tys = types(c);
    switch (n.kind) {
        case NodeKind.Negate: {
            const t = hxsCheckExpr(c, n.a, 0);
            if (t == 0) return 0;
            if (!hxsIsNumeric(c, t)) {
                void errorNode(c, node, `\`-\` needs a number, found \`${typeName(c, t)}\``);
                return 0;
            }
            if (typeOf(c, t).kind == TypeKind.Int && (typeOf(c, t).flags & Signed) == 0) {
                const diag = errorNode(c, node, `can't negate unsigned \`${typeName(c, t)}\``);
                hint(c, diag, "for wrapping negation use `0 -% x`");
                return 0;
            }
            if (const v = hxsValueOf(c, n.a)) {
                if (v.kind == HxValueFloat as u8) {
                    infoOf(c, node).value = hxsFloatValue(c, -v.floating);
                } else {
                    let r: i128 = 0;
                    if (hxsFoldInt(c, node, BinOp.Sub as u32, 0, v.integer, t, &r)) infoOf(c, node).value = hxsIntValue(c, r);
                }
            }
            return t;
        }
        case NodeKind.Not: {
            void hxsCheckExpr(c, n.a, tys.boolType);
            if (const v = hxsValueOf(c, n.a)) infoOf(c, node).value = hxsBoolValue(c, !v.boolean);
            return tys.boolType;
        }
        case NodeKind.BitNot: {
            const t = hxsCheckExpr(c, n.a, 0);
            if (t == 0) return 0;
            if (typeOf(c, t).kind != TypeKind.Int) {
                const diag = errorNode(c, node, `\`~\` needs a concrete integer type, found \`${typeName(c, t)}\``);
                if (hxsIsComptimeNumber(c, t)) hint(c, diag, "give it a type: `~(x as u32)`");
                return 0;
            }
            if (const v = hxsValueOf(c, n.a)) infoOf(c, node).value = hxsIntValue(c, hxsWrapInt(c, t, ~v.integer));
            return t;
        }
        case NodeKind.AddressOf: {
            const t = hxsCheckExpr(c, n.a, 0);
            noteWrite(c, n.a);   // whoever gets the address may give it a value
            if (t == 0) return 0;
            const kind = nodeOf(c, n.a).kind;
            const addressable = kind == NodeKind.Ident || kind == NodeKind.Index || kind == NodeKind.Deref ||
                                (kind == NodeKind.FieldAccess && (infoOf(c, n.a).flags & HxInfoField) != 0);
            if (kind == NodeKind.Ident && hxsValueOf(c, n.a) != null) {
                const sym = infoOf(c, n.a).symbol;
                if (hxsIsComptimeNumber(c, t) || symbolOf(c, sym).kind != HxSymLocal as u8) {
                    const diag = errorNode(c, node, "compile-time constants have no address");
                    hint(c, diag, "give it a concrete type so it can be stored: `const x: i32 = ...`");
                    return 0;
                }
                symbolOf(c, sym).flags |= HxSymAddressed as u16;
                return hxTypePointer(tys, TypeKind.Pointer as u32, t, true);
            }
            if (!addressable || hxsIsComptimeNumber(c, t) || t == tys.stringLiteral) {
                void errorNode(c, node, "can't take the address of this expression");
                return 0;
            }
            const mutable = hxsIsMutablePlace(c, n.a, false);
            if (mutable) {
                const root = hxsPlaceRoot(c, n.a);
                if (root != 0) symbolOf(c, root).flags |= HxSymMutated as u16;   // may be changed through the pointer
            }
            return hxTypePointer(tys, TypeKind.Pointer as u32, t, !mutable);
        }
        case NodeKind.Deref: {
            const t = hxsCheckExpr(c, n.a, 0);
            if (t == 0) return 0;
            if (typeOf(c, t).kind != TypeKind.Pointer) {
                void errorNode(c, node, `can't dereference \`${typeName(c, t)}\`; only \`*T\` pointers can be`);
                return 0;
            }
            return typeOf(c, t).child;
        }
        case NodeKind.Discard: {
            const t = hxsCheckExpr(c, n.a, 0);
            if (t == tys.voidType) {
                const diag = errorNode(c, node, "nothing to discard: the expression is `void`");
                hint(c, diag, "remove the `void`");
            } else if (t != 0 && typeOf(c, t).kind == TypeKind.ErrorUnion) {
                const diag = errorNode(c, node, "`void` discards values, not errors");
                hint(c, diag, "handle the error: `void try f()` or `f() catch ...`");
            }
            if (t != 0 && hxsIsComptimeNumber(c, t)) void hxsCoerce(c, n.a, hxsIsFloat(c, t) ? tys.f64 : tys.i64);
            return tys.voidType;
        }
        default: unreachable;
    }
}

/**
 * Checks an `as` conversion and converts a known value right away.
 *
 * @param c - The checker context
 * @param node - The cast node
 * @returns The target type, or 0 on an error
 *
 * @remarks
 * `as` converts between numbers, from a boolean to an integer, and from an enum to an integer.
 * A cast to a `dyn` type, as in `&file as dyn Writer`, spells out the implicit conversion.
 * The checker converts known values now,
 * so an out-of-range constant is a compile error, not a runtime panic.
 * A float that does not fit or is NaN is an error when the target is an integer.
 *
 * @example
 * ```hx
 * // 300 as u8
 * hxsCheckCast(c, node); // error: 300 does not fit in `u8`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckCast(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const from = hxsCheckExpr(c, n.a, 0);
    const to = hxsResolveType(c, n.b);
    if (from == 0 || to == 0) return 0;
    const f = typeOf(c, from);
    const t = typeOf(c, to);
    const tys = types(c);
    if (t.kind == TypeKind.Dyn) return hxsCoerce(c, n.a, to) ? to : 0;   // `&file as dyn Writer`: the implicit conversion, spelled out
    const numericTo = t.kind == TypeKind.Int || t.kind == TypeKind.Float;
    const numericFrom = hxsIsNumeric(c, from) || f.kind == TypeKind.Bool || (f.kind == TypeKind.Enum && t.kind == TypeKind.Int);
    if (!numericTo || !numericFrom || (f.kind == TypeKind.Bool && t.kind != TypeKind.Int)) {
        void errorNode(c, node, `can't convert \`${typeName(c, from)}\` to \`${typeName(c, to)}\` with \`as\``);
        return 0;
    }
    // known values are converted now, so an out-of-range constant is a compile error, not a runtime panic
    if (const v = hxsValueOf(c, n.a)) {
        if (t.kind == TypeKind.Int) {
            if (v.kind == HxValueFloat as u8 && (v.floating != v.floating || v.floating >= 1.7e38 || v.floating <= -1.7e38)) {
                void errorNode(c, node, `float value is out of range for \`${typeName(c, to)}\``);
                return 0;
            }
            const x: i128 = v.kind == HxValueFloat as u8 ? v.floating as i128 : v.kind == HxValueBool as u8 ? (v.boolean ? 1 : 0) : v.integer;
            if (!hxsIntFits(c, to, x)) {
                let buf: u8[48] = undefined;
                const diag = errorNode(c, node, `${i128Text(x, &buf)} does not fit in \`${typeName(c, to)}\``);
                hintf(c, diag, `use \`@truncate(${typeName(c, to)}, x)\` to keep only the low bits`);
                return 0;
            }
            infoOf(c, node).value = hxsIntValue(c, x);
        } else {
            infoOf(c, node).value = hxsFloatValue(c, v.kind == HxValueFloat as u8 ? v.floating : v.integer as f64);
        }
    } else if (hxsIsComptimeNumber(c, from)) {
        void hxsCoerce(c, n.a, hxsIsFloat(c, from) ? tys.f64 : tys.i64);
    }
    return to;
}
