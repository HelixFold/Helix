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

describe("hxsMentions") {
    test("should refuse Self in a parameter other than the receiver") {
        expect(errors("interface Bad { same(this: *Self, other: *Self): bool; }"))
            .toInclude("`Self` can only be the receiver's type");
    }

    test("should refuse Self in the result") {
        expect(errors("interface Bad { copy(this: *Self): ?Self; }")).toInclude("`Self` can only be the receiver's type");
    }
}

describe("hxsIfaceSignature") {
    test("should accept a method that takes this as its receiver") {
        expect(errors("interface Writer { write(this: *Self, bytes: string): usize; }")).toBe("");
    }

    test("should refuse a method without a receiver") {
        expect(errors("interface Bad { make(): i32; }")).toInclude("interface method `make` needs a receiver");
    }

    test("should refuse a comptime parameter") {
        expect(errors("interface Bad { make(this: *Self, comptime n: i32): i32; }"))
            .toInclude("an interface method can't take `comptime` parameters");
    }
}

describe("hxsIfaceReadonlyOk") {
    test("should refuse a readonly pointer when a method changes the value") {
        expect(errors("interface Writer { write(this: *Self, bytes: string): usize; }\nstruct Ok { write(this: *Ok, bytes: string): usize { return bytes.len; } }\nfunction use(w: dyn Writer): void { void w; }\nfunction f(ok: readonly *Ok): void { use(ok); }"))
            .toInclude("expected `dyn Writer`, found `readonly *Ok`");
    }

    test("should accept a readonly pointer when every method leaves the value alone") {
        expect(errors("interface Shape { area(this: readonly *Self): f64; }\nstruct Sq { s: f64, area(this: readonly *Sq): f64 { return this.s; } }\nfunction use(s: dyn Shape): void { void s; }\nfunction f(sq: readonly *Sq): void { use(sq); }"))
            .toBe("");
    }
}

describe("hxsReceiverFits") {
    test("should accept a method that takes the value where the interface asks for a pointer") {
        expect(errors("interface Writer { write(this: *Self, bytes: string): usize; }\nstruct Ok { write(this: Ok, bytes: string): usize { return bytes.len; } }\nfunction use(w: dyn Writer): void { void w; }\nfunction f(ok: *Ok): void { use(ok); }"))
            .toBe("");
    }

    test("should accept a readonly receiver where the interface asks for a mutable one") {
        expect(errors("interface Writer { write(this: *Self, bytes: string): usize; }\nstruct Ok { write(this: readonly *Ok, bytes: string): usize { return bytes.len; } }\nfunction use(w: dyn Writer): void { void w; }\nfunction f(ok: *Ok): void { use(ok); }"))
            .toBe("");
    }
}

describe("hxsSignatureFits") {
    test("should refuse a method whose result differs") {
        expect(errors("interface Writer { write(this: *Self, bytes: string): usize; }\nstruct Wrong { write(this: *Wrong, bytes: string): i32 { void bytes; return 0; } }\nfunction use(w: dyn Writer): void { void w; }\nfunction f(w: *Wrong): void { use(w); }"))
            .toInclude("expected `dyn Writer`, found `*Wrong`");
    }
}

describe("hxsImplOf") {
    test("should refuse a struct without the method") {
        expect(errors("interface Writer { write(this: *Self, bytes: string): usize; }\nstruct Quiet {}\nfunction use(w: dyn Writer): void { void w; }\nfunction f(q: *Quiet): void { use(q); }"))
            .toInclude("expected `dyn Writer`, found `*Quiet`");
    }

    test("should refuse a type that has no methods") {
        expect(errors("interface Writer { write(this: *Self, bytes: string): usize; }\nfunction use(w: dyn Writer): void { void w; }\nfunction f(n: *i32): void { use(n); }"))
            .toInclude("expected `dyn Writer`, found `*i32`");
    }

    test("should report a generic constraint that the type does not meet") {
        expect(errors("interface Writer { write(this: *Self, bytes: string): usize; }\nstruct Quiet {}\nfunction stat<W extends Writer>(w: *W): void { void w.write(\"y\"); }\nfunction f(q: *Quiet): void { stat(q); }"))
            .toInclude("`Quiet` doesn't implement `Writer`");
    }
}

describe("hxsResolveInterface") {
    test("should report an unknown interface") {
        expect(errors("function f(w: dyn Missing): void { void w; }")).toInclude("unknown interface `Missing`");
    }

    test("should refuse a struct after dyn") {
        expect(errors("struct Ok {}\nfunction f(w: dyn Ok): void { void w; }")).toInclude("`dyn` needs an interface, and `Ok` isn't one");
    }

    test("should refuse a generic interface without type arguments") {
        expect(errors("interface Source<T> { next(this: *Self): ?T; }\nfunction f(s: dyn Source): void { void s; }"))
            .toInclude("`Source` is generic, so it needs type arguments");
    }

    test("should accept a generic interface with type arguments") {
        expect(errors("interface Source<T> { next(this: *Self): ?T; }\nfunction f(s: dyn Source<i32>): void { void s; }"))
            .toBe("");
    }
}
