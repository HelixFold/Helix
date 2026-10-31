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

describe("formatterType") {
    test("should give a template's formatter the values and the writer and return the error code") {
        const text = ir("export function f(x: i32): void { print(`${x}`); }");

        expect(text).toInclude("define internal i16 @helix.template.");
        expect(text).toInclude("(ptr %0, { ptr, ptr } %1)");
    }
}

describe("writeText") {
    test("should write literal text as a constant with its length") {
        const text = ir("export function f(x: i32): void { print(`x = ${x}`); }");

        expect(text).toInclude("@text = private unnamed_addr constant [5 x i8] c\"x = \\00\"");
        expect(text).toInclude("{ ptr @text, i64 4 }");
    }

    test("should write nothing for a template without literal text") {
        expect(ir("export function f(x: i32): void { print(`${x}`); }")).not.toInclude("@text =");
    }
}

describe("writeCstr") {
    test("should measure a many-pointer string with strlen before writing it") {
        expect(ir("export function f(z: u8[*]): void { print(`${z}`); }")).toInclude("call i64 @strlen(ptr");
    }
}

describe("emitFormat") {
    test("should widen a signed integer and format it with hx_format_i64") {
        const text = ir("export function f(x: i32): void { print(`${x}`); }");

        expect(text).toInclude("sext i32");
        expect(text).toInclude("call i64 @hx_format_i64(ptr %digits, i64");
    }

    test("should widen an unsigned integer and format it with hx_format_u64") {
        const text = ir("export function f(x: u32): void { print(`${x}`); }");

        expect(text).toInclude("zext i32");
        expect(text).toInclude("@hx_format_u64(");
    }

    test("should pick the text true or false for a boolean") {
        const text = ir("export function f(b: bool): void { print(`${b}`); }");

        expect(text).toInclude("select i1 %");
        expect(text).toInclude("ptr @true, ptr @false");
    }

    test("should format an f32 with hx_format_f32 and an f64 with hx_format_f64") {
        expect(ir("export function f(x: f32): void { print(`${x}`); }")).toInclude("@hx_format_f32(ptr %digits, float");
        expect(ir("export function f(x: f64): void { print(`${x}`); }")).toInclude("@hx_format_f64(ptr %digits, double");
    }

    test("should format a pointer with hx_format_ptr") {
        expect(ir("export function f(p: *i32): void { print(`${p}`); }")).toInclude("@hx_format_ptr(ptr %digits, ptr");
    }

    test("should hand a struct to one generated function that writes its fields by name") {
        const text = ir("struct P { x: i32 }\nexport function f(p: P, q: P): void { print(`${p} ${q}`); }");

        expect(text).toInclude("define internal i16 @helix.format.");
        expect(text).toInclude("c\"{ \\00\"");
        expect(text).toInclude("c\" }\\00\"");
    }

    test("should put a string inside a struct in quotes") {
        expect(ir("struct P { s: string }\nexport function f(p: P): void { print(`${p}`); }")).toInclude("c\"\\22\\00\"");
    }

    test("should write a string on its own without quotes") {
        expect(ir("export function f(s: string): void { print(`${s}`); }")).not.toInclude("c\"\\22\\00\"");
    }
}

describe("emitFormatValue") {
    test("should store the values of a template in a struct on the stack") {
        expect(ir("export function f(x: i32, b: bool): void { print(`${x}${b}`); }"))
            .toInclude("%template.values = alloca { i32, i1 }");
    }

    test("should pair the values with the formatter") {
        const text = ir("export function f(x: i32): void { print(`${x}`); }");

        expect(text).toInclude("insertvalue { ptr, ptr } undef, ptr %template.values, 0");
        expect(text).toInclude(", ptr @helix.template.");
    }

    test("should give a plain string passed as Format an empty values struct") {
        const text = ir("interface Writer { write(this: *Self, bytes: readonly u8[]): void | Error; }\nexport function f(w: dyn Writer, text: Format): void | Error { try text.writeTo(w); }\nexport function g(w: dyn Writer): void | Error { try f(w, \"plain\"); }");

        expect(text).toInclude("%template.values = alloca {}");
    }
}

describe("fdWriter") {
    test("should make one vtable whose write slot calls hx_write") {
        const text = ir("export function f(): void { print(\"a\"); print(\"b\"); }");

        expect(text).toInclude("@helix.fd.vtable = private constant [1 x ptr] [ptr @helix.fd.write]");
        expect(text).toInclude("call void @hx_write(i32");
        expect(text).not.toInclude("@helix.fd.vtable.1");
    }

    test("should carry the file descriptor in the data pointer") {
        expect(ir("export function f(): void { eprint(\"a\"); }"))
            .toInclude("{ ptr inttoptr (i64 2 to ptr), ptr @helix.fd.vtable }");
    }
}

describe("emitFormatWrite") {
    test("should call the formatter of a Format with its values and the writer") {
        const text = ir("interface Writer { write(this: *Self, bytes: readonly u8[]): void | Error; }\nexport function f(w: dyn Writer, text: Format): void | Error { try text.writeTo(w); }");

        expect(text).toInclude("%0 = extractvalue { ptr, ptr } %text3, 0");
        expect(text).toInclude("call i16 %1(ptr %0, { ptr, ptr } %w4)");
    }
}

describe("emitPrint") {
    test("should write print to stdout") {
        expect(ir("export function f(): void { print(\"a\"); }"))
            .toInclude("{ ptr inttoptr (i64 1 to ptr), ptr @helix.fd.vtable }");
    }

    test("should add a newline for println") {
        expect(ir("export function f(): void { println(\"a\"); }")).toInclude("c\"\\0A\\00\"");
    }

    test("should add no newline for print") {
        expect(ir("export function f(): void { print(\"a\"); }")).not.toInclude("c\"\\0A\\00\"");
    }
}
