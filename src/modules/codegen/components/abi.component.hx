/**
 * Imports
 */

import { startsWith, endsWith, indexOf } from "std/text";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { AbiKind, Direct } from "@modules/codegen/constants/abi.constant";
import { AbiPart, Leaf } from "@modules/codegen/components/structs/abi-component.struct";
import { Cg, Value, Type } from "@modules/codegen/components/structs/base-component.struct";
import { store, addAttribute, detourBegin, detourEnd, hasValue } from "@modules/codegen/components/base.component";
import { typeOf, symbolOf, param, lower, lowerFunction, llvmName } from "@modules/codegen/components/base.component";
import { fromCString, fnType, call, structType, entryAlloca, load } from "@modules/codegen/components/base.component";

/**
 * Lists the scalars of an aggregate with their offsets.
 *
 * @param cg - The code generator
 * @param t - The LLVM type to list
 * @param offset - The offset of `t` from the start of the outermost aggregate
 * @param out - The list that receives the scalars
 * @param count - The number of scalars in `out`, which grows with each one
 * @returns `false` when the aggregate holds more than the 64 scalars that fit in `out`
 *
 * @remarks
 * Structs and arrays are walked into, so nested aggregates add their own scalars at their own offsets.
 *
 * @since 1.0.0
 */

function leavesOf(cg: *Cg, t: Type, offset: u64, out: *Leaf[64], count: *u32): bool {
    const kind = llvm.LLVMGetTypeKind(t);
    if (kind == llvm.LLVMStructTypeKind) {
        for (const i of 0..llvm.LLVMCountStructElementTypes(t)) {
            if (!leavesOf(cg, llvm.LLVMStructGetTypeAtIndex(t, i), offset + llvm.LLVMOffsetOfElement(cg.layout, t, i), out, count)) return false;
        }
        return true;
    }
    if (kind == llvm.LLVMArrayTypeKind) {
        const elem = llvm.LLVMGetElementType(t);
        const size = llvm.LLVMABISizeOfType(cg.layout, elem);
        for (const i of 0..llvm.LLVMGetArrayLength2(t)) {
            if (!leavesOf(cg, elem, offset + i * size, out, count)) return false;
        }
        return true;
    }
    if (*count == 64) return false;
    out[*count] = Leaf { type: t, offset };
    *count += 1;
    return true;
}

/**
 * Returns the target triple of the module.
 *
 * @param cg - The code generator
 * @returns The triple, such as `arm64-apple-darwin24.0.0`
 *
 * @remarks
 * It reads the triple back from the module rather than from the options,
 * so the classification always matches the target that LLVM compiles for,
 * even when the options leave the choice to this machine.
 *
 * @since 1.0.0
 */

function targetTriple(cg: *Cg): string {
    return fromCString(llvm.LLVMGetTarget(cg.mod));
}

/**
 * Checks whether the target triple of the module starts with a prefix.
 *
 * @param cg - The code generator
 * @param prefix - The start of the triple to look for, such as `x86_64` or `wasm32`
 * @returns `true` when the triple starts with `prefix`
 *
 * @remarks
 * It compares only the start of the triple, so Apple's `arm64` and the `aarch64` spelling need separate checks.
 *
 * @example
 * ```hx
 * // the module targets x86_64-unknown-linux-gnu
 * targetArch(cg, "x86_64");  // true
 * targetArch(cg, "aarch64"); // false
 * ```
 *
 * @since 1.0.0
 */

export function targetArch(cg: *Cg, prefix: string): bool {
    return startsWith(targetTriple(cg), prefix);
}

/**
 * Decides how a value of a type crosses a C function boundary on the target of the module.
 *
 * @param cg - The code generator
 * @param type - The Helix type of the value
 * @param ret - `true` for the result of the function, `false` for an argument
 * @returns How the value travels
 *
 * @remarks
 * Scalars and aggregates of size zero travel directly. For a struct or an array, the rules depend on the target:
 *
 * - **aarch64** - 1 to 4 floats or 1 to 4 doubles (a homogeneous float aggregate) travel as `[n x float]` or
 *   `[n x double]` in vector registers. Otherwise up to 8 bytes travel as `i64` and up to 16 bytes as `[2 x i64]`.
 *   Bigger ones travel by pointer to a copy, and a result comes back through a hidden pointer (`sret`).
 * - **Windows x64** - 1, 2, 4, or 8 bytes travel as an integer of that size.
 *   Anything else travels by pointer to a copy, and a result comes back through `sret`.
 * - **x86-64 SysV** - up to 16 bytes split into eightbytes, each `i64`,
 *   or `double`, `float`, or `<2 x float>` when the eightbyte holds only floats.
 *   Bigger ones travel `byval`, and a result comes back through `sret`.
 * - **wasm32** - a struct of one scalar travels as that scalar.
 *   Anything else travels `byval`, and a result comes back through `sret`.
 *
 * Other targets keep the aggregates, which is correct for structs passed by pointer, as most C APIs do.
 *
 * @since 1.0.0
 */

