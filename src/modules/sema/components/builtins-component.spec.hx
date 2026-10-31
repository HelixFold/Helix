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

describe("hxsCheckBuiltin") {
    describe("@sizeOf and @alignOf") {
        test("should give an integer constant") {
            expect(errors("function f(): bool { return @sizeOf(u32); }")).toInclude("found `integer literal`");
        }

        test("should fold the size into constant arithmetic") {
            expect(errors("function f(): u8 { const m: u8 = @sizeOf(u64) + 250; return m; }"))
                .toInclude("integer 258 does not fit in `u8`");
        }

        test("should report a call with more than one argument") {
            expect(errors("function f(): usize { return @sizeOf(u32, u8); }")).toInclude("`@sizeOf` takes one type: `@sizeOf(T)`");
        }
    }

    describe("@truncate") {
        test("should give the target integer type") {
            expect(errors("function f(): bool { return @truncate(u8, 300); }")).toInclude("expected `bool`, found `u8`");
        }

        test("should fold a constant into the target type") {
            expect(errors("function f(): u8 { const x: u8 = @truncate(u8, 300); const y: u8 = x + 255; return y; }"))
                .toInclude("integer overflow in a constant expression");
        }

        test("should report a value that is not an integer") {
            expect(errors("function f(x: f64): u8 { return @truncate(u8, x); }"))
                .toInclude("`@truncate` converts integers, found `f64` to `u8`");
        }

        test("should report a call without a value") {
            expect(errors("function f(): u8 { return @truncate(u8); }"))
                .toInclude("`@truncate` takes a type and a value: `@truncate(u8, x)`");
        }
    }

    describe("@panic and @compileError") {
        test("should report a panic with two messages") {
            expect(errors("function f(): i32 { @panic(\"a\", \"b\"); }")).toInclude("`@panic` takes a message: `@panic(\"message\")`");
        }

        test("should accept a panic as the end of a function") {
            expect(errors("function f(): i32 { @panic(\"stop\"); }")).toBe("");
        }

        test("should report the message of a compile error in a used function") {
            expect(errors("function f(): i32 { @compileError(\"nope\"); }")).toBe("nope\n");
        }

        test("should not fire in a function that nothing reaches from main") {
            expect(errors("function g(): i32 { @compileError(\"nope\"); }\nfunction main(): void { }")).toBe("");
        }

        test("should fire in a function that main calls") {
            expect(errors("function g(): i32 { @compileError(\"nope\"); }\nfunction main(): void { void g(); }")).toBe("nope\n");
        }

        test("should not fire in a branch that a constant condition rules out") {
            expect(errors("function f(): i32 { if (comptime false) { @compileError(\"nope\"); } return 0; }")).toBe("");
        }

        test("should report a message that is not known while compiling") {
            expect(errors("function f(m: string): i32 { @compileError(m); }"))
                .toInclude("`@compileError` needs a message known while compiling");
        }
    }

    describe("@compileLog") {
        test("should log values and types and fail the build") {
            expect(errors("function f(): i32 { const x = 3; @compileLog(x, u8); return 0; }"))
                .toInclude("compile log: x = 3, u8 = u8");
        }

        test("should log the type of a value known only at run time") {
            expect(errors("function f(n: i32): i32 { @compileLog(n); return n; }"))
                .toInclude("compile log: n: i32 (known only when the program runs)");
        }
    }

    describe("@ptrCast") {
        test("should require unsafe") {
            expect(errors("function f(p: *u8): *i32 { return @ptrCast(*i32, p); }")).toInclude("`@ptrCast` needs `unsafe { }`");
        }

        test("should accept a cast between pointers inside unsafe") {
            expect(errors("function f(p: *u8): *i32 { unsafe { return @ptrCast(*i32, p); } }")).toBe("");
        }

        test("should report a value that is not a pointer") {
            expect(errors("function f(x: i32): *i32 { unsafe { return @ptrCast(*i32, x); } }"))
                .toInclude("`@ptrCast` converts between pointer types, not `i32` to `*i32`");
        }
    }

    describe("@enumFromInt") {
        test("should accept a constant that is a value of the enum") {
            expect(errors("enum Color { Red, Green }\nfunction f(): Color { return @enumFromInt(Color, 1); }")).toBe("");
        }

        test("should report a constant that is not a value of the enum") {
            expect(errors("enum Color { Red, Green }\nfunction f(): Color { return @enumFromInt(Color, 5); }"))
                .toInclude("5 isn't a value of `Color`");
        }

        test("should report a target that is not an enum") {
            expect(errors("function f(): i32 { return @enumFromInt(i32, 1); }")).toInclude("`@enumFromInt` makes an enum, not `i32`");
        }

        test("should report a value that is not an integer") {
            expect(errors("enum Color { Red, Green }\nfunction f(): Color { return @enumFromInt(Color, true); }"))
                .toInclude("`@enumFromInt` takes an integer, not `bool`");
        }
    }

    describe("@intFromPtr and @ptrFromInt") {
        test("should give the address of a pointer as an integer") {
            expect(errors("function f(p: *u8): bool { return @intFromPtr(p); }")).toInclude("found `u64`");
        }

        test("should report an address taken of a value that is not a pointer") {
            expect(errors("function f(x: i32): usize { return @intFromPtr(x); }")).toInclude("`@intFromPtr` takes a pointer, not `i32`");
        }

        test("should require unsafe to make a pointer from an address") {
            expect(errors("function f(): *u8 { return @ptrFromInt(*u8, 16); }")).toInclude("`@ptrFromInt` needs `unsafe { }`");
        }

        test("should report a target that is not a pointer") {
            expect(errors("function f(): i32 { unsafe { return @ptrFromInt(i32, 16); } }"))
                .toInclude("`@ptrFromInt` makes a pointer, not `i32`");
        }
    }

    describe("@volatileLoad and @volatileStore") {
        test("should load the pointee type") {
            expect(errors("function f(p: *u8): bool { return @volatileLoad(p); }")).toInclude("expected `bool`, found `u8`");
        }

        test("should report a many-item pointer") {
            expect(errors("function f(p: u8[*]): u8 { return @volatileLoad(p); }"))
                .toInclude("`@volatileLoad` needs a pointer to one value (`*T`), found `u8[*]`");
        }

        test("should accept a store through a mutable pointer") {
            expect(errors("function f(p: *u8): void { @volatileStore(p, 1); }")).toBe("");
        }

        test("should report a store through a read-only pointer") {
            expect(errors("function f(p: readonly *u8): void { @volatileStore(p, 1); }"))
                .toInclude("`@volatileStore` can't write through `readonly *u8`");
        }

        test("should report a store without a value") {
            expect(errors("function f(p: *u8): void { @volatileStore(p); }"))
                .toInclude("`@volatileStore` takes a pointer and a value: `@volatileStore(p, v)`");
        }
    }

    describe("@errorName") {
        test("should give a read-only many-item u8 pointer") {
            expect(errors("error E { Bad }\nfunction f(e: E): bool { return @errorName(e); }")).toInclude("found `readonly u8[*]`");
        }

        test("should report a value that is not an error") {
            expect(errors("function f(x: i32): bool { return @errorName(x); }")).toInclude("`@errorName` needs an error, found `i32`");
        }
    }

    test("should report an unknown builtin") {
        expect(errors("function f(x: i32): i32 { return @frob(x); }")).toInclude("unknown builtin `@frob`");
    }
}
