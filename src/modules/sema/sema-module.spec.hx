/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { hxAstFree } from "@models/ast.model";
import { Ctx, HxSema } from "@structs/sema.struct";
import { NodeKind } from "@constants/ast.constant";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { symbolOf, tokenText } from "@modules/sema/components/base.component";
import { HxSymGeneric, HxSymTemplateMethod, HxSymFunction } from "@constants/sema.constant";
import { hxSemaExport, hxsHasGenerics, hxsHasComptimeParams, hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";

/**
 * Tests
 */

/**
 * A source with its tokens, tree, checker state, and diagnostics after one check.
 *
 * @remarks
 * The parser and the checker keep pointers into the source and the token list,
 * so a test declares the state on its stack and lets {@link check} fill it in place.
 * The `ok` field keeps the result of `hxSemaCheck`.
 *
 * @since 1.0.0
 */

struct Checked {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
    sema: HxSema,
    diags: HxDiagList,
    ok: bool,
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
 * The result of `hxSemaCheck` goes into the `ok` field.
 *
 * @since 1.0.0
 */

function check(ch: *Checked, text: string): void {
    ch.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&ch.src, "test.hx", text.ptr, text.len);
    void hxLex(&ch.src, &ch.tokens, &ch.diags);
    void hxParse(&ch.src, &ch.tokens, &ch.ast, &ch.diags);
    ch.ok = hxSemaCheck(&ch.sema, &ch.ast, null, &ch.diags);
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
 * A checker context over the tables of a finished check, outside any function and any instance.
 *
 * @param ch - The finished check
 * @returns The context
 *
 * @remarks
 * Only the table pointers, the instance, and the module are set, and every other field stays undefined,
 * so the context suits lookups such as `symbolOf` and `tokenText` but not checking.
 *
 * @since 1.0.0
 */

function contextOf(ch: *Checked): Ctx {
    let c: Ctx = undefined;
    c.sema = &ch.sema;
    c.ast = &ch.ast;
    c.tokens = &ch.tokens;
    unsafe {
        c.text = @ptrCast(?readonly u8[*], ch.src.text);
    }
    c.types = &ch.sema.types;
    c.instance = 0;
    c.module = 0;
    return c;
}

/**
 * The index of the first node of a kind, or 0.
 *
 * @param ch - The finished check
 * @param kind - The node kind to look for
 * @returns The node index, or 0 when no node has the kind
 *
 * @remarks
 * Scans the nodes in creation order from node 1, so 0 stays free to mean that nothing matched.
 *
 * @since 1.0.0
 */

function findNode(ch: readonly *Checked, kind: NodeKind): u32 {
    for (const i of 1..ch.ast.nodesLen) {
        unsafe {
            if (ch.ast.nodes![i].kind == kind) return i;
        }
    }
    return 0;
}

/**
 * The flags of the symbol of a function whose name is the given text, or 0 when there is none.
 *
 * @param ch - The finished check
 * @param name - The function name
 * @returns The symbol flags
 *
 * @remarks
 * Compares the names byte by byte across every function symbol and returns the first match,
 * so the helper cannot tell apart two functions that share a name.
 *
 * @since 1.0.0
 */

function functionFlags(ch: *Checked, name: string): u16 {
    const c = contextOf(ch);
    for (const i of 1..ch.sema.symbols.len) {
        const sym = symbolOf(&c, i);
        if (sym.kind != HxSymFunction as u8) continue;
        const text = tokenText(&c, sym.token);
        if (text.len != name.len) continue;
        let same = true;
        for (const byte, j of text) {
            if (byte != name[j]) same = false;
        }
        if (same) return sym.flags;
    }
    return 0;
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

describe("hxsHasGenerics") {
    test("should find the type parameters of a function") {
        let ch: Checked = undefined;
        check(&ch, "function first<T>(a: T, _b: T): T { return a; }");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsHasGenerics(&c, findNode(&ch, NodeKind.Function))).toBe(true);
    }

    test("should find the type parameters of a struct") {
        let ch: Checked = undefined;
        check(&ch, "struct Box<T> { value: T }");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsHasGenerics(&c, findNode(&ch, NodeKind.Struct))).toBe(true);
    }

    test("should report a plain function as not generic") {
        let ch: Checked = undefined;
        check(&ch, "function f(): void {}");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsHasGenerics(&c, findNode(&ch, NodeKind.Function))).toBe(false);
    }
}

