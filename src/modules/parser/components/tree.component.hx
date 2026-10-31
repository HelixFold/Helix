/**
 * Imports
 */

import { NodeKind } from "@constants/ast.constant";
import { hxVecGrowImpl } from "@components/memory.component";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { HxNode, HxRange, HxFnData } from "@models/structs/ast-model.struct";

/**
 * Appends a node with flags to the tree.
 *
 * @param p - The parser state
 * @param kind - The kind of the node
 * @param flags - The `Flag` bits of the node
 * @param token - The main token of the node
 * @param a - The first slot
 * @param b - The second slot
 * @returns The index of the new node
 *
 * @remarks
 * The node array grows by doubling when it is full,
 * so a node index stays valid across calls while a pointer into the array may not.
 * The operator field starts at 0, and {@link setOp} fills it in afterwards.
 *
 * @example
 * ```hx
 * addFlaggedNode(p, NodeKind.Const, FlagExport, name, type, value); // the index of the new node
 * ```
 *
 * @since 1.0.0
 */

export function addFlaggedNode(p: *Parser, kind: NodeKind, flags: u8, token: u32, a: u32, b: u32): u32 {
    const ast = p.ast;
    unsafe {
        if (ast.nodesLen == ast.nodesCap) {
            hxVecGrowImpl(@ptrCast(*?u8[*], &ast.nodes), &ast.nodesCap, ast.nodesLen + 1, @sizeOf(HxNode));
        }
        ast.nodes![ast.nodesLen] = HxNode { kind, flags, op: 0, token, a, b };
    }
    ast.nodesLen += 1;
    return ast.nodesLen - 1;
}

/**
 * Appends a node without flags to the tree.
 *
 * @param p - The parser state
 * @param kind - The kind of the node
 * @param token - The main token of the node
 * @param a - The first slot
 * @param b - The second slot
 * @returns The index of the new node
 *
 * @remarks
 * It calls {@link addFlaggedNode} with the flags at 0.
 * Reach for {@link addFlaggedNode} instead when the node carries `Flag` bits such as {@link FlagExport}.
 *
 * @example
 * ```hx
 * addNode(p, NodeKind.Ident, token, 0, 0); // the index of the new node
 * ```
 *
 * @since 1.0.0
 */

export function addNode(p: *Parser, kind: NodeKind, token: u32, a: u32, b: u32): u32 {
    return addFlaggedNode(p, kind, 0, token, a, b);
}

/**
 * Sets the operator field of a node.
 *
 * @param p - The parser state
 * @param id - The index of the node
 * @param op - The operator, or the mode of a test or a hook
 *
 * @remarks
 * Call it right after the node is added, since {@link addFlaggedNode} always stores an operator of 0.
 * It performs no bounds check, so the index must name a node that this run already added.
 *
 * @example
 * ```hx
 * setOp(p, binary, BinOp.Add as u16);
 * ```
 *
 * @since 1.0.0
 */

export function setOp(p: *Parser, id: u32, op: u16): void {
    unsafe {
        p.ast.nodes![id].op = op;
    }
}

/**
 * Appends an invalid node at the current token.
 *
 * @param p - The parser state
 * @returns The index of the new node
 *
 * @remarks
 * Later passes skip invalid nodes, which stand in for a construct that failed to parse.
 *
 * @example
 * ```hx
 * invalidNode(p); // the index of a new Invalid node
 * ```
 *
 * @since 1.0.0
 */

export function invalidNode(p: *Parser): u32 {
    return addNode(p, NodeKind.Invalid, p.pos, 0, 0);
}

/**
 * Returns the kind of a node that this run already added.
 *
 * @param p - The parser state
 * @param id - The index of the node
 * @returns The kind of the node
 *
 * @remarks
 * The parser uses it to look back at a node that it built earlier,
 * for example to check what an expression parsed into before it decides how to continue.
 * It performs no bounds check on the index.
 *
 * @example
 * ```hx
 * nodeKind(p, id); // NodeKind.FieldAccess for the node of a.b
 * ```
 *
 * @since 1.0.0
 */

export function nodeKind(p: *Parser, id: u32): NodeKind {
    unsafe {
        return p.ast.nodes![id].kind;
    }
}

/**
 * Makes room in the extra array for more words.
 *
 * @param p - The parser state
 * @param count - The number of words to make room for
 *
 * @remarks
 * It only grows the capacity and leaves the length alone,
 * so the caller still writes the words and advances the length itself.
 * It does nothing when the array already has room.
 *
 * @example
 * ```hx
 * reserveExtra(p, 8); // room for one HxFnData
 * ```
 *
 * @since 1.0.0
 */

