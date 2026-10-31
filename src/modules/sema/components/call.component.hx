/**
 * Imports
 */

import { record } from "@models/ast.model";
import { NodeKind } from "@constants/ast.constant";
import { Ctx, HxMember } from "@structs/sema.struct";
import { HxMemberField } from "@constants/sema.constant";
import { HxRange, HxFnData } from "@models/structs/ast-model.struct";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { TypeKind, Readonly, Variadic } from "@constants/types.constant";
import { hxsIndirectCall } from "@modules/sema/components/print.component";
import { hxsResolveGlobal } from "@modules/sema/components/decl.component";
import { hxsLookup, u32At } from "@modules/sema/components/scope.component";
import { hxsModuleMember } from "@modules/sema/components/imports.component";
import { hxsCheckFunctionCall } from "@modules/sema/components/ops.component";
import { noteRead, noteWrite } from "@modules/sema/components/unset.component";
import { hxsGenericCallInstance } from "@modules/sema/components/generics.component";
import { hxsCoerce, hxsAggregateOf, hxsIsAggregate } from "@modules/sema/components/base.component";
import { hxsInstantiateTypeNode, hxsMethodInstance } from "@modules/sema/components/generics.component";
import { HxSymArrow, HxInfoNarrowed, HxValueFunction, HxMemberSignature } from "@constants/sema.constant";
import { HxSymExtern, HxSymMutated, HxSymUsed, HxInfoDyn, HxInfoReceiverAddr } from "@constants/sema.constant";
import { hxsResolveAggregate, hxsFindMember, hxsMemberOf } from "@modules/sema/components/aggregate.component";
import { HxMemberMethod, HxInfoModuleRef, HxSymLocal, HxSymParam, HxInfoMethod } from "@constants/sema.constant";
import { HxSymType, HxInfoDeref, HxSymGeneric, HxInfoFormatWrite, HxSymFunction } from "@constants/sema.constant";
import { paramOf, tokenText, typeName, errorNode, hint, hxsIntFits } from "@modules/sema/components/base.component";
import { nodeOf, typeOf, symbolOf, infoOf, extraOf, types, memberAt } from "@modules/sema/components/base.component";
import { hxTypeFunction, hxTypeBuiltin, hxTypeFunctionC, hxTypePointer, hxTypeErrorUnion } from "@models/types.model";
import { HxSymMutable, HxSymGlobal, HxInfoUnionInit, HxSymTemplateMethod, HxInfoField } from "@constants/sema.constant";
import { emptyValue, hintf, hxsTokName, hxsValueOf, hxsAddValue, astOf } from "@modules/sema/components/base.component";

/**
 * Views a pointer and a length from a C-style call as a string.
 *
 * @param text - The first byte of the text
 * @param len - The length of the text in bytes
 * @returns The text as a slice that shares the bytes
 *
 * @remarks
 * Slices without a copy, so the result lives only as long as the bytes behind the pointer.
 * The length converts from `i32` to `usize` without a check, so the caller passes a length that is not negative.
 *
 * @since 1.0.0
 */

function textOf(text: readonly u8[*], len: i32): string {
    unsafe {
        return text[0..len as usize];
    }
}

/**
 * Marks a symbol as used, so the checker does not report it as unused.
 *
 * @param c - The checker context
 * @param sym - The symbol to mark
 *
 * @remarks
 * Sets a flag on the symbol and does nothing else, so marking a symbol twice is harmless.
 * Call it wherever code reads a name, since the checker reports a local whose flag stays clear as unused.
 *
 * @example
 * ```hx
 * hxsMarkUsed(c, sym); // sym is no longer reported as unused
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsMarkUsed(c: *Ctx, sym: u32): void {
    symbolOf(c, sym).flags |= HxSymUsed as u16;
}

/**
 * Finds the variable that a place expression belongs to.
 *
 * @param c - The checker context
 * @param node - The place, such as `x`, `x[i]`, `x.field`, or `x.a[i].b`
 * @returns The symbol of the variable, or 0 when the place does not belong to one
 *
 * @remarks
 * Indexing follows only arrays, and a field access follows only a field read in place.
 * Indexing a slice or a pointer, or reaching a field through a pointer, leaves the variable and gives 0.
 *
 * @example
 * ```hx
 * // let p: Point = undefined; p.x = 1;
 * hxsPlaceRoot(c, target); // the symbol of p
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsPlaceRoot(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    if (n.kind == NodeKind.Ident) return infoOf(c, node).symbol;
    if (n.kind == NodeKind.Index && typeOf(c, infoOf(c, n.a).type).kind == TypeKind.Array) return hxsPlaceRoot(c, n.a);
    if (n.kind == NodeKind.FieldAccess && (infoOf(c, node).flags & HxInfoField) != 0 && (infoOf(c, node).flags & HxInfoDeref) == 0) {
        return hxsPlaceRoot(c, n.a);
    }
    return 0;
}

/**
 * Checks that a write through a pointer does not go through a readonly one.
 *
 * @param c - The checker context
 * @param node - The place to report on
 * @param ptr - The type of the pointer that the write goes through
 * @param report - Whether to report an error when the pointer is readonly
 * @returns `true` when the pointer allows the write
 *
 * @remarks
 * Looks only at the readonly flag of the pointer type,
 * so the caller has already found the pointer that the write goes through.
 * Dereferences and fields reached through a pointer use it.
 *
 * @since 1.0.0
 */

