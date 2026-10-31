/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { hxAstFree } from "@models/ast.model";
import { hxTypeInt } from "@models/types.model";
import { Ctx, HxSema } from "@structs/sema.struct";
import { hxIntern } from "@services/intern.service";
import { TypeKind } from "@constants/types.constant";
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
import { hxsScopeFind } from "@modules/sema/components/scope.component";
import { symbolOf, typeOf, types } from "@modules/sema/components/base.component";
import { hxsErrorCode, hxsDeclareAggregateNamed, hxsFindMember } from "@modules/sema/components/aggregate.component";
import { hxsMemberOf, hxsIntTypeForRange, hxsLayout, hxsSizeAlign } from "@modules/sema/components/aggregate.component";

/**
 * The C library function that clears the hand-built checker context.
 *
 * @since 1.0.0
 */

extern "C" function memset(to: u8[*], byte: i32, len: usize): ?u8[*];

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


let snippet: Builder = undefined;
let snippetReady = false;

/**
 * Every error message that checking `@sizeOf` of a type gives, which names the size plus 256.
 *
 * @param decls - The declarations that the type relies on
 * @param type - The type whose size to measure
 * @returns The error messages, each followed by a newline
 *
 * @remarks
 * Adds 256 to the size and stores the sum in a `u8` constant,
 * so the overflow error spells out the computed value for the test to match.
 *
 * @since 1.0.0
 */

function sizeOf(decls: string, type: string): string {
    if (!snippetReady) {
        snippet = Builder.init(cAllocator());
        snippetReady = true;
    }
    snippet.clear();
    snippet.append(`${decls}\nconst probe: u8 = @sizeOf(${type}) + 256;\n`) catch unreachable;
    return errors(snippet.text());
}

/**
 * Sets up a checker context over a finished check, as `hxSemaCheck` sets up its own.
 *
 * @param ch - The state of a finished check
 * @param ctx - The context to fill
 *
 * @remarks
 * Zeroes the whole context before it points it at the checker, tree, tokens, and type tables of the check.
 * It also sets the defer floor to the value that means outside any defer,
 * so a test can call component functions directly.
 *
 * @since 1.0.0
 */

function contextOf(ch: *Checked, ctx: *Ctx): void {
    unsafe {
        void memset(@ptrCast(u8[*], ctx), 0, @sizeOf(Ctx));
    }
    ctx.sema = &ch.sema;
    ctx.ast = &ch.ast;
    ctx.tokens = ch.ast.tokens;
    ctx.types = &ch.sema.types;
    ctx.deferFloor = 0xFFFF_FFFF;
}

/**
 * Interns a name in the names of a finished check.
 *
 * @param ch - The state of a finished check
 * @param name - The name to intern
 * @returns The name's index in the name table
 *
 * @remarks
 * A name that the check already interned gets back its existing index, so the result matches the index in the tree.
 *
 * @since 1.0.0
 */

function nameOf(ch: *Checked, name: string): u32 {
    return hxIntern(&ch.sema.names, name.ptr, @truncate(u32, name.len));
}

/**
 * The type that a top-level declaration of a finished check names.
 *
 * @param ch - The state of a finished check
 * @param ctx - The context that `contextOf` filled
 * @param name - The name of the declaration
 * @returns The type of the declaration's symbol
 *
 * @remarks
 * Looks the name up in the module scope and reads the type of the symbol that it finds.
 * It stops the test when no declaration has the name, since it unwraps the lookup.
 *
 * @since 1.0.0
 */

function typeNamed(ch: *Checked, ctx: *Ctx, name: string): u32 {
    return symbolOf(ctx, hxsScopeFind(&ch.sema, 0, nameOf(ch, name))!.symbol).type;
}

describe("hxsErrorCode") {
    test("should give an error name the same code in every error set") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "error E1 { NotFound, Bad }\nerror E2 { Other, NotFound }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);

        expect(hxsErrorCode(&ctx, nameOf(&ch, "NotFound"))).toBe(1);
        expect(hxsErrorCode(&ctx, nameOf(&ch, "Bad"))).toBe(2);
        expect(hxsErrorCode(&ctx, nameOf(&ch, "Other"))).toBe(3);
    }

    test("should give a name seen for the first time the next free code") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "error E1 { NotFound, Bad }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);

        expect(hxsErrorCode(&ctx, nameOf(&ch, "Missing"))).toBe(3);
        expect(hxsErrorCode(&ctx, nameOf(&ch, "Missing"))).toBe(3);
    }
}

