/**
 * Imports
 */

import { Ctx } from "@structs/sema.struct";
import { record } from "@models/ast.model";
import { NodeKind } from "@constants/ast.constant";
import { HxMemberMethod } from "@constants/sema.constant";
import { TypeKind, Readonly } from "@constants/types.constant";
import { hxEvalExpr } from "@modules/sema/services/eval.service";
import { hxTypePointer, hxTypeArray } from "@models/types.model";
import { hxsLookup } from "@modules/sema/components/scope.component";
import { noteNotRead } from "@modules/sema/components/unset.component";
import { HxRange, HxSliceData } from "@models/structs/ast-model.struct";
import { hxsResolveGlobal } from "@modules/sema/components/decl.component";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { hxsModuleMember } from "@modules/sema/components/imports.component";
import { hxsCheckExpr, hxsEvalHost } from "@modules/sema/components/expr.component";
import { hxsMethodInstance, hxsRuntimeType } from "@modules/sema/components/generics.component";
import { hxsMarkUsed, hxsIsMutablePlace, hxsPlaceRoot } from "@modules/sema/components/call.component";
import { hint, hintf, i128Text, hxsTokName, hxsValueOf } from "@modules/sema/components/base.component";
import { hxsPointedArray, hxsExpectedBase, hxsIsAggregate } from "@modules/sema/components/base.component";
import { hxsResolveAggregate, hxsFindMember, hxsMemberOf } from "@modules/sema/components/aggregate.component";
import { memberAt, tokenText, typeName, errorNode, errorToken } from "@modules/sema/components/base.component";
import { hxsFunctionValue, hxsCheckSymbolValue, hxsTypeNameRef } from "@modules/sema/components/call.component";
import { hxsIntValue, hxsErrorValue, hxsCoerce, hxsAggregateOf } from "@modules/sema/components/base.component";
import { HxSymMutated, HxInfoModuleRef, HxSymLocal, HxInfoDeref, HxMemberField } from "@constants/sema.constant";
import { astOf, nodeOf, typeOf, symbolOf, infoOf, extraOf, types } from "@modules/sema/components/base.component";
import { hxsImplicitOk, hxsIsComptimeNumber, hxsIsNumeric, semaOf } from "@modules/sema/components/base.component";
import { HxInfoUnionInit, HxSymGlobal, HxSymParam, HxSymTemplateMethod, HxInfoField } from "@constants/sema.constant";

