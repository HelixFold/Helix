/**
 * Imports
 */

import * as fmt from "std/fmt";
import { hxTypeName } from "@models/types.model";
import { hxNodeKindName } from "@models/ast.model";
import { hxNameText } from "@services/intern.service";
import { hxArenaAlloc } from "@services/arena.service";
import { HxNode } from "@models/structs/ast-model.struct";
import { HxType } from "@models/structs/types-model.struct";
import { TypeKind, Signed } from "@constants/types.constant";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { HxLineCol } from "@models/structs/source-model.struct";
import { files, hxSourceLineCol } from "@models/source.model";
import { cCallable } from "@modules/codegen/components/abi.component";
import { hxDiagRenderLocation } from "@components/diagnostic.component";
import { infoAt, hxNodeSpan } from "@modules/sema/components/base.component";
import { hxFatalMessage, hxZalloc, hxVecGrowImpl } from "@components/memory.component";
import { HxValueFloat, HxValueFunction, HxMemberEnumValue } from "@constants/sema.constant";
import { HxMember, HxU32Vec, HxAggregate, HxNodeInfo, HxSymbol, HxValue } from "@structs/sema.struct";
import { HxValueUndefined, HxMemberField, HxValueAggregate, HxSymParam } from "@constants/sema.constant";
import { HxValueNull, HxValueBool, HxValueError, HxValueInt, HxValueString } from "@constants/sema.constant";
import { Value, Type, Block, Meta, Cg, Detour } from "@modules/codegen/components/structs/base-component.struct";

/**
 * The C library functions that the code generator calls for memory and C strings.
 *
 * @remarks
 * `hx_os_memstream_close` closes a file from `hx_os_memstream`,
 * which leaves the text and its size in the variables that the file was opened with.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;
extern "C" function strlen(text: readonly u8[*]): usize;

/**
 * Opens an in-memory file that collects what is written to it, like `open_memstream`, also on Windows.
 *
 * @param buf - The variable that receives the written text when the file closes
 * @param size - The variable that receives the size of the text
 * @returns The file, or null when it cannot be opened
 *
 * @remarks
 * The C host provides it because Windows lacks `open_memstream`,
 * so code generation can print LLVM text to memory on every platform.
 * The text exists only after `hx_os_memstream_close` closes the file, and the caller frees it with `free`.
 *
 * @since 1.0.0
 */

extern "C" function hx_os_memstream(buf: *?u8[*], size: *usize): ?u8[*];
extern "C" function hx_os_memstream_close(file: ?u8[*]): void;

/**
 * Allocates zeroed items on the C heap.
 *
 * @typeParam T - The item type
 * @param n - The number of items
 * @returns The items, all bytes zero, to release with {@link release}
 *
 * @remarks
 * The allocation always has room for one item more than asked,
 * so even 0 items get a real pointer.
 * The tables of the generator, such as the storage of each symbol and the LLVM type of each type id, start this way.
 *
 * @example
 * ```hx
 * const fields = zeroed<Type>(3);
 * fields.len; // 3
 * fields[0];  // null
 * release(fields);
 * ```
 *
 * @see release
 * @since 1.0.0
 */

export function zeroed<T>(n: u32): T[] {
    const bytes = hxZalloc(((n as usize) + 1) * @sizeOf(T));
    unsafe {
        return @ptrCast(T[*], bytes)[0..n];
    }
}

/**
 * Frees items that {@link zeroed} allocated.
 *
 * @typeParam T - The item type
 * @param items - The items to free
 *
 * @remarks
 * An empty slice frees nothing, which also makes it safe on a table that was never allocated.
 *
 * @example
 * ```hx
 * const values = zeroed<Value>(4);
 * release(values); // the memory goes back to the C heap
 * ```
 *
 * @see zeroed
 * @since 1.0.0
 */

export function release<T>(items: T[]): void {
    unsafe {
        if (items.len > 0) free(@ptrCast(?u8[*], items.ptr));
    }
}

/**
 * Appends a number to a vector of `u32`.
 *
 * @param vec - The vector to grow
 * @param v - The number to append
 *
 * @remarks
 * The vector doubles its capacity when it is full, starting at 8 items.
 *
 * @example
 * ```hx
 * push(&cg.defers, node);
 * cg.defers.len; // one more than before
 * ```
 *
 * @see vectorAt
 * @since 1.0.0
 */

export function push(vec: *HxU32Vec, v: u32): void {
    unsafe {
        if (vec.len == vec.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &vec.items), &vec.cap, vec.len + 1, 4);
        vec.items![vec.len] = v;
    }
    vec.len += 1;
}

/**
 * Reads a number from a vector of `u32`.
 *
 * @param vec - The vector to read
 * @param i - The index of the item, which must be below the length of the vector
 * @returns The item at the index
 *
 * @remarks
 * It does not check the index against the length, so a caller reads only below the length that `push` built.
 *
 * @example
 * ```hx
 * push(&list, 7);
 * vectorAt(&list, 0); // 7
 * ```
 *
 * @see push
 * @since 1.0.0
 */

export function vectorAt(vec: readonly *HxU32Vec, i: u32): u32 {
    unsafe {
        return vec.items![i];
    }
}

/**
 * Formats a template into a NUL-terminated text for the names that LLVM takes.
 *
 * @param cg - The code generator
 * @param text - The template to format
 * @returns The formatted text, which lives in the arena of the generator until code generation ends
 *
 * @remarks
 * A template that fails to format gives an empty text.
 *
 * @example
 * ```hx
 * llvmName(cg, `${module}.${name}`); // "main.add"
 * ```
 *
 * @see fromCString
 * @since 1.0.0
 */

export function llvmName(cg: *Cg, text: Format): readonly u8[*] {
    const n = fmt.count(text) catch 0;
    const buf = hxArenaAlloc(&cg.arena, n + 1, 1);
    unsafe {
        void (fmt.bufPrint(buf[0..n], text) catch []);
        buf[n] = 0;
    }
    return buf;
}

/**
 * Turns a NUL-terminated C string into a Helix string.
 *
 * @param text - The C string, or null
 * @returns The bytes before the NUL, or an empty string for null
 *
 * @remarks
 * The result points into the C string and copies nothing.
 *
 * @example
 * ```hx
 * fromCString("main");   // "main"
 * fromCString(null);     // ""
 * ```
 *
 * @see llvmName
 * @since 1.0.0
 */

