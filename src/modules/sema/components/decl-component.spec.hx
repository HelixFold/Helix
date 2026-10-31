/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { NodeKind } from "@constants/ast.constant";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstInit, hxAstFree, node } from "@models/ast.model";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxSema, HxModule, HxProgram } from "@structs/sema.struct";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxParse, hxParseModule } from "@modules/parser/parser.module";
import { hxLex, hxLexAppend, hxTokensFree } from "@modules/lexer/lexer.module";
import { addText, files, hxSourceFromString, hxSourceFree } from "@models/source.model";

/**
 * Tests
 */

/**
 * A source with its tokens, tree, checker state, and diagnostics after one check.
 *
 * @remarks
 * The tree and the checker hold pointers into the other fields,
 * so a test declares the value once and passes its address to `check` and `release`.
 * Moving the value between those two calls leaves those pointers dangling.
 *
 * @since 1.0.0
 */

struct Checked {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
    sema: HxSema,
    diags: HxDiagList,
}

/**
 * A stand-in for std/testing with the symbols that a test build looks up.
 *
 * @since 1.0.0
 */

const Testing = "export error TestError { RequireFailed }\nexport let allocator: i32 = 0;\nexport function beginTest(): void {}\nexport function endTest(): usize { return 0; }\n";

/**
 * A stand-in for std/process with the `Init` that `main` may take and the `_startup` that builds it.
 *
 * @since 1.0.0
 */

const Process = "export struct Init { argc: i32 }\nexport function _startup(): Init { return Init { argc: 0 }; }\n";

let out: Builder = undefined;
let outReady = false;
let targets: u32[4096] = undefined;

/**
 * A NUL-terminated string as a slice.
 *
 * @param text - The NUL-terminated bytes to view
 * @returns The bytes before the terminating NUL
 *
 * @remarks
 * The slice points into the original buffer without a copy, so it lives only as long as that buffer.
 * Diagnostic messages are C strings, and this view lets the specs append them to a builder.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * Lexes, parses, and checks a text as a single-file program, in a state that must stay where it is.
 *
 * @param ch - The state to fill, which must not move until `release`
 * @param text - The source text to check
 *
 * @remarks
 * Passes no program to `hxSemaCheck`, so the checker sees the text as its only module.
 * The source copies the text, so the caller may reuse its buffer right away.
 *
 * @since 1.0.0
 */

function check(ch: *Checked, text: string): void {
    ch.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&ch.src, "test.hx", text.ptr, text.len);
    void hxLex(&ch.src, &ch.tokens, &ch.diags);
    void hxParse(&ch.src, &ch.tokens, &ch.ast, &ch.diags);
    void hxSemaCheck(&ch.sema, &ch.ast, null, &ch.diags);
}

/**
 * Checks a text as the root module of a two-module program, whose every import names the second module.
 *
 * @param ch - The state to fill, which must not move until `release`
 * @param text - The source text of the root module
 * @param path - The file path that the second module gets
 * @param lib - The source text of the second module
 * @param test - Whether to check a test build with the second module as its testing module
 *
 * @remarks
 * Lexes both files into one token stream and parses each as its own module of one tree.
 * Instead of resolving import paths, it points every `Import` node at module 2,
 * so the text may import the second module under any path.
 *
 * @since 1.0.0
 */

