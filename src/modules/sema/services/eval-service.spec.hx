/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { HxSema } from "@structs/sema.struct";
import { hxAstFree } from "@models/ast.model";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
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
 * The parser and the checker keep pointers into the source and the token list,
 * so a test declares the state on its stack and lets {@link check} fill it in place.
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
 * @param text - The NUL-terminated bytes
 * @returns The bytes before the NUL
 *
 * @remarks
 * Measures the text with `strlen` and slices it without a copy,
 * so the slice stays valid only as long as the bytes do.
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
 * @param ch - The state that receives every stage
 * @param text - The program source
 *
 * @remarks
 * Every stage writes into the same diagnostic list and runs even after an earlier stage reports errors.
 * The check passes no program, so the text stands alone as a single module.
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
 * @param ch - The state that {@link check} filled
 *
 * @remarks
 * Frees the stages in the reverse order of their creation, so the source goes last.
 * A test must not read the state afterwards.
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
 * Every diagnostic message that checking a text gives, one per line, or an empty string when it checks.
 *
 * @param text - The program source
 * @returns The messages, each followed by a newline
 *
 * @remarks
 * Diagnostics of every severity count, and their hints stay out of the text.
 * The text lives in the shared builder, which the next call clears,
 * so a test compares the result before it checks another source.
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

