/**
 * Imports
 */

import { record } from "@models/ast.model";
import { Ctx, Loop } from "@structs/sema.struct";
import { hxTypeName } from "@models/types.model";
import { hxIntern } from "@services/intern.service";
import { HxMemberMethod } from "@constants/sema.constant";
import { HxForOfData } from "@models/structs/ast-model.struct";
import { TypeKind, Readonly } from "@constants/types.constant";
import { hxEvalExpr } from "@modules/sema/services/eval.service";
import { declareUnset } from "@modules/sema/components/unset.component";
import { hxsCheckStmt } from "@modules/sema/components/switch.component";
import { hxsPointedArray } from "@modules/sema/components/base.component";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { NodeKind, BinOp, FlagExtern, NoToken } from "@constants/ast.constant";
import { hxsMethodInstance } from "@modules/sema/components/generics.component";
import { hxsCheckExpr, hxsEvalHost } from "@modules/sema/components/expr.component";
import { hxsFindMember, hxsMemberOf } from "@modules/sema/components/aggregate.component";
import { hxsMarkUsed, hxsIsMutablePlace, hxsPlaceRoot } from "@modules/sema/components/call.component";
import { HxInfoDeref, HxSymMutated, HxSymGlobal, HxSymUsed, HxValueUndefined } from "@constants/sema.constant";
import { HxInfoReceiverAddr, HxSymLocal, HxInfoIterator, HxInfoDyn, MaxLoops } from "@constants/sema.constant";
import { hxsDeclareLocal, hxsPushScope, hxsPopScope, pushU32 } from "@modules/sema/components/scope.component";
import { infoOf, extraOf, types, paramOf, tokenText, typeName } from "@modules/sema/components/base.component";
import { hxsIsAggregate, semaOf, astOf, nodeOf, typeOf, symbolOf } from "@modules/sema/components/base.component";
import { hxsCoerce, hxsPeer, hxsFormatEscapes, hxsIsComptimeNumber } from "@modules/sema/components/base.component";
import { errorNode, errorToken, hint, hintf, hxsTokName, hxsValueOf } from "@modules/sema/components/base.component";
import { HxSymMutable, HxSymTemplateMethod, HxInfoField, HxValueAggregate, HxSymParam } from "@constants/sema.constant";

/**
 * Checks a `const` or `let` declaration, local or global, and declares the local.
 *
 * @param c - The checker context
 * @param node - The declaration node
 * @param global - Whether the declaration is at the top level of a file
 * @returns The symbol of the new local, or 0 for a global, which the declaration pass already declared
 *
 * @remarks
 * The type comes from the annotation, or else from the initial value.
 * A literal number, `undefined`, `null`, and a `void` value give no type of their own, so they are errors there.
 * A `const` keeps a literal number as a compile-time value, and a string literal becomes a `string`.
 * A `const` without a value, and a `let` without a type or a value, are errors.
 * A typed `let` without a value is also an error, and the hint suggests `= undefined`.
 *
 * Helix runs no code before `main`, so the initial value of a global must be known at compile time,
 * and a global constant can't be `undefined`.
 * A global constant initialized with a struct or array literal is data, so the checker folds it without `comptime`,
 * as in `const origin: Point = { x: 0, y: 0 };`.
 * An `extern "C" let` names a global that C defines, so it needs a type and takes no value.
 *
 * A `const` keeps its compile-time value on the symbol, except for arrays and structs from `comptime`,
 * which stay in storage so that each use does not copy the whole value in.
 * A `let` of a whole value initialized with `undefined` starts without a value,
 * since arrays, structs, and unions are filled piece by piece.
 * When the initial value fails to check, the local counts as used and mutated so that no further warnings follow.
 *
 * @example
 * ```hx
 * // let total: i32 = 0;
 * hxsCheckLocal(c, node, false); // the symbol of total
 * ```
 *
 * @see declareUnset
 * @since 1.0.0
 */

