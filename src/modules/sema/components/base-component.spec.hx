/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { hxAstFree } from "@models/ast.model";
import { Ctx, HxSema } from "@structs/sema.struct";
import { NodeKind } from "@constants/ast.constant";
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
import { I128Max, I128Min } from "@modules/sema/constants/base.constant";
import { HxValueInt, HxValueError, HxValueNull } from "@constants/sema.constant";
import { hxTypeInt, hxTypePointer, hxTypeArray, hxTypeOptional } from "@models/types.model";
import { hxsSpanTokens, hxNodeSpan, emptyValue } from "@modules/sema/components/base.component";
import { hxsIsAggregate, hxsTypeNameText, hxsWrapInt } from "@modules/sema/components/base.component";
import { kindOf, hxsAddValue, hxsValueOf, hxsMatchingClose } from "@modules/sema/components/base.component";
import { i128Text, semaOf, astOf, types, hxsIsFloat, errorSpan } from "@modules/sema/components/base.component";
import { hxsIntFits, hxsCAbiDiffers, hxsIsNumeric, hxsIsInteger } from "@modules/sema/components/base.component";
import { hxsTokText, hxsTokName, hxsExpectedBase, hxsImplicitOk } from "@modules/sema/components/base.component";
import { hxsErrorValue, hxsIntMin, hxsIntMax, tokenStart, infoOf } from "@modules/sema/components/base.component";
import { errorNode, errorToken, hint, hintf, nodeOf, extraOf, typeOf } from "@modules/sema/components/base.component";
import { valueAt, memberAt, paramOf, hxsPointedArray, hxsAggregateOf } from "@modules/sema/components/base.component";
import { hxsIsComptimeNumber, symbolOf, infoAt, typeName, hxsI128Text } from "@modules/sema/components/base.component";
import { hxsIntValue, hxsBoolValue, hxsFloatValue, tokenLen, tokenText } from "@modules/sema/components/base.component";

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
 * A checker context over the tables of a finished check, outside any function and any instance.
 *
 * @param ch - The state of a finished check
 * @returns The context, which points into the state
 *
 * @remarks
 * Sets only the fields that the base helpers read, marks the context as global-only,
 * and leaves every other field undefined.
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
    c.coerceSite = 0;
    c.globalsOnly = true;
    return c;
}

/**
 * The index of the first node of a kind, or 0.
 *
 * @param ch - The state of a finished check
 * @param kind - The node kind to look for
 * @returns The index of the first matching node, or 0 when none matches
 *
 * @remarks
 * Scans the node table in order from index 1, since index 0 is the empty node.
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
 * The type of the first top-level declaration, read from its symbol.
 *
 * @param c - The context over a finished check
 * @returns The type of the symbol that the first declaration declares
 *
 * @remarks
 * Reads the first entry of the root's declaration list, so the module must declare at least one name.
 *
 * @since 1.0.0
 */

function firstDeclType(c: readonly *Ctx): u32 {
    const decl = extraOf(c, nodeOf(c, astOf(c).root).a);
    return symbolOf(c, infoOf(c, decl).symbol).type;
}

/**
 * Every error and hint that checking a text gives, one per line, or an empty string when it checks.
 *
 * @param text - The source text to check
 * @returns The messages, each followed by a newline, with a hint line after its error
 *
 * @remarks
 * Prefixes each hint with `hint: ` and places it right after the message that carries it.
 * Every call clears one module-level builder, so the returned text stays valid only until the next call.
 *
 * @since 1.0.0
 */

function report(text: string): string {
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
            const d = ch.diags.items![i];
            out.append(`${cString(d.message)}\n`) catch unreachable;
            if (const h = d.hint) out.append(`hint: ${cString(h)}\n`) catch unreachable;
        }
    }
    return out.text();
}

describe("semaOf") {
    test("should return the checker state of the context") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 1;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(semaOf(&c).symbols.len).toBe(ch.sema.symbols.len);
    }
}

describe("astOf") {
    test("should return the syntax tree of the context") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 1;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(astOf(&c).nodesLen).toBe(ch.ast.nodesLen);
    }
}

describe("types") {
    test("should return the type table of the checker") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 1;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(types(&c).i32).toBe(ch.sema.types.i32);
    }
}

