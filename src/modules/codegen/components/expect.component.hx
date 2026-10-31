/**
 * Imports
 */

import { record } from "@models/ast.model";
import { BinOp } from "@constants/ast.constant";
import { TypeKind } from "@constants/types.constant";
import { hxSourceLineCol } from "@models/source.model";
import { HxRange } from "@models/structs/ast-model.struct";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { hxNodeSpan } from "@modules/sema/components/base.component";
import { HxMatchToBeDefined, HxExpectMatcher } from "@constants/sema.constant";
import { Cg, Value, Type, Block } from "@modules/codegen/components/structs/base-component.struct";
import { callIntrinsic, addAttribute, entryAlloca } from "@modules/codegen/components/base.component";
import { HxExpectNot, HxMatchToBeFalse, HxMatchCloseTo, HxMatchMatch } from "@constants/sema.constant";
import { detourEnd, optionalPayload, errorUnionCode } from "@modules/codegen/components/base.component";
import { emitFormat, writeText, writeCstr, fdWriter } from "@modules/codegen/components/format.component";
import { int32, int64, voidType, constUsize, constBool } from "@modules/codegen/components/base.component";
import { emitValue, emitCompare, errorName, stringEqual } from "@modules/codegen/components/expr.component";
import { errorUnionPayload, load, store, branch, condBr } from "@modules/codegen/components/base.component";
import { HxMatchGreater, HxMatchToBeTrue, HxMatchContainEqual, HxMatchInclude } from "@constants/sema.constant";
import { HxMatchGreaterEqual, HxMatchContain, HxMatchLessEqual, HxMatchEndWith } from "@constants/sema.constant";
import { elementPointer, extract, insert, finalType, typeName } from "@modules/codegen/components/base.component";
import { sourceText, sourcePath, terminated, errorUnionIsBare } from "@modules/codegen/components/base.component";
import { compareIntegers, lower, block, positionAtEnd, int1Type } from "@modules/codegen/components/base.component";
import { constErrorCode, optionalPresent, fnType, call, phiNode } from "@modules/codegen/components/base.component";
import { HxMatchStartWith, HxMatchToEqual, HxMatchToBe, HxMemberField, HxMatchThrow } from "@constants/sema.constant";
import { aggregate, member, declareC, llvmName, fatal, detourBegin } from "@modules/codegen/components/base.component";
import { HxMatchLength, HxMatchLess, HxMatchSucceed, HxMatchToBeNull, HxExpectRequire } from "@constants/sema.constant";
import { helperFunction, fromCString, nodeOf, infoOf, typeOf, extra } from "@modules/codegen/components/base.component";

/**
 * Checks whether {@link emitFormat} can write a value of a type.
 *
 * @param cg - The code generator
 * @param type - The Helix type
 * @param depth - How deep the check is inside the type, which stops the walk past 32 levels
 * @returns `true` for the types that the checker lets `print` take, plus what tests compare
 *
 * @remarks
 * Integers of up to 64 bits, floats, booleans, pointers, enums, error sets, and strings can be written.
 * Optionals, arrays, and slices can when their element can, and structs and unions can when every field can.
 *
 * @since 1.0.0
 */

function canFormat(cg: *Cg, type: u32, depth: u32): bool {
    if (depth > 32) return true;
    const t = typeOf(cg, type);
    switch (t.kind) {
        case TypeKind.Int: return t.bits <= 64;
        case TypeKind.Float, TypeKind.Bool, TypeKind.Pointer, TypeKind.ManyPointer, TypeKind.Enum, TypeKind.ErrorSet,
             TypeKind.StringLiteral: return true;
        case TypeKind.Optional, TypeKind.Array, TypeKind.Slice: return canFormat(cg, t.child, depth + 1);
        case TypeKind.Struct, TypeKind.Union: {
            const agg = aggregate(cg, type);
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind == HxMemberField as u8 && m.type != 0 && !canFormat(cg, m.type, depth + 1)) return false;
            }
            return true;
        }
        default: return false;
    }
}

/**
 * Writes a value for a failure report.
 *
 * @param cg - The code generator
 * @param w - The writer
 * @param v - The value
 * @param type - The Helix type of the value
 *
 * @remarks
 * The value is written as `print` would, with strings in quotes,
 * or as `<type>` when it cannot be written.
 *
 * @since 1.0.0
 */

