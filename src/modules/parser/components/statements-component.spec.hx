/**
 * Imports
 */

import { free } from "std/c";
import { BinOp, NoToken } from "@constants/ast.constant";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxAstInit, hxAstFree } from "@models/ast.model";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstPrint } from "@components/ast-printer.component";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { parseSimpleStatement } from "@modules/parser/components/statements.component";
import { parseStatement, parseConditionCapture, parseIf } from "@modules/parser/components/statements.component";
import { parseWhile, parseFor, parseBlock, assignOp, shrAssign } from "@modules/parser/components/statements.component";

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
 * A lexed source, its tree, its diagnostics, and a parser over them, which must stay where it is.
 *
 * @remarks
 * The parser holds pointers to the source, tokens, tree, and diagnostics stored in the same fixture,
 * so copying or moving a fixture leaves those pointers aimed at the old storage.
 * Each test declares one on the stack, passes its address to {@link setup}, and frees it with {@link release}.
 *
 * @since 1.0.0
 */

struct Fixture {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
    diags: HxDiagList,
    parser: Parser,
}

/**
 * Lexes a text and returns a parser positioned at its first token.
 *
 * @param f - Fixture that receives the source, tokens, tree, diagnostics, and parser
 * @param text - Source text that the parser reads, named `test.hx`
 * @returns The parser stored in the fixture, starting at token 0 with an empty scratch stack
 *
 * @remarks
 * The lexer result is ignored, so a text with lexical errors still yields a parser,
 * and its errors stay in the fixture's diagnostics.
 *
 * @since 1.0.0
 */

function setup(f: *Fixture, text: string): *Parser {
    f.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&f.src, "test.hx", text.ptr, text.len);
    void hxLex(&f.src, &f.tokens, &f.diags);
    hxAstInit(&f.ast, &f.src, &f.tokens);
    f.parser = Parser {
        src: &f.src, tokens: &f.tokens, ast: &f.ast, diags: &f.diags, pos: 0, depth: 0, panicking: false,
        scratch: null, scratchLen: 0, scratchCap: 0,
    };
    return &f.parser;
}

/**
 * Releases everything that a fixture allocated.
 *
 * @param f - Fixture that {@link setup} filled
 *
 * @remarks
 * It frees the parser's scratch stack first, then the tree, the tokens, the diagnostics, and the source.
 * The fixture itself stays where it is, so the caller only owns its storage.
 *
 * @since 1.0.0
 */

function release(f: *Fixture): void {
    unsafe {
        free(@ptrCast(?u8[*], f.parser.scratch));
    }
    hxAstFree(&f.ast);
    hxTokensFree(&f.tokens);
    hxDiagListFree(&f.diags);
    hxSourceFree(&f.src);
}

/**
 * A node as a one-line S-expression, without the newline.
 *
 * @param ast - Tree that holds the node
 * @param id - Index of the node to print
 * @returns The printed node, as a slice of the shared capture buffer
 *
 * @remarks
 * The printer writes into an in-memory stream, and the text is copied into a 2048-byte buffer shared by every call,
 * so a longer result is cut short and the next call overwrites the previous one.
 * The trailing newline that the printer writes is dropped.
 *
 * @since 1.0.0
 */

function printed(ast: readonly *HxAst, id: u32): string {
    const file = open_memstream(&streamBuffer, &streamSize);
    hxAstPrint(ast, id, file, false);
    void fclose(file);
    const n = streamSize - 1 < captured.len ? streamSize - 1 : captured.len;
    unsafe {
        for (const i of 0..n) captured[i] = streamBuffer![i];
    }
    free(streamBuffer);
    streamBuffer = null;
    return captured[0..n];
}

/**
 * The node that one parse function builds from a text, printed.
 *
 * @param text - Source text to parse
 * @param parse - Parse function that runs on the fresh parser and returns the node it built
 * @returns The printed node from {@link printed}
 *
 * @remarks
 * The fixture lives on the stack and is released before the call returns.
 * The result survives the release because it sits in the shared capture buffer, not in the tree.
 *
 * @since 1.0.0
 */