function throughReadonly(c: *Ctx, node: u32, ptr: u32, report: bool): bool {
    if ((typeOf(c, ptr).flags & Readonly) == 0) return true;
    if (report) void errorNode(c, node, `can't assign through a \`${typeName(c, ptr)}\``);
    return false;
}

/**
 * Checks whether a place can be written.
 *
 * @param c - The checker context
 * @param node - The place
 * @param report - Whether to report an error that explains why the place cannot be written
 * @returns `true` when the place can be written
 *
 * @remarks
 * A name can be written when it is a `let` local or a `let` global.
 * A parameter or a constant draws an error with a hint, and a name that already failed to resolve passes.
 * A dereference and a field reached through a pointer need a pointer that is not readonly.
 * An element of an array follows the array, while an element of a slice or a pointer needs one that is not readonly,
 * and a string literal is never writable.
 * A field of a value follows the value, and `ns.count` needs another module's `let` global.
 * Anything else, such as a call or a literal, cannot be written.
 *
 * @example
 * ```hx
 * // const n: i32 = 1; n = 2;
 * hxsIsMutablePlace(c, target, true); // false, error: `n` is a constant
 * ```
 *
 * @see hxsCheckPlace
 * @since 1.0.0
 */

export extern "C" function hxsIsMutablePlace(c: *Ctx, node: u32, report: bool): bool {
    const n = nodeOf(c, node);
    switch (n.kind) {
        case NodeKind.Ident: {
            const sym = infoOf(c, node).symbol;
            if (sym == 0) return true;   // already reported
            const s = symbolOf(c, sym);
            if ((s.kind == HxSymLocal as u8 || s.kind == HxSymGlobal as u8) && (s.flags & (HxSymMutable as u16)) != 0) return true;
            if (report) {
                const name = tokenText(c, n.token);
                if (s.kind == HxSymParam as u8) {
                    const diag = errorNode(c, node, `parameter \`${name}\` can't be assigned`);
                    hintf(c, diag, `parameters are immutable; copy it into a local: \`let my${name} = ${name};\``);
                } else {
                    const diag = errorNode(c, node, `\`${name}\` is a constant`);
                    hint(c, diag, "declare it with `let` to make it mutable");
                }
            }
            return false;
        }
        case NodeKind.Deref: return throughReadonly(c, node, infoOf(c, n.a).type, report);
        case NodeKind.Index: {
            const base = infoOf(c, n.a).type;
            const b = typeOf(c, base);
            if (b.kind == TypeKind.Array) return hxsIsMutablePlace(c, n.a, report);
            if (b.kind == TypeKind.StringLiteral || (b.flags & Readonly) != 0) {
                if (report) void errorNode(c, node, `can't assign through a \`${typeName(c, base)}\``);
                return false;
            }
            return true;
        }
        case NodeKind.FieldAccess: {
            const flags = infoOf(c, node).flags;
            if ((flags & HxInfoModuleRef) != 0) {   // `ns.count = 1`: another module's global, if it's a `let`
                const sym = infoOf(c, node).symbol;
                if (sym != 0 && symbolOf(c, sym).kind == HxSymGlobal as u8 && (symbolOf(c, sym).flags & (HxSymMutable as u16)) != 0) return true;
                if (report) void errorNode(c, node, `\`${tokenText(c, n.token)}\` is a constant`);
                return false;
            }
            if ((flags & HxInfoField) == 0) {
                if (report) void errorNode(c, node, "this can't be assigned to");
                return false;
            }
            if ((flags & HxInfoDeref) != 0) return throughReadonly(c, node, infoOf(c, n.a).type, report);
            return hxsIsMutablePlace(c, n.a, report);
        }
        default: {
            if (report) void errorNode(c, node, "this expression can't be assigned to");
            return false;
        }
    }
}

/**
 * Checks the target of an assignment and marks its variable as changed.
 *
 * @param c - The checker context
 * @param node - The place being assigned
 *
 * @remarks
 * A place without a type already drew an error and is skipped.
 * When the place can be written, its variable is marked as mutated,
 * which the check for a `let` that could be a `const` reads.
 *
 * @example
 * ```hx
 * // let n: i32 = 1; n = 2;
 * hxsCheckPlace(c, target); // n is marked as mutated
 * ```
 *
 * @see hxsIsMutablePlace
 * @since 1.0.0
 */

export extern "C" function hxsCheckPlace(c: *Ctx, node: u32): void {
    if (infoOf(c, node).type == 0) return;
    if (!hxsIsMutablePlace(c, node, true)) return;
    const root = hxsPlaceRoot(c, node);
    if (root != 0) symbolOf(c, root).flags |= HxSymMutated as u16;
}

