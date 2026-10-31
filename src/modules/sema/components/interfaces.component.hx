/**
 * Imports
 */

import { record } from "@models/ast.model";
import { hxIntern } from "@services/intern.service";
import { Ctx, FnState, HxImpl } from "@structs/sema.struct";
import { HxFnData } from "@models/structs/ast-model.struct";
import { hxVecGrowImpl } from "@components/memory.component";
import { HxSymTemplateMethod } from "@constants/sema.constant";
import { NodeKind, FlagComptime } from "@constants/ast.constant";
import { hxsLookup } from "@modules/sema/components/scope.component";
import { hxsMarkUsed } from "@modules/sema/components/call.component";
import { TypeKind, Readonly, Variadic } from "@constants/types.constant";
import { hxsResolveGlobal } from "@modules/sema/components/decl.component";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { hxsModuleMember } from "@modules/sema/components/imports.component";
import { hxTypeFunction, hxTypeReadonly, hxTypeName, hxTypeBuiltin } from "@models/types.model";
import { HxSymGeneric, HxMemberSignature, HxSymType, HxMemberMethod } from "@constants/sema.constant";
import { memberAt, paramOf, tokenText, typeName, errorNode } from "@modules/sema/components/base.component";
import { hxsSaveState, hxsRestoreState, hxsEnterInstance } from "@modules/sema/components/generics.component";
import { hxsResolveAggregate, hxsFindMember, hxsMemberOf } from "@modules/sema/components/aggregate.component";
import { astOf, nodeOf, typeOf, symbolOf, infoOf, extraOf, types } from "@modules/sema/components/base.component";
import { errorToken, hint, hintf, hxsTokName, hxsAggregateOf, semaOf } from "@modules/sema/components/base.component";
import { pushTypeParam, hxsMethodInstance, hxsInstantiateTypeNode } from "@modules/sema/components/generics.component";

/**
 * Checks whether a type mentions an interface as `Self` anywhere.
 *
 * @param c - The checker context
 * @param t - The type to search, where 0 mentions nothing
 * @param iface - The interface type that `Self` stands for
 * @returns `true` when the type is the interface or wraps it
 *
 * @remarks
 * This file covers interfaces: their method signatures,
 * and which types implement them, found structurally the first time the checker needs it.
 * Only the receiver of a method may mention `Self`, so the method can be called through `dyn`.
 * The search goes through pointers, slices, arrays, optionals, and error unions.
 *
 * @example
 * ```hx
 * // interface Bad { same(this: *Self, other: *Self): bool; }
 * hxsMentions(c, otherType, iface); // true
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsMentions(c: *Ctx, t: u32, iface: u32): bool {
    if (t == 0) return false;
    if (t == iface) return true;
    const type = typeOf(c, t);
    return switch (type.kind) {
        case TypeKind.Pointer, TypeKind.ManyPointer, TypeKind.Slice, TypeKind.Array, TypeKind.Optional,
             TypeKind.ErrorUnion: hxsMentions(c, type.child, iface);
        default: false;
    };
}

/**
 * Builds the signature of an interface method with `Self` bound to a type.
 *
 * @param c - The checker context
 * @param fnNode - The method declaration inside the interface
 * @param iface - The interface type
 * @param self - The type that `Self` stands for
 * @param report - Whether to report the errors in the signature
 * @returns The function type of the signature, or 0 when it has an error
 *
 * @remarks
 * Binding `Self` to the interface itself gives the declared signature,
 * and binding it to an implementing type gives the signature that the method of that type must have.
 * The names in the signature resolve in the module of the interface,
 * and so does `T` in an instance such as `Iterator<T>`.
 * With `report` set, the method must take `this` first with the type `*Self`, `readonly *Self`, or `Self`,
 * and no other parameter or the result may mention `Self`,
 * since the concrete type is not known through `dyn`.
 * A `comptime` parameter is an error there too.
 * Without `report`, the diagnostics from resolving the signature are dropped,
 * because the checker already reported them for the interface itself.
 *
 * @example
 * ```hx
 * // interface Writer { write(this: *Self, bytes: string): usize; }
 * hxsIfaceSignature(c, decl, writer, writer, true); // (this: *Writer, bytes: string): usize
 * ```
 *
 * @see hxsMentions
 * @since 1.0.0
 */

