/**
 * Imports
 */

import { record } from "@models/ast.model";
import { ArrayList, cAllocator } from "std";
import { TypeKind } from "@constants/types.constant";
import { HxMemberField } from "@constants/sema.constant";
import { NodeKind, NoToken } from "@constants/ast.constant";
import { hxVecGrowImpl } from "@components/memory.component";
import { hxTypeNominal, hxTypeInt } from "@models/types.model";
import { HxContainerData } from "@models/structs/ast-model.struct";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { hxsAddSymbol } from "@modules/sema/components/scope.component";
import { hxsResolveGlobal } from "@modules/sema/components/decl.component";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { Ctx, HxAggregate, HxNodeInfo, HxMember } from "@structs/sema.struct";
import { hxsIfaceSignature } from "@modules/sema/components/interfaces.component";
import { typeName, errorNode, errorToken, hintf } from "@modules/sema/components/base.component";
import { hxsIntFits, hxsFormatEscapes, semaOf, nodeOf, typeOf } from "@modules/sema/components/base.component";
import { HxMemberError, HxValueInt, HxSymGlobal, HxMemberConst, HxAggResolved } from "@constants/sema.constant";
import { HxMemberMethod, HxAggResolving, HxMemberEnumValue, HxMemberSignature } from "@constants/sema.constant";
import { symbolOf, infoOf, extraOf, types, memberAt, tokenText } from "@modules/sema/components/base.component";
import { hxsTokName, hxsValueOf, hxsAggregateOf, hxsIsAggregate } from "@modules/sema/components/base.component";

/**
 * Gives an error name its program-wide code.
 *
 * @param c - The checker context
 * @param name - The interned name of the error, such as `NotFound`
 * @returns The code of the name, which is 1 or more
 *
 * @remarks
 * Codes are numbered by name across the whole program, so `NotFound` has the same code in every error set.
 * A name seen for the first time gets the next free code, and code 0 never names an error.
 *
 * @example
 * ```hx
 * // error E1 { NotFound, Bad }   error E2 { Other, NotFound }
 * hxsErrorCode(c, notFound); // 1, for both sets
 * hxsErrorCode(c, other);    // 3
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsErrorCode(c: *Ctx, name: u32): u32 {
    const names = &semaOf(c).errorNames;
    unsafe {
        for (const i of 1..names.len) {
            if (names.items![i] == name) return i;
        }
        if (names.len == names.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &names.items), &names.cap, names.len + 1, 4);
        names.items![names.len] = name;
    }
    names.len += 1;
    return names.len - 1;
}

/**
 * Appends an aggregate to the checker's list of aggregates.
 *
 * @param c - The checker context
 * @param agg - The aggregate to append
 *
 * @remarks
 * Grows the list when it is full, so a pointer from {@link hxsAggregateOf} taken before the call may dangle afterward.
 * The new aggregate's index is the length of the list before the call.
 *
 * @since 1.0.0
 */

function pushAggregate(c: *Ctx, agg: HxAggregate): void {
    const list = &semaOf(c).aggregates;
    unsafe {
        if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, @sizeOf(HxAggregate));
        @ptrCast(HxAggregate[*], list.items)[list.len] = agg;
    }
    list.len += 1;
}

/**
 * Appends a member to the checker's shared list of members.
 *
 * @param c - The checker context
 * @param m - The member to append
 *
 * @remarks
 * An aggregate finds its members through its `membersStart` and `membersCount` in this list.
 * Growing the list may move it, which invalidates pointers from {@link memberAt}.
 *
 * @since 1.0.0
 */

function pushMember(c: *Ctx, m: HxMember): void {
    const list = &semaOf(c).members;
    unsafe {
        if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, @sizeOf(HxMember));
        @ptrCast(HxMember[*], list.items)[list.len] = m;
    }
    list.len += 1;
}

/**
 * Creates the type of a struct, enum, union, error set, or interface, with its members still unresolved.
 *
 * @param c - The checker context
 * @param kind - The `TypeKind` of the new type, as a number
 * @param decl - The declaration node that lists the members
 * @param name - The name of the type, or `null` for an anonymous type
 * @param len - The length of the name in bytes
 * @returns The new nominal type
 *
 * @remarks
 * The type gets an aggregate record that belongs to the current module.
 * Its members are read later, by {@link hxsResolveAggregate}, the first time something needs them.
 * Generic instances such as `ArrayList<u8>` use this form, since their name is built rather than written.
 *
 * @example
 * ```hx
 * hxsDeclareAggregateNamed(c, TypeKind.Struct as u32, decl, name, len); // a new struct type
 * ```
 *
 * @see hxsDeclareAggregate
 * @since 1.0.0
 */