export function fromCString(text: ?readonly u8[*]): string {
    if (text == null) return "";
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * Stops the compiler with an internal compiler error.
 *
 * @param cg - The code generator, whose arena holds the formatted message
 * @param message - The template of the message
 *
 * @remarks
 * The message goes to stderr after `helix: internal compiler error:`, and the process then aborts.
 * Code generation calls it only for states the checker should have ruled out, such as a type without a lowering.
 *
 * @example
 * ```hx
 * fatal(cg, `codegen: unknown intrinsic ${name}`); // helix: internal compiler error: codegen: unknown ...
 * ```
 *
 * @since 1.0.0
 */

export function fatal(cg: *Cg, message: Format): noreturn {
    hxFatalMessage(llvmName(cg, message));
}

/**
 * Converts a Helix `bool` into the `LLVMBool` that the LLVM C API takes.
 *
 * @param v - The flag to convert
 * @returns 1 for `true` and 0 for `false`
 *
 * @remarks
 * The LLVM C API declares its flags as a 32-bit integer, so every flag that code generation passes goes through here.
 *
 * @example
 * ```hx
 * llvmBool(true);  // 1
 * llvmBool(false); // 0
 * ```
 *
 * @since 1.0.0
 */

export function llvmBool(v: bool): i32 {
    if (v) return 1;
    return 0;
}

/**
 * Reads a node of the syntax tree.
 *
 * @param cg - The code generator
 * @param id - The id of the node
 * @returns A copy of the node
 *
 * @remarks
 * It indexes the node table without a bounds check, so the id must come from the tree that the generator holds.
 * The copy does not change when the tree does, which code generation never does anyway.
 *
 * @example
 * ```hx
 * nodeOf(cg, node).kind; // NodeKind.Return
 * ```
 *
 * @see infoOf
 * @since 1.0.0
 */

export function nodeOf(cg: readonly *Cg, id: u32): HxNode {
    unsafe {
        return cg.ast.nodes![id];
    }
}

/**
 * Reads what the checker decided about a node.
 *
 * @param cg - The code generator
 * @param id - The id of the node
 * @returns A copy of the node's info: its type, its conversion, its symbol, and its constant value
 *
 * @remarks
 * Inside a generic instance, the info comes from that instance, so the same node can have a different type in each.
 * Code generation never derives a type again and reads every type and conversion from here.
 *
 * @example
 * ```hx
 * infoOf(cg, node).type; // the type id of the expression
 * ```
 *
 * @see finalType
 * @since 1.0.0
 */

export function infoOf(cg: readonly *Cg, id: u32): HxNodeInfo {
    return *infoAt(cg.sema, cg.instance, id);
}

/**
 * Reads a type from the type table of the checker.
 *
 * @param cg - The code generator
 * @param id - The type id
 * @returns A copy of the type
 *
 * @remarks
 * It indexes the type table without a bounds check.
 * Use {@link lower} instead when the LLVM form of the type is the goal.
 *
 * @example
 * ```hx
 * typeOf(cg, cg.types.u8).bits; // 8
 * ```
 *
 * @see lower
 * @since 1.0.0
 */

export function typeOf(cg: readonly *Cg, id: u32): HxType {
    unsafe {
        return cg.types.items![id];
    }
}

/**
 * Reads a symbol from the symbol table of the checker.
 *
 * @param cg - The code generator
 * @param id - The symbol id
 * @returns A copy of the symbol
 *
 * @remarks
 * It indexes the symbol table without a bounds check, so the id must come from the checker of this program.
 *
 * @example
 * ```hx
 * symbolOf(cg, sym).type; // the type id of the local, global, or function
 * ```
 *
 * @since 1.0.0
 */

export function symbolOf(cg: readonly *Cg, id: u32): HxSymbol {
    unsafe {
        return @ptrCast(HxSymbol[*], cg.sema.symbols.items)[id];
    }
}

/**
 * Reads a number from the extra array of the syntax tree, where nodes keep their lists and records.
 *
 * @param cg - The code generator
 * @param index - The index into the extra array
 * @returns The number at that index
 *
 * @remarks
 * Nodes with more children than their fixed fields hold keep a range into this array,
 * so a list of children is read one `extra` call per item.
 *
 * @example
 * ```hx
 * extra(cg, range.start); // the id of the first node in the list
 * ```
 *
 * @since 1.0.0
 */

export function extra(cg: readonly *Cg, index: u32): u32 {
    unsafe {
        return cg.ast.extra![index];
    }
}

/**
 * Reads a constant value that the checker computed.
 *
 * @param cg - The code generator
 * @param index - The index of the value, as a node's info holds it
 * @returns A copy of the value
 *
 * @remarks
 * Index 0 means that the checker computed no value, so a caller checks the index before it reads.
 *
 * @example
 * ```hx
 * value(cg, infoOf(cg, node).value).integer; // 42 for the literal 42
 * ```
 *
 * @see emitConst
 * @since 1.0.0
 */

export function value(cg: readonly *Cg, index: u32): HxValue {
    unsafe {
        return @ptrCast(HxValue[*], cg.sema.values.items)[index];
    }
}

/**
 * Reads an element of an aggregate constant, such as an array or struct that `comptime` computed.
 *
 * @param cg - The code generator
 * @param index - The index into the element table of the checker
 * @returns The index of the value of the element
 *
 * @remarks
 * An aggregate value keeps the index of its first element, and its elements follow in order,
 * so the element at position `i` lives at that index plus `i`.
 *
 * @example
 * ```hx
 * valueElem(cg, v.elems + 1); // the value index of the second element
 * ```
 *
 * @see value
 * @since 1.0.0
 */

export function valueElem(cg: readonly *Cg, index: u32): u32 {
    unsafe {
        return cg.sema.valueElems.items![index];
    }
}

/**
 * Reads the type of one parameter of a function type.
 *
 * @param cg - The code generator
 * @param fn - The function type
 * @param i - The position of the parameter, from 0
 * @returns The type id of the parameter
 *
 * @remarks
 * A function type keeps the start of its run in the shared parameter table, and the position is an offset from it.
 * It does not check the position against the parameter count.
 *
 * @example
 * ```hx
 * // function add(a: i32, b: i64): i64
 * param(cg, typeOf(cg, fnType), 1); // the type id of i64
 * ```
 *
 * @since 1.0.0
 */

export function param(cg: readonly *Cg, fn: HxType, i: u64): u32 {
    unsafe {
        return cg.types.params![fn.params + @truncate(u32, i)];
    }
}

/**
 * Reads the member table of a struct, union, or enum type.
 *
 * @param cg - The code generator
 * @param type - The type id, whose `len` holds the aggregate index plus 1
 * @returns A copy of the aggregate, with the range of its members and its field count
 *
 * @remarks
 * The type keeps the aggregate index plus 1 in its `len`, so 0 can mean a type without members.
 * Calling it on such a type reads out of range, so a caller asks only for a struct, a union, or an enum.
 *
 * @example
 * ```hx
 * aggregate(cg, pointType).fieldCount; // 2 for struct Point { x: i32, y: i32 }
 * ```
 *
 * @see member
 * @since 1.0.0
 */

export function aggregate(cg: readonly *Cg, type: u32): HxAggregate {
    unsafe {
        return @ptrCast(HxAggregate[*], cg.sema.aggregates.items)[(typeOf(cg, type).len as usize) - 1];
    }
}

/**
 * Reads one member of an aggregate.
 *
 * @param cg - The code generator
 * @param agg - The aggregate that owns the member
 * @param i - The position of the member in the aggregate, from 0
 * @returns A copy of the member: a field, an enum value, or a method
 *
 * @remarks
 * The members of an aggregate sit in one run of the shared member table, and the position is an offset into that run.
 *
 * @example
 * ```hx
 * member(cg, aggregate(cg, pointType), 0).index; // 0, the field x
 * ```
 *
 * @see aggregate
 * @since 1.0.0
 */

export function member(cg: readonly *Cg, agg: HxAggregate, i: u32): HxMember {
    unsafe {
        return @ptrCast(HxMember[*], cg.sema.members.items)[agg.membersStart + i];
    }
}

/**
 * Reads the source text of a token.
 *
 * @param cg - The code generator
 * @param token - The token index
 * @returns The text of the token, pointing into the source
 *
 * @remarks
 * The text borrows the source, so it stays valid for the whole of code generation and copies nothing.
 * Use {@link tokenName} instead when LLVM needs a NUL-terminated name.
 *
 * @example
 * ```hx
 * tokenText(cg, symbolOf(cg, sym).token); // "count"
 * ```
 *
 * @see tokenName
 * @since 1.0.0
 */

export function tokenText(cg: readonly *Cg, token: u32): string {
    const a = cg.ast;
    unsafe {
        const start = a.tokens.starts![token];
        return a.src.text![start..start + a.tokens.lens![token]];
    }
}

/**
 * Reads the byte offset where a token starts in the source.
 *
 * @param cg - The code generator
 * @param token - The token index
 * @returns The offset of the first byte of the token
 *
 * @remarks
 * The offset counts into the source text of the tree, and {@link diPosition} turns it into a file, line, and column.
 *
 * @example
 * ```hx
 * // const x = 1;
 * tokenStart(cg, nameToken); // 6
 * ```
 *
 * @see diPosition
 * @since 1.0.0
 */

export function tokenStart(cg: readonly *Cg, token: u32): u32 {
    unsafe {
        return cg.ast.tokens.starts![token];
    }
}

/**
 * Reads a range of the source text.
 *
 * @param cg - The code generator
 * @param start - The offset of the first byte
 * @param len - The number of bytes
 * @returns The text, pointing into the source
 *
 * @remarks
 * The text borrows the source and copies nothing.
 * It does not check the range, so the start and length come from a node or token span.
 *
 * @example
 * ```hx
 * // const x = a + b;
 * sourceText(cg, 10, 5); // "a + b"
 * ```
 *
 * @since 1.0.0
 */

export function sourceText(cg: readonly *Cg, start: u32, len: u32): string {
    unsafe {
        return cg.ast.src.text![start..start + len];
    }
}

/**
 * Reads the path of a source file.
 *
 * @param cg - The code generator
 * @param file - The index of the file in the source set
 * @returns The path as the source set recorded it
 *
 * @remarks
 * The path borrows the source set, so it lives as long as code generation does.
 *
 * @example
 * ```hx
 * sourcePath(cg, 0); // "src/main.hx"
 * ```
 *
 * @see diFile
 * @since 1.0.0
 */

export function sourcePath(cg: readonly *Cg, file: u32): string {
    unsafe {
        return fromCString(files(cg.ast.src)[file].path);
    }
}

/**
 * Finds the type that a node's value has where it is used.
 *
 * @param cg - The code generator
 * @param node - The expression node
 * @returns The type after the implicit conversion of the node, or its own type when it has none
 *
 * @remarks
 * The checker records an implicit conversion, such as `i32` to `?i32`, in the `coerce` field of the node info.
 * Code that stores or passes a value uses this type, while code that computes the value itself reads `infoOf` instead.
 *
 * @example
 * ```hx
 * // const x: ?i32 = 1;
 * finalType(cg, literal); // the type id of ?i32, not of i32
 * ```
 *
 * @see infoOf
 * @since 1.0.0
 */

export function finalType(cg: readonly *Cg, node: u32): u32 {
    const info = infoOf(cg, node);
    return info.coerce != 0 ? info.coerce : info.type;
}

/**
 * Checks whether an integer type is signed.
 *
 * @param cg - The code generator
 * @param type - The type id
 * @returns `true` when the type carries the signed flag
 *
 * @remarks
 * It reads only the signed flag, so it gives `false` for any type that is not an integer, such as a float.
 *
 * @example
 * ```hx
 * isSigned(cg, cg.types.i32); // true
 * isSigned(cg, cg.types.u8);  // false
 * ```
 *
 * @since 1.0.0
 */

export function isSigned(cg: readonly *Cg, type: u32): bool {
    return (typeOf(cg, type).flags & Signed) != 0;
}

/**
 * Spells a type as the source writes it, for messages and debug info.
 *
 * @param cg - The code generator
 * @param type - The type id
 * @returns The name, at most 160 bytes, in the arena of the generator
 *
 * @remarks
 * The buffer has a fixed size, so the name stops at 160 bytes.
 * The text lives in the arena until code generation ends.
 *
 * @example
 * ```hx
 * typeName(cg, sliceOfU8); // "u8[]"
 * ```
 *
 * @since 1.0.0
 */

export function typeName(cg: *Cg, type: u32): string {
    const buf = hxArenaAlloc(&cg.arena, 160, 1);
    hxTypeName(cg.types, type, buf, 160);
    return fromCString(buf);
}

/**
 * Turns a token's text into a NUL-terminated LLVM value name.
 *
 * @param cg - The code generator
 * @param token - The token index, where `0xFFFF_FFFF` means there is no token
 * @returns The text of the token, or an empty name without a token
 *
 * @remarks
 * LLVM makes a name unique by adding a number, so two locals named `x` come out as `%x` and `%x1`.
 * The copy lives in the arena of the generator.
 *
 * @example
 * ```hx
 * tokenName(cg, symbolOf(cg, sym).token); // "count", so the IR reads %count
 * tokenName(cg, 0xFFFF_FFFF);             // ""
 * ```
 *
 * @see tokenText
 * @since 1.0.0
 */

export function tokenName(cg: *Cg, token: u32): readonly u8[*] {
    if (token == 0xFFFF_FFFF) return "";
    return llvmName(cg, `${tokenText(cg, token)}`);
}

/**
 * Names a node kind, for internal error messages.
 *
 * @param kind - The node kind
 * @returns The name of the kind
 *
 * @remarks
 * The name comes from the parser's own table, so it matches the `NodeKind` spelling.
 *
 * @example
 * ```hx
 * nodeKindName(NodeKind.Return); // "Return"
 * ```
 *
 * @since 1.0.0
 */

export function nodeKindName(kind: u32): string {
    return fromCString(hxNodeKindName(kind));
}

/**
 * Checks whether the current block already ends in a terminator such as a branch, a return, or `unreachable`.
 *
 * @param cg - The code generator
 * @returns `true` when nothing more may go into the block
 *
 * @remarks
 * Statement code checks it before adding the jump that ends a block,
 * so a body that already returned or broke out gets no second terminator.
 *
 * @example
 * ```hx
 * branch(cg, end);
 * terminated(cg); // true
 * ```
 *
 * @see startDeadBlock
 * @since 1.0.0
 */

export function terminated(cg: readonly *Cg): bool {
    return llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(cg.b)) != null;
}

/**
 * Moves the builder into a new block that nothing jumps to.
 *
 * @param cg - The code generator
 *
 * @remarks
 * After a call that never returns or an `unreachable`, the current block is finished,
 * and code that the source still has after it goes into this block named `dead`, which LLVM removes.
 *
 * @example
 * ```hx
 * void llvm.LLVMBuildUnreachable(cg.b);
 * startDeadBlock(cg); // later instructions land in %dead
 * ```
 *
 * @see terminated
 * @since 1.0.0
 */

export function startDeadBlock(cg: *Cg): void {
    llvm.LLVMPositionBuilderAtEnd(cg.b, llvm.LLVMAppendBasicBlockInContext(cg.ctx, cg.fn, "dead"));
}

/**
 * Appends a new basic block to the function being emitted.
 *
 * @param cg - The code generator
 * @param name - The label of the block in the IR
 * @returns The block, which the builder does not move into
 *
 * @remarks
 * It does not move the builder, so a caller calls {@link positionAtEnd} once it wants to fill the block.
 *
 * @example
 * ```hx
 * const ok = block(cg, "ok");
 * positionAtEnd(cg, ok); // later instructions go into %ok
 * ```
 *
 * @see positionAtEnd
 * @since 1.0.0
 */

export function block(cg: *Cg, name: readonly u8[*]): Block {
    return llvm.LLVMAppendBasicBlockInContext(cg.ctx, cg.fn, name);
}

/**
 * Moves the builder to the end of a block.
 *
 * @param cg - The code generator
 * @param b - The block to emit into
 *
 * @remarks
 * It suits a new block or one still open, since an instruction after a terminator would make the IR invalid.
 *
 * @example
 * ```hx
 * positionAtEnd(cg, cg.entryBlock); // the next instruction goes at the end of %entry
 * ```
 *
 * @see block
 * @since 1.0.0
 */

export function positionAtEnd(cg: *Cg, b: Block): void {
    llvm.LLVMPositionBuilderAtEnd(cg.b, b);
}

/**
 * Gives the LLVM `i1` type, which a Helix `bool` lowers to.
 *
 * @param cg - The code generator
 * @returns The `i1` type of the context
 *
 * @remarks
 * A `bool` in memory also stays `i1`, and LLVM gives it a byte of storage.
 *
 * @example
 * ```hx
 * int1Type(cg); // i1
 * ```
 *
 * @since 1.0.0
 */

export function int1Type(cg: *Cg): Type {
    return llvm.LLVMInt1TypeInContext(cg.ctx);
}

/**
 * Gives the LLVM `i8` type.
 *
 * @param cg - The code generator
 * @returns The `i8` type of the context
 *
 * @remarks
 * It serves as the type of raw bytes, such as the fill byte of a `memset`.
 *
 * @example
 * ```hx
 * int8Type(cg); // i8
 * ```
 *
 * @since 1.0.0
 */

export function int8Type(cg: *Cg): Type {
    return llvm.LLVMInt8TypeInContext(cg.ctx);
}

/**
 * Gives the LLVM `i32` type.
 *
 * @param cg - The code generator
 * @returns The `i32` type of the context
 *
 * @remarks
 * LLVM takes struct field indices as `i32` constants, and C functions such as `main` take or give an `i32`.
 *
 * @example
 * ```hx
 * int32(cg); // i32
 * ```
 *
 * @since 1.0.0
 */

export function int32(cg: *Cg): Type {
    return llvm.LLVMInt32TypeInContext(cg.ctx);
}

