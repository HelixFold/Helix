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

describe("hxsCheckLocal") {
    test("should report a const without a value") {
        expect(errors("function f(): void { const x: i32; }")).toInclude("`const x` needs a value");
    }

    test("should report a let without a type or a value") {
        expect(errors("function f(): void { let x; }")).toInclude("`let x` needs a type or a value");
    }

    test("should report a typed let without a value") {
        expect(errors("function f(): void { let x: i32; }")).toInclude("`x` needs an initial value");
    }

    test("should report a global without a value") {
        expect(errors("let g: i32;")).toInclude("global `g` needs an initial value");
    }

    test("should report a let of a literal number without a type") {
        expect(errors("function f(): void { let x = 1; x = 2; }")).toInclude("can't tell which number type `x` should be");
    }

    test("should keep a const of a literal number") {
        expect(errors("function f(): i32 { const x = 1; return x; }")).toBe("");
    }

    test("should report undefined without a type") {
        expect(errors("function f(): void { let x = undefined; }"))
            .toInclude("`undefined` needs an explicit type: `let x: T = undefined;`");
    }

    test("should report null without a type") {
        expect(errors("function f(): void { let x = null; }")).toInclude("`null` needs an explicit type: `let x: ?T = null;`");
    }

    test("should report a value of type void") {
        expect(errors("function g(): void {}\nfunction f(): void { const x = g(); }"))
            .toInclude("this expression has no value (`void`)");
    }

    test("should report a global whose value is not known at compile time") {
        expect(errors("function g(): i32 { return 1; }\nconst x: i32 = g();"))
            .toInclude("a global's initial value must be known at compile time");
    }

    test("should report a global constant set to undefined") {
        expect(errors("const x: i32 = undefined;")).toInclude("a global constant can't be `undefined`");
    }

    test("should fold a global constant struct literal without comptime") {
        expect(errors("struct P { x: i32, y: i32 }\nconst origin: P = P { x: 0, y: 0 };")).toBe("");
    }

    test("should report a C global without a type") {
        expect(errors("extern \"C\" let g;")).toInclude("a C global needs a type");
    }

    test("should report a C global with a value") {
        expect(errors("extern \"C\" let g: i32 = 1;")).toInclude("a C global gets its value from C");
    }
}

describe("hxsFindLoop") {
    test("should report a break outside of a loop") {
        expect(errors("function f(): void { break; }")).toInclude("`break` outside of a loop");
    }

    test("should report a label that no enclosing loop has") {
        expect(errors("function f(): void { outer: while (true) { break inner; } }"))
            .toInclude("no enclosing loop is labeled `inner`");
    }

    test("should find an outer loop by its label") {
        expect(errors("function f(): void { outer: while (true) { while (true) { break outer; } } }")).toBe("");
    }

    test("should report a jump out of a defer") {
        expect(errors("function f(): void { for (const i of 0..3) { defer { if (i > 1) continue; } } }"))
            .toInclude("`continue` can't jump out of a `defer`");
    }
}

describe("hxsPushLoop") {
    test("should let a continue find the loop it is in") {
        expect(errors("function f(): void { for (const i of 0..3) { if (i == 1) continue; } }")).toBe("");
    }
}

describe("hxsPopLoop") {
    test("should treat while (true) with a break as a loop that ends") {
        expect(errors("function f(): i32 { while (true) { break; } }")).toInclude("can reach its end without returning");
    }

    test("should treat a for without a condition or a break as never ending") {
        expect(errors("function f(): i32 { for (;;) {} }")).toBe("");
    }
}

describe("hxsCheckCondition") {
    test("should report a condition that is not a bool") {
        expect(errors("function f(n: i32): void { if (n) {} }")).toInclude("expected `bool`, found `i32`");
    }
}

describe("hxsCheckBlockContents") {
    test("should report the first statement after a return as unreachable code") {
        expect(errors("function g(): void {}\nfunction f(): i32 { return 1; g(); }")).toInclude("unreachable code");
    }

    test("should report unreachable code once per block") {
        const text = errors("function g(): void {}\nfunction f(): i32 { return 1; g(); g(); }");

        expect(text).toInclude("unreachable code\n");
        expect(text).not.toInclude("unreachable code\nunreachable code");
    }
}