export extern "C" function hxsDeclareAggregateNamed(c: *Ctx, kind: u32, decl: u32, name: ?readonly u8[*], len: u32): u32 {
    const index = semaOf(c).aggregates.len;
    const type = hxTypeNominal(types(c), kind, index, 0, name, len);
    pushAggregate(c, HxAggregate {
        type, decl, membersStart: 0, membersCount: 0, fieldCount: 0, state: 0, instance: 0, module: c.module,
    });
    return type;
}

/**
 * Creates the type of a declared struct, enum, union, error set, or interface, named by a token.
 *
 * @param c - The checker context
 * @param kind - The `TypeKind` of the new type, as a number
 * @param decl - The declaration node that lists the members
 * @param nameToken - The token of the name, or `NoToken` for an anonymous struct type
 * @returns The new nominal type
 *
 * @remarks
 * Use it for a type written in the source, whose name is the text of a token.
 * It passes a `null` name for an anonymous type and leaves the rest to {@link hxsDeclareAggregateNamed}.
 *
 * @example
 * ```hx
 * // struct Point { x: i32 }
 * hxsDeclareAggregate(c, TypeKind.Struct as u32, decl, nameToken); // the type `Point`
 * ```
 *
 * @see hxsDeclareAggregateNamed
 * @since 1.0.0
 */

export extern "C" function hxsDeclareAggregate(c: *Ctx, kind: u32, decl: u32, nameToken: u32): u32 {
    if (nameToken == NoToken) return hxsDeclareAggregateNamed(c, kind, decl, null, 0);
    const name = tokenText(c, nameToken);
    return hxsDeclareAggregateNamed(c, kind, decl, name.ptr, @truncate(u32, name.len));
}

/**
 * Finds a member of an aggregate type by name.
 *
 * @param c - The checker context
 * @param type - The type to search
 * @param name - The interned name of the member
 * @returns The index of the member within the aggregate, or -1 when the type has no such member
 *
 * @remarks
 * The type is resolved first, so its members are known.
 * A type that is not an aggregate gives -1.
 *
 * @example
 * ```hx
 * // struct Point { x: i32, y: i32 }
 * hxsFindMember(c, point, y); // 1
 * hxsFindMember(c, point, z); // -1
 * ```
 *
 * @see hxsMemberOf
 * @since 1.0.0
 */

export extern "C" function hxsFindMember(c: *Ctx, type: u32, name: u32): i32 {
    if (!hxsIsAggregate(c, type)) return -1;
    hxsResolveAggregate(c, type);
    const agg = hxsAggregateOf(c, type);
    for (const i of 0..agg.membersCount) {
        if (memberAt(c, agg.membersStart + i).name == name) return i as i32;
    }
    return -1;
}