/**
 * Gives the LLVM `i64` type.
 *
 * @param cg - The code generator
 * @returns The `i64` type of the context
 *
 * @remarks
 * It is fixed at 64 bits, while `usize` takes whatever width {@link lower} gives it.
 *
 * @example
 * ```hx
 * int64(cg); // i64
 * ```
 *
 * @since 1.0.0
 */

export function int64(cg: *Cg): Type {
    return llvm.LLVMInt64TypeInContext(cg.ctx);
}

/**
 * Gives the LLVM `void` type, which `void` and `noreturn` lower to.
 *
 * @param cg - The code generator
 * @returns The `void` type of the context
 *
 * @remarks
 * A `noreturn` function returns `void` in the IR, and its callers emit `unreachable` after the call.
 *
 * @example
 * ```hx
 * voidType(cg); // void
 * ```
 *
 * @since 1.0.0
 */

export function voidType(cg: *Cg): Type {
    return llvm.LLVMVoidTypeInContext(cg.ctx);
}

/**
 * Builds an LLVM function type.
 *
 * @param ret - The result type
 * @param params - The parameter types
 * @param variadic - Whether the function takes more arguments after the listed ones, as C's `...` does
 * @returns The function type
 *
 * @remarks
 * Only C functions such as `dprintf` set the flag, since a Helix function always takes a fixed list.
 *
 * @example
 * ```hx
 * const params: Type[2] = [int32(cg), cg.ptrType];
 * fnType(int32(cg), &params, true); // i32 (i32, ptr, ...)
 * ```
 *
 * @see lowerFunction
 * @since 1.0.0
 */

export function fnType(ret: Type, params: readonly Type[], variadic: bool): Type {
    unsafe {
        return llvm.LLVMFunctionType(ret, @ptrCast(?Type[*], params.ptr), @truncate(u32, params.len), llvmBool(variadic));
    }
}

/**
 * Emits a call.
 *
 * @param cg - The code generator
 * @param type - The function type of the callee
 * @param fn - The callee, a function or a function pointer
 * @param args - The arguments
 * @param name - The name of the result in the IR
 * @returns The call instruction, which is the result of the call
 *
 * @remarks
 * On arm64e a call through a function pointer checks the signature of the pointer first.
 * It carries a `ptrauth` operand bundle with key IA and no discriminator, as C does.
 * A direct call to a known function needs no check.
 *
 * @example
 * ```hx
 * call(cg, fnT, callee, &args, "sum"); // %sum = call i32 @main.add(i32 1, i32 2)
 * ```
 *
 * @see fnType
 * @since 1.0.0
 */

export function call(cg: *Cg, type: Type, fn: Value, args: readonly Value[], name: readonly u8[*]): Value {
    unsafe {
        if (cg.ptrauth && llvm.LLVMIsAFunction(fn) == null) {
            // a call through a function pointer checks its signature first: key IA, no discriminator, as C does
            let bundleArgs: Value[2] = [int32Const(cg, 0), llvm.LLVMConstInt(int64(cg), 0, 0)];
            let bundles: llvm.LLVMOperandBundleRef[1] = [llvm.LLVMCreateOperandBundle("ptrauth", 7, &bundleArgs, 2)];
            const result = llvm.LLVMBuildCallWithOperandBundles(cg.b, type, fn, @ptrCast(?Value[*], args.ptr), @truncate(u32, args.len),
                                                             &bundles, 1, name);
            llvm.LLVMDisposeOperandBundle(bundles[0]);
            return result;
        }
        return llvm.LLVMBuildCall2(cg.b, type, fn, @ptrCast(?Value[*], args.ptr), @truncate(u32, args.len), name);
    }
}

/**
 * Makes an `i32` constant.
 *
 * @param cg - The code generator
 * @param v - The value
 * @returns The constant
 *
 * @remarks
 * The operand bundle of a pointer authentication check takes its key as such a constant.
 *
 * @since 1.0.0
 */

function int32Const(cg: *Cg, v: u64): Value {
    return llvm.LLVMConstInt(int32(cg), v, 0);
}

/**
 * Builds an unnamed LLVM struct type with the natural, unpacked layout.
 *
 * @param cg - The code generator
 * @param fields - The field types in order
 * @returns The struct type
 *
 * @remarks
 * LLVM treats two literal structs with the same fields as the same type,
 * so slices, optionals, and error unions of one payload share a type without a name.
 *
 * @example
 * ```hx
 * const fields: Type[2] = [int32(cg), int1Type(cg)];
 * structType(cg, &fields); // { i32, i1 }, the layout of ?i32
 * ```
 *
 * @see constStruct
 * @since 1.0.0
 */

export function structType(cg: *Cg, fields: readonly Type[]): Type {
    unsafe {
        return llvm.LLVMStructTypeInContext(cg.ctx, @ptrCast(?Type[*], fields.ptr), @truncate(u32, fields.len), 0);
    }
}

/**
 * Builds a constant of an unnamed struct type.
 *
 * @param cg - The code generator
 * @param fields - The constant fields in order
 * @returns The constant struct
 *
 * @remarks
 * The type of the result follows from the fields,
 * so it matches the type that {@link structType} builds from their types.
 *
 * @example
 * ```hx
 * const fields: Value[2] = [ptr, len];
 * constStruct(cg, &fields); // { ptr @str, i64 5 }
 * ```
 *
 * @see constPair
 * @since 1.0.0
 */

export function constStruct(cg: *Cg, fields: readonly Value[]): Value {
    unsafe {
        return llvm.LLVMConstStructInContext(cg.ctx, @ptrCast(?Value[*], fields.ptr), @truncate(u32, fields.len), 0);
    }
}

/**
 * Builds a constant array.
 *
 * @param type - The element type
 * @param items - The constant elements
 * @returns The constant array
 *
 * @remarks
 * It builds the constant arrays that `comptime` computed,
 * and code generation builds its own tables with it, such as vtables and error names.
 *
 * @example
 * ```hx
 * constArray(int32(cg), &items); // [3 x i32] [i32 1, i32 2, i32 3]
 * ```
 *
 * @since 1.0.0
 */

export function constArray(type: Type, items: readonly Value[]): Value {
    unsafe {
        return llvm.LLVMConstArray2(type, @ptrCast(?Value[*], items.ptr), items.len as u64);
    }
}

/**
 * Emits a phi that picks a value by the block that control came from.
 *
 * @param cg - The code generator
 * @param type - The type of the values
 * @param values - The incoming values
 * @param blocks - The block that each value comes from, in the same order
 * @param name - The name of the result in the IR
 * @returns The phi instruction
 *
 * @remarks
 * The builder must sit at the start of the block, before any other instruction, as LLVM requires of a phi.
 * The two slices must have the same length, since the count comes from the values alone.
 *
 * @example
 * ```hx
 * phiNode(cg, int1Type(cg), &values, &blocks, "and"); // %and = phi i1 [ false, %entry ], [ %b, %rhs ]
 * ```
 *
 * @since 1.0.0
 */

export function phiNode(cg: *Cg, type: Type, values: readonly Value[], blocks: readonly Block[], name: readonly u8[*]): Value {
    const p = llvm.LLVMBuildPhi(cg.b, type, name);
    unsafe {
        llvm.LLVMAddIncoming(p, @ptrCast(?Value[*], values.ptr), @ptrCast(?Block[*], blocks.ptr), @truncate(u32, values.len));
    }
    return p;
}

/**
 * Emits an `inbounds` getelementptr that computes the address of an element or a field.
 *
 * @param cg - The code generator
 * @param type - The type that the pointer points at
 * @param ptr - The base pointer
 * @param indices - The indices into that type
 * @param name - The name of the result in the IR
 * @returns The computed address
 *
 * @remarks
 * The `inbounds` flag lets LLVM assume that the address stays inside the object,
 * so an address outside it gives a poison value.
 *
 * @example
 * ```hx
 * elementPointer(cg, pointType, address, &indices, "y");
 * // %y = getelementptr inbounds %main.Point, ptr %p, i32 0, i32 1
 * ```
 *
 * @since 1.0.0
 */

export function elementPointer(cg: *Cg, type: Type, ptr: Value, indices: readonly Value[], name: readonly u8[*]): Value {
    unsafe {
        return llvm.LLVMBuildInBoundsGEP2(cg.b, type, ptr, @ptrCast(?Value[*], indices.ptr), @truncate(u32, indices.len), name);
    }
}

/**
 * Emits an `extractvalue` that reads one field of a struct value.
 *
 * @param cg - The code generator
 * @param v - The struct value
 * @param index - The position of the field
 * @param name - The name of the result in the IR
 * @returns The field
 *
 * @remarks
 * It reads a value held in registers, while {@link elementPointer} and {@link load} reach a field in memory.
 *
 * @example
 * ```hx
 * extract(cg, slice, 1, "len"); // %len = extractvalue { ptr, i64 } %s, 1
 * ```
 *
 * @see insert
 * @since 1.0.0
 */

export function extract(cg: *Cg, v: Value, index: u32, name: readonly u8[*]): Value {
    return llvm.LLVMBuildExtractValue(cg.b, v, index, name);
}

/**
 * Emits an `insertvalue` that replaces one field of a struct value.
 *
 * @param cg - The code generator
 * @param agg - The struct value
 * @param v - The new field
 * @param index - The position of the field
 * @returns The struct with the field replaced
 *
 * @remarks
 * The result has no name, and a chain of calls builds a whole value field by field.
 *
 * @example
 * ```hx
 * insert(cg, undefinedOptional, payload, 0); // insertvalue { i32, i1 } undef, i32 %x, 0
 * ```
 *
 * @see extract
 * @since 1.0.0
 */

export function insert(cg: *Cg, agg: Value, v: Value, index: u32): Value {
    return llvm.LLVMBuildInsertValue(cg.b, agg, v, index, "");
}

/**
 * Emits a load.
 *
 * @param cg - The code generator
 * @param type - The type of the loaded value
 * @param ptr - The address to read
 * @param name - The name of the result in the IR
 * @returns The loaded value
 *
 * @remarks
 * LLVM pointers are opaque, so the type must come from the caller, usually through {@link lower}.
 *
 * @example
 * ```hx
 * load(cg, int32(cg), slot, "x"); // %x = load i32, ptr %x1
 * ```
 *
 * @see store
 * @since 1.0.0
 */

export function load(cg: *Cg, type: Type, ptr: Value, name: readonly u8[*]): Value {
    return llvm.LLVMBuildLoad2(cg.b, type, ptr, name);
}

/**
 * Emits a store.
 *
 * @param cg - The code generator
 * @param v - The value to write
 * @param ptr - The address to write it to
 *
 * @remarks
 * The store takes its type from the value, so a caller converts the value to the stored type first.
 *
 * @example
 * ```hx
 * store(cg, value, slot); // store i32 %v, ptr %x
 * ```
 *
 * @see load
 * @since 1.0.0
 */

export function store(cg: *Cg, v: Value, ptr: Value): void {
    void llvm.LLVMBuildStore(cg.b, v, ptr);
}

/**
 * Emits an unconditional jump.
 *
 * @param cg - The code generator
 * @param to - The block to jump to
 *
 * @remarks
 * The jump ends the current block, so a caller moves the builder to another block before it emits more.
 *
 * @example
 * ```hx
 * branch(cg, end); // br label %end
 * ```
 *
 * @see condBr
 * @since 1.0.0
 */

export function branch(cg: *Cg, to: Block): void {
    void llvm.LLVMBuildBr(cg.b, to);
}

/**
 * Emits a jump that depends on a condition.
 *
 * @param cg - The code generator
 * @param cond - The `i1` condition
 * @param then - The block for `true`
 * @param otherwise - The block for `false`
 *
 * @remarks
 * The jump ends the current block, so a caller moves the builder to one of the targets before it emits more.
 *
 * @example
 * ```hx
 * condBr(cg, cond, thenBlock, elseBlock); // br i1 %cond, label %then, label %else
 * ```
 *
 * @see branch
 * @since 1.0.0
 */

export function condBr(cg: *Cg, cond: Value, then: Block, otherwise: Block): void {
    void llvm.LLVMBuildCondBr(cg.b, cond, then, otherwise);
}

