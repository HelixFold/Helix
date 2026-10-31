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
 * Every error message that checking a text gives, one per line, or an empty string when it checks.
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

describe("hxsCheckCall") {
    test("should report a call to an unknown function") {
        expect(errors("function f(): void { missing(1); }")).toInclude("unknown function `missing`");
    }

    test("should build a union variant from the expected type") {
        expect(errors("struct Point { x: i32, y: i32 }\nunion Event { click: Point, quit }\nfunction f(): Event { return .click(Point { x: 1, y: 2 }); }"))
            .toBe("");
    }

    test("should report a variant call without a union to belong to") {
        expect(errors("function f(): void { const e = .click(1); void e; }"))
            .toInclude("can't tell which union `.click` belongs to");
    }

    test("should report a variant that the union does not have") {
        expect(errors("union Event { click: i32, quit }\nfunction f(): Event { return .press(1); }"))
            .toInclude("`Event` has no variant `press`");
    }

    test("should instantiate a generic function with explicit type arguments") {
        expect(errors("function max<T>(a: T, b: T): T { return a > b ? a : b; }\nfunction f(): i64 { return max<i64>(1, 2); }"))
            .toBe("");
    }

    test("should refuse type arguments on a function that is not generic") {
        expect(errors("function one(a: i32): i32 { return a; }\nfunction f(): i32 { return one<i32>(1); }"))
            .toInclude("expected a generic function");
    }

    test("should report expect outside a test as an unknown function") {
        expect(errors("function f(): void { expect(1).toBe(1); }")).toInclude("unknown function `expect`");
    }

    test("should call a variable of function type through its value") {
        expect(errors("function one(): i32 { return 1; }\nfunction f(): i32 { const g = one; return g(); }")).toBe("");
    }
}

describe("hxsCheckFunctionCall") {
    test("should check the arguments against the function") {
        expect(errors("function add(a: i32, b: i32): i32 { return a + b; }\nfunction f(): i32 { return add(1); }"))
            .toInclude("`add` takes 2 arguments, but 1 was given");
    }

    test("should give the call the result type of the function") {
        expect(errors("function add(a: i32, b: i32): i32 { return a + b; }\nfunction f(): bool { return add(1, 2); }"))
            .toInclude("expected `bool`, found `i32`");
    }
}

describe("hxsCheckCoalesce") {
    test("should unwrap the optional with the fallback") {
        expect(errors("function f(n: ?i32): i32 { return n ?? 0; }")).toBe("");
    }

    test("should refuse a left side that is not optional") {
        expect(errors("function f(n: i32): i32 { return n ?? 0; }"))
            .toInclude("`??` needs an optional on the left, found `i32`");
    }

    test("should stay optional when both sides are optional") {
        expect(errors("function f(a: ?i32, b: ?i32): i32 { return a ?? b; }")).toInclude("expected `i32`, found `?i32`");
    }
}

describe("hxsCheckBinary") {
    test("should refuse arithmetic on booleans") {
        expect(errors("function f(a: bool): void { void (a + a); }")).toInclude("`+` doesn't work on `bool`");
    }

    test("should refuse to compare null with a value that is never null") {
        expect(errors("function f(a: i32): bool { return a == null; }")).toInclude("`i32` is never null");
    }

    test("should refuse an ordering comparison with null") {
        expect(errors("function f(a: ?i32): bool { return a < null; }"))
            .toInclude("`null` can only be compared with `==` or `!=`");
    }

    test("should refuse to compare structs") {
        expect(errors("struct P { x: i32 }\nfunction f(a: P, b: P): bool { return a == b; }"))
            .toInclude("`P` can't be compared with `==`");
    }

    test("should refuse a shift of a non-integer") {
        expect(errors("function f(a: f64): f64 { return a << 1; }")).toInclude("shifts need integers");
    }

    test("should refuse a literal shifted by a runtime amount") {
        expect(errors("function f(n: u32): u64 { return 1 << n; }"))
            .toInclude("shifting a literal by a runtime amount needs a concrete type");
    }

    test("should refuse a wrapping operator on literals") {
        expect(errors("function f(): void { const x = 1 +% 2; void x; }"))
            .toInclude("`+%` needs a concrete integer type to know where to wrap");
    }

    test("should narrow the left side of && for the right side") {
        expect(errors("function f(s: ?string): bool { return s != null && s.len > 0; }")).toBe("");
    }

    test("should fold a constant expression") {
        expect(errors("function f(): void { const x: u8 = 200 + 100; void x; }")).toInclude("300 does not fit in `u8`");
    }

    test("should give an enum literal on the right the type of the left") {
        expect(errors("enum Role { Admin, User }\nfunction f(r: Role): bool { return r == .Admin; }")).toBe("");
    }
}

describe("hxsCheckUnary") {
    test("should refuse to negate an unsigned integer") {
        expect(errors("function f(x: u32): u32 { return -x; }")).toInclude("can't negate unsigned `u32`");
    }

    test("should refuse ~ on a literal") {
        expect(errors("function f(): void { const x = ~1; void x; }"))
            .toInclude("`~` needs a concrete integer type, found");
    }

    test("should refuse the address of a compile-time constant") {
        expect(errors("function f(): void { const x = 1; const p = &x; void p; }"))
            .toInclude("compile-time constants have no address");
    }

    test("should refuse the address of a value that is not a place") {
        expect(errors("function one(): i32 { return 1; }\nfunction f(): void { const p = &one(); void p; }"))
            .toInclude("can't take the address of this expression");
    }

    test("should give a readonly pointer to a constant place") {
        expect(errors("function f(a: i32): void { const p: *i32 = &a; void p; }")).toInclude("expected `*i32`, found `readonly *i32`");
    }

    test("should refuse to dereference a value that is not a pointer") {
        expect(errors("function f(a: i32): i32 { return *a; }")).toInclude("can't dereference `i32`");
    }

    test("should refuse to discard a void value") {
        expect(errors("function g(): void {}\nfunction f(): void { void g(); }"))
            .toInclude("nothing to discard: the expression is `void`");
    }

    test("should fold the negation of a constant") {
        expect(errors("function f(): void { const x: i8 = -200; void x; }")).toInclude("-200 does not fit in `i8`");
    }
}

describe("hxsCheckCast") {
    test("should convert between numbers") {
        expect(errors("function f(a: i32): f64 { return a as f64; }")).toBe("");
    }

    test("should refuse a conversion that is not numeric") {
        expect(errors("function f(a: bool): f64 { return a as f64; }")).toInclude("can't convert `bool` to `f64` with `as`");
    }

    test("should report a known value that does not fit the target") {
        expect(errors("function f(): u8 { return 300 as u8; }")).toInclude("300 does not fit in `u8`");
    }

    test("should report a float that is out of range for an integer") {
        expect(errors("function f(): i32 { return 1e39 as i32; }")).toInclude("float value is out of range for `i32`");
    }
}
