/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { hxAstFree } from "@models/ast.model";
import { BinOp } from "@constants/ast.constant";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { I128Max, I128Min } from "@modules/sema/constants/scope.constant";
import { HxSema, HxValue, HxSymbol, HxU32Vec } from "@structs/sema.struct";
import { hxSemaCheck, hxSemaFree, hxSemaExport } from "@modules/sema/sema.module";
import { hxsDecodeEscape, hxsEncodeUtf8, hxsScopeFind } from "@modules/sema/components/scope.component";
import { hxsIsSaturating, subOverflows, mulOverflows, pushU32 } from "@modules/sema/components/scope.component";
import { u32At, hxsScopeKey, hxsDecodeCodepoint, addOverflows } from "@modules/sema/components/scope.component";
import { hxsHexValue, hxsScopeInsert, hxsScopeSlot, hxsIsWrapping } from "@modules/sema/components/scope.component";

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

/**
 * The compile-time value of the exported constant `x` after a check, copied out before the state goes away.
 *
 * @param text - The program source, which exports a constant `x`
 * @returns A copy of the value
 *
 * @remarks
 * The bytes of a string value go into the shared builder,
 * so the copy stays readable after the checker state is gone, until the next call clears the builder.
 *
 * @since 1.0.0
 */

function valueOf(text: string): HxValue {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    const sym = hxSemaExport(&ch.sema, 0, "x");
    unsafe {
        const index = @ptrCast(HxSymbol[*], ch.sema.symbols.items)[sym].value;
        let v = @ptrCast(HxValue[*], ch.sema.values.items)[index];
        if (const bytes = v.bytes) {
            const b = cleared();
            b.append(`${sliceOf(bytes, v.len)}`) catch unreachable;
            v.bytes = b.text().ptr;
        }
        return v;
    }
}

/**
 * The first `len` bytes at a pointer as a slice.
 *
 * @param bytes - The start of the bytes
 * @param len - The number of bytes
 * @returns The bytes as a slice
 *
 * @remarks
 * The slice points at the bytes without a copy, and nothing checks that `len` bytes are there.
 *
 * @since 1.0.0
 */

function sliceOf(bytes: readonly u8[*], len: u32): string {
    unsafe {
        return bytes[0..len];
    }
}

/**
 * A string literal as a string, so that its pointer can be taken.
 *
 * @param text - The string
 * @returns The pointer to its first byte
 *
 * @remarks
 * The decoder tests use it to hand the bytes of a literal to `hxsDecodeCodepoint`, which reads through a raw pointer.
 *
 * @since 1.0.0
 */

function textAt(text: string): readonly u8[*] {
    return text.ptr;
}

/**
 * The text of a string value.
 *
 * @param v - A string value
 * @returns The bytes of the value as a slice
 *
 * @remarks
 * The slice points at the bytes of the value without a copy,
 * so a value from {@link valueOf} stays readable only until the next call clears the shared builder.
 *
 * @since 1.0.0
 */

function textOf(v: HxValue): string {
    unsafe {
        return v.bytes![0..v.len];
    }
}

describe("pushU32") {
    test("should append values in order and grow the vector") {
        let vec = HxU32Vec { items: null, len: 0, cap: 0 };
        for (const i of 0..100) pushU32(&vec, i as u32);

        expect(vec.len).toBe(100);
        expect(u32At(&vec, 0)).toBe(0);
        expect(u32At(&vec, 99)).toBe(99);
    }
}

describe("u32At") {
    test("should read the value at an index") {
        let vec = HxU32Vec { items: null, len: 0, cap: 0 };
        pushU32(&vec, 7);
        pushU32(&vec, 9);

        expect(u32At(&vec, 1)).toBe(9);
    }
}

describe("hxsScopeKey") {
    test("should keep the module above the name and never give 0") {
        expect(hxsScopeKey(0, 0)).toBe(1 << 32);
        expect(hxsScopeKey(2, 5)).toBe((3 << 32) | 5);
    }
}

describe("hxsScopeSlot") {
    test("should give a slot inside the table") {
        let s: HxSema = undefined;
        s.scopesCap = 1024;

        expect(hxsScopeSlot(&s, hxsScopeKey(0, 12345)) < 1024).toBeTrue();
    }
}

