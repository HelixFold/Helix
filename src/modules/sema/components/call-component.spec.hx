/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { NodeKind } from "@constants/ast.constant";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstInit, hxAstFree, node } from "@models/ast.model";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxSema, HxModule, HxProgram } from "@structs/sema.struct";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxParse, hxParseModule } from "@modules/parser/parser.module";
import { hxLex, hxLexAppend, hxTokensFree } from "@modules/lexer/lexer.module";
import { addText, files, hxSourceFromString, hxSourceFree } from "@models/source.model";

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

/**
 * A second module that the tests import as `ns`.
 *
 * @since 1.0.0
 */

const Lib = "export const limit: i32 = 1;\nexport let count: i32 = 0;\nexport function twice(n: i32): i32 { return n * 2; }\nexport struct P { x: i32, make(): P { return P { x: 1 }; } }\n";

let out: Builder = undefined;
let outReady = false;
let targets: u32[4096] = undefined;

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
 * Checks a text as the root module of a two-module program, whose every import names the second module.
 *
 * @param ch - The state to fill, which must not move until `release`
 * @param text - The source text of the root module
 * @param path - The file path that the second module gets
 * @param lib - The source text of the second module
 * @param test - Whether to check a test build with the second module as its testing module
 *
 * @remarks
 * Lexes both files into one token stream and parses each as its own module of one tree.
 * Instead of resolving import paths, it points every `Import` node at module 2,
 * so the text may import the second module under any path.
 *
 * @since 1.0.0
 */

function checkProgram(ch: *Checked, text: string, path: readonly u8[*], lib: string, test: bool): void {
    ch.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&ch.src, "test.hx", text.ptr, text.len);
    void addText(&ch.src, path, lib);
    ch.tokens = HxTokens { kinds: null, starts: null, lens: null, len: 0, cap: 0, docs: null, docsLen: 0, docsCap: 0 };
    let second: u32 = 0;
    unsafe {
        void hxLexAppend(&ch.src, files(&ch.src)[0].start, files(&ch.src)[0].end, &ch.tokens, &ch.diags);
        second = ch.tokens.len;
        void hxLexAppend(&ch.src, files(&ch.src)[1].start, files(&ch.src)[1].end, &ch.tokens, &ch.diags);
    }
    hxAstInit(&ch.ast, &ch.src, &ch.tokens);
    let ok = true;
    let modules: HxModule[2] = undefined;
    modules[0] = HxModule { root: hxParseModule(&ch.ast, 0, &ch.diags, &ok), name: "test" };
    modules[1] = HxModule { root: hxParseModule(&ch.ast, second, &ch.diags, &ok), name: "lib" };
    for (const id of 0..ch.ast.nodesLen) {
        targets[id] = id > 0 && node(&ch.ast, id).kind == NodeKind.Import ? 2 : 0;
    }
    const program = HxProgram {
        modules: &modules[0], count: 2, importTargets: &targets, test, testingModule: test ? 2 : 0, pointerBytes: 8,
    };
    void hxSemaCheck(&ch.sema, &ch.ast, &program, &ch.diags);
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
 * Every error message of a check, one per line, or an empty string when it checks.
 *
 * @param ch - The state that a check filled
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Copies the messages into one module-level builder, so the result outlives `release` of the state.
 * Every call clears that builder, so the returned text stays valid only until the next call.
 *
 * @since 1.0.0
 */

