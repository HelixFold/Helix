/**
 * Imports
 */

import { Ctx } from "@structs/sema.struct";
import { record } from "@models/ast.model";
import { NodeKind } from "@constants/ast.constant";
import { TypeKind } from "@constants/types.constant";
import { hxArenaAlloc } from "@services/arena.service";
import { HxRange } from "@models/structs/ast-model.struct";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { hxsResolveAggregate } from "@modules/sema/components/aggregate.component";
import { hxsDecodeEscape, hxsEncodeUtf8 } from "@modules/sema/components/scope.component";
import { hxsCheckArgsUnknown, hxsCheckArgs } from "@modules/sema/components/call.component";
import { HxMemberField, HxValueString, HxInfoPrint, HxInfoIndirect } from "@constants/sema.constant";
import { hxsValueOf, hxsAddValue, hxsCoerce, hxsAggregateOf } from "@modules/sema/components/base.component";
import { emptyValue, memberAt, tokenText, typeName, errorNode, hint } from "@modules/sema/components/base.component";
import { hintf, semaOf, astOf, nodeOf, typeOf, infoOf, extraOf, types } from "@modules/sema/components/base.component";

/**
 * Checks whether the compiler can generate the formatting for a type.
 *
 * @param c - The checker context
 * @param t - The type to check
 * @param depth - The nesting depth reached so far, 0 at the printed value itself
 * @returns `true` when a value of the type can be printed
 *
 * @remarks
 * This file covers `print` and template strings: what can be printed,
 * and the text between the substitutions of a template.
 * Integers up to 64 bits, floats, booleans, pointers, enums, and error sets print directly.
 * Pointers print their address, so the recursion ends at them.
 * Optionals, arrays, and slices print when their element does,
 * and structs and unions print when every field does.
 * Past a depth of 32 the answer is always `true`,
 * since codegen handles a deeply nested type, or one recursive through slices, with functions.
 *
 * @example
 * ```hx
 * hxsPrintable(c, int32, 0);      // true, where int32 is the i32 type
 * hxsPrintable(c, voidType, 0);   // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsPrintable(c: *Ctx, t: u32, depth: u32): bool {
    if (depth > 32) return true;   // deeply nested or recursive through slices: codegen handles it with functions
    const type = typeOf(c, t);
    switch (type.kind) {
        case TypeKind.Int: return type.bits <= 64;
        case TypeKind.Float, TypeKind.Bool, TypeKind.Pointer, TypeKind.ManyPointer, TypeKind.Enum, TypeKind.ErrorSet: return true;
        case TypeKind.Optional, TypeKind.Array, TypeKind.Slice: return hxsPrintable(c, type.child, depth + 1);
        case TypeKind.Struct, TypeKind.Union: {
            hxsResolveAggregate(c, t);
            const agg = *hxsAggregateOf(c, t);
            for (const i of 0..agg.membersCount) {
                const m = *memberAt(c, agg.membersStart + i);
                if (m.kind == HxMemberField as u8 && m.type != 0 && !hxsPrintable(c, m.type, depth + 1)) return false;
            }
            return true;
        }
        default: return false;
    }
}

/**
 * Checks one printed value and gives it a runtime type.
 *
 * @param c - The checker context
 * @param node - The expression being printed
 *
 * @remarks
 * Literals have no runtime type of their own, so a compile-time integer becomes `i64` when it is negative
 * and `u64` otherwise, a compile-time float becomes `f64`, and a string literal becomes `string`.
 * Any other type must pass {@link hxsPrintable}, or the value is reported as one that can't be printed.
 * The error carries a hint for an error union, for an integer wider than 64 bits, and for `void`.
 *
 * @example
 * ```hx
 * // println(`value ${work()}`);   work returns u32 | Problem
 * hxsCheckPrinted(c, node); // error: `u32 | Problem` can't be printed
 * ```
 *
 * @see hxsPrintable
 * @since 1.0.0
 */

export extern "C" function hxsCheckPrinted(c: *Ctx, node: u32): void {
    const t = hxsCheckExpr(c, node, 0);
    if (t == 0) return;
    const tys = types(c);
    const kind = typeOf(c, t).kind;
    if (kind == TypeKind.ComptimeInt) {
        const v = hxsValueOf(c, node);
        void hxsCoerce(c, node, v != null && v.integer < 0 ? tys.i64 : tys.u64);
        return;
    }
    if (kind == TypeKind.ComptimeFloat) {
        void hxsCoerce(c, node, tys.f64);
        return;
    }
    if (kind == TypeKind.StringLiteral) {
        void hxsCoerce(c, node, tys.string);
        return;
    }
    if (hxsPrintable(c, t, 0)) return;
    const diag = errorNode(c, node, `\`${typeName(c, t)}\` can't be printed`);
    if (kind == TypeKind.ErrorUnion) hint(c, diag, "handle the error first with `try` or `catch`");
    else if (kind == TypeKind.Int) hint(c, diag, "integers up to 64 bits can be printed");
    else if (t == tys.voidType) hint(c, diag, "this expression has no value");
}