function abiPart(cg: *Cg, type: u32, ret: bool): AbiPart {
    const t = lower(cg, type);
    const kind = llvm.LLVMGetTypeKind(t);
    if (kind != llvm.LLVMStructTypeKind && kind != llvm.LLVMArrayTypeKind) return Direct;
    const size = llvm.LLVMABISizeOfType(cg.layout, t);
    if (size == 0) return Direct;
    const i64t = llvm.LLVMInt64TypeInContext(cg.ctx);
    let leaves: Leaf[64] = undefined;
    let count: u32 = 0;
    const listed = leavesOf(cg, t, 0, &leaves, &count);
    const byPointer = AbiPart { kind: ret ? AbiKind.Pointer : AbiKind.Byval, type: null };

    if (targetArch(cg, "x86_64") && indexOf(targetTriple(cg), "windows") != null) {
        // Microsoft x64: 1, 2, 4 or 8 bytes travel as an integer of that size; anything else by pointer to a copy
        if (size == 1 || size == 2 || size == 4 || size == 8) {
            return AbiPart { kind: AbiKind.Coerce, type: llvm.LLVMIntTypeInContext(cg.ctx, @truncate(u32, size * 8)) };
        }
        return AbiPart { kind: AbiKind.Pointer, type: null };
    }
    if (targetArch(cg, "arm64") || targetArch(cg, "aarch64")) {
        if (listed && count >= 1 && count <= 4) {   // a homogeneous float aggregate
            const first = llvm.LLVMGetTypeKind(leaves[0].type);
            let same = first == llvm.LLVMFloatTypeKind || first == llvm.LLVMDoubleTypeKind;
            for (const i of 1..count) {
                if (same) same = llvm.LLVMGetTypeKind(leaves[i].type) == first;
            }
            if (same) return AbiPart { kind: AbiKind.Coerce, type: llvm.LLVMArrayType2(leaves[0].type, count as u64) };
        }
        if (size > 16) return AbiPart { kind: AbiKind.Pointer, type: null };
        return AbiPart { kind: AbiKind.Coerce, type: size <= 8 ? i64t : llvm.LLVMArrayType2(i64t, 2) };
    }
    if (targetArch(cg, "x86_64")) {
        if (size > 16 || !listed) return byPointer;
        let parts: Type[2] = [null, null];
        const eightbytes = @truncate(u32, (size + 7) / 8);
        for (const e of 0..eightbytes) {
            let floats: u32 = 0;
            let doubles: u32 = 0;
            let others: u32 = 0;
            for (const i of 0..count) {
                if (leaves[i].offset / 8 != (e as u64)) continue;
                const k = llvm.LLVMGetTypeKind(leaves[i].type);
                if (k == llvm.LLVMFloatTypeKind) floats += 1;
                else if (k == llvm.LLVMDoubleTypeKind) doubles += 1;
                else others += 1;
            }
            const f32t = llvm.LLVMFloatTypeInContext(cg.ctx);
            if (others != 0 || (floats == 0 && doubles == 0)) parts[e] = i64t;
            else if (doubles != 0) parts[e] = llvm.LLVMDoubleTypeInContext(cg.ctx);
            else if (floats == 2) parts[e] = llvm.LLVMVectorType(f32t, 2);
            else parts[e] = f32t;
        }
        return AbiPart { kind: AbiKind.Coerce, type: eightbytes == 1 ? parts[0] : structType(cg, &parts) };
    }
    if (targetArch(cg, "wasm32")) {
        if (listed && count == 1) return AbiPart { kind: AbiKind.Coerce, type: leaves[0].type };
        return byPointer;
    }
    return Direct;
}

/**
 * Checks whether a function type passes or returns anything that needs the C ABI's treatment.
 *
 * @param cg - The code generator
 * @param fn - The Helix function type
 * @returns `true` when the result or any parameter travels other than directly
 *
 * @remarks
 * A function type for which this is `false` has the same LLVM signature in Helix and in C,
 * so calls to it and pointers to it need no translation.
 *
 * @example
 * ```hx
 * // on aarch64, where struct Pair { a: i32, b: i32 } travels as an i64
 * needsCAbi(cg, symbolOf(cg, add).type);  // false for function add(a: i32, b: i32): i32
 * needsCAbi(cg, symbolOf(cg, take).type); // true for function take(p: Pair): void
 * ```
 *
 * @see emitCCall
 * @since 1.0.0
 */