function writeValue(cg: *Cg, w: Value, v: Value, type: u32): void {
    if (canFormat(cg, type, 0)) {
        emitFormat(cg, w, v, type, true);
        return;
    }
    writeText(cg, w, fromCString(llvmName(cg, `<${typeName(cg, type)}>`)));
}

/**
 * Checks two values for equality, as `toBe` and `toEqual` do.
 *
 * @param cg - The code generator
 * @param a - The first value
 * @param b - The second value
 * @param type - The Helix type of both values
 * @returns An `i1` that is true when both values are the same
 *
 * @remarks
 * Scalars compare in place, and floats compare ordered, so `NaN` never equals itself.
 * Strings compare their bytes.
 * Optionals, error unions, structs, unions, arrays, and other slices call {@link equalFn},
 * which compares them deeply.
 *
 * @since 1.0.0
 */

function emitEqual(cg: *Cg, a: Value, b: Value, type: u32): Value {
    const t = typeOf(cg, type);
    switch (t.kind) {
        case TypeKind.Int, TypeKind.Bool, TypeKind.Enum, TypeKind.ErrorSet, TypeKind.Pointer, TypeKind.ManyPointer,
             TypeKind.Function: return compareIntegers(cg, llvm.LLVMIntEQ, a, b);
        case TypeKind.Float: return llvm.LLVMBuildFCmp(cg.b, llvm.LLVMRealOEQ, a, b, "");
        case TypeKind.StringLiteral: return stringEqual(cg, a, b);
        case TypeKind.Slice: if (t.child == cg.types.u8) return stringEqual(cg, a, b);
        default: {}
    }
    const params: Type[2] = [lower(cg, type), lower(cg, type)];
    const fnT = fnType(int1Type(cg), &params, false);
    const args: Value[2] = [a, b];
    return call(cg, fnT, equalFn(cg, type), &args, "");
}

/**
 * Returns a constant boolean from the current function.
 *
 * @param cg - The code generator
 * @param v - The boolean to return
 *
 * @remarks
 * The equality functions that {@link equalFn} builds end each branch with it,
 * so the current block is finished afterwards and needs a new position before more code.
 *
 * @since 1.0.0
 */

function returnBool(cg: *Cg, v: bool): void {
    void llvm.LLVMBuildRet(cg.b, constBool(cg, v));
}

/**
 * Returns a pointer to an element of a sequence.
 *
 * @param cg - The code generator
 * @param type - The LLVM type of an element
 * @param base - A pointer to the first element
 * @param i - The index of the element
 * @returns A pointer to element `i`
 *
 * @remarks
 * It takes a single index, so it steps over whole elements from the base rather than into a field.
 *
 * @since 1.0.0
 */

function elementPtr(cg: *Cg, type: Type, base: Value, i: Value): Value {
    const indices: Value[1] = [i];
    return elementPointer(cg, type, base, &indices, "");
}

/**
 * Compares the elements of two sequences inside an {@link equalFn}.
 *
 * @param cg - The code generator
 * @param a - A pointer to the first element of one sequence
 * @param b - A pointer to the first element of the other sequence
 * @param count - The number of elements to compare
 * @param elem - The Helix type of an element
 *
 * @remarks
 * The function returns `false` at the first pair that differs.
 * When every pair is equal, the builder continues after the loop.
 *
 * @since 1.0.0
 */

function compareElements(cg: *Cg, a: Value, b: Value, count: Value, elem: u32): void {
    const usize = cg.usizeType;
    const counter = entryAlloca(cg, usize, "i");
    store(cg, constUsize(cg, 0), counter);
    const cond = block(cg, "elems.cond");
    const body = block(cg, "elems.body");
    const next = block(cg, "elems.next");
    const differ = block(cg, "elems.differ");
    const end = block(cg, "elems.end");
    branch(cg, cond);

    positionAtEnd(cg, cond);
    const i = load(cg, usize, counter, "");
    condBr(cg, compareIntegers(cg, llvm.LLVMIntULT, i, count), body, end);

    positionAtEnd(cg, body);
    const elemType = lower(cg, elem);
    const x = load(cg, elemType, elementPtr(cg, elemType, a, i), "");
    const y = load(cg, elemType, elementPtr(cg, elemType, b, i), "");
    condBr(cg, emitEqual(cg, x, y, elem), next, differ);

    positionAtEnd(cg, next);
    store(cg, llvm.LLVMBuildNUWAdd(cg.b, i, constUsize(cg, 1), ""), counter);
    branch(cg, cond);

    positionAtEnd(cg, differ);
    returnBool(cg, false);
    positionAtEnd(cg, end);
}

