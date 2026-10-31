/**
 * Imports
 */

import { equal } from "std/text";
import { record } from "@models/ast.model";
import { HxImpl } from "@structs/sema.struct";
import { hxNameText } from "@services/intern.service";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { HxCatchData } from "@models/structs/ast-model.struct";
import { TypeKind, Signed, CCall } from "@constants/types.constant";
import { emitCCall } from "@modules/codegen/components/abi.component";
import { emitExpect } from "@modules/codegen/components/expect.component";
import { elementPointer, extract } from "@modules/codegen/components/base.component";
import { Indexable } from "@modules/codegen/components/structs/expr-component.struct";
import { emitScoped, emitDefers, emitStmt } from "@modules/codegen/components/stmt.component";
import { Cg, Value, Type, Block } from "@modules/codegen/components/structs/base-component.struct";
import { NodeKind, BinOp, FlagInclusive, FlagPointer, FlagComptime } from "@constants/ast.constant";
import { isSigned, errorUnionCode, errorUnionPayload } from "@modules/codegen/components/base.component";
import { declareC, llvmBool, knownCondition, emitCheck } from "@modules/codegen/components/base.component";
import { emitPrint, emitFormatWrite, emitFormatValue } from "@modules/codegen/components/format.component";
import { HxMemberSignature, HxInfoDyn, HxInfoReceiverAddr, HxInfoIndirect } from "@constants/sema.constant";
import { emitPanic, insert, load, store, branch, condBr } from "@modules/codegen/components/base.component";
import { HxCaseData, HxRange, HxFnData, HxSliceData, HxTernaryData } from "@models/structs/ast-model.struct";
import { compareIntegers, lower, lowerFunction, constInt } from "@modules/codegen/components/base.component";
import { emitConst, aggregate, member, tokenText, finalType } from "@modules/codegen/components/base.component";
import { int1Type, int32, fnType, call, constArray, phiNode } from "@modules/codegen/components/base.component";
import { optionalSome, constGlobal, cstring, constErrorCode } from "@modules/codegen/components/base.component";
import { errorUnionMake, fromCString, fatal, zeroed, release } from "@modules/codegen/components/base.component";
import { llvmName, errorUnionIsBare, hasValue, callIntrinsic } from "@modules/codegen/components/base.component";
import { HxInfoModuleRef, HxInfoExpect, HxInfoNarrowed, HxInfoDeref, HxInfoPrint } from "@constants/sema.constant";
import { constUsize, constBool, nodeOf, infoOf, typeOf, symbolOf } from "@modules/codegen/components/base.component";
import { emitBoundsCheck, buildPanicHandler, typeName, tokenName } from "@modules/codegen/components/base.component";
import { extra, value, param, startDeadBlock, block, positionAtEnd } from "@modules/codegen/components/base.component";
import { helperFunction, locationString, entryAlloca, localStorage } from "@modules/codegen/components/base.component";
import { HxInfoMethod, HxInfoFormatWrite, HxInfoField, HxMemberField, HxInfoUnionInit } from "@constants/sema.constant";
import { nodeKindName, terminated, optionalPresent, optionalPayload } from "@modules/codegen/components/base.component";

/**
 * The C library function that computes the powers of two for the range checks of float casts.
 *
 * @since 1.0.0
 */

extern "C" function ldexp(x: f64, exp: i32): f64;

/**
 * Builds the LLVM function type that a vtable slot holds.
 *
 * @param cg - The code generator
 * @param signature - The function type of the interface method
 * @returns The method's LLVM function type with a plain pointer as its receiver
 *
 * @remarks
 * A `dyn` value only carries a data pointer, so every method in a vtable takes the receiver as a pointer,
 * whatever the method itself declares.
 *
 * @example
 * ```hx
 * // write(this: *Self, bytes: string): usize
 * slotType(cg, signature); // i64 (ptr, { ptr, i64 })
 * ```
 *
 * @see loadSlot
 * @since 1.0.0
 */

export function slotType(cg: *Cg, signature: u32): Type {
    const f = typeOf(cg, signature);
    let params: Type[256] = undefined;
    params[0] = cg.ptrType;
    for (const i of 1..f.len) params[i] = lower(cg, param(cg, f, i));
    const all: *Type[256] = &params;
    return fnType(lower(cg, f.child), all[0..f.len], false);
}

/**
 * Wraps a method that takes `this: T` by value in a function that takes the pointer a `dyn` holds.
 *
 * @param cg - The code generator
 * @param method - The symbol of the method
 * @param type - The type that implements the interface
 * @returns The wrapper, named after the method with a `.thunk` suffix
 *
 * @remarks
 * The wrapper loads the value from the pointer and passes it on with the other arguments.
 * It is emitted in its own function without a debug location, and the builder then goes back to where it was.
 *
 * @since 1.0.0
 */

function byValueThunk(cg: *Cg, method: u32, type: u32): Value {
    const fnT = symbolOf(cg, method).type;
    const target = cg.storage[method];
    const thunk = helperFunction(cg, llvmName(cg, `${fromCString(llvm.LLVMGetValueName(target))}.thunk`), slotType(cg, fnT));

    const savedBlock = llvm.LLVMGetInsertBlock(cg.b);
    const savedLocation = llvm.LLVMGetCurrentDebugLocation2(cg.b);
    llvm.LLVMSetCurrentDebugLocation2(cg.b, null);
    positionAtEnd(cg, llvm.LLVMAppendBasicBlockInContext(cg.ctx, thunk, "entry"));
    let args: Value[256] = undefined;
    const count = llvm.LLVMCountParams(thunk);
    args[0] = load(cg, lower(cg, type), llvm.LLVMGetParam(thunk, 0), "");
    for (const i of 1..count) args[i] = llvm.LLVMGetParam(thunk, i);
    const ret = typeOf(cg, fnT).child;
    const all: *Value[256] = &args;
    const result = call(cg, lowerFunction(cg, fnT), target, all[0..count], "");
    if (hasValue(cg, ret)) void llvm.LLVMBuildRet(cg.b, result);
    else if (ret == cg.types.noreturnType) void llvm.LLVMBuildUnreachable(cg.b);
    else void llvm.LLVMBuildRetVoid(cg.b);
    if (savedBlock != null) positionAtEnd(cg, savedBlock);
    llvm.LLVMSetCurrentDebugLocation2(cg.b, savedLocation);
    return thunk;
}

/**
 * Finds the implementation of an interface for a type.
 *
 * @param cg - The code generator
 * @param type - The implementing type
 * @param iface - The interface
 * @returns The index of the implementation plus one, or 0 when the type does not implement the interface
 *
 * @remarks
 * It scans the implementations of the checker in order,
 * and {@link vtable} caches what it builds, so the scan runs once per vtable.
 * The index is 1-based so that 0 can mean that the type does not implement the interface.
 *
 * @since 1.0.0
 */

function implIndex(cg: *Cg, type: u32, iface: u32): u32 {
    for (const i of 0..cg.sema.impls.len) {
        unsafe {
            const impl = @ptrCast(HxImpl[*], cg.sema.impls.items)[i];
            if (impl.type == type && impl.iface == iface) return i + 1;
        }
    }
    return 0;
}

/**
 * Gets the vtable of a type as an interface, building it the first time it is needed.
 *
 * @param cg - The code generator
 * @param type - The implementing type
 * @param iface - The interface
 * @returns A constant global array with one function pointer per method of the interface
 *
 * @remarks
 * Each type and interface pair gets one vtable, named `<module>.vtable.<type>.<interface>`.
 * A method that takes its receiver through a pointer goes in directly,
 * and a method that takes it by value goes in through {@link byValueThunk}.
 * A pair without an implementation is an internal error, since the checker allows no such conversion.
 *
 * @since 1.0.0
 */

function vtable(cg: *Cg, type: u32, iface: u32): Value {
    const index = implIndex(cg, type, iface);
    if (index == 0) fatal(cg, `codegen: no impl of \`${typeName(cg, iface)}\` for a dyn conversion`);
    if (cg.vtables[index - 1] != null) return cg.vtables[index - 1];

    let impl: HxImpl = undefined;
    unsafe {
        impl = @ptrCast(HxImpl[*], cg.sema.impls.items)[index - 1];
    }
    const count = aggregate(cg, iface).fieldCount;
    const slots = zeroed<Value>(count);
    for (const i of 0..count) {
        let method: u32 = 0;
        unsafe {
            method = cg.sema.implMethods.items![impl.methodsStart + i];
        }
        const receiver = param(cg, typeOf(cg, symbolOf(cg, method).type), 0);
        slots[i] = typeOf(cg, receiver).kind == TypeKind.Pointer ? cg.storage[method] : byValueThunk(cg, method, type);
    }
    const name = llvmName(cg, `${fromCString(cg.options.module_name)}.vtable.${typeName(cg, type)}.${typeName(cg, iface)}`);
    const global = constGlobal(cg, constArray(cg.ptrType, slots), name);
    release(slots);
    cg.vtables[index - 1] = global;
    return global;
}

/**
 * Finds the signature of the method in a vtable slot of an interface.
 *
 * @param cg - The code generator
 * @param iface - The interface
 * @param slot - The slot index, which is the method's position in the interface
 * @returns The function type of the method, or 0 when the interface has no such slot
 *
 * @remarks
 * The slot is the position of the method in the interface declaration, which the checker records on the call node.
 * It gives 0 when no signature has that slot, which the checker rules out for a well-formed call.
 *
 * @example
 * ```hx
 * // interface Writer { write(this: *Self, bytes: string): usize; }
 * slotSignature(cg, writer, 0); // the type of write
 * ```
 *
 * @see slotType
 * @since 1.0.0
 */

export function slotSignature(cg: *Cg, iface: u32, slot: u32): u32 {
    const agg = aggregate(cg, iface);
    for (const i of 0..agg.membersCount) {
        const m = member(cg, agg, i);
        if (m.kind == HxMemberSignature as u8 && m.index == slot) return m.type;
    }
    return 0;
}

/**
 * Loads the method in a vtable slot of a `dyn` value.
 *
 * @param cg - The code generator
 * @param d - The `dyn` value, a pair of a data pointer and a vtable pointer
 * @param slot - The slot index
 * @returns The function pointer in the slot
 *
 * @remarks
 * The load carries `invariant.load` metadata, since a vtable never changes,
 * which lets LLVM reuse one load for several calls.
 *
 * @example
 * ```hx
 * loadSlot(cg, d, 0); // %method = load ptr, ptr %slot, !invariant.load
 * ```
 *
 * @see slotType
 * @since 1.0.0
 */