export function needsCAbi(cg: *Cg, fn: u32): bool {
    const t = typeOf(cg, fn);
    if (abiPart(cg, t.child, true).kind != AbiKind.Direct) return true;
    for (const i of 0..t.len) {
        if (abiPart(cg, param(cg, t, i), false).kind != AbiKind.Direct) return true;
    }
    return false;
}

/**
 * Builds the C ABI's LLVM signature for a function type.
 *
 * @param cg - The code generator
 * @param fn - The Helix function type
 * @param ret - Receives how the result travels
 * @param params - Receives how each parameter travels
 * @returns The LLVM function type
 *
 * @remarks
 * A result that travels by pointer becomes a leading pointer parameter, and the function then returns `void`.
 * The variadic flag of the function type carries over.
 *
 * @since 1.0.0
 */

function cFunctionType(cg: *Cg, fn: u32, ret: *AbiPart, params: *AbiPart[256]): Type {
    const t = typeOf(cg, fn);
    let types: Type[258] = undefined;
    let n: usize = 0;
    *ret = abiPart(cg, t.child, true);
    if (ret.kind == AbiKind.Pointer) {
        types[n] = cg.ptrType;
        n += 1;
    }
    for (const i of 0..t.len) {
        const p = param(cg, t, i);
        params[i] = abiPart(cg, p, false);
        types[n] = params[i].kind == AbiKind.Direct ? lower(cg, p) : params[i].kind == AbiKind.Coerce ? params[i].type : cg.ptrType;
        n += 1;
    }
    const result = ret.kind == AbiKind.Pointer ? llvm.LLVMVoidTypeInContext(cg.ctx) : ret.kind == AbiKind.Coerce ? ret.type : lower(cg, t.child);
    const all: *Type[258] = &types;
    return fnType(result, all[0..n], (t.flags & 0x04) != 0);
}

/**
 * Adds `sret(T)` and `byval(T)` to the parameters of a function or the arguments of a call.
 *
 * @param cg - The code generator
 * @param fnOrCall - The function or the call instruction
 * @param isCall - `true` when `fnOrCall` is a call
 * @param fn - The Helix function type
 * @param ret - How the result travels
 * @param params - How each parameter travels
 *
 * @remarks
 * The attributes go on parameter indexes counted from 1, past the `sret` pointer when there is one.
 *
 * @since 1.0.0
 */

function abiAttributes(cg: *Cg, fnOrCall: Value, isCall: bool, fn: u32, ret: readonly *AbiPart, params: readonly *AbiPart[256]): void {
    const t = typeOf(cg, fn);
    let index: u32 = 1;
    if (ret.kind == AbiKind.Pointer) {
        const sret = llvm.LLVMCreateTypeAttribute(cg.ctx, llvm.LLVMGetEnumAttributeKindForName("sret", 4), lower(cg, t.child));
        if (isCall) llvm.LLVMAddCallSiteAttribute(fnOrCall, index, sret);
        else llvm.LLVMAddAttributeAtIndex(fnOrCall, index, sret);
        index += 1;
    }
    for (const i of 0..t.len) {
        if (params[i].kind == AbiKind.Byval) {
            const byval = llvm.LLVMCreateTypeAttribute(cg.ctx, llvm.LLVMGetEnumAttributeKindForName("byval", 5), lower(cg, param(cg, t, i)));
            if (isCall) llvm.LLVMAddCallSiteAttribute(fnOrCall, index, byval);
            else llvm.LLVMAddAttributeAtIndex(fnOrCall, index, byval);
        }
        index += 1;
    }
}

/**
 * Reinterprets a value as another LLVM type through a stack slot.
 *
 * @param cg - The code generator
 * @param v - The value to reinterpret
 * @param from - The LLVM type of `v`
 * @param to - The LLVM type to read it back as
 * @returns The same bytes as a value of `to`
 *
 * @remarks
 * The slot is big enough for either type and aligned to 16 bytes, so the store and the load both stay inside it.
 *
 * @since 1.0.0
 */

function reinterpret(cg: *Cg, v: Value, from: Type, to: Type): Value {
    const bigger = llvm.LLVMABISizeOfType(cg.layout, from) >= llvm.LLVMABISizeOfType(cg.layout, to) ? from : to;
    const slot = entryAlloca(cg, bigger, "abi");
    llvm.LLVMSetAlignment(slot, 16);
    store(cg, v, slot);
    return load(cg, to, slot, "");
}