/**
 * Emits an integer or pointer comparison.
 *
 * @param cg - The code generator
 * @param pred - The comparison, such as `LLVMIntEQ` or `LLVMIntULT`
 * @param a - The left operand
 * @param b - The right operand
 * @returns The `i1` result
 *
 * @remarks
 * The predicate carries the signedness, so a caller picks the signed or unsigned form from {@link isSigned}.
 *
 * @example
 * ```hx
 * compareIntegers(cg, llvm.LLVMIntEQ, a, b); // icmp eq i32 %a, %b
 * ```
 *
 * @since 1.0.0
 */

export function compareIntegers(cg: *Cg, pred: llvm.LLVMIntPredicate, a: Value, b: Value): Value {
    return llvm.LLVMBuildICmp(cg.b, pred, a, b, "");
}

/**
 * Checks whether an optional type is stored as a bare pointer.
 *
 * @param cg - The code generator
 * @param optional - The optional type
 * @returns `true` when its child is a pointer, a many-pointer, or a function
 *
 * @remarks
 * Such an optional lowers to the pointer alone, and null means that the value is not there.
 * Every other optional is a `{ T, i1 }` pair with a flag that says whether the value is present.
 *
 * @example
 * ```hx
 * optionalIsPointer(cg, optionalPointerToI32); // true, ?*i32 is a ptr
 * optionalIsPointer(cg, optionalI32);          // false, ?i32 is { i32, i1 }
 * ```
 *
 * @see lower
 * @since 1.0.0
 */

export function optionalIsPointer(cg: readonly *Cg, optional: u32): bool {
    const child = typeOf(cg, typeOf(cg, optional).child).kind;
    return child == TypeKind.Pointer || child == TypeKind.ManyPointer || child == TypeKind.Function;
}

/**
 * Checks whether an error union carries no value besides its error code.
 *
 * @param cg - The code generator
 * @param type - The error union type
 * @returns `true` for `void | E`, which lowers to the error code alone
 *
 * @remarks
 * Such a union lowers to the error code alone, so the error union helpers skip the payload field for it.
 *
 * @example
 * ```hx
 * errorUnionIsBare(cg, voidOrError); // true, the type is i16
 * errorUnionIsBare(cg, i32OrError);  // false, the type is { i32, i16 }
 * ```
 *
 * @see lower
 * @since 1.0.0
 */

export function errorUnionIsBare(cg: readonly *Cg, type: u32): bool {
    return typeOf(cg, type).child == cg.types.voidType;
}

/**
 * Checks whether a function with a given result type gives a value back.
 *
 * @param cg - The code generator
 * @param ret - The result type
 * @returns `false` for `void` and `noreturn`, and `true` for every other type
 *
 * @remarks
 * An error union with a `void` value still gives back its code, so it counts as a value here.
 *
 * @example
 * ```hx
 * hasValue(cg, cg.types.voidType); // false
 * hasValue(cg, cg.types.i32);       // true
 * ```
 *
 * @since 1.0.0
 */

export function hasValue(cg: readonly *Cg, ret: u32): bool {
    return ret != cg.types.voidType && ret != cg.types.noreturnType;
}

/**
 * Finds the LLVM type that a Helix type is stored as.
 *
 * @param cg - The code generator
 * @param id - The type id
 * @returns The LLVM type, cached for later calls
 *
 * @remarks
 * The memory layouts are:
 * - `?*T` is a pointer, where null means that the value is not there
 * - `?T` is `{ T, i1 present }`
 * - `T | E` is `{ T, i16 code }`, or a bare `i16` when `T` is `void`, and code 0 means success
 * - an enum is its backing integer, and an error set is `i16`
 * - a union is `{ tag, [n x i64] payload }`, sized for its largest payload,
 *   or just `{ tag }` when no field has a payload
 * - a struct is a named LLVM struct called `<module>.<name>`, with the fields in declaration order (C layout)
 * - a slice and a string literal are `{ ptr, usize }`
 * - `dyn I` is `{ data pointer, vtable pointer }`, and a `Format` is `{ values, formatter }` in the same shape
 *
 * A vtable is an array of function pointers, one per method of the interface in declaration order,
 * and each takes the data pointer as its receiver.
 * A struct goes into the cache before its fields, so a field can point back to the struct.
 * A type that only exists while compiling, such as an untyped integer, has no lowering and stops the compiler.
 *
 * @example
 * ```hx
 * lower(cg, cg.types.boolType); // i1
 * lower(cg, optionalI32);        // { i32, i1 }
 * lower(cg, pointType);          // %main.Point = type { i32, i32 }
 * ```
 *
 * @see lowerFunction
 * @since 1.0.0
 */

export function lower(cg: *Cg, id: u32): Type {
    if (cg.typeCache[id] != null) return cg.typeCache[id];
    const type = typeOf(cg, id);
    let result: Type = null;

    switch (type.kind) {
        case TypeKind.Void, TypeKind.Noreturn: result = voidType(cg);
        case TypeKind.Bool: result = int1Type(cg);
        case TypeKind.Int: result = llvm.LLVMIntTypeInContext(cg.ctx, type.bits as u32);
        case TypeKind.Float: result = type.bits == 32 ? llvm.LLVMFloatTypeInContext(cg.ctx) : llvm.LLVMDoubleTypeInContext(cg.ctx);
        case TypeKind.Pointer, TypeKind.ManyPointer, TypeKind.Function: result = cg.ptrType;
        case TypeKind.Slice, TypeKind.StringLiteral: result = cg.sliceType;
        case TypeKind.Dyn, TypeKind.Format: result = cg.dynType;   // Format: { values, formatter }
        case TypeKind.Array: result = llvm.LLVMArrayType2(lower(cg, type.child), type.len);
        case TypeKind.Enum: result = lower(cg, type.child);
        case TypeKind.ErrorSet: result = lower(cg, cg.types.errorCode);
        case TypeKind.Optional: {
            if (optionalIsPointer(cg, id)) {
                result = cg.ptrType;
            } else {
                const fields: Type[2] = [lower(cg, type.child), int1Type(cg)];
                result = structType(cg, &fields);
            }
        }
        case TypeKind.ErrorUnion: {
            if (errorUnionIsBare(cg, id)) {
                result = lower(cg, cg.types.errorCode);
            } else {
                const fields: Type[2] = [lower(cg, type.child), lower(cg, cg.types.errorCode)];
                result = structType(cg, &fields);
            }
        }
        case TypeKind.Struct: {
            const name = type.name != null ? fromCString(type.name)[0..type.nameLen] : "anon";
            result = llvm.LLVMStructCreateNamed(cg.ctx, llvmName(cg, `${fromCString(cg.options.module_name)}.${name}`));
            cg.typeCache[id] = result;   // cached first, so fields can point back to this struct
            const agg = aggregate(cg, id);
            const fields = zeroed<Type>(agg.fieldCount);
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind == HxMemberField as u8) fields[m.index] = lower(cg, m.type);
            }
            unsafe {
                llvm.LLVMStructSetBody(result, @ptrCast(?Type[*], fields.ptr), agg.fieldCount, 0);
            }
            release(fields);
            return result;
        }
        case TypeKind.Union: {
            const agg = aggregate(cg, id);
            let payload: u64 = 0;
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind != HxMemberField as u8 || m.type == 0) continue;
                const size = llvm.LLVMABISizeOfType(cg.layout, lower(cg, m.type));
                if (size > payload) payload = size;
            }
            const tag = lower(cg, type.child);
            const words = (payload + 7) / 8;
            let fields: Type[2] = [tag, llvm.LLVMArrayType2(int64(cg), words)];
            const all: *Type[2] = &fields;
            result = structType(cg, all[0..(words != 0 ? 2 : 1)]);
        }
        default: fatal(cg, `codegen: unlowered type kind ${type.kind as u32} (a comptime type reached codegen)`);
    }
    cg.typeCache[id] = result;
    return result;
}

/**
 * Finds the LLVM function type of a Helix function type.
 *
 * @param cg - The code generator
 * @param id - The function type
 * @returns The function type with each parameter and the result lowered
 *
 * @remarks
 * A variadic function type keeps its `...`.
 * Structs pass by value here, which matches Helix functions but not the C ABI.
 * The C ABI uses its own signature from the ABI component.
 *
 * @example
 * ```hx
 * // function add(a: i32, b: i32): i32
 * lowerFunction(cg, addType); // i32 (i32, i32)
 * ```
 *
 * @see lower
 * @since 1.0.0
 */

export function lowerFunction(cg: *Cg, id: u32): Type {
    const f = typeOf(cg, id);
    let params: Type[256] = undefined;
    for (const i of 0..f.len) params[i] = lower(cg, param(cg, f, i));
    const all: *Type[256] = &params;
    return fnType(lower(cg, f.child), all[0..f.len], (f.flags & 0x04) != 0);
}

/**
 * Makes an integer constant of any width.
 *
 * @param type - The integer type
 * @param v - The value
 * @returns The constant
 *
 * @remarks
 * Types up to 64 bits take the value directly and sign-extend a negative one.
 * Wider types, such as `i128`, take it as two 64-bit words.
 *
 * @example
 * ```hx
 * constInt(int32(cg), -1); // i32 -1
 * ```
 *
 * @since 1.0.0
 */

export function constInt(type: Type, v: i128): Value {
    if (llvm.LLVMGetIntTypeWidth(type) <= 64) return llvm.LLVMConstInt(type, @truncate(u64, v), llvmBool(v < 0));
    const words: u64[2] = [@truncate(u64, v), @truncate(u64, @truncate(u128, v) >> 64)];
    return llvm.LLVMConstIntOfArbitraryPrecision(type, 2, &words);
}

/**
 * Makes a `usize` constant.
 *
 * @param cg - The code generator
 * @param v - The value
 * @returns The constant, `i64` or `i32` by the target
 *
 * @remarks
 * The type comes from {@link lower}, so the constant always matches the `usize` values that it meets.
 *
 * @example
 * ```hx
 * constUsize(cg, 5); // i64 5
 * ```
 *
 * @since 1.0.0
 */

export function constUsize(cg: *Cg, v: u64): Value {
    return llvm.LLVMConstInt(lower(cg, cg.types.usize), v, 0);
}

/**
 * Makes a `bool` constant.
 *
 * @param cg - The code generator
 * @param v - The value
 * @returns The `i1` constant
 *
 * @remarks
 * Every condition that code generation already knows uses it, such as the flag of a present optional.
 *
 * @example
 * ```hx
 * constBool(cg, true); // i1 true
 * ```
 *
 * @since 1.0.0
 */

export function constBool(cg: *Cg, v: bool): Value {
    return llvm.LLVMConstInt(int1Type(cg), v ? 1 : 0, 0);
}

/**
 * Places a constant in a private global.
 *
 * @param cg - The code generator
 * @param init - The constant to place
 * @param name - The name of the global in the IR
 * @returns The global, which is a pointer to the constant
 *
 * @remarks
 * The global is constant and private, with an unnamed address,
 * so LLVM may merge it with an equal one.
 *
 * @example
 * ```hx
 * constGlobal(cg, array, "const.items"); // @const.items = private unnamed_addr constant [3 x i32] ...
 * ```
 *
 * @see cstring
 * @since 1.0.0
 */

export function constGlobal(cg: *Cg, init: Value, name: readonly u8[*]): Value {
    const global = llvm.LLVMAddGlobal(cg.mod, llvm.LLVMTypeOf(init), name);
    llvm.LLVMSetInitializer(global, init);
    llvm.LLVMSetGlobalConstant(global, 1);
    llvm.LLVMSetLinkage(global, llvm.LLVMPrivateLinkage);
    llvm.LLVMSetUnnamedAddress(global, llvm.LLVMGlobalUnnamedAddr);
    return global;
}

/**
 * Places bytes in a private global with a NUL after them.
 *
 * @param cg - The code generator
 * @param bytes - The bytes to place
 * @param name - The name of the global in the IR
 * @returns The global, which is a pointer to the first byte
 *
 * @remarks
 * The NUL lets C functions such as `dprintf` read the text, and a Helix slice of it leaves the NUL out.
 *
 * @example
 * ```hx
 * cstring(cg, "integer overflow", "panic.msg"); // @panic.msg = private unnamed_addr constant [17 x i8] ...
 * ```
 *
 * @see constGlobal
 * @since 1.0.0
 */