describe("hxsHasComptimeParams") {
    test("should find a comptime parameter") {
        let ch: Checked = undefined;
        check(&ch, "function f(comptime n: u32): u32 { return n; }");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsHasComptimeParams(&c, findNode(&ch, NodeKind.Function))).toBe(true);
    }

    test("should report ordinary parameters as not comptime") {
        let ch: Checked = undefined;
        check(&ch, "function f(n: u32): u32 { return n; }");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsHasComptimeParams(&c, findNode(&ch, NodeKind.Function))).toBe(false);
    }
}

describe("hxsDeclareType") {
    test("should declare a struct whose name later code can use") {
        expect(errors("struct Point { x: i32 }\nconst p: Point = Point { x: 1 };")).toBe("");
    }

    test("should report a generic enum as unsupported") {
        expect(errors("enum E<T> { A }")).toInclude("generic enums are not supported yet");
    }

    test("should mark a method with its own type parameters as a template method") {
        let ch: Checked = undefined;
        check(&ch, "struct Box { value: i32, function plain(this: *Box): i32 { return this.value; }, function pick<U>(this: *Box, u: U): U { return u; } }");
        defer release(&ch);

        expect((functionFlags(&ch, "pick") & (HxSymTemplateMethod as u16)) != 0).toBe(true);
        expect((functionFlags(&ch, "plain") & (HxSymGeneric as u16)) != 0).toBe(false);
    }

    test("should mark the methods of a generic struct as generic but not as template methods") {
        let ch: Checked = undefined;
        check(&ch, "struct Box<T> { value: T, function get(this: *Box<T>): T { return this.value; } }");
        defer release(&ch);
        const flags = functionFlags(&ch, "get");

        expect((flags & (HxSymGeneric as u16)) != 0).toBe(true);
        expect((flags & (HxSymTemplateMethod as u16)) != 0).toBe(false);
    }
}

describe("hxSemaCheck") {
    test("should return true for a program without errors") {
        let ch: Checked = undefined;
        check(&ch, "function add(a: i32, b: i32): i32 { return a + b; }");
        defer release(&ch);

        expect(ch.ok).toBe(true);
    }

    test("should return false after an error") {
        let ch: Checked = undefined;
        check(&ch, "const x: u8 = 300;");
        defer release(&ch);

        expect(ch.ok).toBe(false);
    }

    test("should let a declaration use a name declared after it") {
        expect(errors("function f(): i32 { return g(); }\nfunction g(): i32 { return limit; }\nconst limit: i32 = 3;")).toBe("");
    }

    test("should report a global that depends on itself") {
        expect(errors("const a: i32 = b;\nconst b: i32 = a;")).toInclude("depends on itself");
    }

    test("should report imports in a single-file check as unsupported") {
        expect(errors("import { x } from \"./other\";")).toInclude("imports in a single-file check are not supported yet");
    }

    test("should fold a constant at compile time and report its overflow") {
        expect(errors("const big: u8 = 200 + 100;")).toInclude("integer 300 does not fit in `u8`");
    }
}

describe("hxSemaFree") {
    test("should release a state after a failed check") {
        let ch: Checked = undefined;
        check(&ch, "const x: bool = 1;");
        release(&ch);

        expect(ch.ok).toBe(false);
    }
}

describe("hxSemaExport") {
    test("should find an exported function") {
        let ch: Checked = undefined;
        check(&ch, "export function visible(): void {}");
        defer release(&ch);
        const sym = hxSemaExport(&ch.sema, 0, "visible");
        const c = contextOf(&ch);

        expect(sym != 0).toBe(true);
        unsafe {
            expect(symbolOf(&c, sym).kind).toBe(HxSymFunction as u8);
        }
    }

    test("should return 0 for a name that is declared but not exported") {
        let ch: Checked = undefined;
        check(&ch, "function hidden(): void {}");
        defer release(&ch);

        expect(hxSemaExport(&ch.sema, 0, "hidden")).toBe(0);
    }

    test("should return 0 for a name that is not declared") {
        let ch: Checked = undefined;
        check(&ch, "export function visible(): void {}");
        defer release(&ch);

        expect(hxSemaExport(&ch.sema, 0, "missing")).toBe(0);
    }
}