describe("hxsDeclareAggregateNamed") {
    test("should create a struct type with the given name and an aggregate record") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "struct Point { x: i32 }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);
        const before = ch.sema.aggregates.len;
        const decl = symbolOf(&ctx, hxsScopeFind(&ch.sema, 0, nameOf(&ch, "Point"))!.symbol).decl;
        const name: string = "Made";

        const type = hxsDeclareAggregateNamed(&ctx, TypeKind.Struct as u32, decl, name.ptr, 4);

        expect(typeOf(&ctx, type).kind == TypeKind.Struct).toBeTrue();
        expect(typeOf(&ctx, type).nameLen).toBe(4);
        expect(ch.sema.aggregates.len).toBe(before + 1);
    }

    test("should give each instance of a generic struct its own type") {
        expect(sizeOf("struct Box<T> { v: T }", "Box<u8>")).toInclude("integer 257 does not fit");
        expect(sizeOf("struct Box<T> { v: T }", "Box<u64>")).toInclude("integer 264 does not fit");
    }
}

describe("hxsDeclareAggregate") {
    test("should name the type after its declaration") {
        expect(errors("struct Point { x: i32 }\nconst p: Point = Point { x: 1, z: 2 };\n"))
            .toInclude("`Point` has no field `z`");
    }
}

describe("hxsFindMember") {
    test("should give the index of a member and -1 for a missing one") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "struct Point { x: i32, y: i64 }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);
        const point = typeNamed(&ch, &ctx, "Point");

        expect(hxsFindMember(&ctx, point, nameOf(&ch, "y"))).toBe(1);
        expect(hxsFindMember(&ctx, point, nameOf(&ch, "z"))).toBe(-1);
    }

    test("should give -1 for a type that is not an aggregate") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "struct Point { x: i32 }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);

        expect(hxsFindMember(&ctx, types(&ctx).i32, nameOf(&ch, "x"))).toBe(-1);
    }
}

describe("hxsMemberOf") {
    test("should read the field at an index") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "struct Point { x: i32, y: i64 }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);
        const point = typeNamed(&ch, &ctx, "Point");

        const m = hxsMemberOf(&ctx, point, 1);

        expect(m.index).toBe(1);
        expect(m.type).toBe(types(&ctx).i64);
    }

    test("should read the value of an enum member") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "enum Level { Low, High = 10 }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);
        const level = typeNamed(&ch, &ctx, "Level");

        expect(hxsMemberOf(&ctx, level, hxsFindMember(&ctx, level, nameOf(&ch, "High"))).value == 10).toBeTrue();
    }
}

describe("hxsCheckContainment") {
    test("should report a struct that contains itself, with a hint to store a pointer") {
        let ch: Checked = undefined;
        check(&ch, "struct Node { next: Node }\n");
        defer release(&ch);

        unsafe {
            expect(cString(ch.diags.items![0].message)).toBe("`Node` contains itself, so it would be infinitely large");
            expect(cString(ch.diags.items![0].hint!)).toBe("store a pointer instead: `*Node` or `?*Node`");
        }
    }

    test("should report a cycle through two structs") {
        expect(errors("struct A { b: B }\nstruct B { a: A }\n")).toInclude("contains itself");
    }

    test("should look inside arrays and optionals") {
        expect(errors("struct Grid { cells: Grid[2] }\n")).toInclude("`Grid` contains itself");
        expect(errors("struct List { next: ?List }\n")).toInclude("`List` contains itself");
    }

    test("should accept pointers and slices to the struct itself") {
        expect(errors("struct Ok { next: ?*Ok, items: Ok[] }\n")).toBe("");
    }
}

describe("hxsIntTypeForRange") {
    test("should pick the smallest integer type that holds the range") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "");
        defer release(&ch);
        contextOf(&ch, &ctx);

        expect(hxsIntTypeForRange(&ctx, 0, 255)).toBe(types(&ctx).u8);
        expect(hxsIntTypeForRange(&ctx, 0, 300)).toBe(types(&ctx).u16);
        expect(hxsIntTypeForRange(&ctx, -1, 100)).toBe(types(&ctx).i8);
    }

    test("should pick a 128-bit type past 64 bits") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "");
        defer release(&ch);
        contextOf(&ch, &ctx);
        const big: i128 = 1 << 100;

        expect(hxsIntTypeForRange(&ctx, -1, big)).toBe(hxTypeInt(types(&ctx), true, 128));
    }
}

