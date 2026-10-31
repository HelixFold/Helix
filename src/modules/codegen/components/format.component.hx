/**
 * Imports
 */

import { record } from "@models/ast.model";
import { NodeKind } from "@constants/ast.constant";
import { HxRange } from "@models/structs/ast-model.struct";
import { TypeKind, Signed } from "@constants/types.constant";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { emitValue, errorName } from "@modules/codegen/components/expr.component";
import { Piece } from "@modules/codegen/components/structs/format-component.struct";
import { Cg, Value, Type } from "@modules/codegen/components/structs/base-component.struct";
import { finalType, block, positionAtEnd, int32, int64 } from "@modules/codegen/components/base.component";
import { HxPrintln, HxEprint, HxMemberField, HxEprintln, HxMemberEnumValue } from "@constants/sema.constant";
import { call, constArray, structType, extract, tokenText } from "@modules/codegen/components/base.component";
import { constUsize, cstring, optionalPresent, nodeOf, infoOf } from "@modules/codegen/components/base.component";
import { detourBegin, detourEnd, helperFunction, insert, load } from "@modules/codegen/components/base.component";
import { store, branch, condBr, compareIntegers, lower, constInt } from "@modules/codegen/components/base.component";
import { entryAlloca, declareC, llvmName, fatal, voidType, fnType } from "@modules/codegen/components/base.component";
import { typeOf, extra, value, aggregate, member, optionalPayload } from "@modules/codegen/components/base.component";

/**
 * Returns the LLVM type of the `write` slot of a writer's vtable.
 *
 * @param cg - The code generator
 * @returns The type of `write(this, bytes: readonly u8[]): void | Error`, which returns an error code
 *
 * @remarks
 * The slot takes the writer's data pointer and a byte slice, and it returns an error code, where 0 means success.
 * {@link writeBytes} calls the slot through a loaded pointer,
 * so the type comes from here rather than from a declaration.
 *
 * @since 1.0.0
 */

function writeSlotType(cg: *Cg): Type {
    const params: Type[2] = [cg.ptrType, cg.sliceType];
    return fnType(lower(cg, cg.types.errorCode), &params, false);
}

/**
 * Returns the LLVM type of a template's formatter.
 *
 * @param cg - The code generator
 * @returns The type of `(values: ptr, w: dyn Writer) -> code`, where code 0 means that every write succeeded
 *
 * @remarks
 * A template passed to a `Format` parameter becomes a pair of a pointer to its values and its formatter.
 * Calling the formatter with the values and a writer writes the template.
 *
 * @example
 * ```hx
 * formatterType(cg); // i16 (ptr, { ptr, ptr })
 * ```
 *
 * @see emitFormatValue
 * @since 1.0.0
 */

export function formatterType(cg: *Cg): Type {
    const params: Type[2] = [cg.ptrType, cg.dynType];
    return fnType(lower(cg, cg.types.errorCode), &params, false);
}

/**
 * Returns an error code from the current formatting function unless it is 0.
 *
 * @param cg - The code generator
 * @param code - The error code of a write
 *
 * @remarks
 * Every formatting function stops at the first write that fails and returns its code.
 * The builder continues in the block where the write succeeded.
 *
 * @since 1.0.0
 */

function checkCode(cg: *Cg, code: Value): void {
    const fail = block(cg, "write.failed");
    const ok = block(cg, "write.ok");
    const failed = compareIntegers(cg, llvm.LLVMIntNE, code, llvm.LLVMConstNull(llvm.LLVMTypeOf(code)));
    condBr(cg, failed, fail, ok);
    positionAtEnd(cg, fail);
    void llvm.LLVMBuildRet(cg.b, code);
    positionAtEnd(cg, ok);
}

/**
 * Writes bytes to a writer through the `write` slot of its vtable.
 *
 * @param cg - The code generator
 * @param w - The writer, a `dyn` value of a data pointer and a vtable
 * @param ptr - The first byte
 * @param len - The number of bytes
 *
 * @remarks
 * The writer is a `dyn` pair, so the call loads the slot from the vtable at run time.
 * A failed write returns its code from the current formatting function through {@link checkCode}.
 *
 * @since 1.0.0
 */