export function loadSlot(cg: *Cg, d: Value, slot: u32): Value {
    const table = extract(cg, d, 1, "vtable");
    const indices: Value[1] = [constUsize(cg, slot as u64)];
    let address: Value = null;
    unsafe {
        address = llvm.LLVMBuildGEP2(cg.b, cg.ptrType, table, @ptrCast(?Value[*], &indices), 1, "");
    }
    const target = load(cg, cg.ptrType, address, "method");
    const empty = llvm.LLVMMetadataAsValue(cg.ctx, llvm.LLVMMDNodeInContext2(cg.ctx, null, 0));
    llvm.LLVMSetMetadata(target, llvm.LLVMGetMDKindIDInContext(cg.ctx, "invariant.load", 14), empty);   // vtables never change
    return target;
}

/**
 * Emits a method call on a `dyn` value, such as `w.write(bytes)` on a `dyn Writer`.
 *
 * @param cg - The code generator
 * @param node - The call node
 * @returns The result of the call, or `null` when the method returns nothing
 *
 * @remarks
 * The method comes from the vtable, and the data pointer of the `dyn` is its first argument.
 * A call to a `noreturn` method ends the block with `unreachable`.
 *
 * @since 1.0.0
 */

function emitDynCall(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const info = infoOf(cg, node);
    const args = record<HxRange>(cg.ast, n.b);
    const receiver = nodeOf(cg, n.a).a;
    const signature = slotSignature(cg, typeOf(cg, finalType(cg, receiver)).child, info.aux);

    const d = emitValue(cg, receiver);
    let values: Value[257] = undefined;
    let count: u32 = 0;
    values[count] = extract(cg, d, 0, "data");
    count += 1;
    for (const i of args.start..args.end) {
        if (count >= 256) break;
        values[count] = emitValue(cg, extra(cg, i));
        count += 1;
    }
    const target = loadSlot(cg, d, info.aux);
    const ret = typeOf(cg, signature).child;
    const all: *Value[257] = &values;
    const result = call(cg, slotType(cg, signature), target, all[0..count], hasValue(cg, ret) ? "call" : "");
    if (ret == cg.types.noreturnType) {
        void llvm.LLVMBuildUnreachable(cg.b);
        startDeadBlock(cg);
        return null;
    }
    return hasValue(cg, ret) ? result : null;
}

/**
 * Computes the smallest signed integer of a bit width, -2^(bits-1).
 *
 * @param bits - The bit width
 * @returns The smallest value, worked out in two halves so that 128 bits does not overflow
 *
 * @remarks
 * It builds the value from two halves, so even a 128-bit width never shifts a one into the sign bit.
 * A width below 2 gives -1, the minimum of a 1-bit signed integer.
 *
 * @since 1.0.0
 */

function smallest(bits: u16): i128 {
    if (bits < 2) return -1;
    const half = (1 as i128) << (bits - 2);
    return -half - half;
}

/**
 * Computes 2^bits - 1, the largest value with a number of magnitude bits.
 *
 * @param bits - The number of magnitude bits, up to 127
 * @returns The largest value, worked out in two halves so that 127 bits does not overflow
 *
 * @remarks
 * It adds two halves for the same reason as {@link smallest}, so a width of 127 stays within `i128`.
 * The range check of an integer cast compares against it as the upper bound of the target type.
 *
 * @since 1.0.0
 */

function allOnes(bits: u16): i128 {
    if (bits == 0) return 0;
    const half = (1 as i128) << (bits - 1);
    return (half - 1) + half;
}

/**
 * Emits the range check of an integer cast, which panics when the value does not fit in the target type.
 *
 * @param cg - The code generator
 * @param v - The value to convert
 * @param from - The source integer type
 * @param to - The target integer type
 * @param node - The cast node, for the panic's location
 *
 * @remarks
 * A signed value is checked against the lower bound when the target is unsigned or narrower,
 * and against the upper bound when the target has fewer magnitude bits.
 * A cast that always fits, such as `u8` to `i32`, emits no check.
 *
 * @since 1.0.0
 */

function checkIntFits(cg: *Cg, v: Value, from: u32, to: u32, node: u32): void {
    const f = typeOf(cg, from);
    const t = typeOf(cg, to);
    const fromSigned = (f.flags & Signed) != 0;
    const toSigned = (t.flags & Signed) != 0;
    const type = lower(cg, from);
    let failed: Value = null;

    if (fromSigned && (!toSigned || t.bits < f.bits)) {
        let min: i128 = 0;
        if (toSigned) min = smallest(t.bits);
        failed = compareIntegers(cg, llvm.LLVMIntSLT, v, constInt(type, min));
    }
    const toMagnitude: u16 = toSigned ? t.bits - 1 : t.bits;
    const fromMagnitude: u16 = fromSigned ? f.bits - 1 : f.bits;
    if (toMagnitude < fromMagnitude) {
        const max = allOnes(toMagnitude);
        const above = compareIntegers(cg, fromSigned ? llvm.LLVMIntSGT : llvm.LLVMIntUGT, v, constInt(type, max));
        failed = failed != null ? llvm.LLVMBuildOr(cg.b, failed, above, "") : above;
    }
    if (failed == null) return;
    emitCheck(cg, failed, node, fromCString(llvmName(cg, `integer cast out of range: the value doesn't fit in \`${typeName(cg, to)}\``)));
}

/**
 * Emits the range check of a float to integer cast, which panics when the value does not fit in the target type.
 *
 * @param cg - The code generator
 * @param v - The float value to convert
 * @param from - The source float type
 * @param to - The target integer type
 * @param node - The cast node, for the panic's location
 *
 * @remarks
 * The value must lie in the range that truncating toward zero maps into the target.
 * Ordered comparisons are false for NaN, so NaN fails the check too.
 *
 * @since 1.0.0
 */

function checkFloatFits(cg: *Cg, v: Value, from: u32, to: u32, node: u32): void {
    const t = typeOf(cg, to);
    const type = lower(cg, from);
    const toSigned = (t.flags & Signed) != 0;
    const lo = toSigned ? -ldexp(1.0, (t.bits - 1) as i32) : -1.0;
    const hi = ldexp(1.0, (toSigned ? t.bits - 1 : t.bits) as i32);

    // Ordered comparisons are false for NaN, so NaN fails the check too.
    const aboveLo = llvm.LLVMBuildFCmp(cg.b, toSigned ? llvm.LLVMRealOGE : llvm.LLVMRealOGT, v, llvm.LLVMConstReal(type, lo), "");
    const belowHi = llvm.LLVMBuildFCmp(cg.b, llvm.LLVMRealOLT, v, llvm.LLVMConstReal(type, hi), "");
    const ok = llvm.LLVMBuildAnd(cg.b, aboveLo, belowHi, "");
    emitCheck(cg, llvm.LLVMBuildNot(cg.b, ok, ""), node, fromCString(llvmName(cg, `float cast out of range: the value doesn't fit in \`${typeName(cg, to)}\``)));
}

/**
 * Converts a value from one type to another.
 *
 * @param cg - The code generator
 * @param v - The value to convert, where `null` comes back unchanged
 * @param from - The type of the value
 * @param to - The type to convert to
 * @param node - The node that converts, for the location of a failed check
 * @param checked - Whether an `as` cast asks for range checks, which only safe builds emit
 * @returns The converted value
 *
 * @remarks
 * The conversions follow the memory layouts of the types:
 * - **Optionals** - `null` becomes the null constant, and a plain value is wrapped as present.
 * - **Error unions** - an error becomes an error union with an undefined payload,
 *   and a plain value becomes one with the success code 0.
 * - **Integers** - widened by sign or zero extension, narrowed by truncation, or turned into floats.
 * - **Floats** - widened, narrowed, or turned into integers.
 * - **Pointers** - a pointer to a struct becomes a `dyn` with the vtable of its type,
 *   and a pointer to an array becomes a slice of the whole array.
 *
 * An enum converts through its backing integer, and `bool` widens with zero extension.
 * Anything else, such as a mutable pointer to a readonly one, keeps its representation.
 *
 * @example
 * ```hx
 * // const n = x as u8;   x: i32
 * convert(cg, v, i32Type, u8Type, node, true); // a range check, then trunc i32 to i8
 * ```
 *
 * @since 1.0.0
 */

export function convert(cg: *Cg, v: Value, from: u32, to: u32, node: u32, checked: bool): Value {
    if (from == to || v == null) return v;
    const f = typeOf(cg, from);
    const t = typeOf(cg, to);
    const target = lower(cg, to);

    if (t.kind == TypeKind.Optional) {
        if (f.kind == TypeKind.Null) return llvm.LLVMConstNull(target);
        if (f.kind == TypeKind.Optional) return v;
        return optionalSome(cg, convert(cg, v, from, t.child, node, checked), to);
    }
    if (t.kind == TypeKind.ErrorUnion) {
        if (f.kind == TypeKind.ErrorUnion) return v;   // same layout; only the error set differs
        if (f.kind == TypeKind.ErrorSet) {
            const payload = errorUnionIsBare(cg, to) ? null : llvm.LLVMGetUndef(lower(cg, t.child));
            return errorUnionMake(cg, payload, v, to);
        }
        const payload = convert(cg, v, from, t.child, node, checked);
        return errorUnionMake(cg, payload, constErrorCode(cg, 0), to);
    }

    switch (f.kind) {
        case TypeKind.Noreturn, TypeKind.Undefined: return llvm.LLVMGetUndef(target);
        case TypeKind.Bool: return llvm.LLVMBuildZExt(cg.b, v, target, "");
        case TypeKind.Enum: return convert(cg, v, f.child, to, node, checked);   // `role as u8`: the backing integer
        case TypeKind.Int: {
            if (t.kind == TypeKind.Float) {
                return (f.flags & Signed) != 0 ? llvm.LLVMBuildSIToFP(cg.b, v, target, "") : llvm.LLVMBuildUIToFP(cg.b, v, target, "");
            }
            if (checked && cg.safe) checkIntFits(cg, v, from, to, node);
            if (t.bits > f.bits) return (f.flags & Signed) != 0 ? llvm.LLVMBuildSExt(cg.b, v, target, "") : llvm.LLVMBuildZExt(cg.b, v, target, "");
            if (t.bits < f.bits) return llvm.LLVMBuildTrunc(cg.b, v, target, "");
            return v;
        }
        case TypeKind.Float: {
            if (t.kind == TypeKind.Int) {
                if (checked && cg.safe) checkFloatFits(cg, v, from, to, node);
                return (t.flags & Signed) != 0 ? llvm.LLVMBuildFPToSI(cg.b, v, target, "") : llvm.LLVMBuildFPToUI(cg.b, v, target, "");
            }
            if (t.bits > f.bits) return llvm.LLVMBuildFPExt(cg.b, v, target, "");
            if (t.bits < f.bits) return llvm.LLVMBuildFPTrunc(cg.b, v, target, "");
            return v;
        }
        case TypeKind.Pointer: {
            if (t.kind == TypeKind.Dyn) {
                const d = insert(cg, llvm.LLVMGetUndef(cg.dynType), v, 0);
                return insert(cg, d, vtable(cg, f.child, t.child), 1);
            }
            if (t.kind == TypeKind.Slice) {   // `&array` as a slice of the whole array
                const slice = insert(cg, llvm.LLVMGetUndef(cg.sliceType), v, 0);
                return insert(cg, slice, constUsize(cg, typeOf(cg, f.child).len), 1);
            }
            return v;
        }
        default: return v;   // mutable -> readonly is the same representation
    }
}

