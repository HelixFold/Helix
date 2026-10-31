/**
 * Imports
 */

import { TypeKind } from "@constants/types.constant";

/**
 * One entry of the type table.
 *
 * @remarks
 * The kind decides what `bits`, `child`, `len`, and `params` hold, and the unused fields stay 0.
 * Two entries with equal fields are the same type, so the table interns them under one id.
 * The C checker read this table directly, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * const t = types.items![hxTypeArray(&types, types.u8, 4)];
 * t.kind;  // TypeKind.Array
 * t.child; // types.u8
 * t.len;   // 4
 * ```
 *
 * @see HxTypes
 * @see TypeKind
 *
 * @since 1.0.0
 */

export extern "C" struct HxType {
    /**
     * The kind of the type.
     *
     * @example
     * ```hx
     * t.kind; // TypeKind.Pointer for *i32
     * ```
     *
     * @since 1.0.0
     */

    kind: TypeKind,

    /**
     * The flag bits of the type, such as {@link Signed} and {@link Readonly}.
     *
     * @example
     * ```hx
     * (t.flags & Readonly) != 0; // true for readonly *i32
     * ```
     *
     * @since 1.0.0
     */

    flags: u8,

    /**
     * The width in bits of an integer or a float.
     *
     * @example
     * ```hx
     * t.bits; // 32 for i32
     * ```
     *
     * @since 1.0.0
     */

    bits: u16,

    /**
     * The type that this one is built on.
     *
     * @remarks
     * It holds the pointee or element type, the return type of a function, the payload of an optional
     * or an error union, the backing integer of an enum, the tag type of a union, or the interface of a `dyn`.
     *
     * @example
     * ```hx
     * t.child; // types.i32 for *i32
     * ```
     *
     * @since 1.0.0
     */

    child: u32,

    /**
     * The length of an array, or a count or an index that depends on the kind.
     *
     * @remarks
     * It holds the parameter count of a function and the error set of an error union.
     * A nominal type holds the index of its aggregate plus one,
     * which keeps two declarations apart even when everything else matches.
     *
     * @example
     * ```hx
     * t.len; // 4 for u8[4]
     * ```
     *
     * @since 1.0.0
     */

    len: u64,

    /**
     * The index of the first parameter type of a function in the shared parameter list.
     *
     * @example
     * ```hx
     * types.params![t.params]; // the first parameter type of a function
     * ```
     *
     * @since 1.0.0
     */

    params: u32,

    /**
     * The declared name of a nominal type, or `null`.
     *
     * @remarks
     * The name is not part of the identity of the type.
     * It points into the source text, so it is not NUL-terminated and {@link HxType.nameLen} gives its length.
     *
     * @example
     * ```hx
     * t.name; // "Point" for struct Point
     * ```
     *
     * @since 1.0.0
     */

    name: ?readonly u8[*],

    /**
     * The length of the declared name in bytes.
     *
     * @example
     * ```hx
     * t.nameLen; // 5 for Point
     * ```
     *
     * @since 1.0.0
     */

    nameLen: u32,
}

/**
 * The interned type table of one check.
 *
 * @remarks
 * Structurally equal types get the same id, so two types are equal exactly when their ids are equal.
 * Id 0 is the invalid type, which an expression gets after an error so that one mistake does not cascade into more.
 * The table also holds the ids of the built-in types, which {@link hxTypesInit} fills in.
 * The C checker read this table directly, so the struct keeps its C layout.
 *
 * @example
 * ```hx
 * let types: HxTypes = undefined;
 * hxTypesInit(&types, 8);
 * hxTypeInt(&types, true, 32) == types.i32; // true
 * hxTypesFree(&types);
 * ```
 *
 * @see HxType
 * @see hxTypesInit
 *
 * @since 1.0.0
 */