describe("hxsCheckScoped") {
    test("should drop a local declared in a branch after the branch") {
        expect(errors("function f(ok: bool): i32 { if (ok) { const x: i32 = 1; return x; } return x; }"))
            .toInclude("unknown name `x`");
    }
}

describe("hxsCheckIterator") {
    test("should loop over a value with a next method") {
        expect(errors("struct C { n: i32, next(this: *C): ?i32 { this.n += 1; return this.n < 3 ? this.n : null; } }\nfunction f(): void { let c = C { n: 0 }; for (const x of c) println(x); }"))
            .toBe("");
    }

    test("should report an iterator held in a const") {
        expect(errors("struct C { n: i32, next(this: *C): ?i32 { return null; } }\nfunction f(): void { const c = C { n: 0 }; for (const x of c) println(x); }"))
            .toInclude("the loop advances this `C`, but it's constant");
    }

    test("should report a next with the wrong signature") {
        expect(errors("struct W { next(this: W): i32 { return 1; } }\nfunction f(): void { const w = W {}; for (const x of w) println(x); }"))
            .toInclude("`for-of` calls `W.next()`, which isn't `next(this: *Self): ?T`");
    }

    test("should report a generic next") {
        expect(errors("struct G { next<T>(this: *G, x: T): ?T { return x; } }\nfunction f(): void { let g = G {}; for (const x of g) println(x); }"))
            .toInclude("`G.next` is generic, so `for-of` can't call it");
    }

    test("should report a readonly pointer to an iterator that next changes") {
        expect(errors("struct C { n: i32, next(this: *C): ?i32 { return null; } }\nfunction f(r: readonly *C): void { for (const x of r) println(x); }"))
            .toInclude("`next` changes the `C`, but this pointer is readonly");
    }
}

describe("hxsCheckForOf") {
    test("should loop over a range, an array, a slice, and a string") {
        expect(errors("function f(s: i32[], a: i32[3]): void { for (const i of 0..3) println(i); for (const x of a) println(x); for (const y of s) println(y); for (const ch of \"ab\") println(ch); }"))
            .toBe("");
    }

    test("should give the index a usize") {
        expect(errors("function f(s: i32[]): usize { let n: usize = 0; for (const x, i of s) { n = i; println(x); } return n; }"))
            .toBe("");
    }

    test("should report a value that it can't loop over") {
        expect(errors("function f(): void { for (const x of 5) println(x); }")).toInclude("can't loop over `integer literal`");
    }

    test("should report a range of values that are not integers") {
        expect(errors("function f(a: f64, b: f64): void { for (const x of a..b) println(x); }"))
            .toInclude("a range needs integers, found `f64`");
    }
}

describe("hxsNarrowable") {
    test("should narrow a parameter") {
        expect(errors("function f(p: ?i32): i32 { if (p != null) { const v: i32 = p; return v; } return 0; }")).toBe("");
    }

    test("should not narrow a let") {
        expect(errors("function f(): i32 { let p: ?i32 = null; p = 1; if (p != null) { const v: i32 = p; return v; } return 0; }"))
            .toInclude("expected `i32`, found `?i32`");
    }
}

describe("hxsCollectNarrowing") {
    test("should narrow both sides of an and") {
        expect(errors("function f(a: ?i32, b: ?i32): i32 { if (a != null && b != null) { const x: i32 = a; const y: i32 = b; return x + y; } return 0; }"))
            .toBe("");
    }

    test("should narrow the else branch of an equality with null") {
        expect(errors("function f(a: ?i32): i32 { if (a == null) { return 0; } else { const x: i32 = a; return x; } }")).toBe("");
    }

    test("should narrow through a not") {
        expect(errors("function f(a: ?i32): i32 { if (!(a == null)) { const x: i32 = a; return x; } return 0; }")).toBe("");
    }

    test("should not narrow the then branch of an equality with null") {
        expect(errors("function f(a: ?i32): i32 { if (a == null) { const x: i32 = a; return x; } return 0; }"))
            .toInclude("expected `i32`, found `?i32`");
    }
}