/**
 * Emits an arithmetic operation through an LLVM overflow intrinsic, then a check that panics on overflow.
 *
 * @param cg - The code generator
 * @param signedName - The intrinsic for a signed type, such as `llvm.sadd.with.overflow`
 * @param unsignedName - The intrinsic for an unsigned type
 * @param a - The left operand
 * @param b - The right operand
 * @param type - The operand type
 * @param node - The operator node, for the panic's location
 * @returns The result of the operation
 *
 * @remarks
 * Only safe builds call it, while other builds emit an `nsw` or `nuw` operation that leaves overflow undefined.
 * The intrinsic name follows the signedness of the type, since signed and unsigned overflow differ.
 *
 * @since 1.0.0
 */

function emitChecked(cg: *Cg, signedName: string, unsignedName: string, a: Value, b: Value, type: u32, node: u32): Value {
    const args: Value[2] = [a, b];
    const pair = callIntrinsic(cg, isSigned(cg, type) ? signedName : unsignedName, llvm.LLVMTypeOf(a), &args);
    const result = extract(cg, pair, 0, "");
    emitCheck(cg, extract(cg, pair, 1, ""), node, "integer overflow");
    return result;
}

/**
 * Emits a shift, converting the amount to the width of the value.
 *
 * @param cg - The code generator
 * @param op - The operator, `Shl` or `Shr`
 * @param a - The value to shift
 * @param b0 - The shift amount
 * @param type - The type of the value
 * @param node - The operator node, for the panic's location
 * @returns The shifted value
 *
 * @remarks
 * Safe builds panic when the amount is not less than the bit width.
 * An amount type too narrow to ever reach the width, such as `u3` for a `u8`, needs no check.
 * A right shift is arithmetic for a signed type and logical for an unsigned one.
 *
 * @since 1.0.0
 */

function emitShift(cg: *Cg, op: BinOp, a: Value, b0: Value, type: u32, node: u32): Value {
    let b = b0;
    const llvmType = llvm.LLVMTypeOf(a);
    const bits = typeOf(cg, type).bits as u32;
    const amountBits = llvm.LLVMGetIntTypeWidth(llvm.LLVMTypeOf(b));

    // An amount type too narrow to ever reach `bits` (like `u3` for a `u8`) needs no check.
    const canFail = amountBits >= 32 || ((1 as u64) << amountBits) - 1 >= (bits as u64);
    if (cg.safe && canFail) {
        const failed = compareIntegers(cg, llvm.LLVMIntUGE, b, llvm.LLVMConstInt(llvm.LLVMTypeOf(b), bits as u64, 0));
        emitCheck(cg, failed, node, fromCString(llvmName(cg, `shift amount is too large: it must be less than ${bits}`)));
    }
    if (amountBits > bits) b = llvm.LLVMBuildTrunc(cg.b, b, llvmType, "");
    else if (amountBits < bits) b = llvm.LLVMBuildZExt(cg.b, b, llvmType, "");

    if (op == BinOp.Shl) return llvm.LLVMBuildShl(cg.b, a, b, "");
    return isSigned(cg, type) ? llvm.LLVMBuildAShr(cg.b, a, b, "") : llvm.LLVMBuildLShr(cg.b, a, b, "");
}

/**
 * Emits an arithmetic or bitwise operator on two values already converted to the same type.
 *
 * @param cg - The code generator
 * @param op - The operator
 * @param a - The left operand
 * @param b - The right operand
 * @param type - The type of both operands
 * @param node - The operator node, for the location of a failed check
 * @returns The result of the operation
 *
 * @remarks
 * Floats support `+`, `-`, `*`, and `/` without checks.
 * For integers, safe builds check `+`, `-`, and `*` for overflow,
 * and check `/` and `%` for a zero divisor and for the one signed overflow, the smallest value divided by -1.
 * Other builds mark `+`, `-`, and `*` with `nsw` or `nuw` instead.
 * The wrapping operators `+%`, `-%`, and `*%` never check, and the saturating operators `+|`, `-|`, and `*|`
 * call the LLVM saturation intrinsics.
 * An operator without a lowering is an internal error.
 *
 * @example
 * ```hx
 * // a + b   a, b: i32, debug build
 * emitArith(cg, BinOp.Add, a, b, i32Type, node); // llvm.sadd.with.overflow.i32 and a panic block
 * ```
 *
 * @see emitCompare
 * @since 1.0.0
 */

export function emitArith(cg: *Cg, op: BinOp, a: Value, b: Value, type: u32, node: u32): Value {
    if (typeOf(cg, type).kind == TypeKind.Float) {
        switch (op) {
            case BinOp.Add: return llvm.LLVMBuildFAdd(cg.b, a, b, "");
            case BinOp.Sub: return llvm.LLVMBuildFSub(cg.b, a, b, "");
            case BinOp.Mul: return llvm.LLVMBuildFMul(cg.b, a, b, "");
            case BinOp.Div: return llvm.LLVMBuildFDiv(cg.b, a, b, "");
            default: fatal(cg, `codegen: float operator ${op as u32} has no lowering`);
        }
    }

    const sign = isSigned(cg, type);
    const pair: Value[2] = [a, b];
    switch (op) {
        case BinOp.Add: {
            if (cg.safe) return emitChecked(cg, "llvm.sadd.with.overflow", "llvm.uadd.with.overflow", a, b, type, node);
            return sign ? llvm.LLVMBuildNSWAdd(cg.b, a, b, "") : llvm.LLVMBuildNUWAdd(cg.b, a, b, "");
        }
        case BinOp.Sub: {
            if (cg.safe) return emitChecked(cg, "llvm.ssub.with.overflow", "llvm.usub.with.overflow", a, b, type, node);
            return sign ? llvm.LLVMBuildNSWSub(cg.b, a, b, "") : llvm.LLVMBuildNUWSub(cg.b, a, b, "");
        }
        case BinOp.Mul: {
            if (cg.safe) return emitChecked(cg, "llvm.smul.with.overflow", "llvm.umul.with.overflow", a, b, type, node);
            return sign ? llvm.LLVMBuildNSWMul(cg.b, a, b, "") : llvm.LLVMBuildNUWMul(cg.b, a, b, "");
        }
        case BinOp.AddWrap: return llvm.LLVMBuildAdd(cg.b, a, b, "");
        case BinOp.SubWrap: return llvm.LLVMBuildSub(cg.b, a, b, "");
        case BinOp.MulWrap: return llvm.LLVMBuildMul(cg.b, a, b, "");
        case BinOp.AddSat: return callIntrinsic(cg, sign ? "llvm.sadd.sat" : "llvm.uadd.sat", llvm.LLVMTypeOf(a), &pair);
        case BinOp.SubSat: return callIntrinsic(cg, sign ? "llvm.ssub.sat" : "llvm.usub.sat", llvm.LLVMTypeOf(a), &pair);
        case BinOp.MulSat: {
            const args: Value[3] = [a, b, llvm.LLVMConstInt(int32(cg), 0, 0)];
            return callIntrinsic(cg, sign ? "llvm.smul.fix.sat" : "llvm.umul.fix.sat", llvm.LLVMTypeOf(a), &args);
        }
        case BinOp.Div, BinOp.Mod: {
            if (cg.safe) {
                const zero = compareIntegers(cg, llvm.LLVMIntEQ, b, llvm.LLVMConstNull(llvm.LLVMTypeOf(b)));
                emitCheck(cg, zero, node, "division by zero");
                if (sign) {
                    const bits = typeOf(cg, type).bits;
                    let minValue: i128 = 0;
                    if (bits >= 128) minValue = @truncate(i128, (1 as u128) << 127);
                    else minValue = -((1 as i128) << (bits - 1));
                    const isMin = compareIntegers(cg, llvm.LLVMIntEQ, a, constInt(llvm.LLVMTypeOf(a), minValue));
                    const isNegOne = compareIntegers(cg, llvm.LLVMIntEQ, b, llvm.LLVMConstAllOnes(llvm.LLVMTypeOf(b)));
                    emitCheck(cg, llvm.LLVMBuildAnd(cg.b, isMin, isNegOne, ""), node, "integer overflow");
                }
            }
            if (op == BinOp.Div) return sign ? llvm.LLVMBuildSDiv(cg.b, a, b, "") : llvm.LLVMBuildUDiv(cg.b, a, b, "");
            return sign ? llvm.LLVMBuildSRem(cg.b, a, b, "") : llvm.LLVMBuildURem(cg.b, a, b, "");
        }
        case BinOp.BitAnd: return llvm.LLVMBuildAnd(cg.b, a, b, "");
        case BinOp.BitOr: return llvm.LLVMBuildOr(cg.b, a, b, "");
        case BinOp.BitXor: return llvm.LLVMBuildXor(cg.b, a, b, "");
        case BinOp.Shl, BinOp.Shr: return emitShift(cg, op, a, b, type, node);
        default: fatal(cg, `codegen: operator ${op as u32} has no lowering`);
    }
}

/**
 * Emits a comparison of two values of the same type.
 *
 * @param cg - The code generator
 * @param op - The comparison operator, from `Eq` to `Ge`
 * @param a - The left operand
 * @param b - The right operand
 * @param type - The type of both operands
 * @returns The `i1` result
 *
 * @remarks
 * Floats use ordered predicates, except `!=`, which is unordered so that NaN is unequal to everything.
 * Signed integers use signed predicates, while unsigned integers, pointers, and other values use unsigned ones.
 *
 * @example
 * ```hx
 * // a < b   a, b: i32
 * emitCompare(cg, BinOp.Lt, a, b, i32Type); // icmp slt i32 %a, %b
 * ```
 *
 * @see emitArith
 * @since 1.0.0
 */

export function emitCompare(cg: *Cg, op: BinOp, a: Value, b: Value, type: u32): Value {
    if (typeOf(cg, type).kind == TypeKind.Float) {
        const pred = switch (op) {
            case BinOp.Eq: llvm.LLVMRealOEQ;
            case BinOp.Ne: llvm.LLVMRealUNE;
            case BinOp.Lt: llvm.LLVMRealOLT;
            case BinOp.Le: llvm.LLVMRealOLE;
            case BinOp.Gt: llvm.LLVMRealOGT;
            default: llvm.LLVMRealOGE;
        };
        return llvm.LLVMBuildFCmp(cg.b, pred, a, b, "");
    }
    const sign = typeOf(cg, type).kind == TypeKind.Int && isSigned(cg, type);
    const pred = switch (op) {
        case BinOp.Eq: llvm.LLVMIntEQ;
        case BinOp.Ne: llvm.LLVMIntNE;
        case BinOp.Lt: sign ? llvm.LLVMIntSLT : llvm.LLVMIntULT;
        case BinOp.Le: sign ? llvm.LLVMIntSLE : llvm.LLVMIntULE;
        case BinOp.Gt: sign ? llvm.LLVMIntSGT : llvm.LLVMIntUGT;
        default: sign ? llvm.LLVMIntSGE : llvm.LLVMIntUGE;
    };
    return compareIntegers(cg, pred, a, b);
}