export function reserveExtra(p: *Parser, count: u32): void {
    const ast = p.ast;
    if (ast.extraLen + count > ast.extraCap) {
        unsafe {
            hxVecGrowImpl(@ptrCast(*?u8[*], &ast.extra), &ast.extraCap, ast.extraLen + count, 4);
        }
    }
}

/**
 * Copies a record into the extra array.
 *
 * @typeParam T - The record type, one of the `Data` structs or {@link HxRange}
 * @param p - The parser state
 * @param data - The record, whose fields are all 32-bit
 * @returns The index of the first word of the record
 *
 * @remarks
 * The record is copied word by word, so every field of `T` must be 32 bits wide and the size a multiple of 4.
 * A record that breaks this rule loses its trailing bytes.
 *
 * @example
 * ```hx
 * addRecord<HxSliceData>(p, HxSliceData { start, end }); // the index of its first word
 * ```
 *
 * @since 1.0.0
 */

export function addRecord<T>(p: *Parser, data: T): u32 {
    const count = @truncate(u32, @sizeOf(T) / 4);
    reserveExtra(p, count);
    const index = p.ast.extraLen;
    unsafe {
        const words = @ptrCast(u32[*], &data);
        for (const i of 0..count) p.ast.extra![index + i] = words[i];
    }
    p.ast.extraLen += count;
    return index;
}

/**
 * Returns the top of the scratch stack, where a new list starts.
 *
 * @param p - The parser state
 * @returns The number of entries on the stack
 *
 * @remarks
 * Pass the value to {@link listFinish} once the children of the list are pushed.
 * It only reads the stack length and never allocates.
 *
 * @example
 * ```hx
 * const top = scratchTop(p); // where the new list starts
 * ```
 *
 * @since 1.0.0
 */

export function scratchTop(p: *Parser): u32 {
    return p.scratchLen;
}

/**
 * Pushes a child onto the scratch stack.
 *
 * @param p - The parser state
 * @param id - The index of the child node
 *
 * @remarks
 * The stack is allocated on the first push and grows by doubling.
 * The child stays on the stack until {@link listFinish} moves it into the extra array.
 *
 * @example
 * ```hx
 * scratchPush(p, argument); // one more child of the list being built
 * ```
 *
 * @since 1.0.0
 */

export function scratchPush(p: *Parser, id: u32): void {
    unsafe {
        if (p.scratchLen == p.scratchCap) {
            hxVecGrowImpl(@ptrCast(*?u8[*], &p.scratch), &p.scratchCap, p.scratchLen + 1, 4);
        }
        p.scratch![p.scratchLen] = id;
    }
    p.scratchLen += 1;
}

/**
 * Moves the children pushed since a mark into the extra array.
 *
 * @param p - The parser state
 * @param top - The mark that {@link scratchTop} returned when the list started
 * @returns The range of the children in the extra array
 *
 * @remarks
 * The stack drops back to the mark, so the enclosing list goes on where it left off.
 *
 * @example
 * ```hx
 * const args = listFinish(p, top); // { start, end } in the extra array
 * ```
 *
 * @since 1.0.0
 */

export function listFinish(p: *Parser, top: u32): HxRange {
    const count = p.scratchLen - top;
    const range = HxRange { start: p.ast.extraLen, end: p.ast.extraLen + count };
    reserveExtra(p, count);
    unsafe {
        for (const i of 0..count) p.ast.extra![range.start + i] = p.scratch![top + i];
    }
    p.ast.extraLen = range.end;
    p.scratchLen = top;
    return range;
}

/**
 * Stores a range as a record in the extra array.
 *
 * @param p - The parser state
 * @param range - The range to store
 * @returns The index of the record
 *
 * @remarks
 * Use it where a node slot must point at a list range, since a slot holds a single word and a range takes two.
 * It is {@link addRecord} specialized to {@link HxRange}.
 *
 * @example
 * ```hx
 * rangeRecord(p, args); // the index of the stored range
 * ```
 *
 * @since 1.0.0
 */

export function rangeRecord(p: *Parser, range: HxRange): u32 {
    return addRecord<HxRange>(p, range);
}

/**
 * Returns a function record with every range empty.
 *
 * @param abi - The ABI string token, or {@link NoToken}
 * @param firstNode - The index of the first node of the declaration
 * @returns The record
 *
 * @remarks
 * A declaration parser starts from this record and fills in each range as it parses that part.
 * A zero return type or body means that the part is absent, which is what a declaration without a body keeps.
 *
 * @example
 * ```hx
 * emptyFunctionData(NoToken, 0); // every range empty, no return type, no body
 * ```
 *
 * @since 1.0.0
 */

export function emptyFunctionData(abi: u32, firstNode: u32): HxFnData {
    return HxFnData {
        genericsStart: 0, genericsEnd: 0, paramsStart: 0, paramsEnd: 0, returnType: 0, body: 0, abiToken: abi,
        firstNode: firstNode,
    };
}
