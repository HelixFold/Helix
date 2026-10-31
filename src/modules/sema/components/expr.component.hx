/**
 * Imports
 */

import { record } from "@models/ast.model";
import { TypeKind } from "@constants/types.constant";
import { hxTypeFunction } from "@models/types.model";
import { hxVecGrowImpl } from "@components/memory.component";
import { Ctx, HxEvalHost, FnState } from "@structs/sema.struct";
import { hxsCheckIdent } from "@modules/sema/components/call.component";
import { hxsCheckField } from "@modules/sema/components/access.component";
import { HxTernaryData, HxFnData } from "@models/structs/ast-model.struct";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { hxEvalExpr, hxEvalBlock } from "@modules/sema/services/eval.service";
import { hxsCheckBuiltin } from "@modules/sema/components/builtins.component";
import { hxsCollectNarrowing } from "@modules/sema/components/stmt.component";
import { NodeKind, FlagComptime, FlagVariadic } from "@constants/ast.constant";
import { hxsCheckFunctionBody } from "@modules/sema/components/decl.component";
import { hxsCheckTemplateParts } from "@modules/sema/components/print.component";
import { hxsCheckStmt, hxsCheckSwitch } from "@modules/sema/components/switch.component";
import { hxsCheckOptionalField, hxsCheckTry } from "@modules/sema/components/errors.component";
import { hxsAddSymbol, hxsPushScope, hxsPopScope } from "@modules/sema/components/scope.component";
import { HxSymChecking, HxValueUndefined, HxSymArrow, HxSymFailed } from "@constants/sema.constant";
import { hxsCheckFloatLiteral, hxsCheckCharLiteral } from "@modules/sema/components/scope.component";
import { hxsCheckArrayLiteral, hxsCheckEnumLiteral } from "@modules/sema/components/access.component";
import { hxsFormatEscapes, hxsUnsupported, emptyValue } from "@modules/sema/components/base.component";
import { hxsCheckCatch, hxsCheckThrow, hxsCheckUnwrap } from "@modules/sema/components/errors.component";
import { hxsSaveState, hxsRestoreState, hxsRuntimeType } from "@modules/sema/components/generics.component";
import { HxSymUsed, HxSymParam, HxValueNull, HxValueFunction, HxSymFunction } from "@constants/sema.constant";
import { hxsCheckStructLiteral, hxsCheckIndex, hxsCheckSlice } from "@modules/sema/components/access.component";
import { hxsValueOf, hxsAddValue, hxsBoolValue, hxsCoerce, types } from "@modules/sema/components/base.component";
import { hxsCheckCast, hxsCheckCall, hxsCheckBinary, hxsCheckUnary } from "@modules/sema/components/ops.component";
import { tokenText, typeName, errorNode, errorToken, hint, semaOf } from "@modules/sema/components/base.component";
import { astOf, nodeOf, typeOf, symbolOf, infoOf, extraOf, hxsPeer } from "@modules/sema/components/base.component";
import { hxsCheckStringLiteral, hxsDeclareLocal, hxsCheckIntLiteral } from "@modules/sema/components/scope.component";

/**
 * Checks a ternary `cond ? a : b`.
 *
 * @param c - The checker context
 * @param node - The ternary node
 * @param expected - The type that the context wants, or 0 when it wants none
 * @returns The expected type when there is one, otherwise the common type of both branches
 *
 * @remarks
 * The condition must be a `bool`.
 * Each branch sees what the condition proves on its side, so `p != null ? p.x : 0` reads `p` as not null.
 * With a condition known at compile time,
 * the ternary takes the constant value of the branch that it picks when that branch has one.
 *
 * @example
 * ```hx
 * // const n = ok ? 1 : 2;
 * hxsCheckTernary(c, node, 0); // the common type of `1` and `2`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckTernary(c: *Ctx, node: u32, expected: u32): u32 {
    const n = nodeOf(c, node);
    const data = record<HxTernaryData>(astOf(c), n.b);
    void hxsCheckExpr(c, n.a, types(c).boolType);
    const mark = c.narrowed.len;
    hxsCollectNarrowing(c, n.a, true);
    void hxsCheckExpr(c, data.thenValue, expected);
    c.narrowed.len = mark;
    hxsCollectNarrowing(c, n.a, false);
    void hxsCheckExpr(c, data.elseValue, expected);
    c.narrowed.len = mark;
    if (expected != 0) return expected;
    const common = hxsPeer(c, data.thenValue, data.elseValue, node);
    if (const cond = hxsValueOf(c, n.a)) {
        if (hxsValueOf(c, cond.boolean ? data.thenValue : data.elseValue) != null) {
            infoOf(c, node).value = infoOf(c, cond.boolean ? data.thenValue : data.elseValue).value;
        }
    }
    return common;
}

/**
 * Appends a function symbol to the list of the functions in the program.
 *
 * @param c - The checker context
 * @param sym - The symbol of the function
 *
 * @remarks
 * The arrow function checker calls it only after the body checks without an error.
 * The later passes walk the list by index while it grows, so appending during a pass is safe.
 *
 * @since 1.0.0
 */