function writeBytes(cg: *Cg, w: Value, ptr: Value, len: Value): void {
    const data = extract(cg, w, 0, "");
    const table = extract(cg, w, 1, "");
    const write = load(cg, cg.ptrType, table, "write");
    let bytes = insert(cg, llvm.LLVMGetUndef(cg.sliceType), ptr, 0);
    bytes = insert(cg, bytes, len, 1);
    const args: Value[2] = [data, bytes];
    checkCode(cg, call(cg, writeSlotType(cg), write, &args, ""));
}

/**
 * Writes a constant text to a writer.
 *
 * @param cg - The code generator
 * @param w - The writer
 * @param text - The text, which becomes a constant of the module
 *
 * @remarks
 * An empty text writes nothing and emits no call.
 *
 * @example
 * ```hx
 * writeText(cg, w, "null"); // calls the write slot with "null" and 4
 * ```
 *
 * @since 1.0.0
 */

export function writeText(cg: *Cg, w: Value, text: string): void {
    if (text.len > 0) writeBytes(cg, w, cstring(cg, text, "text"), constUsize(cg, text.len as u64));
}

/**
 * Formats a number into a stack buffer with a runtime function, then writes it.
 *
 * @param cg - The code generator
 * @param w - The writer
 * @param name - The runtime function, one of the `hx_format_*` functions of `lib/rt/runtime.c`
 * @param v - The number
 *
 * @remarks
 * The buffer holds 48 bytes, and the runtime function returns how many of them it used.
 *
 * @since 1.0.0
 */

function writeNumber(cg: *Cg, w: Value, name: readonly u8[*], v: Value): void {
    const params: Type[2] = [cg.ptrType, llvm.LLVMTypeOf(v)];
    const type = fnType(cg.usizeType, &params, false);
    const buf = entryAlloca(cg, llvm.LLVMArrayType2(llvm.LLVMInt8TypeInContext(cg.ctx), 48), "digits");
    const args: Value[2] = [buf, v];
    const len = call(cg, type, declareC(cg, name, type), &args, "");
    writeBytes(cg, w, buf, len);
}

/**
 * Writes a NUL-terminated string to a writer.
 *
 * @param cg - The code generator
 * @param w - The writer
 * @param ptr - The string
 *
 * @remarks
 * Error names and `u8[*]` values are written this way, with `strlen` giving the length.
 *
 * @example
 * ```hx
 * writeCstr(cg, w, errorName(cg, code)); // writes "NotFound"
 * ```
 *
 * @since 1.0.0
 */

export function writeCstr(cg: *Cg, w: Value, ptr: Value): void {
    const params: Type[1] = [cg.ptrType];
    const type = fnType(cg.usizeType, &params, false);
    const args: Value[1] = [ptr];
    const len = call(cg, type, declareC(cg, "strlen", type), &args, "");
    writeBytes(cg, w, ptr, len);
}

/**
 * Writes a value of a type to a writer.
 *
 * @param cg - The code generator
 * @param w - The writer
 * @param v0 - The value
 * @param type - The Helix type of the value
 * @param quoted - `true` to put strings in quotes, as they are inside structs, arrays, and optionals
 *
 * @remarks
 * Scalars are written directly.
 * Integers go through `hx_format_i64` or `hx_format_u64`, floats through `hx_format_f32` or `hx_format_f64`,
 * and pointers through `hx_format_ptr`.
 * Booleans write `true` or `false`, error sets write their name, and `u8[*]` writes the string it points to.
 * Structs, unions, enums, optionals, arrays, and slices other than strings call one generated function per type,
 * so the formatting code of each type exists once no matter how often the program prints it.
 *
 * @example
 * ```hx
 * emitFormat(cg, w, v, i32, false);         // calls hx_format_i64
 * emitFormat(cg, w, s, pointType, false);   // calls helix.format.<type>, which writes { x: 1, y: 2 }
 * ```
 *
 * @see printFn
 * @since 1.0.0
 */