/**
 * Emits `&&` or `||` with short-circuit evaluation.
 *
 * @param cg - The code generator
 * @param node - The binary node
 * @returns The `i1` result, a phi of the constant that the left side decides and the value of the right side
 *
 * @remarks
 * The right side runs in its own block, so its side effects happen only when the left side does not decide the result.
 * A phi joins the constant from the short-circuit edge with the value of the right side.
 *
 * @since 1.0.0
 */

function emitLogical(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const isAnd = n.op == (BinOp.And as u16);
    const lhs = emitValue(cg, n.a);
    const lhsBlock = llvm.LLVMGetInsertBlock(cg.b);
    const rhsBlock = block(cg, isAnd ? "and.rhs" : "or.rhs");
    const end = block(cg, isAnd ? "and.end" : "or.end");
    if (isAnd) condBr(cg, lhs, rhsBlock, end);
    else condBr(cg, lhs, end, rhsBlock);

    positionAtEnd(cg, rhsBlock);
    const rhs = emitValue(cg, n.b);
    const rhsEnd = llvm.LLVMGetInsertBlock(cg.b);
    branch(cg, end);

    positionAtEnd(cg, end);
    const values: Value[2] = [constBool(cg, !isAnd), rhs];
    const blocks: Block[2] = [lhsBlock, rhsEnd];
    return phiNode(cg, int1Type(cg), &values, &blocks, "");
}

/**
 * Emits the base pointer and length of an expression that can be indexed.
 *
 * @param cg - The code generator
 * @param base - The expression node
 * @returns The pointer, the length, the element type, and the array type when there is one
 *
 * @remarks
 * An array is reached by its address, so indexing it copies nothing, and its length is a constant.
 * A pointer to an array also has a constant length.
 * A slice or a string gives its pointer and length fields, and a raw `T[*]` pointer has no length.
 *
 * @example
 * ```hx
 * // buffer[i]   buffer: u8[4]
 * emitIndexable(cg, baseNode); // { ptr: %buffer, len: i64 4, arrayType: [4 x i8] }
 * ```
 *
 * @see elementAddress
 * @since 1.0.0
 */

export function emitIndexable(cg: *Cg, base: u32): Indexable {
    const type = finalType(cg, base);
    const t = typeOf(cg, type);
    let result = Indexable { ptr: null, len: null, elem: 0, arrayType: null };

    if (t.kind == TypeKind.Array) {
        result.ptr = emitAddress(cg, base);
        result.len = constUsize(cg, t.len);
        result.elem = t.child;
        result.arrayType = lower(cg, type);
    } else if (t.kind == TypeKind.Pointer) {   // pointer to array
        const array = typeOf(cg, t.child);
        result.ptr = emitValue(cg, base);
        result.len = constUsize(cg, array.len);
        result.elem = array.child;
        result.arrayType = lower(cg, t.child);
    } else if (t.kind == TypeKind.ManyPointer) {
        result.ptr = emitValue(cg, base);
        result.elem = t.child;
    } else {   // slice or string literal
        const slice = infoOf(cg, base).value != 0 ? emitConst(cg, infoOf(cg, base).value, cg.types.string) : emitValue(cg, base);
        result.ptr = extract(cg, slice, 0, "ptr");
        result.len = extract(cg, slice, 1, "len");
        result.elem = t.kind == TypeKind.StringLiteral ? cg.types.u8 : t.child;
    }
    return result;
}

/**
 * Emits the address of an element of an indexable base.
 *
 * @param cg - The code generator
 * @param base - The base from {@link emitIndexable}
 * @param index - The `usize` index
 * @returns The address of the element
 *
 * @remarks
 * This emits no bounds check, which the callers add where they need one.
 *
 * @example
 * ```hx
 * elementAddress(cg, &base, i); // getelementptr inbounds [4 x i8], ptr %buffer, i64 0, i64 %i
 * ```
 *
 * @see emitIndexable
 * @since 1.0.0
 */

export function elementAddress(cg: *Cg, base: readonly *Indexable, index: Value): Value {
    if (base.arrayType != null) {
        const indices: Value[2] = [constUsize(cg, 0), index];
        return elementPointer(cg, base.arrayType, base.ptr, &indices, "");
    }
    const indices: Value[1] = [index];
    return elementPointer(cg, lower(cg, base.elem), base.ptr, &indices, "");
}

/**
 * Emits the address of an index expression `a[i]`, with a bounds check in safe builds.
 *
 * @param cg - The code generator
 * @param node - The index node
 * @returns The address of the element
 *
 * @remarks
 * A raw `T[*]` pointer has no length to check against.
 * A constant index into an array needs no check either, since the checker already proved it in range.
 *
 * @since 1.0.0
 */

function emitIndexAddress(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const base = emitIndexable(cg, n.a);
    const index = emitValue(cg, n.b);
    const proven = infoOf(cg, n.b).value != 0 && base.arrayType != null;   // sema checked constant indexes into arrays
    if (base.len != null && !proven) emitBoundsCheck(cg, index, base.len, node);
    return elementAddress(cg, &base, index);
}

/**
 * Checks whether an expression names memory, so that its fields can be reached by address instead of copying it.
 *
 * @param cg - The code generator
 * @param node - The expression node
 * @returns `true` for a local or a global with storage, a dereference, an index,
 * or a field of a place or of a pointer
 *
 * @remarks
 * A name that the checker folded into a constant, or one narrowed from an optional, is not a place.
 *
 * @example
 * ```hx
 * // point.x   point is a local struct
 * isPlace(cg, node); // true
 * // make().x
 * isPlace(cg, node); // false
 * ```
 *
 * @see emitAddress
 * @since 1.0.0
 */

export function isPlace(cg: readonly *Cg, node: u32): bool {
    const n = nodeOf(cg, node);
    const info = infoOf(cg, node);
    switch (n.kind) {
        case NodeKind.Ident: return info.value == 0 && (info.flags & HxInfoNarrowed) == 0 && cg.storage[info.symbol] != null;
        case NodeKind.FieldAccess: {
            if ((info.flags & HxInfoModuleRef) != 0) return info.value == 0 && cg.storage[info.symbol] != null;
            return (info.flags & HxInfoField) != 0 && ((info.flags & HxInfoDeref) != 0 || isPlace(cg, n.a));
        }
        case NodeKind.Deref, NodeKind.Index: return true;
        default: return false;
    }
}

/**
 * Finds the type of a field of a struct or a payload of a union.
 *
 * @param cg - The code generator
 * @param owner - The struct or union type
 * @param index - The field index
 * @returns The type of the field
 *
 * @remarks
 * A field missing from the type is an internal error.
 *
 * @example
 * ```hx
 * // struct Point { x: i32, y: i32 }
 * fieldType(cg, point, 1); // the i32 type
 * ```
 *
 * @since 1.0.0
 */

export function fieldType(cg: *Cg, owner: u32, index: u32): u32 {
    const agg = aggregate(cg, owner);
    for (const i of 0..agg.membersCount) {
        const m = member(cg, agg, i);
        if (m.kind == HxMemberField as u8 && m.index == index) return m.type;
    }
    fatal(cg, `codegen: field ${index} of \`${typeName(cg, owner)}\` not found`);
}

/**
 * Emits the address of a field access, through a pointer or from the address of the base.
 *
 * @param cg - The code generator
 * @param node - The field access node
 * @returns The address of the field
 *
 * @remarks
 * When the checker marks the access as a dereference, the base value itself is the pointer,
 * and otherwise the base must be a place whose address {@link emitAddress} gives.
 *
 * @since 1.0.0
 */

function fieldAddress(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const info = infoOf(cg, node);
    const baseType = finalType(cg, n.a);
    const deref = (info.flags & HxInfoDeref) != 0;
    const structT = deref ? typeOf(cg, baseType).child : baseType;
    const base = deref ? emitValue(cg, n.a) : emitAddress(cg, n.a);
    return llvm.LLVMBuildStructGEP2(cg.b, lower(cg, structT), base, info.aux, "");
}

/**
 * Emits the address of a place.
 *
 * @param cg - The code generator
 * @param node - The place node: a name, a dereference, an index, or a field access
 * @returns The address of the place
 *
 * @remarks
 * A name gives its storage, and `*p` gives the pointer itself.
 * An index checks its bounds in safe builds, and a field access through a module, such as `ns.global`,
 * gives the storage of the global.
 * Any other node is an internal error, since the checker only allows places here.
 *
 * @example
 * ```hx
 * // x = 1;
 * emitAddress(cg, target); // ptr %x
 * ```
 *
 * @see isPlace
 * @since 1.0.0
 */

export function emitAddress(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    switch (n.kind) {
        case NodeKind.Ident: return cg.storage[infoOf(cg, node).symbol];
        case NodeKind.Deref: return emitValue(cg, n.a);
        case NodeKind.Index: return emitIndexAddress(cg, node);
        case NodeKind.FieldAccess: {
            if ((infoOf(cg, node).flags & HxInfoModuleRef) != 0) return cg.storage[infoOf(cg, node).symbol];
            return fieldAddress(cg, node);
        }
        default: fatal(cg, `codegen: node kind ${nodeKindName(n.kind as u32)} is not addressable`);
    }
}

/**
 * Builds a union value from its variant and payload.
 *
 * @param cg - The code generator
 * @param type - The union type
 * @param variant - The variant index, which becomes the tag
 * @param payload - The payload, or `null` for a variant without one
 * @returns The union value, written into a temporary and loaded back
 *
 * @remarks
 * It writes the tag and the payload through a stack slot and loads the whole union back,
 * so a payload of any variant fits the shared storage of the union.
 * A variant without a payload stores only the tag.
 *
 * @since 1.0.0
 */

function emitUnion(cg: *Cg, type: u32, variant: u32, payload: Value): Value {
    const llvmType = lower(cg, type);
    const slot = entryAlloca(cg, llvmType, "union");
    const tag = llvm.LLVMConstInt(lower(cg, typeOf(cg, type).child), variant as u64, 0);
    store(cg, tag, llvm.LLVMBuildStructGEP2(cg.b, llvmType, slot, 0, ""));
    if (payload != null) store(cg, payload, llvm.LLVMBuildStructGEP2(cg.b, llvmType, slot, 1, ""));
    return load(cg, llvmType, slot, "");
}

/**
 * Emits a struct literal.
 *
 * @param cg - The code generator
 * @param node - The struct literal node
 * @returns The struct value
 *
 * @remarks
 * The fields are emitted in source order, so their side effects happen as written.
 * The shorthand `{ name }` reads a constant or a variable of that name.
 * A field left out takes its default value, emitted in the struct's own generic instance, which its types belong to.
 *
 * @since 1.0.0
 */