describe("nodeOf") {
    test("should read the root node of the file") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 1;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(nodeOf(&c, ch.ast.root).kind == NodeKind.File).toBe(true);
    }
}

describe("extraOf") {
    test("should read the top-level declarations of the file in order") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 1;\nfunction f(): void {}");
        defer release(&ch);
        const c = contextOf(&ch);
        const file = nodeOf(&c, ch.ast.root);

        expect(nodeOf(&c, extraOf(&c, file.a)).kind == NodeKind.Const).toBe(true);
        expect(nodeOf(&c, extraOf(&c, file.a + 1)).kind == NodeKind.Function).toBe(true);
    }
}

describe("typeOf") {
    test("should copy the entry of a type") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(typeOf(&c, types(&c).i32).bits).toBe(32);
    }
}

describe("kindOf") {
    test("should give the kind of a type") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(kindOf(&c, types(&c).string) == TypeKind.Slice).toBe(true);
        expect(kindOf(&c, 0) == TypeKind.Invalid).toBe(true);
    }
}

describe("symbolOf") {
    test("should give the symbol that a declaration was given") {
        let ch: Checked = undefined;
        check(&ch, "const limit: u16 = 10;");
        defer release(&ch);
        const c = contextOf(&ch);
        const decl = extraOf(&c, nodeOf(&c, ch.ast.root).a);
        const sym = symbolOf(&c, infoOf(&c, decl).symbol);

        expect(tokenText(&c, sym.token)).toBe("limit");
        expect(sym.type).toBe(types(&c).u16);
    }
}

describe("infoAt") {
    test("should read the shared info outside any instance") {
        let ch: Checked = undefined;
        check(&ch, "const a: bool = true;");
        defer release(&ch);
        const c = contextOf(&ch);
        const literal = findNode(&ch, NodeKind.True);

        expect(infoAt(&ch.sema, 0, literal).type).toBe(types(&c).boolType);
    }
}

describe("infoOf") {
    test("should give the type that checking gave a node") {
        let ch: Checked = undefined;
        check(&ch, "const a: f64 = 1.5;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(infoOf(&c, findNode(&ch, NodeKind.Float)).type).toBe(types(&c).comptimeFloat);
    }
}

describe("valueAt") {
    test("should read the value that a literal folded to") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 40 + 2;");
        defer release(&ch);
        const c = contextOf(&ch);
        const sum = findNode(&ch, NodeKind.Binary);

        expect(valueAt(&c, infoOf(&c, sum).value).integer).toBe(42);
    }
}

describe("memberAt") {
    test("should read the members of a struct in declaration order") {
        let ch: Checked = undefined;
        check(&ch, "struct Point { x: i32, y: bool }");
        defer release(&ch);
        const c = contextOf(&ch);
        const agg = hxsAggregateOf(&c, firstDeclType(&c));

        expect(memberAt(&c, agg.membersStart).type).toBe(types(&c).i32);
        expect(memberAt(&c, agg.membersStart + 1).type).toBe(types(&c).boolType);
    }
}

describe("paramOf") {
    test("should read the parameter types of a function type") {
        let ch: Checked = undefined;
        check(&ch, "function f(a: i32, b: bool): void {}");
        defer release(&ch);
        const c = contextOf(&ch);
        const fn = typeOf(&c, firstDeclType(&c));

        expect(paramOf(&c, fn, 0)).toBe(types(&c).i32);
        expect(paramOf(&c, fn, 1)).toBe(types(&c).boolType);
    }
}