function pushFunction(c: *Ctx, sym: u32): void {
    const list = &semaOf(c).functions;
    unsafe {
        if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, 4);
        list.items![list.len] = sym;
    }
    list.len += 1;
}

/**
 * Checks an arrow function such as `(a: i32, b: i32): bool => a < b`, an anonymous function checked where it is
 * written.
 *
 * @param c - The checker context
 * @param node - The arrow function node
 * @returns The function type, or 0 when the parameters or the return type do not resolve
 *
 * @remarks
 * The body sees the globals but not the locals of the enclosing function.
 * Without a return type, an expression body gives the result type,
 * and a body whose type is `null`, `undefined`, or a template string is an error.
 * A block body with a return type must return on every path.
 * Arrow functions cannot be variadic, and their parameters cannot be `comptime` or `void`.
 * Inside a generic instance the function belongs to that instance.
 * An arrow function that checks without errors becomes a constant function value,
 * and the node keeps it, so checking the same node again returns the same type at once.
 *
 * @example
 * ```hx
 * // const less = (a: i32, b: i32) => a < b;
 * hxsCheckArrow(c, node); // the type of `(i32, i32): bool`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckArrow(c: *Ctx, node: u32): u32 {
    if (infoOf(c, node).value != 0) return infoOf(c, node).type;
    const n = nodeOf(c, node);
    const fn = record<HxFnData>(astOf(c), n.a);
    const tys = types(c);
    if ((n.flags & FlagVariadic) != 0) void errorNode(c, node, "an arrow function can't be variadic");

    const sym = hxsAddSymbol(c, HxSymFunction, n.token, node, 0);
    symbolOf(c, sym).flags |= (HxSymUsed | HxSymArrow) as u16;
    symbolOf(c, sym).module = c.module;
    symbolOf(c, sym).instance = c.instance;   // inside a generic instance, its body belongs to the instance too

    let params: u32[256] = undefined;
    let count: u32 = 0;
    let ok = true;
    for (const i of fn.paramsStart..fn.paramsEnd) {
        if (count >= 256) break;
        const p = extraOf(c, i);
        if ((nodeOf(c, p).flags & FlagComptime) != 0) hxsUnsupported(c, p, "`comptime` parameters");
        const t = hxsResolveType(c, nodeOf(c, p).a);
        if (t == 0) ok = false;
        if (t == tys.voidType) {
            void errorNode(c, nodeOf(c, p).a, "a parameter can't be `void`");
            ok = false;
        }
        infoOf(c, p).type = t;
        params[count] = t;
        count += 1;
    }
    const isBlock = nodeOf(c, fn.body).kind == NodeKind.Block;
    const inferResult = fn.returnType == 0 && !isBlock;
    let ret = inferResult ? 0 : hxsResolveType(c, fn.returnType);
    if (fn.returnType != 0 && ret == 0) ok = false;
    if (hxsFormatEscapes(c, ret, fn.returnType)) ok = false;
    if (ok && !inferResult) symbolOf(c, sym).type = hxTypeFunction(tys, ret, &params, count, false);

    let saved: FnState = undefined;
    hxsSaveState(c, &saved);
    const errorsBefore = semaOf(c).diags!.errorCount;
    c.scopeBase = c.scope.len;
    c.globalsOnly = false;
    const fallible = ret != 0 && typeOf(c, ret).kind == TypeKind.ErrorUnion;
    c.returnType = ret;
    c.errorSet = fallible ? @truncate(u32, typeOf(c, ret).len) : 0;
    c.functionSymbol = sym;
    c.loopCount = 0;
    c.inDefer = false;
    c.deferFloor = 0xFFFF_FFFF;
    c.unsafeDepth = 0;

    hxsPushScope(c);
    for (const i of fn.paramsStart..fn.paramsEnd) {
        const p = extraOf(c, i);
        infoOf(c, p).symbol = hxsDeclareLocal(c, HxSymParam, nodeOf(c, p).token, p, infoOf(c, p).type);
    }
    if (isBlock) {
        const terminated = hxsCheckStmt(c, fn.body);
        const payload = fallible ? typeOf(c, ret).child : ret;
        if (!terminated && ret != 0 && payload != tys.voidType) {
            const diag = errorNode(c, node, `this arrow function can reach its end without returning a \`${typeName(c, payload)}\``);
            hint(c, diag, "add a `return` on every path");
        }
    } else if (inferResult) {
        const t = hxsCheckExpr(c, fn.body, 0);
        if (t != 0) {
            ret = hxsRuntimeType(c, t);
            if (typeOf(c, ret).kind == TypeKind.Null || typeOf(c, ret).kind == TypeKind.Undefined || ret == tys.format) {
                void errorNode(c, fn.body, "can't tell what type this arrow function returns");
                ret = 0;
            } else {
                void hxsCoerce(c, fn.body, ret);
            }
        }
        if (ok && ret != 0) symbolOf(c, sym).type = hxTypeFunction(tys, ret, &params, count, false);
    } else {
        void hxsCheckExpr(c, fn.body, ret);
        if (ret != 0) void hxsCoerce(c, fn.body, ret);
    }
    hxsPopScope(c);
    hxsRestoreState(c, &saved);

    if (symbolOf(c, sym).type == 0 || semaOf(c).diags!.errorCount != errorsBefore) return symbolOf(c, sym).type;
    pushFunction(c, sym);
    let v = emptyValue(HxValueFunction as u8);
    v.integer = sym as i128;
    infoOf(c, node).value = hxsAddValue(c, v);
    infoOf(c, node).symbol = sym;
    return symbolOf(c, sym).type;
}

/**
 * Makes sure that a function has a checked body before the interpreter runs it at compile time.
 *
 * @param user - The checker context, as the interpreter passes it back
 * @param sym - The symbol of the function to run
 * @returns `true` when the function checked without errors and can run
 *
 * @remarks
 * The interpreter calls this hook for each function that compile-time code calls.
 * An arrow function was already checked where it was written.
 * A function still being checked cannot run, so `comptime` code that calls the function around it is an error.
 *
 * @example
 * ```hx
 * // comptime square(4)
 * hxsEnsureBody(user, square); // true, after checking the body of square
 * ```
 *
 * @see hxsEvalHost
 * @since 1.0.0
 */