/**
 * Checks whether a name is a local of a function that encloses the current arrow function.
 *
 * @param c - The checker context
 * @param name - The interned name
 * @returns `true` when the name is such a local, which the arrow function cannot reach
 *
 * @remarks
 * Only the scopes below the arrow function's own base are searched, which belong to the enclosing functions.
 * The local is marked as used, so the capture is the only error reported about it.
 * Outside an arrow function, the result is always `false`.
 *
 * @example
 * ```hx
 * // function f(n: i32): void { const g = (): i32 => n; }
 * hxsOuterLocal(c, name); // true for n
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsOuterLocal(c: *Ctx, name: u32): bool {
    if (c.functionSymbol == 0 || (symbolOf(c, c.functionSymbol).flags & (HxSymArrow as u16)) == 0) return false;
    let i = c.scopeBase;
    while (i > 0) {
        const sym = u32At(&c.scope, i - 1);
        i -= 1;
        if (symbolOf(c, sym).name != name) continue;
        hxsMarkUsed(c, sym);
        return true;
    }
    return false;
}

/**
 * Checks a name used as a value and finds what it refers to.
 *
 * @param c - The checker context
 * @param node - The identifier node
 * @returns The type of the value, or 0 after an error
 *
 * @remarks
 * A name that is not in scope draws one of three errors.
 * A built-in type name such as `i32` is a type, not a value.
 * A local of a function around the current arrow function cannot be captured,
 * since capturing would need a hidden allocation.
 * Any other name is unknown.
 *
 * @example
 * ```hx
 * // const a = 1; const b = a;
 * hxsCheckIdent(c, node); // the type of a
 * ```
 *
 * @see hxsCheckSymbolValue
 * @since 1.0.0
 */

export extern "C" function hxsCheckIdent(c: *Ctx, node: u32): u32 {
    const text = tokenText(c, nodeOf(c, node).token);
    const sym = hxsLookup(c, hxsTokName(c, nodeOf(c, node).token));
    if (sym == 0) {
        if (hxTypeBuiltin(types(c), text.ptr, @truncate(u32, text.len)) != 0) {
            void errorNode(c, node, `\`${text}\` is a type, not a value`);
        } else if (hxsOuterLocal(c, hxsTokName(c, nodeOf(c, node).token))) {
            const diag = errorNode(c, node, `an arrow function can't capture \`${text}\``);
            hint(c, diag, "pass it as a parameter; capturing would need a hidden allocation");
        } else {
            void errorNode(c, node, `unknown name \`${text}\``);
        }
        return 0;
    }
    return hxsCheckSymbolValue(c, node, sym, text.ptr, text.len as i32);
}

/**
 * Checks a function used as a value, like `isEven` in `filter(xs, isEven)`.
 *
 * @param c - The checker context
 * @param node - The node that names the function
 * @param sym - The symbol of the function
 * @param textPtr - The first byte of the name as written
 * @param len - The length of the name in bytes
 * @returns The function type, or 0 for a generic function or one without a type
 *
 * @remarks
 * The node becomes a constant that names the function.
 * A generic function has no single address, so it draws an error with a hint to wrap the wanted instance.
 * An `extern "C"` function gives a C function pointer type,
 * so a call through the value uses the C calling convention.
 *
 * @example
 * ```hx
 * // function isEven(n: i32): bool { ... }  filter(xs, isEven);
 * hxsFunctionValue(c, node, sym, "isEven", 6); // (i32) => bool
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsFunctionValue(c: *Ctx, node: u32, sym: u32, textPtr: readonly u8[*], len: i32): u32 {
    const text = textOf(textPtr, len);
    if ((symbolOf(c, sym).flags & (HxSymGeneric as u16)) != 0) {
        const diag = errorNode(c, node, `\`${text}\` is generic, so it can't be used as a value on its own`);
        hintf(c, diag, `wrap the instance you want: \`(a: i32, b: i32): i32 => ${text}(a, b)\``);
        return 0;
    }
    infoOf(c, node).symbol = sym;
    if (symbolOf(c, sym).type == 0) return 0;
    let v = emptyValue(HxValueFunction as u8);
    v.integer = sym as i128;
    infoOf(c, node).value = hxsAddValue(c, v);
    // a C function's address is a C function pointer: called through, it uses the C calling convention
    if ((symbolOf(c, sym).flags & (HxSymExtern as u16)) != 0) return hxTypeFunctionC(types(c), symbolOf(c, sym).type, true);
    return symbolOf(c, sym).type;
}

/**
 * Checks a symbol used as a value, through `name` or `ns.name`.
 *
 * @param c - The checker context
 * @param node - The node that names the symbol
 * @param sym - The symbol
 * @param textPtr - The first byte of the name as written
 * @param len - The length of the name in bytes
 * @returns The type of the value, or 0 after an error
 *
 * @remarks
 * The symbol is marked as used and recorded on the node.
 * A module or a type is not a value and draws an error, and a function goes to {@link hxsFunctionValue}.
 * A global is resolved first, so its type and constant value are known.
 * A read of a local is recorded for the check of locals without a value.
 * An optional local that an enclosing `x != null` check narrowed reads as its payload type.
 *
 * @example
 * ```hx
 * // let x: ?i32 = 1; if (x != null) { const y = x; }
 * hxsCheckSymbolValue(c, node, sym, "x", 1); // i32, the narrowed payload
 * ```
 *
 * @see hxsCheckIdent
 * @since 1.0.0
 */