function checkProgram(ch: *Checked, text: string, path: readonly u8[*], lib: string, test: bool): void {
    ch.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&ch.src, "test.hx", text.ptr, text.len);
    void addText(&ch.src, path, lib);
    ch.tokens = HxTokens { kinds: null, starts: null, lens: null, len: 0, cap: 0, docs: null, docsLen: 0, docsCap: 0 };
    let second: u32 = 0;
    unsafe {
        void hxLexAppend(&ch.src, files(&ch.src)[0].start, files(&ch.src)[0].end, &ch.tokens, &ch.diags);
        second = ch.tokens.len;
        void hxLexAppend(&ch.src, files(&ch.src)[1].start, files(&ch.src)[1].end, &ch.tokens, &ch.diags);
    }
    hxAstInit(&ch.ast, &ch.src, &ch.tokens);
    let ok = true;
    let modules: HxModule[2] = undefined;
    modules[0] = HxModule { root: hxParseModule(&ch.ast, 0, &ch.diags, &ok), name: "test" };
    modules[1] = HxModule { root: hxParseModule(&ch.ast, second, &ch.diags, &ok), name: "lib" };
    for (const id of 0..ch.ast.nodesLen) {
        targets[id] = id > 0 && node(&ch.ast, id).kind == NodeKind.Import ? 2 : 0;
    }
    const program = HxProgram {
        modules: &modules[0], count: 2, importTargets: &targets, test, testingModule: test ? 2 : 0, pointerBytes: 8,
    };
    void hxSemaCheck(&ch.sema, &ch.ast, &program, &ch.diags);
}

/**
 * Releases everything that one check allocated.
 *
 * @param ch - The state that a check filled
 *
 * @remarks
 * Frees the checker state, tree, tokens, diagnostics, and source of the state.
 * The state holds no live tables afterward until the next check fills it again.
 *
 * @since 1.0.0
 */

function release(ch: *Checked): void {
    hxSemaFree(&ch.sema);
    hxAstFree(&ch.ast);
    hxTokensFree(&ch.tokens);
    hxDiagListFree(&ch.diags);
    hxSourceFree(&ch.src);
}

/**
 * Every error message of a check, one per line, or an empty string when it checks.
 *
 * @param ch - The state that a check filled
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Copies the messages into one module-level builder, so the result outlives `release` of the state.
 * Every call clears that builder, so the returned text stays valid only until the next call.
 *
 * @since 1.0.0
 */

function collect(ch: *Checked): string {
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    for (const i of 0..ch.diags.itemsLen) {
        unsafe {
            out.append(`${cString(ch.diags.items![i].message)}\n`) catch unreachable;
        }
    }
    return out.text();
}

/**
 * Every error message that checking a text as a single-file program gives.
 *
 * @param text - The source text to check
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Runs `check`, collects the messages, and releases the state before it returns.
 * The result shares the builder of `collect`, so it stays valid only until the next call.
 *
 * @since 1.0.0
 */

function errors(text: string): string {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    return collect(&ch);
}

/**
 * Every error message that checking a text in a test build gives, next to a std/testing made from `lib`.
 *
 * @param text - The source text of the root module
 * @param lib - The source text that stands in for std/testing
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Places the second module at `lib/std/testing.hx` and marks it as the testing module,
 * so `test` blocks and `expect` calls in the text resolve against the names it declares.
 *
 * @since 1.0.0
 */

function testErrors(text: string, lib: string): string {
    let ch: Checked = undefined;
    checkProgram(&ch, text, "lib/std/testing.hx", lib, true);
    defer release(&ch);
    return collect(&ch);
}

/**
 * Every error message that checking a text gives next to a second module at `path`.
 *
 * @param text - The source text of the root module
 * @param path - The file path that the second module gets
 * @param lib - The source text of the second module
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Checks an ordinary build.
 * The path decides which std module the second module stands for, such as `lib/std/process.hx`.
 * The result shares the builder of `collect`, so it stays valid only until the next call.
 *
 * @since 1.0.0
 */

function programErrors(text: string, path: readonly u8[*], lib: string): string {
    let ch: Checked = undefined;
    checkProgram(&ch, text, path, lib, false);
    defer release(&ch);
    return collect(&ch);
}

describe("hxsResolveGlobal") {
    test("should report a global whose value refers back to itself") {
        expect(errors("const a: i32 = b;\nconst b: i32 = a;")).toInclude("`a` depends on itself\n");
    }

    test("should resolve a global used before its declaration") {
        expect(errors("function f(): i32 { return b; }\nconst b: i32 = 2;")).toBe("");
    }

    test("should refuse a generic type alias") {
        expect(errors("type T<X> = X;")).toInclude("generic type aliases are not supported yet in this alpha\n");
    }
}

