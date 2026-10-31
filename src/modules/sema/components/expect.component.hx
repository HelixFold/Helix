/**
 * Imports
 */

import { Ctx } from "@structs/sema.struct";
import { record } from "@models/ast.model";
import { NodeKind } from "@constants/ast.constant";
import { hxIntern } from "@services/intern.service";
import { TypeKind } from "@constants/types.constant";
import { HxRange } from "@models/structs/ast-model.struct";
import { hxTypeErrorUnion, hxTypeArray } from "@models/types.model";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { Matchers, Matcher } from "@modules/sema/constants/expect.constant";
import { hxsRuntimeType } from "@modules/sema/components/generics.component";
import { hxsCheckArgsUnknown } from "@modules/sema/components/call.component";
import { hxsLookup, hxsScopeFind } from "@modules/sema/components/scope.component";
import { hxsResolveAggregate } from "@modules/sema/components/aggregate.component";
import { HxMemberField, HxExpectNot, HxExpectRequire, HxInfoExpect } from "@constants/sema.constant";
import { memberAt, tokenText, typeName, errorNode, errorToken } from "@modules/sema/components/base.component";
import { astOf, nodeOf, typeOf, symbolOf, infoOf, extraOf, types } from "@modules/sema/components/base.component";
import { hint, hintf, hxsTokName, hxsCoerce, hxsAggregateOf, semaOf } from "@modules/sema/components/base.component";

/**
 * Compares two strings byte by byte.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns `true` when both strings have the same length and bytes
 *
 * @remarks
 * Compares the lengths first, so texts of different lengths return early without reading a byte.
 * The comparison is exact, so letters of different case never match.
 *
 * @since 1.0.0
 */

function sameText(a: string, b: string): bool {
    if (a.len != b.len) return false;
    for (const ch, i of a) {
        if (b[i] != ch) return false;
    }
    return true;
}

/**
 * Checks whether a type is text, a string literal or a `u8` slice.
 *
 * @param c - The checker context
 * @param t - The type to check
 * @returns `true` for a string literal type or a slice of `u8`
 *
 * @remarks
 * Any `u8` slice counts, readonly or not, since only the child type is compared.
 * Matchers such as `toStartWith` use it to accept their subject.
 *
 * @example
 * ```hx
 * hxsIsText(c, types(c).string); // true
 * hxsIsText(c, types(c).i32);    // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIsText(c: readonly *Ctx, t: u32): bool {
    return typeOf(c, t).kind == TypeKind.StringLiteral || (typeOf(c, t).kind == TypeKind.Slice && typeOf(c, t).child == types(c).u8);
}

/**
 * Checks whether `toBe` and `toContain` can compare values of a type.
 *
 * @param c - The checker context
 * @param t - The type to check
 * @returns `true` for the types that `==` works on, for text, and for optionals of either
 *
 * @remarks
 * The types that `==` works on are integers, floats, booleans, enums, error sets, and pointers.
 * Text compares by its bytes.
 *
 * @example
 * ```hx
 * // struct Point { x: i32 }
 * hxsIdentityComparable(c, optionalI32); // true
 * hxsIdentityComparable(c, point);       // false
 * ```
 *
 * @see hxsDeepComparable
 * @since 1.0.0
 */

export extern "C" function hxsIdentityComparable(c: *Ctx, t: u32): bool {
    return switch (typeOf(c, t).kind) {
        case TypeKind.Int, TypeKind.Float, TypeKind.Bool, TypeKind.Enum, TypeKind.ErrorSet, TypeKind.Pointer,
             TypeKind.ManyPointer: true;
        case TypeKind.Optional: hxsIdentityComparable(c, typeOf(c, t).child);
        default: hxsIsText(c, t);
    };
}

/**
 * Checks whether `toEqual` and `toContainEqual` can compare values of a type.
 *
 * @param c - The checker context
 * @param t - The type to check
 * @param depth - How many types deep the check already is, 0 at the start
 * @returns `true` for a type made only of values, compared field by field and element by element
 *
 * @remarks
 * Beyond what {@link hxsIdentityComparable} accepts, functions also count,
 * and optionals, arrays, slices, and error unions count when their child does.
 * A struct or a union counts when each of its fields does, and an interface or a `dyn` value never does.
 * Past a depth of 32 a type counts, since a type that recurses through slices or pointers
 * has a comparison function that recurses too.
 *
 * @example
 * ```hx
 * // struct Point { x: i32 }
 * hxsDeepComparable(c, point, 0); // true
 * ```
 *
 * @see hxsIdentityComparable
 * @since 1.0.0
 */

