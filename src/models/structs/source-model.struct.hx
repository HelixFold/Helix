/**
 * The source of a whole program, with every file in one buffer.
 *
 * @remarks
 * Files sit one after another, separated by a newline, and the buffer ends with a NUL.
 * Tokens, nodes, and diagnostics point into it by offset,
 * so the rest of the compiler works on a program the same way that it works on a single file.
 * Offsets are 32-bit, which limits a program to 4 GiB of source.
 *
 * @example
 * ```ts
 * let src: HxSource = undefined;
 * hx_source_from_string(&src, "main.hx", "let a = 1;", 10);
 * hx_source_line_col(&src, 4); // { file: 0, line: 1, col: 5, global_line: 0 }
 * hx_source_free(&src);
 * ```
 *
 * @see HxSourceFile
 * @see hx_source_add_file
 *
 * @since 1.0.0
 */

export extern "C" struct HxSource {
    /**
     * The text of every file, NUL-terminated, with a newline between files.
     *
     * @example
     * ```ts
     * // two files 'a' and 'b': a\nb\0
     * ```
     *
     * @since 1.0.0
     */

    text: ?u8[*],

    /**
     * The length of the text in bytes, without the final NUL.
     *
     * @example
     * ```ts
     * src.len; // 3 for two files 'a' and 'b'
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The capacity in bytes of the text buffer.
     *
     * @example
     * ```ts
     * src.cap; // 4096 after the first small file
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,

    /**
     * The offset of the first byte of each line, across all files.
     *
     * @example
     * ```ts
     * // a\nbc: line_starts [ 0, 2 ]
     * ```
     *
     * @since 1.0.0
     */

    line_starts: ?u32[*],

    /**
     * The number of lines across all files.
     *
     * @example
     * ```ts
     * src.line_count; // 2 for a\nbc
     * ```
     *
     * @since 1.0.0
     */

    line_count: u32,

    /**
     * The capacity of the line table.
     *
     * @example
     * ```ts
     * src.line_cap; // 256 after the first file
     * ```
     *
     * @since 1.0.0
     */

    line_cap: u32,

    /**
     * The files of the program, as an array of {@link HxSourceFile} that `files()` reads.
     *
     * @remarks
     * It is typed as bytes so that the layout stays the one C expects.
     *
     * @example
     * ```ts
     * files(&src)[0]; // the first file
     * ```
     *
     * @since 1.0.0
     */

    files: ?u8[*],

    /**
     * The number of files.
     *
     * @example
     * ```ts
     * src.file_count; // 2 for two files
     * ```
     *
     * @since 1.0.0
     */

    file_count: u32,

    /**
     * The capacity of the file array.
     *
     * @example
     * ```ts
     * src.file_cap; // 8 after the first file
     * ```
     *
     * @since 1.0.0
     */

    file_cap: u32,
}

/**
 * The place of one file inside the source buffer.
 *
 * @example
 * ```ts
 * // two files 'a' and 'b'
 * files(&src)[1]; // { path: 'b.hx', start: 2, end: 3, first_line: 1 }
 * ```
 *
 * @see HxSource
 * @since 1.0.0
 */

export extern "C" struct HxSourceFile {
    /**
     * The NUL-terminated path that the file was loaded from.
     *
     * @example
     * ```ts
     * file.path; // 'src/main.hx'
     * ```
     *
     * @since 1.0.0
     */

    path: u8[*],

    /**
     * The offset of the first byte of the file.
     *
     * @example
     * ```ts
     * file.start; // 2 for the second of two one-byte files
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The offset one past the last byte of the file.
     *
     * @example
     * ```ts
     * file.end; // 3 for the second of two one-byte files
     * ```
     *
     * @since 1.0.0
     */

    end: u32,

    /**
     * The index of the first line of the file in the line table of the whole program.
     *
     * @example
     * ```ts
     * file.first_line; // 1 for the second of two one-line files
     * ```
     *
     * @since 1.0.0
     */

    first_line: u32,
}

/**
 * A position in the source as a file, a line, and a column.
 *
 * @example
 * ```ts
 * hx_source_line_col(&src, 4); // { file: 0, line: 1, col: 5, global_line: 0 }
 * ```
 *
 * @see hx_source_line_col
 * @since 1.0.0
 */

export extern "C" struct HxLineCol {
    /**
     * The index of the file in the file array of the source.
     *
     * @example
     * ```ts
     * pos.file; // 0
     * ```
     *
     * @since 1.0.0
     */

    file: u32,

    /**
     * The line within the file, counted from 1.
     *
     * @example
     * ```ts
     * pos.line; // 1
     * ```
     *
     * @since 1.0.0
     */

    line: u32,

    /**
     * The column within the line, counted from 1 in code points.
     *
     * @remarks
     * A multibyte UTF-8 character counts as one column.
     *
     * @example
     * ```ts
     * pos.col; // 5
     * ```
     *
     * @since 1.0.0
     */

    col: u32,

    /**
     * The index of the line in the line table of the whole program, counted from 0.
     *
     * @example
     * ```ts
     * hx_source_line(&src, pos.global_line, &len); // the start of that line
     * ```
     *
     * @since 1.0.0
     */

    global_line: u32,
}