export extern "C" function hxsCheckSymbolValue(c: *Ctx, node: u32, sym: u32, textPtr: readonly u8[*], len: i32): u32 {
    const text = textOf(textPtr, len);
    hxsMarkUsed(c, sym);
    infoOf(c, node).symbol = sym;
    switch (symbolOf(c, sym).kind as u32) {
        case 5: {   // MODULE
            const diag = errorNode(c, node, `\`${text}\` is a module, not a value`);
            hintf(c, diag, `use one of its exports: \`${text}.name\``);
            return 0;
        }
        case 3: return hxsFunctionValue(c, node, sym, textPtr, len);   // FUNCTION
        case 4: {   // TYPE
            void errorNode(c, node, `\`${text}\` is a type, not a value`);
            return 0;
        }
        case 2: hxsResolveGlobal(c, sym);   // GLOBAL
        default: {}
    }
    const s = symbolOf(c, sym);   // fetched after resolving: resolving can add symbols
    infoOf(c, node).value = s.value;
    if (s.kind == HxSymLocal as u8) noteRead(c, node, sym);
    if (s.type != 0 && typeOf(c, s.type).kind == TypeKind.Optional) {
        let i = c.narrowed.len;
        while (i > 0) {
            i -= 1;
            if (u32At(&c.narrowed, i) != sym) continue;
            infoOf(c, node).flags |= HxInfoNarrowed;   // `x != null` was checked: read the payload
            return typeOf(c, s.type).child;
        }
    }
    return s.type;
}

/**
 * Applies C's default argument promotions to an argument in the variadic part of an `extern "C"` call.
 *
 * @param c - The checker context
 * @param arg - The checked argument node
 *
 * @remarks
 * - **Integers** - an untyped integer becomes `i32` when it fits and `i64` otherwise,
 *   and a sized integer under 32 bits becomes `i32`.
 * - **Floats** - any float becomes `f64`.
 * - **Strings** - a string literal becomes a `readonly u8[*]`.
 * - **Pointers** - pass unchanged.
 * - **Everything else** - draws an error.
 *   A slice gets a hint to pass its pointer, a `bool` or an enum a hint to convert it,
 *   and an error a hint to pass its name.
 *
 * @example
 * ```hx
 * // printf("%d", 1);
 * hxsPromoteVararg(c, arg); // the 1 becomes an i32
 * ```
 *
 * @see hxsCheckArgs
 * @since 1.0.0
 */

export extern "C" function hxsPromoteVararg(c: *Ctx, arg: u32): void {
    const t = infoOf(c, arg).type;
    if (t == 0) return;
    const type = typeOf(c, t);
    const tys = types(c);
    switch (type.kind) {
        case TypeKind.ComptimeInt: {
            const v = hxsValueOf(c, arg);
            void hxsCoerce(c, arg, v != null && hxsIntFits(c, tys.i32, v.integer) ? tys.i32 : tys.i64);
        }
        case TypeKind.ComptimeFloat, TypeKind.Float: void hxsCoerce(c, arg, tys.f64);
        case TypeKind.StringLiteral: void hxsCoerce(c, arg, hxTypePointer(tys, TypeKind.ManyPointer as u32, tys.u8, true));
        case TypeKind.Int: if (type.bits < 32) void hxsCoerce(c, arg, tys.i32);
        case TypeKind.Pointer, TypeKind.ManyPointer: {}
        case TypeKind.Slice: {
            const diag = errorNode(c, arg, "a slice can't be passed to a C variadic function");
            hint(c, diag, "pass its pointer with `.ptr` (and its length separately if C needs it)");
        }
        default: {
            const diag = errorNode(c, arg, `\`${typeName(c, t)}\` can't be passed to a C variadic function`);
            if (type.kind == TypeKind.Bool || type.kind == TypeKind.Enum) hint(c, diag, "convert it: `x as i32`");
            if (type.kind == TypeKind.ErrorSet) hint(c, diag, "pass its name: `@errorName(e)`");
        }
    }
}

/**
 * Checks the arguments of a call whose callee failed, without expected types.
 *
 * @param c - The checker context
 * @param node - The call node
 *
 * @remarks
 * The arguments still get checked, so the errors inside them are reported and their names count as used.
 *
 * @example
 * ```hx
 * // nope(missing);
 * hxsCheckArgsUnknown(c, node); // error: unknown name `missing`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckArgsUnknown(c: *Ctx, node: u32): void {
    const args = record<HxRange>(astOf(c), nodeOf(c, node).b);
    for (const i of args.start..args.end) void hxsCheckExpr(c, extraOf(c, i), 0);
}

/**
 * Checks the arguments of a call of a function or method against its function type.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param fnType - The function type of the callee
 * @param skip - The number of leading parameters that the arguments do not fill, 1 for a method's receiver
 * @param namePtr - The first byte of the callee's name, for the error message
 * @param nameLen - The length of the name in bytes
 *
 * @remarks
 * Too few arguments, or too many for a function that is not variadic,
 * draws an error that gives the expected count and the function type.
 * Each argument is checked against its parameter type,
 * and the extra arguments of a variadic function get C's default promotions.
 *
 * @example
 * ```hx
 * // function add(a: i32, b: i32): i32 { ... }  add(1);
 * hxsCheckArgs(c, node, fnType, 0, "add", 3); // error: `add` takes 2 arguments, but 1 was given
 * ```
 *
 * @see hxsPromoteVararg
 * @since 1.0.0
 */