/**
 * Emits a call to an `extern "C"` function whose arguments or result follow the C ABI.
 *
 * @param cg - The code generator
 * @param fn - The Helix function type of the callee
 * @param target - The function or function pointer to call
 * @param values - The arguments, lowered as Helix passes them
 * @returns The result of the call as Helix lowers it, or the call itself when it returns nothing
 *
 * @remarks
 * Each argument is coerced, copied to the stack, or passed as it is, as {@link abiPart} decides.
 * The variadic part of the arguments is already promoted and passes as it is.
 * A result that comes back through `sret` lands in a stack slot, and a coerced one is reinterpreted back.
 *
 * @example
 * ```hx
 * // extern "C" function make(a: i32, b: i32): Pair;   on aarch64
 * emitCCall(cg, makeType, make, args); // %call = call i64 @make(...), read back as { i32, i32 }
 * ```
 *
 * @see declareCFunction
 * @since 1.0.0
 */

export function emitCCall(cg: *Cg, fn: u32, target: Value, values: readonly Value[]): Value {
    const t = typeOf(cg, fn);
    let ret = Direct;
    let params: AbiPart[256] = undefined;
    const fnT = cFunctionType(cg, fn, &ret, &params);
    let args: Value[258] = undefined;
    let n: usize = 0;
    let resultSlot: Value = null;
    if (ret.kind == AbiKind.Pointer) {
        resultSlot = entryAlloca(cg, lower(cg, t.child), "sret");
        args[n] = resultSlot;
        n += 1;
    }
    for (const v, i of values) {
        if ((i as u64) >= t.len) {   // the variadic part: already promoted, passed as is
            args[n] = v;
            n += 1;
            continue;
        }
        const p = param(cg, t, i as u64);
        switch (params[i].kind) {
            case AbiKind.Direct: args[n] = v;
            case AbiKind.Coerce: args[n] = reinterpret(cg, v, lower(cg, p), params[i].type);
            default: {
                const copy = entryAlloca(cg, lower(cg, p), "arg");
                store(cg, v, copy);
                args[n] = copy;
            }
        }
        n += 1;
    }
    const returns = ret.kind != AbiKind.Pointer && hasValue(cg, t.child);
    const all: *Value[258] = &args;
    const result = call(cg, fnT, target, all[0..n], returns ? "call" : "");
    abiAttributes(cg, result, true, fn, &ret, &params);
    if (ret.kind == AbiKind.Pointer) return load(cg, lower(cg, t.child), resultSlot, "");
    if (ret.kind == AbiKind.Coerce) return reinterpret(cg, result, ret.type, lower(cg, t.child));
    return result;
}

/**
 * Declares an `extern "C"` function with the C ABI's signature for its type.
 *
 * @param cg - The code generator
 * @param name - The C name of the function
 * @param fn - The Helix function type
 * @returns The LLVM function, with its `sret` and `byval` attributes
 *
 * @remarks
 * Use it for a C function without a Helix body, which code generation calls through {@link emitCCall}.
 * The attributes that it adds tell LLVM which parameters are hidden result pointers or copies passed by pointer.
 *
 * @example
 * ```hx
 * // extern "C" function make(a: i32, b: i32): Pair;   on aarch64
 * declareCFunction(cg, "make", makeType); // declare i64 @make(i32, i32)
 * ```
 *
 * @see emitCCall
 * @since 1.0.0
 */

export function declareCFunction(cg: *Cg, name: readonly u8[*], fn: u32): Value {
    let ret = Direct;
    let params: AbiPart[256] = undefined;
    const f = llvm.LLVMAddFunction(cg.mod, name, cFunctionType(cg, fn, &ret, &params));
    abiAttributes(cg, f, false, fn, &ret, &params);
    return f;
}

/**
 * Makes the C entry point of a Helix function.
 *
 * @param cg - The code generator
 * @param sym - The symbol of the Helix function
 * @param name - The name of the entry point
 * @param internal - `true` to give the entry point internal linkage
 * @returns The entry point
 *
 * @remarks
 * The entry point unpacks what C passes, calls the Helix-ABI function, and packs the result.
 * It is named after an `extern "C"` function's own name,
 * or `<function>.c` and internal for a Helix function passed to C as a callback.
 * It is made once. A C header may declare the same name too, in which case the declaration gets the body.
 *
 * @since 1.0.0
 */