export extern "C" function hxsIfaceSignature(c: *Ctx, fnNode: u32, iface: u32, self: u32, report: bool): u32 {
    const fn = record<HxFnData>(astOf(c), nodeOf(c, fnNode).a);
    const n = nodeOf(c, fnNode);
    // the names in the signature are the interface's, and so is `T` in `Iterator<T>`
    let saved: FnState = undefined;
    hxsSaveState(c, &saved);
    if (hxsAggregateOf(c, iface).instance != 0) hxsEnterInstance(c, hxsAggregateOf(c, iface).instance);
    c.module = hxsAggregateOf(c, iface).module;
    pushTypeParam(c, hxIntern(&semaOf(c).names, "Self", 4), self);

    let params: u32[256] = undefined;
    let count: u32 = 0;
    let ok = true;
    const diags = semaOf(c).diags!;
    const errors = diags.errorCount;
    const diagCount = diags.itemsLen;
    for (const i of fn.paramsStart..fn.paramsEnd) {
        if (count >= 256) break;
        const p = extraOf(c, i);
        if (report && (nodeOf(c, p).flags & FlagComptime) != 0) {
            void errorNode(c, p, "an interface method can't take `comptime` parameters");
            ok = false;
        }
        const t = hxsResolveType(c, nodeOf(c, p).a);
        if (t == 0) ok = false;
        params[count] = t;
        count += 1;
    }
    const ret = hxsResolveType(c, fn.returnType);
    if (fn.returnType != 0 && ret == 0) ok = false;
    hxsRestoreState(c, &saved);
    if (!report) {
        diags.itemsLen = diagCount;   // already reported for the interface itself
        diags.errorCount = errors;
    }
    if (!ok) return 0;

    if (report) {
        const name = tokenText(c, n.token);
        const first = fn.paramsStart < fn.paramsEnd ? extraOf(c, fn.paramsStart) : 0;
        const thisName = first != 0 ? tokenText(c, nodeOf(c, first).token) : "";
        const receiver = count != 0 ? params[0] : 0;
        const receiverOk = receiver == iface || (typeOf(c, receiver).kind == TypeKind.Pointer && typeOf(c, receiver).child == iface);
        const isThis = thisName.len == 4 && thisName[0] == 't' && thisName[1] == 'h' && thisName[2] == 'i' && thisName[3] == 's';
        if (first == 0 || !isThis || !receiverOk) {
            const diag = errorToken(c, n.token, `interface method \`${name}\` needs a receiver`);
            hint(c, diag, "make its first parameter `this: *Self`, `this: readonly *Self` or `this: Self`");
            return 0;
        }
        for (const i of 1..count + 1) {
            const t = i < count ? params[i] : ret;
            if (!hxsMentions(c, t, iface)) continue;
            const where = i < count ? nodeOf(c, extraOf(c, fn.paramsStart + i)).a : fn.returnType;
            const diag = errorNode(c, where, "`Self` can only be the receiver's type");
            hint(c, diag, "through `dyn` the concrete type isn't known, so other parameters and the result can't use it");
            return 0;
        }
    }
    return hxTypeFunction(types(c), ret, &params, count, false);
}

/**
 * Checks whether every method of an interface leaves the value alone.
 *
 * @param c - The checker context
 * @param iface - The interface type
 * @returns `true` when no method takes its receiver through a mutable pointer
 *
 * @remarks
 * A readonly pointer can become a `dyn` of the interface only when this holds.
 *
 * @example
 * ```hx
 * // interface Writer { write(this: *Self, bytes: string): usize; }
 * hxsIfaceReadonlyOk(c, writer); // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIfaceReadonlyOk(c: *Ctx, iface: u32): bool {
    hxsResolveAggregate(c, iface);
    const agg = *hxsAggregateOf(c, iface);
    for (const i of 0..agg.membersCount) {
        const m = *memberAt(c, agg.membersStart + i);
        if (m.kind != HxMemberSignature as u8 || m.type == 0) continue;
        const receiver = paramOf(c, typeOf(c, m.type), 0);
        if (typeOf(c, receiver).kind == TypeKind.Pointer && (typeOf(c, receiver).flags & Readonly) == 0) return false;
    }
    return true;
}

/**
 * Checks whether the receiver of a method works where an interface asks for another receiver.
 *
 * @param c - The checker context
 * @param wanted - The receiver type that the interface asks for
 * @param given - The receiver type of the method
 * @returns `true` when the method can fill the slot
 *
 * @remarks
 * The method may promise more than the interface asks.
 * Where the interface asks for `*Self`, the method may take `readonly *Self` or `Self` by value.
 * Where it asks for `readonly *Self`, the method may take `Self` by value.
 *
 * @example
 * ```hx
 * // the interface asks for *Self, and the method takes this: Square
 * hxsReceiverFits(c, wanted, square); // true
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsReceiverFits(c: *Ctx, wanted: u32, given: u32): bool {
    if (wanted == given) return true;
    const w = typeOf(c, wanted);
    if (w.kind != TypeKind.Pointer) return false;
    if (given == w.child) return true;
    return (w.flags & Readonly) == 0 && given == hxTypeReadonly(types(c), wanted);
}

/**
 * Checks whether a method signature fills the slot of an interface method.
 *
 * @param c - The checker context
 * @param wanted - The function type that the interface asks for, with `Self` bound
 * @param given - The function type of the method
 * @returns `true` when the two signatures match
 *
 * @remarks
 * Both must take the same number of parameters and return the same type,
 * and a variadic method never fits.
 * The receiver follows {@link hxsReceiverFits}, and every other parameter must match exactly.
 *
 * @example
 * ```hx
 * // wanted: (this: *Wrong, bytes: string): usize, given: (this: *Wrong, bytes: string): i32
 * hxsSignatureFits(c, wanted, given); // false
 * ```
 *
 * @see hxsReceiverFits
 * @since 1.0.0
 */