export extern "C" function hxsCheckArgs(c: *Ctx, node: u32, fnType: u32, skip: u32, namePtr: readonly u8[*], nameLen: i32): void {
    const name = textOf(namePtr, nameLen);
    const args = record<HxRange>(astOf(c), nodeOf(c, node).b);
    const argCount = args.end - args.start;
    const fn = typeOf(c, fnType);   // a copy: checking arguments can add types and move the table
    const paramCount = @truncate(u32, fn.len) - skip;
    const variadic = (fn.flags & Variadic) != 0;
    if (argCount < paramCount || (argCount > paramCount && !variadic)) {
        const diag = errorNode(c, node, `\`${name}\` takes ${paramCount} argument${paramCount == 1 ? "" : "s"}, but ${argCount} ${argCount == 1 ? "was" : "were"} given`);
        hintf(c, diag, `its type is \`${typeName(c, fnType)}\``);
    }
    for (const i of 0..argCount) {
        const arg = extraOf(c, args.start + i);
        if (i < paramCount) {
            void hxsCheckExpr(c, arg, paramOf(c, fn, (skip + i) as u64));
        } else {
            void hxsCheckExpr(c, arg, 0);
            if (variadic) hxsPromoteVararg(c, arg);
        }
    }
}

/**
 * Checks a union value built from a variant, like `Shape.Circle(2.0)`.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param owner - The union type
 * @param variant - The member of the variant
 * @param namePtr - The first byte of the variant's name
 * @param len - The length of the name in bytes
 * @returns The union type, or 0 after an error
 *
 * @remarks
 * The call needs exactly one argument of the variant's type.
 * A variant that carries no value is written without parentheses, and calling it draws an error.
 * On success, the node records the variant's index.
 *
 * @example
 * ```hx
 * // union Shape { Circle: f64, Empty }  Shape.Circle(2.0);
 * hxsCheckUnionInit(c, node, shape, variant, "Circle", 6); // Shape
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckUnionInit(c: *Ctx, node: u32, owner: u32, variant: HxMember, namePtr: readonly u8[*], len: i32): u32 {
    const name = textOf(namePtr, len);
    const args = record<HxRange>(astOf(c), nodeOf(c, node).b);
    const count = args.end - args.start;
    if (variant.type == 0) {
        const diag = errorNode(c, node, `\`${typeName(c, owner)}.${name}\` carries no value`);
        hintf(c, diag, `write it without parentheses: \`${typeName(c, owner)}.${name}\``);
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    if (count != 1) {
        void errorNode(c, node, `\`${typeName(c, owner)}.${name}\` takes exactly one value of type \`${typeName(c, variant.type)}\``);
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    void hxsCheckExpr(c, extraOf(c, args.start), variant.type);
    infoOf(c, node).flags |= HxInfoUnionInit;
    infoOf(c, node).aux = variant.index;
    return owner;
}

/**
 * Finds the type that an expression names, like `Role` in `Role.Admin`.
 *
 * @param c - The checker context
 * @param node - The expression
 * @returns The type when the expression names one, or 0 otherwise
 *
 * @remarks
 * A name, another module's `ns.Type`, and a generic instance such as `Box<i32>` can name a type.
 * The type's symbol is marked as used and resolved, and nothing gets reported when the expression names no type.
 *
 * @example
 * ```hx
 * // enum Role { Admin }  Role.Admin;
 * hxsTypeNameRef(c, base); // the Role type
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsTypeNameRef(c: *Ctx, node: u32): u32 {
    if (nodeOf(c, node).kind == NodeKind.GenericInstance) return hxsInstantiateTypeNode(c, node);
    if (nodeOf(c, node).kind == NodeKind.FieldAccess) {   // `ns.Type`
        const mem = hxsModuleMember(c, nodeOf(c, node).a, nodeOf(c, node).token, false);
        if (mem == 0 || mem == 0xFFFF_FFFF || symbolOf(c, mem).kind != HxSymType as u8) return 0;
        hxsMarkUsed(c, mem);
        hxsResolveGlobal(c, mem);
        infoOf(c, node).symbol = mem;
        return symbolOf(c, mem).type;
    }
    if (nodeOf(c, node).kind != NodeKind.Ident) return 0;
    const sym = hxsLookup(c, hxsTokName(c, nodeOf(c, node).token));
    if (sym == 0 || symbolOf(c, sym).kind != HxSymType as u8) return 0;
    hxsMarkUsed(c, sym);
    hxsResolveGlobal(c, sym);
    infoOf(c, node).symbol = sym;
    return symbolOf(c, sym).type;
}

/**
 * Checks whether a type is a writer that formatting can target.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns `true` for a `dyn I` whose first method is a `write` with the expected signature
 *
 * @remarks
 * The first method must be `write(this: *Self, bytes: readonly u8[]): void | Error`.
 * The generated code calls only that slot, so the method's name does not matter,
 * and a matching `write` in a later slot does not count.
 *
 * @example
 * ```hx
 * // import { Writer } from "std/io";
 * hxsIsWriter(c, dynWriter); // true
 * ```
 *
 * @see hxsCheckFormatWrite
 * @since 1.0.0
 */

