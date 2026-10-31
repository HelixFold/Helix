/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";
import { HxAst, HxNode } from "@models/structs/ast-model.struct";
import { hxVecGrowImpl, free } from "@components/memory.component";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { NodeKind, NodeNames, BinopSpellings, NoToken } from "@constants/ast.constant";

/**
 * Returns the printed name of a node kind.
 *
 * @param kind - The kind as a number
 * @returns The NUL-terminated name, or `?` for a number that names no kind
 *
 * @remarks
 * Indexes {@link NodeNames} directly and returns a pointer into that static table, so the caller never frees it.
 * The `?` fallback keeps a corrupt or future kind from reading past the end of that table.
 *
 * @example
 * ```hx
 * hxNodeKindName(NodeKind.FieldAccess as u32); // '.'
 * hxNodeKindName(500);                         // '?'
 * ```
 *
 * @see NodeNames
 * @since 1.0.0
 */

export extern "C" function hxNodeKindName(kind: u32): readonly u8[*] {
    return kind < NodeNames.len ? NodeNames[kind].ptr : "?";
}

/**
 * Returns the source text of a binary operator.
 *
 * @param op - The operator as a number
 * @returns The NUL-terminated spelling, or `?` for a number that names no operator
 *
 * @remarks
 * Indexes {@link BinopSpellings} directly, where `BinOp.None` spells the plain assignment `=`.
 * The `?` fallback keeps an out-of-range number from reading past the end of that table.
 *
 * @example
 * ```hx
 * hxBinopSpelling(BinOp.AddSat as u32); // '+|'
 * hxBinopSpelling(BinOp.None as u32);   // '='
 * ```
 *
 * @see BinopSpellings
 * @since 1.0.0
 */

export extern "C" function hxBinopSpelling(op: u32): readonly u8[*] {
    return op < BinopSpellings.len ? BinopSpellings[op].ptr : "?";
}

/**
 * Prepares an empty tree for the tokens of a source.
 *
 * @param ast - The tree to set up, whose previous contents are ignored
 * @param src - The source that the tokens point into
 * @param tokens - The tokens that the parser reads
 *
 * @remarks
 * The arrays are sized from the token count, about one node per two tokens and one extra word per four,
 * which avoids most regrowth while parsing.
 * The tree starts with the reserved empty node at index 0.
 * Release it with {@link hxAstFree}.
 *
 * @example
 * ```hx
 * let ast: HxAst = undefined;
 * hxAstInit(&ast, &src, &tokens);
 * ast.nodesLen; // 1
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxAstInit(ast: *HxAst, src: readonly *HxSource, tokens: readonly *HxTokens): void {
    *ast = HxAst { src, tokens, nodes: null, nodesLen: 0, nodesCap: 0, extra: null, extraLen: 0, extraCap: 0, root: 0 };
    unsafe {
        hxVecGrowImpl(@ptrCast(*?u8[*], &ast.nodes), &ast.nodesCap, tokens.len / 2 + 16, @sizeOf(HxNode));
        hxVecGrowImpl(@ptrCast(*?u8[*], &ast.extra), &ast.extraCap, tokens.len / 4 + 16, 4);
        ast.nodes![0] = HxNode { kind: NodeKind.None, flags: 0, op: 0, token: NoToken, a: 0, b: 0 };
    }
    ast.nodesLen = 1;
}

/**
 * Releases the node and extra arrays of a tree.
 *
 * @param ast - The tree to release
 *
 * @remarks
 * The source and the tokens stay alive, since the tree only borrows them.
 * The tree is left empty, so releasing it twice is harmless.
 *
 * @example
 * ```hx
 * hxAstFree(&ast);
 * ast.nodesLen; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxAstFree(ast: *HxAst): void {
    unsafe {
        free(@ptrCast(?u8[*], ast.nodes));
        free(@ptrCast(?u8[*], ast.extra));
    }
    ast.nodes = null;
    ast.nodesLen = 0;
    ast.nodesCap = 0;
    ast.extra = null;
    ast.extraLen = 0;
    ast.extraCap = 0;
}

/**
 * Copies a record out of the extra array into a buffer.
 *
 * @param ast - The tree that holds the record
 * @param index - The index of the first word of the record
 * @param out - The buffer that receives the record
 * @param size - The size of the record in bytes
 *
 * @remarks
 * It is the form of {@link record} that C code can call, since C has no generics.
 *
 * @example
 * ```hx
 * let data: HxIfData = undefined;
 * hxAstRecord(&ast, n.a, @ptrCast(u8[*], &data), @sizeOf(HxIfData));
 * ```
 *
 * @see record
 * @since 1.0.0
 */