export extern "C" function hxsCheckLocal(c: *Ctx, node: u32, global: bool): u32 {
    const n = nodeOf(c, node);
    const isConst = n.kind == NodeKind.Const;
    const name = n.token != NoToken ? tokenText(c, n.token) : "?";
    const tys = types(c);
    const s = semaOf(c);
    let declared = n.a != 0 ? hxsResolveType(c, n.a) : 0;
    if (hxsFormatEscapes(c, declared, n.a)) declared = 0;
    let type = declared;
    let value: u32 = 0;
    let initFailed = false;

    if (global && (n.flags & FlagExtern) != 0) {   // `extern "C" let x: i32;`: C defines it, Helix only names it
        if (n.a == 0) void errorToken(c, n.token, `a C global needs a type: \`extern "C" let ${name}: i32;\``);
        if (n.b != 0) {
            const diag = errorNode(c, n.b, "a C global gets its value from C");
            hint(c, diag, "remove the `= ...`; to define a global for C, leave out `extern`");
            void hxsCheckExpr(c, n.b, 0);
        }
    } else if (n.a != 0 && declared == 0) {
        if (n.b != 0) void hxsCheckExpr(c, n.b, 0);
        type = 0;
    } else if (n.b == 0) {
        if (isConst) {
            void errorToken(c, n.token, `\`const ${name}\` needs a value`);
        } else if (declared == 0) {
            const diag = errorToken(c, n.token, `\`let ${name}\` needs a type or a value`);
            hintf(c, diag, `write \`let ${name}: i32 = 0;\``);
        } else if (global) {
            const diag = errorToken(c, n.token, `global \`${name}\` needs an initial value`);
            hint(c, diag, "use `= undefined` if it's assigned before it's read");
        } else {
            const diag = errorToken(c, n.token, `\`${name}\` needs an initial value`);
            hint(c, diag, "use `= undefined` if it's assigned before it's read");
        }
    } else {
        const errorsBefore = s.diags!.errorCount;
        const savedConstInit = c.constInit;
        c.constInit = global && isConst;
        let init = hxsCheckExpr(c, n.b, declared);
        c.constInit = savedConstInit;
        initFailed = s.diags!.errorCount != errorsBefore;
        const initKind = nodeOf(c, n.b).kind;
        if (global && isConst && !initFailed && hxsValueOf(c, n.b) == null &&
            (initKind == NodeKind.StructLiteral || initKind == NodeKind.ArrayLiteral)) {
            // `const origin: Point = { x: 0, y: 0 };`: data, so the compiler works it out without `comptime`
            if (declared != 0) void hxsCoerce(c, n.b, declared);
            let host = hxsEvalHost(c);
            const folded = hxEvalExpr(&host, n.b, c.instance);
            if (folded != 0 && folded != 0xFFFF_FFFF) infoOf(c, n.b).value = folded;
            initFailed = s.diags!.errorCount != errorsBefore;
        }
        if (declared == 0 && init != 0 && !initFailed) {
            const t = typeOf(c, init);
            switch (t.kind) {
                case TypeKind.ComptimeInt, TypeKind.ComptimeFloat: {
                    if (!isConst || hxsValueOf(c, n.b) == null) {
                        const diag = errorToken(c, n.token, `can't tell which number type \`${name}\` should be`);
                        hintf(c, diag, `write the type: \`let ${name}: ${t.kind == TypeKind.ComptimeInt ? "i32" : "f64"} = ...\``);
                        init = 0;
                    }
                }
                case TypeKind.StringLiteral: {
                    void hxsCoerce(c, n.b, tys.string);
                    init = tys.string;
                }
                case TypeKind.Undefined: {
                    void errorToken(c, n.token, `\`undefined\` needs an explicit type: \`let ${name}: T = undefined;\``);
                    init = 0;
                }
                case TypeKind.Null: {
                    void errorToken(c, n.token, `\`null\` needs an explicit type: \`let ${name}: ?T = null;\``);
                    init = 0;
                }
                case TypeKind.Void: {
                    void errorNode(c, n.b, "this expression has no value (`void`)");
                    init = 0;
                }
                case TypeKind.Format: {
                    void hxsFormatEscapes(c, init, n.b);
                    init = 0;
                }
                default: {}
            }
            type = init;
        }
        if (declared == 0 && initFailed) type = 0;
        const v = hxsValueOf(c, n.b);
        // arrays and structs from `comptime` stay in storage, so each use doesn't copy the whole value in
        if (isConst && v != null && v.kind != HxValueUndefined as u8 && v.kind != HxValueAggregate as u8) value = infoOf(c, n.b).value;
        if (global && !initFailed) {
            if (v == null) {
                const diag = errorNode(c, n.b, "a global's initial value must be known at compile time");
                hint(c, diag, "Helix runs no code before `main`; compute it while compiling with `comptime f()`, or inside `main`");
            } else if (isConst && v.kind == HxValueUndefined as u8) {
                void errorNode(c, n.b, "a global constant can't be `undefined`");
            }
        }
    }

    infoOf(c, node).type = type;
    if (global) return 0;
    const sym = hxsDeclareLocal(c, HxSymLocal, n.token, node, type);
    if (sym != 0) {
        if (!isConst) symbolOf(c, sym).flags |= HxSymMutable as u16;
        if (initFailed) symbolOf(c, sym).flags |= (HxSymUsed | HxSymMutated) as u16;
        symbolOf(c, sym).value = value;
        infoOf(c, node).symbol = sym;
        // arrays, structs and unions are filled piece by piece, so only whole values are followed
        const k = type != 0 ? typeOf(c, type).kind : TypeKind.Invalid;
        if (!isConst && n.b != 0 && k != TypeKind.Array && k != TypeKind.Struct && k != TypeKind.Union && k != TypeKind.Invalid) {
            if (const v = hxsValueOf(c, n.b)) {
                if (v.kind == HxValueUndefined as u8) declareUnset(c, sym);
            }
        }
    }
    return sym;
}

