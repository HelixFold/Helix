/**
 * A fixed message buffer that drops what does not fit.
 *
 * @remarks
 * The switch check collects the names of the unhandled cases in it for the hint of its error.
 * The buffer keeps one byte free, so it holds at most 255 bytes of text.
 *
 * @example
 * ```hx
 * let missing = Text { buf: undefined, used: 0 };
 * appendText(&missing, "Color.red");
 * missing.used; // 9
 * ```
 *
 * @since 1.0.0
 */

export struct Text {
    /**
     * The bytes of the text.
     *
     * @example
     * ```hx
     * missing.buf[0]; // the first byte of the text
     * ```
     *
     * @since 1.0.0
     */

    buf: u8[256],

    /**
     * The number of bytes of the buffer in use.
     *
     * @example
     * ```hx
     * missing.used; // 0 for an empty buffer
     * ```
     *
     * @since 1.0.0
     */

    used: usize,
}