export extern "C" function hxsSignatureFits(c: *Ctx, wanted: u32, given: u32): bool {
    const w = typeOf(c, wanted);
    const g = typeOf(c, given);
    if (w.len != g.len || w.child != g.child || (g.flags & Variadic) != 0) return false;
    if (!hxsReceiverFits(c, paramOf(c, w, 0), paramOf(c, g, 0))) return false;
    for (const i of 1..w.len) {
        if (paramOf(c, w, i) != paramOf(c, g, i)) return false;
    }
    return true;
}

/**
 * Writes the name of a type into a buffer, for the hints.
 *
 * @param c - The checker context
 * @param t - The type to name
 * @param buf - The buffer that receives the NUL-terminated name
 * @returns The name as a slice of the buffer
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
 * Finds how a type implements an interface, creating the record the first time.
 *
 * @param c - The checker context
 * @param type - The type that should implement the interface
 * @param iface - The interface type
 * @param diag - The diagnostic that receives a hint on a failure, or 0xFFFFFFFF for none
 * @param site - The node that needs the record, where generic methods get instantiated
 * @returns The index of the record plus 1, or 0 when the type does not implement the interface
 *
 * @remarks
 * Implementing is structural.
 * The type needs a method for every interface method, with the same parameters and result,
 * following {@link hxsSignatureFits}.
 * Only structs, unions, and enums have methods, so only they can implement an interface.
 * A generic method can't fill the slot of an interface method.
 * The record keeps one method symbol per interface method, in the order of the interface,
 * and later calls return the same record.
 * When `diag` is set, a failure attaches a hint that says what is missing or what does not match.
 *
 * @example
 * ```hx
 * // struct Quiet {}
 * hxsImplOf(c, quiet, writer, diag, node); // 0, hint: `Quiet` has no method `write`
 * ```
 *
 * @see hxsSignatureFits
 * @since 1.0.0
 */

export extern "C" function hxsImplOf(c: *Ctx, type: u32, iface: u32, diag: u32, site: u32): u32 {
    const s = semaOf(c);
    unsafe {
        for (const i of 0..s.impls.len) {
            const impl = @ptrCast(HxImpl[*], s.impls.items)[i];
            if (impl.type == type && impl.iface == iface) return i + 1;
        }
    }
    const kind = typeOf(c, type).kind;
    if (kind != TypeKind.Struct && kind != TypeKind.Union && kind != TypeKind.Enum) {
        if (diag != 0xFFFF_FFFF) hintf(c, diag, `only structs, unions and enums have methods, so only they can implement \`${typeName(c, iface)}\``);
        return 0;
    }
    hxsResolveAggregate(c, iface);
    hxsResolveAggregate(c, type);
    const agg = *hxsAggregateOf(c, iface);
    let methods: u32[256] = undefined;
    let ok = true;
    for (const i of 0..agg.membersCount) {
        if (!ok) break;
        const sig = *memberAt(c, agg.membersStart + i);
        if (sig.kind != HxMemberSignature as u8) continue;
        if (sig.type == 0) {   // already reported
            ok = false;
            break;
        }
        const name = tokenText(c, sig.token);
        const index = hxsFindMember(c, type, sig.name);
        const wanted = hxsIfaceSignature(c, sig.decl, iface, type, false);
        if (index < 0 || hxsMemberOf(c, type, index).kind != HxMemberMethod as u8) {
            if (diag != 0xFFFF_FFFF) {
                let text: u8[256] = undefined;
                hintf(c, diag, `\`${typeName(c, type)}\` has no method \`${name}\`; \`${typeName(c, iface)}\` asks for \`${name}\` as \`${typeText(c, wanted, &text)}\``);
            }
            ok = false;
            break;
        }
        if ((symbolOf(c, hxsMemberOf(c, type, index).symbol).flags & (HxSymTemplateMethod as u16)) != 0) {
            if (diag != 0xFFFF_FFFF) hintf(c, diag, `\`${typeName(c, type)}.${name}\` is generic, and a generic method can't fill an interface's slot`);
            ok = false;
            break;
        }
        const method = hxsMethodInstance(c, hxsMemberOf(c, type, index).symbol, type, site);
        const given = symbolOf(c, method).type;
        if (given == 0 || wanted == 0) {
            ok = false;
            break;
        }
        if (!hxsSignatureFits(c, wanted, given)) {
            if (diag != 0xFFFF_FFFF) {
                let wantText: u8[256] = undefined;
                let givenText: u8[256] = undefined;
                hintf(c, diag, `\`${typeName(c, type)}.${name}\` is \`${typeText(c, given, &givenText)}\`, but \`${typeName(c, iface)}\` asks for \`${typeText(c, wanted, &wantText)}\``);
            }
            ok = false;
            break;
        }
        hxsMarkUsed(c, method);
        methods[sig.index] = method;
    }
    if (!ok) return 0;
    const methodsStart = s.implMethods.len;
    unsafe {
        for (const i of 0..agg.fieldCount) {
            if (s.implMethods.len == s.implMethods.cap) {
                hxVecGrowImpl(@ptrCast(*?u8[*], &s.implMethods.items), &s.implMethods.cap, s.implMethods.len + 1, 4);
            }
            s.implMethods.items![s.implMethods.len] = methods[i];
            s.implMethods.len += 1;
        }
        if (s.impls.len == s.impls.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &s.impls.items), &s.impls.cap, s.impls.len + 1, @sizeOf(HxImpl));
        @ptrCast(HxImpl[*], s.impls.items)[s.impls.len] = HxImpl { type, iface, methodsStart: methodsStart };
    }
    s.impls.len += 1;
    return s.impls.len;
}

