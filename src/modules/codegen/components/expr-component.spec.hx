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

/**
 * The mode that drops the safety checks and optimizes at O3.
 *
 * @since 1.0.0
 */

const ReleaseFast: u32 = 2;

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

describe("slotType") {
    test("should call a vtable slot with the data pointer as the receiver") {
        const text = body("interface Grow { grow(this: *Self, by: i32): i32; }\nstruct Sq { s: i32, grow(this: *Sq, by: i32): i32 { return by; } }\nexport function f(g: dyn Grow): i32 { return g.grow(2); }", Debug);

        expect(text).toInclude("%data = extractvalue { ptr, ptr } %g2, 0");
        expect(text).toInclude("%call = call i32 %method(ptr %data, i32 2)");
    }
}

describe("slotSignature") {
    test("should take the slot of a method from its position in the interface") {
        const text = body("interface Shape { area(this: readonly *Self): f64; grow(this: *Self, by: i32): i32; }\nstruct Sq { s: f64, area(this: readonly *Sq): f64 { return this.s; } grow(this: *Sq, by: i32): i32 { return by; } }\nexport function f(s: dyn Shape): i32 { return s.grow(2); }", Debug);

        expect(text).toInclude("getelementptr ptr, ptr %vtable, i64 1");
    }
}

describe("loadSlot") {
    test("should mark the load of a method as invariant") {
        const text = body("interface Grow { grow(this: *Self, by: i32): i32; }\nstruct Sq { s: i32, grow(this: *Sq, by: i32): i32 { return by; } }\nexport function f(g: dyn Grow): i32 { return g.grow(2); }", Debug);

        expect(text).toInclude("%method = load ptr, ptr %0, align 8, !invariant.load");
    }
}

describe("convert") {
    test("should pair a pointer with the vtable of its type for a dyn") {
        const text = ir("interface Grow { grow(this: *Self, by: i32): i32; }\nstruct Sq { s: i32, grow(this: *Sq, by: i32): i32 { return by; } }\nexport function f(x: *Sq): dyn Grow { return x; }", Debug);

        expect(text).toInclude("@test.vtable.Sq.Grow = private unnamed_addr constant [1 x ptr] [ptr @test.Sq.grow]");
        expect(text).toInclude("insertvalue { ptr, ptr } %0, ptr @test.vtable.Sq.Grow, 1");
    }

    test("should wrap a method that takes its receiver by value") {
        const text = ir("interface Area { area(this: readonly *Self): f64; }\nstruct Sq { s: f64, area(this: Sq): f64 { return this.s; } }\nexport function f(x: *Sq): dyn Area { return x; }", Debug);

        expect(text).toInclude("[1 x ptr] [ptr @test.Sq.area.thunk]");
        expect(text).toInclude("define internal double @test.Sq.area.thunk(ptr %0)");
    }

    test("should check that a narrowing integer cast fits") {
        const text = body("export function f(x: i32): u8 { return x as u8; }", Debug);

        expect(text).toInclude("icmp slt i32 %x2, 0");
        expect(text).toInclude("icmp sgt i32 %x2, 255");
        expect(text).toInclude("trunc i32 %x2 to i8");
    }

    test("should widen an integer that always fits without a check") {
        const text = body("export function f(x: u8): i32 { return x as i32; }", Debug);

        expect(text).toInclude("zext i8 %x2 to i32");
        expect(text).not.toInclude("panic");
    }

    test("should check that a float fits before converting it to an integer") {
        const text = body("export function f(y: f64): i64 { return y as i64; }", Debug);

        expect(text).toInclude("fcmp oge double");
        expect(text).toInclude("fcmp olt double");
        expect(text).toInclude("fptosi double");
    }

    test("should drop the range checks in a release-fast build") {
        expect(body("export function f(x: i32): u8 { return x as u8; }", ReleaseFast)).not.toInclude("panic");
    }

    test("should turn a pointer to an array into a slice of the whole array") {
        const text = body("export function f(b: *u8[4]): u8[] { return b; }", Debug);

        expect(text).toInclude("insertvalue { ptr, i64 } %0, i64 4, 1");
    }

    test("should mark a plain value as present in an optional") {
        expect(body("export function f(x: i32): ?i32 { return x; }", Debug)).toInclude("insertvalue { i32, i1 } %0, i1 true, 1");
    }
}