describe("tokenStart") {
    test("should give the offset of a token") {
        let ch: Checked = undefined;
        check(&ch, "const count: i32 = 1;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(tokenStart(&c, 1)).toBe(6);
    }
}

describe("tokenLen") {
    test("should give the length of a token") {
        let ch: Checked = undefined;
        check(&ch, "const count: i32 = 1;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(tokenLen(&c, 1)).toBe(5);
    }
}

describe("tokenText") {
    test("should give the text of a token") {
        let ch: Checked = undefined;
        check(&ch, "const count: i32 = 1;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(tokenText(&c, 1)).toBe("count");
    }
}

describe("hxsTokText") {
    test("should point at the token and give its length") {
        let ch: Checked = undefined;
        check(&ch, "const count: i32 = 1;");
        defer release(&ch);
        const c = contextOf(&ch);
        let len: i32 = 0;
        const text = hxsTokText(&c, 1, &len);

        expect(len).toBe(5);
        unsafe {
            expect(text[0..5]).toBe("count");
        }
    }
}

describe("hxsTokName") {
    test("should give equal names to tokens with equal text") {
        let ch: Checked = undefined;
        check(&ch, "const n: i32 = 1;\nconst m: i32 = n;");
        defer release(&ch);
        let c = contextOf(&ch);

        expect(hxsTokName(&c, 1)).toBe(hxsTokName(&c, 12));
        expect(hxsTokName(&c, 1) == hxsTokName(&c, 7)).toBe(false);
    }
}

describe("hxsTypeNameText") {
    test("should keep four names apart before reusing a buffer") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);
        const a = hxsTypeNameText(&c, types(&c).i32);
        void hxsTypeNameText(&c, types(&c).u8);
        void hxsTypeNameText(&c, types(&c).boolType);
        void hxsTypeNameText(&c, types(&c).f64);

        expect(cString(a)).toBe("i32");
        void hxsTypeNameText(&c, types(&c).string);
        expect(cString(a)).toBe("string");
    }
}

describe("typeName") {
    test("should name a type the way messages show it") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(typeName(&c, hxTypeOptional(types(&c), types(&c).string))).toBe("?string");
    }
}

describe("hxsI128Text") {
    test("should write a negative number with its sign") {
        let buf: u8[48] = undefined;
        hxsI128Text(-42, &buf, 48);

        expect(cString(&buf)).toBe("-42");
    }

    test("should write the smallest i128") {
        let buf: u8[48] = undefined;
        hxsI128Text(I128Min, &buf, 48);

        expect(cString(&buf)).toBe("-170141183460469231731687303715884105728");
    }

    test("should drop the digits that do not fit") {
        let buf: u8[4] = undefined;
        hxsI128Text(123456, &buf, 4);

        expect(cString(&buf)).toBe("123");
    }
}

describe("i128Text") {
    test("should give the decimal text of a number") {
        let buf: u8[48] = undefined;

        expect(i128Text(0, &buf)).toBe("0");
        expect(i128Text(I128Max, &buf)).toBe("170141183460469231731687303715884105727");
    }
}

describe("errorSpan") {
    test("should add an error at the given span") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 1;");
        defer release(&ch);
        let c = contextOf(&ch);
        const diag = errorSpan(&c, 6, 1, `bad ${"name"}`);

        unsafe {
            expect(cString(ch.diags.items![diag].message)).toBe("bad name");
            expect(ch.diags.items![diag].start).toBe(6);
        }
        expect(ch.diags.errorCount).toBe(1);
    }
}

describe("errorNode") {
    test("should cover the whole expression") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 1 + 2;");
        defer release(&ch);
        let c = contextOf(&ch);
        const diag = errorNode(&c, findNode(&ch, NodeKind.Binary), `bad sum`);

        unsafe {
            expect(ch.diags.items![diag].start).toBe(15);
            expect(ch.diags.items![diag].len).toBe(5);
        }
    }
}

describe("errorToken") {
    test("should point at one token") {
        let ch: Checked = undefined;
        check(&ch, "const count: i32 = 1;");
        defer release(&ch);
        let c = contextOf(&ch);
        const diag = errorToken(&c, 1, `bad token`);

        unsafe {
            expect(ch.diags.items![diag].start).toBe(6);
            expect(ch.diags.items![diag].len).toBe(5);
        }
    }
}

describe("hint") {
    test("should attach a hint to the diagnostic") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const diag = errorSpan(&c, 0, 0, `bad`);
        hint(&c, diag, "fix it");

        unsafe {
            expect(cString(ch.diags.items![diag].hint!)).toBe("fix it");
        }
    }
}

describe("hintf") {
    test("should attach a formatted hint to the diagnostic") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const diag = errorSpan(&c, 0, 0, `bad`);
        hintf(&c, diag, `use ${typeName(&c, types(&c).i32)}`);

        unsafe {
            expect(cString(ch.diags.items![diag].hint!)).toBe("use i32");
        }
    }
}

describe("hxsUnsupported") {
    test("should report a feature that this alpha does not support") {
        expect(report("enum E<T> { A }")).toBe("generic enums are not supported yet in this alpha\nhint: it's planned for a later alpha\n");
    }
}

