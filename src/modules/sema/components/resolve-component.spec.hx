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
 * The shared output builder, emptied.
 *
 * @returns The shared builder, without any text
 *
 * @remarks
 * Creates the builder with the C allocator on the first call and only clears it afterwards,
 * so every helper that returns builder text shares one buffer.
 *
 * @since 1.0.0
 */

function cleared(): *Builder {
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    return &out;
}

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
 * Every error message that checking a text gives with its hint, one per line, or an empty string when it checks.
 *
 * @param text - The program source
 * @returns The messages, each followed by a newline
 *
 * @remarks
 * A hint follows its message in parentheses on the same line.
 * The text lives in the shared builder, which the next call clears,
 * so a test compares the result before it checks another source.
 *
 * @since 1.0.0
 */

function errors(text: string): string {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    const b = cleared();
    for (const i of 0..ch.diags.itemsLen) {
        unsafe {
            const d = ch.diags.items![i];
            b.append(`${cString(d.message)}`) catch unreachable;
            if (const h = d.hint) b.append(` (hint: ${cString(h)})`) catch unreachable;
            b.append("\n") catch unreachable;
        }
    }
    return b.text();
}

describe("hxsResolveType") {
    test("should resolve built-in, declared, and aliased names") {
        const text = "struct P { x: i32 }\ntype Q = P;\nfunction f(p: Q, n: u64): u64 { void p; return n; }";

        expect(errors(text)).toBe("");
    }

    test("should report an unknown type") {
        expect(errors("function f(p: Nope): void { void p; }")).toInclude("unknown type `Nope`");
    }

    test("should report a value used as a type") {
        expect(errors("const v: i32 = 1;\nfunction f(p: v): void { void p; }")).toInclude("`v` is a value, not a type");
    }

    test("should report a generic type named without type arguments") {
        expect(errors("struct Box<T> { value: T }\nfunction f(b: *Box): void { void b; }"))
            .toInclude("`Box` is generic, so it needs type arguments (hint: write them in angle brackets");
    }

    test("should report an interface used as a type and suggest dyn") {
        expect(errors("interface W { write(this: *Self): void; }\nfunction f(w: *W): void { void w; }"))
            .toInclude("`W` is an interface, not a type (hint: take any implementation with `dyn W`");
    }

    test("should resolve pointers, slices, optionals, and readonly") {
        expect(errors("function f(a: ?*i32, b: readonly u8[], c: u8[*]): void { void a; void b; void c; }")).toBe("");
    }

    test("should take an array length that folds at compile time") {
        expect(errors("const N = 2;\nfunction f(a: u8[N * 2]): u8 { return a[3]; }")).toBe("");
    }

    test("should report an array length that is negative or not known at compile time") {
        expect(errors("function f(a: u8[-1]): void { void a; }"))
            .toInclude("array length must be a non-negative integer known at compile time");
        expect(errors("let n: usize = 2;\nfunction f(a: u8[n]): void { void a; }"))
            .toInclude("array length must be a non-negative integer known at compile time");
    }

    test("should report readonly in front of a type that is not a pointer or a slice") {
        expect(errors("function f(a: readonly i32): void { void a; }"))
            .toInclude("`readonly` applies to pointers and slices, not `i32`");
    }

    test("should report an optional of an optional") {
        expect(errors("function f(a: ?void): void { void a; }")).toInclude("`?void` is not a valid optional");
    }

    test("should report an error union whose right side is not an error set") {
        expect(errors("function f(): i32 | u8 { return 1; }")).toInclude("`u8` is not an error set");
    }

    test("should report an error union with two error sets") {
        expect(errors("error A { X }\nerror B { Y }\nfunction f(): i32 | A | B { return 1; }"))
            .toInclude("a type can have only one error set");
    }

    test("should resolve a function type") {
        expect(errors("function f(g: (a: i32) => bool): bool { return g(1); }")).toBe("");
    }

    test("should report a variadic function type that is not extern C") {
        expect(errors("function f(g: (a: i32, ...) => void): void { void g; }"))
            .toInclude("only a C function type can be variadic");
    }

    test("should report a comptime parameter in a function type") {
        expect(errors("function f(g: (comptime a: i32) => void): void { void g; }"))
            .toInclude("a function type can't have `comptime` parameters");
    }

    test("should resolve dyn of an interface") {
        expect(errors("interface W { write(this: *Self): void; }\nfunction f(w: dyn W): void { void w; }")).toBe("");
    }

    test("should resolve a generic instance") {
        expect(errors("struct Box<T> { value: T }\nfunction f(b: Box<i32>): i32 { return b.value; }")).toBe("");
    }
}
