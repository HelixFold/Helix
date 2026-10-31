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
 * The tree and the checker hold pointers into the other fields,
 * so a test declares the value once and passes its address to `check` and `release`.
 * Moving the value between those two calls leaves those pointers dangling.
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
 * @returns The bytes before the terminating NUL
 *
 * @remarks
 * The slice points into the original buffer without a copy, so it lives only as long as that buffer.
 * Diagnostic messages are C strings, and this view lets the specs append them to a builder.
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
 * @param ch - The state to fill, which must not move until `release`
 * @param text - The source text to check
 *
 * @remarks
 * Passes no program to `hxSemaCheck`, so the checker sees the text as its only module.
 * The source copies the text, so the caller may reuse its buffer right away.
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
 * @param ch - The state that a check filled
 *
 * @remarks
 * Frees the checker state, tree, tokens, diagnostics, and source of the state.
 * The state holds no live tables afterward until the next check fills it again.
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
 * @param text - The source text to check
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Copies the messages into one module-level builder and releases the check before it returns.
 * Every call clears that builder, so the returned text stays valid only until the next call.
 * Hints are left out.
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

describe("hxsCheckIndex") {
    test("should give the element type of an array") {
        expect(errors("function f(): bool { const a: i32[4] = [1, 2, 3, 4]; return a[1]; }"))
            .toInclude("expected `bool`, found `i32`");
    }

    test("should report a constant index past the end of an array") {
        expect(errors("function f(): i32 { const a: i32[4] = [1, 2, 3, 4]; return a[4]; }"))
            .toInclude("index 4 is out of bounds for `i32[4]`");
    }

    test("should give a u8 for a string literal") {
        expect(errors("function f(): bool { const s = \"abc\"; return s[0]; }")).toInclude("expected `bool`, found `u8`");
    }

    test("should require unsafe to index a raw pointer") {
        expect(errors("function f(p: i32[*]): i32 { return p[0]; }"))
            .toInclude("indexing a raw `i32[*]` pointer needs `unsafe { }`");
    }

    test("should accept a raw pointer indexed inside unsafe") {
        expect(errors("function f(p: i32[*]): i32 { unsafe { return p[0]; } }")).toBe("");
    }

    test("should report a value that cannot be indexed") {
        expect(errors("function f(x: i32): i32 { return x[0]; }")).toInclude("`i32` can't be indexed");
    }
}

describe("hxsCheckSlice") {
    test("should give a mutable slice of a mutable array") {
        expect(errors("function f(): bool { let a: i32[4] = [1, 2, 3, 4]; const s = a[1..3]; return s; }"))
            .toInclude("found `i32[]`");
    }

    test("should give a read-only slice of a constant array") {
        expect(errors("function f(): bool { const a: i32[4] = [1, 2, 3, 4]; const s = a[1..3]; return s; }"))
            .toInclude("found `readonly i32[]`");
    }

    test("should give a string for a slice of a string literal") {
        expect(errors("function f(): bool { const s = \"abc\"; return s[0..1]; }")).toInclude("found `string`");
    }

    test("should report an array that is not stored in a variable") {
        expect(errors("function g(): i32[4] { return [1, 2, 3, 4]; }\nfunction f(): i32 { const s = g()[0..2]; return s[0]; }"))
            .toInclude("only an array stored in a variable can be sliced");
    }

    test("should require unsafe to slice a raw pointer") {
        expect(errors("function f(p: i32[*]): i32[] { return p[0..2]; }"))
            .toInclude("slicing a raw `i32[*]` pointer needs `unsafe { }`");
    }

    test("should require an end to slice a raw pointer") {
        expect(errors("function f(p: i32[*]): i32[] { unsafe { return p[0..]; } }"))
            .toInclude("slicing a raw pointer needs an end: `p[0..len]`");
    }

    test("should report a value that cannot be sliced") {
        expect(errors("function f(x: i32): i32 { const s = x[0..1]; return s; }")).toInclude("`i32` can't be sliced");
    }
}