export function emitFormat(cg: *Cg, w: Value, v0: Value, type: u32, quoted: bool): void {
    let v = v0;
    const t = typeOf(cg, type);
    switch (t.kind) {
        case TypeKind.Int: {
            const sign = (t.flags & Signed) != 0;
            const i64t = int64(cg);
            if (t.bits < 64) v = sign ? llvm.LLVMBuildSExt(cg.b, v, i64t, "") : llvm.LLVMBuildZExt(cg.b, v, i64t, "");
            writeNumber(cg, w, sign ? "hx_format_i64" : "hx_format_u64", v);
            return;
        }
        case TypeKind.Bool: {
            const text = llvm.LLVMBuildSelect(cg.b, v, cstring(cg, "true", "true"), cstring(cg, "false", "false"), "");
            writeBytes(cg, w, text, llvm.LLVMBuildSelect(cg.b, v, constUsize(cg, 4), constUsize(cg, 5), ""));
            return;
        }
        case TypeKind.Float: {
            if (t.bits < 32) v = llvm.LLVMBuildFPExt(cg.b, v, llvm.LLVMFloatTypeInContext(cg.ctx), "");
            if (t.bits > 64) v = llvm.LLVMBuildFPTrunc(cg.b, v, llvm.LLVMDoubleTypeInContext(cg.ctx), "");
            writeNumber(cg, w, t.bits <= 32 ? "hx_format_f32" : "hx_format_f64", v);
            return;
        }
        case TypeKind.ErrorSet: {
            writeCstr(cg, w, errorName(cg, v));
            return;
        }
        case TypeKind.Pointer: {
            writeNumber(cg, w, "hx_format_ptr", v);
            return;
        }
        case TypeKind.ManyPointer: {
            if (t.child == cg.types.u8) {
                if (quoted) writeText(cg, w, "\"");
                writeCstr(cg, w, v);
                if (quoted) writeText(cg, w, "\"");
            } else {
                writeNumber(cg, w, "hx_format_ptr", v);
            }
            return;
        }
        case TypeKind.Slice, TypeKind.StringLiteral: {
            if (t.kind == TypeKind.StringLiteral || t.child == cg.types.u8) {
                if (quoted) writeText(cg, w, "\"");
                writeBytes(cg, w, extract(cg, v, 0, ""), extract(cg, v, 1, ""));
                if (quoted) writeText(cg, w, "\"");
                return;
            }
        }
        default: {}
    }
    const fn = printFn(cg, type, quoted);
    const params: Type[2] = [cg.dynType, lower(cg, type)];
    const fnT = fnType(lower(cg, cg.types.errorCode), &params, false);
    const args: Value[2] = [w, v];
    checkCode(cg, call(cg, fnT, fn, &args, ""));
}

/**
 * Writes elements in brackets, separated by commas.
 *
 * @param cg - The code generator
 * @param w - The writer
 * @param base - A pointer to the first element
 * @param count - The number of elements
 * @param elem - The Helix type of an element
 *
 * @remarks
 * The output looks like `[a, b, c]`, with string elements in quotes.
 *
 * @since 1.0.0
 */