/**
 * Finds the loop that a `break` or `continue` leaves.
 *
 * @param c - The checker context
 * @param node - The `break` or `continue` node
 * @param label - The label token, or `NoToken` for the innermost loop
 * @param keywordPtr - The keyword for the error messages, as a NUL-terminated string
 * @param index - The variable that receives the index of the loop on the loop stack
 * @returns The loop, or `null` after an error
 *
 * @remarks
 * It is an error outside of a loop, with a label that no enclosing loop has,
 * and when the jump would leave a `defer`, since a defer always runs to completion.
 *
 * @example
 * ```hx
 * // outer: while (true) { while (true) { break outer; } }
 * let index: u32 = 0;
 * hxsFindLoop(c, node, label, "break", &index); // the outer loop, index 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsFindLoop(c: *Ctx, node: u32, label: u32, keywordPtr: readonly u8[*], index: *u32): ?*Loop {
    let keyword: string = "";
    unsafe {
        let n: usize = 0;
        while (keywordPtr[n] != 0) n += 1;
        keyword = keywordPtr[0..n];
    }
    if (c.loopCount == 0) {
        void errorNode(c, node, `\`${keyword}\` outside of a loop`);
        return null;
    }
    let i = c.loopCount;
    if (label == NoToken) {
        i -= 1;
    } else {
        const name = hxsTokName(c, label);
        while (i > 0) {
            const loopLabel = c.loops[i - 1].label;
            if (loopLabel != NoToken && hxsTokName(c, loopLabel) == name) break;
            i -= 1;
        }
        if (i == 0) {
            void errorToken(c, label, `no enclosing loop is labeled \`${tokenText(c, label)}\``);
            return null;
        }
        i -= 1;
    }
    if (c.inDefer && i < c.deferFloor) {
        const diag = errorNode(c, node, `\`${keyword}\` can't jump out of a \`defer\``);
        hint(c, diag, "a defer always runs to completion; move the loop control outside it");
        return null;
    }
    *index = i;
    return &c.loops[i];
}

/**
 * Enters a loop, so that `break` and `continue` inside it can find it.
 *
 * @param c - The checker context
 * @param node - The loop node
 * @param label - The label token of the loop, or `NoToken`
 *
 * @remarks
 * More than `MaxLoops` nested loops are an error, and the loop is then not entered.
 *
 * @example
 * ```hx
 * hxsPushLoop(c, node, NoToken);
 * // check the body
 * hxsPopLoop(c); // true when the body breaks out
 * ```
 *
 * @see hxsPopLoop
 * @since 1.0.0
 */

