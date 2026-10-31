/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { hxDiagListFree } from "@models/diagnostic.model";
import { NodeKind, NoToken } from "@constants/ast.constant";
import { hxParseModule } from "@modules/parser/parser.module";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxSema, HxModule, HxProgram } from "@structs/sema.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { HxAst, HxImportData } from "@models/structs/ast-model.struct";
import { hxLexAppend, hxTokensFree } from "@modules/lexer/lexer.module";
import { moduleRoot } from "@modules/sema/components/imports.component";
import { hxSemaCheck, hxSemaFree, hxSemaExport } from "@modules/sema/sema.module";
import { addText, files, hxSourceFromString, hxSourceFree } from "@models/source.model";
import { hxAstInit, hxAstFree, node, extraAt, record, tokenText } from "@models/ast.model";

/**
 * Tests
 */

/**
 * A program of two or three modules with its tokens, tree, checker state, and diagnostics after one check.
 *
 * @remarks
 * One source holds every module text, and `targets` maps each import node to its module plus 1.
 * The parser and the checker keep pointers into this state,
 * so a test declares it on its stack and lets {@link check} fill it in place.
 *
 * @since 1.0.0
 */

struct Program {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
    sema: HxSema,
    diags: HxDiagList,
    modules: HxModule[3],
    targets: u32[4096],
    program: HxProgram,
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
 * Lexes, parses, and checks the modules `a.hx`, `b.hx`, and `c.hx`, in a state that must stay where it is.
 *
 * @param p - The state that receives every stage
 * @param a - The text of `a.hx`, the root module
 * @param b - The text of `b.hx`
 * @param c - The text of `c.hx`, or an empty string to leave it out
 *
 * @remarks
 * An empty third text leaves `c.hx` out.
 * An import path names its target by the letter before its closing quote, so `"./b"` means `b.hx`.
 *
 * @since 1.0.0
 */

function check(p: *Program, a: string, b: string, c: string): void {
    const all: string[3] = [ a, b, c ];
    const texts = c.len > 0 ? all[0..3] : all[0..2];
    p.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&p.src, "a.hx", texts[0].ptr, texts[0].len);
    void addText(&p.src, "b.hx", b);
    if (c.len > 0) void addText(&p.src, "c.hx", c);
    p.tokens = HxTokens { kinds: null, starts: null, lens: null, len: 0, cap: 0, docs: null, docsLen: 0, docsCap: 0 };
    let starts: u32[3] = undefined;
    for (const m of 0..texts.len) {
        starts[m] = p.tokens.len;
        unsafe {
            void hxLexAppend(&p.src, files(&p.src)[m].start, files(&p.src)[m].end, &p.tokens, &p.diags);
        }
    }
    hxAstInit(&p.ast, &p.src, &p.tokens);
    let ok = true;
    for (const m of 0..texts.len) {
        p.modules[m] = HxModule { root: hxParseModule(&p.ast, starts[m], &p.diags, &ok), name: null };
    }
    for (const i of 0..4096) p.targets[i] = 0;
    for (const m of 0..texts.len) {
        const file = node(&p.ast, p.modules[m].root);
        for (const i of file.a..file.b) {
            const decl = extraAt(&p.ast, i);
            if (node(&p.ast, decl).kind != NodeKind.Import) continue;
            const data = record<HxImportData>(&p.ast, node(&p.ast, decl).a);
            if (data.pathToken == NoToken) continue;
            const path = tokenText(&p.ast, data.pathToken);
            const letter = path[path.len - 2];
            p.targets[decl] = (letter - 'a') as u32 + 1;
        }
    }
    p.ast.root = p.modules[0].root;
    p.program = HxProgram {
        modules: &p.modules[0], count: texts.len as u32, importTargets: &p.targets, test: false, testingModule: 0,
        pointerBytes: 8,
    };
    void hxSemaCheck(&p.sema, &p.ast, &p.program, &p.diags);
}

/**
 * Releases everything that one check allocated.
 *
 * @param p - The state that {@link check} filled
 *
 * @remarks
 * Frees the stages in the reverse order of their creation, so the source goes last.
 * A test must not read the state afterwards.
 *
 * @since 1.0.0
 */

function release(p: *Program): void {
    hxSemaFree(&p.sema);
    hxAstFree(&p.ast);
    hxTokensFree(&p.tokens);
    hxDiagListFree(&p.diags);
    hxSourceFree(&p.src);
}

/**
 * Every error message that checking the modules gives with its hint, one per line, or an empty string when they check.
 *
 * @param a - The text of `a.hx`, the root module
 * @param b - The text of `b.hx`
 * @param c - The text of `c.hx`, or an empty string to leave it out
 * @returns The messages, each followed by a newline
 *
 * @remarks
 * A hint follows its message in parentheses on the same line.
 * The text lives in the shared builder, which the next call clears,
 * so a test compares the result before it checks another source.
 *
 * @since 1.0.0
 */