function cEntryPoint(cg: *Cg, sym: u32, name: readonly u8[*], internal: bool): Value {
    const fn = symbolOf(cg, sym).type;
    const t = typeOf(cg, fn);
    let ret = Direct;
    let params: AbiPart[256] = undefined;
    const wrapperType = cFunctionType(cg, fn, &ret, &params);
    let wrapper = llvm.LLVMGetNamedFunction(cg.mod, name);   // a C header may declare it too
    if (wrapper != null && llvm.LLVMCountBasicBlocks(wrapper) != 0) return wrapper;
    if (wrapper == null) {
        wrapper = llvm.LLVMAddFunction(cg.mod, name, wrapperType);
        abiAttributes(cg, wrapper, false, fn, &ret, &params);
    }
    if (internal) llvm.LLVMSetLinkage(wrapper, llvm.LLVMInternalLinkage);
    addAttribute(cg, wrapper, "nounwind");

    const saved = detourBegin(cg, wrapper);
    let values: Value[256] = undefined;
    let index: u32 = ret.kind == AbiKind.Pointer ? 1 : 0;
    for (const i of 0..t.len) {
        const p = param(cg, t, i);
        const v = llvm.LLVMGetParam(wrapper, index);
        values[i] = params[i].kind == AbiKind.Direct ? v
                  : params[i].kind == AbiKind.Coerce ? reinterpret(cg, v, params[i].type, lower(cg, p))
                  : load(cg, lower(cg, p), v, "");
        index += 1;
    }
    const returns = hasValue(cg, t.child);
    const all: *Value[256] = &values;
    const result = call(cg, lowerFunction(cg, fn), cg.storage[sym], all[0..t.len], returns ? "result" : "");
    if (t.child == cg.types.noreturnType) {
        void llvm.LLVMBuildUnreachable(cg.b);
    } else if (!returns) {
        void llvm.LLVMBuildRetVoid(cg.b);
    } else if (ret.kind == AbiKind.Pointer) {
        store(cg, result, llvm.LLVMGetParam(wrapper, 0));
        void llvm.LLVMBuildRetVoid(cg.b);
    } else if (ret.kind == AbiKind.Coerce) {
        void llvm.LLVMBuildRet(cg.b, reinterpret(cg, result, lower(cg, t.child), ret.type));
    } else {
        void llvm.LLVMBuildRet(cg.b, result);
    }
    detourEnd(cg, saved);
    return wrapper;
}

/**
 * Returns the name of an LLVM value.
 *
 * @param v - The value
 * @returns The name, such as `test.add`
 *
 * @remarks
 * The text borrows LLVM's copy of the name, so it stays valid only while the value keeps that name.
 *
 * @since 1.0.0
 */

function valueName(v: Value): string {
    return fromCString(llvm.LLVMGetValueName(v));
}

/**
 * Emits the C entry point of an `extern "C"` function with a body whose signature needs the C ABI.
 *
 * @param cg - The code generator
 * @param sym - The symbol of the function
 *
 * @remarks
 * The Helix-ABI body is named `<name>.helix`, and the entry point takes the C name without that suffix.
 *
 * @example
 * ```hx
 * // export extern "C" function make(a: i32, b: i32): Pair { ... }   on aarch64
 * emitCWrapper(cg, sym); // define i64 @make(i32, i32), which calls @make.helix
 * ```
 *
 * @see cCallable
 * @since 1.0.0
 */

export function emitCWrapper(cg: *Cg, sym: u32): void {
    const name = valueName(cg.storage[sym]);
    void cEntryPoint(cg, sym, llvmName(cg, `${name[0..name.len - 6]}`), false);   // without `.helix`
}

/**
 * Returns a function as a C function pointer.
 *
 * @param cg - The code generator
 * @param sym - The symbol of the function
 * @returns The function itself, or a C entry point that calls it
 *
 * @remarks
 * A C function, or a function that C and Helix pass alike, is its own C function pointer.
 * Otherwise an `export extern "C"` function with a body gets its C name,
 * and any other function gets an internal entry point named `<function>.c`.
 *
 * @example
 * ```hx
 * // function onPair(p: Pair): void   passed to C as a callback, on aarch64
 * cCallable(cg, sym); // @onPair.c, which takes an i64 and calls @onPair
 * ```
 *
 * @see emitCWrapper
 * @since 1.0.0
 */

export function cCallable(cg: *Cg, sym: u32): Value {
    if (cg.cAbi[sym] || !needsCAbi(cg, symbolOf(cg, sym).type)) return cg.storage[sym];   // a C function, or no difference
    const name = valueName(cg.storage[sym]);
    if (name.len > 6 && endsWith(name, ".helix")) {   // `export extern "C"` with a body: its C name
        return cEntryPoint(cg, sym, llvmName(cg, `${name[0..name.len - 6]}`), false);
    }
    return cEntryPoint(cg, sym, llvmName(cg, `${name}.c`), true);
}
