/**
 * Imports
 */

import { free, strlen } from "std/c";
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
import { NoDiag, Sync } from "@modules/parser/constants/parser.constant";
import { advanceToken, tokenSource } from "@modules/parser/components/cursor.component";
import { expectName, expectFieldName, expectSemicolon } from "@modules/parser/components/report.component";
import { describeToken, errorAt, attachHint, attachHintf } from "@modules/parser/components/report.component";
import { expectGenericClose, expectMemberSeparator, enterNesting } from "@modules/parser/components/report.component";
import { leaveNesting, synchronize, recover, rejectMethodKeyword } from "@modules/parser/components/report.component";
import { errorToken, reportDisallowed, errorExpected, expectToken } from "@modules/parser/components/report.component";

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

/**
 * A NUL-terminated string as a slice.
 *
 * @param text - Pointer to the first byte of a NUL-terminated string
 * @returns A slice over the bytes before the terminator
 *
 * @remarks
 * The slice borrows the original bytes rather than copying them, so it lives only as long as they do.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

describe("describeToken") {
    test("should describe identifiers, keywords, punctuation, and the end of file") {
        let f: Fixture = undefined;
        const p = setup(&f, "x if )");
        defer release(&f);
        let buf: u8[64] = undefined;
        let used: usize = 0;

        expect(describeToken(p, 0, &buf, &used)).toBe("identifier `x`");
        expect(describeToken(p, 1, &buf, &used)).toBe("keyword `if`");
        expect(describeToken(p, 2, &buf, &used)).toBe("`)`");
        expect(describeToken(p, 3, &buf, &used)).toBe("end of file");
    }
}

describe("errorAt") {
    test("should report the first error and suppress the next until recovery") {
        let f: Fixture = undefined;
        const p = setup(&f, "a");
        defer release(&f);
        const first = errorAt(p, 0, 1, `first`);

        expect(first).toBe(0);
        expect(errorAt(p, 0, 1, `second`)).toBe(NoDiag);
        expect(f.diags.itemsLen).toBe(1);
    }
}

describe("attachHint") {
    test("should attach a hint, and drop one for a suppressed error") {
        let f: Fixture = undefined;
        const p = setup(&f, "a");
        defer release(&f);
        const diag = errorAt(p, 0, 1, `oops`);
        attachHint(p, diag, "the fix");
        attachHint(p, NoDiag, "ignored");

        unsafe {
            expect(cString(f.diags.items![0].hint!)).toBe("the fix");
        }
    }
}

describe("attachHintf") {
    test("should attach a formatted hint") {
        let f: Fixture = undefined;
        const p = setup(&f, "a");
        defer release(&f);
        const diag = errorAt(p, 0, 1, `oops`);
        const name = "beforeAll";
        attachHintf(p, diag, `write ${name}`);

        unsafe {
            expect(cString(f.diags.items![0].hint!)).toBe("write beforeAll");
        }
    }
}

describe("errorToken") {
    test("should report an error over a whole token") {
        let f: Fixture = undefined;
        const p = setup(&f, "count");
        defer release(&f);
        void errorToken(p, 0, "bad name");

        unsafe {
            expect(f.diags.items![0].len).toBe(5);
        }
    }
}

describe("reportDisallowed") {
    test("should report without entering panic mode") {
        let f: Fixture = undefined;
        const p = setup(&f, "function");
        defer release(&f);
        void reportDisallowed(p, 0, "not here");

        expect(p.panicking).toBeFalse();
        expect(f.diags.errorCount).toBe(1);
    }
}

describe("errorExpected") {
    test("should say what was expected and what was found") {
        expect(firstError(")", (p: *Parser): u32 => errorExpected(p, "a type"))).toBe("expected a type, found `)`");
    }
}

describe("expectToken") {
    test("should consume a token of the kind, or report it missing") {
        let f: Fixture = undefined;
        const p = setup(&f, "( ;");
        defer release(&f);

        expect(expectToken(p, TokenKind.Lparen)).toBe(0);
        expect(expectToken(p, TokenKind.Rparen)).toBe(0xFFFF_FFFF);
        unsafe {
            expect(cString(f.diags.items![0].message)).toBe("expected `)`, found `;`");
        }
    }
}

describe("expectName") {
    test("should point out a reserved keyword where a name was expected") {
        let f: Fixture = undefined;
        const p = setup(&f, "const");
        defer release(&f);
        void expectName(p, "a variable name");

        unsafe {
            expect(cString(f.diags.items![0].hint!)).toBe("`const` is a reserved keyword");
        }
    }
}

describe("expectFieldName") {
    test("should accept a keyword as a field name") {
        let f: Fixture = undefined;
        const p = setup(&f, "type");
        defer release(&f);

        expect(expectFieldName(p)).toBe(0);
    }
}

describe("expectSemicolon") {
    test("should report a missing semicolon right after the previous token") {
        let f: Fixture = undefined;
        const p = setup(&f, "a\nb");
        defer release(&f);
        void advanceToken(p);
        expectSemicolon(p, "the statement");

        unsafe {
            expect(f.diags.items![0].start).toBe(1);
            expect(cString(f.diags.items![0].message)).toBe("expected `;` after the statement, found identifier `b`");
        }
    }
}

describe("expectGenericClose") {
    test("should explain a >= right after type arguments") {
        expect(firstError(">= x", (p: *Parser): u32 => { expectGenericClose(p); return 0; }))
            .toBe("`>=` here is read as one operator");
    }
}

describe("expectMemberSeparator") {
    test("should accept a closing brace without a separator") {
        expect(firstError("}", (p: *Parser): u32 => { expectMemberSeparator(p); return 0; })).toBe("");
        expect(firstError("x", (p: *Parser): u32 => { expectMemberSeparator(p); return 0; }))
            .toBe("expected `,` after the member, found identifier `x`");
    }
}

describe("enterNesting") {
    test("should refuse to nest deeper than the limit") {
        let f: Fixture = undefined;
        const p = setup(&f, "a");
        defer release(&f);
        p.depth = 256;

        expect(enterNesting(p)).toBeFalse();
        expect(f.diags.errorCount).toBe(1);
    }
}

describe("leaveNesting") {
    test("should undo one level of nesting") {
        let f: Fixture = undefined;
        const p = setup(&f, "a");
        defer release(&f);
        void enterNesting(p);
        leaveNesting(p);

        expect(p.depth).toBe(0);
    }
}

describe("synchronize") {
    test("should skip past the next semicolon at the outer level") {
        let f: Fixture = undefined;
        const p = setup(&f, "a { b; } c; d");
        defer release(&f);
        synchronize(p, Sync.Statement);

        expect(tokenSource(p, p.pos)).toBe("d");
    }
}

describe("recover") {
    test("should leave panic mode and always move forward") {
        let f: Fixture = undefined;
        const p = setup(&f, "a b");
        defer release(&f);
        p.panicking = true;
        recover(p, Sync.Declaration, 0);

        expect(p.panicking).toBeFalse();
        expect(p.pos > 0).toBeTrue();
    }
}

describe("rejectMethodKeyword") {
    test("should report and skip a function keyword before a method") {
        let f: Fixture = undefined;
        const p = setup(&f, "function f");
        defer release(&f);
        rejectMethodKeyword(p);

        expect(p.pos).toBe(1);
        unsafe {
            expect(cString(f.diags.items![0].message)).toBe("methods are written without `function`");
        }
    }
}