function emitStructLiteral(cg: *Cg, node: u32): Value {
    const type = infoOf(cg, node).type;
    const agg = aggregate(cg, type);
    const values = zeroed<Value>(agg.fieldCount);
    defer release(values);

    const inits = record<HxRange>(cg.ast, nodeOf(cg, node).b);
    for (const i of inits.start..inits.end) {   // source order, so side effects happen as written
        const init = extra(cg, i);
        const info = infoOf(cg, init);
        let v: Value = null;
        if (nodeOf(cg, init).a != 0) {
            v = emitValue(cg, nodeOf(cg, init).a);
        } else if (info.value != 0) {   // `{ name }` of a constant
            v = emitConst(cg, info.value, finalType(cg, init));
        } else {                         // `{ name }` of a variable
            v = load(cg, lower(cg, info.type), cg.storage[info.symbol], "");
            if (info.coerce != 0) v = convert(cg, v, info.type, info.coerce, init, false);
        }
        values[info.aux] = v;
    }
    for (const i of 0..agg.membersCount) {
        const m = member(cg, agg, i);
        if (m.kind == HxMemberField as u8 && values[m.index] == null && m.defaultValue != 0) {
            const saved = cg.instance;
            cg.instance = agg.instance;   // the default's types belong to the struct's own instance
            values[m.index] = emitValue(cg, m.defaultValue);
            cg.instance = saved;
        }
    }

    let result = llvm.LLVMGetUndef(lower(cg, type));
    for (const i of 0..agg.fieldCount) {
        if (values[i] != null) result = insert(cg, result, values[i], i);
    }
    return result;
}

/**
 * Emits a lookup of the name of an error code.
 *
 * @param cg - The code generator
 * @param code - The error code
 * @returns A pointer to the NUL-terminated name
 *
 * @remarks
 * The names live in the private table `helix.errorNames`, built the first time it is needed.
 * Code 0 means success and has the name `(no error)`.
 *
 * @example
 * ```hx
 * // @errorName(e)
 * errorName(cg, code); // load ptr from @helix.errorNames at the code
 * ```
 *
 * @since 1.0.0
 */

export function errorName(cg: *Cg, code: Value): Value {
    const count = cg.sema.errorNames.len;
    const tableType = llvm.LLVMArrayType2(cg.ptrType, count as u64);
    if (cg.errorNames == null) {
        const names = zeroed<Value>(count);
        names[0] = cstring(cg, "(no error)", "error.none");
        for (const i of 1..count) {
            let len: u32 = 0;
            let name: u32 = 0;
            unsafe {
                name = cg.sema.errorNames.items![i];
            }
            const text = hxNameText(&cg.sema.names, name, &len);
            unsafe {
                names[i] = cstring(cg, text![0..len], "error.name");
            }
        }
        cg.errorNames = llvm.LLVMAddGlobal(cg.mod, tableType, "helix.error_names");
        llvm.LLVMSetInitializer(cg.errorNames, constArray(cg.ptrType, names));
        llvm.LLVMSetGlobalConstant(cg.errorNames, 1);
        llvm.LLVMSetLinkage(cg.errorNames, llvm.LLVMPrivateLinkage);
        release(names);
    }
    const index = llvm.LLVMBuildZExt(cg.b, code, cg.usizeType, "");
    const indices: Value[2] = [constUsize(cg, 0), index];
    const slot = elementPointer(cg, tableType, cg.errorNames, &indices, "");
    return load(cg, cg.ptrType, slot, "error.name");
}

/**
 * Leaves the function with an error.
 *
 * @param cg - The code generator
 * @param code - The error code
 *
 * @remarks
 * Every pending `errdefer` and `defer` runs first, innermost first.
 * The function then returns an error union with the code and an undefined payload.
 * Nothing more is emitted when a deferred statement already left the block.
 *
 * @example
 * ```hx
 * // throw ParseError.Empty;
 * emitErrorReturn(cg, code); // the defers, then ret { i32 undef, i16 <code> }
 * ```
 *
 * @see emitDefers
 * @since 1.0.0
 */

export function emitErrorReturn(cg: *Cg, code: Value): void {
    emitDefers(cg, 0, code);
    if (terminated(cg)) return;
    const ret = cg.returnType;
    const payload = errorUnionIsBare(cg, ret) ? null : llvm.LLVMGetUndef(lower(cg, typeOf(cg, ret).child));
    void llvm.LLVMBuildRet(cg.b, errorUnionMake(cg, payload, code, ret));
}

/**
 * Emits `try x`, which returns the error of an error union or gives its payload.
 *
 * @param cg - The code generator
 * @param node - The `try` node
 * @returns The payload, or `null` for an error union without one
 *
 * @remarks
 * The error path goes through {@link emitErrorReturn}, so pending defers run before the function returns the code.
 * A bare `void | E` union has no payload, so the result is null for it.
 *
 * @since 1.0.0
 */

function emitTry(cg: *Cg, node: u32): Value {
    const operand = nodeOf(cg, node).a;
    const type = finalType(cg, operand);
    const v = emitValue(cg, operand);
    const code = errorUnionCode(cg, v, type);
    const failed = block(cg, "try.error");
    const ok = block(cg, "try.ok");
    condBr(cg, compareIntegers(cg, llvm.LLVMIntNE, code, constErrorCode(cg, 0)), failed, ok);

    positionAtEnd(cg, failed);
    emitErrorReturn(cg, code);
    positionAtEnd(cg, ok);
    return errorUnionPayload(cg, v, type);
}

/**
 * Emits `x catch fallback`, which handles the error of an error union.
 *
 * @param cg - The code generator
 * @param node - The `catch` node
 * @returns The payload or the fallback value, or `null` for an error union without a payload
 *
 * @remarks
 * The capture `catch (e)` gets the error code.
 * A block handler runs as its own scope, while any other handler is the fallback value.
 * When the handler always leaves, such as with `return` or `throw`, the result is the payload without a phi.
 *
 * @since 1.0.0
 */

function emitCatch(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const data = record<HxCatchData>(cg.ast, n.b);
    const type = finalType(cg, n.a);
    const payloadType = typeOf(cg, type).child;
    const returnsValue = hasValue(cg, payloadType);

    const v = emitValue(cg, n.a);
    const code = errorUnionCode(cg, v, type);
    const okValue = returnsValue ? errorUnionPayload(cg, v, type) : null;
    const from = llvm.LLVMGetInsertBlock(cg.b);
    const handler = block(cg, "catch");
    const end = block(cg, "catch.end");
    condBr(cg, compareIntegers(cg, llvm.LLVMIntNE, code, constErrorCode(cg, 0)), handler, end);

    positionAtEnd(cg, handler);
    if (infoOf(cg, node).symbol != 0) store(cg, code, localStorage(cg, infoOf(cg, node).symbol));
    let fallback: Value = null;
    if (nodeOf(cg, data.body).kind == NodeKind.Block) emitScoped(cg, data.body);
    else fallback = emitValue(cg, data.body);
    const handlerEnd = llvm.LLVMGetInsertBlock(cg.b);
    const live = !terminated(cg);
    if (live) branch(cg, end);

    positionAtEnd(cg, end);
    if (!returnsValue) return null;
    if (!live) return okValue;
    const values: Value[2] = [okValue, fallback != null ? fallback : llvm.LLVMGetUndef(lower(cg, payloadType))];
    const blocks: Block[2] = [from, handlerEnd];
    return phiNode(cg, lower(cg, payloadType), &values, &blocks, "");
}

/**
 * Emits `x!`, the payload of an optional.
 *
 * @param cg - The code generator
 * @param node - The unwrap node
 * @returns The payload
 *
 * @remarks
 * Safe builds panic with `unwrapped a null value` when the optional holds none.
 *
 * @since 1.0.0
 */

function emitUnwrap(cg: *Cg, node: u32): Value {
    const operand = nodeOf(cg, node).a;
    const type = finalType(cg, operand);
    const v = emitValue(cg, operand);
    if (cg.safe) emitCheck(cg, llvm.LLVMBuildNot(cg.b, optionalPresent(cg, v, type), ""), node, "unwrapped a null value");
    return optionalPayload(cg, v, type);
}

/**
 * Emits `x ?? fallback`, which evaluates the fallback only when the optional holds no value.
 *
 * @param cg - The code generator
 * @param node - The binary node
 * @returns The payload or the fallback, or the optional itself when the result is optional too
 *
 * @remarks
 * A fallback that leaves, such as `x ?? return 0`, gives no value, so the phi gets an undefined one from that block.
 *
 * @since 1.0.0
 */

function emitCoalesce(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const leftType = finalType(cg, n.a);
    const resultType = infoOf(cg, node).type;
    const left = emitValue(cg, n.a);
    const present = optionalPresent(cg, left, leftType);
    const some = resultType == leftType ? left : optionalPayload(cg, left, leftType);

    const from = llvm.LLVMGetInsertBlock(cg.b);
    const fallbackBlock = block(cg, "coalesce.fallback");
    const end = block(cg, "coalesce.end");
    condBr(cg, present, end, fallbackBlock);

    positionAtEnd(cg, fallbackBlock);
    let fallback = emitValue(cg, n.b);
    if (fallback == null) fallback = llvm.LLVMGetUndef(lower(cg, resultType));
    const fallbackEnd = llvm.LLVMGetInsertBlock(cg.b);
    branch(cg, end);

    positionAtEnd(cg, end);
    const values: Value[2] = [some, fallback];
    const blocks: Block[2] = [from, fallbackEnd];
    return phiNode(cg, lower(cg, resultType), &values, &blocks, "");
}

/**
 * Emits `x?.field`, a field of an optional that is `null` when the optional holds no value.
 *
 * @param cg - The code generator
 * @param node - The optional field node
 * @returns The field wrapped as an optional, or the field itself when it is already optional
 *
 * @remarks
 * The field is read through a pointer or out of the struct value.
 * On an optional slice, `?.len` reads the length.
 *
 * @since 1.0.0
 */

function emitOptionalField(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const info = infoOf(cg, node);
    const baseType = finalType(cg, n.a);
    const resultType = info.type;
    const base = emitValue(cg, n.a);

    const from = llvm.LLVMGetInsertBlock(cg.b);
    const someBlock = block(cg, "field.some");
    const end = block(cg, "field.end");
    condBr(cg, optionalPresent(cg, base, baseType), someBlock, end);

    positionAtEnd(cg, someBlock);
    const inner = optionalPayload(cg, base, baseType);
    const innerType = typeOf(cg, baseType).child;
    let field: Value = null;
    let type: u32 = 0;
    if ((info.flags & HxInfoField) != 0) {
        const deref = (info.flags & HxInfoDeref) != 0;
        const structT = deref ? typeOf(cg, innerType).child : innerType;
        type = fieldType(cg, structT, info.aux);
        if (deref) {
            const ptr = llvm.LLVMBuildStructGEP2(cg.b, lower(cg, structT), inner, info.aux, "");
            field = load(cg, lower(cg, type), ptr, "");
        } else {
            field = extract(cg, inner, info.aux, "");
        }
    } else {   // `?.len` of an optional slice
        type = cg.types.usize;
        field = extract(cg, inner, 1, "len");
    }
    const wrapped = type == resultType ? field : optionalSome(cg, field, resultType);
    const someEnd = llvm.LLVMGetInsertBlock(cg.b);
    branch(cg, end);

    positionAtEnd(cg, end);
    const values: Value[2] = [llvm.LLVMConstNull(lower(cg, resultType)), wrapped];
    const blocks: Block[2] = [from, someEnd];
    return phiNode(cg, lower(cg, resultType), &values, &blocks, "");
}