/**
 * Returns the generated function that compares two values of a type.
 *
 * @param cg - The code generator
 * @param type - The Helix type, an optional, error union, struct, union, array, or slice
 * @returns The function `helix.equal.<type>(a, b) -> i1`, made once per type
 *
 * @remarks
 * - **Optionals** - equal when both are null, or both are present with equal payloads
 * - **Error unions** - equal with the same error, or when both succeeded with equal values
 * - **Structs** - equal when every field is equal
 * - **Unions** - equal with the same variant and equal payloads
 * - **Arrays and slices** - equal with the same length and equal elements
 *
 * The function is cached before its body is emitted, so a recursive type calls back into it.
 *
 * @since 1.0.0
 */

function equalFn(cg: *Cg, type: u32): Value {
    if (cg.equalFns[type] != null) return cg.equalFns[type];
    const llvmType = lower(cg, type);
    const params: Type[2] = [llvmType, llvmType];
    const fn = helperFunction(cg, llvmName(cg, `helix.equal.${type}`), fnType(int1Type(cg), &params, false));
    cg.equalFns[type] = fn;   // cached before the body, so recursive types call back into it

    const saved = detourBegin(cg, fn);
    const a = llvm.LLVMGetParam(fn, 0);
    const b = llvm.LLVMGetParam(fn, 1);
    const t = typeOf(cg, type);
    switch (t.kind) {
        case TypeKind.Optional: {   // both null, or both present and equal
            const hasA = optionalPresent(cg, a, type);
            const hasB = optionalPresent(cg, b, type);
            const both = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "both");
            const other = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "other");
            condBr(cg, llvm.LLVMBuildAnd(cg.b, hasA, hasB, ""), both, other);
            positionAtEnd(cg, both);
            void llvm.LLVMBuildRet(cg.b, emitEqual(cg, optionalPayload(cg, a, type), optionalPayload(cg, b, type), t.child));
            positionAtEnd(cg, other);
            void llvm.LLVMBuildRet(cg.b, compareIntegers(cg, llvm.LLVMIntEQ, hasA, hasB));
        }
        case TypeKind.ErrorUnion: {   // the same error, or both succeeded with equal values
            const codeA = errorUnionCode(cg, a, type);
            const same = compareIntegers(cg, llvm.LLVMIntEQ, codeA, errorUnionCode(cg, b, type));
            if (errorUnionIsBare(cg, type)) {
                void llvm.LLVMBuildRet(cg.b, same);
            } else {
                const values = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "values");
                const done = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "done");
                const succeeded = compareIntegers(cg, llvm.LLVMIntEQ, codeA, constErrorCode(cg, 0));
                condBr(cg, llvm.LLVMBuildAnd(cg.b, same, succeeded, ""), values, done);
                positionAtEnd(cg, values);
                void llvm.LLVMBuildRet(cg.b, emitEqual(cg, errorUnionPayload(cg, a, type), errorUnionPayload(cg, b, type), t.child));
                positionAtEnd(cg, done);
                void llvm.LLVMBuildRet(cg.b, same);
            }
        }
        case TypeKind.Struct: {
            const agg = aggregate(cg, type);
            const differ = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "differ");
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind != HxMemberField as u8) continue;
                const same = emitEqual(cg, extract(cg, a, m.index, ""), extract(cg, b, m.index, ""), m.type);
                const next = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "field");
                condBr(cg, same, next, differ);
                positionAtEnd(cg, next);
            }
            returnBool(cg, true);
            positionAtEnd(cg, differ);
            returnBool(cg, false);
        }
        case TypeKind.Union: {   // the same variant with equal payloads
            const agg = aggregate(cg, type);
            const slotA = entryAlloca(cg, llvmType, "a");
            const slotB = entryAlloca(cg, llvmType, "b");
            store(cg, a, slotA);
            store(cg, b, slotB);
            const tag = extract(cg, a, 0, "tag");
            const sameTag = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "same");
            const differ = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "differ");
            const noPayload = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "bare");
            condBr(cg, compareIntegers(cg, llvm.LLVMIntEQ, tag, extract(cg, b, 0, "")), sameTag, differ);
            positionAtEnd(cg, sameTag);
            const sw = llvm.LLVMBuildSwitch(cg.b, tag, noPayload, agg.fieldCount);
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind != HxMemberField as u8 || m.type == 0) continue;
                const variant = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "variant");
                llvm.LLVMAddCase(sw, llvm.LLVMConstInt(lower(cg, t.child), m.index as u64, 0), variant);
                positionAtEnd(cg, variant);
                const payloadType = lower(cg, m.type);
                const x = load(cg, payloadType, llvm.LLVMBuildStructGEP2(cg.b, llvmType, slotA, 1, ""), "");
                const y = load(cg, payloadType, llvm.LLVMBuildStructGEP2(cg.b, llvmType, slotB, 1, ""), "");
                void llvm.LLVMBuildRet(cg.b, emitEqual(cg, x, y, m.type));
            }
            positionAtEnd(cg, noPayload);
            returnBool(cg, true);
            positionAtEnd(cg, differ);
            returnBool(cg, false);
        }
        case TypeKind.Array: {
            const slotA = entryAlloca(cg, llvmType, "a");
            const slotB = entryAlloca(cg, llvmType, "b");
            store(cg, a, slotA);
            store(cg, b, slotB);
            compareElements(cg, slotA, slotB, constUsize(cg, t.len), t.child);
            returnBool(cg, true);
        }
        case TypeKind.Slice: {
            const items = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "items");
            const differ = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "differ");
            const len = extract(cg, a, 1, "");
            condBr(cg, compareIntegers(cg, llvm.LLVMIntEQ, len, extract(cg, b, 1, "")), items, differ);
            positionAtEnd(cg, differ);
            returnBool(cg, false);
            positionAtEnd(cg, items);
            compareElements(cg, extract(cg, a, 0, ""), extract(cg, b, 0, ""), len, t.child);
            returnBool(cg, true);
        }
        default: fatal(cg, `codegen: no equality for type kind ${t.kind as u32}`);
    }
    detourEnd(cg, saved);
    return fn;
}

