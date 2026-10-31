/**
 * Imports
 */

import { free } from "std/c";
import { hxAstFree } from "@models/ast.model";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstPrint } from "@components/ast-printer.component";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";

/**
 * The C library functions that capture the printed tree in memory.
 *
 * @since 1.0.0
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
 * The source, the tokens, the tree, and the diagnostics of one parse.
 *
 * @remarks
 * The tree points into the source and the tokens, so the four live together and {@link release} frees them together.
 *
 * @since 1.0.0
 */

struct Parsed {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
    diags: HxDiagList,
}

/**
 * Lexes and parses a text into a parse state.
 *
 * @param p - The state that receives the source, the tokens, the tree, and the diagnostics
 * @param text - The source text, which the source copies under the name `test.hx`
 *
 * @remarks
 * The tree points at the source and the tokens of the state, so the state must not move until {@link release}.
 * Diagnostics go into the state and do not stop the parse.
 *
 * @since 1.0.0
 */

function parse(p: *Parsed, text: string): void {
    p.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&p.src, "test.hx", text.ptr, text.len);
    void hxLex(&p.src, &p.tokens, &p.diags);
    void hxParse(&p.src, &p.tokens, &p.ast, &p.diags);
}

/**
 * Releases everything that one parse allocated.
 *
 * @param p - The state that {@link parse} filled
 *
 * @remarks
 * It frees the tree before the tokens and the source that the tree points into.
 *
 * @since 1.0.0
 */

function release(p: *Parsed): void {
    hxAstFree(&p.ast);
    hxTokensFree(&p.tokens);
    hxDiagListFree(&p.diags);
    hxSourceFree(&p.src);
}

/**
 * Returns the whole tree of a source as the printer writes it.
 *
 * @param text - The source text to parse
 * @param pretty - Whether to print in pretty mode with one node per indented line
 * @returns The printed tree, cut at 2048 bytes
 *
 * @remarks
 * It prints into an in-memory stream and copies the result into the shared `captured` buffer,
 * so the next call overwrites the text that this one returned.
 *
 * @since 1.0.0
 */

function printed(text: string, pretty: bool): string {
    let p: Parsed = undefined;
    parse(&p, text);
    defer release(&p);
    const file = open_memstream(&streamBuffer, &streamSize);
    hxAstPrint(&p.ast, p.ast.root, file, pretty);
    void fclose(file);
    const n = streamSize < captured.len ? streamSize : captured.len;
    unsafe {
        for (const i of 0..n) captured[i] = streamBuffer![i];
    }
    free(streamBuffer);
    streamBuffer = null;
    return captured[0..n];
}

describe("hxAstPrint") {
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
