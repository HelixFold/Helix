/**
 * Imports
 */

import { strlen } from "std/c";
import { hx_diag_list_free } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { NodeKind, BinOp, NO_TOKEN } from "@constants/ast.constant";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { hx_lex, hx_tokens_free } from "@modules/lexer/lexer.module";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hx_source_from_string, hx_source_free } from "@models/source.model";
import { hx_ast_record, record, node, extraAt, tokenText } from "@models/ast.model";
import { HxAst, HxNode, HxRange, HxSliceData } from "@models/structs/ast-model.struct";
import { hx_node_kind_name, hx_binop_spelling, hx_ast_init, hx_ast_free } from "@models/ast.model";

/**
 * Tests
 */

/**
 * A source and its tokens, which a tree borrows.
 */

struct Input {
    src: HxSource,
    tokens: HxTokens,
    diags: HxDiagList,
}

/**
 * A NUL-terminated string as a slice.
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * Lexes a text so that a tree can be built over it.
 */

function input(it: *Input, text: string): void {
    it.diags = HxDiagList { items: null, items_len: 0, items_cap: 0, arena: HxArena { head: null }, error_count: 0 };
    hx_source_from_string(&it.src, "test.hx", text.ptr, text.len);
    void hx_lex(&it.src, &it.tokens, &it.diags);
}

/**
 * Releases a lexed input.
 */

function release(it: *Input): void {
    hx_tokens_free(&it.tokens);
    hx_diag_list_free(&it.diags);
    hx_source_free(&it.src);
}

/**
 * Appends a node by hand and returns its index.
 */

function addNode(ast: *HxAst, n: HxNode): u32 {
    unsafe {
        ast.nodes![ast.nodes_len] = n;
    }
    ast.nodes_len += 1;
    return ast.nodes_len - 1;
}

/**
 * Appends a word to the extra array by hand and returns its index.
 */

function addWord(ast: *HxAst, word: u32): u32 {
    unsafe {
        ast.extra![ast.extra_len] = word;
    }
    ast.extra_len += 1;
    return ast.extra_len - 1;
}

describe("hx_node_kind_name") {
    test("should return the printed name of a kind") {
        expect(cString(hx_node_kind_name(NodeKind.FieldAccess as u32))).toBe(".");
        expect(cString(hx_node_kind_name(NodeKind.ForOf as u32))).toBe("for-of");
        expect(cString(hx_node_kind_name(NodeKind.Hook as u32))).toBe("hook");
    }

    test("should return a question mark for a number that names no kind") {
        expect(cString(hx_node_kind_name(500))).toBe("?");
    }
}

describe("hx_binop_spelling") {
    test("should return the source text of an operator") {
        expect(cString(hx_binop_spelling(BinOp.Coalesce as u32))).toBe("??");
        expect(cString(hx_binop_spelling(BinOp.MulSat as u32))).toBe("*|");
    }

    test("should spell the plain assignment as =") {
        expect(cString(hx_binop_spelling(BinOp.None as u32))).toBe("=");
    }

    test("should return a question mark for a number that names no operator") {
        expect(cString(hx_binop_spelling(500))).toBe("?");
    }
}

describe("hx_ast_init") {
    test("should start with the reserved empty node only") {
        let it: Input = undefined;
        input(&it, "let a = 1;");
        defer release(&it);
        let ast: HxAst = undefined;
        hx_ast_init(&ast, &it.src, &it.tokens);
        defer hx_ast_free(&ast);

        expect(ast.nodes_len).toBe(1);
        expect(ast.extra_len).toBe(0);
        expect(ast.root).toBe(0);
        expect(node(&ast, 0).kind).toBe(NodeKind.None);
        expect(node(&ast, 0).token).toBe(NO_TOKEN);
    }

    test("should size the arrays from the token count") {
        let it: Input = undefined;
        input(&it, "let a = 1;");
        defer release(&it);
        let ast: HxAst = undefined;
        hx_ast_init(&ast, &it.src, &it.tokens);
        defer hx_ast_free(&ast);

        expect(ast.nodes_cap >= it.tokens.len / 2 + 16).toBe(true);
        expect(ast.extra_cap >= it.tokens.len / 4 + 16).toBe(true);
    }
}

describe("hx_ast_free") {
    test("should leave the tree empty") {
        let it: Input = undefined;
        input(&it, "a");
        defer release(&it);
        let ast: HxAst = undefined;
        hx_ast_init(&ast, &it.src, &it.tokens);
        hx_ast_free(&ast);

        expect(ast.nodes).toBeNull();
        expect(ast.extra).toBeNull();
        expect(ast.nodes_len).toBe(0);
    }
}

describe("hx_ast_record") {
    test("should copy the words of a record into a buffer") {
        let it: Input = undefined;
        input(&it, "a");
        defer release(&it);
        let ast: HxAst = undefined;
        hx_ast_init(&ast, &it.src, &it.tokens);
        defer hx_ast_free(&ast);
        const at = addWord(&ast, 7);
        void addWord(&ast, 9);
        let data: HxSliceData = undefined;
        unsafe {
            hx_ast_record(&ast, at, @ptrCast(u8[*], &data), @sizeOf(HxSliceData));
        }

        expect(data.start).toBe(7);
        expect(data.end).toBe(9);
    }
}

describe("record") {
    test("should read a record of the given type") {
        let it: Input = undefined;
        input(&it, "a");
        defer release(&it);
        let ast: HxAst = undefined;
        hx_ast_init(&ast, &it.src, &it.tokens);
        defer hx_ast_free(&ast);
        void addWord(&ast, 1);
        const at = addWord(&ast, 3);
        void addWord(&ast, 5);
        const range = record<HxRange>(&ast, at);

        expect(range.start).toBe(3);
        expect(range.end).toBe(5);
    }
}

describe("node") {
    test("should return the node at an index") {
        let it: Input = undefined;
        input(&it, "a");
        defer release(&it);
        let ast: HxAst = undefined;
        hx_ast_init(&ast, &it.src, &it.tokens);
        defer hx_ast_free(&ast);
        const id = addNode(&ast, HxNode { kind: NodeKind.Ident, flags: 0, op: 0, token: 0, a: 0, b: 0 });

        expect(id).toBe(1);
        expect(node(&ast, id).kind).toBe(NodeKind.Ident);
    }
}

describe("extraAt") {
    test("should return the word at an index") {
        let it: Input = undefined;
        input(&it, "a");
        defer release(&it);
        let ast: HxAst = undefined;
        hx_ast_init(&ast, &it.src, &it.tokens);
        defer hx_ast_free(&ast);
        void addWord(&ast, 11);
        const at = addWord(&ast, 42);

        expect(extraAt(&ast, at)).toBe(42);
    }
}

describe("tokenText") {
    test("should return the source text of a token") {
        let it: Input = undefined;
        input(&it, "let  value = 1;");
        defer release(&it);
        let ast: HxAst = undefined;
        hx_ast_init(&ast, &it.src, &it.tokens);
        defer hx_ast_free(&ast);

        expect(tokenText(&ast, 0)).toBe("let");
        expect(tokenText(&ast, 1)).toBe("value");
        expect(tokenText(&ast, 5)).toBe("");
    }
}
