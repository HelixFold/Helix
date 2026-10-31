/**
 * Anything that takes bytes, such as a file, a buffer, or a socket.
 *
 * @remarks
 * A struct implements it with one `write` method, and a pointer to the struct then converts to `dyn Writer`.
 * Formatting calls only `write`, so {@link fprint} and {@link fprintln} work with any writer.
 * Use {@link stdout} and {@link stderr} for the standard streams.
 *
 * @example
 * ```hx
 * const w: dyn Writer = stdout();
 * try fprint(w, `${1 + 1} items`); // prints 2 items
 * ```
 *
 * @since 1.0.0
 */

export interface Writer {
    /**
     * Takes all of the bytes, or fails.
     *
     * @param this - The writer
     * @param bytes - The bytes to take
     * @returns Nothing, or the error that stopped the write
     *
     * @remarks
     * A writer never takes part of the bytes, so a caller does not loop over short writes.
     *
     * @example
     * ```hx
     * try stdout().write("hi\n"); // prints hi
     * ```
     *
     * @since 1.0.0
     */

    write(this: *Self, bytes: readonly u8[]): void | Error;
}

/**
 * Anything that gives bytes, such as a file, stdin, or a socket.
 *
 * @remarks
 * A struct implements it with one `read` method, and a pointer to the struct then converts to `dyn Reader`.
 *
 * @example
 * ```hx
 * const r: dyn Reader = &file;
 * const n = try r.read(buffer); // the count of bytes read, 0 at the end
 * ```
 *
 * @since 1.0.0
 */

export interface Reader {
    /**
     * Reads bytes into a buffer.
     *
     * @param this - The reader
     * @param buf - The buffer to fill
     * @returns The number of bytes that it read, or 0 when there is nothing more, or the error that stopped the read
     *
     * @remarks
     * A read may fill only part of the buffer, so a caller loops until it gets 0.
     *
     * @example
     * ```hx
     * const n = try r.read(buffer); // 4, then 1, then 0 for a reader with 5 bytes and a buffer of 4
     * ```
     *
     * @since 1.0.0
     */

    read(this: *Self, buf: u8[]): usize | Error;
}

/**
 * Writes a template or a plain string to a writer.
 *
 * @param w - The writer
 * @param text - The template or the string
 * @returns Nothing, or the error that the writer threw
 *
 * @remarks
 * The template writes itself piece by piece, so the writer may get several calls for one template.
 * Nothing follows the text, so use {@link fprintln} to end the line.
 *
 * @example
 * ```hx
 * const n = 42;
 * try fprint(stderr(), `n=${n}`); // prints n=42 on stderr
 * ```
 *
 * @since 1.0.0
 */

export function fprint(w: dyn Writer, text: Format): void | Error {
    try text.writeTo(w);
}

/**
 * Writes a template or a plain string to a writer, then a newline.
 *
 * @param w - The writer
 * @param text - The template or the string
 * @returns Nothing, or the error that the writer threw
 *
 * @remarks
 * It works like {@link fprint} and writes the newline in a separate call to the writer.
 *
 * @example
 * ```hx
 * try fprintln(stdout(), "done"); // prints done and a newline
 * ```
 *
 * @since 1.0.0
 */

export function fprintln(w: dyn Writer, text: Format): void | Error {
    try text.writeTo(w);
    try w.write("\n");
}

/**
 * Writes bytes to a file descriptor.
 *
 * @remarks
 * The runtime in `lib/rt/runtime.c` implements it.
 * For descriptors 0 to 2 it writes to the buffered C stream, which `print` and `eprint` share,
 * and for any other descriptor it writes directly and retries on an interrupted call.
 *
 * @since 1.0.0
 */

extern "C" function hx_write(fd: i32, bytes: readonly u8[*], len: usize): void;

/**
 * The writer behind {@link stdout}.
 *
 * @remarks
 * It has no fields, since the C stream that it writes to keeps the buffer.
 *
 * @since 1.0.0
 */

struct Stdout {
    /**
     * Writes bytes to standard output.
     *
     * @param this - The writer
     * @param bytes - The bytes to write
     * @returns Nothing, since it never reports an error
     *
     * @remarks
     * The bytes go through the buffer that `print` uses, so the two keep their order.
     *
     * @since 1.0.0
     */

    write(this: *Stdout, bytes: readonly u8[]): void | Error {
        hx_write(1, bytes.ptr, bytes.len);
    }
}

/**
 * The writer behind {@link stderr}.
 *
 * @remarks
 * It has no fields, since the C stream that it writes to keeps the buffer.
 *
 * @since 1.0.0
 */

struct Stderr {
    /**
     * Writes bytes to standard error.
     *
     * @param this - The writer
     * @param bytes - The bytes to write
     * @returns Nothing, since it never reports an error
     *
     * @remarks
     * The bytes go through the buffer that `eprint` uses, so the two keep their order.
     *
     * @since 1.0.0
     */

    write(this: *Stderr, bytes: readonly u8[]): void | Error {
        hx_write(2, bytes.ptr, bytes.len);
    }
}

/**
 * The one writer for standard output.
 *
 * @remarks
 * It has no fields, so it needs no initialization.
 *
 * @since 1.0.0
 */

let stdoutWriter: Stdout = undefined;

/**
 * The one writer for standard error.
 *
 * @remarks
 * It has no fields, so it needs no initialization.
 *
 * @since 1.0.0
 */

let stderrWriter: Stderr = undefined;

/**
 * Returns the writer for standard output.
 *
 * @returns The writer
 *
 * @remarks
 * It shares its buffer with `print`, so output from both comes out in order.
 * Every call returns the same writer.
 *
 * @example
 * ```hx
 * print("a");
 * try stdout().write("b"); // stdout shows ab
 * ```
 *
 * @since 1.0.0
 */

export function stdout(): dyn Writer {
    return &stdoutWriter;
}

/**
 * Returns the writer for standard error.
 *
 * @returns The writer
 *
 * @remarks
 * It shares its buffer with `eprint`, so output from both comes out in order.
 * Every call returns the same writer.
 *
 * @example
 * ```hx
 * try fprintln(stderr(), "warning: disk almost full"); // prints the line on stderr
 * ```
 *
 * @since 1.0.0
 */

export function stderr(): dyn Writer {
    return &stderrWriter;
}
