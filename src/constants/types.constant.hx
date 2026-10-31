/**
 * The kind of an interned type.
 *
 * @remarks
 * Each {@link HxType} carries one, and the kind decides what the other fields of the entry mean.
 * Struct, enum, union, error set, and interface types are nominal:
 * each declaration is its own type, even when two declarations look the same.
 * Every other kind is structural, so two types built from the same parts share one id.
 *
 * @example
 * ```hx
 * types.items![types.i32].kind;    // TypeKind.Int
 * types.items![types.string].kind; // TypeKind.Slice
 * ```
 *
 * @see HxType
 * @since 1.0.0
 */

export enum TypeKind: u8 {
    /**
     * The invalid type, which id 0 always holds.
     *
     * @remarks
     * The checker gives it to an expression after an error, so one mistake does not cascade into more.
     *
     * @example
     * ```hx
     * types.items![0].kind; // TypeKind.Invalid
     * ```
     *
     * @since 1.0.0
     */

    Invalid,

    /**
     * The `void` type of a function without a result.
     *
     * @example
     * ```hx
     * types.items![types.voidType].kind; // TypeKind.Void
     * ```
     *
     * @since 1.0.0
     */

    Void,

    /**
     * The `bool` type.
     *
     * @example
     * ```hx
     * types.items![types.boolType].kind; // TypeKind.Bool
     * ```
     *
     * @since 1.0.0
     */

    Bool,

    /**
     * The `noreturn` type of an expression that never finishes, such as a call to a function that exits.
     *
     * @example
     * ```hx
     * types.items![types.noreturnType].kind; // TypeKind.Noreturn
     * ```
     *
     * @since 1.0.0
     */

    Noreturn,

    /**
     * A fixed-size integer, such as `u8` or `i32`.
     *
     * @remarks
     * The `bits` field holds the width, and the {@link Signed} flag tells `i32` from `u32`.
     *
     * @example
     * ```hx
     * hxTypeInt(&types, true, 32); // the id of i32
     * ```
     *
     * @since 1.0.0
     */

    Int,

    /**
     * A floating-point number, `f32` or `f64`.
     *
     * @remarks
     * The `bits` field holds the width.
     *
     * @example
     * ```hx
     * types.items![types.f64].bits; // 64
     * ```
     *
     * @since 1.0.0
     */

    Float,

    /**
     * The type of an integer literal before it gets a concrete type.
     *
     * @example
     * ```hx
     * // const n = 5;   5 is a ComptimeInt until it meets an i32
     * types.items![types.comptimeInt].kind; // TypeKind.ComptimeInt
     * ```
     *
     * @since 1.0.0
     */

    ComptimeInt,

    /**
     * The type of a float literal before it gets a concrete type.
     *
     * @example
     * ```hx
     * types.items![types.comptimeFloat].kind; // TypeKind.ComptimeFloat
     * ```
     *
     * @since 1.0.0
     */

    ComptimeFloat,

    /**
     * The type of the `undefined` initializer.
     *
     * @example
     * ```hx
     * // let x: i32 = undefined;
     * types.items![types.undefinedType].kind; // TypeKind.Undefined
     * ```
     *
     * @since 1.0.0
     */

    Undefined,

    /**
     * The type of a string literal.
     *
     * @remarks
     * It coerces to `readonly u8[]`, to the C string `readonly u8[*]`, and to `Format`.
     *
     * @example
     * ```hx
     * types.items![types.stringLiteral].kind; // TypeKind.StringLiteral
     * ```
     *
     * @since 1.0.0
     */

    StringLiteral,

    /**
     * A pointer to one value, written `*T`.
     *
     * @remarks
     * The `child` field holds the pointee, and the {@link Readonly} flag marks `readonly *T`.
     *
     * @example
     * ```hx
     * hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, false); // *i32
     * ```
     *
     * @since 1.0.0
     */

    Pointer,

    /**
     * A pointer to an unknown number of values, written `T[*]`.
     *
     * @remarks
     * The `child` field holds the element type.
     *
     * @example
     * ```hx
     * hxTypePointer(&types, TypeKind.ManyPointer as u32, types.u8, true); // readonly u8[*]
     * ```
     *
     * @since 1.0.0
     */

    ManyPointer,

    /**
     * A pointer and a length, written `T[]`.
     *
     * @remarks
     * The `child` field holds the element type.
     *
     * @example
     * ```hx
     * hxTypePointer(&types, TypeKind.Slice as u32, types.u8, true); // readonly u8[], the id of string
     * ```
     *
     * @since 1.0.0
     */

    Slice,

    /**
     * A fixed number of values held inline, written `T[N]`.
     *
     * @remarks
     * The `child` field holds the element type and `len` holds the length.
     *
     * @example
     * ```hx
     * hxTypeArray(&types, types.u8, 4); // u8[4]
     * ```
     *
     * @since 1.0.0
     */

    Array,

    /**
     * A function type, written `(A, B) => R`.
     *
     * @remarks
     * The `child` field holds the return type, `len` the parameter count,
     * and `params` the index of the first parameter type in the shared parameter list.
     *
     * @example
     * ```hx
     * hxTypeFunction(&types, types.i32, &params, 2, false); // (i32, i32) => i32
     * ```
     *
     * @since 1.0.0
     */