/**
 * Emits a comparison of two strings by length and content.
 *
 * @param cg - The code generator
 * @param a - The first string
 * @param b - The second string
 * @returns The `i1` that is true when the strings are equal
 *
 * @remarks
 * The content is compared with `memcmp`.
 * When the lengths differ, it compares 0 bytes, so `memcmp` never reads past the shorter string.
 *
 * @example
 * ```hx
 * // case "quit":
 * stringEqual(cg, actual, expected); // the lengths match and memcmp returns 0
 * ```
 *
 * @see emitSwitch
 * @since 1.0.0
 */

export function stringEqual(cg: *Cg, a: Value, b: Value): Value {
    const i32t = int32(cg);
    const params: Type[3] = [cg.ptrType, cg.ptrType, cg.usizeType];
    const memcmpType = fnType(i32t, &params, false);
    const memcmpFn = declareC(cg, "memcmp", memcmpType);
    const lenA = extract(cg, a, 1, "");
    const sameLen = compareIntegers(cg, llvm.LLVMIntEQ, lenA, extract(cg, b, 1, ""));
    // Compare 0 bytes when the lengths differ, so memcmp never reads past the shorter string.
    const count = llvm.LLVMBuildSelect(cg.b, sameLen, lenA, constUsize(cg, 0), "");
    const args: Value[3] = [extract(cg, a, 0, ""), extract(cg, b, 0, ""), count];
    const cmp = call(cg, memcmpType, memcmpFn, &args, "");
    return llvm.LLVMBuildAnd(cg.b, sameLen, compareIntegers(cg, llvm.LLVMIntEQ, cmp, llvm.LLVMConstInt(i32t, 0, 0)), "");
}

/**
 * Continues in a new block when a condition holds, otherwise jumps to a failure block.
 *
 * @param cg - The code generator
 * @param ok - The condition
 * @param onFail - The block to jump to when the condition is false
 *
 * @remarks
 * The pattern tests chain through it, so each test that passes leaves the builder ready for the next one.
 *
 * @since 1.0.0
 */

function branchUnless(cg: *Cg, ok: Value, onFail: Block): void {
    const next = block(cg, "match");
    condBr(cg, ok, next, onFail);
    positionAtEnd(cg, next);
}

/**
 * Tests the tag of the union at an address against a variant, jumping to a failure block on a mismatch.
 *
 * @param cg - The code generator
 * @param ptr - The address of the union
 * @param unionType - The union type
 * @param variant - The variant index
 * @param onFail - The block to jump to on a mismatch
 *
 * @remarks
 * It reads the tag from the first field of the union in memory, so the value must already sit in a slot.
 *
 * @since 1.0.0
 */

function matchTag(cg: *Cg, ptr: Value, unionType: u32, variant: u32, onFail: Block): void {
    const tagType = lower(cg, typeOf(cg, unionType).child);
    const tag = load(cg, tagType, llvm.LLVMBuildStructGEP2(cg.b, lower(cg, unionType), ptr, 0, ""), "tag");
    branchUnless(cg, compareIntegers(cg, llvm.LLVMIntEQ, tag, llvm.LLVMConstInt(tagType, variant as u64, 0)), onFail);
}

/**
 * Tests a pattern against the value at an address.
 *
 * @param cg - The code generator
 * @param pat - The pattern node
 * @param ptr - The address of the value
 * @param type - The type of the value
 * @param onFail - The block to jump to when the pattern does not match
 *
 * @remarks
 * Code after it runs only on a match.
 * A value pattern compares integers and enums with `==`, floats with an ordered `==`, and strings by content,
 * and a union variant by its tag.
 * A range pattern tests both bounds, and the upper one is inclusive for `..=`.
 * Tag and struct patterns test their nested patterns, while a binding always matches.
 *
 * @since 1.0.0
 */

function matchPattern(cg: *Cg, pat: u32, ptr: Value, type: u32, onFail: Block): void {
    const p = nodeOf(cg, pat);
    const info = infoOf(cg, pat);
    switch (p.kind) {
        case NodeKind.PatternValue: {
            if ((info.flags & HxInfoUnionInit) != 0) {
                matchTag(cg, ptr, type, info.aux, onFail);
                return;
            }
            const actual = load(cg, lower(cg, type), ptr, "");
            const expected = emitValue(cg, p.a);
            let ok: Value = null;
            if (typeOf(cg, type).kind == TypeKind.Slice) ok = stringEqual(cg, actual, expected);
            else if (typeOf(cg, type).kind == TypeKind.Float) ok = llvm.LLVMBuildFCmp(cg.b, llvm.LLVMRealOEQ, actual, expected, "");
            else ok = compareIntegers(cg, llvm.LLVMIntEQ, actual, expected);
            branchUnless(cg, ok, onFail);
        }
        case NodeKind.PatternRange: {
            const actual = load(cg, lower(cg, type), ptr, "");
            const sign = isSigned(cg, type);
            const lo = compareIntegers(cg, sign ? llvm.LLVMIntSGE : llvm.LLVMIntUGE, actual, emitValue(cg, p.a));
            const inclusive = (p.flags & FlagInclusive) != 0;
            const upper = inclusive ? (sign ? llvm.LLVMIntSLE : llvm.LLVMIntULE) : (sign ? llvm.LLVMIntSLT : llvm.LLVMIntULT);
            const hi = compareIntegers(cg, upper, actual, emitValue(cg, p.b));
            branchUnless(cg, llvm.LLVMBuildAnd(cg.b, lo, hi, ""), onFail);
        }
        case NodeKind.PatternTag: {
            matchTag(cg, ptr, type, info.aux, onFail);
            const payload = llvm.LLVMBuildStructGEP2(cg.b, lower(cg, type), ptr, 1, "payload");
            matchPattern(cg, p.b, payload, fieldType(cg, type, info.aux), onFail);
        }
        case NodeKind.PatternStruct: {
            for (const i of p.a..p.b) {
                const field = extra(cg, i);
                if (nodeOf(cg, field).a == 0) continue;
                const fieldPtr = llvm.LLVMBuildStructGEP2(cg.b, lower(cg, type), ptr, infoOf(cg, field).aux, "");
                matchPattern(cg, nodeOf(cg, field).a, fieldPtr, infoOf(cg, field).type, onFail);
            }
        }
        default: {}   // bindings always match
    }
}

/**
 * Stores the bindings of a matched pattern.
 *
 * @param cg - The code generator
 * @param pat - The pattern node
 * @param ptr - The address of the value
 * @param type - The type of the value
 *
 * @remarks
 * A `*name` binding gets the address, so the case can change the value in place.
 * Any other binding gets a copy, and so does the shorthand of a struct pattern field.
 *
 * @since 1.0.0
 */

function bindPattern(cg: *Cg, pat: u32, ptr: Value, type: u32): void {
    const p = nodeOf(cg, pat);
    const info = infoOf(cg, pat);
    switch (p.kind) {
        case NodeKind.PatternBind: {
            if (info.symbol == 0) return;
            const v = (p.flags & FlagPointer) != 0 ? ptr : load(cg, lower(cg, type), ptr, "");
            store(cg, v, localStorage(cg, info.symbol));
        }
        case NodeKind.PatternTag: {
            const payload = llvm.LLVMBuildStructGEP2(cg.b, lower(cg, type), ptr, 1, "payload");
            bindPattern(cg, p.b, payload, fieldType(cg, type, info.aux));
        }
        case NodeKind.PatternStruct: {
            for (const i of p.a..p.b) {
                const field = extra(cg, i);
                const fieldPtr = llvm.LLVMBuildStructGEP2(cg.b, lower(cg, type), ptr, infoOf(cg, field).aux, "");
                if (nodeOf(cg, field).a != 0) {
                    bindPattern(cg, nodeOf(cg, field).a, fieldPtr, infoOf(cg, field).type);
                } else if (infoOf(cg, field).symbol != 0) {
                    const v = load(cg, lower(cg, infoOf(cg, field).type), fieldPtr, "");
                    store(cg, v, localStorage(cg, infoOf(cg, field).symbol));
                }
            }
        }
        default: {}
    }
}

/**
 * Emits a `switch`, as a statement or as an expression.
 *
 * @param cg - The code generator
 * @param node - The `switch` node
 * @param wantValue - Whether the `switch` is an expression whose value the caller uses
 * @returns The value of the chosen case, or `null` for a statement or a `switch` without a value
 *
 * @remarks
 * The cases are tested in order, top to bottom, as a chain of compare-and-branch blocks.
 * LLVM turns dense integer and enum chains into jump tables when it optimizes.
 * The `default` case is tested last, wherever it appears.
 * Without one, the chain ends in `unreachable`, since the checker proved that the cases cover every value.
 *
 * A subject that is a place is matched where it is, and any other subject is copied into a temporary first.
 * Each alternative pattern of a case binds its own captures, and a guard runs after the bindings.
 * As a statement, an empty case such as `case 1: case 2: ...` runs the case after it.
 *
 * @example
 * ```hx
 * // const name = switch (n) { case 1: "one"; default: "many"; };
 * emitSwitch(cg, node, true); // case blocks, then a load of %switch.result
 * ```
 *
 * @see stringEqual
 * @since 1.0.0
 */