function errors(a: string, b: string, c: string): string {
    let p: Program = undefined;
    check(&p, a, b, c);
    defer release(&p);
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    for (const i of 0..p.diags.itemsLen) {
        unsafe {
            const d = p.diags.items![i];
            out.append(`${cString(d.message)}`) catch unreachable;
            if (const h = d.hint) out.append(` (hint: ${cString(h)})`) catch unreachable;
            out.append("\n") catch unreachable;
        }
    }
    return out.text();
}

describe("moduleRoot") {
    test("should give the file node of each module") {
        let p: Program = undefined;
        check(&p, "export const a = 1;", "export const b = 2;\nexport const c = 3;", "");
        defer release(&p);
        const first = node(&p.ast, moduleRoot(&p.sema, 0));
        const second = node(&p.ast, moduleRoot(&p.sema, 1));

        expect(first.kind).toBe(NodeKind.File);
        expect(first.b - first.a).toBe(1);
        expect(second.b - second.a).toBe(2);
    }
}

describe("hxsBindImport") {
    test("should let the same name be imported twice from the same module") {
        expect(errors(
            "import { f } from \"./b\";\nimport { f } from \"./b\";\nexport function main(): void { f(); }",
            "export function f(): void {}",
            "",
        )).toBe("");
    }

    test("should report an import that takes a name the module already declares") {
        expect(errors(
            "import { f } from \"./b\";\nfunction f(): void {}\nexport function main(): void { f(); }",
            "export function f(): void {}",
            "",
        )).toInclude("`f` is already declared");
    }
}

describe("hxsProcessImport") {
    test("should bind a name under its alias") {
        expect(errors(
            "import { f as g } from \"./b\";\nexport function main(): void { g(); }",
            "export function f(): void {}",
            "",
        )).toBe("");
    }

    test("should report a name that the target does not export") {
        expect(errors(
            "import { nope } from \"./b\";\nexport function main(): void { nope(); }",
            "export function f(): void {}",
            "",
        )).toInclude("\"./b\" has no export named `nope`");
    }

    test("should hint at export for a name that is private in the target") {
        expect(errors(
            "import { f } from \"./b\";\nexport function main(): void { f(); }",
            "function f(): void {}\nexport function g(): void { f(); }",
            "",
        )).toInclude("has no export named `f` (hint: it exists but is private; add `export` to its declaration)");
    }

    test("should export every exported name again for export star") {
        let p: Program = undefined;
        check(&p, "export * from \"./b\";", "export const x = 1;\nconst y = 2;", "");
        defer release(&p);

        expect(hxSemaExport(&p.sema, 0, "x") != 0).toBeTrue();
        expect(hxSemaExport(&p.sema, 0, "y")).toBe(0);
    }
}

describe("hxsProcessImports") {
    test("should follow a re-export through a module listed before its source") {
        expect(errors(
            "import { f } from \"./b\";\nexport function main(): void { f(); }",
            "export { f } from \"./c\";",
            "export function f(): void {}",
        )).toBe("");
    }
}

describe("hxsModuleMentions") {
    test("should count a use inside a generic that nothing instantiates") {
        expect(errors(
            "import { f } from \"./b\";\nfunction g<T>(x: T): T { f(); return x; }\nexport function main(): void {}",
            "export function f(): void {}",
            "",
        )).not.toInclude("unused import");
    }
}

describe("hxsReportUnusedImports") {
    test("should report an import that the module never uses") {
        expect(errors(
            "import { f } from \"./b\";\nexport function main(): void {}",
            "export function f(): void {}",
            "",
        )).toInclude("unused import `f` (hint: remove it)");
    }

    test("should leave a re-exported name alone") {
        expect(errors("export { f } from \"./b\";", "export function f(): void {}", "")).toBe("");
    }
}

describe("hxsModuleMember") {
    test("should resolve a name through a namespace import") {
        expect(errors(
            "import * as ns from \"./b\";\nexport function main(): void { ns.f(); }",
            "export function f(): void {}",
            "",
        )).toBe("");
    }

    test("should report a name that the namespace does not export") {
        expect(errors(
            "import * as ns from \"./b\";\nexport function main(): void { ns.g(); }",
            "export function f(): void {}",
            "",
        )).toInclude("`ns` has no export named `g`");
    }

    test("should resolve a type through a namespace import") {
        expect(errors(
            "import * as ns from \"./b\";\nexport function main(): void { const p: ns.P = ns.P { x: 1 }; void p; }",
            "export struct P { x: i32 }",
            "",
        )).toBe("");
    }
}