export function cstring(cg: *Cg, bytes: string, name: readonly u8[*]): Value {
    return constGlobal(cg, llvm.LLVMConstStringInContext(cg.ctx, bytes.ptr, @truncate(u32, bytes.len), 0), name);
}

/**
 * Finds the global that holds the bytes of a string constant.
 *
 * @param cg - The code generator
 * @param index - The index of the string value
 * @returns The global named `str`, created on first use and shared afterwards
 *
 * @remarks
 * The cache is keyed by the value index, so every use of one literal points at a single global.
 * An empty string still gets a global, so the pointer of an empty slice is never null.
 *
 * @since 1.0.0
 */

function stringGlobal(cg: *Cg, index: u32): Value {
    if (cg.stringGlobals[index] == null) {
        const v = value(cg, index);
        let text: string = "";
        unsafe {
            if (v.len > 0) text = v.bytes![0..v.len];
        }
        cg.stringGlobals[index] = cstring(cg, text, "str");
    }
    return cg.stringGlobals[index];
}

/**
 * Builds a constant struct of two fields.
 *
 * @param cg - The code generator
 * @param first - The first field
 * @param second - The second field
 * @returns The constant pair
 *
 * @remarks
 * Slices, optionals, and error unions with a value all have this two-field shape.
 *
 * @example
 * ```hx
 * constPair(cg, ptr, constUsize(cg, 5)); // { ptr @str, i64 5 }, a slice
 * ```
 *
 * @see constStruct
 * @since 1.0.0
 */

export function constPair(cg: *Cg, first: Value, second: Value): Value {
    const fields: Value[2] = [first, second];
    return constStruct(cg, &fields);
}

/**
 * Makes an error code constant.
 *
 * @param cg - The code generator
 * @param code - The code, where 0 means success
 * @returns The constant of the error code type
 *
 * @remarks
 * The value is cut to 64 bits before LLVM narrows it to the width of the error code type.
 * Code 0 means success, and each error name has the code that the checker gave it.
 *
 * @example
 * ```hx
 * constErrorCode(cg, 0); // i16 0
 * ```
 *
 * @since 1.0.0
 */

export function constErrorCode(cg: *Cg, code: i128): Value {
    return llvm.LLVMConstInt(lower(cg, cg.types.errorCode), @truncate(u64, code), 0);
}

/**
 * Reads a condition that the checker already computed while compiling.
 *
 * @param cg - The code generator
 * @param node - The condition node
 * @returns 1 for true, 0 for false, and -1 when the condition is only known at run time
 *
 * @remarks
 * Code generation leaves out a branch that the condition rules out,
 * so code for another platform, such as the body of `if (comptime target.os == Os.Windows)`, never reaches the linker.
 *
 * @example
 * ```hx
 * knownCondition(cg, condition); // 1 for `if (true)`
 * knownCondition(cg, flag);      // -1 for `if (flag)`
 * ```
 *
 * @since 1.0.0
 */

export function knownCondition(cg: *Cg, node: u32): i32 {
    const index = infoOf(cg, node).value;
    if (index == 0) return -1;
    const v = value(cg, index);
    if (v.kind != HxValueBool as u8) return -1;
    return v.boolean ? 1 : 0;
}

/**
 * Builds the LLVM constant of a value that the checker computed.
 *
 * @param cg - The code generator
 * @param index - The index of the value
 * @param type - The type that the constant takes
 * @returns The constant
 *
 * @remarks
 * The type decides the shape:
 * - an optional wraps the value in `{ T, true }`, or stays a bare pointer, and `null` becomes all zeros
 * - an error union pairs the value with code 0, and an error pairs `undef` with its code
 * - an integer becomes a float constant when the type is a float
 * - a string is its global, paired with its length unless the type is a many-pointer
 * - a function is its storage, or its C entry point when a C function pointer type holds it
 * - an aggregate from `comptime` becomes a constant array, a named struct,
 *   or for a slice a private `const.items` array paired with its length
 *
 * `undefined` becomes `undef`.
 * A value kind without a lowering stops the compiler.
 *
 * @example
 * ```hx
 * emitConst(cg, infoOf(cg, node).value, cg.types.i32); // i32 42
 * ```
 *
 * @see value
 * @since 1.0.0
 */

export function emitConst(cg: *Cg, index: u32, type: u32): Value {
    const v = value(cg, index);
    const t = typeOf(cg, type);
    const llvmType = lower(cg, type);
    const kind = v.kind as u32;

    if (t.kind == TypeKind.Optional) {
        if (kind == HxValueNull) return llvm.LLVMConstNull(llvmType);
        const inner = emitConst(cg, index, t.child);
        if (optionalIsPointer(cg, type)) return inner;
        return constPair(cg, inner, constBool(cg, true));
    }
    if (t.kind == TypeKind.ErrorUnion) {
        const bare = errorUnionIsBare(cg, type);
        if (kind == HxValueError) {
            const code = constErrorCode(cg, v.integer);
            return bare ? code : constPair(cg, llvm.LLVMGetUndef(lower(cg, t.child)), code);
        }
        const inner = emitConst(cg, index, t.child);
        return bare ? constErrorCode(cg, 0) : constPair(cg, inner, constErrorCode(cg, 0));
    }

    if (kind == HxValueInt) {
        if (t.kind == TypeKind.Float) return llvm.LLVMConstReal(llvmType, v.integer as f64);
        return constInt(llvmType, v.integer);
    }
    if (kind == HxValueFloat) return llvm.LLVMConstReal(llvmType, v.floating);
    if (kind == HxValueBool) return llvm.LLVMConstInt(llvmType, v.boolean ? 1 : 0, 0);
    if (kind == HxValueString) {
        const ptr = stringGlobal(cg, index);
        if (t.kind == TypeKind.ManyPointer) return ptr;
        return constPair(cg, ptr, constUsize(cg, v.len as u64));
    }
    if (kind == HxValueError) return constErrorCode(cg, v.integer);
    if (kind == HxValueUndefined) return llvm.LLVMGetUndef(llvmType);
    if (kind == HxValueNull) return llvm.LLVMConstNull(llvmType);
    if (kind == HxValueFunction) {   // as a C function pointer, a function with structs in its signature needs a C entry
        const sym = @truncate(u32, v.integer);
        return t.kind == TypeKind.Function && (t.flags & 0x10) != 0 ? cCallable(cg, sym) : cg.storage[sym];
    }
    if (kind == HxValueAggregate) {   // an array or struct computed by `comptime`
        const elems = zeroed<Value>(v.count);
        defer release(elems);
        if (t.kind == TypeKind.Slice) {   // a constant slice: its elements in a private constant array
            for (const i of 0..v.count) elems[i] = emitConst(cg, valueElem(cg, v.elems + i), t.child);
            const array = constArray(lower(cg, t.child), elems);
            return constPair(cg, constGlobal(cg, array, "const.items"), constUsize(cg, v.count as u64));
        }
        if (t.kind == TypeKind.Array) {
            for (const i of 0..v.count) elems[i] = emitConst(cg, valueElem(cg, v.elems + i), t.child);
            return constArray(lower(cg, t.child), elems);
        }
        const fields = aggregate(cg, type);
        for (const m of 0..fields.membersCount) {
            const mem = member(cg, fields, m);
            if (mem.kind != HxMemberField as u8) continue;
            elems[mem.index] = emitConst(cg, valueElem(cg, v.elems + mem.index), mem.type);
        }
        unsafe {
            return llvm.LLVMConstNamedStruct(llvmType, @ptrCast(?Value[*], elems.ptr), v.count);
        }
    }
    fatal(cg, `codegen: a constant of value kind ${kind} has no lowering`);
}

/**
 * Emits the check of whether an optional value is there.
 *
 * @param cg - The code generator
 * @param v - The optional value
 * @param type - The optional type
 * @returns The `i1` flag, a null check for a pointer optional or the second field otherwise
 *
 * @remarks
 * A pointer optional has no flag of its own, so the check compares the pointer against null.
 *
 * @example
 * ```hx
 * optionalPresent(cg, v, optionalI32); // %present = extractvalue { i32, i1 } %v, 1
 * ```
 *
 * @see optionalPayload
 * @since 1.0.0
 */

export function optionalPresent(cg: *Cg, v: Value, type: u32): Value {
    if (optionalIsPointer(cg, type)) return llvm.LLVMBuildIsNotNull(cg.b, v, "present");
    return extract(cg, v, 1, "present");
}

/**
 * Emits the read of the value inside an optional, without checking that it is there.
 *
 * @param cg - The code generator
 * @param v - The optional value
 * @param type - The optional type
 * @returns The pointer itself for a pointer optional, or the first field otherwise
 *
 * @remarks
 * It reads whatever the payload holds,
 * so a caller checks {@link optionalPresent} first or already knows that the value is there.
 *
 * @example
 * ```hx
 * optionalPayload(cg, v, optionalI32); // %payload = extractvalue { i32, i1 } %v, 0
 * ```
 *
 * @see optionalPresent
 * @since 1.0.0
 */

export function optionalPayload(cg: *Cg, v: Value, type: u32): Value {
    if (optionalIsPointer(cg, type)) return v;
    return extract(cg, v, 0, "payload");
}

/**
 * Emits an optional that holds a value.
 *
 * @param cg - The code generator
 * @param v - The value to wrap
 * @param type - The optional type
 * @returns The pointer itself for a pointer optional, or `{ v, true }` otherwise
 *
 * @remarks
 * It starts from `undef` and fills both fields, so the result is a new value in registers rather than memory.
 *
 * @example
 * ```hx
 * optionalSome(cg, x, optionalI32); // { i32 %x, i1 true }
 * ```
 *
 * @see optionalPayload
 * @since 1.0.0
 */

export function optionalSome(cg: *Cg, v: Value, type: u32): Value {
    if (optionalIsPointer(cg, type)) return v;
    const result = insert(cg, llvm.LLVMGetUndef(lower(cg, type)), v, 0);
    return insert(cg, result, constBool(cg, true), 1);
}

/**
 * Emits the read of the error code of an error union.
 *
 * @param cg - The code generator
 * @param v - The error union value
 * @param type - The error union type
 * @returns The code, where 0 means success
 *
 * @remarks
 * For `void | E`, the union is the code itself, so the value passes through unchanged.
 *
 * @example
 * ```hx
 * errorUnionCode(cg, v, i32OrError); // %code = extractvalue { i32, i16 } %v, 1
 * ```
 *
 * @see errorUnionPayload
 * @since 1.0.0
 */

export function errorUnionCode(cg: *Cg, v: Value, type: u32): Value {
    if (errorUnionIsBare(cg, type)) return v;
    return extract(cg, v, 1, "code");
}

/**
 * Emits the read of the value of an error union.
 *
 * @param cg - The code generator
 * @param v - The error union value
 * @param type - The error union type
 * @returns The value, or null for `void | E`, which has none
 *
 * @remarks
 * It does not check the code, so a caller reads the value only after the code shows success.
 *
 * @example
 * ```hx
 * errorUnionPayload(cg, v, i32OrError);  // %value = extractvalue { i32, i16 } %v, 0
 * errorUnionPayload(cg, v, voidOrError); // null
 * ```
 *
 * @see errorUnionCode
 * @since 1.0.0
 */

export function errorUnionPayload(cg: *Cg, v: Value, type: u32): Value {
    if (errorUnionIsBare(cg, type)) return null;
    return extract(cg, v, 0, "value");
}

/**
 * Emits an error union from a value and a code.
 *
 * @param cg - The code generator
 * @param payload - The value, or null to leave it undefined, as an error does
 * @param code - The error code, 0 for success
 * @param type - The error union type
 * @returns The error union, which is the code alone for `void | E`
 *
 * @remarks
 * A null payload leaves the value field `undef`, which suits an error result that carries no value.
 *
 * @example
 * ```hx
 * errorUnionMake(cg, x, constErrorCode(cg, 0), i32OrError); // { i32 %x, i16 0 }
 * ```
 *
 * @see errorUnionCode
 * @since 1.0.0
 */