/**
 * Returns the base pointer and the length of an array, a slice, or a string.
 *
 * @param cg - The code generator
 * @param v - The value
 * @param type - The Helix type of the value
 * @param ptr - Receives a pointer to the first item
 * @param len - Receives the number of items
 *
 * @remarks
 * An array is stored to the stack first, so its items have an address.
 *
 * @since 1.0.0
 */

function itemsOf(cg: *Cg, v: Value, type: u32, ptr: *Value, len: *Value): void {
    if (typeOf(cg, type).kind == TypeKind.Array) {
        *ptr = entryAlloca(cg, lower(cg, type), "items");
        store(cg, v, *ptr);
        *len = constUsize(cg, typeOf(cg, type).len);
        return;
    }
    *ptr = extract(cg, v, 0, "");
    *len = extract(cg, v, 1, "");
}

/**
 * Checks whether any item of a sequence equals a value, as `toContain` does.
 *
 * @param cg - The code generator
 * @param items - The array, slice, or string
 * @param type - The Helix type of `items`
 * @param x - The value to look for
 * @returns An `i1` that is true when an item equals `x`
 *
 * @remarks
 * The loop stops at the first equal item, and the result comes from a phi over the loop exit and the match.
 * It copies an array to the stack first, since the loop reads its items through a pointer.
 *
 * @since 1.0.0
 */

