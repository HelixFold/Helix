/**
 * Imports
 */

import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { strlen, free } from "std/c";
import { HxSema } from "@structs/sema.struct";
import { hxAstFree } from "@models/ast.model";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { exists, stat, deleteFile, Stat, Kind } from "std/fs";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { ModeReleaseSafe } from "@modules/codegen/constants/base.constant";
import { HxCodegenOptions } from "@modules/codegen/components/structs/base-component.struct";
import { ModeReleaseSmall, ModeDebug, ModeReleaseFast } from "@modules/codegen/constants/base.constant";
import { hxModeParse, hxModeName, hxCodegenObject, hxCodegenIr } from "@modules/codegen/codegen.module";

/**
 * Tests
 */

/**
 * A source with its tokens, tree, checker state, and diagnostics after one check.
 *
 * @remarks
 * The stages keep pointers into one another, so a spec declares it on the stack, fills it with `check`,
 * and frees it with `release` without moving it in between.
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
 * Lexes, parses, and checks a text as a single-file program, in a state that must stay where it is.
 *
 * @param ch - The uninitialized state that receives every stage
 * @param text - The Helix source of the program
 *
 * @remarks
 * It checks without a program, so the text forms one module for this machine.
 * It ignores the stage results and leaves the diagnostics in the state for the caller to inspect.
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
 * Releases everything that one check allocated.
 *
 * @param ch - The state that `check` filled
 *
 * @remarks
 * It frees the stages in reverse order of creation, from the checker state back to the source.
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
 * The options of a build for a mode and a target, where a `null` triple means this machine.
 *
 * @param mode - The build mode
 * @param triple - The target triple, or `null` for this machine
 * @returns The options for a module named `test`
 *
 * @remarks
 * Debug info, a CPU name, and a freestanding target stay off, so only the mode and the triple vary between specs.
 *
 * @since 1.0.0
 */

function options(mode: u32, triple: ?readonly u8[*]): HxCodegenOptions {
    return HxCodegenOptions { mode, module_name: "test", debugInfo: false, triple, cpu: null, freestanding: false };
}

/**
 * Empties the shared output and gives it back.
 *
 * @returns The cleared shared builder
 *
 * @remarks
 * It creates the builder on first use, and every later call clears the text of the previous one.
 *
 * @since 1.0.0
 */

function output(): *Builder {
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    return &out;
}

/**
 * The LLVM IR of a text built in a mode for a target, or `error: <message>` when the code generator fails.
 *
 * @param text - The Helix source of the program
 * @param mode - The build mode
 * @param triple - The target triple, or `null` for this machine
 * @returns The module's IR, or an `error:` line from the code generator
 *
 * @remarks
 * It does not report check diagnostics, so a spec passes it a text that checks cleanly.
 * The result lives in the shared output, and the next call overwrites it.
 *
 * @since 1.0.0
 */

function irFor(text: string, mode: u32, triple: ?readonly u8[*]): string {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    const buffer = output();
    const opts = options(mode, triple);
    let error: ?u8[*] = null;
    if (const result = hxCodegenIr(&ch.sema, &opts, &error)) {
        buffer.append(`${cString(result)}`) catch unreachable;
        free(result);
    } else if (error != null) {
        buffer.append(`error: ${cString(error!)}`) catch unreachable;
        free(error);
    }
    return buffer.text();
}

/**
 * The LLVM IR of a text built in debug mode for this machine.
 *
 * @param text - The Helix source of the program
 * @returns The module's IR, or an `error:` line from the code generator
 *
 * @remarks
 * It forwards to `irFor` with `ModeDebug` and no triple, so the result shares the same output.
 *
 * @since 1.0.0
 */

function ir(text: string): string {
    return irFor(text, ModeDebug, null);
}

describe("hxModeParse") {
    test("should read each mode name as its number") {
        let mode: u32 = 99;

        expect(hxModeParse("debug", &mode)).toBe(true);
        expect(mode).toBe(ModeDebug);
        expect(hxModeParse("release-safe", &mode)).toBe(true);
        expect(mode).toBe(ModeReleaseSafe);
        expect(hxModeParse("release-fast", &mode)).toBe(true);
        expect(mode).toBe(ModeReleaseFast);
        expect(hxModeParse("release-small", &mode)).toBe(true);
        expect(mode).toBe(ModeReleaseSmall);
    }

    test("should reject an unknown name and leave the mode alone") {
        let mode: u32 = 99;

        expect(hxModeParse("fast", &mode)).toBe(false);
        expect(mode).toBe(99);
    }
}

describe("hxModeName") {
    test("should name each mode") {
        expect(cString(hxModeName(ModeDebug))).toBe("debug");
        expect(cString(hxModeName(ModeReleaseSafe))).toBe("release-safe");
        expect(cString(hxModeName(ModeReleaseFast))).toBe("release-fast");
        expect(cString(hxModeName(ModeReleaseSmall))).toBe("release-small");
    }
}