describe("hxsMatchingClose") {
    test("should skip nested brackets") {
        let ch: Checked = undefined;
        check(&ch, "f(a, (b))");
        defer release(&ch);

        expect(hxsMatchingClose(&ch.ast, 1)).toBe(7);
    }

    test("should return the opening token when nothing closes it") {
        let ch: Checked = undefined;
        check(&ch, "f(a");
        defer release(&ch);

        expect(hxsMatchingClose(&ch.ast, 1)).toBe(1);
    }
}

describe("hxsSpanTokens") {
    test("should reach from the left operand to the closing bracket of a call") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = b + f(c);");
        defer release(&ch);
        let first: u32 = 0;
        let last: u32 = 0;
        hxsSpanTokens(&ch.ast, findNode(&ch, NodeKind.Binary), &first, &last);

        expect(first).toBe(5);
        expect(last).toBe(10);
    }
}

describe("hxNodeSpan") {
    test("should give the byte span of a whole expression") {
        let ch: Checked = undefined;
        check(&ch, "const x = a + b;");
        defer release(&ch);
        let start: u32 = 0;
        let len: u32 = 0;
        hxNodeSpan(&ch.ast, findNode(&ch, NodeKind.Binary), &start, &len);

        expect(start).toBe(10);
        expect(len).toBe(5);
    }
}

describe("emptyValue") {
    test("should set only the kind") {
        const v = emptyValue(HxValueNull as u8);

        expect(v.kind).toBe(HxValueNull as u8);
        expect(v.integer == 0).toBe(true);
        expect(v.len).toBe(0);
    }
}

describe("hxsAddValue") {
    test("should append the value and return its index") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const before = ch.sema.values.len;
        const index = hxsAddValue(&c, emptyValue(HxValueNull as u8));

        expect(index).toBe(before);
        expect(ch.sema.values.len).toBe(before + 1);
    }
}

describe("hxsValueOf") {
    test("should give the folded value of a constant expression") {
        let ch: Checked = undefined;
        check(&ch, "const a: i32 = 6 * 7;");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsValueOf(&c, findNode(&ch, NodeKind.Binary))!.integer).toBe(42);
    }

    test("should give null for a value known only at run time") {
        let ch: Checked = undefined;
        check(&ch, "function f(x: i32): i32 { return x + 1; }");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsValueOf(&c, findNode(&ch, NodeKind.Binary)) == null).toBe(true);
    }
}

describe("hxsIntValue") {
    test("should add an integer value") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const v = valueAt(&c, hxsIntValue(&c, 7));

        expect(v.kind).toBe(HxValueInt as u8);
        expect(v.integer).toBe(7);
    }
}

describe("hxsBoolValue") {
    test("should add a boolean value") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);

        expect(valueAt(&c, hxsBoolValue(&c, true)).boolean).toBe(true);
    }
}

describe("hxsFloatValue") {
    test("should add a float value") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);

        expect(valueAt(&c, hxsFloatValue(&c, 0.5)).floating).toBe(0.5);
    }
}

describe("hxsErrorValue") {
    test("should add an error value that carries its code") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const v = valueAt(&c, hxsErrorValue(&c, 2));

        expect(v.kind).toBe(HxValueError as u8);
        expect(v.integer).toBe(2);
    }
}

describe("hxsIntMin") {
    test("should give the smallest value of signed and unsigned types") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIntMin(&c, types(&c).i8)).toBe(-128);
        expect(hxsIntMin(&c, types(&c).u64)).toBe(0);
        expect(hxsIntMin(&c, hxTypeInt(types(&c), true, 128)) == I128Min).toBe(true);
    }
}

describe("hxsIntMax") {
    test("should give the largest value of signed and unsigned types") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIntMax(&c, types(&c).i8)).toBe(127);
        expect(hxsIntMax(&c, types(&c).u8)).toBe(255);
    }

    test("should cap u128 at the largest i128") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIntMax(&c, hxTypeInt(types(&c), false, 128)) == I128Max).toBe(true);
    }
}

describe("hxsIntFits") {
    test("should accept the bounds and reject one past them") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIntFits(&c, types(&c).u8, 255)).toBe(true);
        expect(hxsIntFits(&c, types(&c).u8, 256)).toBe(false);
        expect(hxsIntFits(&c, types(&c).i8, -129)).toBe(false);
    }
}