describe("hxsScopeFind") {
    test("should find nothing in an empty table") {
        let s: HxSema = undefined;
        s.scopes = null;
        s.scopesCap = 0;
        s.scopesCount = 0;

        expect(hxsScopeFind(&s, 0, 1)).toBeNull();
    }

    test("should tell the same name in two modules apart") {
        let s: HxSema = undefined;
        s.scopes = null;
        s.scopesCap = 0;
        s.scopesCount = 0;
        hxsScopeInsert(&s, 0, 4).symbol = 10;
        hxsScopeInsert(&s, 1, 4).symbol = 20;

        expect(hxsScopeFind(&s, 0, 4)!.symbol).toBe(10);
        expect(hxsScopeFind(&s, 1, 4)!.symbol).toBe(20);
        expect(hxsScopeFind(&s, 2, 4)).toBeNull();
    }
}

describe("hxsScopeInsert") {
    test("should keep every entry when the table grows") {
        let s: HxSema = undefined;
        s.scopes = null;
        s.scopesCap = 0;
        s.scopesCount = 0;
        for (const i of 1..2001) hxsScopeInsert(&s, 0, i as u32).symbol = i as u32;

        expect(s.scopesCount).toBe(2000);
        expect(s.scopesCap).toBe(4096);
        expect(hxsScopeFind(&s, 0, 1)!.symbol).toBe(1);
        expect(hxsScopeFind(&s, 0, 2000)!.symbol).toBe(2000);
    }
}

describe("hxsLookup") {
    test("should find a global declared after the function that uses it") {
        expect(errors("function f(): i32 { return g; }\nconst g: i32 = 1;")).toBe("");
    }

    test("should report a name that is not declared anywhere") {
        expect(errors("function f(): i32 { return nope; }")).toInclude("nope");
    }

    test("should not let a nested function body see the locals around it") {
        expect(errors("function f(): void { const a: i32 = 1; const g = (): i32 => a; void g; }"))
            .toInclude("`a`");
    }
}

describe("hxsAddSymbol") {
    test("should give each declaration its own symbol") {
        expect(errors("const a: i32 = 1;\nconst b: i32 = 2;\nfunction f(): i32 { return a + b; }")).toBe("");
    }
}

describe("hxsReportRedeclared") {
    test("should point at the earlier declaration and forbid shadowing") {
        const text = errors("function f(): i32 {\n    const a: i32 = 1;\n    const a: i32 = 2;\n    return a;\n}");

        expect(text).toInclude("`a` is already declared");
        expect(text).toInclude("the earlier declaration is at line 2");
    }
}

describe("hxsDeclareLocal") {
    test("should report a local that shadows a global") {
        expect(errors("const a: i32 = 1;\nfunction f(): i32 { const a: i32 = 2; return a; }"))
            .toInclude("`a` is already declared");
    }

    test("should not also report a redeclared local as unused") {
        expect(errors("function f(): i32 { const a: i32 = 1; const a: i32 = 2; return 0; }"))
            .not.toInclude("unused local `a`\n");
    }
}

describe("hxsPushScope") {
    test("should let two sibling blocks declare the same name") {
        expect(errors("function f(): i32 { { const a: i32 = 1; void a; } { const a: i32 = 2; void a; } return 0; }"))
            .toBe("");
    }
}

describe("hxsCheckUnused") {
    test("should report an unused local and suggest the underscore") {
        expect(errors("function f(): void { const a: i32 = 1; }"))
            .toInclude("unused local `a` (hint: remove it, or rename it to `_a` to keep it)");
    }

    test("should report an unused parameter") {
        expect(errors("function f(a: i32): void {}")).toInclude("unused parameter `a`");
    }

    test("should leave a name that starts with an underscore alone") {
        expect(errors("function f(_a: i32): void { const _b: i32 = 1; }")).toBe("");
    }

    test("should report a let that is never reassigned") {
        expect(errors("function f(): i32 { let a: i32 = 1; return a; }"))
            .toInclude("`a` is never reassigned (hint: declare it with `const`)");
    }
}

