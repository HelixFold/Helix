/**
 * Imports
 */

import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { strlen, free } from "std/c";
import { hxAstFree } from "@models/ast.model";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { hxCodegenIr } from "@modules/codegen/codegen.module";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { HxSema, HxProgram, HxModule } from "@structs/sema.struct";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { HxCodegenOptions } from "@modules/codegen/components/structs/base-component.struct";

/**
 * Tests
 */

let out: Builder = undefined;
let outReady = false;

/**
 * A NUL-terminated string as a slice.
 *
 * @param text - The NUL-terminated bytes to view
 * @returns A slice over the bytes before the terminator
 *
 * @remarks
 * The slice borrows the bytes, so it stays valid only while the caller keeps them alive.
 * It measures the length with `strlen` and copies nothing.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * The unoptimized LLVM IR of a single-file program for a target, or its errors when it does not compile.
 *
 * @param text - The Helix source of the program
 * @param triple - The target triple, or `null` for this machine
 * @param test - Whether to check and lower the program as a test build
 * @returns The module's IR, or one `error:` line per diagnostic
 *
 * @remarks
 * It runs the whole pipeline from lexing through codegen on a module named `test` with 8-byte pointers.
 * The result lives in one shared builder, so the next call overwrites it and a spec must read it first.
 *
 * @since 1.0.0
 */

function irFor(text: string, triple: ?readonly u8[*], test: bool): string {
    let src: HxSource = undefined;
    let tokens: HxTokens = undefined;
    let ast: HxAst = undefined;
    let sema: HxSema = undefined;
    let diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&src, "test.hx", text.ptr, text.len);
    void hxLex(&src, &tokens, &diags);
    void hxParse(&src, &tokens, &ast, &diags);
    let module = HxModule { root: ast.root, name: "test" };
    const program = HxProgram { modules: &module, count: 1, importTargets: null, test, testingModule: 1, pointerBytes: 8 };
    const checked = hxSemaCheck(&sema, &ast, &program, &diags);
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    if (!checked || diags.errorCount > 0) {
        for (const i of 0..diags.itemsLen) {
            unsafe {
                out.append(`error: ${cString(diags.items![i].message)}\n`) catch unreachable;
            }
        }
    } else {
        const options = HxCodegenOptions { mode: 0, module_name: "test", debugInfo: false, triple, cpu: null, freestanding: false };
        let error: ?u8[*] = null;
        if (const result = hxCodegenIr(&sema, &options, &error)) {
            out.append(`${cString(result)}`) catch unreachable;
            free(result);
        } else if (error != null) {
            out.append(`error: ${cString(error!)}`) catch unreachable;
            free(error);
        }
    }
    hxSemaFree(&sema);
    hxAstFree(&ast);
    hxTokensFree(&tokens);
    hxDiagListFree(&diags);
    hxSourceFree(&src);
    return out.text();
}

/**
 * The unoptimized LLVM IR of a single-file program for this machine.
 *
 * @param text - The Helix source of the program
 * @returns The module's IR, or one `error:` line per diagnostic
 *
 * @remarks
 * It forwards to `irFor` without a triple and outside a test build,
 * so the shared builder behind `irFor` holds the result.
 *
 * @since 1.0.0
 */

function ir(text: string): string {
    return irFor(text, null, false);
}

let snippet: Builder = undefined;
let snippetReady = false;

/**
 * The unoptimized LLVM IR of a test build whose one test holds a body, after the names that a test build needs.
 *
 * @param declarations - The top-level declarations placed before the test
 * @param body - The statements inside the single test
 * @returns The module's IR, or one `error:` line per diagnostic
 *
 * @remarks
 * It prepends the `TestError` error set and the `beginTest` and `endTest` hooks that a test build requires,
 * so a spec states only the code under test.
 * The source lives in a second shared builder, and the next call overwrites it.
 *
 * @since 1.0.0
 */

function testIr(declarations: string, body: string): string {
    if (!snippetReady) {
        snippet = Builder.init(cAllocator());
        snippetReady = true;
    }
    snippet.clear();
    snippet.append(`error TestError { RequireFailed }\nfunction beginTest(): void {}\nfunction endTest(): usize { return 0; }\n`)
        catch unreachable;
    snippet.append(`${declarations}\ntest("t") { ${body} }\n`) catch unreachable;
    return irFor(snippet.text(), null, true);
}

