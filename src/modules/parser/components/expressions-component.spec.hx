/**
 * Imports
 */

import { free } from "std/c";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxAstInit, hxAstFree } from "@models/ast.model";
import { NodeKind, BinOp } from "@constants/ast.constant";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstPrint } from "@components/ast-printer.component";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { addNode } from "@modules/parser/components/tree.component";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { PrecAdd, PrecCoalesce, PrecShift } from "@modules/parser/constants/parser.constant";
import { binaryOperator, currentBinaryOperator } from "@modules/parser/components/expressions.component";
import { parsePostfix, parseUnary, parseBinary } from "@modules/parser/components/expressions.component";
import { parseCatch, parseExpr, parseIndexSuffix } from "@modules/parser/components/expressions.component";
import { parseArrowFunction, parsePrimary, parseCast } from "@modules/parser/components/expressions.component";
import { startsCaptureBody, parseCapture, isTypeLike } from "@modules/parser/components/expressions.component";
import { parseExprList, parseStructLiteral, parseTemplate } from "@modules/parser/components/expressions.component";

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

describe("isTypeLike") {
    test("should accept names and reject calls") {
        let f: Fixture = undefined;
        const p = setup(&f, "a");
        defer release(&f);

        expect(isTypeLike(p, addNode(p, NodeKind.Ident, 0, 0, 0))).toBeTrue();
        expect(isTypeLike(p, addNode(p, NodeKind.Call, 0, 0, 0))).toBeFalse();
    }
}

describe("parseExprList") {
    test("should read expressions up to the closing token, with a trailing comma") {
        let f: Fixture = undefined;
        const p = setup(&f, "a, b,)");
        defer release(&f);
        const list = parseExprList(p, TokenKind.Rparen);

        expect(list.end - list.start).toBe(2);
        expect(f.diags.errorCount).toBe(0);
    }
}

describe("parseStructLiteral") {
    test("should read named and shorthand fields") {
        expect(run("{ id: 1, name }", (p: *Parser): u32 => parseStructLiteral(p, 0))).toBe("(struct-literal _ (id 1) (name name))");
    }
}

describe("parseTemplate") {
    test("should read the text and the substitutions of a template") {
        expect(run("`id-${id}`", parseTemplate)).toBe("(template `id-${ id }`)");
    }
}

describe("parseArrowFunction") {
    test("should read an arrow function with an expression body") {
        expect(run("(x: i32): i32 => x * 2", parseArrowFunction)).toBe("(arrow (params (x i32)) i32 (* x 2))");
    }
}

describe("parsePrimary") {
    test("should read literals, arrays, and enum literals") {
        expect(run("[1, 2, 3]", parsePrimary)).toBe("(array-literal 1 2 3)");
        expect(run(".Admin", parsePrimary)).toBe(".Admin");
    }
}

describe("parseIndexSuffix") {
    test("should read an index and a slice") {
        expect(run("buf[0..n]", parsePostfix)).toBe("(slice-of buf 0 n)");
        expect(run("buf[2]", parsePostfix)).toBe("(index buf 2)");
    }

    test("should read an inclusive slice with an open start") {
        let f: Fixture = undefined;
        const p = setup(&f, "buf[..=n]");
        defer release(&f);
        const base = addNode(p, NodeKind.Ident, 0, 0, 0);
        p.pos = 1;

        expect(printed(&f.ast, parseIndexSuffix(p, base))).toBe("(slice-of= buf _ n)");
    }
}

describe("parsePostfix") {
    test("should chain calls, fields, and indexes") {
        expect(run("a.b(1)[2]", parsePostfix)).toBe("(index (call (. a b) 1) 2)");
        expect(run("email!", parsePostfix)).toBe("(unwrap email)");
    }
}

describe("parseUnary") {
    test("should read prefix operators") {
        expect(run("-a", parseUnary)).toBe("(neg a)");
        expect(run("void compute()", parseUnary)).toBe("(void (call compute))");
    }
}

describe("parseCast") {
    test("should bind as tighter than binary operators") {
        expect(run("b as u64", parseCast)).toBe("(as b u64)");
    }
}

describe("binaryOperator") {
    test("should describe a left-associative operator of one token") {
        const op = binaryOperator(PrecAdd, BinOp.Add);

        expect(op.prec).toBe(PrecAdd);
        expect(op.right).toBeFalse();
        expect(op.width).toBe(1);
    }
}

describe("currentBinaryOperator") {
    test("should join two touching > into a shift") {
        let f: Fixture = undefined;
        const p = setup(&f, ">> 2");
        defer release(&f);
        const op = currentBinaryOperator(p);

        expect(op.prec).toBe(PrecShift);
        expect(op.width).toBe(2);
    }

    test("should make ?? right-associative") {
        let f: Fixture = undefined;
        const p = setup(&f, "?? b");
        defer release(&f);

        expect(currentBinaryOperator(p).right).toBeTrue();
    }
}

describe("parseBinary") {
    test("should follow precedence") {
        expect(run("a + b * c", (p: *Parser): u32 => parseBinary(p, PrecCoalesce))).toBe("(+ a (* b c))");
    }

    test("should report a chained comparison") {
        expect(firstError("a < b < c", (p: *Parser): u32 => parseBinary(p, PrecCoalesce))).toBe("comparison operators cannot be chained");
    }
}

describe("startsCaptureBody") {
    test("should tell a capture body from an operator") {
        expect(startsCaptureBody(TokenKind.Lbrace)).toBeTrue();
        expect(startsCaptureBody(TokenKind.Plus)).toBeFalse();
    }
}

describe("parseCapture") {
    test("should read a capture only when a body follows") {
        let f: Fixture = undefined;
        const p = setup(&f, "(e) { }");
        defer release(&f);
        let g: Fixture = undefined;
        const q = setup(&g, "(e) + 1");
        defer release(&g);

        expect(parseCapture(p)).toBe(1);
        expect(parseCapture(q)).toBe(0xFFFF_FFFF);
    }
}

describe("parseCatch") {
    test("should read a fallback value") {
        expect(run("parse(s) catch 8080", parseCatch)).toBe("(catch (call parse s) _ 8080)");
    }
}

describe("parseExpr") {
    test("should nest ternaries to the right") {
        expect(run("x < lo ? lo : x > hi ? hi : x", parseExpr)).toBe("(? (< x lo) lo (? (> x hi) hi x))");
    }
}
