/**
 * Imports
 */

import { Value, Type } from "@modules/codegen/components/structs/base-component.struct";

/**
 * The base pointer and length of something that can be indexed.
 *
 * @remarks
 * Indexing, slicing, and `for` loops over items all reach their elements through it.
 * It covers arrays reached by address, pointers to arrays, slices, raw `T[*]` pointers, and string literals.
 *
 * @example
 * ```hx
 * const base = emitIndexable(cg, node);
 * elementAddress(cg, &base, index); // the address of base[index]
 * ```
 *
 * @see emitIndexable
 * @see elementAddress
 *
 * @since 1.0.0
 */

export struct Indexable {
    /**
     * The pointer to the first element, or to the whole array when the array type is set.
     *
     * @example
     * ```hx
     * base.ptr; // ptr %buffer
     * ```
     *
     * @since 1.0.0
     */

    ptr: Value,

    /**
     * The number of elements as a `usize` value, or `null` for a raw `T[*]` pointer.
     *
     * @example
     * ```hx
     * base.len; // i64 4 for a u8[4]
     * ```
     *
     * @since 1.0.0
     */

    len: Value,

    /**
     * The element type.
     *
     * @remarks
     * A string literal has `u8` elements.
     *
     * @example
     * ```hx
     * base.elem; // the u8 type for a string
     * ```
     *
     * @since 1.0.0
     */

    elem: u32,

    /**
     * The LLVM array type when the pointer points to a whole array, or `null` otherwise.
     *
     * @remarks
     * An element of an array is reached with a GEP of `[0, i]`, and one of any other base with a GEP of `[i]`.
     *
     * @example
     * ```hx
     * base.arrayType; // [4 x i8] for a u8[4]
     * ```
     *
     * @since 1.0.0
     */

    arrayType: Type,
}