describe("emitExpect") {
    describe("the check it makes") {
        test("should compare a struct through one generated equality function") {
            const text = testIr("struct Point { x: i32, y: i32 }\nfunction p(): Point { return Point { x: 1, y: 2 }; }", "expect(p()).toEqual(Point { x: 1, y: 2 });");

            expect(text).toInclude("define internal i1 @helix.equal.");
            expect(text).toInclude("icmp eq i32 %");
        }

        test("should compare floats ordered") {
            expect(testIr("function half(): f64 { return 1.5; }", "expect(half()).toBe(1.5);"))
                .toInclude("fcmp oeq double %call, 1.500000e+00");
        }

        test("should compare a slice with an array literal as a slice") {
            const text = testIr("const xs: i32[3] = [1, 2, 3];", "const s: readonly i32[] = xs[0..3]; expect(s).toEqual([1, 2, 3]);");

            expect(text).toInclude("define internal i1 @helix.equal.");
            expect(text).toInclude("({ ptr, i64 } %0, { ptr, i64 } %1)");
        }

        test("should look for an item with a loop for toContain") {
            const text = testIr("const xs: i32[3] = [1, 2, 3];", "const s: readonly i32[] = xs[0..3]; expect(s).toContain(2);");

            expect(text).toInclude("%contains = phi i1 [ false, %contains.cond ], [ true, %contains.body ]");
        }

        test("should call hx_test_close_to with 2 digits unless the test gives others") {
            expect(testIr("function half(): f64 { return 1.5; }", "expect(half()).toBeCloseTo(1.0);"))
                .toInclude("call i1 @hx_test_close_to(double %call, double 1.000000e+00, i32 2)");
        }

        test("should call hx_test_text with the index of the text matcher") {
            const text = testIr("function s(): string { return \"abc\"; }", "expect(s()).toStartWith(\"a\"); expect(s()).toInclude(\"b\");");

            expect(text).toInclude("call i1 @hx_test_text(i32 0, ");
            expect(text).toInclude("call i1 @hx_test_text(i32 2, ");
        }

        test("should compare the error code for toThrow") {
            expect(testIr("error E { Bad }\nfunction bad(): i32 | Error { throw E.Bad; }", "expect(bad()).toThrow(E.Bad);"))
                .toInclude("icmp eq i16 %code, ");
        }
    }

    describe("the failure it reports") {
        test("should mark the test as failed and write the report to descriptor 3") {
            const text = testIr("function one(): i32 { return 1; }", "expect(one()).toBe(2);");

            expect(text).toInclude("call void @hx_test_fail()");
            expect(text).toInclude("ptr inttoptr (i64 3 to ptr)");
            expect(text).toInclude("define internal i16 @helix.expect.failed(");
        }

        test("should hold the source of the expression, what was expected, what was received, and where") {
            const text = testIr("function one(): i32 { return 1; }", "expect(one()).toBe(2);");

            expect(text).toInclude("c\"expect(one()).toBe(2)\\00\"");
            expect(text).toInclude("c\"Expected: \\00\"");
            expect(text).toInclude("c\"\\0AReceived: \\00\"");
            expect(text).toInclude("c\"\\0A\\0Aat test.hx:5:");
        }

        test("should write not before the expectation of a negated matcher") {
            expect(testIr("function one(): i32 { return 1; }", "expect(one()).not.toBe(1);")).toInclude("c\"not \\00\"");
        }

        test("should write the comparison of a comparing matcher") {
            expect(testIr("function one(): i32 { return 1; }", "expect(one()).toBeGreaterThan(2);")).toInclude("c\"> \\00\"");
        }

        test("should write the lengths for toHaveLength") {
            const text = testIr("const xs: i32[3] = [1, 2, 3];", "const s: readonly i32[] = xs[0..3]; expect(s).toHaveLength(3);");

            expect(text).toInclude("c\"Expected length: \\00\"");
            expect(text).toInclude("c\"\\0AReceived length: \\00\"");
        }

        test("should write the name of the type for a value that cannot be printed") {
            expect(testIr("struct Box { f: () => void }\nfunction g(): void {}", "const b = Box { f: g }; const c = Box { f: g }; expect(b).toEqual(c);"))
                .toInclude("c\"<Box>\\00\"");
        }

        test("should write an error union that failed as its error") {
            expect(testIr("error E { Bad }\nfunction bad(): i32 | Error { throw E.Bad; }", "expect(bad()).toThrow(E.Bad);"))
                .toInclude("c\"error \\00\"");
        }
    }

    describe("the value it returns") {
        test("should give require the code of RequireFailed when the check fails") {
            expect(testIr("function one(): i32 { return 1; }", "try require(one()).toBe(1);"))
                .toInclude("%require = phi i16 [ 0, %entry ], [ 1, %expect.failed ]");
        }

        test("should let expect go on without a code") {
            expect(testIr("function one(): i32 { return 1; }", "expect(one()).toBe(1);")).not.toInclude("%require");
        }
    }
}