export function errorUnionMake(cg: *Cg, payload: Value, code: Value, type: u32): Value {
    if (errorUnionIsBare(cg, type)) return code;
    let result = llvm.LLVMGetUndef(lower(cg, type));
    if (payload != null) result = insert(cg, result, payload, 0);
    return insert(cg, result, code, 1);
}

/**
 * Emits a call to an LLVM intrinsic that one type overloads.
 *
 * @param cg - The code generator
 * @param name - The name of the intrinsic, such as `llvm.expect`
 * @param overload - The type that picks the overload
 * @param args - The arguments
 * @returns The result of the call
 *
 * @remarks
 * An unknown name stops the compiler.
 *
 * @example
 * ```hx
 * callIntrinsic(cg, "llvm.sadd.with.overflow", int32(cg), &args); // call { i32, i1 } @llvm.sadd.with.overflow.i32
 * ```
 *
 * @since 1.0.0
 */

export function callIntrinsic(cg: *Cg, name: string, overload: Type, args: readonly Value[]): Value {
    const id = llvm.LLVMLookupIntrinsicID(name.ptr, name.len);
    if (id == 0) fatal(cg, `codegen: unknown intrinsic ${name}`);
    let overloads: Type[1] = [overload];
    const fn = llvm.LLVMGetIntrinsicDeclaration(cg.mod, id, &overloads, 1);
    const type = llvm.LLVMIntrinsicGetType(cg.ctx, id, &overloads, 1);
    return call(cg, type, fn, args, "");
}

/**
 * Adds an LLVM attribute without a value to a function.
 *
 * @param cg - The code generator
 * @param fn - The function
 * @param name - The attribute, such as `noreturn` or `nounwind`
 *
 * @remarks
 * It looks up the attribute kind by name, and LLVM gives kind 0 for an unknown name,
 * so the name must be one that LLVM knows.
 *
 * @example
 * ```hx
 * addAttribute(cg, fn, "cold"); // attributes #0 = { cold ... }
 * ```
 *
 * @see addStringAttribute
 * @since 1.0.0
 */

export function addAttribute(cg: *Cg, fn: Value, name: string): void {
    const kind = llvm.LLVMGetEnumAttributeKindForName(name.ptr, name.len);
    llvm.LLVMAddAttributeAtIndex(fn, @truncate(u32, llvm.LLVMAttributeFunctionIndex as i64), llvm.LLVMCreateEnumAttribute(cg.ctx, kind, 0));
}

/**
 * Adds a key and value attribute to a function.
 *
 * @param cg - The code generator
 * @param fn - The function
 * @param key - The attribute key
 * @param text - The attribute value
 *
 * @remarks
 * A safe build marks functions with `frame-pointer` set to `all` this way, which keeps stack traces reliable.
 *
 * @example
 * ```hx
 * addStringAttribute(cg, fn, "frame-pointer", "all"); // "frame-pointer"="all"
 * ```
 *
 * @see addAttribute
 * @since 1.0.0
 */

export function addStringAttribute(cg: *Cg, fn: Value, key: string, text: string): void {
    const attr = llvm.LLVMCreateStringAttribute(cg.ctx, key.ptr, @truncate(u32, key.len), text.ptr, @truncate(u32, text.len));
    llvm.LLVMAddAttributeAtIndex(fn, @truncate(u32, llvm.LLVMAttributeFunctionIndex as i64), attr);
}

/**
 * Finds the debug info file of a source file.
 *
 * @param cg - The code generator
 * @param file - The index of the source file
 * @returns The file, created on first use
 *
 * @remarks
 * The path splits at its last `/` into a directory and a name.
 * A path without a `/` gets `.` as its directory.
 *
 * @example
 * ```hx
 * diFile(cg, 0); // !DIFile(filename: "main.hx", directory: "src")
 * ```
 *
 * @see sourcePath
 * @since 1.0.0
 */

export function diFile(cg: *Cg, file: u32): Meta {
    if (cg.diFiles[file] == null) {
        const path = sourcePath(cg, file);
        let slash: usize = path.len;
        for (const ch, i of path) {
            if (ch == '/') slash = i;
        }
        const name = slash < path.len ? path[slash + 1..] : path;
        const dir = slash < path.len ? path : ".";
        const dirLen = slash < path.len ? slash : 1;
        cg.diFiles[file] = llvm.LLVMDIBuilderCreateFile(cg.di, name.ptr, name.len, dir.ptr, dirLen);
    }
    return cg.diFiles[file];
}

/**
 * Finds the file, line, and column where a token starts.
 *
 * @param cg - The code generator
 * @param token - The token index
 * @returns The position, with the line and column counted from 1
 *
 * @remarks
 * It works without debug info, so the location of a test title comes from it as well.
 *
 * @example
 * ```hx
 * diPosition(cg, symbolOf(cg, sym).token).line; // 3
 * ```
 *
 * @since 1.0.0
 */

export function diPosition(cg: readonly *Cg, token: u32): HxLineCol {
    return hxSourceLineCol(cg.ast.src, tokenStart(cg, token));
}

/**
 * Attributes the instructions that follow to the line of a node, for debuggers and stack traces.
 *
 * @param cg - The code generator
 * @param node - The node whose first byte gives the line and column
 *
 * @remarks
 * Outside a Helix function with debug info, such as in a generated helper, it does nothing.
 *
 * @example
 * ```hx
 * setLocation(cg, stmt); // later instructions carry !dbg with the line of stmt
 * ```
 *
 * @since 1.0.0
 */

export function setLocation(cg: *Cg, node: u32): void {
    if (cg.diScope == null) return;
    let start: u32 = 0;
    let len: u32 = 0;
    hxNodeSpan(cg.ast, node, &start, &len);
    const pos = hxSourceLineCol(cg.ast.src, start);
    llvm.LLVMSetCurrentDebugLocation2(cg.b, llvm.LLVMDIBuilderCreateDebugLocation(cg.ctx, pos.line, pos.col, cg.diScope, null));
}

/**
 * Builds a DWARF base type.
 *
 * @param cg - The code generator
 * @param name - The name of the type
 * @param bits - The size in bits
 * @param encoding - The DWARF encoding, such as `DW_ATE_signed`
 * @returns The base type
 *
 * @remarks
 * It carries no flags, and {@link diType} wraps it in a typedef so that debuggers show the Helix name.
 *
 * @since 1.0.0
 */

function diBasic(cg: *Cg, name: string, bits: u64, encoding: u32): Meta {
    return llvm.LLVMDIBuilderCreateBasicType(cg.di, name.ptr, name.len, bits, encoding, llvm.LLVMDIFlagZero);
}

/**
 * Builds a DWARF member at the offset that the target layout gives a field.
 *
 * @param cg - The code generator
 * @param scope - The struct that owns the member
 * @param name - The name of the member
 * @param owner - The LLVM struct type that holds the field
 * @param index - The position of the field in that type
 * @param memberType - The Helix type of the member, used when `memberDi` is null
 * @param memberDi - The debug type to use directly, or null to derive it from `memberType`
 * @returns The member
 *
 * @remarks
 * The size, alignment, and offset come from the data layout, so the debug view matches the real memory layout.
 * A caller passes the debug type directly for a field without a Helix type, such as the pointer of a slice.
 *
 * @since 1.0.0
 */

function diMember(cg: *Cg, scope: Meta, name: string, owner: Type, index: u32, memberType: u32, memberDi: Meta): Meta {
    const field = llvm.LLVMStructGetTypeAtIndex(owner, index);
    const bits = llvm.LLVMSizeOfTypeInBits(cg.layout, field);
    const align = llvm.LLVMABIAlignmentOfType(cg.layout, field) * 8;
    const offset = llvm.LLVMOffsetOfElement(cg.layout, owner, index) * 8;
    const type = memberDi != null ? memberDi : diType(cg, memberType);
    return llvm.LLVMDIBuilderCreateMemberType(cg.di, scope, name.ptr, name.len, null, 0, bits, align, offset, llvm.LLVMDIFlagZero, type);
}

/**
 * Builds a DWARF struct with the size and alignment of an LLVM type.
 *
 * @param cg - The code generator
 * @param name - The name of the struct
 * @param llvmType - The LLVM type that the struct describes
 * @param members - The members
 * @returns The struct type
 *
 * @remarks
 * The struct has no file or line, since code generation also builds such structs for slices and optionals,
 * which have no declaration.
 *
 * @since 1.0.0
 */

function diStruct(cg: *Cg, name: string, llvmType: Type, members: readonly Meta[]): Meta {
    const bits = llvm.LLVMSizeOfTypeInBits(cg.layout, llvmType);
    const align = llvm.LLVMABIAlignmentOfType(cg.layout, llvmType) * 8;
    unsafe {
        return llvm.LLVMDIBuilderCreateStructType(cg.di, cg.diUnit, name.ptr, name.len, null, 0, bits, align, llvm.LLVMDIFlagZero,
                                               null, @ptrCast(?Meta[*], members.ptr), @truncate(u32, members.len), 0, null, "", 0);
    }
}

/**
 * Builds a DWARF typedef that gives a type its Helix name.
 *
 * @param cg - The code generator
 * @param name - The Helix name, such as `i32`
 * @param base - The type to name
 * @returns The typedef
 *
 * @remarks
 * lldb shows a base type by its C name, such as `int`, rather than its own name, so the typedef keeps the Helix one.
 *
 * @since 1.0.0
 */

function diNamed(cg: *Cg, name: string, base: Meta): Meta {
    return llvm.LLVMDIBuilderCreateTypedef(cg.di, base, name.ptr, name.len, null, 0, cg.diUnit, 0);
}

/**
 * Builds the DWARF type of an error code as an enumeration of every error name.
 *
 * @param cg - The code generator
 * @param name - The name of the type
 * @param bits - The size in bits
 * @param align - The alignment in bits
 * @returns The enumeration
 *
 * @remarks
 * Debuggers then show `NotFound` instead of 3.
 *
 * @since 1.0.0
 */

function diErrors(cg: *Cg, name: string, bits: u64, align: u32): Meta {
    const count = cg.sema.errorNames.len;
    const values = zeroed<Meta>(count);
    for (const i of 1..count) {
        let len: u32 = 0;
        let id: u32 = 0;
        unsafe {
            id = cg.sema.errorNames.items![i];
        }
        const text = hxNameText(&cg.sema.names, id, &len);
        unsafe {
            values[i - 1] = llvm.LLVMDIBuilderCreateEnumerator(cg.di, text, len, i as i64, 1);
        }
    }
    let result: Meta = null;
    unsafe {
        result = llvm.LLVMDIBuilderCreateEnumerationType(cg.di, cg.diUnit, name.ptr, name.len, null, 0, bits, align,
                                                      @ptrCast(?Meta[*], values.ptr), @truncate(u32, count - 1), diType(cg, cg.types.errorCode));
    }
    release(values);
    return result;
}

/**
 * Builds a 64-bit DWARF pointer type.
 *
 * @param cg - The code generator
 * @param pointee - The type pointed at, or null for an opaque pointer
 * @param name - The name of the pointer type
 * @returns The pointer type
 *
 * @remarks
 * The size and alignment are fixed at 64 bits, so the debug view of a pointer on a 32-bit target is wrong.
 *
 * @since 1.0.0
 */

function diPointer(cg: *Cg, pointee: Meta, name: string): Meta {
    return llvm.LLVMDIBuilderCreatePointerType(cg.di, pointee, 64, 64, 0, name.ptr, name.len);
}

/**
 * Describes a Helix type in DWARF, so that debuggers can show its values.
 *
 * @param cg - The code generator
 * @param type - The type id
 * @returns The debug type, cached for later calls, or null for a type that it cannot describe
 *
 * @remarks
 * Integers, floats, pointers, and functions become typedefs of base types under their Helix names.
 * Slices, optionals, error unions, `dyn` values, and formats become structs of their fields.
 * Enums and error sets become enumerations, so a debugger shows the names of their values.
 * A struct goes in as a placeholder first, so a field can point back to it, and the full type replaces it afterwards.
 * A union shows as raw bytes for now.
 * `void`, `noreturn`, and the types that only exist while compiling, such as an untyped integer, give null,
 * since nothing stores or shows them.
 *
 * @example
 * ```hx
 * diType(cg, cg.types.i32);       // !DIDerivedType(tag: DW_TAG_typedef, name: "i32", ...)
 * diType(cg, cg.types.voidType); // null
 * ```
 *
 * @see debuggable
 * @since 1.0.0
 */