describe("hxEvalExpr") {
    test("should fold a recursive call into a constant") {
        expect(errors("function fib(n: u64): u64 { return n < 2 ? n : fib(n - 1) + fib(n - 2); }\nconst F = comptime fib(10);\ncomptime { if (F != 55) @compileError(\"wrong\"); }")).toBe("");
    }

    test("should keep the folded value exact enough to fail a wrong assertion") {
        expect(errors("function fib(n: u64): u64 { return n < 2 ? n : fib(n - 1) + fib(n - 2); }\nconst F = comptime fib(10);\ncomptime { if (F != 56) @compileError(\"wrong\"); }")).toInclude("wrong");
    }

    test("should fold loops, arrays, and assignments into an array constant") {
        expect(errors("function squares(): u32[4] { let a: u32[4] = undefined; for (const i of 0..4) a[i] = (i * i) as u32; return a; }\nconst S = comptime squares();\ncomptime { if (S[3] != 9) @compileError(\"wrong\"); }")).toBe("");
    }

    test("should fill struct fields from their defaults and run methods") {
        expect(errors("struct P { x: i32, y: i32 = 7, scaled(this: P, k: i32): P { return P { x: this.x * k, y: this.y * k }; } }\nconst O = comptime (P { x: 1 }).scaled(3);\ncomptime { if (O.x != 3 || O.y != 21) @compileError(\"wrong\"); }"))
            .toBe("");
    }

    test("should keep a string that a switch picks") {
        expect(errors("function name(n: i32): string { return switch (n) { case 1: \"one\"; case 2, 3: \"few\"; default: \"many\"; }; }\nconst W = comptime name(3);\ncomptime { if (W.len != 3 || W[0] != 'f') @compileError(\"wrong\"); }")).toBe("");
    }

    test("should wrap a value with @truncate") {
        expect(errors("function t(): u8 { const x: u32 = 300; return @truncate(u8, x); }\nconst X = comptime t();\ncomptime { if (X != 44) @compileError(\"wrong\"); }")).toBe("");
    }

    test("should run defers newest first") {
        expect(errors("function order(): i32 { let log: i32 = 0; { defer log = log * 10 + 1; defer log = log * 10 + 2; } return log; }\nconst X = comptime order();\ncomptime { if (X != 21) @compileError(\"wrong\"); }")).toBe("");
    }

    test("should report an integer overflow with the type it overflows") {
        expect(errors("function f(): u8 { let x: u8 = 250; for (const _ of 0..10) x += 1; return x; }\nconst A = comptime f();"))
            .toInclude("integer overflow at compile time: the result doesn't fit in `u8`");
    }

    test("should add a note at the comptime expression when the error is inside a call") {
        expect(errors("function f(): u8 { let x: u8 = 250; for (const _ of 0..10) x += 1; return x; }\nconst A = comptime f();"))
            .toInclude("while evaluating this at compile time");
    }

    test("should stop an endless loop after the step limit") {
        expect(errors("function f(): i32 { let n: i32 = 0; while (true) n = n +% 1; }\nconst B = comptime f();"))
            .toInclude("compile-time evaluation took more than 1000000 steps (loop iterations and calls)");
    }

    test("should report an index out of bounds with the index and length") {
        expect(errors("function f(): i32 { const a: i32[3] = [1, 2, 3]; let i: usize = 0; while (i < 5) i += 1; return a[i]; }\nconst C = comptime f();")).toInclude("index out of bounds at compile time: index 5, len 3");
    }

    test("should refuse to call a C function") {
        expect(errors("extern \"C\" function abs(x: i32): i32;\nconst D = comptime abs(-3);"))
            .toInclude("`abs` is a C function, so it can't run at compile time");
    }

    test("should turn @panic into a compile error") {
        expect(errors("function f(n: i32): i32 { if (n < 0) @panic(\"negative input\"); return n; }\nconst E = comptime f(-1);"))
            .toInclude("panic at compile time: negative input");
    }

    test("should refuse to keep a pointer for the program") {
        expect(errors("function f(): *i32 { let x: i32 = 1; const p = &x; return p; }\nconst F = comptime f();"))
            .toInclude("a `*i32` made at compile time can't be kept for the program");
    }

    test("should refuse to read a global variable") {
        expect(errors("let counter: i32 = 0;\nconst G = comptime counter + 1;"))
            .toInclude("`counter` is only known when the program runs");
    }

    test("should report a division by zero") {
        expect(errors("function f(d: i32): i32 { return 10 / d; }\nconst X = comptime f(0);"))
            .toInclude("division by zero at compile time");
    }

    test("should report a shift amount wider than the type") {
        expect(errors("function f(n: u32): u32 { const x: u32 = 1; return x << n; }\nconst X = comptime f(40);"))
            .toInclude("shift amount 40 is too large for `u32`");
    }

    test("should report a checked cast that does not fit") {
        expect(errors("function big(): i32 { return 300; }\nconst X = comptime big() as u8;"))
            .toInclude("300 doesn't fit in `u8` (cast at compile time)");
    }

    test("should report unwrapping a null value") {
        expect(errors("function none(): ?i32 { return null; }\nfunction f(): i32 { return none()!; }\nconst X = comptime f();"))
            .toInclude("unwrapped a null value at compile time");
    }

    test("should report reaching unreachable code") {
        expect(errors("function f(): i32 { unreachable; }\nconst X = comptime f();"))
            .toInclude("reached unreachable code at compile time");
    }

    test("should fold a constant struct global without comptime") {
        expect(errors("struct P { x: i32, y: i32 }\nconst O: P = { x: 1, y: 2 };\ncomptime { if (O.y != 2) @compileError(\"wrong\"); }"))
            .toBe("");
    }
}

describe("hxEvalBlock") {
    test("should report @compileError when the condition holds") {
        expect(errors("struct H { magic: u32, size: u64 }\ncomptime { if (@sizeOf(H) != 12) @compileError(\"H must be 12 bytes\"); }"))
            .toInclude("H must be 12 bytes");
    }

    test("should leave a block that passes without diagnostics") {
        expect(errors("struct H { magic: u32, size: u64 }\ncomptime { if (@sizeOf(H) != 16) @compileError(\"H must be 16 bytes\"); }"))
            .toBe("");
    }

    test("should run locals and loops inside the block") {
        expect(errors("comptime { let total: i32 = 0; for (const i of 1..=4) total += i as i32; if (total != 10) @compileError(\"wrong\"); }"))
            .toBe("");
    }

    test("should report a panic inside the block") {
        expect(errors("comptime { @panic(\"stop\"); }")).toInclude("panic at compile time: stop");
    }
}