/**
 * Resolves the interface that a type node names, for `dyn` and `extends`.
 *
 * @param c - The checker context
 * @param node - The type node, such as `Writer`, `io.Writer`, or `Iterator<i32>`
 * @param useText - The NUL-terminated name of the use, such as `` `dyn` ``, for the messages
 * @returns The interface type, or 0 after reporting the error
 *
 * @remarks
 * An unknown name, a type that is not an interface,
 * and a generic interface without type arguments are each reported.
 * A generic instance such as `Iterator<i32>` is instantiated first.
 *
 * @example
 * ```hx
 * // function notInterface(_a: dyn Ok): void {}
 * hxsResolveInterface(c, node, "`dyn`"); // 0, error: `dyn` needs an interface, and `Ok` isn't one
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsResolveInterface(c: *Ctx, node: u32, useText: readonly u8[*]): u32 {
    let use: string = "";
    unsafe {
        let n: usize = 0;
        while (useText[n] != 0) n += 1;
        use = useText[0..n];
    }
    const n = nodeOf(c, node);
    let sym: u32 = 0;
    if (n.kind == NodeKind.Ident) {
        sym = hxsLookup(c, hxsTokName(c, n.token));
    } else if (n.kind == NodeKind.FieldAccess) {
        sym = hxsModuleMember(c, n.a, n.token, true);
        if (sym == 0xFFFF_FFFF) return 0;
    } else if (n.kind == NodeKind.GenericInstance) {   // `Iterator<i32>`
        const t = hxsInstantiateTypeNode(c, node);
        if (t != 0 && typeOf(c, t).kind != TypeKind.Interface) {
            void errorNode(c, node, `${use} needs an interface, found \`${typeName(c, t)}\``);
            return 0;
        }
        return t;
    } else {
        const t = hxsResolveType(c, node);
        if (t != 0) void errorNode(c, node, `${use} needs an interface, found \`${typeName(c, t)}\``);
        return 0;
    }
    const name = tokenText(c, n.token);
    if (sym == 0 || symbolOf(c, sym).kind != HxSymType as u8) {
        if (sym == 0 && hxTypeBuiltin(types(c), name.ptr, @truncate(u32, name.len)) == 0) void errorNode(c, node, `unknown interface \`${name}\``);
        else void errorNode(c, node, `${use} needs an interface, and \`${name}\` isn't one`);
        return 0;
    }
    hxsMarkUsed(c, sym);
    hxsResolveGlobal(c, sym);
    const t = symbolOf(c, sym).type;
    const generic = (symbolOf(c, sym).flags & (HxSymGeneric as u16)) != 0;
    if (t == 0 && generic && nodeOf(c, symbolOf(c, sym).decl).kind == NodeKind.Interface) {
        const diag = errorNode(c, node, `\`${name}\` is generic, so it needs type arguments`);
        hintf(c, diag, `write them in angle brackets, e.g. \`${name}<i32>\``);
        return 0;
    }
    if (t == 0 || typeOf(c, t).kind != TypeKind.Interface) {
        if (t != 0 || generic) void errorNode(c, node, `${use} needs an interface, and \`${name}\` isn't one`);
        return 0;
    }
    infoOf(c, node).type = t;
    return t;
}