export extern "C" function hxsPushLoop(c: *Ctx, node: u32, label: u32): void {
    if (c.loopCount == MaxLoops) {
        void errorNode(c, node, "loops are nested too deeply");
        return;
    }
    c.loops[c.loopCount] = Loop { node, label, hasBreak: false };
    c.loopCount += 1;
}

/**
 * Leaves the innermost loop.
 *
 * @param c - The checker context
 * @returns `true` when a `break` left the loop, which then ends even without a condition
 *
 * @remarks
 * With no loop entered it returns `false` and changes nothing.
 * The caller uses the result to decide whether code after an endless loop is reachable.
 *
 * @example
 * ```hx
 * // while (true) { break; }
 * hxsPopLoop(c); // true
 * ```
 *
 * @see hxsPushLoop
 * @since 1.0.0
 */

export extern "C" function hxsPopLoop(c: *Ctx): bool {
    if (c.loopCount == 0) return false;
    c.loopCount -= 1;
    return c.loops[c.loopCount].hasBreak;
}

/**
 * Checks a condition, which must be a `bool`.
 *
 * @param c - The checker context
 * @param cond - The condition expression
 *
 * @remarks
 * Helix has no truthiness, so `if (count)` is an error.
 *
 * @example
 * ```hx
 * // if (count > 0)
 * hxsCheckCondition(c, cond); // the condition is a bool
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckCondition(c: *Ctx, cond: u32): void {
    void hxsCheckExpr(c, cond, types(c).boolType);
}

/**
 * Checks the statements of a block in order.
 *
 * @param c - The checker context
 * @param start - The index of the first statement in the extra list
 * @param end - The index after the last statement
 * @returns `true` when the block never goes on
 *
 * @remarks
 * The first statement after one that always returns, breaks, or panics is reported as unreachable code,
 * once per block.
 * Narrowing from `if (x == null) return;` lasts to the end of the block.
 * The caller enters and leaves the scope of the block.
 *
 * @example
 * ```hx
 * // { return 1; f(); }
 * hxsCheckBlockContents(c, start, end); // true, and f() is unreachable code
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckBlockContents(c: *Ctx, start: u32, end: u32): bool {
    const narrowed = c.narrowed.len;   // narrowing from `if (x == null) return;` lasts to the end of the block
    let terminated = false;
    let reported = false;
    for (const i of start..end) {
        const stmt = extraOf(c, i);
        if (terminated && !reported) {
            const diag = errorNode(c, stmt, "unreachable code");
            hint(c, diag, "the statement before it always returns, breaks or panics");
            reported = true;
        }
        if (hxsCheckStmt(c, stmt)) terminated = true;
    }
    c.narrowed.len = narrowed;
    return terminated;
}

/**
 * Checks a statement in a scope of its own, as for the body of a branch or a loop.
 *
 * @param c - The checker context
 * @param stmt - The statement node, where 0 does nothing
 * @returns `true` when the statement never goes on
 *
 * @remarks
 * The scope ends with the statement, so a declaration in a branch without braces is gone after the branch.
 *
 * @example
 * ```hx
 * // if (ok) const x = 1;   x is gone after the branch
 * hxsCheckScoped(c, thenBranch); // false
 * ```
 *
 * @see hxsCheckStmt
 * @since 1.0.0
 */

export extern "C" function hxsCheckScoped(c: *Ctx, stmt: u32): bool {
    if (stmt == 0) return false;
    hxsPushScope(c);
    const terminated = hxsCheckStmt(c, stmt);
    hxsPopScope(c);
    return terminated;
}

/**
 * Writes the name of a type into a buffer.
 *
 * @param c - The checker context
 * @param t - The type
 * @param buf - The buffer that receives the name
 * @returns The name, as a slice of the buffer
 *
 * @remarks
 * Unlike `typeName`, it writes into a 256-byte buffer that the caller owns,
 * so a hint can name a long function type next to any number of other types.
 * A name that does not fit is cut short at 255 bytes.
 *
 * @since 1.0.0
 */

function typeText(c: *Ctx, t: u32, buf: *u8[256]): string {
    hxTypeName(types(c), t, buf, 256);
    let n: usize = 0;
    while (buf[n] != 0) n += 1;
    return buf[0..n];
}