describe("hxsCheckStaticMember") {
    test("should give the enum type for an enum value") {
        expect(errors("enum Color { Red, Green }\nfunction f(): bool { return Color.Green; }"))
            .toInclude("expected `bool`, found `Color`");
    }

    test("should report a member that the type does not have") {
        expect(errors("enum Color { Red, Green }\nfunction f(): Color { return Color.Blue; }"))
            .toInclude("`Color` has no member `Blue`");
    }

    test("should report a struct field read from the type") {
        expect(errors("struct P { x: i32 }\nfunction f(): i32 { return P.x; }"))
            .toInclude("`x` is a field, so it needs a `P` value");
    }

    test("should accept a union variant without a payload") {
        expect(errors("union S { circle: f64, empty }\nfunction f(): S { return S.empty; }")).toBe("");
    }

    test("should report a union variant that carries a payload") {
        expect(errors("union S { circle: f64, empty }\nfunction f(): S { return S.circle; }"))
            .toInclude("`S.circle` carries a `f64`");
    }

    test("should give the type of a constant member") {
        expect(errors("struct P { x: i32, const ZERO: i32 = 0; }\nfunction f(): bool { return P.ZERO; }"))
            .toInclude("expected `bool`, found `i32`");
    }

    test("should turn a method into a function that takes the receiver first") {
        expect(errors("struct P { x: i32, get(this: readonly *P): i32 { return this.x; } }\nfunction f(): bool { const g = P.get; return g; }"))
            .toInclude("found `(readonly *P) => i32`");
    }

    test("should report a generic method used as a value") {
        expect(errors("struct P { x: i32, id<T>(this: readonly *P, v: T): T { return v; } }\nfunction f(): i32 { const g = P.id; return 0; }"))
            .toInclude("`P.id` is generic, so it can't be used as a value on its own");
    }

    test("should report an interface method read from the interface") {
        expect(errors("interface Shape { area(this: *Self): f64; }\nfunction f(): i32 { const g = Shape.area; return 0; }"))
            .toInclude("`Shape.area` is an interface method; call it on a value");
    }
}

describe("hxsCheckField") {
    test("should read a field through a pointer to a struct") {
        expect(errors("struct P { x: i32 }\nfunction f(p: *P): bool { return p.x; }")).toInclude("expected `bool`, found `i32`");
    }

    test("should report a field that the struct does not have") {
        expect(errors("struct P { x: i32 }\nfunction f(p: P): i32 { return p.y; }")).toInclude("`P` has no field `y`");
    }

    test("should report a method read without a call") {
        expect(errors("struct P { x: i32, get(this: readonly *P): i32 { return this.x; } }\nfunction f(p: P): i32 { return p.get; }"))
            .toInclude("`get` is a method");
    }

    test("should report a field of an optional") {
        expect(errors("struct P { x: i32 }\nfunction f(p: ?P): i32 { return p.x; }")).toInclude("`?P` might be null");
    }

    test("should report a field of a value that can fail") {
        expect(errors("function g(): i32 | Error { return 1; }\nfunction f(): i32 { return g().x; }"))
            .toInclude("this can fail, so it has no fields yet");
    }

    test("should give a many-item pointer for the ptr of a slice") {
        expect(errors("function f(s: i32[]): bool { return s.ptr; }")).toInclude("found `i32[*]`");
    }

    test("should give the length of a slice") {
        expect(errors("function f(s: i32[]): bool { return s.len; }")).toInclude("found `u64`");
    }

    test("should hint at len and ptr for an unknown field of a slice") {
        const text = errors("function f(s: i32[]): i32 { return s.cap; }");

        expect(text).toInclude("`i32[]` has no field `cap`");
        expect(text).not.toInclude("found");
    }
}