function emitContains(cg: *Cg, items: Value, type: u32, x: Value): Value {
    const elem = typeOf(cg, type).child;
    let base: Value = null;
    let count: Value = null;
    itemsOf(cg, items, type, &base, &count);
    const usize = cg.usizeType;
    const counter = entryAlloca(cg, usize, "i");
    store(cg, constUsize(cg, 0), counter);
    const cond = block(cg, "contains.cond");
    const body = block(cg, "contains.body");
    const next = block(cg, "contains.next");
    const end = block(cg, "contains.end");
    branch(cg, cond);

    positionAtEnd(cg, cond);
    const i = load(cg, usize, counter, "");
    condBr(cg, compareIntegers(cg, llvm.LLVMIntULT, i, count), body, end);
    positionAtEnd(cg, body);
    const item = load(cg, lower(cg, elem), elementPtr(cg, lower(cg, elem), base, i), "");
    const found = emitEqual(cg, item, x, elem);
    const bodyEnd = llvm.LLVMGetInsertBlock(cg.b);
    condBr(cg, found, end, next);
    positionAtEnd(cg, next);
    store(cg, llvm.LLVMBuildNUWAdd(cg.b, i, constUsize(cg, 1), ""), counter);
    branch(cg, cond);

    positionAtEnd(cg, end);
    const values: Value[2] = [constBool(cg, false), constBool(cg, true)];
    const blocks: Block[2] = [cond, bodyEnd];
    return phiNode(cg, int1Type(cg), &values, &blocks, "contains");
}

/**
 * Writes a label of a failure report, followed by `not ` when the matcher is negated.
 *
 * @param cg - The code generator
 * @param w - The writer
 * @param label - The label, such as `Expected: `
 * @param negated - `true` when the matcher follows `.not`
 *
 * @remarks
 * Every line of a report that names a matcher goes through it, so `.not` reads the same way on each line.
 *
 * @since 1.0.0
 */

function writeLabel(cg: *Cg, w: Value, label: string, negated: bool): void {
    writeText(cg, w, label);
    if (negated) writeText(cg, w, "not ");
}

/**
 * Writes what an error union holds, for the `Received: ` line of a failure report.
 *
 * @param cg - The code generator
 * @param w - The writer
 * @param v - The error union
 * @param type - The Helix type of the error union
 *
 * @remarks
 * A failure writes `error <name>`.
 * A success writes its value, or `success` for an error union without a value.
 *
 * @since 1.0.0
 */

function writeOutcome(cg: *Cg, w: Value, v: Value, type: u32): void {
    const code = errorUnionCode(cg, v, type);
    const failed = block(cg, "failed");
    const succeeded = block(cg, "succeeded");
    const end = block(cg, "end");
    condBr(cg, compareIntegers(cg, llvm.LLVMIntNE, code, constErrorCode(cg, 0)), failed, succeeded);
    positionAtEnd(cg, failed);
    writeText(cg, w, "error ");
    writeCstr(cg, w, errorName(cg, code));
    branch(cg, end);
    positionAtEnd(cg, succeeded);
    if (errorUnionIsBare(cg, type)) writeText(cg, w, "success");
    else writeValue(cg, w, errorUnionPayload(cg, v, type), typeOf(cg, type).child);
    branch(cg, end);
    positionAtEnd(cg, end);
}

/**
 * Returns what a comparing matcher puts before the expected value in a failure report.
 *
 * @param matcher - The matcher
 * @returns The text, such as `> ` for `toBeGreaterThan` or `to contain ` for `toContain`, or an empty string
 *
 * @remarks
 * The report then reads like `Expected: > 3`.
 *
 * @since 1.0.0
 */

function matcherWhat(matcher: u32): string {
    if (matcher == HxMatchGreater) return "> ";
    if (matcher == HxMatchGreaterEqual) return ">= ";
    if (matcher == HxMatchLess) return "< ";
    if (matcher == HxMatchLessEqual) return "<= ";
    if (matcher == HxMatchCloseTo) return "close to ";
    if (matcher == HxMatchContain || matcher == HxMatchContainEqual) return "to contain ";
    if (matcher == HxMatchStartWith) return "to start with ";
    if (matcher == HxMatchEndWith) return "to end with ";
    if (matcher == HxMatchInclude) return "to include ";
    if (matcher == HxMatchMatch) return "to match ";
    return "";
}