/**
 * Reads a member of a resolved aggregate type by its index.
 *
 * @param c - The checker context
 * @param type - The aggregate type
 * @param index - The index of the member, as {@link hxsFindMember} returns it
 * @returns A copy of the member
 *
 * @remarks
 * The index must be valid for the type, since nothing checks it.
 *
 * @example
 * ```hx
 * const m = hxsMemberOf(c, point, hxsFindMember(c, point, y));
 * m.index; // 1
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsMemberOf(c: readonly *Ctx, type: u32, index: i32): HxMember {
    return *memberAt(c, hxsAggregateOf(c, type).membersStart + (index as u32));
}

/**
 * Reports a struct or union that contains itself by value.
 *
 * @param c - The checker context
 * @param t - The type of a field or variant
 * @param where - The node that the error points at
 *
 * @remarks
 * Such a type would be infinitely large.
 * A struct or union still being resolved is the one that contains itself, which is an error with a hint
 * to store a pointer instead.
 * Any other struct or union is resolved here,
 * so a cycle through several types is found at the field that closes it.
 * Arrays, optionals, and error unions hold their child by value, so the check goes on into the child.
 * Pointers and slices end the check.
 *
 * @example
 * ```hx
 * // struct Node { next: Node }
 * hxsCheckContainment(c, node, field); // error: `Node` contains itself, so it would be infinitely large
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckContainment(c: *Ctx, t: u32, where: u32): void {
    const kind = typeOf(c, t).kind;
    if (kind == TypeKind.Struct || kind == TypeKind.Union) {
        if (hxsAggregateOf(c, t).state == HxAggResolving as u8) {
            const diag = errorNode(c, where, `\`${typeName(c, t)}\` contains itself, so it would be infinitely large`);
            hintf(c, diag, `store a pointer instead: \`*${typeName(c, t)}\` or \`?*${typeName(c, t)}\``);
            return;
        }
        hxsResolveAggregate(c, t);
    } else if (kind == TypeKind.Array || kind == TypeKind.Optional || kind == TypeKind.ErrorUnion) {
        hxsCheckContainment(c, typeOf(c, t).child, where);
    }
}

/**
 * Picks the smallest integer type that holds a range of values.
 *
 * @param c - The checker context
 * @param lo - The lowest value
 * @param hi - The highest value
 * @returns The smallest of the 8, 16, 32, 64, and 128-bit integer types that holds both ends, signed when `lo` is
 * negative, or `i128` when none does
 *
 * @remarks
 * An enum without a backing type uses this type for its values.
 *
 * @example
 * ```hx
 * hxsIntTypeForRange(c, 0, 300);  // u16
 * hxsIntTypeForRange(c, -1, 100); // i8
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIntTypeForRange(c: *Ctx, lo: i128, hi: i128): u32 {
    const widths: u16[5] = [8, 16, 32, 64, 128];
    for (const w of widths) {
        const t = hxTypeInt(types(c), lo < 0, w);
        if (hxsIntFits(c, t, lo) && hxsIntFits(c, t, hi)) return t;
    }
    return hxTypeInt(types(c), true, 128);
}

/**
 * Sets the child type of a type, which holds the backing integer of an enum, union, or error set.
 *
 * @param c - The checker context
 * @param type - The type to change
 * @param child - The new child type
 *
 * @remarks
 * Writes into the type table in place, so every holder of the type id sees the new child at once.
 *
 * @since 1.0.0
 */

function setChild(c: *Ctx, type: u32, child: u32): void {
    unsafe {
        types(c).items![type].child = child;
    }
}

/**
 * Builds a member with its name and token set and every other field zero.
 *
 * @param token - The token that names the member
 * @param name - The interned name of the member
 * @returns The member
 *
 * @remarks
 * Kind 0 is {@link HxMemberField}, so a caller that builds any other member sets the kind as well.
 *
 * @since 1.0.0
 */

function blankMember(token: u32, name: u32): HxMember {
    return HxMember { kind: 0, name, token, type: 0, defaultValue: 0, value: 0, index: 0, symbol: 0, decl: 0 };
}

/**
 * Reads the members of an aggregate type the first time something needs them.
 *
 * @param c - The checker context
 * @param type - The type to resolve, where anything other than an unresolved aggregate does nothing
 *
 * @remarks
 * The members are checked in the module that declared the type, with only globals in scope,
 * so a member type or a default value never sees the locals of a function.
 * Generic declarations are only resolved as instances, with their type parameters bound.
 * By kind of member:
 * - **Fields and union variants** - the type is resolved and may not be `void` or contain the aggregate itself.
 *   A field's default value is checked against the field's type here,
 *   and is checked again at every literal that leaves the field out.
 * - **Enum values** - a value must be an integer known at compile time, and a member without one takes the next
 *   number after the member before it.
 *   Two members with the same value are an error.
 * - **Error members** - the value is the program-wide code of the name, from {@link hxsErrorCode}.
 * - **Functions** - in an interface each one is a signature with its vtable slot,
 *   and anywhere else a method whose symbol the collection step already made.
 * - **Constants** - each one becomes a global owned by the type, resolved after the members.
 *
 * A name declared twice is an error, and the checker drops the second one.
 * An enum's backing type must be an integer, and without one the enum gets the smallest one for its values.
 * A union carries a `u8` tag, or a `u16` tag past 256 variants, and an error set holds the error code type.
 *
 * @example
 * ```hx
 * // enum Level { Low, High = 10 }
 * hxsResolveAggregate(c, level); // Low is 0, High is 10, backed by u8
 * ```
 *
 * @see hxsFindMember
 * @since 1.0.0
 */

