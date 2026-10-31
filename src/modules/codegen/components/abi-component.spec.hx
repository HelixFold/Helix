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

describe("targetArch") {
    test("should classify by the triple the module targets") {
        const source = "struct One { x: f64 }\nextern \"C\" function one(o: One): One;\nexport function f(): f64 { return one(One { x: 1.0 }).x; }";

        expect(irFor(source, "aarch64-unknown-linux-gnu", false)).toInclude("declare [1 x double] @one([1 x double])");
        expect(irFor(source, "x86_64-unknown-linux-gnu", false)).toInclude("declare double @one(double)");
        expect(irFor(source, "x86_64-pc-windows-msvc", false)).toInclude("declare i64 @one(i64)");
    }
}

describe("needsCAbi") {
    test("should leave a C function of scalars with its Helix signature") {
        expect(ir("extern \"C\" function plain(a: i32): i32;\nexport function f(): i32 { return plain(1); }"))
            .toInclude("declare i32 @plain(i32)");
    }

    test("should keep aggregates on a target without C ABI rules") {
        expect(irFor("struct Pair { a: i32, b: i32 }\nextern \"C\" function make(a: i32, b: i32): Pair;\nexport function f(): i32 { return make(1, 2).a; }", "riscv64-unknown-linux-gnu", false))
            .toInclude("declare %test.Pair @make(i32, i32)");
    }
}

describe("emitCCall") {
    test("should pass a struct of up to 8 bytes as an i64 on aarch64") {
        expect(irFor("struct Pair { a: i32, b: i32 }\nextern \"C\" function make(a: i32, b: i32): Pair;\nexport function f(): i32 { return make(1, 2).a; }", "aarch64-unknown-linux-gnu", false))
            .toInclude("%call = call i64 @make(i32 1, i32 2)");
    }

    test("should pass a homogeneous float aggregate as an array of floats on aarch64") {
        expect(irFor("struct Vec2 { x: f32, y: f32 }\nextern \"C\" function scale(v: Vec2, k: f32): Vec2;\nexport function f(): f32 { return scale(Vec2 { x: 1.0, y: 2.0 }, 2.0).x; }", "aarch64-unknown-linux-gnu", false))
            .toInclude("call [2 x float] @scale([2 x float] %");
    }

    test("should pass a struct over 16 bytes by pointer and return it through sret on aarch64") {
        expect(irFor("struct Big { a: i64, b: i64, c: i64 }\nextern \"C\" function big(b: Big): Big;\nexport function f(): i64 { return big(Big { a: 1, b: 2, c: 3 }).c; }", "aarch64-unknown-linux-gnu", false))
            .toInclude("call void @big(ptr sret(%test.Big) %sret, ptr %arg)");
    }

    test("should split two floats into a <2 x float> eightbyte on x86-64 SysV") {
        expect(irFor("struct Vec2 { x: f32, y: f32 }\nextern \"C\" function scale(v: Vec2, k: f32): Vec2;\nexport function f(): f32 { return scale(Vec2 { x: 1.0, y: 2.0 }, 2.0).x; }", "x86_64-unknown-linux-gnu", false))
            .toInclude("call <2 x float> @scale(<2 x float> %");
    }

    test("should pass a struct over 16 bytes byval on x86-64 SysV") {
        expect(irFor("struct Big { a: i64, b: i64, c: i64 }\nextern \"C\" function big(b: Big): Big;\nexport function f(): i64 { return big(Big { a: 1, b: 2, c: 3 }).c; }", "x86_64-unknown-linux-gnu", false))
            .toInclude("call void @big(ptr sret(%test.Big) %sret, ptr byval(%test.Big) %arg)");
    }

    test("should pass an 8-byte struct as an i64 on Windows x64") {
        expect(irFor("struct Vec2 { x: f32, y: f32 }\nextern \"C\" function scale(v: Vec2, k: f32): Vec2;\nexport function f(): f32 { return scale(Vec2 { x: 1.0, y: 2.0 }, 2.0).x; }", "x86_64-pc-windows-msvc", false))
            .toInclude("call i64 @scale(i64 %");
    }

    test("should pass a struct of another size by pointer without byval on Windows x64") {
        expect(irFor("struct Big { a: i64, b: i64, c: i64 }\nextern \"C\" function big(b: Big): Big;\nexport function f(): i64 { return big(Big { a: 1, b: 2, c: 3 }).c; }", "x86_64-pc-windows-msvc", false))
            .toInclude("call void @big(ptr sret(%test.Big) %sret, ptr %arg)");
    }

    test("should pass a struct of one scalar as that scalar on wasm32") {
        expect(irFor("struct One { x: f64 }\nextern \"C\" function one(o: One): One;\nexport function f(): f64 { return one(One { x: 1.0 }).x; }", "wasm32-unknown-unknown", false))
            .toInclude("call double @one(double %");
    }

    test("should pass a struct of two scalars byval on wasm32") {
        expect(irFor("struct Pair { a: i32, b: i32 }\nextern \"C\" function take(p: Pair): i32;\nexport function f(): i32 { return take(Pair { a: 1, b: 2 }); }", "wasm32-unknown-unknown", false))
            .toInclude("call i32 @take(ptr byval(%test.Pair) %arg)");
    }
}

describe("declareCFunction") {
    test("should declare the C signature with its sret and byval attributes") {
        expect(irFor("struct Big { a: i64, b: i64, c: i64 }\nextern \"C\" function big(b: Big): Big;\nexport function f(): i64 { return big(Big { a: 1, b: 2, c: 3 }).c; }", "x86_64-unknown-linux-gnu", false))
            .toInclude("declare void @big(ptr sret(%test.Big), ptr byval(%test.Big))");
    }
}

describe("emitCWrapper") {
    test("should give an extern C function with a body a C entry point under its own name") {
        const text = irFor("struct Pair { a: i32, b: i32 }\nexport extern \"C\" function make(a: i32, b: i32): Pair { return Pair { a, b }; }", "aarch64-unknown-linux-gnu", false);

        expect(text).toInclude("define internal %test.Pair @make.helix(i32 %a, i32 %b)");
        expect(text).toInclude("define i64 @make(i32 %0, i32 %1)");
        expect(text).toInclude("call %test.Pair @make.helix(i32 %0, i32 %1)");
    }
}

describe("cCallable") {
    test("should pass a Helix callback whose signature needs the C ABI through an internal entry point") {
        const text = irFor("struct Pair { a: i32, b: i32 }\nfunction onPair(p: Pair): void { void p; }\nextern \"C\" function register(f: extern \"C\" (p: Pair) => void): void;\nexport function f(): void { register(onPair); }", "aarch64-unknown-linux-gnu", false);

        expect(text).toInclude("call void @register(ptr @test.onPair.c)");
        expect(text).toInclude("define internal void @test.onPair.c(i64 %0)");
    }

    test("should pass a callback that C and Helix call alike as itself") {
        expect(ir("function onInt(x: i32): void { void x; }\nextern \"C\" function register(f: extern \"C\" (x: i32) => void): void;\nexport function f(): void { register(onInt); }"))
            .toInclude("call void @register(ptr @test.onInt)");
    }

    test("should pass an extern C function with a body under its C name") {
        const text = irFor("struct Pair { a: i32, b: i32 }\nexport extern \"C\" function onPair(p: Pair): void { void p; }\nextern \"C\" function register(f: extern \"C\" (p: Pair) => void): void;\nexport function f(): void { register(onPair); }", "aarch64-unknown-linux-gnu", false);

        expect(text).toInclude("call void @register(ptr @onPair)");
        expect(text).not.toInclude("@onPair.helix.c");
    }
}
