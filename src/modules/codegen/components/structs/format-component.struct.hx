/**
 * One piece of a template, either literal text or a value stored in the values struct.
 *
 * @remarks
 * The formatter of a template walks its pieces in order,
 * writing the text of a text piece and formatting the next stored value for a value piece.
 * A newline that `println` adds also travels as a text piece.
 *
 * @example
 * ```hx
 * // `x = ${x}`
 * pieces[0]; // { text: "x = ", type: 0 }
 * pieces[1]; // { text: "", type: i32 }
 * ```
 *
 * @see templateFormatter
 * @since 1.0.0
 */

export struct Piece {
    /**
     * The literal text of a text piece.
     *
     * @example
     * ```hx
     * piece.text; // "x = "
     * ```
     *
     * @since 1.0.0
     */

    text: string,

    /**
     * The Helix type of a value piece, or 0 for a text piece.
     *
     * @example
     * ```hx
     * piece.type; // 0 for literal text
     * ```
     *
     * @since 1.0.0
     */

    type: u32,
}