/**
 * Compares two strings byte by byte.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns `true` when both strings have the same length and the same bytes
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
 * Checks an index expression `x[i]`.
 *
 * @param c - The checker context
 * @param node - The index node, whose operands are the base and the index
 * @returns The element type, or 0 when the base cannot be indexed
 *
 * @remarks
 * This file checks reading parts of values, such as indexing, slicing, fields, and members,
 * and the literals that build structs and arrays.
 * The index is checked as a `usize`.
 * Arrays, pointers to arrays, slices, and string literals can be indexed,
 * and a string literal gives a `u8`.
 * An index that is known while compiling is checked against the length of an array.
 * Indexing a raw many-item pointer needs `unsafe { }`, since nothing checks its bounds.
 *
 * @example
 * ```hx
 * // const a: i32[4] = [1, 2, 3, 4];   a[4]
 * hxsCheckIndex(c, node); // error: index 4 is out of bounds for `i32[4]`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckIndex(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const base = hxsCheckExpr(c, n.a, 0);
    void hxsCheckExpr(c, n.b, types(c).usize);
    if (base == 0) return 0;
    const b = typeOf(c, base);
    const array = b.kind == TypeKind.Array ? base : hxsPointedArray(c, base);
    if (array != 0) {
        const len = typeOf(c, array).len;
        if (const index = hxsValueOf(c, n.b)) {
            if (index.integer >= 0 && @truncate(u64, index.integer) >= len) {
                let buf: u8[48] = undefined;
                void errorNode(c, n.b, `index ${i128Text(index.integer, &buf)} is out of bounds for \`${typeName(c, array)}\``);
            }
        }
        return typeOf(c, array).child;
    }
    if (b.kind == TypeKind.Slice) return b.child;
    if (b.kind == TypeKind.StringLiteral) return types(c).u8;
    if (b.kind == TypeKind.ManyPointer) {
        if (c.unsafeDepth == 0) {
            const diag = errorNode(c, node, `indexing a raw \`${typeName(c, base)}\` pointer needs \`unsafe { }\``);
            hint(c, diag, "nothing checks the bounds of a raw pointer; prefer a slice, or wrap this in `unsafe`");
        }
        return b.child;
    }
    void errorNode(c, n.a, `\`${typeName(c, base)}\` can't be indexed`);
    return 0;
}

/**
 * Checks a slice expression `x[start..end]`.
 *
 * @param c - The checker context
 * @param node - The slice node, whose record holds the optional start and end
 * @returns The slice type, or 0 when the base cannot be sliced
 *
 * @remarks
 * The bounds are checked as `usize` values.
 * An array must be stored in a variable, an element, or a dereference to be sliced.
 * The slice of an array is read-only unless the array is a mutable place,
 * and slicing it mutably marks the root variable as mutated.
 * Slicing a slice gives the same type, and slicing a string literal gives a `string`.
 * Slicing a raw many-item pointer needs `unsafe { }` and an end, as in `p[0..len]`.
 *
 * @example
 * ```hx
 * // let a: i32[4] = undefined;   a[1..3]
 * hxsCheckSlice(c, node); // the i32[] type
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckSlice(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const data = record<HxSliceData>(astOf(c), n.b);
    const base = hxsCheckExpr(c, n.a, 0);
    const tys = types(c);
    if (data.start != 0) void hxsCheckExpr(c, data.start, tys.usize);
    if (data.end != 0) void hxsCheckExpr(c, data.end, tys.usize);
    if (base == 0) return 0;
    const b = typeOf(c, base);
    const array = b.kind == TypeKind.Array ? base : hxsPointedArray(c, base);
    if (array != 0) {
        const readonly = b.kind == TypeKind.Array ? !hxsIsMutablePlace(c, n.a, false) : (b.flags & Readonly) != 0;
        const baseKind = nodeOf(c, n.a).kind;
        if (b.kind == TypeKind.Array && baseKind != NodeKind.Ident && baseKind != NodeKind.Index && baseKind != NodeKind.Deref) {
            void errorNode(c, n.a, "only an array stored in a variable can be sliced");
            return 0;
        }
        if (!readonly && b.kind == TypeKind.Array) {
            const root = hxsPlaceRoot(c, n.a);
            if (root != 0) symbolOf(c, root).flags |= HxSymMutated as u16;
        }
        return hxTypePointer(tys, TypeKind.Slice as u32, typeOf(c, array).child, readonly);
    }
    if (b.kind == TypeKind.Slice) return base;
    if (b.kind == TypeKind.StringLiteral) return tys.string;
    if (b.kind == TypeKind.ManyPointer) {
        if (c.unsafeDepth == 0) void errorNode(c, node, `slicing a raw \`${typeName(c, base)}\` pointer needs \`unsafe { }\``);
        if (data.end == 0) void errorNode(c, node, "slicing a raw pointer needs an end: `p[0..len]`");
        return hxTypePointer(tys, TypeKind.Slice as u32, b.child, (b.flags & Readonly) != 0);
    }
    void errorNode(c, n.a, `\`${typeName(c, base)}\` can't be sliced`);
    return 0;
}

/**
 * Checks `Type.member` without a call.
 *
 * @param c - The checker context
 * @param node - The node that reads the member
 * @param owner - The type that owns the member
 * @param nameToken - The token of the member's name
 * @returns The type of the value, or 0 after an error
 *
 * @remarks
 * The member can be an enum value, an error, a union variant without a payload, a constant, or a method.
 * An enum value or an error gives the owner type, with its value recorded on the node.
 * A union variant that carries a payload must be built with a call, as in `Shape.circle(...)`.
 * A struct field is an error, since it needs a value to read it from.
 * A method becomes a function value whose first parameter is the receiver, unless it is generic.
 * An interface method signature must be called on a value.
 *
 * @example
 * ```hx
 * // enum Color { Red, Green }   Color.Green
 * hxsCheckStaticMember(c, node, color, nameToken); // the Color type, with the value 1
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckStaticMember(c: *Ctx, node: u32, owner: u32, nameToken: u32): u32 {
    const name = tokenText(c, nameToken);
    const index = hxsFindMember(c, owner, hxsTokName(c, nameToken));
    if (index < 0) {
        void errorNode(c, node, `\`${typeName(c, owner)}\` has no member \`${name}\``);
        return 0;
    }
    const m = hxsMemberOf(c, owner, index);
    switch (m.kind as u32) {
        case 1: {   // ENUM_VALUE
            infoOf(c, node).value = hxsIntValue(c, m.value);
            return owner;
        }
        case 2: {   // ERROR
            infoOf(c, node).value = hxsErrorValue(c, m.value);
            return owner;
        }
        case 0: {   // FIELD
            if (typeOf(c, owner).kind != TypeKind.Union) {
                const diag = errorNode(c, node, `\`${name}\` is a field, so it needs a \`${typeName(c, owner)}\` value`);
                hintf(c, diag, `read it from a value: \`x.${name}\``);
                return 0;
            }
            if (m.type != 0) {
                const diag = errorNode(c, node, `\`${typeName(c, owner)}.${name}\` carries a \`${typeName(c, m.type)}\``);
                hintf(c, diag, `build it with a value: \`${typeName(c, owner)}.${name}(...)\``);
                return 0;
            }
            infoOf(c, node).flags |= HxInfoUnionInit;
            infoOf(c, node).aux = m.index;
            return owner;
        }
        case 4: {   // CONST
            hxsResolveGlobal(c, m.symbol);
            hxsMarkUsed(c, m.symbol);
            infoOf(c, node).symbol = m.symbol;
            infoOf(c, node).value = symbolOf(c, m.symbol).value;
            return symbolOf(c, m.symbol).type;
        }
        case 3: {   // METHOD: `Point.less` as a value; the receiver is its first parameter
            if ((symbolOf(c, m.symbol).flags & (HxSymTemplateMethod as u16)) != 0) {
                const diag = errorNode(c, node, `\`${typeName(c, owner)}.${name}\` is generic, so it can't be used as a value on its own`);
                hint(c, diag, "call it, or wrap one instance in an arrow function");
                return 0;
            }
            const method = hxsMethodInstance(c, m.symbol, owner, node);
            hxsMarkUsed(c, method);
            return hxsFunctionValue(c, node, method, name.ptr, name.len as i32);
        }
        case 5: {   // SIGNATURE
            void errorNode(c, node, `\`${typeName(c, owner)}.${name}\` is an interface method; call it on a value`);
            return 0;
        }
        default: return 0;
    }
}

/**
 * Checks a field expression `x.name`.
 *
 * @param c - The checker context
 * @param node - The field node, whose operand is `x` and whose token is the name
 * @returns The type of the field, or 0 after an error
 *
 * @remarks
 * A module namespace gives the module's member, and a type name gives a static member.
 * Otherwise the name must be a field of a struct, or of a struct behind a pointer, which the node then reads through.
 * Arrays, pointers to arrays, string literals, and slices have `len`, and slices also have `ptr`.
 * The length of an array or a string literal is known while compiling, so it is recorded as a constant,
 * and reading the length of an array does not count as reading the array.
 * An optional or a value that can fail has no fields, and the error hints at `?.`, `!.`, `try`, or `catch`.
 *
 * @example
 * ```hx
 * // const s: string = "abc";   s.len
 * hxsCheckField(c, node); // the usize type
 * ```
 *
 * @see hxsCheckStaticMember
 * @since 1.0.0
 */