function emitFormatElements(cg: *Cg, w: Value, base: Value, count: Value, elem: u32): void {
    const usize = cg.usizeType;
    const counter = entryAlloca(cg, usize, "i");
    store(cg, constUsize(cg, 0), counter);
    writeText(cg, w, "[");
    const cond = block(cg, "elems.cond");
    const body = block(cg, "elems.body");
    const sep = block(cg, "elems.sep");
    const item = block(cg, "elems.item");
    const end = block(cg, "elems.end");
    branch(cg, cond);

    positionAtEnd(cg, cond);
    const i = load(cg, usize, counter, "");
    condBr(cg, compareIntegers(cg, llvm.LLVMIntULT, i, count), body, end);

    positionAtEnd(cg, body);
    condBr(cg, compareIntegers(cg, llvm.LLVMIntEQ, i, constUsize(cg, 0)), item, sep);
    positionAtEnd(cg, sep);
    writeText(cg, w, ", ");
    branch(cg, item);

    positionAtEnd(cg, item);
    const indices: Value[1] = [i];
    let ptr: Value = null;
    unsafe {
        ptr = llvm.LLVMBuildInBoundsGEP2(cg.b, lower(cg, elem), base, @ptrCast(?Value[*], &indices), 1, "");
    }
    emitFormat(cg, w, load(cg, lower(cg, elem), ptr, ""), elem, true);
    store(cg, llvm.LLVMBuildNUWAdd(cg.b, i, constUsize(cg, 1), ""), counter);
    branch(cg, cond);

    positionAtEnd(cg, end);
    writeText(cg, w, "]");
}

/**
 * Returns the generated function that writes a value of a type.
 *
 * @param cg - The code generator
 * @param type - The Helix type, an optional, enum, struct, union, array, or slice
 * @param quoted - `true` for the variant that puts strings in quotes
 * @returns The function `helix.format.<type>`, or `helix.format.<type>.q` when quoted, made once per type
 *
 * @remarks
 * Optionals write their payload or `null`, enums write the name of their member or `?`,
 * structs write `{ name: value, ... }` or `{}`, unions write `variant(payload)`,
 * and arrays and slices write `[a, b]`.
 * The function is cached before its body is emitted, so a recursive type calls back into it.
 *
 * @since 1.0.0
 */

function printFn(cg: *Cg, type: u32, quoted: bool): Value {
    let key = type * 2;
    if (quoted) key += 1;
    if (cg.printFns[key] != null) return cg.printFns[key];

    const codeType = lower(cg, cg.types.errorCode);
    const params: Type[2] = [cg.dynType, lower(cg, type)];
    const fnT = fnType(codeType, &params, false);
    const fn = helperFunction(cg, llvmName(cg, `helix.format.${type}${quoted ? ".q" : ""}`), fnT);
    cg.printFns[key] = fn;   // cached before the body, so recursive types call back into it

    const saved = detourBegin(cg, fn);
    const w = llvm.LLVMGetParam(fn, 0);
    const v = llvm.LLVMGetParam(fn, 1);
    const t = typeOf(cg, type);

    switch (t.kind) {
        case TypeKind.Optional: {
            const some = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "some");
            const none = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "none");
            const end = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "end");
            condBr(cg, optionalPresent(cg, v, type), some, none);
            positionAtEnd(cg, some);
            emitFormat(cg, w, optionalPayload(cg, v, type), t.child, quoted);
            branch(cg, end);
            positionAtEnd(cg, none);
            writeText(cg, w, "null");
            branch(cg, end);
            positionAtEnd(cg, end);
        }
        case TypeKind.Enum: {
            const agg = aggregate(cg, type);
            const end = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "end");
            const unknown = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "unknown");
            const sw = llvm.LLVMBuildSwitch(cg.b, v, unknown, agg.fieldCount);
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind != HxMemberEnumValue as u8) continue;
                const b = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "member");
                llvm.LLVMAddCase(sw, constInt(lower(cg, type), m.value), b);
                positionAtEnd(cg, b);
                writeText(cg, w, tokenText(cg, m.token));
                branch(cg, end);
            }
            positionAtEnd(cg, unknown);
            writeText(cg, w, "?");
            branch(cg, end);
            positionAtEnd(cg, end);
        }
        case TypeKind.Struct: {
            const agg = aggregate(cg, type);
            if (agg.fieldCount == 0) {
                writeText(cg, w, "{}");
            } else {
                writeText(cg, w, "{ ");
                let first = true;
                for (const i of 0..agg.membersCount) {
                    const m = member(cg, agg, i);
                    if (m.kind != HxMemberField as u8) continue;
                    if (!first) writeText(cg, w, ", ");
                    first = false;
                    writeText(cg, w, tokenText(cg, m.token));
                    writeText(cg, w, ": ");
                    emitFormat(cg, w, extract(cg, v, m.index, ""), m.type, true);
                }
                writeText(cg, w, " }");
            }
        }
        case TypeKind.Union: {
            const agg = aggregate(cg, type);
            const llvmType = lower(cg, type);
            const slot = entryAlloca(cg, llvmType, "value");
            store(cg, v, slot);
            const tag = extract(cg, v, 0, "tag");
            const end = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "end");
            const sw = llvm.LLVMBuildSwitch(cg.b, tag, end, agg.fieldCount);
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind != HxMemberField as u8) continue;
                const b = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "variant");
                llvm.LLVMAddCase(sw, llvm.LLVMConstInt(lower(cg, t.child), m.index as u64, 0), b);
                positionAtEnd(cg, b);
                writeText(cg, w, tokenText(cg, m.token));
                if (m.type != 0) {
                    writeText(cg, w, "(");
                    const payload = llvm.LLVMBuildStructGEP2(cg.b, llvmType, slot, 1, "");
                    emitFormat(cg, w, load(cg, lower(cg, m.type), payload, ""), m.type, true);
                    writeText(cg, w, ")");
                }
                branch(cg, end);
            }
            positionAtEnd(cg, end);
        }
        case TypeKind.Array: {
            const slot = entryAlloca(cg, lower(cg, type), "array");
            store(cg, v, slot);
            emitFormatElements(cg, w, slot, constUsize(cg, t.len), t.child);
        }
        case TypeKind.Slice: emitFormatElements(cg, w, extract(cg, v, 0, ""), extract(cg, v, 1, ""), t.child);
        default: fatal(cg, `codegen: no formatting for type kind ${t.kind as u32}`);
    }
    void llvm.LLVMBuildRet(cg.b, llvm.LLVMConstNull(codeType));
    detourEnd(cg, saved);
    return fn;
}

