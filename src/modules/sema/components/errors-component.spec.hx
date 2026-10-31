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

describe("hxsCheckUnwrap") {
    test("should give the type inside the optional") {
        expect(errors("function f(x: ?i32): bool { return x!; }")).toInclude("expected `bool`, found `i32`");
    }

    test("should report a value that is never null") {
        expect(errors("function f(x: i32): i32 { return x!; }")).toInclude("`!` unwraps an optional, but `i32` is never null");
    }
}

describe("hxsCheckOptionalField") {
    test("should give the field wrapped in an optional") {
        expect(errors("struct P { x: i32 }\nfunction f(p: ?P): bool { return p?.x; }")).toInclude("found `?i32`");
    }

    test("should not wrap a field that is already optional") {
        expect(errors("struct P { x: ?i32 }\nfunction f(p: ?P): bool { return p?.x; }")).toInclude("found `?i32`");
    }

    test("should read through an optional pointer to a struct") {
        expect(errors("struct P { x: i32 }\nfunction f(p: ?*P): bool { return p?.x; }")).toInclude("found `?i32`");
    }

    test("should give an optional length for an optional slice") {
        expect(errors("function f(s: ?i32[]): bool { return s?.len; }")).toInclude("found `?u64`");
    }

    test("should report a base that is never null") {
        expect(errors("struct P { x: i32 }\nfunction f(p: P): ?i32 { return p?.x; }"))
            .toInclude("`?.` needs an optional, but `P` is never null");
    }

    test("should report an optional that does not hold a struct") {
        expect(errors("function f(p: ?i32): ?i32 { return p?.x; }")).toInclude("`?.` reads struct fields, and `i32` is not a struct");
    }

    test("should report a field that the struct does not have") {
        expect(errors("struct P { x: i32 }\nfunction f(p: ?P): ?i32 { return p?.y; }")).toInclude("`P` has no field `y`");
    }
}

describe("hxsCheckTry") {
    test("should give the payload type") {
        expect(errors("error E { Bad }\nfunction g(): i32 | E { return 1; }\nfunction f(): bool | E { return try g(); }"))
            .toInclude("expected `bool | E`, found `i32`");
    }

    test("should report a value that cannot fail") {
        expect(errors("function f(x: i32): i32 { return try x; }")).toInclude("`try` needs something that can fail, but `i32` can't");
    }

    test("should report a function that cannot fail") {
        expect(errors("error E { Bad }\nfunction g(): i32 | E { return 1; }\nfunction f(): i32 { return try g(); }"))
            .toInclude("`try` passes errors on, but this function can't fail");
    }

    test("should report errors that the function's error set does not hold") {
        expect(errors("error E { Bad }\nerror F { Worse }\nfunction g(): i32 | E { return 1; }\nfunction f(): i32 | F { return try g(); }"))
            .toInclude("errors from `E` can't leave this function, which returns `F`");
    }

    test("should report a try inside a defer") {
        expect(errors("error E { Bad }\nfunction g(): i32 | E { return 1; }\nfunction f(): void | E { defer { const _x = try g(); } }"))
            .toInclude("`try` can't be used inside a `defer`");
    }
}

describe("hxsCheckCatch") {
    test("should give the payload type") {
        expect(errors("error E { Bad }\nfunction g(): i32 | E { return 1; }\nfunction f(): bool { return g() catch 0; }"))
            .toInclude("expected `bool`, found `i32`");
    }

    test("should check the fallback against the payload type") {
        expect(errors("error E { Bad }\nfunction g(): i32 | E { return 1; }\nfunction f(): i32 { return g() catch true; }"))
            .toInclude("expected `i32`, found `bool`");
    }

    test("should report a value that cannot fail") {
        expect(errors("function f(x: i32): i32 { return x catch 0; }")).toInclude("`catch` needs something that can fail, but `i32` can't");
    }

    test("should require a block handler to leave when there is a payload") {
        expect(errors("error E { Bad }\nfunction g(): i32 | E { return 1; }\nfunction f(): i32 { const v = g() catch (_e) { }; return v; }"))
            .toInclude("this `catch` block must return, throw or panic");
    }

    test("should accept a block handler that returns") {
        expect(errors("error E { Bad }\nfunction g(): i32 | E { return 1; }\nfunction f(): i32 { const v = g() catch (_e) { return 0; }; return v; }"))
            .toBe("");
    }

    test("should accept an empty block handler for a void payload") {
        expect(errors("error E { Bad }\nfunction g(): void | E { }\nfunction f(): void { g() catch { }; }")).toBe("");
    }

    test("should give the capture the error set of the value") {
        expect(errors("error E { Bad }\nfunction g(): i32 | E { return 1; }\nfunction f(): bool { const _v = g() catch (e) { const b: bool = e; return b; }; return true; }"))
            .toInclude("expected `bool`, found `E`");
    }
}

describe("hxsCheckThrow") {
    test("should accept an error of the function's error set") {
        expect(errors("error E { Bad }\nfunction f(): i32 | E { throw E.Bad; }")).toBe("");
    }

    test("should accept any error when the function returns Error") {
        expect(errors("error E { Bad }\nfunction f(): i32 | Error { throw E.Bad; }")).toBe("");
    }

    test("should report a function that cannot fail") {
        expect(errors("error E { Bad }\nfunction f(): i32 { throw E.Bad; }")).toInclude("`throw` needs a function that can fail");
    }

    test("should report a throw inside a defer") {
        expect(errors("error E { Bad }\nfunction f(): i32 | E { defer { throw E.Bad; } return 1; }"))
            .toInclude("`throw` can't be used inside a `defer`");
    }

    test("should report an error that the function's error set does not hold") {
        expect(errors("error E { Bad }\nerror F { Worse }\nfunction f(): i32 | E { throw F.Worse; }")).toInclude("expected `E`, found `F`");
    }

    test("should report a value that is not an error") {
        expect(errors("function f(): i32 | Error { throw 1; }")).toInclude("`throw` needs an error, found `integer literal`");
    }
}
