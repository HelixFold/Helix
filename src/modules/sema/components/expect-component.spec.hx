/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { hxAstFree } from "@models/ast.model";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { HxSema, HxProgram, HxModule } from "@structs/sema.struct";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";

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

let out: Builder = undefined;
let outReady = false;

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
 * Lexes, parses, and checks a text as a one-module test build, in a state that must stay where it is.
 *
 * @param ch - The state to fill, which must not move until `release`
 * @param text - The source text to check
 *
 * @remarks
 * Describes a program whose only module is also its testing module,
 * so `test` blocks and `expect` calls resolve against the names that the text itself declares.
 *
 * @since 1.0.0
 */

function check(ch: *Checked, text: string): void {
    ch.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&ch.src, "test.hx", text.ptr, text.len);
    void hxLex(&ch.src, &ch.tokens, &ch.diags);
    void hxParse(&ch.src, &ch.tokens, &ch.ast, &ch.diags);
    let module = HxModule { root: ch.ast.root, name: null };
    const program = HxProgram {
        modules: &module, count: 1, importTargets: null, test: true, testingModule: 1, pointerBytes: 8,
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
 * Every error message that checking a text gives, one per line, or an empty string when it checks.
 *
 * @param text - The source text to check
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Copies the messages into one module-level builder and releases the check before it returns.
 * Every call clears that builder, so the returned text stays valid only until the next call.
 * Hints are left out.
 *
 * @since 1.0.0
 */

function errors(text: string): string {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
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


let snippet: Builder = undefined;
let snippetReady = false;

/**
 * A test build's module with the statements inside a `test` block.
 *
 * @param body - The statements to place inside the `test` block
 * @returns The module text, which stays valid until the next call
 *
 * @remarks
 * The text also declares the names that a test build looks up in std/testing, so the module stands in for it.
 * It adds a struct, an interface, and a struct with a `dyn` field for the statements to use as subjects.
 *
 * @since 1.0.0
 */

function source(body: string): string {
    if (!snippetReady) {
        snippet = Builder.init(cAllocator());
        snippetReady = true;
    }
    snippet.clear();
    snippet.append("error TestError { RequireFailed }\n") catch unreachable;
    snippet.append("function beginTest(): void {}\nfunction endTest(): usize { return 0; }\n") catch unreachable;
    snippet.append("struct Point { x: i32 }\ninterface Shape { area(this: *Self): i32; }\n") catch unreachable;
    snippet.append("struct Holder { s: dyn Shape }\n") catch unreachable;
    snippet.append(`test("t") { ${body} }\n`) catch unreachable;
    return snippet.text();
}

/**
 * Every error message that checking statements inside a `test` block gives.
 *
 * @param body - The statements to place inside the `test` block
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Wraps the statements with `source` and checks the module with `errors`, so the result shares the builder of `errors`.
 *
 * @since 1.0.0
 */

function inTest(body: string): string {
    return errors(source(body));
}

describe("hxsIsText") {
    test("should accept a string literal as text") {
        expect(inTest("expect(\"abc\").toStartWith(\"a\");")).toBe("");
    }

    test("should reject a subject that is not text") {
        expect(inTest("expect(5).toInclude(\"a\");"))
            .toInclude("`toInclude` needs a string, but this is `integer literal`");
    }
}

describe("hxsIdentityComparable") {
    test("should compare an optional number with toBe") {
        expect(inTest("const n: ?i32 = 1; expect(n).toBe(1);")).toBe("");
    }

    test("should reject a struct with toBe and point to toEqual") {
        let ch: Checked = undefined;
        check(&ch, source("const p = Point { x: 1 }; expect(p).toBe(p);"));
        defer release(&ch);

        expect(ch.diags.itemsLen).toBe(1);
        unsafe {
            expect(cString(ch.diags.items![0].message)).toBe("`toBe` compares with `==`, which `Point` doesn't have");
            expect(cString(ch.diags.items![0].hint!)).toBe("use `toEqual`, which compares field by field");
        }
    }
}

describe("hxsDeepComparable") {
    test("should compare a struct field by field with toEqual") {
        expect(inTest("const p = Point { x: 1 }; expect(p).toEqual(p);")).toBe("");
    }

    test("should reject a struct that holds a dyn value") {
        expect(inTest("const h: Holder = undefined; expect(h).toEqual(h);"))
            .toInclude("`toEqual` can't compare `Holder`");
    }
}

describe("hxsExpectParts") {
    test("should accept a .not before the matcher") {
        expect(inTest("expect(1).not.toBe(2);")).toBe("");
    }

    test("should leave a call without a matcher to the ordinary checks") {
        expect(inTest("expect(1);")).toInclude("unknown function `expect`");
    }
}

describe("hxsCheckExpect") {
    test("should report a matcher that does not exist") {
        expect(inTest("expect(1).toBeShiny();")).toInclude("`toBeShiny` isn't a matcher");
    }

    test("should report an expect that does not take exactly one value") {
        expect(inTest("expect(1, 2).toBe(1);")).toInclude("`expect` takes the one value to check");
    }

    test("should report the wrong number of arguments for a matcher") {
        expect(inTest("expect(1).toBe();")).toInclude("`toBe` takes one argument");
        expect(inTest("const n: ?i32 = 1; expect(n).toBeNull(1);")).toInclude("`toBeNull` takes no arguments");
        expect(inTest("expect(1.5).toBeCloseTo(1.4, 2, 3);"))
            .toInclude("`toBeCloseTo` takes a number and, optionally, the digits to compare");
    }

    test("should accept the digits of toBeCloseTo") {
        expect(inTest("expect(1.5).toBeCloseTo(1.4, 2);")).toBe("");
    }

    test("should report a subject that the matcher does not fit") {
        expect(inTest("expect(1).toBeNull();"))
            .toInclude("`toBeNull` needs an optional (`?T`), but this is `integer literal`");
        expect(inTest("expect(true).toBeGreaterThan(false);")).toInclude("`toBeGreaterThan` needs a number");
        expect(inTest("expect(1).toHaveLength(1);")).toInclude("`toHaveLength` needs a slice, array or string");
        expect(inTest("expect(1).toThrow();")).toInclude("`toThrow` needs a call that can fail (`T | Error`)");
    }

    test("should report toContain on items that == cannot compare") {
        expect(inTest("const p = Point { x: 1 }; const ps: Point[1] = [p]; expect(ps).toContain(p);"))
            .toInclude("`toContain` compares items with `==`, which `Point` doesn't have");
        expect(inTest("const p = Point { x: 1 }; const ps: Point[1] = [p]; expect(ps).toContainEqual(p);")).toBe("");
    }

    test("should convert each argument to the type of the subject") {
        expect(inTest("expect(1).toBe(true);")).toInclude("expected `i64`, found `bool`");
    }

    test("should compare a slice with an array literal") {
        expect(inTest("const xs: i32[] = undefined; expect(xs).toEqual([1, 2]);")).toBe("");
    }

    test("should take an error for toThrow") {
        expect(inTest("const f: i32 | Error = 1; expect(f).toThrow(5);"))
            .toInclude("`toThrow` takes an error, like `MyError.Case`, but this is `integer literal`");
        expect(inTest("const f: i32 | Error = 1; expect(f).toThrow(TestError.RequireFailed);")).toBe("");
    }

    test("should give require a result that can fail") {
        expect(inTest("require(1).toBe(1);")).toInclude("the error from `toBe` is not handled");
        expect(inTest("try require(1).toBe(1);")).toBe("");
    }

    test("should report a check inside comptime") {
        expect(inTest("comptime { expect(1).toBe(1); }"))
            .toInclude("`expect` checks run with the test, not while compiling");
    }
}
