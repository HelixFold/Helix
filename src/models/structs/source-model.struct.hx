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
 * ```hx
 * let src: HxSource = undefined;
 * hxSourceFromString(&src, "main.hx", "let a = 1;", 10);
 * hxSourceLineCol(&src, 4); // { file: 0, line: 1, col: 5, globalLine: 0 }
 * hxSourceFree(&src);
 * ```
 *
 * @see HxSourceFile
 * @see hxSourceAddFile
 *
 * @since 1.0.0
 */

export extern "C" struct HxSource {
    /**
     * The text of every file, NUL-terminated, with a newline between files.
     *
     * @example
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
     * // a\nbc: lineStarts [ 0, 2 ]
     * ```
     *
     * @since 1.0.0
     */

    lineStarts: ?u32[*],

    /**
     * The number of lines across all files.
     *
     * @example
     * ```hx
     * src.lineCount; // 2 for a\nbc
     * ```
     *
     * @since 1.0.0
     */

    lineCount: u32,

    /**
     * The capacity of the line table.
     *
     * @example
     * ```hx
     * src.lineCap; // 256 after the first file
     * ```
     *
     * @since 1.0.0
     */

    lineCap: u32,

    /**
     * The files of the program, as an array of {@link HxSourceFile} that `files()` reads.
     *
     * @remarks
     * It is typed as bytes so that the layout stays the one C expects.
     *
     * @example
     * ```hx
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
     * ```hx
     * src.fileCount; // 2 for two files
     * ```
     *
     * @since 1.0.0
     */

    fileCount: u32,

    /**
     * The capacity of the file array.
     *
     * @example
     * ```hx
     * src.fileCap; // 8 after the first file
     * ```
     *
     * @since 1.0.0
     */

    fileCap: u32,
}

/**
 * The place of one file inside the source buffer.
 *
 * @remarks
 * Every file of a program shares one text buffer, and this entry marks where its bytes start and end.
 * Files are separated by a newline, so the `end` of one file is one less than the `start` of the next.
 *
 * @example
 * ```hx
 * // two files 'a' and 'b'
 * files(&src)[1]; // { path: 'b.hx', start: 2, end: 3, firstLine: 1 }
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
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
     * file.firstLine; // 1 for the second of two one-line files
     * ```
     *
     * @since 1.0.0
     */

    firstLine: u32,
}

/**
 * A position in the source as a file, a line, and a column.
 *
 * @remarks
 * Lines and columns count from 1 within their file, while `globalLine` counts from 0 across the whole program.
 * A column counts code points, so a multi-byte character advances it by one.
 *
 * @example
 * ```hx
 * hxSourceLineCol(&src, 4); // { file: 0, line: 1, col: 5, globalLine: 0 }
 * ```
 *
 * @see hxSourceLineCol
 * @since 1.0.0
 */

export extern "C" struct HxLineCol {
    /**
     * The index of the file in the file array of the source.
     *
     * @example
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
     * hxSourceLine(&src, pos.globalLine, &len); // the start of that line
     * ```
     *
     * @since 1.0.0
     */

    globalLine: u32,
}