export extern "C" function hxsResolveAggregate(c: *Ctx, type: u32): void {
    if (!hxsIsAggregate(c, type) || hxsAggregateOf(c, type).state != 0) return;
    hxsAggregateOf(c, type).state = HxAggResolving as u8;
    const savedModule = c.module;
    c.module = hxsAggregateOf(c, type).module;
    const decl = hxsAggregateOf(c, type).decl;
    const n = nodeOf(c, decl);
    const kind = typeOf(c, type).kind;
    const savedGlobalsOnly = c.globalsOnly;
    c.globalsOnly = true;   // member types and default values never see a function's locals

    let start: u32 = 0;
    let end: u32 = 0;
    let backing: u32 = 0;
    if (n.kind == NodeKind.TypeStruct || n.kind == NodeKind.ErrorSet) {
        start = n.a;
        end = n.b;
    } else {
        const data = record<HxContainerData>(c.ast!, n.a);
        start = data.membersStart;   // generic declarations are only resolved as instances, with `T` bound
        end = data.membersEnd;
        if (data.backingType != 0) {
            backing = hxsResolveType(c, data.backingType);
            if (backing != 0 && typeOf(c, backing).kind != TypeKind.Int) {
                void errorNode(c, data.backingType, `an enum's backing type must be an integer, found \`${typeName(c, backing)}\``);
                backing = 0;
            }
        }
    }

    const a = cAllocator();
    let members = ArrayList<HxMember>.init(a);
    defer members.deinit();
    let consts = ArrayList<u32>.init(a);
    defer consts.deinit();
    let fields: u32 = 0;
    let next: i128 = 0;
    let lo: i128 = 0;
    let hi: i128 = 0;

    for (const i of start..end) {
        const m = extraOf(c, i);
        const mn = nodeOf(c, m);
        if (mn.token == NoToken) continue;
        let mem = blankMember(mn.token, hxsTokName(c, mn.token));
        switch (mn.kind) {
            case NodeKind.FieldDecl: {
                mem.kind = HxMemberField as u8;
                mem.type = hxsResolveType(c, mn.a);
                if (hxsFormatEscapes(c, mem.type, mn.a)) mem.type = 0;
                if (mem.type == types(c).voidType) {
                    void errorNode(c, mn.a, "a field can't be `void`");
                    mem.type = 0;
                }
                if (mem.type != 0) hxsCheckContainment(c, mem.type, mn.a);
                if (mn.b != 0) {
                    void hxsCheckExpr(c, mn.b, mem.type);   // evaluated again at every literal that omits the field
                    mem.defaultValue = mn.b;
                }
                mem.index = fields;
                fields += 1;
            }
            case NodeKind.UnionVariant: {
                mem.kind = HxMemberField as u8;
                mem.type = mn.a != 0 ? hxsResolveType(c, mn.a) : 0;
                if (hxsFormatEscapes(c, mem.type, mn.a)) mem.type = 0;
                if (mem.type != 0) hxsCheckContainment(c, mem.type, mn.a);
                mem.index = fields;
                fields += 1;
            }
            case NodeKind.EnumMember: {
                mem.kind = HxMemberEnumValue as u8;
                mem.type = type;
                if (mn.a != 0) {
                    void hxsCheckExpr(c, mn.a, backing);
                    const v = hxsValueOf(c, mn.a);
                    if (v == null || v.kind != HxValueInt as u8) {
                        void errorNode(c, mn.a, "an enum value must be an integer known at compile time");
                    } else {
                        next = v.integer;
                    }
                }
                for (const other of members.items) {
                    if (other.kind == HxMemberEnumValue as u8 && other.value == next) {
                        void errorToken(c, mn.token, `\`${tokenText(c, mn.token)}\` has the same value as \`${tokenText(c, other.token)}\``);
                    }
                }
                mem.value = next;
                next += 1;
                if (fields == 0 || mem.value < lo) lo = mem.value;
                if (fields == 0 || mem.value > hi) hi = mem.value;
                mem.index = fields;
                fields += 1;
            }
            case NodeKind.ErrorMember: {
                mem.kind = HxMemberError as u8;
                mem.type = type;
                mem.value = hxsErrorCode(c, mem.name) as i128;
                mem.index = fields;
                fields += 1;
            }
            case NodeKind.Function: {
                if (kind == TypeKind.Interface) {
                    mem.kind = HxMemberSignature as u8;
                    mem.decl = m;
                    mem.type = hxsIfaceSignature(c, m, type, type, true);
                    mem.index = fields;   // the vtable slot
                    fields += 1;
                } else {
                    mem.kind = HxMemberMethod as u8;
                    unsafe {
                        mem.symbol = @ptrCast(HxNodeInfo[*], semaOf(c).info)[m].symbol;   // set at collection, outside any instance
                    }
                }
            }
            case NodeKind.Const: {
                mem.kind = HxMemberConst as u8;
                const sym = hxsAddSymbol(c, HxSymGlobal, mn.token, m, 0);
                symbolOf(c, sym).owner = type;
                infoOf(c, m).symbol = sym;
                mem.symbol = sym;
                consts.append(sym) catch @panic("out of memory");
            }
            default: continue;
        }
        let duplicate = false;
        for (const other of members.items) duplicate = duplicate || other.name == mem.name;
        if (duplicate) {
            void errorToken(c, mn.token, `\`${tokenText(c, mn.token)}\` is declared twice in \`${typeName(c, type)}\``);
            continue;
        }
        members.append(mem) catch @panic("out of memory");
    }

    const tys = types(c);
    if (kind == TypeKind.Enum) {
        if (backing == 0) backing = hxsIntTypeForRange(c, lo, hi);
        for (const m of members.items) {
            if (m.kind != HxMemberEnumValue as u8 || hxsIntFits(c, backing, m.value)) continue;
            void errorToken(c, m.token, `\`${tokenText(c, m.token)}\` doesn't fit in the backing type \`${typeName(c, backing)}\``);
        }
        setChild(c, type, backing);
    } else if (kind == TypeKind.Union) {
        setChild(c, type, fields <= 256 ? tys.u8 : tys.u16);
    } else if (kind == TypeKind.ErrorSet) {
        setChild(c, type, tys.errorCode);
    }

    const agg = hxsAggregateOf(c, type);
    agg.membersStart = semaOf(c).members.len;
    agg.membersCount = @truncate(u32, members.items.len);
    agg.fieldCount = fields;
    for (const m of members.items) pushMember(c, m);
    hxsAggregateOf(c, type).state = HxAggResolved as u8;

    for (const sym of consts.items) hxsResolveGlobal(c, sym);
    c.globalsOnly = savedGlobalsOnly;
    c.module = savedModule;
}