    Function,

    /**
     * The type of the `null` literal, which coerces to any optional.
     *
     * @example
     * ```hx
     * types.items![types.nullType].kind; // TypeKind.Null
     * ```
     *
     * @since 1.0.0
     */

    Null,

    /**
     * A value that may be `null`, written `?T`.
     *
     * @remarks
     * The `child` field holds the payload type.
     *
     * @example
     * ```hx
     * hxTypeOptional(&types, types.i32); // ?i32
     * ```
     *
     * @since 1.0.0
     */

    Optional,

    /**
     * A result that is either a value or an error, written `T | E`.
     *
     * @remarks
     * The `child` field holds the payload type `T`, and `len` holds the error set type `E`.
     *
     * @example
     * ```hx
     * hxTypeErrorUnion(&types, types.i32, types.anyError); // i32 | Error
     * ```
     *
     * @since 1.0.0
     */

    ErrorUnion,

    /**
     * A nominal struct type.
     *
     * @remarks
     * The `len` field holds the index of its aggregate plus one.
     *
     * @example
     * ```hx
     * hxTypeNominal(&types, TypeKind.Struct as u32, 0, 0, "Point", 5); // Point
     * ```
     *
     * @since 1.0.0
     */

    Struct,

    /**
     * A nominal enum type.
     *
     * @remarks
     * The `child` field holds the backing integer type, and `len` holds the index of its aggregate plus one.
     *
     * @example
     * ```hx
     * hxTypeNominal(&types, TypeKind.Enum as u32, 1, types.u8, "Color", 5); // Color
     * ```
     *
     * @since 1.0.0
     */

    Enum,

    /**
     * A nominal tagged union type.
     *
     * @remarks
     * The `len` field holds the index of its aggregate plus one.
     *
     * @example
     * ```hx
     * hxTypeNominal(&types, TypeKind.Union as u32, 2, 0, "Shape", 5); // Shape
     * ```
     *
     * @since 1.0.0
     */

    Union,

    /**
     * A nominal set of errors.
     *
     * @remarks
     * The {@link AnyError} flag marks `Error`, the set that holds every error.
     *
     * @example
     * ```hx
     * types.items![types.anyError].kind; // TypeKind.ErrorSet
     * ```
     *
     * @since 1.0.0
     */

    ErrorSet,

    /**
     * A nominal interface.
     *
     * @remarks
     * An interface is a constraint or sits behind `dyn`, and it is never the type of a value.
     *
     * @example
     * ```hx
     * hxTypeNominal(&types, TypeKind.Interface as u32, 3, 0, "Writer", 6); // Writer
     * ```
     *
     * @since 1.0.0
     */

    Interface,

    /**
     * A pointer to a value together with the methods of an interface, written `dyn I`.
     *
     * @remarks
     * The `child` field holds the interface.
     *
     * @example
     * ```hx
     * hxTypePointer(&types, TypeKind.Dyn as u32, writer, false); // dyn Writer
     * ```
     *
     * @since 1.0.0
     */

    Dyn,

    /**
     * The `Format` type of a template string passed to a parameter.
     *
     * @example
     * ```hx
     * types.items![types.format].kind; // TypeKind.Format
     * ```
     *
     * @since 1.0.0
     */

    Format,
}

/**
 * The flag of a signed integer type.
 *
 * @remarks
 * Only {@link TypeKind.Int} uses it.
 *
 * @example
 * ```hx
 * (types.items![types.i32].flags & Signed) != 0; // true
 * (types.items![types.u32].flags & Signed) != 0; // false
 * ```
 *
 * @since 1.0.0
 */

export const Signed: u8 = 0x01;

/**
 * The flag of a pointer, many-pointer, or slice whose pointee cannot be modified through it.
 *
 * @example
 * ```hx
 * (types.items![types.string].flags & Readonly) != 0; // true, string is readonly u8[]
 * ```
 *
 * @see hxTypeReadonly
 * @since 1.0.0
 */

export const Readonly: u8 = 0x02;

/**
 * The flag of a function type that ends with the C variadic `...`.
 *
 * @example
 * ```hx
 * const printf = hxTypeFunction(&types, types.i32, &params, 1, true);
 * (types.items![printf].flags & Variadic) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const Variadic: u8 = 0x04;

/**
 * The flag of `Error`, the error set that holds every error.
 *
 * @example
 * ```hx
 * (types.items![types.anyError].flags & AnyError) != 0; // true
 * ```
 *
 * @since 1.0.0
 */

export const AnyError: u8 = 0x08;

/**
 * The flag of a function type that uses the C calling convention, written `extern "C" (...) => T`.
 *
 * @example
 * ```hx
 * const callback = hxTypeFunctionC(&types, fn, true);
 * (types.items![callback].flags & CCall) != 0; // true
 * ```
 *
 * @see hxTypeFunctionC
 * @since 1.0.0
 */

export const CCall: u8 = 0x10;