function collect(ch: *Checked): string {
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

/**
 * Every error message that checking a text as a single-file program gives.
 *
 * @param text - The source text to check
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Runs `check`, collects the messages, and releases the state before it returns.
 * The result shares the builder of `collect`, so it stays valid only until the next call.
 *
 * @since 1.0.0
 */

function errors(text: string): string {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    return collect(&ch);
}

/**
 * Every error message that checking a text gives next to a second module at `lib.hx` made from `lib`.
 *
 * @param text - The source text of the root module
 * @param lib - The source text of the second module
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Checks an ordinary build, so the second module is never the testing module.
 * The result shares the builder of `collect`, so it stays valid only until the next call.
 *
 * @since 1.0.0
 */

function programErrors(text: string, lib: string): string {
    let ch: Checked = undefined;
    checkProgram(&ch, text, "lib.hx", lib, false);
    defer release(&ch);
    return collect(&ch);
}

let joined: Builder = undefined;
let joinedReady = false;

/**
 * Every error message that checking a shared prelude followed by a text gives, one per line.
 *
 * @param prelude - The declarations that the text relies on
 * @param text - The source text that follows the prelude
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Joins the two texts in a second module-level builder and checks the result as a single-file program.
 * The prelude and the text share one module, so a name declared in either is visible to both.
 *
 * @since 1.0.0
 */

function errorsAfter(prelude: string, text: string): string {
    if (!joinedReady) {
        joined = Builder.init(cAllocator());
        joinedReady = true;
    }
    joined.clear();
    joined.append(`${prelude}${text}`) catch unreachable;
    return errors(joined.text());
}

describe("hxsMarkUsed") {
    test("should keep a local read once from being reported as unused") {
        expect(errors("function f(): i32 { const a: i32 = 1; return a; }")).toBe("");
    }

    test("should report a local that nothing reads") {
        expect(errors("function f(): void { const a: i32 = 1; }")).toBe("unused local `a`\n");
    }
}

describe("hxsPlaceRoot") {
    test("should mark a local as changed through an element of its array") {
        expect(errors("function f(): i32 { let a: i32[2] = [1, 2]; a[0] = 3; return a[1]; }")).toBe("");
    }

    test("should mark a local as changed through one of its fields") {
        expect(errors("struct P { x: i32 }\nfunction f(): i32 { let p = P { x: 1 }; p.x = 2; return p.x; }")).toBe("");
    }

    test("should leave a local unchanged by a write through the pointer that it holds") {
        expect(errors("struct P { x: i32 }\nfunction f(q: *P): i32 { let p = q; p.x = 2; return p.x; }"))
            .toBe("`p` is never reassigned\n");
    }

    test("should leave a local unchanged by a write into the slice that it holds") {
        expect(errors("function f(s: u8[]): u8 { let t = s; t[0] = 1; return t[0]; }")).toBe("`t` is never reassigned\n");
    }
}

describe("hxsIsMutablePlace") {
    test("should refuse to assign a parameter") {
        expect(errors("function f(x: i32): void { x = 1; }")).toBe("parameter `x` can't be assigned\n");
    }

    test("should refuse to assign a constant") {
        expect(errors("function f(): void { const n: i32 = 1; n = 2; }")).toBe("`n` is a constant\n");
    }

    test("should refuse to assign a constant global") {
        expect(errors("const g: i32 = 1;\nfunction f(): void { g = 2; }")).toBe("`g` is a constant\n");
    }

    test("should accept assigning a let global") {
        expect(errors("let g: i32 = 1;\nfunction f(): void { g = 2; }")).toBe("");
    }

    test("should refuse to write through a readonly pointer") {
        expect(errors("function f(p: readonly *i32): void { *p = 1; }")).toBe("can't assign through a `readonly *i32`\n");
    }

    test("should refuse to write into a readonly slice") {
        expect(errors("function f(s: readonly u8[]): void { s[0] = 1; }")).toBe("can't assign through a `string`\n");
    }

    test("should refuse to write into a string literal") {
        expect(errors("function f(): void { \"ab\"[0] = 1; }")).toBe("can't assign through a `string literal`\n");
    }

    test("should refuse to assign the result of a call") {
        expect(errors("function g(): i32 { return 1; }\nfunction f(): void { g() = 1; }"))
            .toBe("this expression can't be assigned to\n");
    }

    test("should accept assigning a let global of another module") {
        expect(programErrors("import * as ns from \"lib\";\nfunction f(): void { ns.count = 1; }", Lib)).toBe("");
    }

    test("should refuse assigning a constant of another module") {
        expect(programErrors("import * as ns from \"lib\";\nfunction f(): void { ns.limit = 2; }", Lib)).toBe("`limit` is a constant\n");
    }
}

describe("hxsCheckPlace") {
    test("should mark an assigned local as changed") {
        expect(errors("function f(): i32 { let n: i32 = 1; n = 2; return n; }")).toBe("");
    }

    test("should leave a local that is never assigned to the unchanged check") {
        expect(errors("function f(): i32 { let n: i32 = 1; return n; }")).toBe("`n` is never reassigned\n");
    }
}

describe("hxsOuterLocal") {
    test("should refuse a capture of an enclosing function's local by an arrow function") {
        expect(errors("function f(n: i32): void { const g = (): i32 => n; void g; }"))
            .toBe("an arrow function can't capture `n`\n");
    }
}

describe("hxsCheckIdent") {
    test("should report a built-in type used as a value") {
        expect(errors("function f(): void { const a = i32; void a; }")).toInclude("`i32` is a type, not a value\n");
    }

    test("should report an unknown name") {
        expect(errors("function f(): void { const a = nope; void a; }")).toInclude("unknown name `nope`\n");
    }
}

describe("hxsFunctionValue") {
    test("should accept a function used as a value") {
        expect(errors("function add(a: i32, b: i32): i32 { return a + b; }\nfunction f(): i32 { const g = add; return g(1, 2); }"))
            .toBe("");
    }

    test("should refuse a generic function used as a value") {
        expect(errors("function id<T>(x: T): T { return x; }\nfunction f(): void { const g = id; void g; }"))
            .toInclude("`id` is generic, so it can't be used as a value on its own\n");
    }
}

describe("hxsCheckSymbolValue") {
    test("should report a struct used as a value") {
        expect(errors("struct P { x: i32 }\nfunction f(): void { const a = P; void a; }")).toInclude("`P` is a type, not a value\n");
    }

    test("should read an optional as its payload after a null check") {
        expect(errors("function f(x: ?i32): i32 { if (x != null) return x; return 0; }")).toBe("");
    }

    test("should keep the optional type without a null check") {
        expect(errors("function f(x: ?i32): i32 { return x; }")).toBe("expected `i32`, found `?i32`\n");
    }

    test("should report a module used as a value") {
        expect(programErrors("import * as ns from \"lib\";\nfunction f(): void { const m = ns; void m; }", Lib))
            .toBe("`ns` is a module, not a value\n");
    }
}

describe("hxsPromoteVararg") {
    const printf = "extern \"C\" function printf(fmt: readonly u8[*], ...): i32;\n";

    test("should promote numbers and strings for a C variadic call") {
        expect(errorsAfter(printf, "function f(n: u8): void { void printf(\"x\", n, 1, 2.0, \"s\"); }")).toBe("");
    }

    test("should refuse a slice") {
        expect(errorsAfter(printf, "function f(s: readonly u8[]): void { void printf(\"x\", s); }"))
            .toBe("a slice can't be passed to a C variadic function\n");
    }

    test("should refuse a bool") {
        expect(errorsAfter(printf, "function f(b: bool): void { void printf(\"x\", b); }"))
            .toBe("`bool` can't be passed to a C variadic function\n");
    }

    test("should refuse an enum") {
        expect(errorsAfter(printf, "enum Color { Red }\nfunction f(): void { void printf(\"x\", Color.Red); }"))
            .toBe("`Color` can't be passed to a C variadic function\n");
    }
}

describe("hxsCheckArgsUnknown") {
    test("should still check the arguments of a call to an unknown function") {
        expect(errors("function f(): void { nope(missing); }")).toBe("unknown function `nope`\nunknown name `missing`\n");
    }
}

describe("hxsCheckArgs") {
    const add = "function add(a: i32, b: i32): i32 { return a + b; }\n";

    test("should report too few arguments") {
        expect(errorsAfter(add, "function f(): i32 { return add(1); }")).toBe("`add` takes 2 arguments, but 1 was given\n");
    }

    test("should report too many arguments") {
        expect(errorsAfter(add, "function f(): i32 { return add(1, 2, 3); }")).toBe("`add` takes 2 arguments, but 3 were given\n");
    }

    test("should check each argument against its parameter") {
        expect(errorsAfter(add, "function f(): i32 { return add(1, true); }")).toBe("expected `i32`, found `bool`\n");
    }
}

describe("hxsCheckUnionInit") {
    const shape = "union Shape { Circle: f64, Empty }\n";

    test("should build a union from a variant and its value") {
        expect(errorsAfter(shape, "function f(): Shape { return Shape.Circle(1.0); }")).toBe("");
    }

    test("should refuse a value for a variant that carries none") {
        expect(errorsAfter(shape, "function f(): Shape { return Shape.Empty(1); }")).toBe("`Shape.Empty` carries no value\n");
    }

    test("should refuse more than one value") {
        expect(errorsAfter(shape, "function f(): Shape { return Shape.Circle(1.0, 2.0); }"))
            .toBe("`Shape.Circle` takes exactly one value of type `f64`\n");
    }
}

describe("hxsTypeNameRef") {
    test("should call a function of a struct through its name") {
        expect(errors("struct P { x: i32, make(): P { return P { x: 1 }; } }\nfunction f(): i32 { return P.make().x; }")).toBe("");
    }

    test("should call a function of a generic instance") {
        expect(errors("struct Box<T> { v: T, make(v: T): Box<T> { return Box<T> { v }; } }\nfunction f(): i32 { return Box<i32>.make(1).v; }"))
            .toBe("");
    }

    test("should call a function of a type from another module") {
        expect(programErrors("import * as ns from \"lib\";\nfunction f(): i32 { return ns.P.make().x; }", Lib)).toBe("");
    }
}

describe("hxsIsWriter") {
    test("should accept a dyn whose first method writes bytes and may fail") {
        expect(errors("interface W { put(this: *Self, bytes: readonly u8[]): void | Error; }\nfunction f(fm: Format, w: dyn W): void | Error { try fm.writeTo(w); }"))
            .toBe("");
    }

    test("should refuse a dyn whose write method returns something else") {
        expect(errors("interface W { write(this: *Self, bytes: readonly u8[]): usize; }\nfunction f(fm: Format, w: dyn W): void | Error { try fm.writeTo(w); }"))
            .toBe("`writeTo` needs a writer, found `dyn W`\n");
    }

    test("should refuse a dyn whose write method is not the first") {
        expect(errors("interface W { flush(this: *Self): void; write(this: *Self, bytes: readonly u8[]): void | Error; }\nfunction f(fm: Format, w: dyn W): void | Error { try fm.writeTo(w); }"))
            .toBe("`writeTo` needs a writer, found `dyn W`\n");
    }
}

describe("hxsCheckFormatWrite") {
    test("should refuse a method other than writeTo") {
        expect(errors("function f(fm: Format): void { void fm.render(); }")).toBe("`Format` has no method `render`\n");
    }

    test("should need exactly one writer") {
        expect(errors("function f(fm: Format): void | Error { try fm.writeTo(); }")).toBe("`writeTo` takes one writer\n");
    }

    test("should refuse an argument that is not a writer") {
        expect(errors("function f(fm: Format): void | Error { try fm.writeTo(1); }"))
            .toBe("`writeTo` needs a writer, found `integer literal`\n");
    }
}

describe("hxsMethodTypeArgsOk") {
    test("should refuse type arguments for a method without type parameters") {
        expect(errors("struct P { x: i32, get(this: P): i32 { return this.x; } }\nfunction f(p: P): i32 { return p.get<i32>(); }"))
            .toBe("`get` has no type parameters of its own\n");
    }
}

describe("hxsCheckMemberCall") {
    const point = "struct P { x: i32, bump(this: *P): void { this.x += 1; } get(this: P): i32 { return this.x; } make(): P { return P { x: 1 }; } }\n";

    test("should call a method on a let local and count it as a change") {
        expect(errorsAfter(point, "function f(): i32 { let p = P { x: 1 }; p.bump(); return p.get(); }")).toBe("");
    }

    test("should refuse a method that changes a constant") {
        expect(errorsAfter(point, "function f(): void { const p = P { x: 1 }; p.bump(); }"))
            .toBe("`bump` changes the `P`, but this value is constant\n");
    }

    test("should refuse a method that changes a temporary value") {
        expect(errorsAfter(point, "function f(): void { P { x: 1 }.bump(); }")).toBe("`bump` needs the address of a `P`\n");
    }

    test("should refuse a method that changes the value behind a readonly pointer") {
        expect(errorsAfter(point, "function f(p: readonly *P): void { p.bump(); }"))
            .toBe("`bump` changes the `P`, but this pointer is readonly\n");
    }

    test("should refuse a function without a receiver called on a value") {
        expect(errorsAfter(point, "function f(p: P): P { return p.make(); }")).toBe("`make` can't be called on a value\n");
    }

    test("should report a method on an optional that is not narrowed") {
        expect(errorsAfter(point, "function f(p: ?P): i32 { return p.get(); }")).toBe("`?P` might be null\n");
    }

    test("should report a method that does not exist") {
        expect(errorsAfter(point, "function f(p: P): void { p.nope(); }")).toBe("`P` has no method `nope`\n");
    }

    test("should report a function that the type does not have") {
        expect(errorsAfter(point, "function f(): void { P.nope(); }")).toBe("`P` has no function `nope`\n");
    }

    test("should refuse a function called on an interface") {
        expect(errors("interface I { m(this: *Self): void; }\nfunction f(): void { I.m(); }"))
            .toBe("`I` is an interface, so it has no functions of its own\n");
    }

    test("should call the function stored in a field") {
        expect(errors("struct P { cb: (v: i32) => i32 }\nfunction f(p: P): i32 { return p.cb(1); }")).toBe("");
    }

    test("should call a method through a dyn value") {
        expect(errors("interface I { m(this: *Self): i32; }\nfunction f(x: dyn I): i32 { return x.m(); }")).toBe("");
    }

    test("should report a method that the interface does not have") {
        expect(errors("interface I { m(this: *Self): i32; }\nfunction f(x: dyn I): i32 { return x.nope(); }"))
            .toBe("`dyn I` has no method `nope`\n");
    }

    test("should refuse type arguments for a method called through dyn") {
        expect(errors("interface I { m(this: *Self): i32; }\nfunction f(x: dyn I): i32 { return x.m<i32>(); }"))
            .toBe("methods called through `dyn` have no type parameters\n");
    }

    test("should call an exported function of another module") {
        expect(programErrors("import * as ns from \"lib\";\nfunction f(): i32 { return ns.twice(2); }", Lib)).toBe("");
    }

    test("should check the arguments of a function of another module") {
        expect(programErrors("import * as ns from \"lib\";\nfunction f(): i32 { return ns.twice(); }", Lib))
            .toBe("`twice` takes 1 argument, but 0 were given\n");
    }
}