export extern "C" function hxsEnsureBody(user: ?u8[*], sym: u32): bool {
    let c: *Ctx = undefined;
    unsafe {
        c = @ptrCast(*Ctx, user!);
    }
    if ((symbolOf(c, sym).flags & (HxSymArrow as u16)) != 0) return true;   // checked where it was written
    if ((symbolOf(c, sym).flags & (HxSymChecking as u16)) != 0) {
        const diag = errorToken(c, symbolOf(c, sym).token, `\`${tokenText(c, symbolOf(c, sym).token)}\` runs at compile time while it's still being checked`);
        hint(c, diag, "a function can't use `comptime` to call itself");
        return false;
    }
    hxsCheckFunctionBody(c, sym);
    return symbolOf(c, sym).type != 0 && (symbolOf(c, sym).flags & (HxSymFailed as u16)) == 0;
}

/**
 * Builds the host that the compile-time interpreter uses to reach the checker.
 *
 * @param c - The checker context
 * @returns The host, holding the checker state, the {@link hxsEnsureBody} hook, and the context as its user data
 *
 * @remarks
 * The interpreter calls back through {@link hxsEnsureBody} to check a function body before it runs it,
 * so `comptime` code can call a function declared further down.
 * The host holds a pointer to the context, so it must not outlive it.
 *
 * @example
 * ```hx
 * let host = hxsEvalHost(c);
 * hxEvalExpr(&host, node, c.instance); // the value of node
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsEvalHost(c: *Ctx): HxEvalHost {
    unsafe {
        return HxEvalHost { sema: c.sema, ensureBody: hxsEnsureBody, user: @ptrCast(?u8[*], c) };
    }
}

/**
 * Checks `comptime f(x)`, then runs it at once, so that its value replaces it in the program.
 *
 * @param c - The checker context
 * @param node - The `comptime` expression node
 * @param expected - The type that the context wants, or 0 when it wants none
 * @returns The type of the operand
 *
 * @remarks
 * The operand is checked like any expression, and nothing runs when that gives an error.
 * An operand that is already a constant keeps its value without running.
 *
 * @example
 * ```hx
 * // const n = comptime square(4);
 * hxsCheckComptimeExpr(c, node, 0); // n is the constant 16
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckComptimeExpr(c: *Ctx, node: u32, expected: u32): u32 {
    const operand = nodeOf(c, node).a;
    const errors = semaOf(c).diags!.errorCount;
    c.comptimeDepth += 1;
    const type = hxsCheckExpr(c, operand, expected);
    c.comptimeDepth -= 1;
    if (type == 0 || semaOf(c).diags!.errorCount != errors) return type;
    if (hxsValueOf(c, operand) != null) {   // already a constant
        infoOf(c, node).value = infoOf(c, operand).value;
        return type;
    }
    let host = hxsEvalHost(c);
    const v = hxEvalExpr(&host, operand, c.instance);
    if (v != 0 && v != 0xFFFF_FFFF) infoOf(c, node).value = v;
    return type;
}

/**
 * Checks a `comptime { ... }` block in its own scope, then runs it.
 *
 * @param c - The checker context
 * @param node - The `comptime` block node
 *
 * @remarks
 * The block does not run when checking it gives an error.
 *
 * @example
 * ```hx
 * // comptime { assert(SIZE > 0); }
 * hxsCheckComptimeBlock(c, node); // checks the block, then runs the assert
 * ```
 *
 * @see hxsRunComptimeBlock
 * @since 1.0.0
 */

