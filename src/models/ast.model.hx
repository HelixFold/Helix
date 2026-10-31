/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";
import { HxAst, HxNode } from "@models/structs/ast-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hx_vec_grow_impl, free } from "@components/memory.component";
import { NodeKind, NODE_NAMES, BINOP_SPELLINGS, NO_TOKEN } from "@constants/ast.constant";

/**
 * Returns the printed name of a node kind.
 *
 * @param kind - The kind as a number
 * @returns The NUL-terminated name, or `?` for a number that names no kind
 *
 * @example
 * ```ts
 * hx_node_kind_name(NodeKind.FieldAccess as u32); // '.'
 * hx_node_kind_name(500);                         // '?'
 * ```
 *
 * @see NODE_NAMES
 * @since 1.0.0
 */

export extern "C" function hx_node_kind_name(kind: u32): readonly u8[*] {
    return kind < NODE_NAMES.len ? NODE_NAMES[kind].ptr : "?";
}

/**
 * Returns the source text of a binary operator.
 *
 * @param op - The operator as a number
 * @returns The NUL-terminated spelling, or `?` for a number that names no operator
 *
 * @example
 * ```ts
 * hx_binop_spelling(BinOp.AddSat as u32); // '+|'
 * hx_binop_spelling(BinOp.None as u32);   // '='
 * ```
 *
 * @see BINOP_SPELLINGS
 * @since 1.0.0
 */

export extern "C" function hx_binop_spelling(op: u32): readonly u8[*] {
    return op < BINOP_SPELLINGS.len ? BINOP_SPELLINGS[op].ptr : "?";
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
 * Release it with {@link hx_ast_free}.
 *
 * @example
 * ```ts
 * let ast: HxAst = undefined;
 * hx_ast_init(&ast, &src, &tokens);
 * ast.nodes_len; // 1
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_ast_init(ast: *HxAst, src: readonly *HxSource, tokens: readonly *HxTokens): void {
    *ast = HxAst { src, tokens, nodes: null, nodes_len: 0, nodes_cap: 0, extra: null, extra_len: 0, extra_cap: 0, root: 0 };
    unsafe {
        hx_vec_grow_impl(@ptrCast(*?u8[*], &ast.nodes), &ast.nodes_cap, tokens.len / 2 + 16, @sizeOf(HxNode));
        hx_vec_grow_impl(@ptrCast(*?u8[*], &ast.extra), &ast.extra_cap, tokens.len / 4 + 16, 4);
        ast.nodes![0] = HxNode { kind: NodeKind.None, flags: 0, op: 0, token: NO_TOKEN, a: 0, b: 0 };
    }
    ast.nodes_len = 1;
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
 * ```ts
 * hx_ast_free(&ast);
 * ast.nodes_len; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_ast_free(ast: *HxAst): void {
    unsafe {
        free(@ptrCast(?u8[*], ast.nodes));
        free(@ptrCast(?u8[*], ast.extra));
    }
    ast.nodes = null;
    ast.nodes_len = 0;
    ast.nodes_cap = 0;
    ast.extra = null;
    ast.extra_len = 0;
    ast.extra_cap = 0;
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
 * ```ts
 * let data: HxIfData = undefined;
 * hx_ast_record(&ast, n.a, @ptrCast(u8[*], &data), @sizeOf(HxIfData));
 * ```
 *
 * @see record
 * @since 1.0.0
 */

export extern "C" function hx_ast_record(ast: readonly *HxAst, index: u32, out: u8[*], size: usize): void {
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
 * ```ts
 * const n = node(&ast, id);                  // an If node
 * const data = record<HxIfData>(&ast, n.a);  // its condition and branches
 * ```
 *
 * @see hx_ast_record
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
 * @example
 * ```ts
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
 * @example
 * ```ts
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
 * @example
 * ```ts
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