export function emitSwitch(cg: *Cg, node: u32, wantValue: bool): Value {
    const n = nodeOf(cg, node);
    const cases = record<HxRange>(cg.ast, n.b);
    const subject = n.a;
    const subjectType = finalType(cg, subject);

    let slot: Value = null;
    if (isPlace(cg, subject)) {
        slot = emitAddress(cg, subject);
    } else {
        slot = entryAlloca(cg, lower(cg, subjectType), "subject");
        store(cg, emitValue(cg, subject), slot);
    }

    const resultType = wantValue ? infoOf(cg, node).type : 0;
    const hasResult = resultType != 0 && hasValue(cg, resultType);
    const result = hasResult ? entryAlloca(cg, lower(cg, resultType), "switch.result") : null;

    const count = cases.end - cases.start;
    const bodies = zeroed<Block>(count);
    defer release(bodies);
    for (const i of 0..count) bodies[i] = block(cg, "case");
    const end = block(cg, "switch.end");
    let defaultIndex: i32 = -1;

    for (const i of 0..count) {
        const cn = nodeOf(cg, extra(cg, cases.start + i));
        if (cn.kind == NodeKind.DefaultCase) {
            defaultIndex = i as i32;
            continue;
        }
        const data = record<HxCaseData>(cg.ast, cn.a);
        const nextCase = block(cg, "case.next");
        const matched = data.guard != 0 ? block(cg, "case.guard") : bodies[i];

        for (const j of data.patternsStart..data.patternsEnd) {
            const pat = extra(cg, j);
            const fail = j + 1 < data.patternsEnd ? block(cg, "case.alt") : nextCase;
            matchPattern(cg, pat, slot, subjectType, fail);
            bindPattern(cg, pat, slot, subjectType);
            branch(cg, matched);
            positionAtEnd(cg, fail);
        }
        if (data.guard != 0) {
            const resume = llvm.LLVMGetInsertBlock(cg.b);
            positionAtEnd(cg, matched);
            condBr(cg, emitValue(cg, data.guard), bodies[i], nextCase);
            positionAtEnd(cg, resume);
        }
    }
    if (defaultIndex >= 0) branch(cg, bodies[defaultIndex as u32]);
    else void llvm.LLVMBuildUnreachable(cg.b);   // sema proved the cases cover every value

    for (const i of 0..count) {
        const cn = nodeOf(cg, extra(cg, cases.start + i));
        const body = cn.kind == NodeKind.DefaultCase ? cn.a : record<HxCaseData>(cg.ast, cn.a).body;
        positionAtEnd(cg, bodies[i]);
        if (!wantValue || !hasResult) {
            const stacked = nodeOf(cg, body).kind == NodeKind.Block && nodeOf(cg, body).a == nodeOf(cg, body).b && i + 1 < count;
            if (stacked) {   // `case 1: case 2: ...` - an empty case runs the next one
                branch(cg, bodies[i + 1]);
                continue;
            }
            if (wantValue) void emitValue(cg, body);
            else emitScoped(cg, body);
        } else {
            const v = emitValue(cg, body);
            if (v != null && !terminated(cg)) store(cg, v, result);
        }
        if (!terminated(cg)) branch(cg, end);
    }

    positionAtEnd(cg, end);
    return hasResult ? load(cg, lower(cg, resultType), result, "") : null;
}

/**
 * Emits a call, including the calls that the checker marked for special lowering.
 *
 * @param cg - The code generator
 * @param node - The call node
 * @returns The result of the call, or `null` when the function returns nothing
 *
 * @remarks
 * A union variant with a payload, `print`, a method on a `dyn`, a format write, and `expect`
 * each have a lowering of their own.
 * A method call passes the receiver first, by address, through a pointer, or by value, as the checker resolved it.
 * The `comptime` arguments of a generic function were folded into its instance, so only the others are passed.
 * A function with the C calling convention goes through {@link emitCCall}.
 * A call to a `noreturn` function ends the block with `unreachable`.
 *
 * @since 1.0.0
 */

function emitCall(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const info = infoOf(cg, node);
    const sym = info.symbol;
    const args = record<HxRange>(cg.ast, n.b);

    if ((info.flags & HxInfoUnionInit) != 0) return emitUnion(cg, info.type, info.aux, emitValue(cg, extra(cg, args.start)));
    if ((info.flags & HxInfoPrint) != 0) {
        emitPrint(cg, node);
        return null;
    }
    if ((info.flags & HxInfoDyn) != 0) return emitDynCall(cg, node);
    if ((info.flags & HxInfoFormatWrite) != 0) return emitFormatWrite(cg, node);
    if ((info.flags & HxInfoExpect) != 0) return emitExpect(cg, node);

    let values: Value[257] = undefined;
    let count: u32 = 0;
    if ((info.flags & HxInfoMethod) != 0) {   // the receiver is the first argument
        const callee = nodeOf(cg, n.a).kind == NodeKind.GenericInstance ? nodeOf(cg, n.a).a : n.a;   // `x.map<i32>(f)`
        const receiver = nodeOf(cg, callee).a;
        const throughPointer = (info.flags & HxInfoDeref) != 0;
        if ((info.flags & HxInfoReceiverAddr) != 0) {
            values[count] = throughPointer ? emitValue(cg, receiver) : emitAddress(cg, receiver);
        } else if (throughPointer) {
            const pointee = typeOf(cg, finalType(cg, receiver)).child;
            values[count] = load(cg, lower(cg, pointee), emitValue(cg, receiver), "");
        } else {
            values[count] = emitValue(cg, receiver);
        }
        count += 1;
    }
    // `comptime` arguments were folded into the instance; only the others are passed
    const indirect = (info.flags & HxInfoIndirect) != 0;
    const hasComptime = !indirect && symbolOf(cg, sym).instance != 0 && nodeOf(cg, symbolOf(cg, sym).decl).kind == NodeKind.Function;
    let callee = HxFnData { genericsStart: 0, genericsEnd: 0, paramsStart: 0, paramsEnd: 0, returnType: 0, body: 0, abiToken: 0, firstNode: 0 };
    if (hasComptime) callee = record<HxFnData>(cg.ast, nodeOf(cg, symbolOf(cg, sym).decl).a);
    const receiverParams: u32 = (info.flags & HxInfoMethod) != 0 ? 1 : 0;
    for (const i of args.start..args.end) {
        if (count >= 256) break;
        const p = callee.paramsStart + receiverParams + (i - args.start);
        if (hasComptime && p < callee.paramsEnd && (nodeOf(cg, extra(cg, p)).flags & FlagComptime) != 0) continue;
        values[count] = emitValue(cg, extra(cg, i));
        count += 1;
    }

    const fnT = indirect ? finalType(cg, n.a) : symbolOf(cg, sym).type;
    const target = indirect ? emitValue(cg, n.a) : cg.storage[sym];
    const ret = typeOf(cg, fnT).child;
    const cCall = indirect ? (typeOf(cg, fnT).flags & CCall) != 0 : cg.cAbi[sym];
    const all: *Value[257] = &values;
    const result = cCall ? emitCCall(cg, fnT, target, all[0..count])
                         : call(cg, lowerFunction(cg, fnT), target, all[0..count], hasValue(cg, ret) ? "call" : "");
    if (ret == cg.types.noreturnType) {
        void llvm.LLVMBuildUnreachable(cg.b);
        startDeadBlock(cg);
        return null;
    }
    return hasValue(cg, ret) ? result : null;
}

/**
 * Emits a slice expression `a[start..end]`.
 *
 * @param cg - The code generator
 * @param node - The slice node
 * @returns The slice value of a pointer and a length
 *
 * @remarks
 * A missing start is 0, a missing end is the length, and `..=` adds one to the end.
 * Safe builds panic when the start is after the end, or when the end is past the length of the base.
 *
 * @since 1.0.0
 */

function emitSlice(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const data = record<HxSliceData>(cg.ast, n.b);

    const base = emitIndexable(cg, n.a);
    const start = data.start != 0 ? emitValue(cg, data.start) : constUsize(cg, 0);
    let end = data.end != 0 ? emitValue(cg, data.end) : base.len;
    if ((n.flags & FlagInclusive) != 0) end = llvm.LLVMBuildNUWAdd(cg.b, end, constUsize(cg, 1), "");

    if (cg.safe) {
        emitCheck(cg, compareIntegers(cg, llvm.LLVMIntUGT, start, end), node, "slice start is after its end");
        if (base.len != null) emitCheck(cg, compareIntegers(cg, llvm.LLVMIntUGT, end, base.len), node, "slice end is out of bounds");
    }

    const ptr = elementAddress(cg, &base, start);
    const slice = insert(cg, llvm.LLVMGetUndef(cg.sliceType), ptr, 0);
    return insert(cg, slice, llvm.LLVMBuildSub(cg.b, end, start, ""), 1);
}

/**
 * Emits `condition ? a : b`.
 *
 * @param cg - The code generator
 * @param node - The ternary node
 * @returns The value of the branch taken
 *
 * @remarks
 * A condition that the checker decided while compiling emits only the branch it takes.
 * A branch that leaves, such as one that throws, adds no incoming value to the phi.
 *
 * @since 1.0.0
 */

function emitTernary(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const data = record<HxTernaryData>(cg.ast, n.b);
    const known = knownCondition(cg, n.a);
    if (known >= 0) return emitValue(cg, known == 1 ? data.thenValue : data.elseValue);   // only the branch taken

    const cond = emitValue(cg, n.a);
    const thenBlock = block(cg, "then");
    const elseBlock = block(cg, "else");
    const end = block(cg, "end");
    condBr(cg, cond, thenBlock, elseBlock);

    positionAtEnd(cg, thenBlock);
    const thenValue = emitValue(cg, data.thenValue);
    const thenEnd = llvm.LLVMGetInsertBlock(cg.b);
    const thenLive = !terminated(cg);
    if (thenLive) branch(cg, end);

    positionAtEnd(cg, elseBlock);
    const elseValue = emitValue(cg, data.elseValue);
    const elseEnd = llvm.LLVMGetInsertBlock(cg.b);
    const elseLive = !terminated(cg);
    if (elseLive) branch(cg, end);

    positionAtEnd(cg, end);
    if (thenValue == null || elseValue == null) return thenValue != null ? thenValue : elseValue;
    const p = llvm.LLVMBuildPhi(cg.b, llvm.LLVMTypeOf(thenValue), "");
    let values: Value[1] = [thenValue];
    let blocks: Block[1] = [thenEnd];
    if (thenLive) llvm.LLVMAddIncoming(p, &values, &blocks, 1);
    values[0] = elseValue;
    blocks[0] = elseEnd;
    if (elseLive) llvm.LLVMAddIncoming(p, &values, &blocks, 1);
    return p;
}

/**
 * Emits a call to a builtin such as `@truncate` or `@panic`.
 *
 * @param cg - The code generator
 * @param node - The builtin call node
 * @returns The result of the builtin, or `null` for one without a value
 *
 * @remarks
 * - **Conversions** - `@truncate` truncates or extends to the target width,
 *   `@enumFromInt` casts the integer to the backing width, and `@ptrCast` passes the pointer through,
 *   since pointers are untyped in LLVM.
 * - **Memory** - `@volatileLoad` and `@volatileStore` emit volatile accesses,
 *   and `@intFromPtr` and `@ptrFromInt` convert between pointers and `usize`.
 * - **Panics** - `@panic` panics with a constant message,
 *   or with one made at runtime through the panic handler.
 * - **Compile-time** - `@compileError` only reaches code generation in a function that nothing uses,
 *   or in a branch ruled out while compiling, so it emits `unreachable`, and `@compileLog` emits nothing.
 *
 * Any other builtin is an internal error.
 *
 * @since 1.0.0
 */