/**
 * The number that the next template formatter takes in its name, `helix.template.<n>`.
 *
 * @remarks
 * The count is never reset, so a second module that the same process generates goes on from where the first stopped.
 * The formatters are internal, so their numbers never meet across modules.
 *
 * @since 1.0.0
 */

let nextTemplate: u32 = 0;

/**
 * Generates the formatter of a template.
 *
 * @param cg - The code generator
 * @param pieces - The pieces of the template, in order
 * @param valuesType - The LLVM struct type that holds the values of the template
 * @returns The formatter `helix.template.<n>`, of {@link formatterType}
 *
 * @remarks
 * The formatter writes each text piece as it is and each value piece from the next field of the values struct.
 *
 * @since 1.0.0
 */

function templateFormatter(cg: *Cg, pieces: readonly Piece[], valuesType: Type): Value {
    const fn = helperFunction(cg, llvmName(cg, `helix.template.${nextTemplate}`), formatterType(cg));
    nextTemplate += 1;

    const saved = detourBegin(cg, fn);
    const values = llvm.LLVMGetParam(fn, 0);
    const w = llvm.LLVMGetParam(fn, 1);
    let field: u32 = 0;
    for (const piece of pieces) {
        if (piece.type == 0) {
            writeText(cg, w, piece.text);
            continue;
        }
        const ptr = llvm.LLVMBuildStructGEP2(cg.b, valuesType, values, field, "");
        field += 1;
        emitFormat(cg, w, load(cg, lower(cg, piece.type), ptr, ""), piece.type, false);
    }
    void llvm.LLVMBuildRet(cg.b, llvm.LLVMConstNull(lower(cg, cg.types.errorCode)));
    detourEnd(cg, saved);
    return fn;
}

/**
 * Returns the bytes of a constant string value of the checker.
 *
 * @param cg - The code generator
 * @param index - The index of the value
 * @returns The text, or an empty string for a value without bytes
 *
 * @remarks
 * The text borrows the value table, and an empty value gives `""` without reading its byte pointer.
 *
 * @since 1.0.0
 */