/**
 * Checks a `for-of` loop over an iterator, a value with a method `next(this: *Self): ?T`.
 *
 * @param c - The checker context
 * @param node - The `for-of` node
 * @param iterable - The expression that the loop runs over
 * @param t - The type of the expression
 * @param isIterator - The variable that is set to `true` when the type has a `next` member
 * @returns The item type `T`, or 0 after an error or when the type is not an iterator, which it does not report
 *
 * @remarks
 * The loop calls `next` until it returns `null`.
 * Like a method call, it advances a variable in place, so the variable must be a `let`.
 * It advances a pointer through the pointer, and any other value as a copy.
 * A `dyn` interface value calls `next` through the interface.
 *
 * A generic `next`, or one with a different signature, is an error.
 * When `next` can fail, the hint suggests `while (const x = try it.next())`, since `for-of` can't `try` it.
 * A readonly pointer can't advance an iterator whose `next` takes a mutable receiver.
 *
 * @example
 * ```hx
 * // for (const word of words) where words has next(this: *Words): ?string
 * let isIterator = false;
 * hxsCheckIterator(c, node, iterable, wordsType, &isIterator); // string, and isIterator is true
 * ```
 *
 * @see hxsCheckForOf
 * @since 1.0.0
 */

export extern "C" function hxsCheckIterator(c: *Ctx, node: u32, iterable: u32, t: u32, isIterator: *bool): u32 {
    const next = hxIntern(&semaOf(c).names, "next", 4);
    let fnType: u32 = 0;
    let target = t;
    let throughPointer = false;
    if (typeOf(c, t).kind == TypeKind.Dyn) {
        const iface = typeOf(c, t).child;
        const index = hxsFindMember(c, iface, next);
        if (index < 0) return 0;
        *isIterator = true;
        const m = hxsMemberOf(c, iface, index);
        if (m.type == 0) return 0;
        fnType = m.type;
        infoOf(c, node).flags |= HxInfoIterator | HxInfoDyn;
        infoOf(c, node).aux = m.index;
    } else {
        if (typeOf(c, t).kind == TypeKind.Pointer && hxsIsAggregate(c, typeOf(c, t).child)) {
            target = typeOf(c, t).child;
            throughPointer = true;
        }
        if (!hxsIsAggregate(c, target) || typeOf(c, target).kind == TypeKind.Interface) return 0;
        const index = hxsFindMember(c, target, next);
        if (index < 0 || hxsMemberOf(c, target, index).kind != HxMemberMethod as u8) return 0;
        *isIterator = true;
        if ((symbolOf(c, hxsMemberOf(c, target, index).symbol).flags & (HxSymTemplateMethod as u16)) != 0) {
            void errorNode(c, iterable, `\`${typeName(c, target)}.next\` is generic, so \`for-of\` can't call it`);
            return 0;
        }
        const method = hxsMethodInstance(c, hxsMemberOf(c, target, index).symbol, target, node);
        hxsMarkUsed(c, method);
        fnType = symbolOf(c, method).type;
        if (fnType == 0) return 0;
        infoOf(c, node).flags |= HxInfoIterator | (throughPointer ? HxInfoDeref : 0);
        infoOf(c, node).aux = method;
    }

    const fn = typeOf(c, fnType);
    const receiver = fn.len != 0 ? paramOf(c, fn, 0) : 0;
    const receiverOk = receiver != 0 && typeOf(c, receiver).kind == TypeKind.Pointer &&
                       (typeOf(c, t).kind == TypeKind.Dyn || typeOf(c, receiver).child == target);
    const result = fn.child;
    if (!receiverOk || fn.len != 1 || typeOf(c, result).kind != TypeKind.Optional) {
        const diag = errorNode(c, iterable, `\`for-of\` calls \`${typeName(c, target)}.next()\`, which isn't \`next(this: *Self): ?T\``);
        let text: u8[256] = undefined;
        const fnText = typeText(c, fnType, &text);
        if (typeOf(c, result).kind == TypeKind.ErrorUnion && typeOf(c, typeOf(c, result).child).kind == TypeKind.Optional) {
            hintf(c, diag, `its \`next\` can fail (\`${fnText}\`), and \`for-of\` can't \`try\` it; write \`while (const x = try it.next()) { ... }\``);
        } else {
            hintf(c, diag, `its \`next\` is \`${fnText}\``);
        }
        return 0;
    }
    if (typeOf(c, t).kind == TypeKind.Dyn || throughPointer) {
        if ((typeOf(c, receiver).flags & Readonly) == 0 && (typeOf(c, t).flags & Readonly) != 0) {
            const diag = errorNode(c, iterable, `\`next\` changes the \`${typeName(c, target)}\`, but this pointer is readonly`);
            hintf(c, diag, `pass a mutable \`*${typeName(c, target)}\``);
        }
        return typeOf(c, result).child;
    }
    // a value: a variable is advanced in place, anything else runs on a copy
    const kind = nodeOf(c, iterable).kind;
    const place = kind == NodeKind.Ident || kind == NodeKind.Index || kind == NodeKind.Deref ||
                  (kind == NodeKind.FieldAccess && (infoOf(c, iterable).flags & HxInfoField) != 0);
    if (place && !(kind == NodeKind.Ident && hxsValueOf(c, iterable) != null)) {
        infoOf(c, node).flags |= HxInfoReceiverAddr;
        if ((typeOf(c, receiver).flags & Readonly) == 0) {
            if (!hxsIsMutablePlace(c, iterable, false)) {
                const diag = errorNode(c, iterable, `the loop advances this \`${typeName(c, target)}\`, but it's constant`);
                hint(c, diag, "declare it with `let`");
            } else {
                const root = hxsPlaceRoot(c, iterable);
                if (root != 0) symbolOf(c, root).flags |= HxSymMutated as u16;
            }
        }
    }
    return typeOf(c, result).child;
}