export extern "C" function hxsCheckField(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const mem = hxsModuleMember(c, n.a, n.token, true);
    if (mem == 0xFFFF_FFFF) return 0;
    if (mem != 0) {   // `ns.name`
        const text = tokenText(c, n.token);
        infoOf(c, node).flags |= HxInfoModuleRef;
        return hxsCheckSymbolValue(c, node, mem, text.ptr, text.len as i32);
    }
    const owner = hxsTypeNameRef(c, n.a);
    if (owner != 0) return hxsCheckStaticMember(c, node, owner, n.token);

    const base = hxsCheckExpr(c, n.a, 0);
    if (base == 0) return 0;
    const field = tokenText(c, n.token);
    const b = typeOf(c, base);
    const tys = types(c);
    let target = base;
    let deref = false;
    if (b.kind == TypeKind.Pointer && typeOf(c, b.child).kind == TypeKind.Struct) {
        target = b.child;
        deref = true;
    }
    if (typeOf(c, target).kind == TypeKind.Struct) {
        const index = hxsFindMember(c, target, hxsTokName(c, n.token));
        if (index >= 0) {
            const m = hxsMemberOf(c, target, index);
            if (m.kind == HxMemberField as u8) {
                infoOf(c, node).flags |= HxInfoField | (deref ? HxInfoDeref : 0);
                infoOf(c, node).aux = m.index;
                return m.type;
            }
            if (m.kind == HxMemberMethod as u8) {
                const diag = errorNode(c, node, `\`${field}\` is a method`);
                hintf(c, diag, `call it: \`.${field}(...)\``);
                return 0;
            }
        }
        void errorNode(c, node, `\`${typeName(c, target)}\` has no field \`${field}\``);
        return 0;
    }
    if (b.kind == TypeKind.Optional) {
        const diag = errorNode(c, n.a, `\`${typeName(c, base)}\` might be null`);
        hintf(c, diag, `use \`?.${field}\` for an optional result, \`!.${field}\` if it can't be null, or check \`!= null\` first`);
        return 0;
    }
    if (b.kind == TypeKind.ErrorUnion) {
        const diag = errorNode(c, n.a, "this can fail, so it has no fields yet");
        hint(c, diag, "handle the error first with `try` or `catch`");
        return 0;
    }
    const isLen = sameText(field, "len");
    const isPtr = sameText(field, "ptr");
    const array = b.kind == TypeKind.Array ? base : hxsPointedArray(c, base);
    if (isLen && array != 0) {
        if (b.kind == TypeKind.Array) noteNotRead(c, n.a);   // the length is known while compiling
        infoOf(c, node).value = hxsIntValue(c, typeOf(c, array).len as i128);
        return tys.usize;
    }
    if (isLen && b.kind == TypeKind.StringLiteral) {
        infoOf(c, node).value = hxsIntValue(c, hxsValueOf(c, n.a)!.len as i128);
        return tys.usize;
    }
    if (isLen && b.kind == TypeKind.Slice) return tys.usize;
    if (isPtr && b.kind == TypeKind.Slice) return hxTypePointer(tys, TypeKind.ManyPointer as u32, b.child, (b.flags & Readonly) != 0);
    const diag = errorNode(c, node, `\`${typeName(c, base)}\` has no field \`${field}\``);
    if (b.kind == TypeKind.Slice || array != 0) hint(c, diag, "slices and arrays have `.len`; slices also have `.ptr`");
    return 0;
}

