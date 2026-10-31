/**
 * The largest `i128`.
 *
 * @remarks
 * {@link hxsIntMax} gives it for `u128` and `i128`, since a `u128` beyond it does not fit in a compile-time value.
 *
 * @example
 * ```hx
 * I128Max; // 170141183460469231731687303715884105727
 * ```
 *
 * @since 1.0.0
 */

export const I128Max: i128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

/**
 * The smallest `i128`.
 *
 * @example
 * ```hx
 * I128Min; // -170141183460469231731687303715884105728
 * ```
 *
 * @since 1.0.0
 */

export const I128Min: i128 = -I128Max - 1;
