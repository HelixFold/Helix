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

describe("signFunctionPointers") {
    test("should sign a function passed as a value with key IA and no discriminator") {
        expect(irFor("function onInt(x: i32): void { void x; }\nextern \"C\" function register(f: extern \"C\" (x: i32) => void): void;\nexport function f(): void { register(onInt); }", "arm64e-apple-macos", false))
            .toInclude("call void @register(ptr ptrauth (ptr @test.onInt, i32 0))");
    }

    test("should leave a direct call unsigned") {
        expect(irFor("function g(x: i32): void { void x; }\nexport function f(): void { g(2); }", "arm64e-apple-macos", false))
            .toInclude("call void @test.g(i32 2)");
    }

    test("should sign a function inside a constant, such as a vtable slot") {
        expect(irFor("export function f(x: i32): void { print(`${x}`); }", "arm64e-apple-macos", false))
            .toInclude("[1 x ptr] [ptr ptrauth (ptr @helix.fd.write, i32 0)]");
    }

    test("should put back the internal linkage of a signed function and leave no placeholder") {
        const text = irFor("export function f(x: i32): void { print(`${x}`); }", "arm64e-apple-macos", false);

        expect(text).toInclude("define internal i16 @helix.fd.write(");
        expect(text).not.toInclude("hx.ptrauth.");
    }

    test("should give every function the four pointer authentication attributes") {
        const text = irFor("export function f(): void {}", "arm64e-apple-macos", false);

        expect(text).toInclude("\"ptrauth-auth-traps\" \"ptrauth-calls\" \"ptrauth-indirect-gotos\" \"ptrauth-returns\"");
    }

    test("should add every attribute but ptrauth-calls to the module flags") {
        const text = irFor("export function f(): void {}", "arm64e-apple-macos", false);

        expect(text).toInclude("!{i32 7, !\"ptrauth-returns\", i32 1}");
        expect(text).toInclude("!{i32 7, !\"ptrauth-auth-traps\", i32 1}");
        expect(text).toInclude("!{i32 7, !\"ptrauth-indirect-gotos\", i32 1}");
        expect(text).not.toInclude("!\"ptrauth-calls\"");
    }

    test("should sign nothing for a target without pointer authentication") {
        expect(irFor("function onInt(x: i32): void { void x; }\nextern \"C\" function register(f: extern \"C\" (x: i32) => void): void;\nexport function f(): void { register(onInt); }", "arm64-apple-macos", false))
            .not.toInclude("ptrauth");
    }
}