/**
 * Checks a member name without its type, such as `.Admin`, `.quit`, or `.NotFound`.
 *
 * @param c - The checker context
 * @param node - The enum literal node, whose token is the member's name
 * @param expected - The type the context expects, or 0 when nothing is expected
 * @returns The owner type, or 0 when the expected type does not say which enum, union, or error set it is
 *
 * @remarks
 * The expected type, seen through optionals and error unions, picks the owner, which must not be a struct.
 *
 * @example
 * ```hx
 * // const c: Color = .Green;
 * hxsCheckEnumLiteral(c, node, color); // the Color type
 * ```
 *
 * @see hxsCheckStaticMember
 * @since 1.0.0
 */

export extern "C" function hxsCheckEnumLiteral(c: *Ctx, node: u32, expected: u32): u32 {
    const owner = hxsExpectedBase(c, expected);
    if (owner == 0 || !hxsIsAggregate(c, owner) || typeOf(c, owner).kind == TypeKind.Struct) {
        const name = tokenText(c, nodeOf(c, node).token);
        const diag = errorNode(c, node, `can't tell which type \`.${name}\` belongs to`);
        hintf(c, diag, `write the enum's name before it: \`SomeEnum.${name}\``);
        return 0;
    }
    return hxsCheckStaticMember(c, node, owner, nodeOf(c, node).token);
}