export function diType(cg: *Cg, type: u32): Meta {
    if (cg.diTypes[type] != null) return cg.diTypes[type];
    const t = typeOf(cg, type);
    const name = typeName(cg, type);
    if (t.kind == TypeKind.Void || t.kind == TypeKind.Noreturn) return null;
    // types only the compiler has (`const n = 64;` before it's used as a u8 or a u64): nothing to store or show
    if (t.kind == TypeKind.ComptimeInt || t.kind == TypeKind.ComptimeFloat || t.kind == TypeKind.Undefined ||
        t.kind == TypeKind.Null) return null;
    const llvmType = lower(cg, type);
    const bits = llvm.LLVMSizeOfTypeInBits(cg.layout, llvmType);
    const align = llvm.LLVMABIAlignmentOfType(cg.layout, llvmType) * 8;
    let result: Meta = null;

    switch (t.kind) {
        case TypeKind.Bool: result = diBasic(cg, "bool", 8, 0x02);   // DW_ATE_boolean
        case TypeKind.Int: result = diNamed(cg, name, diBasic(cg, name, llvm.LLVMABISizeOfType(cg.layout, llvmType) * 8, (t.flags & Signed) != 0 ? 0x05 : 0x07));
        case TypeKind.Float: result = diNamed(cg, name, diBasic(cg, name, bits, 0x04));   // DW_ATE_float
        case TypeKind.ErrorSet: result = diErrors(cg, name, bits, align);
        case TypeKind.Pointer, TypeKind.ManyPointer: result = diNamed(cg, name, diPointer(cg, diType(cg, t.child), name));
        case TypeKind.Function: result = diNamed(cg, name, diPointer(cg, null, name));
        case TypeKind.Array: {
            let range: Meta[1] = [llvm.LLVMDIBuilderGetOrCreateSubrange(cg.di, 0, t.len as i64)];
            result = llvm.LLVMDIBuilderCreateArrayType(cg.di, bits, align, diType(cg, t.child), &range, 1);
        }
        case TypeKind.Slice, TypeKind.StringLiteral: {
            const elem = t.kind == TypeKind.Slice ? t.child : cg.types.u8;
            const ptr = diPointer(cg, diType(cg, elem), "ptr");
            const members: Meta[2] = [
                diMember(cg, cg.diUnit, "ptr", llvmType, 0, 0, ptr),
                diMember(cg, cg.diUnit, "len", llvmType, 1, cg.types.usize, null),
            ];
            result = diStruct(cg, name, llvmType, &members);
        }
        case TypeKind.Optional: {
            if (optionalIsPointer(cg, type)) {
                result = diNamed(cg, name, diType(cg, t.child));
            } else {
                const members: Meta[2] = [
                    diMember(cg, cg.diUnit, "value", llvmType, 0, t.child, null),
                    diMember(cg, cg.diUnit, "present", llvmType, 1, cg.types.boolType, null),
                ];
                result = diStruct(cg, name, llvmType, &members);
            }
        }
        case TypeKind.ErrorUnion: {
            if (errorUnionIsBare(cg, type)) {
                result = diType(cg, @truncate(u32, t.len));
            } else {
                const members: Meta[2] = [
                    diMember(cg, cg.diUnit, "value", llvmType, 0, t.child, null),
                    diMember(cg, cg.diUnit, "error", llvmType, 1, @truncate(u32, t.len), null),
                ];
                result = diStruct(cg, name, llvmType, &members);
            }
        }
        case TypeKind.Enum: {
            const agg = aggregate(cg, type);
            const values = zeroed<Meta>(agg.membersCount);
            let count: u32 = 0;
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind != HxMemberEnumValue as u8) continue;
                const text = tokenText(cg, m.token);
                values[count] = llvm.LLVMDIBuilderCreateEnumerator(cg.di, text.ptr, text.len, @truncate(i64, m.value), llvmBool(!isSigned(cg, t.child)));
                count += 1;
            }
            unsafe {
                result = llvm.LLVMDIBuilderCreateEnumerationType(cg.di, cg.diUnit, name.ptr, name.len, null, 0, bits, align,
                                                              @ptrCast(?Meta[*], values.ptr), count, diType(cg, t.child));
            }
            release(values);
        }
        case TypeKind.Struct: {
            // A placeholder first, so fields that point back to this struct can refer to it.
            const placeholder = llvm.LLVMDIBuilderCreateReplaceableCompositeType(cg.di, 0x13, name.ptr, name.len, cg.diUnit, null, 0, 0,
                                                                              bits, align, llvm.LLVMDIFlagZero, "", 0);
            cg.diTypes[type] = placeholder;
            const agg = aggregate(cg, type);
            const members = zeroed<Meta>(agg.fieldCount);
            let count: u32 = 0;
            for (const i of 0..agg.membersCount) {
                const m = member(cg, agg, i);
                if (m.kind != HxMemberField as u8) continue;
                members[count] = diMember(cg, placeholder, tokenText(cg, m.token), llvmType, m.index, m.type, null);
                count += 1;
            }
            result = diStruct(cg, name, llvmType, members[0..count]);
            release(members);
            llvm.LLVMMetadataReplaceAllUsesWith(placeholder, result);
        }
        case TypeKind.Union: result = diBasic(cg, name, bits, 0x08);   // shown as raw bytes for now
        case TypeKind.Dyn, TypeKind.Format: {
            const opaque = diPointer(cg, null, "ptr");
            const members: Meta[2] = [
                diMember(cg, cg.diUnit, "data", llvmType, 0, 0, opaque),
                diMember(cg, cg.diUnit, "vtable", llvmType, 1, 0, opaque),
            ];
            result = diStruct(cg, name, llvmType, &members);
        }
        default: return null;
    }
    cg.diTypes[type] = result;
    return result;
}

/**
 * Checks whether a debugger can show values of a type, so that locals of it are worth describing.
 *
 * @param cg - The code generator
 * @param type - The type id
 * @returns `true` inside a function with debug info, for a type that {@link diType} can describe
 *
 * @remarks
 * Outside a function with debug info it gives `false` before it builds any debug type.
 *
 * @example
 * ```hx
 * debuggable(cg, cg.types.i32); // true when debug info is on
 * ```
 *
 * @see diType
 * @since 1.0.0
 */

export function debuggable(cg: *Cg, type: u32): bool {
    return cg.diScope != null && diType(cg, type) != null;
}

/**
 * Describes a variable stored in an alloca, so that debuggers can show it by name.
 *
 * @param cg - The code generator
 * @param sym - The symbol of the variable
 * @param storage - The alloca that holds it
 * @param argNo - The position of a parameter, from 1, or 0 for a local
 *
 * @remarks
 * Outside a function with debug info, or for a type that {@link diType} cannot describe, it does nothing.
 *
 * @example
 * ```hx
 * declareVariable(cg, sym, slot, 1); // #dbg_declare(ptr %a1, !DILocalVariable(name: "a", arg: 1, ...), ...)
 * ```
 *
 * @see localStorage
 * @since 1.0.0
 */

export function declareVariable(cg: *Cg, sym: u32, storage: Value, argNo: u32): void {
    if (cg.diScope == null) return;
    const s = symbolOf(cg, sym);
    const type = diType(cg, s.type);
    if (type == null) return;
    const pos = diPosition(cg, s.token);
    const file = diFile(cg, pos.file);
    const name = tokenText(cg, s.token);
    const variable = argNo != 0
        ? llvm.LLVMDIBuilderCreateParameterVariable(cg.di, cg.diScope, name.ptr, name.len, argNo, file, pos.line, type, 1, llvm.LLVMDIFlagZero)
        : llvm.LLVMDIBuilderCreateAutoVariable(cg.di, cg.diScope, name.ptr, name.len, file, pos.line, type, 1, llvm.LLVMDIFlagZero, 0);
    const loc = llvm.LLVMDIBuilderCreateDebugLocation(cg.ctx, pos.line, pos.col, cg.diScope, null);
    void llvm.LLVMDIBuilderInsertDeclareRecordAtEnd(cg.di, storage, variable, llvm.LLVMDIBuilderCreateExpression(cg.di, null, 0), loc,
                                                 llvm.LLVMGetInsertBlock(cg.b));
}

/**
 * Finds a C function in the module, declaring it the first time.
 *
 * @param cg - The code generator
 * @param name - The C name
 * @param type - The function type to declare it with
 * @returns The function
 *
 * @remarks
 * An earlier declaration with the same name wins, whatever type this call gives.
 *
 * @example
 * ```hx
 * declareC(cg, "abort", abortType); // declare void @abort()
 * ```
 *
 * @since 1.0.0
 */

export function declareC(cg: *Cg, name: readonly u8[*], type: Type): Value {
    const fn = llvm.LLVMGetNamedFunction(cg.mod, name);
    return fn != null ? fn : llvm.LLVMAddFunction(cg.mod, name, type);
}

/**
 * Marks a panic function as internal, `noreturn`, `cold`, `noinline`, and `nounwind`, then starts its entry block.
 *
 * @param cg - The code generator
 * @param fn - The function to set up
 *
 * @remarks
 * It also keeps the frame pointer, so the stack trace can walk through the panic.
 *
 * @since 1.0.0
 */

function coldHandler(cg: *Cg, fn: Value): void {
    llvm.LLVMSetLinkage(fn, llvm.LLVMInternalLinkage);
    addAttribute(cg, fn, "noreturn");
    addAttribute(cg, fn, "cold");
    addAttribute(cg, fn, "noinline");
    addAttribute(cg, fn, "nounwind");
    addStringAttribute(cg, fn, "frame-pointer", "all");
    positionAtEnd(cg, llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "entry"));
}

/**
 * Emits the runtime panic handlers on first use.
 *
 * @param cg - The code generator
 *
 * @remarks
 * `helix.panic(header, header_len, location)` flushes stdout first,
 * so output printed before the panic appears before the message.
 * It then writes the message to stderr with `dprintf`,
 * calls `hx_stack_trace` from the runtime, and aborts.
 * The trace shows file and line when the program has debug info.
 * `helix.panic_bounds(location, index, len)` formats the out-of-bounds header with `snprintf`
 * and passes it on to `helix.panic`.
 * The output looks like this:
 *
 * ```text
 * panic: integer overflow
 *  --> test.hx:12:15
 *   |
 * 12 |     const c = a + b;
 *   |               ^~~~~
 * stack trace:
 * ```
 *
 * A second call does nothing, and the builder of the function being emitted stays where it was.
 *
 * @example
 * ```hx
 * buildPanicHandler(cg); // define internal void @helix.panic(ptr %0, i64 %1, ptr %2)
 * ```
 *
 * @see emitPanic
 * @since 1.0.0
 */