/**
 * Checks a `for (const x of ...)` loop and declares its item and index.
 *
 * @param c - The checker context
 * @param node - The `for-of` node
 * @returns `false`, since a `for-of` loop always ends
 *
 * @remarks
 * The loop runs over a range of integers (`0..n`), a slice, an array or a pointer to one, a string, or an iterator.
 * A range of literal numbers counts in `usize`, and the items of a string are `u8` bytes.
 * The optional index is a `usize`.
 * The symbol of the index, when present, is declared right after the item, so it is the item symbol plus one.
 *
 * @example
 * ```hx
 * // for (const ch, i of "abc") { ... }
 * hxsCheckForOf(c, node); // false, ch is a u8, i is a usize
 * ```
 *
 * @see hxsCheckIterator
 * @since 1.0.0
 */

export extern "C" function hxsCheckForOf(c: *Ctx, node: u32): bool {
    const data = record<HxForOfData>(astOf(c), nodeOf(c, node).a);
    const tys = types(c);
    hxsPushScope(c);
    let item: u32 = 0;
    const iter = nodeOf(c, data.iterable);
    if (iter.kind == NodeKind.Range) {
        const ta = hxsCheckExpr(c, iter.a, 0);
        const tb = hxsCheckExpr(c, iter.b, 0);
        if (ta != 0 && tb != 0) {
            let common = hxsPeer(c, iter.a, iter.b, data.iterable);
            if (common != 0 && hxsIsComptimeNumber(c, common)) {
                void hxsCoerce(c, iter.a, tys.usize);
                void hxsCoerce(c, iter.b, tys.usize);
                common = tys.usize;
            }
            if (common != 0 && typeOf(c, common).kind != TypeKind.Int) {
                void errorNode(c, data.iterable, `a range needs integers, found \`${typeName(c, common)}\``);
                common = 0;
            }
            item = common;
        }
        infoOf(c, data.iterable).type = item;
    } else {
        const t = hxsCheckExpr(c, data.iterable, 0);
        if (t != 0) {
            const type = typeOf(c, t);
            const array = type.kind == TypeKind.Array ? t : hxsPointedArray(c, t);
            if (type.kind == TypeKind.Slice) {
                item = type.child;
            } else if (array != 0) {
                item = typeOf(c, array).child;
            } else if (type.kind == TypeKind.StringLiteral) {
                void hxsCoerce(c, data.iterable, tys.string);
                item = tys.u8;
            } else {
                let isIterator = false;
                item = hxsCheckIterator(c, node, data.iterable, t, &isIterator);
                if (!isIterator) {
                    const diag = errorNode(c, data.iterable, `can't loop over \`${typeName(c, t)}\``);
                    hint(c, diag, "`for-of` works on ranges (`0..n`), slices, arrays and iterators (types with `next(this: *Self): ?T`)");
                }
            }
        }
    }
    const itemSym = hxsDeclareLocal(c, HxSymLocal, data.itemToken, node, item);
    if (data.indexToken != NoToken) void hxsDeclareLocal(c, HxSymLocal, data.indexToken, node, tys.usize);
    infoOf(c, node).symbol = itemSym;   // the index symbol, when present, is declared right after it: item + 1
    hxsPushLoop(c, node, data.labelToken);
    void hxsCheckScoped(c, data.body);
    void hxsPopLoop(c);
    hxsPopScope(c);
    return false;
}

