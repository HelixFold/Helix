/**
 * Imports
 */

import { free } from "std/c";
import { hx_ast_free } from "@models/ast.model";
import { HxAst } from "@models/structs/ast-model.struct";
import { hx_parse } from "@modules/parser/parser.module";
import { hx_diag_list_free } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hx_ast_print } from "@components/ast-printer.component";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { hx_lex, hx_tokens_free } from "@modules/lexer/lexer.module";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hx_source_from_string, hx_source_free } from "@models/source.model";

/**
 * The C library functions that capture the printed tree in memory.
 */

extern "C" function open_memstream(buf: *?u8[*], len: *usize): ?u8[*];
extern "C" function fclose(file: ?u8[*]): i32;

/**
 * Tests
 */

let captured: u8[2048] = undefined;
let streamBuffer: ?u8[*] = null;
let streamSize: usize = 0;

/**
 * A source, its tokens, its tree, and its diagnostics after one parse.
 */

struct Parsed {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
    diags: HxDiagList,
}

/**
 * Lexes and parses a text into a state that must stay where it is, since the tree points at its source and tokens.
 */

function parse(p: *Parsed, text: string): void {
    p.diags = HxDiagList { items: null, items_len: 0, items_cap: 0, arena: HxArena { head: null }, error_count: 0 };
    hx_source_from_string(&p.src, "test.hx", text.ptr, text.len);
    void hx_lex(&p.src, &p.tokens, &p.diags);
    void hx_parse(&p.src, &p.tokens, &p.ast, &p.diags);
}

/**
 * Releases everything that one parse allocated.
 */

function release(p: *Parsed): void {
    hx_ast_free(&p.ast);
    hx_tokens_free(&p.tokens);
    hx_diag_list_free(&p.diags);
    hx_source_free(&p.src);
}

/**
 * The whole tree of a source as the printer writes it.
 */

function printed(text: string, pretty: bool): string {
    let p: Parsed = undefined;
    parse(&p, text);
    defer release(&p);
    const file = open_memstream(&streamBuffer, &streamSize);
    hx_ast_print(&p.ast, p.ast.root, file, pretty);
    void fclose(file);
    const n = streamSize < captured.len ? streamSize : captured.len;
    unsafe {
        for (const i of 0..n) captured[i] = streamBuffer![i];
    }
    free(streamBuffer);
    streamBuffer = null;
    return captured[0..n];
}

describe("hx_ast_print") {
    test("should write a whole tree on one line and end it with a newline") {
        expect(printed("const x = 1 + 2 * 3;", false)).toBe("(file (const x _ (+ 1 (* 2 3))))\n");
    }

    test("should put declarations and statements on their own indented lines in pretty mode") {
        expect(printed("const a = 1;\nfunction f() { g(); }", true))
            .toBe("(file\n  (const a _ 1)\n  (function f (params) _\n    (block\n      (call g))))\n");
    }

    test("should write an absent child as an underscore") {
        expect(printed("let a: i32;", false)).toBe("(file (let a i32 _))\n");
    }

    test("should mark exported and extern declarations") {
        expect(printed("export const a = 1;", false)).toBe("(file (const :export a _ 1))\n");
        expect(printed("extern \"C\" function f(): void;", false)).toBe("(file (function :extern \"C\" f (params) void))\n");
    }

    test("should write a compound assignment with its operator") {
        expect(printed("function f() { x <<= 1; y = 2; }", false))
            .toBe("(file (function f (params) _ (block (<<= x 1) (= y 2))))\n");
    }

    test("should write a namespace import and a plain import") {
        expect(printed("import * as fmt from \"std/fmt\";", false)).toBe("(file (import \"std/fmt\" * fmt))\n");
        expect(printed("import \"./c\";", false)).toBe("(file (import \"./c\"))\n");
    }

    test("should write tests with their modes, messages and timeouts") {
        expect(printed("test.skip(\"a\") {}", false)).toBe("(file (test :skip \"a\" (block)))\n");
        expect(printed("test.todo(\"b\");", false)).toBe("(file (test :todo \"b\"))\n");
        expect(printed("test.panics(\"c\", \"boom\") {}", false)).toBe("(file (test :panics \"c\" \"boom\" (block)))\n");
        expect(printed("test(\"d\", { timeout: 100 }) {}", false)).toBe("(file (test \"d\" :timeout 100 (block)))\n");
    }

    test("should write a describe block with its hooks and tests") {
        expect(printed("describe.only(\"s\") { beforeEach { reset(); } test(\"t\") {} }", false))
            .toBe("(file (describe :only \"s\" (beforeEach (block (call reset))) (test \"t\" (block))))\n");
    }

    test("should write a loop label and an errdefer capture") {
        expect(printed("function f() { outer: while (true) { break outer; } errdefer (e) log(e); }", false))
            .toBe("(file (function f (params) _ (block (while :label outer true (block (break outer))) (errdefer e (call log e)))))\n");
    }

    test("should write an invalid node as <error>") {
        expect(printed("const a = ;", false)).toBe("(file (const a _ <error>))\n");
    }
}
