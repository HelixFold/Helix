/**
 * The most type arguments that one generic instance takes.
 *
 * @remarks
 * The checker keeps the arguments of one instance in fixed arrays of this size.
 * A type such as `Box<A, B, ...>` with more arguments reports `too many type arguments`,
 * and a generic function with more type parameters reports `too many type parameters`.
 * A generic function may also have at most three times this many parameters.
 *
 * @example
 * ```hx
 * MaxTypeArgs; // 16
 * ```
 *
 * @since 1.0.0
 */

export const MaxTypeArgs: u32 = 16;
