/**
 * Imports
 */

import { Ctx } from "@structs/sema.struct";
import { record } from "@models/ast.model";
import { hxTypeOptional } from "@models/types.model";
import { NodeKind, NoToken } from "@constants/ast.constant";
import { HxCatchData } from "@models/structs/ast-model.struct";
import { TypeKind, AnyError } from "@constants/types.constant";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { hxsCheckStmt } from "@modules/sema/components/switch.component";
import { hxsFindMember, hxsMemberOf } from "@modules/sema/components/aggregate.component";
import { HxInfoField, HxInfoDeref, HxSymLocal, HxMemberField } from "@constants/sema.constant";
import { hxsPushScope, hxsPopScope, hxsDeclareLocal } from "@modules/sema/components/scope.component";
import { astOf, nodeOf, typeOf, infoOf, types, tokenText, typeName } from "@modules/sema/components/base.component";
import { hxsSetSubset, errorNode, hint, hintf, hxsTokName, hxsCoerce } from "@modules/sema/components/base.component";

/**
 * Checks an unwrap `x!` of an optional.
 *
 * @param c - The checker context
 * @param node - The unwrap node, whose operand is `x`
 * @returns The type inside the optional, or 0 when the operand has no type or is not an optional
 *
 * @remarks
 * This file checks optionals and errors in expressions: `x!`, `x?.field`, `try`, `catch`, and `throw`.
 * An operand that is never null is an error with the hint to remove the `!`.
 *
 * @example
 * ```hx
 * // const p: ?i32 = 1;   p!
 * hxsCheckUnwrap(c, node); // the i32 type
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckUnwrap(c: *Ctx, node: u32): u32 {
    const t = hxsCheckExpr(c, nodeOf(c, node).a, 0);
    if (t == 0) return 0;
    if (typeOf(c, t).kind != TypeKind.Optional) {
        const diag = errorNode(c, node, `\`!\` unwraps an optional, but \`${typeName(c, t)}\` is never null`);
        hint(c, diag, "remove the `!`");
        return 0;
    }
    return typeOf(c, t).child;
}

/**
 * Checks an optional field read `x?.field`, which is null when `x` is null and the field otherwise.
 *
 * @param c - The checker context
 * @param node - The optional field node, whose operand is `x` and whose token names the field
 * @returns The optional type of the field, or 0 after an error
 *
 * @remarks
 * The operand must be an optional of a struct, of a pointer to a struct, or of a slice.
 * A pointer is followed to its struct, and the node is marked to read through it.
 * On a slice, only `len` is allowed, and it gives `?usize`.
 * A field that is already optional is not wrapped a second time.
 * The node records the field's index for code generation.
 *
 * @example
 * ```hx
 * // const p: ?Point = null;   p?.x
 * hxsCheckOptionalField(c, node); // the ?i32 type
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckOptionalField(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const base = hxsCheckExpr(c, n.a, 0);
    if (base == 0) return 0;
    const field = tokenText(c, n.token);
    const tys = types(c);
    if (typeOf(c, base).kind != TypeKind.Optional) {
        const diag = errorNode(c, node, `\`?.\` needs an optional, but \`${typeName(c, base)}\` is never null`);
        hintf(c, diag, `use \`.${field}\``);
        return 0;
    }
    let inner = typeOf(c, base).child;
    let deref = false;
    if (typeOf(c, inner).kind == TypeKind.Pointer && typeOf(c, typeOf(c, inner).child).kind == TypeKind.Struct) {
        inner = typeOf(c, inner).child;
        deref = true;
    }
    if (typeOf(c, inner).kind == TypeKind.Slice && field.len == 3 && field[0] == 'l' && field[1] == 'e' && field[2] == 'n') {
        return hxTypeOptional(tys, tys.usize);
    }
    if (typeOf(c, inner).kind != TypeKind.Struct) {
        void errorNode(c, node, `\`?.\` reads struct fields, and \`${typeName(c, inner)}\` is not a struct`);
        return 0;
    }
    const index = hxsFindMember(c, inner, hxsTokName(c, n.token));
    if (index < 0 || hxsMemberOf(c, inner, index).kind != HxMemberField as u8) {
        void errorNode(c, node, `\`${typeName(c, inner)}\` has no field \`${field}\``);
        return 0;
    }
    const m = hxsMemberOf(c, inner, index);
    infoOf(c, node).flags |= HxInfoField | (deref ? HxInfoDeref : 0);
    infoOf(c, node).aux = m.index;
    return typeOf(c, m.type).kind == TypeKind.Optional ? m.type : hxTypeOptional(tys, m.type);
}

/**
 * Checks a `try` expression, which passes an error on to the caller.
 *
 * @param c - The checker context
 * @param node - The `try` node, whose operand can fail
 * @returns The payload type of the operand, or the operand's own type when it cannot fail
 *
 * @remarks
 * The operand must be an error union.
 * The enclosing function must be able to fail, and its error set must hold every error of the operand.
 * A `try` inside a `defer` is an error, since a defer runs while the function is already returning.
 *
 * @example
 * ```hx
 * // function f(): i32 | Error { const x = try g(); return x; }
 * hxsCheckTry(c, node); // the i32 payload of g
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckTry(c: *Ctx, node: u32): u32 {
    const t = hxsCheckExpr(c, nodeOf(c, node).a, 0);
    if (t == 0) return 0;
    if (typeOf(c, t).kind != TypeKind.ErrorUnion) {
        const diag = errorNode(c, node, `\`try\` needs something that can fail, but \`${typeName(c, t)}\` can't`);
        hint(c, diag, "remove the `try`");
        return t;
    }
    const payload = typeOf(c, t).child;
    const set = @truncate(u32, typeOf(c, t).len);
    if (c.inDefer) {
        const diag = errorNode(c, node, "`try` can't be used inside a `defer`");
        hint(c, diag, "handle the error right there with `catch`");
    } else if (c.errorSet == 0) {
        const diag = errorNode(c, node, "`try` passes errors on, but this function can't fail");
        hint(c, diag, "add errors to the return type, e.g. `: void | Error`, or handle it here with `catch`");
    } else if (!hxsSetSubset(c, set, c.errorSet)) {
        const diag = errorNode(c, node, `errors from \`${typeName(c, set)}\` can't leave this function, which returns \`${typeName(c, c.errorSet)}\``);
        hint(c, diag, "add them to the function's error set, or handle them here with `catch`");
    }
    return payload;
}

/**
 * Checks a `catch` expression, which handles the error of an operand that can fail.
 *
 * @param c - The checker context
 * @param node - The `catch` node, whose operand can fail and whose record holds the capture and the body
 * @returns The payload type of the operand, or 0 when the operand cannot fail
 *
 * @remarks
 * The handler runs in its own scope, where the optional capture `(e)` is a local of the operand's error set.
 * A block handler must end in a `return`, `throw`, or panic when the operand has a payload that is not `void`.
 * Any other handler is an expression that gives the fallback value, checked against the payload type.
 *
 * @example
 * ```hx
 * // const x = g() catch 0;
 * hxsCheckCatch(c, node); // the i32 payload of g
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckCatch(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const data = record<HxCatchData>(astOf(c), n.b);
    let t = hxsCheckExpr(c, n.a, 0);
    const tys = types(c);
    let payload: u32 = 0;
    let set = tys.anyError;
    if (t != 0 && typeOf(c, t).kind != TypeKind.ErrorUnion) {
        const diag = errorNode(c, n.a, `\`catch\` needs something that can fail, but \`${typeName(c, t)}\` can't`);
        hint(c, diag, "remove the `catch`");
        t = 0;
    } else if (t != 0) {
        payload = typeOf(c, t).child;
        set = @truncate(u32, typeOf(c, t).len);
    }
    hxsPushScope(c);
    if (data.captureToken != NoToken) infoOf(c, node).symbol = hxsDeclareLocal(c, HxSymLocal, data.captureToken, node, set);
    if (nodeOf(c, data.body).kind == NodeKind.Block) {
        const ends = hxsCheckStmt(c, data.body);
        if (!ends && payload != 0 && payload != tys.voidType) {
            const diag = errorNode(c, node, "this `catch` block must return, throw or panic");
            hint(c, diag, "end it with `throw e;` or `return ...;`, or give a fallback value: `x catch fallback`");
        }
    } else {
        void hxsCheckExpr(c, data.body, payload != 0 && payload != tys.voidType ? payload : 0);
    }
    hxsPopScope(c);
    return payload;
}

/**
 * Checks a `throw` statement.
 *
 * @param c - The checker context
 * @param node - The `throw` node, whose operand is the error
 * @returns The `noreturn` type, since control never continues past a throw
 *
 * @remarks
 * The enclosing function must be able to fail, and a `throw` inside a `defer` is an error.
 * Against a specific error set, the value is checked as that set, which also checks that it holds the error.
 * Against `Error`, which holds every error, a value of any error set is accepted and then coerced to it.
 * A value that is not an error is reported with a hint to declare one with `error MyError { ... }`.
 *
 * @example
 * ```hx
 * // throw MyError.Bad;
 * hxsCheckThrow(c, node); // the noreturn type
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckThrow(c: *Ctx, node: u32): u32 {
    const value = nodeOf(c, node).a;
    const tys = types(c);
    if (c.inDefer) {
        const diag = errorNode(c, node, "`throw` can't be used inside a `defer`");
        hint(c, diag, "a defer runs while the function is already returning");
    }
    if (c.errorSet == 0) {
        const diag = errorNode(c, node, "`throw` needs a function that can fail");
        hint(c, diag, "add errors to the return type, e.g. `: void | Error`");
        void hxsCheckExpr(c, value, 0);
        return tys.noreturnType;
    }
    const any = (typeOf(c, c.errorSet).flags & AnyError) != 0;
    const t = hxsCheckExpr(c, value, any ? 0 : c.errorSet);   // a specific set also checks membership
    if (t != 0 && typeOf(c, t).kind != TypeKind.ErrorSet) {
        const diag = errorNode(c, value, `\`throw\` needs an error, found \`${typeName(c, t)}\``);
        hint(c, diag, "declare errors with `error MyError { ... }` and throw `MyError.Case`");
    } else if (t != 0 && any) {
        void hxsCoerce(c, value, c.errorSet);
    }
    return tys.noreturnType;
}