describe("emitArith") {
    test("should check an addition for overflow in a debug build") {
        expect(body("export function f(a: i32, b: i32): i32 { return a + b; }", Debug)).toInclude("@llvm.sadd.with.overflow.i32");
    }

    test("should use the unsigned intrinsic for an unsigned type") {
        expect(body("export function f(a: u32, b: u32): u32 { return a * b; }", Debug)).toInclude("@llvm.umul.with.overflow.i32");
    }

    test("should leave a wrapping addition unchecked") {
        const text = body("export function f(a: i32, b: i32): i32 { return a +% b; }", Debug);

        expect(text).toInclude("add i32 %a3, %b4");
        expect(text).not.toInclude("overflow");
    }

    test("should call the saturation intrinsic for a saturating addition") {
        expect(body("export function f(a: u8, b: u8): u8 { return a +| b; }", Debug)).toInclude("@llvm.uadd.sat.i8");
    }

    test("should check a signed division for a zero divisor and for overflow") {
        const text = ir("export function f(a: i32, b: i32): i32 { return a / b; }", Debug);

        expect(text).toInclude("division by zero");
        expect(text).toInclude("icmp eq i32 %a3, -2147483648");
        expect(text).toInclude("sdiv i32");
    }

    test("should check a shift amount against the bit width") {
        const text = ir("export function f(a: u32, n: u32): u32 { return a << n; }", Debug);

        expect(text).toInclude("shift amount is too large: it must be less than 32");
        expect(text).toInclude("shl i32");
    }

    test("should add floats without a check") {
        const text = body("export function f(a: f64, b: f64): f64 { return a + b; }", Debug);

        expect(text).toInclude("fadd double");
        expect(text).not.toInclude("panic");
    }
}

describe("emitCompare") {
    test("should compare signed integers with a signed predicate") {
        expect(body("export function f(a: i32, b: i32): bool { return a < b; }", Debug)).toInclude("icmp slt i32");
    }

    test("should compare unsigned integers with an unsigned predicate") {
        expect(body("export function f(a: u32, b: u32): bool { return a >= b; }", Debug)).toInclude("icmp uge i32");
    }

    test("should treat NaN as unequal to everything") {
        expect(body("export function f(a: f64, b: f64): bool { return a != b; }", Debug)).toInclude("fcmp une double");
    }
}

describe("emitIndexable") {
    test("should read the pointer and length of a slice") {
        const text = body("export function f(s: readonly u8[], i: usize): u8 { return s[i]; }", Debug);

        expect(text).toInclude("%ptr = extractvalue { ptr, i64 }");
        expect(text).toInclude("%len = extractvalue { ptr, i64 }");
        expect(text).toInclude("icmp uge i64 %i4, %len");
    }

    test("should give a pointer to an array a constant length") {
        expect(body("export function f(b: *u8[4], i: usize): u8 { return b[i]; }", Debug)).toInclude("icmp uge i64 %i4, 4");
    }
}

describe("elementAddress") {
    test("should reach an element of an array through the array type") {
        const text = body("export function f(b: *u8[4], i: usize): u8 { return b[i]; }", Debug);

        expect(text).toInclude("getelementptr inbounds [4 x i8], ptr %b3, i64 0, i64 %i4");
    }

    test("should skip the bounds check of a constant index into an array") {
        expect(body("export function f(b: *u8[4]): u8 { return b[2]; }", Debug)).not.toInclude("panic.bounds");
    }
}

describe("isPlace") {
    test("should read a field of a local in place") {
        const text = body("struct P { x: i32, y: i32 }\nexport function f(q: P): i32 { return q.y; }", Debug);

        expect(text).toInclude("getelementptr inbounds nuw %test.P, ptr %q1, i32 0, i32 1");
    }

    test("should copy a subject that is not a place before a switch") {
        const text = body("extern \"C\" function g(): i32;\nexport function f(): i32 { switch (g()) { case 1: return 1; default: return 2; } }", Debug);

        expect(text).toInclude("%subject = alloca i32");
    }

    test("should match a subject that is a place where it is") {
        const text = body("export function f(n: i32): i32 { switch (n) { case 1: return 1; default: return 2; } }", Debug);

        expect(text).not.toInclude("%subject");
    }
}