function textOf(cg: *Cg, index: u32): string {
    const v = value(cg, index);
    unsafe {
        return v.len > 0 ? v.bytes![0..v.len] : "";
    }
}

/**
 * Evaluates the values of a template into a struct on the stack and returns the `Format` pair.
 *
 * @param cg - The code generator
 * @param node - A template, a plain string literal of type `Format`, or a single value to print
 * @param newline - `true` to write a newline after the rest, as `println` does
 * @returns The pair `{ values, formatter }`
 *
 * @remarks
 * A `void` or `noreturn` value inside a template has nothing to print and is left out.
 * A template keeps at most 256 pieces.
 *
 * @example
 * ```hx
 * // fprint(w, `x = ${x}`);
 * emitFormatValue(cg, node, false); // { %template.values, @helix.template.0 }
 * ```
 *
 * @see templateFormatter
 * @since 1.0.0
 */

export function emitFormatValue(cg: *Cg, node: u32, newline: bool): Value {
    let pieces: Piece[257] = undefined;
    let parts: Value[257] = undefined;
    let fields: Type[257] = undefined;
    let count: u32 = 0;
    let fieldCount: u32 = 0;

    if (nodeOf(cg, node).kind == NodeKind.Template) {
        for (const i of nodeOf(cg, node).a..nodeOf(cg, node).b) {
            if (count >= 256) break;
            const part = extra(cg, i);
            if (nodeOf(cg, part).kind == NodeKind.TemplateText) {
                pieces[count] = Piece { text: textOf(cg, infoOf(cg, part).value), type: 0 };
                count += 1;
                continue;
            }
            const v = emitValue(cg, part);
            if (v == null) continue;   // a `void` or `noreturn` value: nothing to print
            pieces[count] = Piece { text: "", type: finalType(cg, part) };
            count += 1;
            parts[fieldCount] = v;
            fields[fieldCount] = llvm.LLVMTypeOf(v);
            fieldCount += 1;
        }
    } else if (nodeOf(cg, node).kind == NodeKind.String && typeOf(cg, finalType(cg, node)).kind == TypeKind.Format) {
        pieces[count] = Piece { text: textOf(cg, infoOf(cg, node).value), type: 0 };
        count += 1;
    } else {
        const v = emitValue(cg, node);
        if (v != null) {
            pieces[count] = Piece { text: "", type: finalType(cg, node) };
            count += 1;
            parts[fieldCount] = v;
            fields[fieldCount] = llvm.LLVMTypeOf(v);
            fieldCount += 1;
        }
    }
    if (newline) {
        pieces[count] = Piece { text: "\n", type: 0 };
        count += 1;
    }

    const allFields: *Type[257] = &fields;
    const valuesType = structType(cg, allFields[0..fieldCount]);
    const values = entryAlloca(cg, valuesType, "template.values");
    for (const i of 0..fieldCount) store(cg, parts[i], llvm.LLVMBuildStructGEP2(cg.b, valuesType, values, i, ""));
    const format = insert(cg, llvm.LLVMGetUndef(cg.dynType), values, 0);
    const allPieces: *Piece[257] = &pieces;
    return insert(cg, format, templateFormatter(cg, allPieces[0..count], valuesType), 1);
}

/**
 * Returns the writer for a file descriptor.
 *
 * @param cg - The code generator
 * @param fd - The file descriptor, such as 1 for stdout or 2 for stderr
 * @returns A `dyn` value with the descriptor in its data pointer and the vtable `helix.fd.vtable`
 *
 * @remarks
 * The vtable is made once per module, and its `write` slot `helix.fd.write` calls the runtime's `hx_write`.
 * `print` and `eprint` use it as their built-in writer, and failed `expect` reports write through it to descriptor 3.
 *
 * @example
 * ```hx
 * fdWriter(cg, 2); // { inttoptr (i64 2 to ptr), @helix.fd.vtable }
 * ```
 *
 * @since 1.0.0
 */

