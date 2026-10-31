/**
 * Imports
 */

import { AbiKind } from "@modules/codegen/constants/abi.constant";
import { Type } from "@modules/codegen/components/structs/base-component.struct";

/**
 * How one argument or the result of a C function travels.
 *
 * @remarks
 * The C calling convention of the target decides it from the size and the scalars of the type,
 * and code generation rewrites the Helix signature of a C function to match.
 *
 * @example
 * ```hx
 * // struct Vec2 { x: f32, y: f32 } on aarch64
 * const part = abiPart(cg, vec2, false);
 * part.kind; // AbiKind.Coerce
 * part.type; // [2 x float]
 * ```
 *
 * @see AbiKind
 * @since 1.0.0
 */

export struct AbiPart {
    /**
     * The way that the value travels.
     *
     * @example
     * ```hx
     * part.kind; // AbiKind.Direct
     * ```
     *
     * @since 1.0.0
     */

    kind: AbiKind,

    /**
     * The LLVM type that a coerced value travels as.
     *
     * @remarks
     * Only {@link AbiKind.Coerce} uses it. The other kinds leave it `null`.
     *
     * @example
     * ```hx
     * part.type; // i64 for a struct of two i32 on aarch64
     * ```
     *
     * @since 1.0.0
     */

    type: Type,
}

/**
 * A scalar inside an aggregate, with its byte offset from the start of the aggregate.
 *
 * @remarks
 * The classification of a struct or an array looks at its scalars, never at its nesting.
 *
 * @example
 * ```hx
 * // struct Pair { a: i32, b: f32 }
 * leaves[1]; // { type: float, offset: 4 }
 * ```
 *
 * @see leavesOf
 * @since 1.0.0
 */

export struct Leaf {
    /**
     * The LLVM type of the scalar.
     *
     * @example
     * ```hx
     * leaf.type; // float
     * ```
     *
     * @since 1.0.0
     */

    type: Type,

    /**
     * The byte offset of the scalar from the start of the aggregate.
     *
     * @example
     * ```hx
     * leaf.offset; // 4 for the second field of a struct of two i32
     * ```
     *
     * @since 1.0.0
     */

    offset: u64,
}
