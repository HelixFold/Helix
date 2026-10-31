/**
 * The largest `i128`, the top of the range that compile-time integers can hold.
 *
 * @remarks
 * An integer literal above it is too large, and constant folding treats a result past it as an overflow.
 *
 * @example
 * ```hx
 * I128Max; // 2^127 - 1
 * ```
 *
 * @see I128Min
 * @since 1.0.0
 */

export const I128Max: i128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

/**
 * The smallest `i128`, the bottom of the range that compile-time integers can hold.
 *
 * @remarks
 * Dividing it by -1 overflows, which constant folding reports.
 *
 * @example
 * ```hx
 * I128Min; // -2^127
 * ```
 *
 * @see I128Max
 * @since 1.0.0
 */

export const I128Min: i128 = -I128Max - 1;