/**
 * Generates the function that reports a failed `expect`.
 *
 * @param cg - The code generator
 * @param node - The `expect` node
 * @param matcher - The matcher
 * @param negated - `true` when the matcher follows `.not`
 * @param actualType - The Helix type of the subject
 * @param argTypes - The Helix types of the arguments of the matcher
 * @returns The function `helix.expect.failed`, which takes the subject and the arguments
 *
 * @remarks
 * The report holds the source of the expression, what was expected, what was received, and where the call is.
 * The function writes it to descriptor 3, which carries the report of the test.
 * It is cold and never inlined, so the code of a passing check stays small.
 *
 * @since 1.0.0
 */

function expectReportFn(cg: *Cg, node: u32, matcher: u32, negated: bool, actualType: u32, argTypes: readonly u32[]): Value {
    let params: Type[3] = [lower(cg, actualType), null, null];
    for (const t, i of argTypes) params[i + 1] = lower(cg, t);
    const all: *Type[3] = &params;
    const fn = helperFunction(cg, "helix.expect.failed", fnType(lower(cg, cg.types.errorCode), all[0..argTypes.len + 1], false));
    addAttribute(cg, fn, "cold");
    addAttribute(cg, fn, "noinline");

    const savedScope = cg.diScope;
    cg.diScope = null;
    const saved = detourBegin(cg, fn);
    const w = fdWriter(cg, 3);
    const v = llvm.LLVMGetParam(fn, 0);
    const x = argTypes.len > 0 ? llvm.LLVMGetParam(fn, 1) : null;
    const xType = argTypes.len > 0 ? argTypes[0] : 0;

    let start: u32 = 0;
    let len: u32 = 0;
    hxNodeSpan(cg.ast, node, &start, &len);
    writeText(cg, w, sourceText(cg, start, len));
    writeText(cg, w, "\n\n");
    if (matcher == HxMatchToBeNull) {
        writeLabel(cg, w, "Expected: ", negated);
        writeText(cg, w, "null");
    } else if (matcher == HxMatchToBeDefined) {
        writeLabel(cg, w, "Expected: ", negated);
        writeText(cg, w, "a value");
    } else if (matcher == HxMatchToBeTrue) {
        writeLabel(cg, w, "Expected: ", negated);
        writeText(cg, w, "true");
    } else if (matcher == HxMatchToBeFalse) {
        writeLabel(cg, w, "Expected: ", negated);
        writeText(cg, w, "false");
    } else if (matcher == HxMatchSucceed) {
        writeLabel(cg, w, "Expected: ", negated);
        writeText(cg, w, "success");
    } else if (matcher == HxMatchThrow) {
        if (x != null) {
            writeLabel(cg, w, "Expected: ", negated);
            writeText(cg, w, "error ");
            writeCstr(cg, w, errorName(cg, x));
        } else {
            writeText(cg, w, negated ? "Expected: no error" : "Expected: an error");
        }
    } else if (matcher == HxMatchLength) {
        let base: Value = null;
        let count: Value = null;
        itemsOf(cg, v, actualType, &base, &count);
        writeLabel(cg, w, "Expected length: ", negated);
        writeValue(cg, w, x, xType);
        writeText(cg, w, "\nReceived length: ");
        writeValue(cg, w, count, cg.types.usize);
    } else {
        writeLabel(cg, w, "Expected: ", negated);
        writeText(cg, w, matcherWhat(matcher));
        writeValue(cg, w, x, xType);
    }
    writeText(cg, w, "\nReceived: ");
    if (typeOf(cg, actualType).kind == TypeKind.ErrorUnion) writeOutcome(cg, w, v, actualType);
    else writeValue(cg, w, v, actualType);

    const pos = hxSourceLineCol(cg.ast.src, start);
    writeText(cg, w, fromCString(llvmName(cg, `\n\nat ${sourcePath(cg, pos.file)}:${pos.line}:${pos.col}\n`)));
    void llvm.LLVMBuildRet(cg.b, llvm.LLVMConstNull(lower(cg, cg.types.errorCode)));
    detourEnd(cg, saved);
    cg.diScope = savedScope;
    return fn;
}

