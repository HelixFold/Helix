/**
 * Imports
 */

import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { indexOf } from "std/text";
import { strlen, free } from "std/c";
import { HxSema } from "@structs/sema.struct";
import { hxAstFree } from "@models/ast.model";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { hxCodegenIr } from "@modules/codegen/codegen.module";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { HxCodegenOptions } from "@modules/codegen/components/structs/base-component.struct";

/**
 * Tests
 */

/**
 * The mode that keeps every safety check and runs no optimization pass.
 *
 * @since 1.0.0
 */

const Debug: u32 = 0;

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
 * The LLVM IR of a text checked as a single-file program, or its first error when it does not check.
 *
 * @param text - The Helix source of the program
 * @param mode - The build mode that sets the safety checks and the optimization level
 * @returns The module's IR, a `check error:` line, or a `codegen error:` line
 *
 * @remarks
 * It checks the text without a program, so it covers one module on this machine's target.
 * Only the first diagnostic shows, and the next call overwrites the shared builder behind the result.
 *
 * @since 1.0.0
 */

function ir(text: string, mode: u32): string {
    let src: HxSource = undefined;
    let tokens: HxTokens = undefined;
    let ast: HxAst = undefined;
    let sema: HxSema = undefined;
    let diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&src, "test.hx", text.ptr, text.len);
    void hxLex(&src, &tokens, &diags);
    void hxParse(&src, &tokens, &ast, &diags);
    void hxSemaCheck(&sema, &ast, null, &diags);
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    if (diags.errorCount != 0) {
        unsafe {
            out.append(`check error: ${cString(diags.items![0].message)}`) catch unreachable;
        }
    } else {
        const options = HxCodegenOptions {
            mode, module_name: "test", debugInfo: false, triple: null, cpu: null, freestanding: false,
        };
        let error: ?u8[*] = null;
        if (const result = hxCodegenIr(&sema, &options, &error)) {
            out.append(`${cString(result)}`) catch unreachable;
            free(result);
        } else if (error != null) {
            out.append(`codegen error: ${cString(error!)}`) catch unreachable;
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
 * The IR of the function `f` that a text exports, from its `define` line to its closing brace.
 *
 * @param text - The Helix source that exports `f`
 * @param mode - The build mode that sets the safety checks and the optimization level
 * @returns The definition of `@test.f`, or the whole output when it cannot find one
 *
 * @remarks
 * It cuts the slice out of the result of `ir`, so a spec matches against one function rather than the module.
 * When the text does not check or `f` is missing, the whole output comes back, and the error stays visible.
 *
 * @since 1.0.0
 */

function body(text: string, mode: u32): string {
    const all = ir(text, mode);
    const start = indexOf(all, "@test.f(") ?? return all;
    const rest = all[start..all.len];
    const end = indexOf(rest, "\n}\n") ?? return rest;
    return rest[0..end + 2];
}

describe("emitDefers") {
    test("should run a defer before the return that leaves its scope") {
        const text = body("extern \"C\" function done(): void;\nexport function f(): i32 { defer done(); return 1; }", Debug);

        expect(text).toInclude("call void @done()\n  ret i32 1");
    }

    test("should run the innermost defer first") {
        const text = body("extern \"C\" function a(): void;\nextern \"C\" function b(): void;\nexport function f(): void { defer a(); defer b(); }", Debug);

        expect(text).toInclude("call void @b()\n  call void @a()");
    }

    test("should leave out an errdefer when the function returns normally") {
        const text = body("error E { A }\nextern \"C\" function undo(): void;\nexport function f(): void | E { errdefer undo(); return; }", Debug);

        expect(text).not.toInclude("@undo");
    }

    test("should run an errdefer when the function throws") {
        const text = body("error E { A }\nextern \"C\" function undo(): void;\nexport function f(): void | E { errdefer undo(); throw E.A; }", Debug);

        expect(text).toInclude("call void @undo()\n  ret i16 1");
    }
}

describe("emitScoped") {
    test("should run the defers of a block at the end of the block") {
        const text = body("extern \"C\" function a(): void;\nextern \"C\" function b(): void;\nextern \"C\" function c(): void;\nexport function f(): void { { defer a(); b(); } c(); }", Debug);

        expect(text).toInclude("call void @b()\n  call void @a()\n  call void @c()");
    }

    test("should run the defers of an if branch inside that branch") {
        const text = body("extern \"C\" function a(): void;\nexport function f(ok: bool): void { if (ok) { defer a(); } }", Debug);

        expect(text).toInclude("if.then:");
        expect(text).toInclude("call void @a()\n  br label %if.end");
    }
}

describe("emitLocal") {
    test("should give a constant with a known value no storage") {
        const text = body("export function f(): i32 { const x: i32 = 5; return x; }", Debug);

        expect(text).not.toInclude("alloca");
        expect(text).toInclude("ret i32 5");
    }

    test("should store the initial value of a variable") {
        const text = body("export function f(n: i32): i32 { let x: i32 = n; x = x; return x; }", Debug);

        expect(text).toInclude("%x = alloca i32");
        expect(text).toInclude("store i32 %n2, ptr %x");
    }

    test("should fill an undefined local with 0xAA in a debug build") {
        const text = body("export function f(): u8 { let b: u8[4] = undefined; b[0] = 1; return b[0]; }", Debug);

        expect(text).toInclude("call void @llvm.memset.p0.i64(ptr align 1 %b, i8 -86, i64 4, i1 false)");
    }
}

describe("emitStmt") {
    test("should emit a while loop as condition, body, and end blocks") {
        const text = body("export function f(n: i32): i32 { let i: i32 = 0; while (i < n) i++; return i; }", Debug);

        expect(text).toInclude("br label %while.cond");
        expect(text).toInclude("br i1 %0, label %while.body, label %while.end");
    }

    test("should test an inclusive range for the last value before adding one") {
        const text = body("export function f(n: u8): u32 { let s: u32 = 0; for (const i of 0..=n) s += i; return s; }", Debug);

        expect(text).not.toInclude("range.cond");
        expect(text).toInclude("icmp eq i8 %7, %n2");
        expect(text).toInclude("br i1 %8, label %range.end, label %range.next");
    }

    test("should test an exclusive range before each pass") {
        const text = body("export function f(n: u8): u32 { let s: u32 = 0; for (const i of 0..n) s += i; return s; }", Debug);

        expect(text).toInclude("range.cond:");
        expect(text).toInclude("icmp ult i8");
    }

    test("should loop over the items of a slice with a counter and no bounds check") {
        const text = body("export function f(s: readonly u8[]): u32 { let t: u32 = 0; for (const c of s) t += c; return t; }", Debug);

        expect(text).toInclude("items.cond:");
        expect(text).not.toInclude("panic.bounds");
    }

    test("should return the success code from a bare return of an error union") {
        expect(body("error E { A }\nexport function f(): void | E { return; }", Debug)).toInclude("ret i16 0");
    }

    test("should emit only the branch that a known condition takes") {
        const text = body("extern \"C\" function a(): void;\nextern \"C\" function b(): void;\nexport function f(): void { if (comptime 1 > 2) a(); else b(); }", Debug);

        expect(text).toInclude("call void @b()");
        expect(text).not.toInclude("@a()");
        expect(text).not.toInclude("if.then");
    }

    test("should run the defers inside a loop when break leaves it") {
        const text = body("extern \"C\" function a(): void;\nexport function f(): void { while (true) { defer a(); break; } }", Debug);

        expect(text).toInclude("call void @a()\n  br label %while.end");
    }
}