describe("hxsCheckEnumLiteral") {
    test("should take the enum from the expected type") {
        expect(errors("enum Color { Red, Green }\nfunction f(): Color { return .Green; }")).toBe("");
    }

    test("should look through an optional expected type") {
        expect(errors("enum Color { Red, Green }\nfunction f(): ?Color { return .Red; }")).toBe("");
    }

    test("should report a literal without an expected type") {
        expect(errors("enum Color { Red, Green }\nfunction f(): Color { const c = .Red; return c; }"))
            .toInclude("can't tell which type `.Red` belongs to");
    }
}

describe("hxsCheckStructLiteral") {
    test("should list the one missing field") {
        expect(errors("struct P { x: i32, y: i32 }\nfunction f(): P { return { x: 1 }; }"))
            .toInclude("missing field `y` in `P`");
    }

    test("should list several missing fields") {
        expect(errors("struct P { x: i32, y: i32, z: i32 }\nfunction f(): P { return P { x: 1 }; }"))
            .toInclude("missing fields `y`, `z` in `P`");
    }

    test("should let a field with a default value be left out") {
        expect(errors("struct P { x: i32, y: i32 = 0 }\nfunction f(): P { return P { x: 1 }; }")).toBe("");
    }

    test("should report a field set twice") {
        expect(errors("struct P { x: i32 }\nfunction f(): P { return P { x: 1, x: 2 }; }")).toInclude("`x` is set twice");
    }

    test("should report a field that the struct does not have") {
        expect(errors("struct P { x: i32 }\nfunction f(): P { return P { x: 1, w: 2 }; }")).toInclude("`P` has no field `w`");
    }

    test("should read the shorthand from a variable of the same name") {
        expect(errors("struct P { x: i32 }\nfunction f(x: i32): P { return P { x }; }")).toBe("");
    }

    test("should coerce the shorthand to a wider field type") {
        expect(errors("struct P { x: i64 }\nfunction f(x: i32): P { return P { x }; }")).toBe("");
    }

    test("should report a shorthand of the wrong type") {
        expect(errors("struct P { x: i32 }\nfunction f(x: bool): P { return P { x }; }")).toInclude("expected `i32`, found `bool`");
    }

    test("should report a shorthand that names nothing") {
        expect(errors("struct P { x: i32 }\nfunction f(): P { return P { x }; }")).toInclude("unknown name `x`");
    }

    test("should report a literal that does not name its struct") {
        expect(errors("function f(): i32 { const p = { x: 1 }; return 0; }")).toInclude("can't tell which struct this is");
    }

    test("should report a type that is not a struct") {
        expect(errors("function f(): i32 { const p = i32 { x: 1 }; return 0; }")).toInclude("`i32` is not a struct");
    }
}

describe("hxsCheckArrayLiteral") {
    test("should give an i64 array without an expected type") {
        expect(errors("function f(): bool { const a = [1, 2, 3]; return a; }")).toInclude("found `i64[3]`");
    }

    test("should report a count that does not match the array length") {
        expect(errors("function f(): bool { const a: i32[2] = [1, 2, 3]; return a[0] == 1; }"))
            .toInclude("`i32[2]` needs 2 elements, found 3");
    }

    test("should check each item against the element type") {
        expect(errors("function f(): bool { const a: i32[2] = [1, true]; return a[0] == 1; }"))
            .toInclude("expected `i32`, found `bool`");
    }

    test("should accept the empty literal as an empty slice") {
        expect(errors("function f(): i32[] { return []; }")).toBe("");
    }

    test("should report the empty literal without an expected type") {
        expect(errors("function f(): bool { const a = []; return true; }")).toInclude("can't tell the element type of `[]`");
    }

    test("should make a constant array for a read-only slice of constants") {
        expect(errors("function f(): readonly i32[] { return [1, 2]; }")).toBe("");
    }

    test("should report a read-only slice with an item known only at run time") {
        expect(errors("function f(x: i32): readonly i32[] { return [1, x]; }"))
            .toInclude("an array literal needs storage before it can be a slice, unless every item is a constant");
    }

    test("should report a literal used as a mutable slice") {
        expect(errors("function f(): i32[] { return [1, 2]; }"))
            .toInclude("an array literal needs storage before it can be a slice\n");
    }
}