describe("hxsComptimeArg") {
    test("should bind a comptime parameter to the value of each instance") {
        expect(errors("function f(comptime n: usize): u8[n] { void n; return undefined; }\nfunction g(): usize { return f(3).len; }"))
            .toBe("");
    }

    test("should use the bound value in the types of the instance") {
        expect(errors("function f(comptime n: usize): u8[n] { void n; return undefined; }\nfunction g(): void { const a: u8[4] = f(3); void a; }"))
            .toBe("expected `u8[4]`, found `u8[3]`\n");
    }
}

describe("hxsResolveSignature") {
    test("should report an unknown type in a signature") {
        expect(errors("function f(x: Nope): void { void x; }")).toBe("unknown type `Nope`\n");
    }
}

describe("hxsResolveSignatureInModule") {
    test("should refuse a void parameter") {
        expect(errors("function f(x: void): void {}")).toBe("a parameter can't be `void`\n");
    }

    test("should refuse a function without a body that is not extern") {
        expect(errors("function f(): i32;")).toBe("function `f` has no body\n");
    }

    test("should refuse a variadic function that is not extern") {
        expect(errors("function f(...): void {}")).toBe("only `extern \"C\"` functions can be variadic\n");
    }

    test("should refuse a calling convention other than C") {
        expect(errors("extern \"X\" function f(): void;")).toBe("only `extern \"C\"` is supported\n");
    }
}

describe("hxsCheckFunctionBody") {
    test("should report a body that can reach its end without returning") {
        expect(errors("function f(): i32 { }")).toBe("`f` can reach its end without returning a `i32`\n");
    }

    test("should report a noreturn function that can return") {
        expect(errors("function f(): noreturn { }")).toBe("`f` is declared `noreturn` but can return\n");
    }

    test("should accept a void function without a return") {
        expect(errors("function f(): void { }")).toBe("");
    }

    test("should name the instance where an error inside it comes from") {
        expect(errors("function f(comptime n: usize): u8[n] { const x: i32 = true; return undefined; }\nfunction g(): usize { return f(3).len; }"))
            .toInclude("while instantiating `f<3>` here\n");
    }
}

describe("hxsInitStartup") {
    test("should accept main taking the Init of std/process") {
        expect(programErrors("import { Init } from \"std/process\";\nexport function main(init: Init): void { void init; }", "lib/std/process.hx", Process))
            .toBe("");
    }

    test("should refuse an Init from a file other than std/process") {
        expect(programErrors("import { Init } from \"other/process\";\nexport function main(init: Init): void { void init; }", "lib/other/process.hx", Process))
            .toBe("`main` takes nothing, or `init: Init`\n");
    }

    test("should refuse an Init declared in the program itself") {
        expect(errors("struct Init { a: i32 }\nexport function main(init: Init): void { void init; }"))
            .toBe("`main` takes nothing, or `init: Init`\n");
    }
}

describe("hxsCheckEntry") {
    test("should accept a main that takes nothing and returns nothing") {
        expect(errors("export function main(): void {}")).toBe("");
    }

    test("should accept a main that returns an exit code or an error") {
        expect(errors("export function main(): i32 | Error { return 0; }")).toBe("");
    }

    test("should refuse a main that takes another parameter") {
        expect(errors("export function main(x: i32): void { void x; }")).toBe("`main` takes nothing, or `init: Init`\n");
    }

    test("should refuse a main with another result") {
        expect(errors("export function main(): bool { return true; }"))
            .toBe("`main` must return `void`, `u8` or `i32`, found `bool`\n");
    }
}

describe("hxsReach") {
    test("should skip an @compileError in a function that main does not reach") {
        expect(errors("function f(): void { @compileError(\"boom\"); }\nexport function main(): void {}")).toBe("");
    }

    test("should report an @compileError in a function that main calls") {
        expect(errors("function f(): void { @compileError(\"boom\"); }\nexport function main(): void { f(); }")).toBe("boom\n");
    }
}