/**
 * Checks a struct literal such as `Point { x: 1, y }`.
 *
 * @param c - The checker context
 * @param node - The struct literal node, with an optional type name and the range of its field values
 * @param expected - The type the context expects, used when the literal does not name its type
 * @returns The struct type, or 0 when the literal does not build a struct
 *
 * @remarks
 * Each value is checked against its field's type, and the node of each value records the field's index.
 * A field that is not there, or one set twice, is an error.
 * The shorthand `{ name }` stands for `{ name: name }` and must name a local, a parameter, or a global.
 * Its value is coerced when the variable's type converts to the field's type implicitly.
 * Every field without a default value must be set, and the error lists the missing ones in up to 255 bytes.
 * At most 512 fields are tracked.
 *
 * @example
 * ```hx
 * // struct Point { x: i32, y: i32 }   const p: Point = { x: 1 };
 * hxsCheckStructLiteral(c, node, point); // error: missing field `y` in `Point`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckStructLiteral(c: *Ctx, node: u32, expected: u32): u32 {
    const n = nodeOf(c, node);
    const inits = record<HxRange>(astOf(c), n.b);
    const type = n.a != 0 ? hxsResolveType(c, n.a) : hxsExpectedBase(c, expected);
    if (type == 0 || typeOf(c, type).kind != TypeKind.Struct) {
        if (type != 0) {
            void errorNode(c, n.a != 0 ? n.a : node, `\`${typeName(c, type)}\` is not a struct`);
        } else if (n.a == 0) {
            const diag = errorNode(c, node, "can't tell which struct this is");
            hint(c, diag, "name it: `Point { ... }`, or give the variable a type");
        }
        for (const i of inits.start..inits.end) {
            const v = nodeOf(c, extraOf(c, i)).a;
            if (v != 0) void hxsCheckExpr(c, v, 0);
        }
        return 0;
    }

    hxsResolveAggregate(c, type);
    let seen: bool[512] = undefined;
    for (const i of 0..512) seen[i] = false;
    for (const i of inits.start..inits.end) {
        const init = extraOf(c, i);
        const in = nodeOf(c, init);
        const name = tokenText(c, in.token);
        const index = hxsFindMember(c, type, hxsTokName(c, in.token));
        if (index < 0 || hxsMemberOf(c, type, index).kind != HxMemberField as u8) {
            void errorToken(c, in.token, `\`${typeName(c, type)}\` has no field \`${name}\``);
            if (in.a != 0) void hxsCheckExpr(c, in.a, 0);
            continue;
        }
        const m = hxsMemberOf(c, type, index);
        if (seen[m.index]) void errorToken(c, in.token, `\`${name}\` is set twice`);
        seen[m.index] = true;
        infoOf(c, init).aux = m.index;
        infoOf(c, init).type = m.type;
        if (in.a != 0) {
            void hxsCheckExpr(c, in.a, m.type);
            continue;
        }
        // `{ name }` is short for `{ name: name }`
        const sym = hxsLookup(c, hxsTokName(c, in.token));
        const kind = sym != 0 ? symbolOf(c, sym).kind as u32 : 0xFF;
        if (sym == 0 || (kind != HxSymLocal && kind != HxSymParam && kind != HxSymGlobal)) {
            void errorToken(c, in.token, `unknown name \`${name}\``);
            continue;
        }
        hxsMarkUsed(c, sym);
        if (kind == HxSymGlobal) hxsResolveGlobal(c, sym);
        infoOf(c, init).symbol = sym;
        infoOf(c, init).value = symbolOf(c, sym).value;
        const have = symbolOf(c, sym).type;
        if (have != 0 && m.type != 0 && have != m.type) {
            if (hxsImplicitOk(c, have, m.type) || (hxsIsComptimeNumber(c, have) && hxsIsNumeric(c, m.type))) {
                infoOf(c, init).coerce = m.type;
                infoOf(c, init).type = have;
            } else {
                void errorToken(c, in.token, `expected \`${typeName(c, m.type)}\`, found \`${typeName(c, have)}\``);
            }
        }
    }

    // the fields left out, listed like "`a`, `b`" (up to 255 bytes, as the C version did)
    let missing: u8[256] = undefined;
    let used: usize = 0;
    let missingCount: u32 = 0;
    const agg = *hxsAggregateOf(c, type);
    for (const i of 0..agg.membersCount) {
        const m = *memberAt(c, agg.membersStart + i);
        if (m.kind != HxMemberField as u8 || seen[m.index] || m.defaultValue != 0) continue;
        const name = tokenText(c, m.token);
        if (missingCount > 0) {
            for (const ch of ", ") {
                if (used < 255) {
                    missing[used] = ch;
                    used += 1;
                }
            }
        }
        for (const ch of "`") {
            if (used < 255) {
                missing[used] = ch;
                used += 1;
            }
        }
        for (const ch of name) {
            if (used < 255) {
                missing[used] = ch;
                used += 1;
            }
        }
        if (used < 255) {
            missing[used] = '`';
            used += 1;
        }
        missingCount += 1;
    }
    if (missingCount > 0) {
        const diag = errorNode(c, node, `missing ${missingCount == 1 ? "field" : "fields"} ${missing[0..used]} in \`${typeName(c, type)}\``);
        hint(c, diag, "every field without a default value must be set");
    }
    return type;
}

/**
 * Checks an array literal such as `[1, 2, 3]`.
 *
 * @param c - The checker context
 * @param node - The array literal node, with the range of its items
 * @param expected - The type the context expects, or 0 when nothing is expected
 * @returns The array or slice type, or 0 after an error
 *
 * @remarks
 * Against an array type, the number of items must match its length.
 * The empty literal `[]` is also the empty slice of any element type.
 * Against a read-only slice, every item must be a constant,
 * and the literal becomes a constant array in the binary, like the bytes of a string literal.
 * A literal that the checker cannot evaluate needs storage first, as does any literal against a mutable slice.
 * Without an expected type, the first item decides the element type,
 * where an integer constant becomes an `i64` and a float constant an `f64`.
 * The literal `[]` alone is then an error.
 *
 * @example
 * ```hx
 * // const a = [1, 2, 3];
 * hxsCheckArrayLiteral(c, node, 0); // the i64[3] type
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckArrayLiteral(c: *Ctx, node: u32, expected: u32): u32 {
    const n = nodeOf(c, node);
    const count = n.b - n.a;
    const base = hxsExpectedBase(c, expected);
    const kind = base != 0 ? typeOf(c, base).kind : TypeKind.Invalid;
    const s = semaOf(c);
    if (kind == TypeKind.Slice) {
        if (count == 0) return base;
        if ((typeOf(c, base).flags & Readonly) != 0) {
            // constant items: a constant array in the binary, like a string literal's bytes
            const errors = s.diags!.errorCount;
            let known = true;
            for (const i of n.a..n.b) {
                if (hxsCheckExpr(c, extraOf(c, i), typeOf(c, base).child) != 0) void hxsCoerce(c, extraOf(c, i), typeOf(c, base).child);
                known = known && hxsValueOf(c, extraOf(c, i)) != null;
            }
            if (c.comptimeDepth != 0 || c.constInit) return base;   // evaluated with the rest
            if (known && s.diags!.errorCount == errors) {
                infoOf(c, node).type = base;
                let host = hxsEvalHost(c);
                const v = hxEvalExpr(&host, node, c.instance);
                if (v != 0 && v != 0xFFFF_FFFF) infoOf(c, node).value = v;
                return base;
            }
            if (s.diags!.errorCount != errors) return 0;
            const diag = errorNode(c, node, "an array literal needs storage before it can be a slice, unless every item is a constant");
            hintf(c, diag, `store it in an array first: \`const values: T[${count}] = [...];\` then slice it with \`&values\``);
            return 0;
        }
        const diag = errorNode(c, node, "an array literal needs storage before it can be a slice");
        hintf(c, diag, `store it in an array first: \`const values: T[${count}] = [...];\` then slice it with \`&values\``);
        for (const i of n.a..n.b) void hxsCheckExpr(c, extraOf(c, i), 0);
        return 0;
    }
    if (kind == TypeKind.Array) {
        const array = typeOf(c, base);
        if (array.len != count as u64) void errorNode(c, node, `\`${typeName(c, base)}\` needs ${array.len} elements, found ${count}`);
        for (const i of n.a..n.b) void hxsCheckExpr(c, extraOf(c, i), array.child);
        return base;
    }
    if (count == 0) {
        const diag = errorNode(c, node, "can't tell the element type of `[]`");
        hint(c, diag, "give it a type: `const empty: i32[] = [];`");
        return 0;
    }
    const elem = hxsRuntimeType(c, hxsCheckExpr(c, extraOf(c, n.a), 0));
    if (elem == 0) return 0;
    void hxsCoerce(c, extraOf(c, n.a), elem);
    for (const i of n.a + 1..n.b) void hxsCheckExpr(c, extraOf(c, i), elem);
    return hxTypeArray(types(c), elem, count as u64);
}
