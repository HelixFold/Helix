/**
 * Imports
 */

import { free } from "std/c";
import { NodeKind } from "@constants/ast.constant";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxAstInit, hxAstFree } from "@models/ast.model";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstPrint } from "@components/ast-printer.component";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { startsStatement, startsDeclaration } from "@modules/parser/components/cursor.component";
import { atKind, tokenStart, tokenLength, tokenSource } from "@modules/parser/components/cursor.component";
import { advanceToken, acceptToken, canStartExpression } from "@modules/parser/components/cursor.component";
import { isFieldName, literalKind, looksLikeParameterList } from "@modules/parser/components/cursor.component";
import { looksLikeGenericArgs, kindAt, currentKind, peekKind } from "@modules/parser/components/cursor.component";
import { tokenIs, atTestItem, atHook, atMethod, adjacent, isName } from "@modules/parser/components/cursor.component";

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

describe("kindAt") {
    test("should return the kind of a token and the end of file past the last one") {
        let f: Fixture = undefined;
        const p = setup(&f, "const a = 1;");
        defer release(&f);

        expect(kindAt(p, 1)).toBe(TokenKind.Ident);
        expect(kindAt(p, 999)).toBe(TokenKind.Eof);
    }
}

describe("currentKind") {
    test("should return the kind of the token at the current position") {
        let f: Fixture = undefined;
        const p = setup(&f, "const a = 1;");
        defer release(&f);

        expect(currentKind(p)).toBe(TokenKind.KwConst);
    }
}

describe("peekKind") {
    test("should look ahead without moving") {
        let f: Fixture = undefined;
        const p = setup(&f, "const a = 1;");
        defer release(&f);

        expect(peekKind(p, 2)).toBe(TokenKind.Eq);
        expect(p.pos).toBe(0);
    }
}

describe("atKind") {
    test("should compare the current token with a kind") {
        let f: Fixture = undefined;
        const p = setup(&f, "const a = 1;");
        defer release(&f);

        expect(atKind(p, TokenKind.KwConst)).toBeTrue();
        expect(atKind(p, TokenKind.KwLet)).toBeFalse();
    }
}

describe("tokenStart") {
    test("should return the offset where a token starts") {
        let f: Fixture = undefined;
        const p = setup(&f, "const a = 1;");
        defer release(&f);

        expect(tokenStart(p, 1)).toBe(6);
    }
}

describe("tokenLength") {
    test("should return the length of a token") {
        let f: Fixture = undefined;
        const p = setup(&f, "const a = 1;");
        defer release(&f);

        expect(tokenLength(p, 0)).toBe(5);
    }
}

describe("tokenSource") {
    test("should return the text of a token") {
        let f: Fixture = undefined;
        const p = setup(&f, "const count = 1;");
        defer release(&f);

        expect(tokenSource(p, 1)).toBe("count");
    }
}

describe("advanceToken") {
    test("should consume the current token and return its index") {
        let f: Fixture = undefined;
        const p = setup(&f, "a b");
        defer release(&f);

        expect(advanceToken(p)).toBe(0);
        expect(p.pos).toBe(1);
    }

    test("should never move past the end of file") {
        let f: Fixture = undefined;
        const p = setup(&f, "");
        defer release(&f);
        void advanceToken(p);

        expect(p.pos).toBe(0);
    }
}

describe("acceptToken") {
    test("should consume only a token of the given kind") {
        let f: Fixture = undefined;
        const p = setup(&f, "const a");
        defer release(&f);

        expect(acceptToken(p, TokenKind.KwLet)).toBeFalse();
        expect(acceptToken(p, TokenKind.KwConst)).toBeTrue();
        expect(p.pos).toBe(1);
    }
}

describe("adjacent") {
    test("should tell touching tokens from separated ones") {
        let f: Fixture = undefined;
        const p = setup(&f, "a >> b > > c");
        defer release(&f);

        expect(adjacent(p, 1)).toBeTrue();
        expect(adjacent(p, 4)).toBeFalse();
    }
}