export extern "C" function hxsCheckComptimeBlock(c: *Ctx, node: u32): void {
    const errors = semaOf(c).diags!.errorCount;
    c.comptimeDepth += 1;
    hxsPushScope(c);
    void hxsCheckStmt(c, nodeOf(c, node).a);
    hxsPopScope(c);
    c.comptimeDepth -= 1;
    if (semaOf(c).diags!.errorCount != errors) return;
    let host = hxsEvalHost(c);
    void hxEvalBlock(&host, nodeOf(c, node).a, c.instance);
}

/**
 * Checks and runs a top-level `comptime { }` block, once every function has been checked.
 *
 * @param c - The checker context
 * @param node - The `comptime` block node
 * @param module - The module that holds the block
 *
 * @remarks
 * The block is checked like the body of a function without parameters that returns `void`,
 * and the state of the checker is restored afterwards.
 *
 * @example
 * ```hx
 * // comptime { assert(@sizeOf(Header) == 16); }   at the top level
 * hxsRunComptimeBlock(c, decl, 0); // fails the build when the assert fails
 * ```
 *
 * @see hxsCheckComptimeBlock
 * @since 1.0.0
 */

export extern "C" function hxsRunComptimeBlock(c: *Ctx, node: u32, module: u32): void {
    let saved: FnState = undefined;
    hxsSaveState(c, &saved);
    c.instance = 0;
    c.typeParams.len = 0;
    c.scopeBase = c.scope.len;
    c.globalsOnly = false;
    c.module = module;
    c.returnType = types(c).voidType;
    c.errorSet = 0;
    c.functionSymbol = 0;
    c.loopCount = 0;
    c.inDefer = false;
    c.deferFloor = 0xFFFF_FFFF;
    c.unsafeDepth = 0;
    hxsCheckComptimeBlock(c, node);
    hxsRestoreState(c, &saved);
}

/**
 * Gives the type of an expression, passing each kind of node to the check for that kind.
 *
 * @param c - The checker context
 * @param node - The expression node
 * @param expected - The type that the context wants, or 0 when it wants none
 * @returns The type of the expression, or 0 after an error
 *
 * @remarks
 * The expected type only guides the checks that need it, such as literals of structs, enums, and arrays.
 * The result is not converted to it, which {@link hxsCheckExpr} does.
 * The literals `true`, `false`, `null`, and `undefined` get their constant values here.
 * A `return`, `break`, or `continue` in an expression, as in `x ?? return 0`, is checked as a statement
 * and has the type `noreturn`.
 * A template string is only a value where a `Format` parameter takes it,
 * and a type, a generic instance, or `import()` where a value belongs is an error.
 *
 * @example
 * ```hx
 * // 1 < 2
 * hxsInfer(c, node, 0); // bool
 * ```
 *
 * @see hxsCheckExpr
 * @since 1.0.0
 */