/**
 * Lays out fields in C order and gives the total size and alignment.
 *
 * @param c - The checker context
 * @param fields - The types of the fields, in order
 * @param count - The number of fields
 * @param size - Receives the total size in bytes, rounded up to the alignment
 * @param align - Receives the largest alignment of a field, at least 1
 *
 * @remarks
 * Each field starts at the next offset that its own alignment allows.
 *
 * @example
 * ```hx
 * // fields: u8, u32
 * hxsLayout(c, &fields, 2, &size, &align); // size 8, align 4
 * ```
 *
 * @see hxsSizeAlign
 * @since 1.0.0
 */

export extern "C" function hxsLayout(c: *Ctx, fields: readonly u32[*], count: u32, size: *u64, align: *u64): void {
    let offset: u64 = 0;
    let maxAlign: u64 = 1;
    for (const i of 0..count) {
        let s: u64 = 0;
        let a: u64 = 0;
        unsafe {
            hxsSizeAlign(c, fields[i], &s, &a);
        }
        offset = (offset + a - 1) / a * a + s;
        if (a > maxAlign) maxAlign = a;
    }
    *size = (offset + maxAlign - 1) / maxAlign * maxAlign;
    *align = maxAlign;
}

/**
 * Gives the size and alignment of a type, exactly as code generation lays it out, for `@sizeOf`.
 *
 * @param c - The checker context
 * @param t - The type to measure
 * @param size - Receives the size in bytes
 * @param align - Receives the alignment in bytes
 *
 * @remarks
 * - **Integers and floats** - the bits rounded up to a power of two bytes, aligned to their size up to 16.
 * - **Pointers and functions** - the pointer size of the target, and slices and `dyn` values take two pointers.
 * - **Arrays** - the element size times the length.
 * - **Enums and error sets** - the backing integer, which is 2 bytes for an error set.
 * - **Optionals** - 8 bytes for an optional pointer or function, otherwise the value followed by a `bool`.
 * - **Error unions** - 2 bytes for `void | Error`, otherwise the value followed by the error code.
 * - **Structs** - the fields in C order.
 * - **Unions** - the tag alone without a payload,
 *   otherwise 8 bytes for the tag followed by the largest payload rounded up to 8 bytes.
 *
 * Any other type has size 0 and alignment 1.
 *
 * @example
 * ```hx
 * // struct S { a: u8, b: u32 }
 * hxsSizeAlign(c, s, &size, &align); // size 8, align 4
 * ```
 *
 * @see hxsLayout
 * @since 1.0.0
 */

