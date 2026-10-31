/**
 * Imports
 */

import { AbiPart } from "@modules/codegen/components/structs/abi-component.struct";

/**
 * The ways that a value can cross a C function boundary.
 *
 * @remarks
 * Between Helix functions, structs travel as LLVM first-class aggregates.
 * C compilers pass them differently on each target,
 * so an `extern "C"` function that takes or returns a struct or an array by value gets the C ABI's signature instead.
 * Each argument and the result of such a function get one of these kinds.
 *
 * @example
 * ```hx
 * // extern "C" function scale(v: Vec2, k: f32): Vec2;   on aarch64
 * abiPart(cg, vec2, false).kind; // AbiKind.Coerce, as [2 x float]
 * abiPart(cg, f32, false).kind;  // AbiKind.Direct
 * ```
 *
 * @see AbiPart
 * @since 1.0.0
 */

export enum AbiKind {
    /**
     * The value travels as Helix lowers it.
     *
     * @remarks
     * Every scalar takes this kind, and so does an aggregate on a target without C ABI rules in this file.
     *
     * @example
     * ```hx
     * Direct.kind; // AbiKind.Direct
     * ```
     *
     * @since 1.0.0
     */

    Direct,

    /**
     * The value travels as another LLVM type, reinterpreted through memory.
     *
     * @remarks
     * The type it travels as is in the `type` field of its {@link AbiPart}.
     *
     * @example
     * ```hx
     * // struct Pair { a: i32, b: i32 } on aarch64
     * abiPart(cg, pair, false); // { kind: AbiKind.Coerce, type: i64 }
     * ```
     *
     * @since 1.0.0
     */

    Coerce,

    /**
     * The value travels as a pointer to a copy, or as the hidden `sret` pointer for a result.
     *
     * @example
     * ```hx
     * // a 24-byte struct on aarch64
     * abiPart(cg, big, true).kind; // AbiKind.Pointer, returned through sret
     * ```
     *
     * @since 1.0.0
     */

    Pointer,

    /**
     * The value travels as a pointer to a copy that carries the `byval` attribute.
     *
     * @example
     * ```hx
     * // a 24-byte struct on x86-64 SysV
     * abiPart(cg, big, false).kind; // AbiKind.Byval
     * ```
     *
     * @since 1.0.0
     */

    Byval,
}

/**
 * The part of a value that travels as Helix lowers it.
 *
 * @remarks
 * Scalars, empty aggregates, and every value on a target without C ABI rules in this file use it.
 *
 * @example
 * ```hx
 * Direct.kind; // AbiKind.Direct
 * Direct.type; // null
 * ```
 *
 * @see AbiKind
 * @since 1.0.0
 */

export const Direct = AbiPart { kind: AbiKind.Direct, type: null };
