/**
 * Imports
 */

import { free } from "std/c";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxAstInit, hxAstFree } from "@models/ast.model";
import { hxDiagListFree } from "@models/diagnostic.model";
import { NoToken, NodeKind } from "@constants/ast.constant";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstPrint } from "@components/ast-printer.component";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { emptyFunctionData, addNode } from "@modules/parser/components/tree.component";
import { parseTypeSuffixes, parsePostfixType } from "@modules/parser/components/types.component";
import { parseParams, parseFunctionType, parseFieldDecl } from "@modules/parser/components/types.component";
import { parsePrefixType, parseType, parseGenericParams } from "@modules/parser/components/types.component";
import { parseStructType, parseGenericInstance, parsePrimaryType } from "@modules/parser/components/types.component";

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

describe("parseGenericParams") {
    test("should read type parameters with their constraints") {
        let f: Fixture = undefined;
        const p = setup(&f, "<T, U extends Ord>");
        defer release(&f);
        const range = parseGenericParams(p);

        expect(range.end - range.start).toBe(2);
    }

    test("should give an empty range without a list") {
        let f: Fixture = undefined;
        const p = setup(&f, "(a: i32)");
        defer release(&f);
        const range = parseGenericParams(p);

        expect(range.end).toBe(range.start);
    }
}

describe("parseParams") {
    test("should read the parameters and the variadic marker") {
        let f: Fixture = undefined;
        const p = setup(&f, "(fmt: u8[*], ...)");
        defer release(&f);
        let fn = emptyFunctionData(NoToken, 0);
        let flags: u8 = 0;
        parseParams(p, &fn, &flags);

        expect(fn.paramsEnd - fn.paramsStart).toBe(1);
        expect(flags).toBe(0x08);
    }

    test("should report a parameter without a type") {
        let f: Fixture = undefined;
        const p = setup(&f, "(a)");
        defer release(&f);
        let fn = emptyFunctionData(NoToken, 0);
        let flags: u8 = 0;
        parseParams(p, &fn, &flags);

        expect(f.diags.errorCount).toBe(1);
    }
}

describe("parseFunctionType") {
    test("should read a function type") {
        expect(run("(a: i32) => bool", parseFunctionType)).toBe("(fn-type (params (a i32)) bool)");
    }
}

describe("parseFieldDecl") {
    test("should read a field with a default") {
        expect(run("x: f32 = 0", parseFieldDecl)).toBe("(field x f32 0)");
    }
}

describe("parseStructType") {
    test("should read an anonymous struct type") {
        expect(run("struct { a: i32, b: i32 }", parseStructType)).toBe("(struct-type (field a i32) (field b i32))");
    }
}

describe("parseGenericInstance") {
    test("should read type arguments after a base") {
        let f: Fixture = undefined;
        const p = setup(&f, "List<u8>");
        defer release(&f);
        const base = addNode(p, NodeKind.Ident, 0, 0, 0);
        p.pos = 1;

        expect(printed(&f.ast, parseGenericInstance(p, base))).toBe("(generic-of List u8)");
    }
}

describe("parsePrimaryType") {
    test("should read a dotted type name") {
        expect(run("Allocator.Error", parsePrimaryType)).toBe("(. Allocator Error)");
    }

    test("should report brackets before the element type") {
        expect(firstError("[]u8", parsePrimaryType)).toBe("expected a type, found `[`");
    }
}

describe("parseTypeSuffixes") {
    test("should read array sizes in C order") {
        let f: Fixture = undefined;
        const p = setup(&f, "f32[3][4]");
        defer release(&f);
        const base = addNode(p, NodeKind.Ident, 0, 0, 0);
        p.pos = 1;

        expect(printed(&f.ast, parseTypeSuffixes(p, base))).toBe("(array (array f32 4) 3)");
    }
}

describe("parsePostfixType") {
    test("should read a slice and a many-item pointer") {
        expect(run("u8[]", parsePostfixType)).toBe("(slice u8)");
        expect(run("u8[*]", parsePostfixType)).toBe("(many-pointer u8)");
    }
}

describe("parsePrefixType") {
    test("should bind prefix operators looser than suffixes") {
        expect(run("?u8[]", parsePrefixType)).toBe("(optional (slice u8))");
        expect(run("readonly *User", parsePrefixType)).toBe("(readonly (pointer User))");
    }
}

describe("parseType") {
    test("should join error unions with |") {
        expect(run("*User | DbError", parseType)).toBe("(error-union (pointer User) DbError)");
    }
}
