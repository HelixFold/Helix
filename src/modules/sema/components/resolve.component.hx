/**
 * Imports
 */

import { record } from "@models/ast.model";
import { Ctx, TypeParam } from "@structs/sema.struct";
import { HxFnData } from "@models/structs/ast-model.struct";
import { hxsLookup } from "@modules/sema/components/scope.component";
import { TypeKind, CCall, Variadic } from "@constants/types.constant";
import { hxsMarkUsed } from "@modules/sema/components/call.component";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { hxsResolveGlobal } from "@modules/sema/components/decl.component";
import { hxsModuleMember } from "@modules/sema/components/imports.component";
import { hxTypePointer, hxTypeArray, hxTypeReadonly } from "@models/types.model";
import { hxsResolveInterface } from "@modules/sema/components/interfaces.component";
import { hxsInstantiateTypeNode } from "@modules/sema/components/generics.component";
import { HxSymUsed, HxSymType, HxSymGeneric, HxValueInt } from "@constants/sema.constant";
import { errorNode, errorToken, hint, hintf } from "@modules/sema/components/base.component";
import { NodeKind, FlagComptime, FlagExtern, FlagVariadic, NoToken } from "@constants/ast.constant";
import { hxsDeclareAggregate, hxsResolveAggregate } from "@modules/sema/components/aggregate.component";
import { hxTypeOptional, hxTypeErrorUnion, hxTypeFunctionFlags, hxTypeBuiltin } from "@models/types.model";
import { hxsTokName, hxsValueOf, hxsFormatEscapes, astOf, nodeOf } from "@modules/sema/components/base.component";
import { typeOf, symbolOf, infoOf, extraOf, types, tokenText, typeName } from "@modules/sema/components/base.component";

/**
 * Reports a generic type named without its type arguments.
 *
 * @param c - The checker context
 * @param node - The node that names the type
 * @param name - The name of the type, used in the message and the hint
 * @returns Always 0, the failed type, so the caller can return it directly
 *
 * @remarks
 * The hint suggests `i32` as the argument whatever the generic takes, since it only shows the shape of the fix.
 *
 * @since 1.0.0
 */

function genericNeedsArguments(c: *Ctx, node: u32, name: string): u32 {
    const diag = errorNode(c, node, `\`${name}\` is generic, so it needs type arguments`);
    hintf(c, diag, `write them in angle brackets, e.g. \`${name}<i32>\``);
    return 0;
}

/**
 * Finds the type that a type parameter in scope stands for.
 *
 * @param c - The checker context
 * @param name - The interned name of the parameter
 * @returns The type bound to the innermost parameter with that name, or 0 when no parameter has it
 *
 * @remarks
 * The search runs from the newest binding to the oldest,
 * so the parameter of an inner generic hides an outer one with the same name.
 *
 * @since 1.0.0
 */

function typeParam(c: *Ctx, name: u32): u32 {
    let i = c.typeParams.len;
    unsafe {
        while (i > 0) {
            const tp = @ptrCast(TypeParam[*], c.typeParams.items)[i - 1];
            if (tp.name == name) return tp.type;
            i -= 1;
        }
    }
    return 0;
}

