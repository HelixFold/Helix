/**
 * The layout of `helix-modules` that this compiler reads.
 *
 * @remarks
 * hpm writes the version of the layout it used to `helix-modules/.hpm/layout`.
 * A higher version there is an error at the import.
 *
 * @example
 * ```hx
 * LayoutVersion; // 1
 * ```
 *
 * @since 1.0.0
 */

export const LayoutVersion: i64 = 1;