/**
 * Decodes one piece of text between the delimiters of a template into a string value.
 *
 * @param c - The checker context
 * @param node - The template text node
 *
 * @remarks
 * The delimiters are the backtick, `${`, and `}`.
 * Decoding starts after the opening backtick or `}` and stops before the closing backtick,
 * or before the `${` of a head or middle piece.
 * Escapes decode as in a string literal, and the bytes go to the checker's arena with a NUL after them.
 * The node gets the value and the type `string`.
 *
 * @example
 * ```hx
 * // `total ${n}`
 * hxsDecodeTemplateText(c, head); // the value "total " of type string
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsDecodeTemplateText(c: *Ctx, node: u32): void {
    const token = nodeOf(c, node).token;
    const text = tokenText(c, token);
    let kind = TokenKind.Eof;
    unsafe {
        kind = @enumFromInt(TokenKind, c.tokens!.kinds![token]);
    }
    const end = @truncate(u32, text.len) - (kind == TokenKind.TemplateHead || kind == TokenKind.TemplateMiddle ? 2 : 1);
    const bytes = hxArenaAlloc(&semaOf(c).arena, text.len + 1, 1);
    let out: u32 = 0;
    let i: u32 = 1;   // after the opening backtick or `}`
    unsafe {
        while (i < end) {
            if (text[i] == '\\') {
                let raw = false;
                const cp = hxsDecodeEscape(text.ptr, &i, &raw);
                if (raw) {
                    bytes[out] = @truncate(u8, cp);
                    out += 1;
                } else {
                    out += hxsEncodeUtf8(cp, @ptrFromInt(u8[*], @intFromPtr(bytes) + (out as usize)));
                }
            } else {
                bytes[out] = text[i];
                out += 1;
                i += 1;
            }
        }
        bytes[out] = 0;
    }
    let v = emptyValue(HxValueString as u8);
    v.bytes = bytes;
    v.len = out;
    infoOf(c, node).value = hxsAddValue(c, v);
    infoOf(c, node).type = types(c).string;
}

/**
 * Checks every part of a template string.
 *
 * @param c - The checker context
 * @param node - The template node
 *
 * @remarks
 * Text parts are decoded with {@link hxsDecodeTemplateText},
 * and each substitution is checked as a printed value with {@link hxsCheckPrinted}.
 * The template node itself gets the type `void`.
 *
 * @example
 * ```hx
 * // println(`result ${nothing()}`);
 * hxsCheckTemplateParts(c, template); // error: `void` can't be printed
 * ```
 *
 * @see hxsCheckPrinted
 * @since 1.0.0
 */

export extern "C" function hxsCheckTemplateParts(c: *Ctx, node: u32): void {
    for (const i of nodeOf(c, node).a..nodeOf(c, node).b) {
        const part = extraOf(c, i);
        if (nodeOf(c, part).kind == NodeKind.TemplateText) hxsDecodeTemplateText(c, part);
        else hxsCheckPrinted(c, part);
    }
    infoOf(c, node).type = types(c).voidType;
}

/**
 * Checks a call to `print`, `println`, `eprint`, or `eprintln`.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param kind - The index of the function: 0 for `print`, 1 for `println`, 2 for `eprint`, 3 for `eprintln`
 * @param namePtr - The name of the function, for the messages
 * @param len - The length of the name in bytes
 * @returns The `void` type
 *
 * @remarks
 * The call takes exactly one argument, either a template string such as `` print(`total ${n}`) ``
 * or a single value such as `print(value)`.
 * Any other count is an error with a hint to put everything in one template.
 * The formatting is generated at compile time for the type of each value,
 * so the node is flagged as a print and keeps `kind` for codegen.
 *
 * @example
 * ```hx
 * // print("a", "b");
 * hxsCheckPrint(c, node, 0, name, 5); // error: `print` takes one template string or value
 * ```
 *
 * @see hxsCheckTemplateParts
 * @since 1.0.0
 */

export extern "C" function hxsCheckPrint(c: *Ctx, node: u32, kind: u32, namePtr: readonly u8[*], len: i32): u32 {
    let name: string = "";
    unsafe {
        name = namePtr[0..len as usize];
    }
    const args = record<HxRange>(astOf(c), nodeOf(c, node).b);
    if (args.end - args.start != 1) {
        const diag = errorNode(c, node, `\`${name}\` takes one template string or value`);
        hintf(c, diag, `put everything in one template: \`${name}(\`total: \${n}\`)\``);
        hxsCheckArgsUnknown(c, node);
        return types(c).voidType;
    }
    const arg = extraOf(c, args.start);
    if (nodeOf(c, arg).kind == NodeKind.Template) hxsCheckTemplateParts(c, arg);
    else hxsCheckPrinted(c, arg);
    infoOf(c, node).flags |= HxInfoPrint;
    infoOf(c, node).aux = kind;
    return types(c).voidType;
}

/**
 * Checks a call through a value of function type.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param callee - The callee expression, which is already checked
 * @param calleeType - The type of the callee, or 0 when it has an error
 * @returns The result type of the function, or 0 on an error
 *
 * @remarks
 * The callee may be a variable, a field, or any expression.
 * A callee that is not a function is an error, with a hint to check for null first
 * when the callee is an optional function.
 * The arguments are still checked on an error, so their own mistakes are reported.
 *
 * @example
 * ```hx
 * // const n: i32 = 1;   n(2);
 * hxsIndirectCall(c, node, callee, int32); // error: `i32` is not a function, so it can't be called
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIndirectCall(c: *Ctx, node: u32, callee: u32, calleeType: u32): u32 {
    if (calleeType == 0) {
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    const t = typeOf(c, calleeType);
    if (t.kind != TypeKind.Function) {
        const diag = errorNode(c, callee, `\`${typeName(c, calleeType)}\` is not a function, so it can't be called`);
        if (t.kind == TypeKind.Optional && typeOf(c, t.child).kind == TypeKind.Function) {
            hint(c, diag, "it might be null; check `!= null` first, or call `f!(...)`");
        }
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    infoOf(c, node).flags |= HxInfoIndirect;
    hxsCheckArgs(c, node, calleeType, 0, "this function", 13);
    return t.child;
}