export extern "C" struct HxTypes {
    /**
     * The types, indexed by id.
     *
     * @remarks
     * Adding a type can move the array, so a pointer into it does not stay valid.
     *
     * @example
     * ```hx
     * types.items![types.boolType].kind; // TypeKind.Bool
     * ```
     *
     * @since 1.0.0
     */

    items: ?HxType[*],

    /**
     * The number of types, the invalid type at id 0 included.
     *
     * @example
     * ```hx
     * types.itemsLen; // one more than the number of interned types
     * ```
     *
     * @since 1.0.0
     */

    itemsLen: u32,

    /**
     * The number of types that the array has room for.
     *
     * @example
     * ```hx
     * types.itemsCap; // 64
     * ```
     *
     * @since 1.0.0
     */

    itemsCap: u32,

    /**
     * The parameter types of every function type, one run per function.
     *
     * @example
     * ```hx
     * types.params![t.params + 1]; // the second parameter of a function type t
     * ```
     *
     * @since 1.0.0
     */

    params: ?u32[*],

    /**
     * The number of entries in the parameter list.
     *
     * @example
     * ```hx
     * types.paramsLen; // 2 after one (i32, i32) => i32
     * ```
     *
     * @since 1.0.0
     */

    paramsLen: u32,

    /**
     * The number of entries that the parameter list has room for.
     *
     * @example
     * ```hx
     * types.paramsCap; // 16
     * ```
     *
     * @since 1.0.0
     */

    paramsCap: u32,

    /**
     * The open-addressing hash table that finds an existing type, holding type ids.
     *
     * @remarks
     * A slot that holds 0 is empty, which works because id 0 is never interned through it.
     * The table grows to keep at most half of its slots in use.
     *
     * @example
     * ```hx
     * types.slots![slot]; // 0 for an empty slot
     * ```
     *
     * @since 1.0.0
     */

    slots: ?u32[*],

    /**
     * The number of slots, a power of two that starts at 256.
     *
     * @example
     * ```hx
     * types.slotsCap; // 256
     * ```
     *
     * @since 1.0.0
     */

    slotsCap: u32,

    /**
     * The id of `void`, which {@link hxTypesInit} fills in.
     *
     * @example
     * ```hx
     * types.voidType; // the id of void
     * ```
     *
     * @since 1.0.0
     */

    voidType: u32,

    /**
     * The id of `bool`.
     *
     * @example
     * ```hx
     * types.boolType; // the id of bool
     * ```
     *
     * @since 1.0.0
     */

    boolType: u32,

    /**
     * The id of `noreturn`, the type of a call that never returns.
     *
     * @example
     * ```hx
     * types.noreturnType; // the id of noreturn
     * ```
     *
     * @since 1.0.0
     */

    noreturnType: u32,

    /**
     * The id of the type of an integer literal that has not met a concrete type yet.
     *
     * @example
     * ```hx
     * types.comptimeInt; // the type of 42 before it is coerced
     * ```
     *
     * @since 1.0.0
     */

    comptimeInt: u32,

    /**
     * The id of the type of a float literal that has not met a concrete type yet.
     *
     * @example
     * ```hx
     * types.comptimeFloat; // the type of 1.5 before it is coerced
     * ```
     *
     * @since 1.0.0
     */

    comptimeFloat: u32,

    /**
     * The id of the type of `undefined`.
     *
     * @example
     * ```hx
     * types.undefinedType; // the type of undefined
     * ```
     *
     * @since 1.0.0
     */

    undefinedType: u32,

    /**
     * The id of the type of a string literal.
     *
     * @example
     * ```hx
     * types.stringLiteral; // the id of a string literal's type
     * ```
     *
     * @since 1.0.0
     */

    stringLiteral: u32,

    /**
     * The id of `u8`.
     *
     * @example
     * ```hx
     * types.u8; // the id of u8
     * ```
     *
     * @since 1.0.0
     */

    u8: u32,

    /**
     * The id of `u16`.
     *
     * @example
     * ```hx
     * types.u16; // the id of u16
     * ```
     *
     * @since 1.0.0
     */

    u16: u32,

    /**
     * The id of `u32`.
     *
     * @example
     * ```hx
     * types.u32; // the id of u32
     * ```
     *
     * @since 1.0.0
     */

    u32: u32,

    /**
     * The id of `u64`.
     *
     * @example
     * ```hx
     * types.u64; // the id of u64
     * ```
     *
     * @since 1.0.0
     */

    u64: u32,

    /**
     * The id of `usize`.
     *
     * @remarks
     * It is the same id as `u64`, or as `u32` on a 32-bit target.
     *
     * @example
     * ```hx
     * types.usize; // the id of usize
     * ```
     *
     * @since 1.0.0
     */

    usize: u32,

    /**
     * The id of `i8`.
     *
     * @example
     * ```hx
     * types.i8; // the id of i8
     * ```
     *
     * @since 1.0.0
     */

    i8: u32,

    /**
     * The id of `i16`.
     *
     * @example
     * ```hx
     * types.i16; // the id of i16
     * ```
     *
     * @since 1.0.0
     */

    i16: u32,

    /**
     * The id of `i32`.
     *
     * @example
     * ```hx
     * types.i32; // the id of i32
     * ```
     *
     * @since 1.0.0
     */

    i32: u32,

    /**
     * The id of `i64`.
     *
     * @example
     * ```hx
     * types.i64; // the id of i64
     * ```
     *
     * @since 1.0.0
     */

    i64: u32,

    /**
     * The id of `isize`.
     *
     * @remarks
     * It is the same id as `i64`, or as `i32` on a 32-bit target.
     *
     * @example
     * ```hx
     * types.isize; // the id of isize
     * ```
     *
     * @since 1.0.0
     */

    isize: u32,

    /**
     * The id of `f32`.
     *
     * @example
     * ```hx
     * types.f32; // the id of f32
     * ```
     *
     * @since 1.0.0
     */

    f32: u32,

    /**
     * The id of `f64`.
     *
     * @example
     * ```hx
     * types.f64; // the id of f64
     * ```
     *
     * @since 1.0.0
     */

    f64: u32,

    /**
     * The id of `string`, the built-in name of `readonly u8[]`.
     *
     * @example
     * ```hx
     * types.string == hxTypePointer(&types, TypeKind.Slice as u32, types.u8, true); // true
     * ```
     *
     * @since 1.0.0
     */

    string: u32,

    /**
     * The id of the type of the `null` literal.
     *
     * @example
     * ```hx
     * types.nullType; // the id of null
     * ```
     *
     * @since 1.0.0
     */

    nullType: u32,

    /**
     * The id of `Error`, the error set that holds every error.
     *
     * @example
     * ```hx
     * hxTypeName(&types, types.anyError, &buf, 64); // buf holds Error
     * ```
     *
     * @since 1.0.0
     */

    anyError: u32,

    /**
     * The id of the integer type that carries an error at run time, which is `u16`.
     *
     * @example
     * ```hx
     * types.errorCode == types.u16; // true
     * ```
     *
     * @since 1.0.0
     */

    errorCode: u32,

    /**
     * The id of `Format`.
     *
     * @example
     * ```hx
     * types.format; // the id of Format
     * ```
     *
     * @since 1.0.0
     */

    format: u32,

    /**
     * The size of a pointer and of `usize` on the target, 8 or 4.
     *
     * @example
     * ```hx
     * types.pointerBytes; // 8 on a 64-bit target
     * ```
     *
     * @since 1.0.0
     */

    pointerBytes: u32,
}

/**
 * A NUL-terminated text buffer that drops what does not fit, as `snprintf` does.
 *
 * @remarks
 * {@link hxTypeName} writes a type's name through one.
 * One byte is always kept for the NUL terminator.
 *
 * @example
 * ```hx
 * let out = Out { buf: bytes[0..8], used: 0 };
 * // writing "readonly u8[]" keeps "readonl" and a NUL
 * ```
 *
 * @since 1.0.0
 */

export struct Out {
    /**
     * The bytes to write into.
     *
     * @example
     * ```hx
     * out.buf.len; // 160
     * ```
     *
     * @since 1.0.0
     */

    buf: u8[],

    /**
     * The number of bytes written so far, the NUL terminator not included.
     *
     * @example
     * ```hx
     * out.used; // 3 after "i32"
     * ```
     *
     * @since 1.0.0
     */

    used: usize,
}