describe("hxsResolveAggregate") {
    test("should number an enum member after the one before it") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "enum Code { A = 5, B }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);
        const code = typeNamed(&ch, &ctx, "Code");

        expect(hxsMemberOf(&ctx, code, 1).value == 6).toBeTrue();
    }

    test("should back an enum with the smallest integer for its values") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "enum Big { A = 300 }\nenum Neg { A = -1, B = 100 }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);

        expect(typeOf(&ctx, typeNamed(&ch, &ctx, "Big")).child).toBe(types(&ctx).u16);
        expect(typeOf(&ctx, typeNamed(&ch, &ctx, "Neg")).child).toBe(types(&ctx).i8);
    }

    test("should tag a union with a u8 and back an error set with the error code") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "union Shape { a: u8, b: u64 }\nerror Failure { Bad }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);

        expect(typeOf(&ctx, typeNamed(&ch, &ctx, "Shape")).child).toBe(types(&ctx).u8);
        expect(typeOf(&ctx, typeNamed(&ch, &ctx, "Failure")).child).toBe(types(&ctx).errorCode);
    }

    test("should report two enum members with the same value") {
        expect(errors("enum E { A = 1, B = 1 }\n")).toInclude("`B` has the same value as `A`");
    }

    test("should report an enum value that is not a constant integer") {
        expect(errors("function one(): i32 { return 1; }\nenum E { A = one() }\n"))
            .toInclude("an enum value must be an integer known at compile time");
    }

    test("should report a backing type that is not an integer") {
        expect(errors("enum E: bool { A }\n")).toInclude("an enum's backing type must be an integer, found `bool`");
    }

    test("should report a value that does not fit in the backing type") {
        expect(errors("enum E: u8 { A = 256 }\n")).toInclude("`A` doesn't fit in the backing type `u8`");
    }

    test("should report a void field") {
        expect(errors("struct V { v: void }\n")).toInclude("a field can't be `void`");
    }

    test("should report a member declared twice") {
        expect(errors("struct D { x: i32, x: i32 }\n")).toInclude("`x` is declared twice in `D`");
    }

    test("should check a default value against the type of its field") {
        expect(errors("struct D { x: u8 = 300 }\n")).toInclude("integer 300 does not fit in `u8`");
    }
}

describe("hxsLayout") {
    test("should align each field and round the size up to the largest alignment") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "");
        defer release(&ch);
        contextOf(&ch, &ctx);
        const fields: u32[3] = [types(&ctx).u8, types(&ctx).u32, types(&ctx).u8];
        let size: u64 = 0;
        let align: u64 = 0;

        hxsLayout(&ctx, &fields, 3, &size, &align);

        expect(size).toBe(12);
        expect(align).toBe(4);
    }

    test("should give size 0 and alignment 1 without fields") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "");
        defer release(&ch);
        contextOf(&ch, &ctx);
        const fields: u32[1] = [0];
        let size: u64 = 9;
        let align: u64 = 9;

        hxsLayout(&ctx, &fields, 0, &size, &align);

        expect(size).toBe(0);
        expect(align).toBe(1);
    }
}

describe("hxsSizeAlign") {
    test("should measure a struct with its fields in C order") {
        let ch: Checked = undefined;
        let ctx: Ctx = undefined;
        check(&ch, "struct S { a: u8, b: u32 }\n");
        defer release(&ch);
        contextOf(&ch, &ctx);
        let size: u64 = 0;
        let align: u64 = 0;

        hxsSizeAlign(&ctx, typeNamed(&ch, &ctx, "S"), &size, &align);

        expect(size).toBe(8);
        expect(align).toBe(4);
    }

    test("should round an odd integer width up to a power of two bytes") {
        expect(sizeOf("", "u24")).toInclude("integer 260 does not fit");
        expect(sizeOf("", "i128")).toInclude("integer 272 does not fit");
    }

    test("should measure a slice as two pointers and an array by its length") {
        expect(sizeOf("", "string")).toInclude("integer 272 does not fit");
        expect(sizeOf("struct S { a: u8, b: u32 }", "S[3]")).toInclude("integer 280 does not fit");
    }

    test("should measure an enum by its backing integer and an error set as 2 bytes") {
        expect(sizeOf("enum Big { A = 300 }", "Big")).toInclude("integer 258 does not fit");
        expect(sizeOf("error Failure { Bad }", "Failure")).toInclude("integer 258 does not fit");
    }

    test("should measure an optional pointer as a pointer and any other optional with a flag") {
        expect(sizeOf("struct S { a: u8 }", "?*S")).toInclude("integer 264 does not fit");
        expect(sizeOf("", "?u32")).toInclude("integer 264 does not fit");
    }

    test("should measure a union as its tag and its largest payload in words") {
        expect(sizeOf("union U { a: u8, b: u64 }", "U")).toInclude("integer 272 does not fit");
        expect(sizeOf("union T { a, b }", "T")).toInclude("integer 257 does not fit");
    }
}