export extern "C" function hxsIsWriter(c: *Ctx, t: u32): bool {
    if (t == 0 || typeOf(c, t).kind != TypeKind.Dyn) return false;
    const iface = typeOf(c, t).child;
    hxsResolveAggregate(c, iface);
    const agg = *hxsAggregateOf(c, iface);
    const tys = types(c);
    for (const i of 0..agg.membersCount) {
        const m = *memberAt(c, agg.membersStart + i);
        if (m.kind != HxMemberSignature as u8 || m.index != 0) continue;
        const params: u32[2] = [hxTypePointer(tys, TypeKind.Pointer as u32, iface, false), tys.string];
        const ret = hxTypeErrorUnion(tys, tys.voidType, tys.anyError);
        return m.type == hxTypeFunction(tys, ret, &params, 2, false);
    }
    return false;
}

/**
 * Checks `f.writeTo(w)`, which runs a template's formatter into a writer.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param namePtr - The first byte of the method's name
 * @param len - The length of the name in bytes
 * @returns The `void | Error` result type, or 0 when the method is not `writeTo`
 *
 * @remarks
 * A `Format` has one method, `writeTo`, which takes exactly one writer.
 * An argument that is not a writer draws an error but keeps the result type.
 *
 * @example
 * ```hx
 * // const f = format`n=${n}`;  f.writeTo(w);
 * hxsCheckFormatWrite(c, node, "writeTo", 7); // void | Error
 * ```
 *
 * @see hxsIsWriter
 * @since 1.0.0
 */