function emitBuiltin(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    const name = tokenText(cg, n.token);

    if (equal(name, "@truncate")) {
        const arg = extra(cg, n.a + 1);
        const v = emitValue(cg, arg);
        const target = lower(cg, infoOf(cg, node).type);
        if (llvm.LLVMGetIntTypeWidth(target) <= llvm.LLVMGetIntTypeWidth(llvm.LLVMTypeOf(v))) return llvm.LLVMBuildTrunc(cg.b, v, target, "");
        return isSigned(cg, finalType(cg, arg)) ? llvm.LLVMBuildSExt(cg.b, v, target, "") : llvm.LLVMBuildZExt(cg.b, v, target, "");
    }
    if (equal(name, "@errorName")) return errorName(cg, emitValue(cg, extra(cg, n.a)));
    if (equal(name, "@ptrCast")) return emitValue(cg, extra(cg, n.a + 1));   // pointers are untyped in LLVM
    if (equal(name, "@enumFromInt")) {   // the backing integer, at its width
        const arg = extra(cg, n.a + 1);
        const v = emitValue(cg, arg);
        return llvm.LLVMBuildIntCast2(cg.b, v, lower(cg, infoOf(cg, node).type), llvmBool(isSigned(cg, finalType(cg, arg))), "");
    }
    if (equal(name, "@volatileLoad")) {
        const read = llvm.LLVMBuildLoad2(cg.b, lower(cg, infoOf(cg, node).type), emitValue(cg, extra(cg, n.a)), "");
        llvm.LLVMSetVolatile(read, 1);
        return read;
    }
    if (equal(name, "@volatileStore")) {
        const ptr = emitValue(cg, extra(cg, n.a));
        const write = llvm.LLVMBuildStore(cg.b, emitValue(cg, extra(cg, n.a + 1)), ptr);
        llvm.LLVMSetVolatile(write, 1);
        return null;
    }
    if (equal(name, "@intFromPtr")) return llvm.LLVMBuildPtrToInt(cg.b, emitValue(cg, extra(cg, n.a)), cg.usizeType, "");
    if (equal(name, "@ptrFromInt")) return llvm.LLVMBuildIntToPtr(cg.b, emitValue(cg, extra(cg, n.a + 1)), cg.ptrType, "");
    // in a function nothing uses (or a branch ruled out while compiling), which is the only place they get here
    if (equal(name, "@compileError")) {
        void llvm.LLVMBuildUnreachable(cg.b);
        startDeadBlock(cg);
        return null;
    }
    if (equal(name, "@compileLog")) return null;
    if (equal(name, "@panic")) {
        const arg = extra(cg, n.a);
        if (infoOf(cg, arg).value != 0) {
            const message = value(cg, infoOf(cg, arg).value);
            unsafe {
                emitPanic(cg, node, message.len > 0 ? message.bytes![0..message.len] : "");
            }
        } else {   // a message made at runtime: `@panic(reason)`
            const message = emitValue(cg, arg);
            buildPanicHandler(cg);
            const args: Value[3] = [extract(cg, message, 0, ""), extract(cg, message, 1, ""), locationString(cg, node)];
            void call(cg, cg.panicFnType, cg.panicFn, &args, "");
            void llvm.LLVMBuildUnreachable(cg.b);
        }
        startDeadBlock(cg);
        return null;
    }
    fatal(cg, `codegen: builtin ${name} has no lowering`);
}

/**
 * Emits an expression that has no constant value, dispatching on its node kind.
 *
 * @param cg - The code generator
 * @param node - The expression node
 * @returns The value, or `null` for an expression without one
 *
 * @remarks
 * A comparison with `null` tests whether the optional holds a value.
 * A `throw`, `return`, `break`, or `continue` used as an expression, such as `x ?? return 0`,
 * leaves the block and continues in a dead one.
 * The `.len` and `.ptr` of a slice read its fields, and an empty array literal `[]` of a slice type is a null slice.
 * Safe builds panic at `unreachable`, and other builds tell LLVM that the code cannot run.
 * A `comptime` expression already ran while compiling.
 * An expression kind without a lowering is an internal error.
 *
 * @since 1.0.0
 */

function emitRaw(cg: *Cg, node: u32): Value {
    const n = nodeOf(cg, node);
    switch (n.kind) {
        case NodeKind.Ident: {
            const sym = infoOf(cg, node).symbol;
            let v = load(cg, lower(cg, symbolOf(cg, sym).type), cg.storage[sym], tokenName(cg, symbolOf(cg, sym).token));
            if ((infoOf(cg, node).flags & HxInfoNarrowed) != 0) v = optionalPayload(cg, v, symbolOf(cg, sym).type);
            return v;
        }
        case NodeKind.Binary: {
            const op = @enumFromInt(BinOp, n.op);
            if (op == BinOp.And || op == BinOp.Or) return emitLogical(cg, node);
            if (op == BinOp.Coalesce) return emitCoalesce(cg, node);
            const nullTest = nodeOf(cg, n.a).kind == NodeKind.Null || nodeOf(cg, n.b).kind == NodeKind.Null;
            if (nullTest && (op == BinOp.Eq || op == BinOp.Ne)) {
                const other = nodeOf(cg, n.a).kind == NodeKind.Null ? n.b : n.a;
                const present = optionalPresent(cg, emitValue(cg, other), finalType(cg, other));
                return op == BinOp.Ne ? present : llvm.LLVMBuildNot(cg.b, present, "");
            }
            const a = emitValue(cg, n.a);
            const b = emitValue(cg, n.b);
            const operand = finalType(cg, n.a);
            if ((op as u32) >= (BinOp.Eq as u32) && (op as u32) <= (BinOp.Ge as u32)) return emitCompare(cg, op, a, b, operand);
            return emitArith(cg, op, a, b, operand, node);
        }
        case NodeKind.Negate: {
            const v = emitValue(cg, n.a);
            const type = finalType(cg, n.a);
            if (typeOf(cg, type).kind == TypeKind.Float) return llvm.LLVMBuildFNeg(cg.b, v, "");
            return emitArith(cg, BinOp.Sub, llvm.LLVMConstNull(llvm.LLVMTypeOf(v)), v, type, node);
        }
        case NodeKind.Not, NodeKind.BitNot: return llvm.LLVMBuildNot(cg.b, emitValue(cg, n.a), "");
        case NodeKind.AddressOf: return emitAddress(cg, n.a);
        case NodeKind.Deref: return load(cg, lower(cg, infoOf(cg, node).type), emitValue(cg, n.a), "");
        case NodeKind.Discard: {
            void emitValue(cg, n.a);
            return null;
        }
        case NodeKind.Call: return emitCall(cg, node);
        case NodeKind.Cast: {
            const v = emitValue(cg, n.a);
            return convert(cg, v, finalType(cg, n.a), infoOf(cg, node).type, node, true);
        }
        case NodeKind.Ternary: return emitTernary(cg, node);
        case NodeKind.Index: return load(cg, lower(cg, infoOf(cg, node).type), emitIndexAddress(cg, node), "");
        case NodeKind.Slice: return emitSlice(cg, node);
        case NodeKind.FieldAccess: {
            const info = infoOf(cg, node);
            if ((info.flags & HxInfoModuleRef) != 0) {   // `ns.global`
                return load(cg, lower(cg, symbolOf(cg, info.symbol).type), cg.storage[info.symbol], "");
            }
            if ((info.flags & HxInfoUnionInit) != 0) return emitUnion(cg, info.type, info.aux, null);
            if ((info.flags & HxInfoField) != 0) {
                if (isPlace(cg, node)) return load(cg, lower(cg, info.type), fieldAddress(cg, node), "");
                return extract(cg, emitValue(cg, n.a), info.aux, "");
            }
            // `.len` / `.ptr` of a slice; array lengths are constants
            const slice = emitValue(cg, n.a);
            const isLen = tokenText(cg, n.token)[0] == 'l';
            return extract(cg, slice, isLen ? 1 : 0, isLen ? "len" : "ptr");
        }
        case NodeKind.BuiltinCall: return emitBuiltin(cg, node);
        case NodeKind.EnumLiteral: return emitUnion(cg, infoOf(cg, node).type, infoOf(cg, node).aux, null);   // `.quit`: a payload-free variant
        case NodeKind.StructLiteral: return emitStructLiteral(cg, node);
        case NodeKind.ArrayLiteral: {
            const type = infoOf(cg, node).type;
            if (typeOf(cg, type).kind == TypeKind.Slice) return llvm.LLVMConstNull(cg.sliceType);   // `[]`
            let array = llvm.LLVMGetUndef(lower(cg, type));
            for (const i of n.a..n.b) {
                const element = emitValue(cg, extra(cg, i));
                if (element != null) array = insert(cg, array, element, i - n.a);
            }
            return array;
        }
        case NodeKind.Unwrap: return emitUnwrap(cg, node);
        case NodeKind.OptionalField: return emitOptionalField(cg, node);
        case NodeKind.Try: return emitTry(cg, node);
        case NodeKind.Catch: return emitCatch(cg, node);
        case NodeKind.Switch: return emitSwitch(cg, node, true);
        case NodeKind.Throw: {
            emitErrorReturn(cg, emitValue(cg, n.a));
            startDeadBlock(cg);
            return null;
        }
        case NodeKind.Return, NodeKind.Break, NodeKind.Continue: {   // `x ?? return 0`
            emitStmt(cg, node);
            startDeadBlock(cg);
            return null;
        }
        case NodeKind.ComptimeExpr: return null;   // its value was computed while compiling; one without a value ran for nothing
        case NodeKind.Unreachable: {
            if (cg.safe) emitPanic(cg, node, "reached unreachable code");
            else void llvm.LLVMBuildUnreachable(cg.b);
            startDeadBlock(cg);
            return null;
        }
        default: fatal(cg, `codegen: expression kind ${nodeKindName(n.kind as u32)} has no lowering`);
    }
}

/**
 * Emits an expression and returns its value.
 *
 * @param cg - The code generator
 * @param node - The expression node
 * @returns The value, converted to the type that the checker coerced it to,
 * or `null` for an expression without a value
 *
 * @remarks
 * A string or template that the checker typed as a format is emitted as one.
 * An expression with a constant value that the checker computed is emitted as that constant, without any code.
 *
 * @example
 * ```hx
 * // a + 1   a: i32
 * emitValue(cg, node); // a load of %a, then llvm.sadd.with.overflow.i32
 * ```
 *
 * @see convert
 * @see emitAddress
 *
 * @since 1.0.0
 */

export function emitValue(cg: *Cg, node: u32): Value {
    const info = infoOf(cg, node);
    const kind = nodeOf(cg, node).kind;
    if ((kind == NodeKind.Template || kind == NodeKind.String) && finalType(cg, node) == cg.types.format) {
        return emitFormatValue(cg, node, false);
    }
    if (info.value != 0) return emitConst(cg, info.value, finalType(cg, node));
    let v = emitRaw(cg, node);
    if (info.coerce != 0 && v != null) v = convert(cg, v, info.type, info.coerce, node, false);
    return v;
}