export function fdWriter(cg: *Cg, fd: u32): Value {
    let table = llvm.LLVMGetNamedGlobal(cg.mod, "helix.fd.vtable");
    if (table == null) {
        const fn = helperFunction(cg, "helix.fd.write", writeSlotType(cg));
        const saved = detourBegin(cg, fn);
        const i32t = int32(cg);
        const params: Type[3] = [i32t, cg.ptrType, cg.usizeType];
        const writeType = fnType(voidType(cg), &params, false);
        const bytes = llvm.LLVMGetParam(fn, 1);
        const args: Value[3] = [
            llvm.LLVMBuildPtrToInt(cg.b, llvm.LLVMGetParam(fn, 0), i32t, ""),
            extract(cg, bytes, 0, ""),
            extract(cg, bytes, 1, ""),
        ];
        void call(cg, writeType, declareC(cg, "hx_write", writeType), &args, "");
        void llvm.LLVMBuildRet(cg.b, llvm.LLVMConstNull(lower(cg, cg.types.errorCode)));
        detourEnd(cg, saved);

        const slots: Value[1] = [fn];
        const init = constArray(cg.ptrType, &slots);
        table = llvm.LLVMAddGlobal(cg.mod, llvm.LLVMTypeOf(init), "helix.fd.vtable");
        llvm.LLVMSetInitializer(table, init);
        llvm.LLVMSetGlobalConstant(table, 1);
        llvm.LLVMSetLinkage(table, llvm.LLVMPrivateLinkage);
    }
    const data = llvm.LLVMConstIntToPtr(llvm.LLVMConstInt(cg.usizeType, fd as u64, 0), cg.ptrType);
    const w = insert(cg, llvm.LLVMGetUndef(cg.dynType), data, 0);
    return insert(cg, w, table, 1);
}

/**
 * Emits `f.writeTo(w)`, which calls the formatter of a template with its values.
 *
 * @param cg - The code generator
 * @param node - The call node
 * @returns The error code that the formatter returns
 *
 * @remarks
 * The `Format` pair already holds the values pointer and the formatter,
 * so the call needs nothing else from the template.
 * The result is the error code of the formatter, which the caller handles like any other error union.
 *
 * @example
 * ```hx
 * // try text.writeTo(w);
 * emitFormatWrite(cg, node); // call i16 %formatter(ptr %values, { ptr, ptr } %w)
 * ```
 *
 * @since 1.0.0
 */

export function emitFormatWrite(cg: *Cg, node: u32): Value {
    const args = record<HxRange>(cg.ast, nodeOf(cg, node).b);
    const format = emitValue(cg, nodeOf(cg, nodeOf(cg, node).a).a);
    const w = emitValue(cg, extra(cg, args.start));
    const callArgs: Value[2] = [extract(cg, format, 0, ""), w];
    return call(cg, formatterType(cg), extract(cg, format, 1, ""), &callArgs, "");
}

/**
 * Emits `print`, `println`, `eprint`, or `eprintln`.
 *
 * @param cg - The code generator
 * @param node - The call node
 *
 * @remarks
 * The `print` forms write to stdout and the `eprint` forms to stderr, and the `ln` forms add a newline.
 * The error code of the write is dropped, since the write slot of {@link fdWriter} always returns 0.
 *
 * @example
 * ```hx
 * // println(`x = ${x}`);
 * emitPrint(cg, node); // formats into the stdout writer, then "\n"
 * ```
 *
 * @see fdWriter
 * @since 1.0.0
 */

export function emitPrint(cg: *Cg, node: u32): void {
    const kind = infoOf(cg, node).aux;
    const args = record<HxRange>(cg.ast, nodeOf(cg, node).b);
    const newline = kind == HxPrintln || kind == HxEprintln;
    const format = emitFormatValue(cg, extra(cg, args.start), newline);
    const w = fdWriter(cg, kind >= HxEprint ? 2 : 1);
    const callArgs: Value[2] = [extract(cg, format, 0, ""), w];
    void call(cg, formatterType(cg), extract(cg, format, 1, ""), &callArgs, "");   // stdout can't fail
}