export extern "C" function hxsDeepComparable(c: *Ctx, t: u32, depth: u32): bool {
    if (depth > 32) return true;   // recursive through slices or pointers: the generated function recurses too
    const type = typeOf(c, t);
    switch (type.kind) {
        case TypeKind.Int, TypeKind.Float, TypeKind.Bool, TypeKind.Enum, TypeKind.ErrorSet, TypeKind.Pointer,
             TypeKind.ManyPointer, TypeKind.Function, TypeKind.StringLiteral: return true;
        case TypeKind.Optional, TypeKind.Array, TypeKind.Slice, TypeKind.ErrorUnion: {
            return type.child == types(c).voidType || hxsDeepComparable(c, type.child, depth + 1);
        }
        case TypeKind.Struct, TypeKind.Union: {
            hxsResolveAggregate(c, t);
            const agg = *hxsAggregateOf(c, t);
            for (const i of 0..agg.membersCount) {
                const m = *memberAt(c, agg.membersStart + i);
                if (m.kind == HxMemberField as u8 && m.type != 0 && !hxsDeepComparable(c, m.type, depth + 1)) return false;
            }
            return true;
        }
        default: return false;
    }
}

/**
 * Splits a call shaped like `expect(x).not.toBe(y)` into its parts.
 *
 * @param c - The checker context
 * @param node - The call of the matcher
 * @param subjectCall - Receives the call of `expect` or `require`, whose one argument is the subject
 * @param matcher - Receives the token of the name of the matcher
 * @param negated - Receives whether a `.not` comes before the matcher
 * @param isRequire - Receives whether the call is `require` rather than `expect`
 * @returns `true` when the call has this shape, otherwise `false`
 *
 * @remarks
 * The call is not a matcher when `expect` or `require` names something that the program declared,
 * so a function of that name keeps working.
 * The checker only tries this inside `test` blocks and hooks.
 *
 * @example
 * ```hx
 * // expect(total).not.toBe(0)
 * hxsExpectParts(c, node, &subject, &matcher, &negated, &isRequire); // true, negated, matcher toBe
 * ```
 *
 * @see hxsCheckExpect
 * @since 1.0.0
 */

export extern "C" function hxsExpectParts(c: *Ctx, node: u32, subjectCall: *u32, matcher: *u32, negated: *bool, isRequire: *bool): bool {
    const callee = nodeOf(c, node).a;
    if (nodeOf(c, callee).kind != NodeKind.FieldAccess) return false;
    *matcher = nodeOf(c, callee).token;
    let base = nodeOf(c, callee).a;
    *negated = nodeOf(c, base).kind == NodeKind.FieldAccess && sameText(tokenText(c, nodeOf(c, base).token), "not");
    if (*negated) base = nodeOf(c, base).a;
    if (nodeOf(c, base).kind != NodeKind.Call || nodeOf(c, nodeOf(c, base).a).kind != NodeKind.Ident) return false;
    const text = tokenText(c, nodeOf(c, nodeOf(c, base).a).token);
    *isRequire = sameText(text, "require");
    if (!*isRequire && !sameText(text, "expect")) return false;
    if (hxsLookup(c, hxsTokName(c, nodeOf(c, nodeOf(c, base).a).token)) != 0) return false;
    *subjectCall = base;
    return true;
}

/**
 * Checks `expect(x).toBe(y)` and the other matchers, where the type of the subject decides which matchers fit.
 *
 * @param c - The checker context
 * @param node - The call of the matcher
 * @param subjectCall - The call of `expect` or `require`
 * @param matcherToken - The token of the name of the matcher
 * @param negated - Whether a `.not` comes before the matcher
 * @param isRequire - Whether the call is `require` rather than `expect`
 * @returns `void` for `expect`, and `void | TestError` for `require`, which fails with `TestError.RequireFailed`
 *
 * @remarks
 * The checks run in this order, and the first one that fails reports and stops:
 * - `expect` takes exactly one value, and a check may not sit inside `comptime`, since it runs with the test.
 * - The name must be one of {@link Matchers}.
 * - The matcher must get the right number of arguments.
 *   Most take one, `toBeNull`, `toBeDefined`, `toBeTrue`, `toBeFalse`, and `toSucceed` take none,
 *   `toThrow` takes at most one error, and `toBeCloseTo` takes a number and, optionally, the digits to compare.
 * - The subject must have a type that the matcher fits, such as an optional for `toBeNull`,
 *   a number for the ordering matchers, a list for `toHaveLength` and `toContain`, a string for `toStartWith`,
 *   and a call that can fail for `toThrow`.
 *   The error hints at `toEqual` where `toBe` cannot compare a value that `toEqual` can.
 *
 * The subject first takes its runtime type, so an integer literal becomes `i64`.
 * Each argument then converts to the type that the matcher compares with.
 * An array literal compared with a slice is checked as an array of the slice's items.
 * On success the node is marked as an expectation that records the matcher, `.not`, and `require`.
 *
 * @example
 * ```hx
 * // test("sum") { expect(1).toBeNull(); }
 * hxsCheckExpect(c, node, subject, matcher, false, false); // error: `toBeNull` needs an optional (`?T`)
 * ```
 *
 * @see hxsExpectParts
 * @since 1.0.0
 */