/**
 * Calls a function of the C runtime for tests, declaring it on first use.
 *
 * @param cg - The code generator
 * @param name - The name of the runtime function
 * @param ret - The LLVM result type
 * @param params - The LLVM parameter types
 * @param args - The arguments
 * @returns The result of the call
 *
 * @remarks
 * The matchers whose check lives in the runtime use it, `toBeCloseTo` through `hx_test_close_to`
 * and the text matchers through `hx_test_text`.
 * The declaration comes from {@link declareC}, so later calls reuse it.
 *
 * @since 1.0.0
 */

function callTestRt(cg: *Cg, name: readonly u8[*], ret: Type, params: readonly Type[], args: readonly Value[]): Value {
    const type = fnType(ret, params, false);
    return call(cg, type, declareC(cg, name, type), args, "");
}

/**
 * Emits `expect(x).matcher(...)` or `require(x).matcher(...)` in a test.
 *
 * @param cg - The code generator
 * @param node - The matcher call node
 * @returns `null` for `expect`, or the error code for `require`, 0 when the check passed
 *
 * @remarks
 * The subject and the arguments are evaluated once, and then the matcher checks them.
 * A failed check writes a report and calls the runtime's `hx_test_fail`, which marks the test as failed.
 * `expect` then goes on, and `require` returns the code of `TestError.RequireFailed`.
 * An array passed to `toEqual` on a slice compares as a slice of the array.
 * `toBeCloseTo` calls `hx_test_close_to` with 2 digits unless the test gives others,
 * and the text matchers call `hx_test_text`.
 *
 * @example
 * ```hx
 * // expect(sum).toBe(3);
 * emitExpect(cg, node); // null, after a branch to helix.expect.failed and hx_test_fail on a mismatch
 * ```
 *
 * @since 1.0.0
 */