describe("hxsWrapInt") {
    test("should wrap around the width of the type") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsWrapInt(&c, types(&c).u8, 256)).toBe(0);
        expect(hxsWrapInt(&c, types(&c).u8, -1)).toBe(255);
        expect(hxsWrapInt(&c, types(&c).i8, 128)).toBe(-128);
    }
}

describe("hxsIsComptimeNumber") {
    test("should accept only the types of number literals") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIsComptimeNumber(&c, types(&c).comptimeInt)).toBe(true);
        expect(hxsIsComptimeNumber(&c, types(&c).comptimeFloat)).toBe(true);
        expect(hxsIsComptimeNumber(&c, types(&c).i32)).toBe(false);
    }
}

describe("hxsIsNumeric") {
    test("should accept integers, floats, and literals") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIsNumeric(&c, types(&c).f32)).toBe(true);
        expect(hxsIsNumeric(&c, types(&c).comptimeInt)).toBe(true);
        expect(hxsIsNumeric(&c, types(&c).boolType)).toBe(false);
    }
}

describe("hxsIsInteger") {
    test("should accept integers and integer literals only") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIsInteger(&c, types(&c).u8)).toBe(true);
        expect(hxsIsInteger(&c, types(&c).comptimeInt)).toBe(true);
        expect(hxsIsInteger(&c, types(&c).f64)).toBe(false);
    }
}

describe("hxsIsFloat") {
    test("should accept floats and float literals only") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIsFloat(&c, types(&c).f64)).toBe(true);
        expect(hxsIsFloat(&c, types(&c).comptimeFloat)).toBe(true);
        expect(hxsIsFloat(&c, types(&c).i32)).toBe(false);
    }
}

describe("hxsPointedArray") {
    test("should find the array behind a pointer") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);
        const array = hxTypeArray(types(&c), types(&c).u8, 4);
        const pointer = hxTypePointer(types(&c), TypeKind.Pointer as u32, array, false);

        expect(hxsPointedArray(&c, pointer)).toBe(array);
        expect(hxsPointedArray(&c, array)).toBe(0);
    }
}

describe("hxsAggregateOf") {
    test("should give the aggregate of a struct with its fields") {
        let ch: Checked = undefined;
        check(&ch, "struct Point { x: i32, y: i32 }");
        defer release(&ch);
        const c = contextOf(&ch);
        const point = firstDeclType(&c);

        expect(hxsAggregateOf(&c, point).fieldCount).toBe(2);
        expect(hxsAggregateOf(&c, point).type).toBe(point);
    }
}

describe("hxsIsAggregate") {
    test("should accept a struct and reject Error and plain types") {
        let ch: Checked = undefined;
        check(&ch, "struct Point { x: i32 }");
        defer release(&ch);
        const c = contextOf(&ch);

        expect(hxsIsAggregate(&c, firstDeclType(&c))).toBe(true);
        expect(hxsIsAggregate(&c, types(&c).anyError)).toBe(false);
        expect(hxsIsAggregate(&c, types(&c).i32)).toBe(false);
    }
}

describe("hxsExpectedBase") {
    test("should strip optionals and error unions") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        const c = contextOf(&ch);
        const tys = types(&c);
        const wrapped = hxTypeOptional(tys, tys.i32);

        expect(hxsExpectedBase(&c, wrapped)).toBe(tys.i32);
        expect(hxsExpectedBase(&c, tys.string)).toBe(tys.string);
    }
}

describe("hxsSetSubset") {
    test("should accept a set whose errors are all in the other") {
        expect(report("error A { X }\nerror B { X, Y }\nfunction f(): void | B { throw A.X; }")).toBe("");
    }

    test("should reject a set with an error that the other lacks") {
        expect(report("error A { X }\nerror B { X, Y }\nfunction f(): void | A { throw B.Y; }"))
            .toInclude("expected `");
    }
}