export extern "C" function hxsCheckExpect(c: *Ctx, node: u32, subjectCall: u32, matcherToken: u32, negated: bool, isRequire: bool): u32 {
    const subjectArgs = record<HxRange>(astOf(c), nodeOf(c, subjectCall).b);
    const args = record<HxRange>(astOf(c), nodeOf(c, node).b);
    const who = isRequire ? "require" : "expect";
    const tys = types(c);
    const s = semaOf(c);
    let result = isRequire ? s.testResult : tys.voidType;
    // `require` fails with `TestError.RequireFailed`, so its result is `void | TestError`
    if (isRequire && s.requireCode != 0) {
        if (const entry = hxsScopeFind(s, s.program!.testingModule - 1, hxIntern(&s.names, "TestError", 9))) {
            result = hxTypeErrorUnion(tys, tys.voidType, symbolOf(c, entry.symbol).type);
        }
    }

    const name = tokenText(c, matcherToken);
    let found: ?Matcher = null;
    for (const m, i of Matchers) {
        if (sameText(name, m)) found = @enumFromInt(Matcher, @truncate(u32, i));
    }
    if (subjectArgs.end - subjectArgs.start != 1) {
        const diag = errorNode(c, subjectCall, `\`${who}\` takes the one value to check`);
        hintf(c, diag, `write \`${who}(actual).toBe(expected)\``);
        hxsCheckArgsUnknown(c, subjectCall);
        hxsCheckArgsUnknown(c, node);
        return result;
    }
    const subject = extraOf(c, subjectArgs.start);
    let actual = hxsCheckExpr(c, subject, 0);
    const written = actual;   // for messages: `integer literal` rather than the `i64` it becomes
    if (actual != 0 && actual != hxsRuntimeType(c, actual)) {
        void hxsCoerce(c, subject, hxsRuntimeType(c, actual));
        actual = hxsRuntimeType(c, actual);
    }
    if (c.comptimeDepth != 0) {
        const diag = errorNode(c, node, `\`${who}\` checks run with the test, not while compiling`);
        hint(c, diag, "check at compile time with `assert` from \"std\", or move this out of `comptime`");
        hxsCheckArgsUnknown(c, node);
        return result;
    }
    if (found == null) {
        const diag = errorToken(c, matcherToken, `\`${name}\` isn't a matcher`);
        hint(c, diag, "matchers: toBe, toEqual, toBeNull, toBeDefined, toBeTrue, toBeFalse, toBeGreaterThan(OrEqual), toBeLessThan(OrEqual), toBeCloseTo, toHaveLength, toContain, toContainEqual, toStartWith, toEndWith, toInclude, toMatch, toThrow, toSucceed");
        hxsCheckArgsUnknown(c, node);
        return result;
    }
    const matcher = found!;

    const count = args.end - args.start;
    let min: u32 = 1;
    let max: u32 = 1;
    switch (matcher) {
        case Matcher.ToBeNull, Matcher.ToBeDefined, Matcher.ToBeTrue, Matcher.ToBeFalse, Matcher.Succeed: {
            min = 0;
            max = 0;
        }
        case Matcher.Throw: min = 0;
        case Matcher.CloseTo: max = 2;
        default: {}
    }
    if (count < min || count > max) {
        const takes = max == 0 ? "no arguments" : min == 0 ? "at most one error"
                    : max == 2 ? "a number and, optionally, the digits to compare" : "one argument";
        const diag = errorNode(c, node, `\`${name}\` takes ${takes}`);
        if (matcher == Matcher.ToBe && count == 0) hint(c, diag, "to check for null, use `toBeNull()`");
        hxsCheckArgsUnknown(c, node);
        return result;
    }
    if (actual == 0) {
        hxsCheckArgsUnknown(c, node);
        return result;
    }

    // what the subject must be, and what each argument converts to
    let needs: string = "";
    let argType = actual;
    const at = typeOf(c, actual);
    switch (matcher) {
        case Matcher.ToBe: {
            if (!hxsIdentityComparable(c, actual)) {
                const diag = errorNode(c, node, `\`toBe\` compares with \`==\`, which \`${typeName(c, actual)}\` doesn't have`);
                if (hxsDeepComparable(c, actual, 0)) {
                    hintf(c, diag, `use \`toEqual\`, which compares ${at.kind == TypeKind.Struct ? "field by field" : "element by element"}`);
                }
                hxsCheckArgsUnknown(c, node);
                return result;
            }
        }
        case Matcher.ToEqual: {
            if (!hxsDeepComparable(c, actual, 0)) {
                void errorNode(c, node, `\`toEqual\` can't compare \`${typeName(c, actual)}\``);
                hxsCheckArgsUnknown(c, node);
                return result;
            }
        }
        case Matcher.ToBeNull, Matcher.ToBeDefined: if (at.kind != TypeKind.Optional) needs = "an optional (`?T`)";
        case Matcher.ToBeTrue, Matcher.ToBeFalse: if (at.kind != TypeKind.Bool) needs = "a `bool`";
        case Matcher.Greater, Matcher.GreaterEqual, Matcher.Less, Matcher.LessEqual: {
            if (at.kind != TypeKind.Int && at.kind != TypeKind.Float) needs = "a number";
        }
        case Matcher.CloseTo: if (at.kind != TypeKind.Float) needs = "a float";
        case Matcher.Length: {
            if (at.kind != TypeKind.Slice && at.kind != TypeKind.Array) needs = "a slice, array or string";
            argType = tys.usize;
        }
        case Matcher.Contain, Matcher.ContainEqual: {
            if (at.kind != TypeKind.Slice && at.kind != TypeKind.Array) {
                needs = "a slice or array";
            } else {
                argType = at.child;
                if (matcher == Matcher.Contain && !hxsIdentityComparable(c, argType)) {
                    const diag = errorNode(c, node, `\`toContain\` compares items with \`==\`, which \`${typeName(c, argType)}\` doesn't have`);
                    if (hxsDeepComparable(c, argType, 0)) hint(c, diag, "use `toContainEqual`, which compares them field by field");
                    hxsCheckArgsUnknown(c, node);
                    return result;
                }
                if (!hxsDeepComparable(c, argType, 0)) {
                    void errorNode(c, node, `\`toContainEqual\` can't compare \`${typeName(c, argType)}\``);
                    hxsCheckArgsUnknown(c, node);
                    return result;
                }
            }
        }
        case Matcher.StartWith, Matcher.EndWith, Matcher.Include, Matcher.Match: {
            if (!hxsIsText(c, actual)) needs = "a string";
            argType = tys.string;
        }
        case Matcher.Throw, Matcher.Succeed: {
            if (at.kind != TypeKind.ErrorUnion) needs = "a call that can fail (`T | Error`)";
            argType = 0;
        }
    }
    if (needs.len > 0) {
        const diag = errorNode(c, subject, `\`${name}\` needs ${needs}, but this is \`${typeName(c, written)}\``);
        if (at.kind == TypeKind.ErrorUnion) hintf(c, diag, `check the value with \`${who}(try ...)\`, or the error with \`toThrow\``);
        else if (matcher == Matcher.ToBeNull || matcher == Matcher.ToBeDefined) hintf(c, diag, `a \`${typeName(c, actual)}\` is never null`);
        hxsCheckArgsUnknown(c, node);
        return result;
    }

    for (const i of args.start..args.end) {
        const arg = extraOf(c, i);
        if (matcher == Matcher.CloseTo && i > args.start) {   // the digits
            void hxsCheckExpr(c, arg, tys.i32);
            void hxsCoerce(c, arg, tys.i32);
        } else if (matcher == Matcher.Throw) {   // `toThrow(ParseError.Empty)`
            const t = hxsCheckExpr(c, arg, 0);
            if (t != 0 && typeOf(c, t).kind != TypeKind.ErrorSet) {
                const diag = errorNode(c, arg, `\`toThrow\` takes an error, like \`MyError.Case\`, but this is \`${typeName(c, t)}\``);
                hint(c, diag, "leave it out to accept any error: `toThrow()`");
            }
        } else {
            // `expect(list.items).toEqual([1, 2])`: the literal is an array, compared item by item with the slice
            const want = nodeOf(c, arg).kind == NodeKind.ArrayLiteral && typeOf(c, argType).kind == TypeKind.Slice
                       ? hxTypeArray(tys, typeOf(c, argType).child, (nodeOf(c, arg).b - nodeOf(c, arg).a) as u64) : argType;
            const errorsBefore = s.diags!.errorCount;
            if (hxsCheckExpr(c, arg, want) != 0 && s.diags!.errorCount == errorsBefore) void hxsCoerce(c, arg, want);
        }
    }
    infoOf(c, node).flags |= HxInfoExpect;
    infoOf(c, node).aux = (matcher as u32) | (negated ? HxExpectNot : 0) | (isRequire ? HxExpectRequire : 0);
    return result;
}