export function buildPanicHandler(cg: *Cg): void {
    if (cg.panicFn != null) return;
    const i32t = int32(cg);
    const i64t = int64(cg);
    const ptr = cg.ptrType;
    const usize = cg.usizeType;
    const voidT = voidType(cg);

    const dprintfParams: Type[2] = [i32t, ptr];
    const dprintfType = fnType(i32t, &dprintfParams, true);
    const snprintfParams: Type[3] = [ptr, usize, ptr];
    const snprintfType = fnType(i32t, &snprintfParams, true);
    const abortType = fnType(voidT, [], false);
    const fflushParams: Type[1] = [ptr];
    const fflushType = fnType(i32t, &fflushParams, false);
    const fflushFn = declareC(cg, "fflush", fflushType);
    const dprintfFn = declareC(cg, "dprintf", dprintfType);
    const snprintfFn = declareC(cg, "snprintf", snprintfType);
    const abortFn = declareC(cg, "abort", abortType);
    addAttribute(cg, abortFn, "noreturn");

    const saved = cg.b;
    cg.b = llvm.LLVMCreateBuilderInContext(cg.ctx);

    // void helix.panic(ptr header, usize header_len, ptr location)
    const panicParams: Type[3] = [ptr, usize, ptr];
    cg.panicFnType = fnType(voidT, &panicParams, false);
    cg.panicFn = llvm.LLVMAddFunction(cg.mod, "helix.panic", cg.panicFnType);
    coldHandler(cg, cg.panicFn);

    // Flush stdout first, so output printed before the panic appears before the message.
    const flushArgs: Value[1] = [llvm.LLVMConstNull(ptr)];
    void call(cg, fflushType, fflushFn, &flushArgs, "");
    const headerLen = llvm.LLVMBuildIntCast2(cg.b, llvm.LLVMGetParam(cg.panicFn, 1), i32t, 0, "");
    const message: Value[5] = [llvm.LLVMConstInt(i32t, 2, 0), cstring(cg, "panic: %.*s\n%s", "panic.fmt"), headerLen,
                               llvm.LLVMGetParam(cg.panicFn, 0), llvm.LLVMGetParam(cg.panicFn, 2)];
    void call(cg, dprintfType, dprintfFn, &message, "");
    // The runtime prints the stack trace, with file and line when the program has debug info.
    const traceType = fnType(voidT, [], false);
    void call(cg, traceType, declareC(cg, "hx_stack_trace", traceType), [], "");
    void call(cg, abortType, abortFn, [], "");
    void llvm.LLVMBuildUnreachable(cg.b);

    // void helix.panic_bounds(ptr location, usize index, usize len)
    const boundsParams: Type[3] = [ptr, usize, usize];
    cg.panicBoundsFnType = fnType(voidT, &boundsParams, false);
    cg.panicBoundsFn = llvm.LLVMAddFunction(cg.mod, "helix.panic_bounds", cg.panicBoundsFnType);
    coldHandler(cg, cg.panicBoundsFn);
    const buffer = llvm.LLVMBuildAlloca(cg.b, llvm.LLVMArrayType2(int8Type(cg), 96), "header");
    const formatArgs: Value[5] = [buffer, llvm.LLVMConstInt(usize, 96, 0), cstring(cg, "index out of bounds: index %llu, len %llu", "bounds.fmt"),
                                  llvm.LLVMBuildZExt(cg.b, llvm.LLVMGetParam(cg.panicBoundsFn, 1), i64t, ""),
                                  llvm.LLVMBuildZExt(cg.b, llvm.LLVMGetParam(cg.panicBoundsFn, 2), i64t, "")];
    const written = call(cg, snprintfType, snprintfFn, &formatArgs, "");
    const writtenLen = llvm.LLVMBuildSExt(cg.b, written, usize, "");
    const panicArgs: Value[3] = [buffer, writtenLen, llvm.LLVMGetParam(cg.panicBoundsFn, 0)];
    void call(cg, cg.panicFnType, cg.panicFn, &panicArgs, "");
    void llvm.LLVMBuildUnreachable(cg.b);

    llvm.LLVMDisposeBuilder(cg.b);
    cg.b = saved;
}

/**
 * Builds the constant `--> file:line:col` snippet of a node that a panic prints.
 *
 * @param cg - The code generator
 * @param node - The node to point at
 * @returns A global named `panic.at` that holds the snippet with its source line and caret underline
 *
 * @remarks
 * The diagnostic renderer writes the snippet at compile time, so a panic does no formatting of its own.
 *
 * @example
 * ```hx
 * locationString(cg, node); // @panic.at = private unnamed_addr constant [146 x i8] c" --> test.hx:1:51..."
 * ```
 *
 * @see emitPanic
 * @since 1.0.0
 */

export function locationString(cg: *Cg, node: u32): Value {
    let start: u32 = 0;
    let len: u32 = 0;
    hxNodeSpan(cg.ast, node, &start, &len);
    let text: ?u8[*] = null;
    let size: usize = 0;
    const out = hx_os_memstream(&text, &size);
    hxDiagRenderLocation(out, cg.ast.src, start, len);
    hx_os_memstream_close(out);
    let rendered: string = "";
    unsafe {
        if (text != null) rendered = text![0..size];
    }
    const global = cstring(cg, rendered, "panic.at");
    free(text);
    return global;
}

/**
 * Emits a call to the panic handler that never returns.
 *
 * @param cg - The code generator
 * @param node - The node that the location of the message points at
 * @param header - The first line of the message, such as `integer overflow`
 *
 * @remarks
 * The current block ends in `unreachable` after the call.
 *
 * @example
 * ```hx
 * emitPanic(cg, node, "reached unreachable code"); // call void @helix.panic(ptr @panic.msg, i64 24, ptr @panic.at)
 * ```
 *
 * @see emitCheck
 * @since 1.0.0
 */

export function emitPanic(cg: *Cg, node: u32, header: string): void {
    buildPanicHandler(cg);
    const args: Value[3] = [cstring(cg, header, "panic.msg"), constUsize(cg, header.len as u64), locationString(cg, node)];
    void call(cg, cg.panicFnType, cg.panicFn, &args, "");
    void llvm.LLVMBuildUnreachable(cg.b);
}

/**
 * Emits a branch to a panic when a condition is true.
 *
 * @param cg - The code generator
 * @param failed - The `i1` condition that means the check failed
 * @param node - The node that the panic points at
 * @param header - The first line of the panic message
 *
 * @remarks
 * Overflow, division, cast, and shift checks use it in debug and release-safe builds,
 * and the caller decides whether the build checks at all.
 * `llvm.expect` marks the failure as unlikely, so the code that passes stays straight-line,
 * and the builder ends up in the `ok` block.
 *
 * @example
 * ```hx
 * emitCheck(cg, overflowed, node, "integer overflow"); // br i1 %3, label %panic, label %ok
 * ```
 *
 * @see emitBoundsCheck
 * @since 1.0.0
 */

export function emitCheck(cg: *Cg, failed: Value, node: u32, header: string): void {
    const args: Value[2] = [failed, constBool(cg, false)];
    const expected = callIntrinsic(cg, "llvm.expect", int1Type(cg), &args);
    const fail = block(cg, "panic");
    const ok = block(cg, "ok");
    condBr(cg, expected, fail, ok);
    positionAtEnd(cg, fail);
    emitPanic(cg, node, header);
    positionAtEnd(cg, ok);
}

/**
 * Emits a branch to a bounds panic when an index is not below a length.
 *
 * @param cg - The code generator
 * @param index - The index, as a `usize`
 * @param len - The length, as a `usize`
 * @param node - The node that the panic points at
 *
 * @remarks
 * The comparison is unsigned, so a negative index converted to `usize` fails as well.
 * The panic prints both numbers through `helix.panic_bounds`.
 * Builds without safety checks emit nothing.
 *
 * @example
 * ```hx
 * emitBoundsCheck(cg, index, len, node); // %oob = icmp uge i64 %i, %len
 * ```
 *
 * @see emitCheck
 * @since 1.0.0
 */

export function emitBoundsCheck(cg: *Cg, index: Value, len: Value, node: u32): void {
    if (!cg.safe) return;
    const failed = llvm.LLVMBuildICmp(cg.b, llvm.LLVMIntUGE, index, len, "oob");
    const args: Value[2] = [failed, constBool(cg, false)];
    const expected = callIntrinsic(cg, "llvm.expect", int1Type(cg), &args);
    const fail = block(cg, "panic.bounds");
    const ok = block(cg, "ok");
    condBr(cg, expected, fail, ok);

    positionAtEnd(cg, fail);
    buildPanicHandler(cg);
    const panicArgs: Value[3] = [locationString(cg, node), index, len];
    void call(cg, cg.panicBoundsFnType, cg.panicBoundsFn, &panicArgs, "");
    void llvm.LLVMBuildUnreachable(cg.b);
    positionAtEnd(cg, ok);
}

/**
 * Allocates a stack slot at the top of the entry block.
 *
 * @param cg - The code generator
 * @param type - The type of the slot
 * @param name - The name of the slot in the IR
 * @returns The alloca
 *
 * @remarks
 * Every alloca goes into the entry block, so a loop never grows the stack,
 * and LLVM's `mem2reg` turns the slots into registers when it optimizes.
 * The current position of the builder stays as it is.
 *
 * @example
 * ```hx
 * entryAlloca(cg, int32(cg), "x"); // %x = alloca i32, align 4, in %entry
 * ```
 *
 * @see localStorage
 * @since 1.0.0
 */

export function entryAlloca(cg: *Cg, type: Type, name: readonly u8[*]): Value {
    const builder = llvm.LLVMCreateBuilderInContext(cg.ctx);
    const first = llvm.LLVMGetFirstInstruction(cg.entryBlock);
    if (first != null) llvm.LLVMPositionBuilderBefore(builder, first);
    else llvm.LLVMPositionBuilderAtEnd(builder, cg.entryBlock);
    const slot = llvm.LLVMBuildAlloca(builder, type, name);
    llvm.LLVMDisposeBuilder(builder);
    return slot;
}

/**
 * Finds the stack slot of a local, creating it on first use.
 *
 * @param cg - The code generator
 * @param sym - The symbol of the local
 * @returns The alloca, named after the local
 *
 * @remarks
 * A new local, other than a parameter, is also described for the debugger.
 * The code that copies the parameters in describes those itself.
 *
 * @example
 * ```hx
 * store(cg, value, localStorage(cg, sym)); // store i32 %v, ptr %x
 * ```
 *
 * @see entryAlloca
 * @since 1.0.0
 */

export function localStorage(cg: *Cg, sym: u32): Value {
    if (cg.storage[sym] == null) {
        cg.storage[sym] = entryAlloca(cg, lower(cg, symbolOf(cg, sym).type), tokenName(cg, symbolOf(cg, sym).token));
        if (symbolOf(cg, sym).kind != HxSymParam as u8) declareVariable(cg, sym, cg.storage[sym], 0);
    }
    return cg.storage[sym];
}

/**
 * Starts emitting into another function with a builder of its own.
 *
 * @param cg - The code generator
 * @param fn - The function to emit, which gets a new `entry` block
 * @returns The builder, function, and entry block to go back to with {@link detourEnd}
 *
 * @remarks
 * Generated helpers, such as formatting functions and C entry points,
 * are built this way in the middle of another function.
 * Only the builder, the function, and the entry block are saved, so the helper must leave the rest of the state alone.
 *
 * @example
 * ```hx
 * const saved = detourBegin(cg, helper);
 * // emit the body of the helper
 * detourEnd(cg, saved);
 * ```
 *
 * @see detourEnd
 * @since 1.0.0
 */

export function detourBegin(cg: *Cg, fn: Value): Detour {
    const d = Detour { b: cg.b, fn: cg.fn, entry: cg.entryBlock };
    cg.b = llvm.LLVMCreateBuilderInContext(cg.ctx);
    cg.fn = fn;
    cg.entryBlock = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fn, "entry");
    positionAtEnd(cg, cg.entryBlock);
    return d;
}

/**
 * Returns to where code generation was before {@link detourBegin}.
 *
 * @param cg - The code generator
 * @param d - The saved state that {@link detourBegin} returned
 *
 * @remarks
 * The builder of the detour is disposed.
 *
 * @example
 * ```hx
 * detourEnd(cg, saved); // the builder is back in the function that was being emitted
 * ```
 *
 * @see detourBegin
 * @since 1.0.0
 */

export function detourEnd(cg: *Cg, d: Detour): void {
    llvm.LLVMDisposeBuilder(cg.b);
    cg.b = d.b;
    cg.fn = d.fn;
    cg.entryBlock = d.entry;
}

/**
 * Adds an internal `nounwind` function that code generation builds on its own.
 *
 * @param cg - The code generator
 * @param name - The name of the function in the IR
 * @param type - The function type
 * @returns The function, without a body yet
 *
 * @remarks
 * Internal linkage keeps the helper private to the module, so LLVM may inline it or drop it when unused.
 * Fill the body between {@link detourBegin} and {@link detourEnd}, so the function being emitted stays intact.
 *
 * @example
 * ```hx
 * helperFunction(cg, "main.add.thunk", fnT); // define internal ... @main.add.thunk(...) #0
 * ```
 *
 * @see detourBegin
 * @since 1.0.0
 */

export function helperFunction(cg: *Cg, name: readonly u8[*], type: Type): Value {
    const fn = llvm.LLVMAddFunction(cg.mod, name, type);
    llvm.LLVMSetLinkage(fn, llvm.LLVMInternalLinkage);
    addAttribute(cg, fn, "nounwind");
    return fn;
}
