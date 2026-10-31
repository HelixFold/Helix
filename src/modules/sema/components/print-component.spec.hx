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

describe("hxsPrintable") {
    test("should print a struct whose fields can all be printed") {
        expect(errors("struct P { x: i32, y: f64 }\nfunction f(p: P): void { println(p); }")).toBe("");
    }

    test("should print optionals, arrays, slices, and pointers") {
        expect(errors("function f(a: ?i32, b: i32[3], s: string, p: *i32): void { println(`${a} ${b} ${s} ${p}`); }"))
            .toBe("");
    }

    test("should refuse an integer wider than 64 bits") {
        expect(errors("function f(x: i128): void { println(x); }")).toInclude("`i128` can't be printed");
    }

    test("should refuse a struct with a field that can't be printed") {
        expect(errors("struct P { x: i128 }\nfunction f(p: P): void { println(p); }")).toInclude("`P` can't be printed");
    }
}

describe("hxsCheckPrinted") {
    test("should give a literal a runtime type") {
        expect(errors("function f(): void { println(-1); println(1.5); println(\"text\"); }")).toBe("");
    }

    test("should refuse an error union") {
        expect(errors("error Problem { Bad }\nfunction work(): u32 | Problem { return 1; }\nfunction f(): void { println(work()); }"))
            .toInclude("`u32 | Problem` can't be printed");
    }
}

describe("hxsDecodeTemplateText") {
    test("should accept escapes in the text between substitutions") {
        expect(errors("function f(n: i32): void { println(`a\\t${n}\\n\\u{41}`); }")).toBe("");
    }
}

describe("hxsCheckTemplateParts") {
    test("should report a substitution without a value") {
        expect(errors("function nothing(): void {}\nfunction f(): void { println(`result ${nothing()}`); }"))
            .toInclude("`void` can't be printed");
    }
}

describe("hxsCheckPrint") {
    test("should accept one template string") {
        expect(errors("function f(n: i32): void { print(`total ${n}`); eprintln(`x`); }")).toBe("");
    }

    test("should refuse more than one argument") {
        expect(errors("function f(): void { print(\"a\", \"b\"); }")).toInclude("`print` takes one template string or value");
    }

    test("should refuse a call without arguments") {
        expect(errors("function f(): void { eprintln(); }")).toInclude("`eprintln` takes one template string or value");
    }
}

describe("hxsIndirectCall") {
    test("should call through a variable of function type") {
        expect(errors("function add(a: i32, b: i32): i32 { return a + b; }\nfunction f(): i32 { const g = add; return g(1, 2); }"))
            .toBe("");
    }

    test("should refuse to call a value that is not a function") {
        expect(errors("function f(): void { const n: i32 = 1; void n(2); }"))
            .toInclude("`i32` is not a function, so it can't be called");
    }

    test("should check the arguments against the function type") {
        expect(errors("function add(a: i32, b: i32): i32 { return a + b; }\nfunction f(): i32 { const g = add; return g(1); }"))
            .toInclude("takes 2 arguments, but 1 was given");
    }
}