describe("hxCodegenObject") {
    test("should write an object file for this machine") {
        const path = "/tmp/helix-codegen-module-spec.o";
        let ch: Checked = undefined;
        check(&ch, "export function add(a: i32, b: i32): i32 { return a + b; }");
        defer release(&ch);
        const opts = options(ModeDebug, null);
        let error: ?u8[*] = null;
        const ok = hxCodegenObject(&ch.sema, &opts, path.ptr, &error);
        const written = exists(path);
        const info = stat(path) catch Stat { size: 0, mtime: 0, kind: Kind.File, mode: 0 };
        deleteFile(path) catch {};

        expect(ok).toBe(true);
        expect(error == null).toBe(true);
        expect(written).toBe(true);
        expect(info.size).toBeGreaterThan(0);
    }

    test("should report a target that LLVM does not know") {
        let ch: Checked = undefined;
        check(&ch, "export function add(a: i32, b: i32): i32 { return a + b; }");
        defer release(&ch);
        const opts = options(ModeDebug, "nonsense-unknown-none");
        let error: ?u8[*] = null;
        const ok = hxCodegenObject(&ch.sema, &opts, "/tmp/helix-codegen-module-spec-bad.o", &error);
        const failed = error != null;
        if (error != null) free(error);

        expect(ok).toBe(false);
        expect(failed).toBe(true);
        expect(exists("/tmp/helix-codegen-module-spec-bad.o")).toBe(false);
    }
}

describe("hxCodegenIr") {
    describe("the names it gives symbols") {
        test("should prefix a top-level function with its module") {
            expect(ir("export function add(a: i32, b: i32): i32 { return a + b; }"))
                .toInclude("define i32 @test.add(i32 %a, i32 %b)");
        }

        test("should put the owner of a method between the module and the method") {
            expect(ir("struct User { id: i32, function rename(this: *User): void { this.id = 2; } }"))
                .toInclude("define void @test.User.rename(ptr %this)");
        }

        test("should add the type arguments of a generic instance") {
            const text = ir("function max<T>(a: T, b: T): T { return a > b ? a : b; }\nexport function f(): i32 { return max<i32>(1, 2); }");

            expect(text).toInclude("define i32 @\"test.max<i32>\"(i32 %a, i32 %b)");
        }

        test("should keep the C name of an extern function") {
            const text = ir("extern \"C\" function puts(s: readonly u8[*]): i32;\nexport function f(): void { void puts(\"hi\"); }");

            expect(text).toInclude("declare i32 @puts(ptr)");
        }
    }

    describe("the globals it emits") {
        test("should give a global internal storage that starts with its value") {
            expect(ir("let counter: i32 = 5;\nexport function f(): i32 { return counter; }"))
                .toInclude("@test.counter = internal global i32 5");
        }

        test("should start a global without a value at zero") {
            expect(ir("let counter: i32;\nexport function f(): i32 { counter = 1; return counter; }"))
                .toInclude("@test.counter = internal global i32 0");
        }
    }

    describe("the entry point") {
        test("should wrap a void main in a C main that returns 0") {
            const text = ir("export function main(): void {}");

            expect(text).toInclude("define i32 @main(i32 %0, ptr %1)");
            expect(text).toInclude("call void @test.main()");
            expect(text).toInclude("ret i32 0");
        }

        test("should print an error that reaches main and exit with 1") {
            const text = ir("export function main(): void | Error {}");

            expect(text).toInclude("c\"error: %s\\0A\\00\"");
            expect(text).toInclude("ret i32 1");
        }

        test("should name the wrapper __main_argc_argv on WebAssembly") {
            expect(irFor("export function main(): void {}", ModeDebug, "wasm32-unknown-wasi"))
                .toInclude("@__main_argc_argv(");
        }
    }

    describe("the mode it builds in") {
        test("should keep frame pointers and visible symbols in a debug build") {
            const text = ir("export function add(a: i32, b: i32): i32 { return a + b; }");

            expect(text).toInclude("define i32 @test.add(");
            expect(text).toInclude("\"frame-pointer\"=\"all\"");
        }

        test("should make a function internal and optimize it in a release build") {
            const text = irFor("export function add(a: i32, b: i32): i32 { return a + b; }", ModeReleaseFast, null);

            expect(text).not.toInclude("define i32 @test.add(");
            expect(text).not.toInclude("alloca");
        }

        test("should keep frame pointers in a release-safe build") {
            expect(irFor("export extern \"C\" function api(): i32 { return 1; }", ModeReleaseSafe, null))
                .toInclude("\"frame-pointer\"=\"all\"");
        }

        test("should leave frame pointers out of a release-fast build") {
            expect(irFor("export extern \"C\" function api(): i32 { return 1; }", ModeReleaseFast, null))
                .not.toInclude("\"frame-pointer\"=\"all\"");
        }
    }

    describe("the target it builds for") {
        test("should build for the triple of the options") {
            expect(irFor("export function f(): void {}", ModeDebug, "x86_64-unknown-linux-gnu"))
                .toInclude("target triple = \"x86_64-unknown-linux-gnu\"");
        }

        test("should report a target that LLVM does not know") {
            expect(irFor("export function f(): void {}", ModeDebug, "nonsense-unknown-none")).toStartWith("error: ");
        }
    }

    test("should mark a function that never returns noreturn") {
        const text = ir("extern \"C\" function abort(): noreturn;\nexport function stop(): noreturn { abort(); }");

        expect(text).toInclude("define void @test.stop() #0");
        expect(text).toInclude("attributes #0 = { noreturn nounwind");
    }
}