describe("fieldType") {
    test("should wrap a field of an optional struct as an optional of the field type") {
        const text = body("struct P { x: i32, y: i32 }\nexport function f(o: ?P): ?i32 { return o?.y; }", Debug);

        expect(text).toInclude("extractvalue %test.P %payload, 1");
        expect(text).toInclude("phi { i32, i1 } [ zeroinitializer, %entry ]");
    }
}

describe("emitAddress") {
    test("should store through a pointer to a field") {
        const text = body("struct P { x: i32, y: i32 }\nexport function f(p: *P): void { p.y = 7; }", Debug);

        expect(text).toInclude("%0 = getelementptr inbounds nuw %test.P, ptr %p2, i32 0, i32 1");
        expect(text).toInclude("store i32 7, ptr %0");
    }

    test("should store into an element of a slice after a bounds check") {
        const text = body("export function f(s: u8[]): void { s[0] = 1; }", Debug);

        expect(text).toInclude("panic.bounds");
        expect(text).toInclude("store i8 1");
    }
}

describe("errorName") {
    test("should look the name up in a table that starts with the success code") {
        const text = ir("error E { A }\nextern \"C\" function puts(s: readonly u8[*]): i32;\nexport function f(e: E): void { void puts(@errorName(e)); }", Debug);

        expect(text).toInclude("@error.none = private unnamed_addr constant [11 x i8] c\"(no error)\\00\"");
        expect(text).toInclude("@helix.error_names = private constant [2 x ptr]");
        expect(text).toInclude("getelementptr inbounds [2 x ptr], ptr @helix.error_names, i64 0, i64 %0");
    }
}

describe("emitErrorReturn") {
    test("should run the defers and return the error code") {
        const text = body("error E { A }\nextern \"C\" function done(): void;\nexport function f(): i32 | E { defer done(); throw E.A; }", Debug);

        expect(text).toInclude("call void @done()\n  ret { i32, i16 } { i32 undef, i16 1 }");
    }

    test("should return the error of a failed try") {
        const text = body("error E { A }\nextern \"C\" function g(): i32 | E;\nexport function f(): i32 | E { return try g(); }", Debug);

        expect(text).toInclude("try.error:");
        expect(text).toInclude("try.ok:");
    }
}

describe("stringEqual") {
    test("should compare strings by length and then with memcmp") {
        const text = body("export function f(s: string): i32 { switch (s) { case \"quit\": return 1; default: return 2; } }", Debug);

        expect(text).toInclude("icmp eq i64 %1, 4");
        expect(text).toInclude("select i1 %2, i64 %1, i64 0");
        expect(text).toInclude("call i32 @memcmp(");
    }
}

describe("emitSwitch") {
    test("should end a switch without a default case in unreachable") {
        const text = body("enum Dir { Up, Down }\nexport function f(d: Dir): i32 { switch (d) { case Dir.Up: return 1; case Dir.Down: return 2; } }", Debug);

        expect(text).toInclude("unreachable");
        expect(text).not.toInclude("panic");
    }

    test("should store the value of the chosen case of a switch expression") {
        const text = body("export function f(n: i32): i32 { return switch (n) { case 1: 10; default: 20; }; }", Debug);

        expect(text).toInclude("%switch.result = alloca i32");
        expect(text).toInclude("store i32 10, ptr %switch.result");
        expect(text).toInclude("store i32 20, ptr %switch.result");
    }

    test("should test a range pattern against both bounds") {
        const text = body("export function f(n: i32): i32 { switch (n) { case 1..=5: return 1; default: return 2; } }", Debug);

        expect(text).toInclude("icmp sge i32");
        expect(text).toInclude("icmp sle i32");
    }
}

describe("emitValue") {
    test("should emit a value that the checker computed as a constant") {
        expect(body("export function f(): i32 { return 2 + 3; }", Debug)).toInclude("ret i32 5");
    }

    test("should convert a value to the type that the checker coerced it to") {
        expect(body("export function f(x: u8): u32 { return x; }", Debug)).toInclude("zext i8 %x2 to i32");
    }

    test("should skip the right side of && when the left side is false") {
        const text = body("export function f(a: bool, b: bool): bool { return a && b; }", Debug);

        expect(text).toInclude("and.rhs:");
        expect(text).toInclude("phi i1 [ false, %entry ]");
    }
}