/**
 * Checks whether an expression names an optional that a null check can narrow.
 *
 * @param c - The checker context
 * @param node - The expression
 * @param out - The variable that receives the symbol
 * @returns `true` for a parameter, a `const` local, or a constant of an optional type
 *
 * @remarks
 * Only symbols that can't change are narrowed, so a `let` stays optional after a check.
 *
 * @example
 * ```hx
 * // function f(p: ?*Node) { if (p != null) ... }
 * let sym: u32 = 0;
 * hxsNarrowable(c, node, &sym); // true, and sym is p
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsNarrowable(c: *Ctx, node: u32, out: *u32): bool {
    if (nodeOf(c, node).kind != NodeKind.Ident) return false;
    const sym = infoOf(c, node).symbol;
    if (sym == 0) return false;
    const s = symbolOf(c, sym);
    const immutable = s.kind == HxSymParam as u8 ||
                      ((s.kind == HxSymLocal as u8 || s.kind == HxSymGlobal as u8) && (s.flags & (HxSymMutable as u16)) == 0);
    if (!immutable || s.type == 0 || typeOf(c, s.type).kind != TypeKind.Optional) return false;
    *out = sym;
    return true;
}

/**
 * Records the optionals that a condition proves non-null.
 *
 * @param c - The checker context
 * @param cond - The condition expression
 * @param whenTrue - Whether the code that follows runs when the condition is `true`
 *
 * @remarks
 * `x != null` proves `x` when the condition holds, and `x == null` proves it when it does not.
 * It looks through `!`, through `&&` when the condition holds, and through `||` when it does not.
 * The caller drops the narrowed symbols again by resetting the length of the list.
 *
 * @example
 * ```hx
 * // if (a != null && b != null)
 * hxsCollectNarrowing(c, cond, true); // a and b are non-null in the then branch
 * ```
 *
 * @see hxsNarrowable
 * @since 1.0.0
 */

export extern "C" function hxsCollectNarrowing(c: *Ctx, cond: u32, whenTrue: bool): void {
    const n = nodeOf(c, cond);
    if (n.kind == NodeKind.Not) {
        hxsCollectNarrowing(c, n.a, !whenTrue);
        return;
    }
    if (n.kind != NodeKind.Binary) return;
    const op = @enumFromInt(BinOp, n.op);
    if (op == BinOp.And && whenTrue) {
        hxsCollectNarrowing(c, n.a, true);
        hxsCollectNarrowing(c, n.b, true);
        return;
    }
    if (op == BinOp.Or && !whenTrue) {
        hxsCollectNarrowing(c, n.a, false);
        hxsCollectNarrowing(c, n.b, false);
        return;
    }
    const nonNull = (op == BinOp.Ne && whenTrue) || (op == BinOp.Eq && !whenTrue);
    if (!nonNull) return;
    const other = nodeOf(c, n.a).kind == NodeKind.Null ? n.b : nodeOf(c, n.b).kind == NodeKind.Null ? n.a : 0;
    let sym: u32 = 0;
    if (other != 0 && hxsNarrowable(c, other, &sym)) pushU32(&c.narrowed, sym);
}
