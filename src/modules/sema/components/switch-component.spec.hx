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

describe("hxsVariantRef") {
    test("should accept a variant named through its union") {
        expect(errors("union Shape { circle: f64, square: f64, empty }\nfunction f(s: Shape): i32 { return switch (s) { case Shape.empty: 0; default: 1; }; }")).toBe("");
    }

    test("should accept a variant named by an enum literal") {
        expect(errors("union Shape { circle: f64, square: f64, empty }\nfunction f(s: Shape): i32 { return switch (s) { case .empty: 0; default: 1; }; }")).toBe("");
    }

    test("should report a name that is not a variant of the union") {
        expect(errors("union Shape { circle: f64, square: f64, empty }\nfunction f(s: Shape): i32 { return switch (s) { case Shape.oval: 0; default: 1; }; }"))
            .toInclude("`Shape` has no variant `oval`");
    }

    test("should report an expression that names no variant") {
        expect(errors("union Shape { circle: f64, square: f64, empty }\nfunction f(s: Shape): i32 { return switch (s) { case 3: 0; default: 1; }; }"))
            .toInclude("expected a variant of `Shape`");
    }
}

describe("hxsIrrefutable") {
    test("should count a struct pattern of bindings as covering every value") {
        expect(errors("struct P { x: i32, y: i32 }\nfunction f(p: P): i32 { return switch (p) { case { x, y }: x + y; }; }"))
            .toBe("");
    }

    test("should not count a struct pattern with a value as covering every value") {
        expect(errors("struct P { x: i32, y: i32 }\nfunction f(p: P): i32 { return switch (p) { case { x: 0, y }: y; }; }"))
            .toInclude("needs a `default` case");
    }
}

describe("hxsCover") {
    test("should not count a guarded case toward exhaustiveness") {
        expect(errors("enum Role { Admin, Member, Guest }\nfunction f(r: Role, ok: bool): i32 { return switch (r) { case Role.Admin if ok: 1; case Role.Member: 2; case Role.Guest: 3; }; }"))
            .toInclude("switch on `Role` doesn't handle every case");
    }

    test("should count each bool value it sees") {
        expect(errors("function f(b: bool): i32 { return switch (b) { case true: 1; case false: 0; }; }")).toBe("");
    }
}

describe("hxsCheckPattern") {
    test("should bind the value of a union variant") {
        expect(errors("union Shape { circle: f64, square: f64, empty }\nfunction f(s: Shape): f64 { return switch (s) { case Shape.circle(r): r * r; default: 0.0; }; }"))
            .toBe("");
    }

    test("should report a value pattern on a variant without a value") {
        expect(errors("union Shape { circle: f64, square: f64, empty }\nfunction f(s: Shape): i32 { return switch (s) { case Shape.empty(x): 0; default: 1; }; }"))
            .toInclude("`empty` carries no value");
    }

    test("should report a range on a type other than an integer") {
        expect(errors("function f(b: bool): i32 { return switch (b) { case false..true: 0; default: 1; }; }"))
            .toInclude("ranges only match integers, not `bool`");
    }

    test("should accept a range of integers") {
        expect(errors("function f(x: i32): i32 { return switch (x) { case 1..5: 0; default: 1; }; }")).toBe("");
    }

    test("should report a case value that is not known at compile time") {
        expect(errors("struct Q { v: i32 }\nfunction f(x: i32, q: Q): i32 { return switch (x) { case q.v: 0; default: 1; }; }"))
            .toInclude("a case value must be known at compile time");
    }

    test("should report a value pattern on a type that is not a union") {
        expect(errors("function f(x: i32): i32 { return switch (x) { case .a(v): v; default: 1; }; }"))
            .toInclude("`i32` is not a union, so its cases carry no values");
    }

    test("should report a struct pattern on a type that is not a struct") {
        expect(errors("function f(x: i32): i32 { return switch (x) { case { a }: a; default: 1; }; }"))
            .toInclude("patterns match structs, not `i32`");
    }

    test("should report a field that the struct does not have") {
        expect(errors("struct P { x: i32 }\nfunction f(p: P): i32 { return switch (p) { case { z }: 0; default: 1; }; }"))
            .toInclude("`P` has no field `z`");
    }
}

