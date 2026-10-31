/**
 * Imports
 */

import { strlen } from "std/c";
import { hxDiagListFree } from "@models/diagnostic.model";
import { tokenText, hxNodeKindName } from "@models/ast.model";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { NodeKind, BinOp, NoToken } from "@constants/ast.constant";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { HxAst, HxNode, HxRange, HxSliceData } from "@models/structs/ast-model.struct";
import { hxBinopSpelling, hxAstInit, hxAstFree, hxAstRecord, record, node, extraAt } from "@models/ast.model";

/**
 * Tests
 */

/**
 * A source and its tokens, which a tree borrows.
 *
 * @remarks
 * A tree stores token indexes and reads their text through the source,
 * so both must outlive any tree built over them.
 * The diagnostic list collects whatever the lexer reports and is released with the rest by `release`.
 *
 * @since 1.0.0
 */

struct Input {
    src: HxSource,
    tokens: HxTokens,
    diags: HxDiagList,
}

/**
 * A NUL-terminated string as a slice.
 *
 * @param text - Pointer to the first byte of a NUL-terminated string
 * @returns The bytes before the terminator, without copying them
 *
 * @remarks
 * Measures the string with `strlen`, so the slice borrows the original memory
 * and stays valid only as long as that memory does.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * Lexes a text so that a tree can be built over it.
 *
 * @param it - Input to fill with the source, the tokens, and the diagnostics
 * @param text - Source text to lex as the file `test.hx`
 *
 * @remarks
 * Starts from an empty diagnostic list and ignores the lexer's result,
 * so a test that needs lexing errors inspects `it.diags` itself.
 * Pair every call with `release`.
 *
 * @since 1.0.0
 */

function input(it: *Input, text: string): void {
    it.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&it.src, "test.hx", text.ptr, text.len);
    void hxLex(&it.src, &it.tokens, &it.diags);
}

/**
 * Releases a lexed input.
 *
 * @param it - Input that `input` filled
 *
 * @remarks
 * Frees the tokens, the diagnostics, and the source in that order.
 * It does not free a tree built over the input, which the test releases with `hxAstFree` first.
 *
 * @since 1.0.0
 */

function release(it: *Input): void {
    hxTokensFree(&it.tokens);
    hxDiagListFree(&it.diags);
    hxSourceFree(&it.src);
}

/**
 * Appends a node by hand and returns its index.
 *
 * @param ast - Tree to append to
 * @param n - Node to store at the end of the node array
 * @returns The index of the new node
 *
 * @remarks
 * Writes past the current length without growing the array,
 * so it relies on the capacity that `hxAstInit` already reserved.
 *
 * @since 1.0.0
 */

function addNode(ast: *HxAst, n: HxNode): u32 {
    unsafe {
        ast.nodes![ast.nodesLen] = n;
    }
    ast.nodesLen += 1;
    return ast.nodesLen - 1;
}

/**
 * Appends a word to the extra array by hand and returns its index.
 *
 * @param ast - Tree to append to
 * @param word - Value to store at the end of the extra array
 * @returns The index of the new word
 *
 * @remarks
 * Writes past the current length without growing the array,
 * so it relies on the capacity that `hxAstInit` already reserved.
 *
 * @since 1.0.0
 */

function addWord(ast: *HxAst, word: u32): u32 {
    unsafe {
        ast.extra![ast.extraLen] = word;
    }
    ast.extraLen += 1;
    return ast.extraLen - 1;
}

describe("hxNodeKindName") {
    test("should return the printed name of a kind") {
        expect(cString(hxNodeKindName(NodeKind.FieldAccess as u32))).toBe(".");
        expect(cString(hxNodeKindName(NodeKind.ForOf as u32))).toBe("for-of");
        expect(cString(hxNodeKindName(NodeKind.Hook as u32))).toBe("hook");
    }

    test("should return a question mark for a number that names no kind") {
        expect(cString(hxNodeKindName(500))).toBe("?");
    }
}

describe("hxBinopSpelling") {
    test("should return the source text of an operator") {
        expect(cString(hxBinopSpelling(BinOp.Coalesce as u32))).toBe("??");
        expect(cString(hxBinopSpelling(BinOp.MulSat as u32))).toBe("*|");
    }

    test("should spell the plain assignment as =") {
        expect(cString(hxBinopSpelling(BinOp.None as u32))).toBe("=");
    }

    test("should return a question mark for a number that names no operator") {
        expect(cString(hxBinopSpelling(500))).toBe("?");
    }
}

describe("hxAstInit") {
    test("should start with the reserved empty node only") {
        let it: Input = undefined;
        input(&it, "let a = 1;");
        defer release(&it);
        let ast: HxAst = undefined;
        hxAstInit(&ast, &it.src, &it.tokens);
        defer hxAstFree(&ast);

        expect(ast.nodesLen).toBe(1);
        expect(ast.extraLen).toBe(0);
        expect(ast.root).toBe(0);
        expect(node(&ast, 0).kind).toBe(NodeKind.None);
        expect(node(&ast, 0).token).toBe(NoToken);
    }

    test("should size the arrays from the token count") {
        let it: Input = undefined;
        input(&it, "let a = 1;");
        defer release(&it);
        let ast: HxAst = undefined;
        hxAstInit(&ast, &it.src, &it.tokens);
        defer hxAstFree(&ast);

        expect(ast.nodesCap >= it.tokens.len / 2 + 16).toBe(true);
        expect(ast.extraCap >= it.tokens.len / 4 + 16).toBe(true);
    }
}

describe("hxAstFree") {
    test("should leave the tree empty") {
        let it: Input = undefined;
        input(&it, "a");
        defer release(&it);
        let ast: HxAst = undefined;
        hxAstInit(&ast, &it.src, &it.tokens);
        hxAstFree(&ast);

        expect(ast.nodes).toBeNull();
        expect(ast.extra).toBeNull();
        expect(ast.nodesLen).toBe(0);
    }
}

describe("hxAstRecord") {
    test("should copy the words of a record into a buffer") {
        let it: Input = undefined;
        input(&it, "a");
        defer release(&it);
        let ast: HxAst = undefined;
        hxAstInit(&ast, &it.src, &it.tokens);
        defer hxAstFree(&ast);
        const at = addWord(&ast, 7);
        void addWord(&ast, 9);
        let data: HxSliceData = undefined;
        unsafe {
            hxAstRecord(&ast, at, @ptrCast(u8[*], &data), @sizeOf(HxSliceData));
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
        hxAstInit(&ast, &it.src, &it.tokens);
        defer hxAstFree(&ast);
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
        hxAstInit(&ast, &it.src, &it.tokens);
        defer hxAstFree(&ast);
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
        hxAstInit(&ast, &it.src, &it.tokens);
        defer hxAstFree(&ast);
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
        hxAstInit(&ast, &it.src, &it.tokens);
        defer hxAstFree(&ast);

        expect(tokenText(&ast, 0)).toBe("let");
        expect(tokenText(&ast, 1)).toBe("value");
        expect(tokenText(&ast, 5)).toBe("");
    }
}
