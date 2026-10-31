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

describe("declareUnset") {
    test("should leave a local declared = undefined without a value") {
        expect(errors("function f(): i32 { let x: i32 = undefined; return x; }"))
            .toInclude("`x` is read before it's given a value");
    }

    test("should leave a local with an initial value alone") {
        expect(errors("function f(): i32 { const x: i32 = 1; return x; }")).toBe("");
    }
}

describe("noteRead") {
    test("should report a read inside a larger expression") {
        expect(errors("function f(): i32 { let x: i32 = undefined; const y = x + 1; return y; }"))
            .toInclude("`x` is read before");
    }
}

describe("noteWrite") {
    test("should give the local a value once it is assigned") {
        expect(errors("function f(): i32 { let x: i32 = undefined; x = 2; return x; }")).toBe("");
    }

    test("should still report a read of the local on the right of its own first assignment") {
        expect(errors("function f(): i32 { let x: i32 = undefined; x = x + 1; return x; }"))
            .toInclude("`x` is read before");
    }

    test("should count taking the address as giving a value") {
        expect(errors("function set(p: *i32): void { *p = 1; }\nfunction f(): i32 { let x: i32 = undefined; set(&x); return x; }"))
            .toBe("");
    }
}

describe("noteNotRead") {
    test("should not count the length of an array as a read") {
        expect(errors("function f(): usize { let b: u8[4] = undefined; return b.len; }")).not.toInclude("read before");
    }
}

describe("flushReads") {
    test("should report each local once, at its first read") {
        const text = errors("function f(): i32 { let x: i32 = undefined; const a = x; const b = x; return a + b; }");

        expect(text).toInclude("`x` is read before it's given a value\n");
        expect(text).not.toInclude("value\n`x` is read before");
    }
}

describe("saveUnset") {
    test("should keep a local unset after an if that assigns it on one branch only") {
        expect(errors("function f(ok: bool): i32 { let x: i32 = undefined; if (ok) x = 1; return x; }"))
            .toInclude("`x` is read before");
    }
}

describe("restoreUnset") {
    test("should start the else branch from the state before the if") {
        expect(errors("function f(ok: bool): i32 { let x: i32 = undefined; if (ok) x = 1; else { const y = x; x = y; } return x; }"))
            .toInclude("`x` is read before");
    }
}

describe("mergeUnset") {
    test("should give the local a value when every branch assigns it") {
        expect(errors("function f(ok: bool): i32 { let x: i32 = undefined; if (ok) x = 1; else x = 2; return x; }"))
            .toBe("");
    }

    test("should leave out a branch that returns") {
        expect(errors("function f(ok: bool): i32 { let x: i32 = undefined; if (!ok) return 0; x = 1; return x; }"))
            .toBe("");
    }
}

describe("isUnset") {
    test("should treat a parameter as always having a value") {
        expect(errors("function f(x: i32): i32 { return x; }")).toBe("");
    }
}