describe("hxsImplicitOk") {
    test("should allow widening an integer and refuse narrowing it") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);

        expect(hxsImplicitOk(&c, types(&c).u8, types(&c).i16)).toBe(true);
        expect(hxsImplicitOk(&c, types(&c).i16, types(&c).u8)).toBe(false);
        expect(hxsImplicitOk(&c, types(&c).u16, types(&c).i16)).toBe(false);
    }

    test("should allow a mutable pointer to become readonly and not the other way") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const tys = types(&c);
        const mutable = hxTypePointer(tys, TypeKind.Pointer as u32, tys.i32, false);
        const readonly = hxTypePointer(tys, TypeKind.Pointer as u32, tys.i32, true);

        expect(hxsImplicitOk(&c, mutable, readonly)).toBe(true);
        expect(hxsImplicitOk(&c, readonly, mutable)).toBe(false);
    }

    test("should allow a value and null into an optional") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const tys = types(&c);

        expect(hxsImplicitOk(&c, tys.i32, hxTypeOptional(tys, tys.i32))).toBe(true);
        expect(hxsImplicitOk(&c, tys.nullType, hxTypeOptional(tys, tys.i32))).toBe(true);
    }

    test("should allow a string literal into a string and a pointer to an array into a slice") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const tys = types(&c);
        const array = hxTypeArray(tys, tys.u8, 4);
        const pointer = hxTypePointer(tys, TypeKind.Pointer as u32, array, false);

        expect(hxsImplicitOk(&c, tys.stringLiteral, tys.string)).toBe(true);
        expect(hxsImplicitOk(&c, pointer, tys.string)).toBe(true);
    }
}

describe("hxsMismatch") {
    test("should suggest a null check for an optional where its payload was expected") {
        expect(report("function f(x: ?i32): i32 { return x; }"))
            .toBe("expected `i32`, found `?i32`\nhint: this may be null; use `x ?? fallback`, `x!`, or check `x != null` first\n");
    }

    test("should suggest an explicit conversion between number types") {
        expect(report("function f(x: i64): i32 { return x; }"))
            .toInclude("hint: convert explicitly with `as i32`");
    }

    test("should explain that Helix has no truthiness") {
        expect(report("function f(x: i32): bool { return x; }")).toInclude("Helix has no truthiness");
    }
}

describe("hxsCoerce") {
    test("should report an integer literal that does not fit and name the range") {
        expect(report("const x: u8 = 300;")).toBe("integer 300 does not fit in `u8`\nhint: `u8` holds 0 to 255\n");
    }

    test("should convert a literal to the payload of an optional") {
        expect(report("const x: ?i32 = 5;")).toBe("");
    }

    test("should convert each branch of a ternary of literals") {
        expect(report("function f(ok: bool): u8 { return ok ? 1 : 300; }")).toInclude("integer 300 does not fit in `u8`");
    }
}

describe("hxsCAbiDiffers") {
    test("should flag slices and leave plain numbers and pointer optionals alone") {
        let ch: Checked = undefined;
        check(&ch, "");
        defer release(&ch);
        let c = contextOf(&ch);
        const tys = types(&c);
        const pointer = hxTypePointer(tys, TypeKind.Pointer as u32, tys.i32, false);

        expect(hxsCAbiDiffers(&c, tys.string)).toBe(true);
        expect(hxsCAbiDiffers(&c, tys.i32)).toBe(false);
        expect(hxsCAbiDiffers(&c, hxTypeOptional(tys, pointer))).toBe(false);
        expect(hxsCAbiDiffers(&c, hxTypeOptional(tys, tys.i32))).toBe(true);
    }
}

describe("hxsCCallConvertible") {
    test("should let a named function become a C callback") {
        expect(report("function cb(_s: string): void {}\nconst f: extern \"C\" (s: string) => void = cb;")).toBe("");
    }

    test("should refuse a function pointer from a variable") {
        expect(report("function cb(_s: string): void {}\nfunction g(h: (s: string) => void): void { const f: extern \"C\" (s: string) => void = h; }"))
            .toInclude("pass structs by value differently");
    }
}

describe("hxsPeer") {
    test("should convert a literal to the type of the other operand") {
        expect(report("function f(x: u8): u8 { return x + 1; }")).toBe("");
    }

    test("should report operands that share no type") {
        expect(report("function f(a: i32, b: bool): void { const c = a == b; }"))
            .toInclude("mismatched operand types `i32` and `bool`");
    }
}

describe("hxsFormatEscapes") {
    test("should refuse a Format field") {
        expect(report("struct Line { text: Format }")).toInclude("a `Format` can only be a parameter's type");
    }

    test("should allow a Format parameter") {
        expect(report("function f(_m: Format): void {}")).toBe("");
    }
}