export extern "C" function hxsInfer(c: *Ctx, node: u32, expected: u32): u32 {
    const n = nodeOf(c, node);
    const tys = types(c);
    switch (n.kind) {
        case NodeKind.Ident: return hxsCheckIdent(c, node);
        case NodeKind.Int: return hxsCheckIntLiteral(c, node);
        case NodeKind.Float: return hxsCheckFloatLiteral(c, node);
        case NodeKind.Char: return hxsCheckCharLiteral(c, node);
        case NodeKind.String: return hxsCheckStringLiteral(c, node);
        case NodeKind.True, NodeKind.False: {
            infoOf(c, node).value = hxsBoolValue(c, n.kind == NodeKind.True);
            return tys.boolType;
        }
        case NodeKind.Undefined: {
            infoOf(c, node).value = hxsAddValue(c, emptyValue(HxValueUndefined as u8));
            return tys.undefinedType;
        }
        case NodeKind.Unreachable: return tys.noreturnType;
        case NodeKind.Binary: return hxsCheckBinary(c, node);
        case NodeKind.Negate, NodeKind.Not, NodeKind.BitNot, NodeKind.AddressOf, NodeKind.Deref, NodeKind.Discard: return hxsCheckUnary(c, node);
        case NodeKind.Call: return hxsCheckCall(c, node, expected);
        case NodeKind.Cast: return hxsCheckCast(c, node);
        case NodeKind.Index: return hxsCheckIndex(c, node);
        case NodeKind.Slice: return hxsCheckSlice(c, node);
        case NodeKind.FieldAccess: return hxsCheckField(c, node);
        case NodeKind.BuiltinCall: return hxsCheckBuiltin(c, node);
        case NodeKind.Ternary: return hxsCheckTernary(c, node, expected);
        case NodeKind.Null: {
            infoOf(c, node).value = hxsAddValue(c, emptyValue(HxValueNull as u8));
            return tys.nullType;
        }
        case NodeKind.StructLiteral: return hxsCheckStructLiteral(c, node, expected);
        case NodeKind.EnumLiteral: return hxsCheckEnumLiteral(c, node, expected);
        case NodeKind.Unwrap: return hxsCheckUnwrap(c, node);
        case NodeKind.OptionalField: return hxsCheckOptionalField(c, node);
        case NodeKind.Try: return hxsCheckTry(c, node);
        case NodeKind.Catch: return hxsCheckCatch(c, node);
        case NodeKind.Throw: return hxsCheckThrow(c, node);
        case NodeKind.Return, NodeKind.Break, NodeKind.Continue: {   // `x ?? return 0`: the statement, as a value that never comes
            void hxsCheckStmt(c, node);
            return types(c).noreturnType;
        }
        case NodeKind.Switch: return hxsCheckSwitch(c, node, expected, true);
        case NodeKind.Template: {
            hxsCheckTemplateParts(c, node);
            if (expected == tys.format) return tys.format;
            const diag = errorNode(c, node, "a template string can only be passed to a `Format` parameter");
            hint(c, diag, "print it with `println(...)`, or build a string with `fmt.alloc(a, ...)` from \"std/fmt\"");
            return 0;
        }
        case NodeKind.ArrayLiteral: return hxsCheckArrayLiteral(c, node, expected);
        case NodeKind.ArrowFunction: return hxsCheckArrow(c, node);
        case NodeKind.GenericInstance: {
            void errorNode(c, node, "a generic type is not a value");
            return 0;
        }
        case NodeKind.ImportExpr: {
            hxsUnsupported(c, node, "`import()`");
            return 0;
        }
        case NodeKind.ComptimeExpr: return hxsCheckComptimeExpr(c, node, expected);
        case NodeKind.Invalid: return 0;
        default: {
            void errorNode(c, node, "expected a value, found a type");
            return 0;
        }
    }
}

/**
 * Checks an expression and converts it to the type that the context wants.
 *
 * @param c - The checker context
 * @param node - The expression node
 * @param expected - The type that the context wants, or 0 when it wants none
 * @returns The expected type when there is one and the expression checks, otherwise the type of the expression
 *
 * @remarks
 * The type of the expression itself is recorded on the node, before any conversion.
 * A failed conversion reports an error at the node.
 *
 * @example
 * ```hx
 * // const x: i64 = 1;
 * hxsCheckExpr(c, value, i64); // i64, from an integer literal
 * ```
 *
 * @see hxsInfer
 * @since 1.0.0
 */

export extern "C" function hxsCheckExpr(c: *Ctx, node: u32, expected: u32): u32 {
    const type = hxsInfer(c, node, expected);
    infoOf(c, node).type = type;
    if (expected != 0 && type != 0) {
        void hxsCoerce(c, node, expected);
        return expected;
    }
    return type;
}