describe("hxsPopScope") {
    test("should check the locals of an inner block when it ends") {
        expect(errors("function f(): void { { const a: i32 = 1; } }")).toInclude("unused local `a`");
    }
}

describe("hxsDecodeCodepoint") {
    test("should decode one and four byte sequences and move past them") {
        const text = textAt("a\u{1F600}");
        let i: u32 = 0;
        const first = hxsDecodeCodepoint(text, &i);
        const second = hxsDecodeCodepoint(text, &i);

        expect(first).toBe(0x61);
        expect(second).toBe(0x1F600);
        expect(i).toBe(5);
    }

    test("should decode a two byte sequence") {
        let i: u32 = 0;

        expect(hxsDecodeCodepoint(textAt("\u{E9}"), &i)).toBe(0xE9);
        expect(i).toBe(2);
    }
}

describe("hxsHexValue") {
    test("should read digits and letters of either case") {
        expect(hxsHexValue('7')).toBe(7);
        expect(hxsHexValue('a')).toBe(10);
        expect(hxsHexValue('F')).toBe(15);
    }
}

describe("hxsDecodeEscape") {
    test("should decode a named escape") {
        let i: u32 = 0;
        let raw = true;

        expect(hxsDecodeEscape(textAt("\\n"), &i, &raw)).toBe(10);
        expect(i).toBe(2);
        expect(raw).toBeFalse();
    }

    test("should mark a hex escape as a raw byte") {
        let i: u32 = 0;
        let raw = false;

        expect(hxsDecodeEscape(textAt("\\xFF"), &i, &raw)).toBe(255);
        expect(i).toBe(4);
        expect(raw).toBeTrue();
    }

    test("should decode a unicode escape up to its closing brace") {
        let i: u32 = 0;
        let raw = false;

        expect(hxsDecodeEscape(textAt("\\u{1F600}x"), &i, &raw)).toBe(0x1F600);
        expect(i).toBe(9);
    }

    test("should give the escaped character itself for a quote") {
        let i: u32 = 0;
        let raw = false;

        expect(hxsDecodeEscape(textAt("\\\""), &i, &raw)).toBe('"' as u32);
    }
}

describe("hxsEncodeUtf8") {
    test("should write each code point in as few bytes as it needs") {
        let buf: u8[4] = undefined;

        expect(hxsEncodeUtf8(0x41, &buf)).toBe(1);
        expect(hxsEncodeUtf8(0xE9, &buf)).toBe(2);
        expect(hxsEncodeUtf8(0x20AC, &buf)).toBe(3);
        expect(hxsEncodeUtf8(0x1F600, &buf)).toBe(4);
        expect(buf[0]).toBe(0xF0);
        expect(buf[3]).toBe(0x80);
    }
}

describe("hxsCheckIntLiteral") {
    test("should read each base and skip underscores") {
        expect(valueOf("export const x = 0x1_F;").integer).toBe(31);
        expect(valueOf("export const x = 0b101;").integer).toBe(5);
        expect(valueOf("export const x = 0o17;").integer).toBe(15);
        expect(valueOf("export const x = 1_000;").integer).toBe(1000);
    }

    test("should report a literal larger than i128 allows") {
        expect(errors("export const x = 0x8000_0000_0000_0000_0000_0000_0000_0000;"))
            .toInclude("integer literal is too large");
    }
}

describe("hxsCheckFloatLiteral") {
    test("should read a literal with underscores") {
        expect(valueOf("export const x = 1_000.5;").floating).toBe(1000.5);
    }
}

describe("hxsCheckCharLiteral") {
    test("should give the code point of a plain or escaped character") {
        expect(valueOf("export const x = 'A';").integer).toBe(65);
        expect(valueOf("export const x = '\\n';").integer).toBe(10);
        expect(valueOf("export const x = '\u{E9}';").integer).toBe(0xE9);
    }
}

describe("hxsCheckStringLiteral") {
    test("should decode escapes into UTF-8 bytes") {
        const v = valueOf("export const x = \"a\\u{E9}\\n\";");

        expect(v.len).toBe(4);
        expect(textOf(v)).toBe("a\u{E9}\n");
    }

    test("should keep a hex escape as one raw byte") {
        expect(valueOf("export const x = \"\\xFF\";").len).toBe(1);
    }
}