describe("isName") {
    test("should accept identifiers and contextual keywords only") {
        expect(isName(TokenKind.Ident)).toBeTrue();
        expect(isName(TokenKind.KwType)).toBeTrue();
        expect(isName(TokenKind.KwConst)).toBeFalse();
    }
}

describe("isFieldName") {
    test("should accept any keyword after a dot") {
        expect(isFieldName(TokenKind.KwConst)).toBeTrue();
        expect(isFieldName(TokenKind.Int)).toBeFalse();
    }
}

describe("literalKind") {
    test("should map literal tokens to their node kinds") {
        expect(literalKind(TokenKind.KwNull)).toBe(NodeKind.Null);
        expect(literalKind(TokenKind.Float)).toBe(NodeKind.Float);
        expect(literalKind(TokenKind.Ident)).toBe(NodeKind.None);
    }
}

describe("canStartExpression") {
    test("should accept tokens that open an expression") {
        expect(canStartExpression(TokenKind.Minus)).toBeTrue();
        expect(canStartExpression(TokenKind.KwSwitch)).toBeTrue();
        expect(canStartExpression(TokenKind.Semicolon)).toBeFalse();
    }
}

describe("startsStatement") {
    test("should accept statement keywords only") {
        expect(startsStatement(TokenKind.KwDefer)).toBeTrue();
        expect(startsStatement(TokenKind.Ident)).toBeFalse();
    }
}

describe("startsDeclaration") {
    test("should accept declaration keywords only") {
        expect(startsDeclaration(TokenKind.KwStruct)).toBeTrue();
        expect(startsDeclaration(TokenKind.KwReturn)).toBeFalse();
    }
}

describe("tokenIs") {
    test("should match an identifier by its text") {
        let f: Fixture = undefined;
        const p = setup(&f, "describe(1)");
        defer release(&f);

        expect(tokenIs(p, 0, "describe")).toBeTrue();
        expect(tokenIs(p, 0, "test")).toBeFalse();
        expect(tokenIs(p, 1, "(")).toBeFalse();
    }
}

describe("atTestItem") {
    test("should recognize tests and describe blocks with or without a modifier") {
        let f: Fixture = undefined;
        const p = setup(&f, "test.skip(\"a\") {}");
        defer release(&f);

        expect(atTestItem(p)).toBeTrue();
    }

    test("should leave a call of another name alone") {
        let f: Fixture = undefined;
        const p = setup(&f, "run(1)");
        defer release(&f);

        expect(atTestItem(p)).toBeFalse();
    }
}

describe("atHook") {
    test("should recognize a hook name followed by a block") {
        let f: Fixture = undefined;
        const p = setup(&f, "beforeEach { }");
        defer release(&f);

        expect(atHook(p)).toBeTrue();
    }
}

describe("atMethod") {
    test("should recognize a name followed by a parameter list") {
        let f: Fixture = undefined;
        const p = setup(&f, "rename(this: *User) {}");
        defer release(&f);

        expect(atMethod(p)).toBeTrue();
    }

    test("should leave a field alone") {
        let f: Fixture = undefined;
        const p = setup(&f, "name: string");
        defer release(&f);

        expect(atMethod(p)).toBeFalse();
    }
}

describe("looksLikeParameterList") {
    test("should tell a parameter list from a parenthesized value") {
        let f: Fixture = undefined;
        const p = setup(&f, "(a: i32) => a");
        defer release(&f);
        let g: Fixture = undefined;
        const q = setup(&g, "(a + b) * c");
        defer release(&g);

        expect(looksLikeParameterList(p)).toBeTrue();
        expect(looksLikeParameterList(q)).toBeFalse();
    }
}

describe("looksLikeGenericArgs") {
    test("should tell type arguments from a comparison") {
        let f: Fixture = undefined;
        const p = setup(&f, "<u8>.init(a)");
        defer release(&f);
        let g: Fixture = undefined;
        const q = setup(&g, "< b && c > d");
        defer release(&g);

        expect(looksLikeGenericArgs(p)).toBeTrue();
        expect(looksLikeGenericArgs(q)).toBeFalse();
    }
}