export extern "C" function hxsSizeAlign(c: *Ctx, t: u32, size: *u64, align: *u64): void {
    const type = typeOf(c, t);
    const tys = types(c);
    switch (type.kind) {
        case TypeKind.Bool: {
            *size = 1;
            *align = 1;
        }
        case TypeKind.Int, TypeKind.Float: {
            let bytes: u64 = 1;
            while (bytes * 8 < (type.bits as u64)) bytes *= 2;
            *size = bytes;
            *align = bytes > 16 ? 16 : bytes;
        }
        case TypeKind.Pointer, TypeKind.ManyPointer, TypeKind.Function: {
            *size = tys.pointerBytes as u64;
            *align = tys.pointerBytes as u64;
        }
        case TypeKind.Slice, TypeKind.Dyn: {
            *size = 2 * (tys.pointerBytes as u64);
            *align = tys.pointerBytes as u64;
        }
        case TypeKind.Array: {
            hxsSizeAlign(c, type.child, size, align);
            *size *= type.len;
        }
        case TypeKind.Enum: {
            hxsResolveAggregate(c, t);
            hxsSizeAlign(c, typeOf(c, t).child, size, align);
        }
        case TypeKind.ErrorSet: {
            *size = 2;
            *align = 2;
        }
        case TypeKind.Optional: {
            const child = typeOf(c, type.child).kind;
            if (child == TypeKind.Pointer || child == TypeKind.ManyPointer || child == TypeKind.Function) {
                *size = 8;
                *align = 8;
                return;
            }
            const fields: u32[2] = [type.child, tys.boolType];
            hxsLayout(c, &fields, 2, size, align);
        }
        case TypeKind.ErrorUnion: {
            if (type.child == tys.voidType) {
                *size = 2;
                *align = 2;
                return;
            }
            const fields: u32[2] = [type.child, tys.errorCode];
            hxsLayout(c, &fields, 2, size, align);
        }
        case TypeKind.Struct: {
            hxsResolveAggregate(c, t);
            const agg = *hxsAggregateOf(c, t);
            let fields = ArrayList<u32>.init(cAllocator());
            defer fields.deinit();
            for (const i of 0..agg.membersCount) {
                const m = memberAt(c, agg.membersStart + i);
                if (m.kind == HxMemberField as u8) fields.append(m.type) catch @panic("out of memory");
            }
            hxsLayout(c, fields.items.ptr, @truncate(u32, fields.items.len), size, align);
        }
        case TypeKind.Union: {
            hxsResolveAggregate(c, t);
            const agg = *hxsAggregateOf(c, t);
            let payload: u64 = 0;
            for (const i of 0..agg.membersCount) {
                const m = *memberAt(c, agg.membersStart + i);
                if (m.kind != HxMemberField as u8 || m.type == 0) continue;
                let s: u64 = 0;
                let a: u64 = 0;
                hxsSizeAlign(c, m.type, &s, &a);
                if (s > payload) payload = s;
            }
            const tag: u64 = typeOf(c, t).child == tys.u8 ? 1 : 2;
            const words = (payload + 7) / 8;
            *size = words != 0 ? 8 + words * 8 : tag;
            *align = words != 0 ? 8 : tag;
        }
        default: {
            *size = 0;
            *align = 1;
        }
    }
}