describe("hxsCheckSwitch") {
    test("should report an enum switch that leaves out a case") {
        expect(errors("enum Role { Admin, Member, Guest }\nfunction f(r: Role): i32 { return switch (r) { case Role.Admin: 1; }; }"))
            .toInclude("switch on `Role` doesn't handle every case");
    }

    test("should accept an enum switch that handles every case without a default") {
        expect(errors("enum Role { Admin, Member, Guest }\nfunction f(r: Role): i32 { return switch (r) { case Role.Admin: 1; case Role.Member: 2; case Role.Guest: 3; }; }"))
            .toBe("");
    }

    test("should ask for a default case on an integer") {
        expect(errors("function f(n: i32): i32 { return switch (n) { case 0: 1; }; }"))
            .toInclude("switch on `i32` needs a `default` case");
    }

    test("should report a literal subject") {
        expect(errors("function f(): i32 { return switch (3) { default: 1; }; }"))
            .toInclude("switching on a literal needs a concrete type");
    }

    test("should switch on a string") {
        expect(errors("function f(s: string): i32 { return switch (s) { case \"a\": 1; default: 2; }; }")).toBe("");
    }

    test("should ask for a type when every case is a literal number") {
        expect(errors("function f(b: bool): void { const x = switch (b) { case true: 1; case false: 2 }; void x; }"))
            .toInclude("can't tell which number type this switch produces");
    }

    test("should make a statement switch that returns in every case end the function") {
        expect(errors("enum Role { Admin, Member, Guest }\nfunction f(r: Role): i32 { switch (r) { case Role.Admin: return 1; case Role.Member: return 2; case Role.Guest: return 3; } }"))
            .toBe("");
    }

    test("should let an empty case fall into the next one") {
        expect(errors("enum Role { Admin, Member, Guest }\nfunction f(r: Role): i32 { switch (r) { case Role.Admin: case Role.Member: return 1; default: return 2; } }"))
            .toBe("");
    }
}

describe("hxsCheckStmt") {
    test("should report a return that points into a local") {
        expect(errors("function f(): *i32 { let x: i32 = 1; return &x; }"))
            .toInclude("this points into `x`, a local that's gone once the function returns");
    }

    test("should report a return that points into a parameter") {
        expect(errors("function f(v: i32): readonly *i32 { return &v; }"))
            .toInclude("this points into `v`, a parameter that's gone once the function returns");
    }

    test("should allow a return that points through a pointer parameter") {
        expect(errors("struct P { x: i32 }\nfunction f(p: *P): *i32 { return &p.x; }")).toBe("");
    }

    test("should report an unused result") {
        expect(errors("function g(): i32 { return 1; }\nfunction f(): void { g(); }"))
            .toInclude("the result of `g` is unused");
    }

    test("should report an unhandled error") {
        expect(errors("function g(): i32 | Error { return 1; }\nfunction f(): void { g(); }"))
            .toInclude("the error from `g` is not handled");
    }

    test("should report a value returned from a void function") {
        expect(errors("function f(): void { return 1; }"))
            .toInclude("this function returns `void`, so `return` takes no value");
    }

    test("should report a missing return value") {
        expect(errors("function f(): i32 { return; }")).toInclude("missing return value of type `i32`");
    }

    test("should report a return inside a defer") {
        expect(errors("function f(): void { defer { return; } }")).toInclude("`return` can't be used inside a `defer`");
    }

    test("should report a compound assignment on a type it does not work on") {
        expect(errors("function f(): void { let b = true; b += true; }")).toInclude("`+=` doesn't work on `bool`");
    }

    test("should report an increment of a value that is not an integer") {
        expect(errors("function f(): void { let x: f64 = 1.0; x++; }")).toInclude("`++` needs an integer, found `f64`");
    }

    test("should report an errdefer in a function that can't fail") {
        expect(errors("function f(): void { errdefer {} }")).toInclude("`errdefer` never runs here");
    }

    test("should report a capture of a value that is not optional") {
        expect(errors("function f(x: i32): void { if (const v = x) { void v; } }"))
            .toInclude("`if (const ... = x)` needs an optional, found `i32`");
    }

    test("should skip a @compileError in a branch that a known condition rules out") {
        expect(errors("function f(): void { if (false) { @compileError(\"no\"); } }")).toBe("");
    }

    test("should treat while (true) without a break as never ending") {
        expect(errors("function f(): i32 { while (true) {} }")).toBe("");
    }

    test("should narrow an optional for the rest of the block after a null check that returns") {
        expect(errors("function f(p: ?i32): i32 { if (p == null) return 0; const v: i32 = p; return v; }")).toBe("");
    }
}
