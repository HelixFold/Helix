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

describe("hxsCheckTernary") {
    test("should require a bool condition") {
        expect(errors("const n: i32 = 1 ? 2 : 3;\n")).toInclude("expected `bool`, found `integer literal`");
    }

    test("should let each branch see what the condition proves") {
        expect(errors("struct P { x: i32 }\nfunction f(p: ?*P): i32 { return p != null ? p.x : 0; }\n")).toBe("");
    }

    test("should take the constant value of the branch that a constant condition picks") {
        expect(errors("const v = true ? 303 : 1;\nconst p: u8 = v;\n")).toInclude("integer 303 does not fit in `u8`");
    }
}

describe("hxsCheckArrow") {
    test("should infer the result type from an expression body") {
        expect(errors("function f(): i32 { const inc = (a: i32) => a + 1; return inc(1); }\n")).toBe("");
    }

    test("should report an expression body whose type it cannot tell") {
        expect(errors("const f = () => null;\n")).toInclude("can't tell what type this arrow function returns");
    }

    test("should report a block body that can end without returning") {
        expect(errors("const f = (): i32 => { };\n"))
            .toInclude("this arrow function can reach its end without returning a `i32`");
    }

    test("should report a void parameter") {
        expect(errors("const f = (x: void): i32 => 1;\n")).toInclude("a parameter can't be `void`");
    }

    test("should not let the body see the locals of the enclosing function") {
        expect(errors("function f(): i32 { const k: i32 = 1; const g = (): i32 => k; return g(); }\n"))
            .toInclude("an arrow function can't capture `k`");
    }
}

describe("hxsEnsureBody") {
    test("should check a function before running it at compile time") {
        expect(errors("function sq(x: i32): i32 { return x * x; }\nconst xs: u8[comptime sq(2)] = [1, 2, 3];\n"))
            .toInclude("`u8[4]` needs 4 elements, found 3");
    }

    test("should report a function that runs itself at compile time") {
        expect(errors("function f(): i32 { return comptime f(); }\n"))
            .toInclude("`f` runs at compile time while it's still being checked");
    }
}

describe("hxsEvalHost") {
    test("should let the interpreter call an arrow function") {
        expect(errors("const sq = (x: i32): i32 => x * x;\nconst xs: u8[comptime sq(2)] = [1, 2, 3];\n"))
            .toInclude("`u8[4]` needs 4 elements, found 3");
    }
}

describe("hxsCheckComptimeExpr") {
    test("should replace the expression with its value") {
        expect(errors("const n = comptime 2 + 3;\nconst p: u8 = n + 251;\n"))
            .toInclude("integer 256 does not fit in `u8`");
    }

    test("should not run an operand that has errors") {
        expect(errors("const n: i32 = comptime missing();\n")).toBe("unknown function `missing`\n");
    }
}

describe("hxsCheckComptimeBlock") {
    test("should check a block inside a function in its own scope") {
        expect(errors("function f(): void { comptime { const x: u8 = 300; } }\n"))
            .toInclude("integer 300 does not fit in `u8`");
    }
}

describe("hxsRunComptimeBlock") {
    test("should check a top-level block like the body of a void function") {
        expect(errors("comptime { return 1; }\n"))
            .toInclude("this function returns `void`, so `return` takes no value");
    }

    test("should run a top-level block") {
        expect(errors("comptime { @panic(\"boom\"); }\n")).toInclude("panic at compile time: boom");
    }
}

describe("hxsInfer") {
    test("should report a template string outside a Format parameter") {
        expect(errors("function f(): void { const s = `x`; }\n"))
            .toInclude("a template string can only be passed to a `Format` parameter");
    }

    test("should report a generic type where a value belongs") {
        expect(errors("struct Box<T> { v: T }\nfunction f(): void { const x = Box<i32>; }\n"))
            .toInclude("a generic type is not a value");
    }

    test("should give a return inside an expression the type noreturn") {
        expect(errors("function f(p: ?i32): i32 { const x: i32 = p ?? return 0; return x; }\n")).toBe("");
    }
}

describe("hxsCheckExpr") {
    test("should convert the expression to the expected type") {
        expect(errors("const x: u8 = 300;\n")).toInclude("integer 300 does not fit in `u8`");
        expect(errors("const x: i64 = 1;\n")).toBe("");
    }
}