export extern "C" function hxsCheckFormatWrite(c: *Ctx, node: u32, namePtr: readonly u8[*], len: i32): u32 {
    const name = textOf(namePtr, len);
    const args = record<HxRange>(astOf(c), nodeOf(c, node).b);
    const tys = types(c);
    const result = hxTypeErrorUnion(tys, tys.voidType, tys.anyError);
    const isWriteTo = name.len == 7 && name[0] == 'w' && name[1] == 'r' && name[2] == 'i' && name[3] == 't' &&
                      name[4] == 'e' && name[5] == 'T' && name[6] == 'o';
    if (!isWriteTo) {
        const diag = errorNode(c, nodeOf(c, node).a, `\`Format\` has no method \`${name}\``);
        hint(c, diag, "a `Format` has one method: `f.writeTo(writer)`");
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    if (args.end - args.start != 1) {
        void errorNode(c, node, "`writeTo` takes one writer");
        hxsCheckArgsUnknown(c, node);
        return result;
    }
    const arg = extraOf(c, args.start);
    const w = hxsCheckExpr(c, arg, 0);
    if (w != 0 && !hxsIsWriter(c, w)) {
        const diag = errorNode(c, arg, `\`writeTo\` needs a writer, found \`${typeName(c, w)}\``);
        hint(c, diag, "pass a `dyn Writer` from \"std/io\", or any `dyn` whose first method is `write(this: *Self, bytes: readonly u8[]): void | Error`");
    }
    infoOf(c, node).flags |= HxInfoFormatWrite;
    return result;
}

/**
 * Checks that a method called with type arguments, like `x.m<i32>(...)`, has type parameters of its own.
 *
 * @param c - The checker context
 * @param method - The symbol of the method
 * @param explicitArgs - The generic instance node of the type arguments, or 0 when there are none
 * @param callee - The callee node, whose name goes into the error
 * @returns `true` when there are no type arguments or the method takes them
 *
 * @remarks
 * Reads the generic parameter list from the declaration of the method,
 * so type parameters of the owning type do not count.
 * The error points at the type arguments rather than at the call.
 *
 * @example
 * ```hx
 * // p.len<i32>();   where len has no type parameters
 * hxsMethodTypeArgsOk(c, method, args, callee); // false, error: `len` has no type parameters of its own
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsMethodTypeArgsOk(c: *Ctx, method: u32, explicitArgs: u32, callee: u32): bool {
    if (explicitArgs == 0) return true;
    const fn = record<HxFnData>(astOf(c), nodeOf(c, symbolOf(c, method).decl).a);
    if (fn.genericsStart != fn.genericsEnd) return true;
    void errorNode(c, explicitArgs, `\`${tokenText(c, nodeOf(c, callee).token)}\` has no type parameters of its own`);
    return false;
}

/**
 * Finds the function to call for a method of a type, called on the type or through a value.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param m - The member of the method
 * @param explicitArgs - The generic instance node of the type arguments, or 0
 * @param callee - The callee node
 * @param name - The method's name
 * @param owner - The type that owns the method
 * @param skip - The number of leading parameters that the arguments do not fill
 * @returns The symbol of the method instance to call, or 0 after an error
 *
 * @remarks
 * A method with type parameters of its own gets an instance for the call, which also checks the arguments.
 * Any other method gets the instance for its owner, and the caller checks the arguments.
 *
 * @since 1.0.0
 */

function callMethod(c: *Ctx, node: u32, m: HxMember, explicitArgs: u32, callee: u32, name: string, owner: u32, skip: u32): u32 {
    if (!hxsMethodTypeArgsOk(c, m.symbol, explicitArgs, callee)) {
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    const own = (symbolOf(c, m.symbol).flags & (HxSymTemplateMethod as u16)) != 0;
    const method = own ? hxsGenericCallInstance(c, node, m.symbol, explicitArgs, name.ptr, name.len as i32, owner, skip)
                       : hxsMethodInstance(c, m.symbol, owner, node);
    if (method == 0) return 0;
    hxsMarkUsed(c, method);
    infoOf(c, node).symbol = method;
    return method;
}

/**
 * Checks a call through a member access, like `Type.member(...)` or `value.method(...)`.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param callee - The member access node
 * @param explicitArgs - The generic instance node of `x.map<i32>(...)`, or 0
 * @returns The result type of the call, or 0 after an error
 *
 * @remarks
 * The callee is tried in this order:
 * - **Another module** - `ns.fn(...)` calls an exported function, and any other export is called as a value.
 * - **A type** - `Type.member(...)` calls a function of the type or builds a union variant.
 *   An interface has no functions of its own.
 * - **A `dyn` value** - the call goes through the vtable slot of the method and takes no type arguments.
 * - **A `Format`** - only `writeTo` exists.
 * - **A struct field** - `this.onClick(x)` calls the function stored in the field.
 * - **A method** - the receiver is passed by value or by address, as its first parameter asks.
 *   A pointer to a struct is followed to the struct.
 *
 * A method that takes `*Self` needs the address of a place, so a temporary value draws an error,
 * and a constant place draws an error when the receiver is not readonly.
 * Calling such a method on a local gives the local a value,
 * and the root variable of the place is marked as mutated.
 * A method without a `this` parameter cannot be called on a value.
 * Calling a method on an optional value that is not narrowed draws a hint to check it for `null` first.
 *
 * @example
 * ```hx
 * // let list = List.init(); list.push(1);
 * hxsCheckMemberCall(c, node, callee, 0); // void
 * ```
 *
 * @see hxsCheckArgs
 * @since 1.0.0
 */

export extern "C" function hxsCheckMemberCall(c: *Ctx, node: u32, callee: u32, explicitArgs: u32): u32 {
    const cn = nodeOf(c, callee);
    const name = tokenText(c, cn.token);
    const memberName = hxsTokName(c, cn.token);

    const exported = hxsModuleMember(c, cn.a, cn.token, true);
    if (exported == 0xFFFF_FFFF) {
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    if (exported != 0 && symbolOf(c, exported).kind != HxSymFunction as u8) return hxsIndirectCall(c, node, callee, hxsCheckExpr(c, callee, 0));
    if (exported != 0) return hxsCheckFunctionCall(c, node, exported, name.ptr, name.len as i32);   // `ns.fn(...)`

    const owner = hxsTypeNameRef(c, cn.a);
    if (owner != 0 && typeOf(c, owner).kind == TypeKind.Interface) {
        const diag = errorNode(c, callee, `\`${typeName(c, owner)}\` is an interface, so it has no functions of its own`);
        hintf(c, diag, `call the method on a value: \`x.${name}(...)\` where \`x\` is a \`dyn ${typeName(c, owner)}\``);
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    if (owner != 0) {
        const index = hxsFindMember(c, owner, memberName);
        if (index >= 0) {
            const m = hxsMemberOf(c, owner, index);
            if (m.kind == HxMemberField as u8 && typeOf(c, owner).kind == TypeKind.Union) {
                return hxsCheckUnionInit(c, node, owner, m, name.ptr, name.len as i32);
            }
            if (m.kind == HxMemberMethod as u8) {
                const own = (symbolOf(c, m.symbol).flags & (HxSymTemplateMethod as u16)) != 0;
                const method = callMethod(c, node, m, explicitArgs, callee, name, owner, 0);
                if (method == 0) return 0;
                const fnType = symbolOf(c, method).type;
                if (fnType == 0) {
                    hxsCheckArgsUnknown(c, node);
                    return 0;
                }
                if (!own) hxsCheckArgs(c, node, fnType, 0, name.ptr, name.len as i32);
                return typeOf(c, fnType).child;
            }
        }
        void errorNode(c, callee, `\`${typeName(c, owner)}\` has no function \`${name}\``);
        hxsCheckArgsUnknown(c, node);
        return 0;
    }

    const base = hxsCheckExpr(c, cn.a, 0);
    if (base == 0) {
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    if (explicitArgs != 0 && typeOf(c, base).kind == TypeKind.Dyn) {
        void errorNode(c, explicitArgs, "methods called through `dyn` have no type parameters");
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    if (typeOf(c, base).kind == TypeKind.Format) return hxsCheckFormatWrite(c, node, name.ptr, name.len as i32);

    if (typeOf(c, base).kind == TypeKind.Dyn) {   // through the vtable
        const iface = typeOf(c, base).child;
        const index = hxsFindMember(c, iface, memberName);
        if (index < 0) {
            void errorNode(c, callee, `\`${typeName(c, base)}\` has no method \`${name}\``);
            hxsCheckArgsUnknown(c, node);
            return 0;
        }
        const m = hxsMemberOf(c, iface, index);
        if (m.type == 0) {
            hxsCheckArgsUnknown(c, node);
            return 0;
        }
        infoOf(c, node).flags |= HxInfoDyn;
        infoOf(c, node).aux = m.index;
        hxsCheckArgs(c, node, m.type, 1, name.ptr, name.len as i32);
        return typeOf(c, m.type).child;
    }

    let target = base;
    let throughPointer = false;
    if (typeOf(c, base).kind == TypeKind.Pointer && hxsIsAggregate(c, typeOf(c, base).child)) {
        target = typeOf(c, base).child;
        throughPointer = true;
    }
    const index = hxsIsAggregate(c, target) ? hxsFindMember(c, target, memberName) : -1;
    if (index >= 0 && typeOf(c, target).kind == TypeKind.Struct && hxsMemberOf(c, target, index).kind == HxMemberField as u8 &&
        explicitArgs == 0) {
        const field = hxsMemberOf(c, target, index);   // `this.onClick(x)`: call the function stored in a field
        infoOf(c, callee).flags |= HxInfoField | (throughPointer ? HxInfoDeref : 0);
        infoOf(c, callee).aux = field.index;
        infoOf(c, callee).type = field.type;
        return hxsIndirectCall(c, node, callee, field.type);
    }
    if (index < 0 || hxsMemberOf(c, target, index).kind != HxMemberMethod as u8) {
        if (typeOf(c, base).kind == TypeKind.Optional) {
            const diag = errorNode(c, cn.a, `\`${typeName(c, base)}\` might be null`);
            hintf(c, diag, `check \`!= null\` first, or assert it with \`x!.${name}(...)\``);
        } else {
            void errorNode(c, callee, `\`${typeName(c, target)}\` has no method \`${name}\``);
        }
        hxsCheckArgsUnknown(c, node);
        return 0;
    }

    const m = hxsMemberOf(c, target, index);
    const own = (symbolOf(c, m.symbol).flags & (HxSymTemplateMethod as u16)) != 0;
    const method = callMethod(c, node, m, explicitArgs, callee, name, target, 1);
    if (method == 0) return 0;
    const fnType = symbolOf(c, method).type;
    if (fnType == 0) {
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    const fn = typeOf(c, fnType);
    const receiver = fn.len != 0 ? paramOf(c, fn, 0) : 0;
    const r = receiver != 0 ? typeOf(c, receiver) : typeOf(c, 0);

    if (receiver != 0 && receiver == target) {
        infoOf(c, node).flags |= HxInfoMethod | (throughPointer ? HxInfoDeref : 0);
    } else if (r.kind == TypeKind.Pointer && r.child == target) {
        const needsMutable = (r.flags & Readonly) == 0;
        infoOf(c, node).flags |= HxInfoMethod | HxInfoReceiverAddr | (throughPointer ? HxInfoDeref : 0);
        if (!throughPointer) noteWrite(c, cn.a);   // `x.init()` gives `x` its value
        if (throughPointer) {
            if (needsMutable && (typeOf(c, base).flags & Readonly) != 0) {
                const diag = errorNode(c, cn.a, `\`${name}\` changes the \`${typeName(c, target)}\`, but this pointer is readonly`);
                hintf(c, diag, `pass a mutable \`*${typeName(c, target)}\``);
            }
        } else {
            const baseKind = nodeOf(c, cn.a).kind;
            const place = baseKind == NodeKind.Ident || baseKind == NodeKind.Index || baseKind == NodeKind.Deref ||
                          (baseKind == NodeKind.FieldAccess && (infoOf(c, cn.a).flags & HxInfoField) != 0);
            if (!place || (baseKind == NodeKind.Ident && hxsValueOf(c, cn.a) != null)) {
                const diag = errorNode(c, cn.a, `\`${name}\` needs the address of a \`${typeName(c, target)}\``);
                hint(c, diag, "store the value in a variable first");
            } else if (needsMutable) {
                if (!hxsIsMutablePlace(c, cn.a, false)) {
                    const diag = errorNode(c, cn.a, `\`${name}\` changes the \`${typeName(c, target)}\`, but this value is constant`);
                    hint(c, diag, "declare it with `let`");
                } else {
                    const root = hxsPlaceRoot(c, cn.a);
                    if (root != 0) symbolOf(c, root).flags |= HxSymMutated as u16;
                }
            }
        }
    } else {
        const diag = errorNode(c, callee, `\`${name}\` can't be called on a value`);
        const t = typeName(c, target);
        hintf(c, diag, `call it as \`${t}.${name}(...)\`, or make its first parameter \`this: ${typeName(c, target)}\` or \`this: *${typeName(c, target)}\``);
        if (!own) hxsCheckArgsUnknown(c, node);
        return 0;
    }
    if (!own) hxsCheckArgs(c, node, fnType, 1, name.ptr, name.len as i32);
    return fn.child;
}