export extern "C" function hxAstRecord(ast: readonly *HxAst, index: u32, out: u8[*], size: usize): void {
    unsafe {
        const from = @ptrCast(u8[*], &ast.extra![index]);
        for (const i of 0..size) out[i] = from[i];
    }
}

/**
 * Reads a record of a given type out of the extra array.
 *
 * @typeParam T - The record type, one of the `Data` structs or {@link HxRange}
 * @param ast - The tree that holds the record
 * @param index - The index of the first word of the record
 * @returns A copy of the record
 *
 * @remarks
 * The kind of a node decides which record its slot points at,
 * so the caller picks the type from the kind and the tree does not check it.
 *
 * @example
 * ```hx
 * const n = node(&ast, id);                  // an If node
 * const data = record<HxIfData>(&ast, n.a);  // its condition and branches
 * ```
 *
 * @see hxAstRecord
 * @since 1.0.0
 */

export function record<T>(ast: readonly *HxAst, index: u32): T {
    unsafe {
        return *@ptrCast(*T, &ast.extra![index]);
    }
}

/**
 * Returns a copy of a node.
 *
 * @param ast - The tree that holds the node
 * @param id - The index of the node, where 0 gives the reserved empty node
 * @returns The node
 *
 * @remarks
 * Returns the node by value, so the copy stays valid after the parser grows the node array.
 * It does not check the index against the length of the array.
 *
 * @example
 * ```hx
 * node(&ast, ast.root).kind; // NodeKind.File
 * node(&ast, 0).kind;        // NodeKind.None
 * ```
 *
 * @since 1.0.0
 */

export function node(ast: readonly *HxAst, id: u32): HxNode {
    unsafe {
        return ast.nodes![id];
    }
}

/**
 * Returns one word of the extra array.
 *
 * @param ast - The tree that holds the word
 * @param index - The index of the word
 * @returns The word, which is a node index inside a child list
 *
 * @remarks
 * Use it to walk a child list whose range a node or a record holds.
 * For a record that spans several words, read it whole with {@link record} instead.
 * It does not check the index against the length of the array.
 *
 * @example
 * ```hx
 * const file = node(&ast, ast.root);
 * for (const i of file.a..file.b) node(&ast, extraAt(&ast, i)); // each declaration
 * ```
 *
 * @see record
 * @since 1.0.0
 */

export function extraAt(ast: readonly *HxAst, index: u32): u32 {
    unsafe {
        return ast.extra![index];
    }
}

/**
 * Returns the source text of a token.
 *
 * @param ast - The tree whose tokens and source to read
 * @param token - The index of the token
 * @returns The text of the token, which is not copied
 *
 * @remarks
 * The slice points into the text of the source, so it stays valid until the source is released.
 * It covers exactly the bytes of the token, so a string token keeps its quotes.
 *
 * @example
 * ```hx
 * // function add(a: i32, b: i32): i32
 * tokenText(&ast, node(&ast, fn).token); // 'add'
 * ```
 *
 * @since 1.0.0
 */

export function tokenText(ast: readonly *HxAst, token: u32): string {
    unsafe {
        const start = ast.tokens.starts![token];
        return ast.src.text![start..start + ast.tokens.lens![token]];
    }
}