/**
 * Resolves the syntax of a type to the type it names.
 *
 * @param c - The checker context
 * @param node - The type node, or 0 for a missing type
 * @returns The type, `void` for a missing type, or 0 after an error was reported
 *
 * @remarks
 * It works out what syntax such as `?*User[]`, `(a: i32) => bool`, or `ArrayList<u8>` names.
 * A plain name is looked up as a type parameter first, then as a built-in type, then as a declared type.
 * It is an error when the name is unknown, is a value, is an interface, or is generic without type arguments.
 * A namespaced name such as `ns.Type` goes through the exports of the imported module with the same checks.
 *
 * The other forms build on the type of their parts:
 * - **Pointers and slices** - `*T`, `T[]`, and `T[*]`, with `readonly` allowed only in front of these three.
 * - **Arrays** - `T[n]`, where the length must be a non-negative integer known at compile time.
 * - **Optionals** - `?T`, which is not valid around `void`, another optional, or an error union.
 * - **Error unions** - `T | E`, where `E` must be an error set and `T` must not be an error set or carry one.
 * - **Function types** - only an `extern "C"` function type can be variadic,
 *   and its parameters cannot be `comptime`.
 * - **Others** - an anonymous struct, `dyn Interface`, and a generic instance such as `List<i32>`.
 *
 * Since the expression parser reads `*T` and `T[n]` as a dereference and an index, those nodes are accepted too.
 * A `Format` cannot hide inside another type such as `*Format`, `Format[]`, or `?Format`,
 * since each of these would outlive the call that the format belongs to.
 * The resolved type is also stored on the node.
 *
 * @example
 * ```hx
 * // let x: ?*i32 = null;
 * hxsResolveType(c, typeNode); // the type ?*i32
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsResolveType(c: *Ctx, node: u32): u32 {
    const tys = types(c);
    if (node == 0) return tys.voidType;
    const n = nodeOf(c, node);
    let result: u32 = 0;
    switch (n.kind) {
        case NodeKind.Ident: {
            const text = tokenText(c, n.token);
            const name = hxsTokName(c, n.token);
            result = typeParam(c, name);
            if (result == 0) result = hxTypeBuiltin(tys, text.ptr, @truncate(u32, text.len));
            if (result == 0) {
                const sym = hxsLookup(c, name);
                if (sym != 0 && symbolOf(c, sym).kind == HxSymType as u8 && (symbolOf(c, sym).flags & (HxSymGeneric as u16)) != 0) {
                    return genericNeedsArguments(c, node, text);
                }
                if (sym == 0) {
                    void errorNode(c, node, `unknown type \`${text}\``);
                    return 0;
                }
                symbolOf(c, sym).flags |= HxSymUsed as u16;
                if (symbolOf(c, sym).kind != HxSymType as u8) {
                    void errorNode(c, node, `\`${text}\` is a value, not a type`);
                    return 0;
                }
                hxsResolveGlobal(c, sym);
                result = symbolOf(c, sym).type;
                if (result != 0 && typeOf(c, result).kind == TypeKind.Interface) {
                    const diag = errorNode(c, node, `\`${text}\` is an interface, not a type`);
                    hintf(c, diag, `take any implementation with \`dyn ${text}\`, or a generic \`<T extends ${text}>\``);
                    return 0;
                }
            }
        }
        case NodeKind.TypePointer, NodeKind.Deref: {
            const child = hxsResolveType(c, n.a);
            result = child != 0 ? hxTypePointer(tys, TypeKind.Pointer as u32, child, false) : 0;
        }
        case NodeKind.TypeSlice, NodeKind.TypeManyPointer: {
            const child = hxsResolveType(c, n.a);
            const kind = n.kind == NodeKind.TypeSlice ? TypeKind.Slice : TypeKind.ManyPointer;
            result = child != 0 ? hxTypePointer(tys, kind as u32, child, false) : 0;
        }
        case NodeKind.TypeArray, NodeKind.Index: {
            const child = hxsResolveType(c, n.a);
            void hxsCheckExpr(c, n.b, 0);
            const len = hxsValueOf(c, n.b);
            if (len == null || len.kind != HxValueInt as u8 || len.integer < 0) {
                void errorNode(c, n.b, "array length must be a non-negative integer known at compile time");
                return 0;
            }
            result = child != 0 ? hxTypeArray(tys, child, @truncate(u64, len.integer)) : 0;
        }
        case NodeKind.TypeReadonly: {
            const child = hxsResolveType(c, n.a);
            if (child == 0) return 0;
            const kind = typeOf(c, child).kind;
            if (kind != TypeKind.Pointer && kind != TypeKind.Slice && kind != TypeKind.ManyPointer) {
                void errorNode(c, node, `\`readonly\` applies to pointers and slices, not \`${typeName(c, child)}\``);
                return 0;
            }
            result = hxTypeReadonly(tys, child);
        }
        case NodeKind.TypeOptional: {
            const child = hxsResolveType(c, n.a);
            if (child == 0) return 0;
            const kind = typeOf(c, child).kind;
            if (kind == TypeKind.Void || kind == TypeKind.Optional || kind == TypeKind.ErrorUnion) {
                void errorNode(c, node, `\`?${typeName(c, child)}\` is not a valid optional`);
                return 0;
            }
            result = hxTypeOptional(tys, child);
        }
        case NodeKind.TypeErrorUnion: {
            const payload = hxsResolveType(c, n.a);
            const set = hxsResolveType(c, n.b);
            if (payload == 0 || set == 0) return 0;
            if (typeOf(c, set).kind != TypeKind.ErrorSet) {
                const diag = errorNode(c, n.b, `\`${typeName(c, set)}\` is not an error set`);
                hint(c, diag, "`|` in a type adds errors, as in `User | DbError`; for a choice between values declare a `union`");
                return 0;
            }
            if (typeOf(c, payload).kind == TypeKind.ErrorUnion || typeOf(c, payload).kind == TypeKind.ErrorSet) {
                const diag = errorNode(c, node, "a type can have only one error set");
                hint(c, diag, "declare one set with all the errors, or use `Error`");
                return 0;
            }
            result = hxTypeErrorUnion(tys, payload, set);
        }
        case NodeKind.TypeStruct: {
            if (infoOf(c, node).type != 0) return infoOf(c, node).type;
            result = hxsDeclareAggregate(c, TypeKind.Struct as u32, node, NoToken);
            infoOf(c, node).type = result;
            hxsResolveAggregate(c, result);
        }
        case NodeKind.TypeFunction: {   // `(a: i32, b: i32) => bool`, `extern "C" (fmt: ?readonly u8[*], ...) => void`
            const fn = record<HxFnData>(astOf(c), n.a);
            const cCall = (n.flags & FlagExtern) != 0;
            if (cCall && fn.abiToken != NoToken) {
                const abi = tokenText(c, fn.abiToken);
                if (abi.len != 3 || abi[1] != 'C') void errorToken(c, fn.abiToken, "only `extern \"C\"` is supported");
            }
            if ((n.flags & FlagVariadic) != 0 && !cCall) {
                const diag = errorNode(c, node, "only a C function type can be variadic");
                hint(c, diag, "write `extern \"C\" (fmt: ?readonly u8[*], ...) => void`; Helix functions take a slice instead");
            }
            let params: u32[256] = undefined;
            let count: u32 = 0;
            let ok = true;
            for (const i of fn.paramsStart..fn.paramsEnd) {
                if (count >= 256) break;
                const p = extraOf(c, i);
                if ((nodeOf(c, p).flags & FlagComptime) != 0) void errorNode(c, p, "a function type can't have `comptime` parameters");
                const t = hxsResolveType(c, nodeOf(c, p).a);
                if (t == 0 || t == tys.voidType) ok = false;
                params[count] = t;
                count += 1;
            }
            const ret = hxsResolveType(c, fn.returnType);
            if (!ok || ret == 0 || hxsFormatEscapes(c, ret, fn.returnType)) return 0;
            const flags = (cCall ? CCall : 0) | (cCall && (n.flags & FlagVariadic) != 0 ? Variadic : 0);
            result = hxTypeFunctionFlags(tys, ret, &params, count, flags);
        }
        case NodeKind.TypeDyn: {
            const iface = hxsResolveInterface(c, n.a, "`dyn`");
            if (iface == 0) return 0;
            result = hxTypePointer(tys, TypeKind.Dyn as u32, iface, false);
        }
        case NodeKind.GenericInstance: {
            result = hxsInstantiateTypeNode(c, node);
            if (result == 0) return 0;
            if (typeOf(c, result).kind == TypeKind.Interface) {
                const diag = errorNode(c, node, `\`${typeName(c, result)}\` is an interface, not a type`);
                hintf(c, diag, `take any implementation with \`dyn ${typeName(c, result)}\``);
                return 0;
            }
        }
        case NodeKind.FieldAccess: {   // `ns.Type`
            const mem = hxsModuleMember(c, n.a, n.token, true);
            if (mem == 0xFFFF_FFFF) return 0;
            const text = tokenText(c, n.token);
            if (mem == 0 || symbolOf(c, mem).kind != HxSymType as u8) {
                void errorNode(c, node, `\`${text}\` is not a type`);
                return 0;
            }
            hxsMarkUsed(c, mem);
            if ((symbolOf(c, mem).flags & (HxSymGeneric as u16)) != 0) return genericNeedsArguments(c, node, text);
            hxsResolveGlobal(c, mem);
            result = symbolOf(c, mem).type;
            if (result != 0 && typeOf(c, result).kind == TypeKind.Interface) {
                const diag = errorNode(c, node, `\`${text}\` is an interface, not a type`);
                hint(c, diag, "take any implementation with `dyn`, or a generic `<T extends ...>`");
                return 0;
            }
        }
        case NodeKind.Invalid: return 0;
        default: {
            void errorNode(c, node, "expected a type");
            return 0;
        }
    }
    // a `Format` can't hide inside another type: `*Format`, `Format[]`, `?Format` all outlive the call
    if (n.kind != NodeKind.Ident && n.kind != NodeKind.FieldAccess && n.kind != NodeKind.TypeFunction && result != 0 &&
        typeOf(c, result).child == tys.format && typeOf(c, result).kind != TypeKind.Function) {
        void hxsFormatEscapes(c, tys.format, node);
        return 0;
    }
    infoOf(c, node).type = result;
    return result;
}
