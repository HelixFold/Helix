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
import { Members } from "@modules/parser/constants/parser.constant";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { parseMember, parseContainer } from "@modules/parser/components/declarations.component";
import { parseFunctionRest, parseInterfaceMember } from "@modules/parser/components/declarations.component";
import { parseImport, parseVarDecl, parseFunction } from "@modules/parser/components/declarations.component";
import { parseDeclaration, parseErrorSet, parseTypeAlias } from "@modules/parser/components/declarations.component";

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

describe("parseVarDecl") {
    test("should read a typed constant") {
        expect(run("const MAX: usize = 1024;", (p: *Parser): u32 => parseVarDecl(p, 0))).toBe("(const MAX usize 1024)");
    }
}

describe("parseFunction") {
    test("should read a function from its keyword") {
        expect(run("function run() {}", (p: *Parser): u32 => parseFunction(p, 0, NoToken))).toBe("(function run (params) _ (block))");
    }
}

describe("parseFunctionRest") {
    test("should read a method written without the keyword") {
        expect(run("name(this: Color) {}", (p: *Parser): u32 => parseFunctionRest(p, 0, NoToken)))
            .toBe("(function name (params (this Color)) _ (block))");
    }

    test("should point out => after a function signature") {
        expect(firstError("f() => 1", (p: *Parser): u32 => parseFunctionRest(p, 0, NoToken)))
            .toBe("expected `{` to start the function body, found `=>`");
    }
}

describe("parseInterfaceMember") {
    test("should read a method signature") {
        expect(run("close(this: *Self);", parseInterfaceMember)).toBe("(function close (params (this (pointer Self))) _)");
    }
}

describe("parseMember") {
    test("should read an enum member with a value") {
        expect(run("Green = 2", (p: *Parser): u32 => parseMember(p, Members.Enum))).toBe("(member Green 2)");
    }

    test("should read a union variant with a payload") {
        expect(run("click: Point", (p: *Parser): u32 => parseMember(p, Members.Union))).toBe("(variant click Point)");
    }
}

describe("parseContainer") {
    test("should read an enum with a backing type") {
        expect(run("enum Color: u8 { Red = 1 }", (p: *Parser): u32 => parseContainer(p, NodeKind.Enum, Members.Enum, 0)))
            .toBe("(enum Color u8 (member Red 1))");
    }
}

describe("parseErrorSet") {
    test("should read the errors of a set") {
        expect(run("error DbError { NotFound, Timeout }", (p: *Parser): u32 => parseErrorSet(p, 0))).toBe("(error DbError NotFound Timeout)");
    }
}

describe("parseTypeAlias") {
    test("should read a type alias") {
        expect(run("type Bytes = u8[];", (p: *Parser): u32 => parseTypeAlias(p, 0))).toBe("(type Bytes (slice u8))");
    }
}

describe("parseImport") {
    test("should read named imports with aliases") {
        expect(run("import { a, b as c } from \"std\";", (p: *Parser): u32 => parseImport(p, false))).toBe("(import \"std\" (a) (b as c))");
    }

    test("should report a default import") {
        expect(firstError("import fs from \"std/fs\";", (p: *Parser): u32 => parseImport(p, false))).toBe("Helix has no default imports");
    }
}

describe("parseDeclaration") {
    test("should read an exported declaration") {
        expect(run("export const a = 1;", parseDeclaration)).toBe("(const :export a _ 1)");
    }

    test("should point a statement at the top level inside a function") {
        expect(firstError("print(1);", parseDeclaration)).toBe("expected a declaration, found identifier `print`");
    }
}