describe("hxsReachFrom") {
    test("should reach a function used as a value") {
        expect(errors("function g(): void { @compileError(\"boom\"); }\nfunction f(): void { const h = g; h(); }\nexport function main(): void { f(); }"))
            .toBe("boom\n");
    }

    test("should reach a function that a global refers to") {
        expect(errors("function g(): void { @compileError(\"boom\"); }\nconst h = g;\nexport function main(): void {}"))
            .toBe("boom\n");
    }
}

describe("hxsReportPending") {
    test("should treat every function of a file without main as used") {
        expect(errors("function f(): void { @compileError(\"boom\"); }")).toBe("boom\n");
    }

    test("should report a reached @compileLog as an error") {
        expect(errors("function f(): void { @compileLog(\"x\"); }")).toBe("compile log: \"x\" = \"x\"\n");
    }

    test("should reach an extern C function with a body") {
        expect(errors("export extern \"C\" function f(): void { @compileError(\"boom\"); }\nexport function main(): void {}"))
            .toBe("boom\n");
    }
}

describe("hxsEnterTestCode") {
    test("should let a test body use try") {
        expect(testErrors("function fail(): void | Error { return; }\ntest(\"b\") { try fail(); }", Testing)).toBe("");
    }
}

describe("hxsCheckTestBlock") {
    test("should check the body of a test") {
        expect(testErrors("describe(\"a\") { test(\"b\") { const x: i32 = true; } }", Testing)).toBe("expected `i32`, found `bool`\n");
    }

    test("should check the body of a hook") {
        expect(testErrors("describe(\"a\") { beforeEach { const x: i32 = true; } }", Testing)).toBe("expected `i32`, found `bool`\n");
    }
}

describe("hxsCheckTestItem") {
    test("should make a fixture of a describe visible to its tests") {
        expect(testErrors("describe(\"a\") { const n: i32 = 1; test(\"b\") { const x: i32 = n; void x; } }", Testing)).toBe("");
    }

    test("should keep a fixture out of the tests of another describe") {
        expect(testErrors("describe(\"a\") { const n: i32 = 1; test(\"b\") { void n; } }\ndescribe(\"c\") { test(\"d\") { void n; } }", Testing))
            .toInclude("unknown name `n`\n");
    }
}

describe("hxsTestingSymbol") {
    test("should report the symbols that std/testing is missing") {
        expect(testErrors("test(\"b\") {}", "export function beginTest(): void {}"))
            .toBe("std/testing has no `endTest`; the standard library next to the compiler is broken\nstd/testing has no `TestError`; the standard library next to the compiler is broken\n");
    }
}

describe("hxsDeclareTesting") {
    test("should make testing visible without an import") {
        expect(testErrors("test(\"b\") { const x = testing.allocator; void x; }", Testing)).toBe("");
    }

    test("should leave a root module's own testing alone") {
        expect(testErrors("const testing: i32 = 1;\ntest(\"b\") { const x: i32 = testing; void x; }", Testing)).toBe("");
    }
}

describe("hxsCheckTests") {
    test("should skip the tests of a build that is not a test build") {
        expect(errors("describe(\"a\") { test(\"b\") { const x: i32 = true; } }")).toBe("");
    }

    test("should treat a top-level const as a global that tests can read") {
        expect(testErrors("test(\"b\") { const x: i32 = n; void x; }\nconst n: i32 = 1;", Testing)).toBe("");
    }
}

describe("hxsDeclareGlobal") {
    test("should refuse a built-in type name") {
        expect(errors("const i32 = 1;")).toBe("`i32` is a built-in type name\n");
    }

    test("should refuse a name that the module already declares") {
        expect(errors("const a = 1;\nconst a = 2;")).toBe("`a` is already declared\n");
    }

    test("should refuse a global that reuses a function's name") {
        expect(errors("function f(): void {}\nconst f = 1;")).toBe("`f` is already declared\n");
    }
}