export function emitExpect(cg: *Cg, node: u32): Value {
    const aux = infoOf(cg, node).aux;
    const matcher = aux & HxExpectMatcher;
    const negated = (aux & HxExpectNot) != 0;
    const isRequire = (aux & HxExpectRequire) != 0;
    let target = nodeOf(cg, nodeOf(cg, node).a).a;   // `expect(x)`, past the matcher and any `.not`
    if (negated) target = nodeOf(cg, target).a;
    const subjectArgs = record<HxRange>(cg.ast, nodeOf(cg, target).b);
    const args = record<HxRange>(cg.ast, nodeOf(cg, node).b);

    const subject = extra(cg, subjectArgs.start);
    const type = finalType(cg, subject);
    const v = emitValue(cg, subject);
    let x: Value[2] = [null, null];
    let xTypes: u32[2] = [0, 0];
    const count = args.end - args.start;
    for (const i of 0..count) {
        x[i] = emitValue(cg, extra(cg, args.start + i));
        xTypes[i] = finalType(cg, extra(cg, args.start + i));
        if (typeOf(cg, xTypes[i]).kind == TypeKind.Array && typeOf(cg, type).kind == TypeKind.Slice && x[i] != null) {   // `toEqual([1, 2])`
            let base: Value = null;
            let len: Value = null;
            itemsOf(cg, x[i], xTypes[i], &base, &len);
            x[i] = insert(cg, insert(cg, llvm.LLVMGetUndef(lower(cg, type)), base, 0), len, 1);
            xTypes[i] = type;
        }
    }
    if (terminated(cg)) return null;

    const i1t = int1Type(cg);
    const i32t = int32(cg);
    const i64t = int64(cg);
    const f64t = llvm.LLVMDoubleTypeInContext(cg.ctx);
    let pass: Value = null;
    if (matcher == HxMatchToBe || matcher == HxMatchToEqual) {
        pass = emitEqual(cg, v, x[0], type);
    } else if (matcher == HxMatchToBeNull) {
        pass = llvm.LLVMBuildNot(cg.b, optionalPresent(cg, v, type), "");
    } else if (matcher == HxMatchToBeDefined) {
        pass = optionalPresent(cg, v, type);
    } else if (matcher == HxMatchToBeTrue) {
        pass = v;
    } else if (matcher == HxMatchToBeFalse) {
        pass = llvm.LLVMBuildNot(cg.b, v, "");
    } else if (matcher == HxMatchGreater) {
        pass = emitCompare(cg, BinOp.Gt, v, x[0], type);
    } else if (matcher == HxMatchGreaterEqual) {
        pass = emitCompare(cg, BinOp.Ge, v, x[0], type);
    } else if (matcher == HxMatchLess) {
        pass = emitCompare(cg, BinOp.Lt, v, x[0], type);
    } else if (matcher == HxMatchLessEqual) {
        pass = emitCompare(cg, BinOp.Le, v, x[0], type);
    } else if (matcher == HxMatchCloseTo) {
        const a = typeOf(cg, type).bits < 64 ? llvm.LLVMBuildFPExt(cg.b, v, f64t, "") : v;
        const b = typeOf(cg, type).bits < 64 ? llvm.LLVMBuildFPExt(cg.b, x[0], f64t, "") : x[0];
        const digits = count > 1 ? x[1] : llvm.LLVMConstInt(i32t, 2, 0);
        const params: Type[3] = [f64t, f64t, i32t];
        const callArgs: Value[3] = [a, b, digits];
        pass = callTestRt(cg, "hx_test_close_to", i1t, &params, &callArgs);
    } else if (matcher == HxMatchLength) {
        let base: Value = null;
        let len: Value = null;
        itemsOf(cg, v, type, &base, &len);
        pass = compareIntegers(cg, llvm.LLVMIntEQ, len, x[0]);
    } else if (matcher == HxMatchContain || matcher == HxMatchContainEqual) {
        pass = emitContains(cg, v, type, x[0]);
    } else if (matcher >= HxMatchStartWith && matcher <= HxMatchMatch) {
        const callArgs: Value[5] = [llvm.LLVMConstInt(i32t, (matcher - HxMatchStartWith) as u64, 0),
                                    extract(cg, v, 0, ""), extract(cg, v, 1, ""), extract(cg, x[0], 0, ""), extract(cg, x[0], 1, "")];
        const params: Type[5] = [i32t, cg.ptrType, i64t, cg.ptrType, i64t];
        pass = callTestRt(cg, "hx_test_text", i1t, &params, &callArgs);
    } else if (matcher == HxMatchThrow) {
        const code = errorUnionCode(cg, v, type);
        pass = x[0] != null ? compareIntegers(cg, llvm.LLVMIntEQ, code, x[0]) : compareIntegers(cg, llvm.LLVMIntNE, code, constErrorCode(cg, 0));
    } else if (matcher == HxMatchSucceed) {
        pass = compareIntegers(cg, llvm.LLVMIntEQ, errorUnionCode(cg, v, type), constErrorCode(cg, 0));
    }
    if (negated) pass = llvm.LLVMBuildNot(cg.b, pass, "");

    const fail = block(cg, "expect.failed");
    const ok = block(cg, "expect.ok");
    const hintArgs: Value[2] = [pass, constBool(cg, true)];
    const checkBlock = llvm.LLVMGetInsertBlock(cg.b);
    condBr(cg, callIntrinsic(cg, "llvm.expect", i1t, &hintArgs), ok, fail);

    positionAtEnd(cg, fail);
    const allTypes: *u32[2] = &xTypes;
    const report = expectReportFn(cg, node, matcher, negated, type, allTypes[0..count]);
    let reportArgs: Value[3] = [v, x[0], x[1]];
    let reportParams: Type[3] = [lower(cg, type), count > 0 ? lower(cg, xTypes[0]) : null, count > 1 ? lower(cg, xTypes[1]) : null];
    const allParams: *Type[3] = &reportParams;
    const allArgs: *Value[3] = &reportArgs;
    void call(cg, fnType(lower(cg, cg.types.errorCode), allParams[0..count + 1], false), report, allArgs[0..count + 1], "");
    void callTestRt(cg, "hx_test_fail", voidType(cg), [], []);
    const failEnd = llvm.LLVMGetInsertBlock(cg.b);
    branch(cg, ok);

    positionAtEnd(cg, ok);
    if (!isRequire) return null;
    const codeType = lower(cg, cg.types.errorCode);
    const codes: Value[2] = [llvm.LLVMConstNull(codeType), llvm.LLVMConstInt(codeType, cg.sema.requireCode as u64, 0)];
    const from: Block[2] = [checkBlock, failEnd];
    return phiNode(cg, codeType, &codes, &from, "require");
}