function run(text: string, parse: (p: *Parser) => u32): string {
    let f: Fixture = undefined;
    const p = setup(&f, text);
    defer release(&f);
    return printed(&f.ast, parse(p));
}

/**
 * The first error message that one parse function reports for a text, or an empty string.
 *
 * @param text - Source text to parse
 * @param parse - Parse function that runs on the fresh parser, whose result is ignored
 * @returns The message of the first diagnostic, or an empty string when the fixture has none
 *
 * @remarks
 * The message is copied into the shared capture buffer up to its NUL terminator or 2048 bytes,
 * so the next call to this function or to {@link printed} overwrites it.
 * Lexer errors count too, since they share the fixture's diagnostics with the parser.
 *
 * @since 1.0.0
 */

function firstError(text: string, parse: (p: *Parser) => u32): string {
    let f: Fixture = undefined;
    const p = setup(&f, text);
    defer release(&f);
    void parse(p);
    if (f.diags.itemsLen == 0) return "";
    let n: usize = 0;
    unsafe {
        const message = f.diags.items![0].message;
        while (message[n] != 0 && n < captured.len) {
            captured[n] = message[n];
            n += 1;
        }
    }
    return captured[0..n];
}

describe("parseBlock") {
    test("should read the statements of a block") {
        expect(run("{ a(); b(); }", parseBlock)).toBe("(block (call a) (call b))");
    }

    test("should report a block that is never closed") {
        expect(firstError("{ a();", parseBlock)).toBe("this `{` is never closed");
    }
}

describe("assignOp") {
    test("should return the operator of a compound assignment") {
        let f: Fixture = undefined;
        const p = setup(&f, "+=");
        defer release(&f);
        let width: u32 = 0;

        expect(assignOp(p, &width)!).toBe(BinOp.Add);
        expect(width).toBe(1);
    }

    test("should return null for a token that does not assign") {
        let f: Fixture = undefined;
        const p = setup(&f, "==");
        defer release(&f);
        let width: u32 = 0;

        expect(assignOp(p, &width)).toBeNull();
    }
}

describe("shrAssign") {
    test("should join a > touching a >= into >>=") {
        let f: Fixture = undefined;
        const p = setup(&f, ">>= 1");
        defer release(&f);
        let width: u32 = 0;

        expect(shrAssign(p, &width)!).toBe(BinOp.Shr);
        expect(width).toBe(2);
    }
}

describe("parseSimpleStatement") {
    test("should read assignments and increments") {
        expect(run("x += 1;", (p: *Parser): u32 => parseSimpleStatement(p, true))).toBe("(+= x 1)");
        expect(run("i++", (p: *Parser): u32 => parseSimpleStatement(p, false))).toBe("(++ i)");
    }
}

describe("parseConditionCapture") {
    test("should read the name of a capture") {
        let f: Fixture = undefined;
        const p = setup(&f, "const v = find()");
        defer release(&f);

        expect(parseConditionCapture(p)).toBe(1);
    }
}

describe("parseIf") {
    test("should read an if with an else") {
        expect(run("if (x > 0) a(); else b();", parseIf)).toBe("(if (> x 0) (call a) (call b))");
    }
}

describe("parseWhile") {
    test("should read a while with a capture") {
        expect(run("while (const item = next()) {}", (p: *Parser): u32 => parseWhile(p, NoToken))).toBe("(while (const item (call next)) (block))");
    }
}

describe("parseFor") {
    test("should read a for-of loop over a range") {
        expect(run("for (const i of 0..=n) {}", (p: *Parser): u32 => parseFor(p, NoToken))).toBe("(for-of i (..= 0 n) (block))");
    }

    test("should report let in a for-of loop") {
        expect(firstError("for (let x of items) {}", (p: *Parser): u32 => parseFor(p, NoToken))).toBe("for-of items are always `const`");
    }
}

describe("parseStatement") {
    test("should read a labeled loop and a defer") {
        expect(run("outer: while (ok) { break outer; }", parseStatement)).toBe("(while :label outer ok (block (break outer)))");
        expect(run("defer close();", parseStatement)).toBe("(defer (call close))");
    }
}