describe("hxsIsWrapping") {
    test("should accept only the wrapping operators") {
        expect(hxsIsWrapping(BinOp.AddWrap as u32)).toBeTrue();
        expect(hxsIsWrapping(BinOp.MulWrap as u32)).toBeTrue();
        expect(hxsIsWrapping(BinOp.Add as u32)).toBeFalse();
    }
}

describe("hxsIsSaturating") {
    test("should accept only the saturating operators") {
        expect(hxsIsSaturating(BinOp.SubSat as u32)).toBeTrue();
        expect(hxsIsSaturating(BinOp.SubWrap as u32)).toBeFalse();
    }
}

describe("addOverflows") {
    test("should report a sum past the largest i128 and keep the wrapped result") {
        let r: i128 = 0;

        expect(addOverflows(I128Max, 1, &r)).toBeTrue();
        expect(r).toBe(I128Min);
        expect(addOverflows(1, 2, &r)).toBeFalse();
        expect(r).toBe(3);
    }
}

describe("subOverflows") {
    test("should report a difference past the smallest i128") {
        let r: i128 = 0;

        expect(subOverflows(I128Min, 1, &r)).toBeTrue();
        expect(subOverflows(-1, I128Max, &r)).toBeFalse();
    }
}

describe("mulOverflows") {
    test("should report a product that does not fit") {
        let r: i128 = 0;

        expect(mulOverflows(I128Max, 2, &r)).toBeTrue();
        expect(mulOverflows(-1, I128Min, &r)).toBeTrue();
        expect(mulOverflows(0, I128Max, &r)).toBeFalse();
        expect(mulOverflows(-3, 4, &r)).toBeFalse();
        expect(r).toBe(-12);
    }
}

describe("hxsFoldInt") {
    test("should wrap a wrapping operator to the width of the type") {
        expect(valueOf("export const x: u8 = 200 +% (100 as u8);").integer).toBe(44);
    }

    test("should clamp a saturating operator to the range of the type") {
        expect(valueOf("export const x: u8 = (200 as u8) +| 100;").integer).toBe(255);
        expect(valueOf("export const x: i8 = (-100 as i8) -| 100;").integer).toBe(-128);
    }

    test("should report division by zero") {
        expect(errors("export const x = 1 / 0;")).toInclude("division by zero in a constant expression");
    }

    test("should report a result that does not fit the type, with its range") {
        expect(errors("export const x: u8 = (200 as u8) + 100;"))
            .toInclude("integer overflow in a constant expression (hint: the result doesn't fit in `u8` (0 to 255)");
    }

    test("should report a shift as wide as the type") {
        expect(errors("export const x: u8 = (1 as u8) << 8;")).toInclude("shift amount 8 is too large for `u8`");
    }

    test("should drop the bits a shift moves out of a sized integer") {
        expect(valueOf("export const x: u8 = (0x81 as u8) << 1;").integer).toBe(2);
    }

    test("should fold division, remainder, and the bitwise operators") {
        expect(valueOf("export const x = 17 / 5;").integer).toBe(3);
        expect(valueOf("export const x = 17 % 5;").integer).toBe(2);
        expect(valueOf("export const x = (12 & 10) | (1 ^ 3);").integer).toBe(10);
        expect(valueOf("export const x = -16 >> 2;").integer).toBe(-4);
    }
}

describe("hxsFoldBinary") {
    test("should fold comparisons and logic to a boolean") {
        expect(valueOf("export const x = 1 < 2 && 2.5 > 2;").boolean).toBeTrue();
        expect(valueOf("export const x = true == false || 3 != 3;").boolean).toBeFalse();
    }

    test("should fold float arithmetic") {
        expect(valueOf("export const x = 1.5 * 4.0 - 0.5;").floating).toBe(5.5);
    }

    test("should fold integer arithmetic") {
        expect(valueOf("export const x = 2 + 3 * 4;").integer).toBe(14);
    }
}
