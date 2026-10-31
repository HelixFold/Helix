/**
 * Imports
 */

import { fprint } from "./io";
import { ArrayList } from "./list";
import { Allocator, alloc as allocBytes } from "./heap";

/**
 * The error that formatting throws when the output does not fit.
 *
 * @remarks
 * Only {@link bufPrint} throws it, since it writes into a buffer of fixed size.
 *
 * @example
 * ```hx
 * let buf: u8[2] = undefined;
 * fmt.bufPrint(&buf, "abc"); // throws FormatError.NoSpaceLeft
 * ```
 *
 * @since 1.0.0
 */

export error FormatError {
    /**
     * The formatted text is longer than the space left in the buffer.
     *
     * @remarks
     * The bytes that fit before the overflow are already in the buffer when it throws.
     *
     * @example
     * ```hx
     * let buf: u8[4] = undefined;
     * expect(fmt.bufPrint(&buf, "hello")).toThrow(FormatError.NoSpaceLeft); // passes
     * ```
     *
     * @since 1.0.0
     */

    NoSpaceLeft
}

/**
 * Formats a template into new memory from `a`.
 *
 * @param a - The allocator that the text comes from
 * @param text - The template or plain string to format
 * @returns The formatted bytes, owned by the caller, or the error that formatting or allocation threw
 *
 * @remarks
 * Nothing in this module allocates unless it takes an allocator.
 * It formats the template twice, once to {@link count} the bytes and once to write them into memory of that size,
 * so the result is exactly as long as the text.
 * The caller gives it back with `free(a, text)`.
 * Use {@link bufPrint} to format into a buffer the caller owns, and {@link Builder} to build text in steps.
 *
 * @example
 * ```hx
 * const id = 7;
 * const name = try fmt.alloc(a, `id-${id}`);
 * name; // "id-7"
 * free(a, name);
 * ```
 *
 * @see Builder
 * @see bufPrint
 *
 * @since 1.0.0
 */

export function alloc(a: dyn Allocator, text: Format): u8[] | Error {
    const size = try count(text);
    const bytes = try allocBytes<u8>(a, size);
    void try bufPrint(bytes, text);
    return bytes;
}

/**
 * Formats a template into `buf`.
 *
 * @param buf - The buffer to write into
 * @param text - The template or plain string to format
 * @returns The front part of `buf` that holds the text, or `FormatError.NoSpaceLeft`
 *
 * @remarks
 * Nothing allocates, so it suits a short text with a known upper bound on its length.
 * When the text does not fit it throws `FormatError.NoSpaceLeft`, and the bytes that did fit stay in `buf`.
 *
 * @example
 * ```hx
 * let buf: u8[16] = undefined;
 * const point = try fmt.bufPrint(&buf, `${3},${4}`);
 * point; // "3,4"
 * ```
 *
 * @since 1.0.0
 */

export function bufPrint(buf: u8[], text: Format): u8[] | Error {
    let w = BufferWriter { buf, len: 0 };
    try fprint(&w, text);
    return buf[0..w.len];
}

/**
 * Counts the bytes that a template formats to.
 *
 * @param text - The template or plain string to measure
 * @returns The number of bytes, or the error that formatting threw
 *
 * @remarks
 * It formats into a writer that only adds up lengths, so nothing allocates and nothing is stored.
 *
 * @example
 * ```hx
 * fmt.count(`${42}!`); // 3
 * ```
 *
 * @since 1.0.0
 */

export function count(text: Format): usize | Error {
    let w = CountingWriter { total: 0 };
    try fprint(&w, text);
    return w.total;
}

/**
 * A writer that fills a fixed buffer from the front.
 *
 * @remarks
 * `bufPrint` formats through it.
 * Each write copies the whole chunk or, when it would not fit, throws before copying any of it.
 *
 * @since 1.0.0
 */

struct BufferWriter {
    /**
     * The buffer to fill.
     *
     * @since 1.0.0
     */

    buf: u8[],

    /**
     * The number of bytes written so far, which is also where the next write starts.
     *
     * @since 1.0.0
     */

    len: usize,

    /**
     * Copies `bytes` after what the buffer already holds.
     *
     * @param this - The buffer writer
     * @param bytes - The bytes to copy
     * @returns Nothing, or `FormatError.NoSpaceLeft` when `bytes` is longer than the space left
     *
     * @remarks
     * A chunk that does not fit leaves the buffer as it was, so earlier chunks stay whole.
     *
     * @since 1.0.0
     */

    write(this: *BufferWriter, bytes: readonly u8[]): void | Error {
        if (bytes.len > this.buf.len - this.len) throw FormatError.NoSpaceLeft;
        for (const b, i of bytes) this.buf[this.len + i] = b;
        this.len += bytes.len;
    }
}

/**
 * A writer that only counts the bytes it receives.
 *
 * @remarks
 * `count` formats through it to measure a template without storing it.
 *
 * @since 1.0.0
 */

struct CountingWriter {
    /**
     * The number of bytes written so far.
     *
     * @since 1.0.0
     */

    total: usize,

    /**
     * Adds the length of `bytes` to the total.
     *
     * @param this - The counting writer
     * @param bytes - The bytes to count
     * @returns Nothing, since counting never fails
     *
     * @remarks
     * The return type matches the `Writer` interface, which lets other writers fail.
     *
     * @since 1.0.0
     */

    write(this: *CountingWriter, bytes: readonly u8[]): void | Error {
        this.total += bytes.len;
    }
}

/**
 * A growable string.
 *
 * @remarks
 * It appends templates and strings into an `ArrayList<u8>` that grows as needed.
 * A `*Builder` is also a `dyn Writer`, so `fprint` and `fprintln` can write into it.
 * Use it to build text in several steps, and {@link alloc} when one template makes the whole text.
 *
 * @example
 * ```hx
 * let b = fmt.Builder.init(a);
 * defer b.deinit();
 * try b.append("a");
 * try b.append(`${1}`);
 * b.text(); // "a1"
 * ```
 *
 * @since 1.0.0
 */

export struct Builder {
    /**
     * The bytes of the text so far.
     *
     * @remarks
     * The list owns the memory, and `deinit` gives it back.
     *
     * @example
     * ```hx
     * try b.append("hi");
     * b.bytes.items.len; // 2
     * ```
     *
     * @since 1.0.0
     */

    bytes: ArrayList<u8>,

    /**
     * Creates an empty builder that takes its memory from `a`.
     *
     * @param a - The allocator that the text comes from
     * @returns An empty builder
     *
     * @remarks
     * Nothing allocates until the first append.
     *
     * @example
     * ```hx
     * const b = fmt.Builder.init(a);
     * b.text(); // ""
     * ```
     *
     * @since 1.0.0
     */

    init(a: dyn Allocator): Builder {
        return Builder { bytes: ArrayList<u8>.init(a) };
    }

    /**
     * Gives the memory of the text back.
     *
     * @param this - The builder
     *
     * @remarks
     * Any slice from `text` is invalid afterwards, and the builder is empty.
     *
     * @example
     * ```hx
     * b.deinit();
     * b.text(); // ""
     * ```
     *
     * @since 1.0.0
     */

    deinit(this: *Builder): void {
        this.bytes.deinit();
    }

    /**
     * Appends a template or a plain string.
     *
     * @param this - The builder
     * @param text - The template or string to append
     * @returns Nothing, or the error that formatting or growing threw
     *
     * @remarks
     * It formats `text` straight into the builder through `fprint`.
     * Growing may move the text, so a slice from `text` taken before the call is invalid after it.
     *
     * @example
     * ```hx
     * try b.append(`x=${2}`);
     * b.text(); // "x=2"
     * ```
     *
     * @since 1.0.0
     */

    append(this: *Builder, text: Format): void | Error {
        try fprint(this, text);
    }

    /**
     * Appends raw bytes, which makes a `*Builder` a `dyn Writer`.
     *
     * @param this - The builder
     * @param bytes - The bytes to append
     * @returns Nothing, or `AllocError.OutOfMemory` when the text could not grow
     *
     * @remarks
     * It appends the bytes one at a time, and a failure part way leaves the bytes before it in place.
     *
     * @example
     * ```hx
     * try b.write("ok");
     * b.text(); // "ok"
     * ```
     *
     * @since 1.0.0
     */

    write(this: *Builder, bytes: readonly u8[]): void | Error {
        for (const b of bytes) try this.bytes.append(b);
    }

    /**
     * Returns the text so far.
     *
     * @param this - The builder
     * @returns The text, which points into the builder's memory
     *
     * @remarks
     * The slice stays valid until the next append, write, or `deinit`.
     * Copy it to keep it longer.
     *
     * @example
     * ```hx
     * try b.append("abc");
     * b.text(); // "abc"
     * ```
     *
     * @since 1.0.0
     */

    text(this: readonly *Builder): string {
        return this.bytes.items;
    }

    /**
     * Empties the text and keeps the memory for reuse.
     *
     * @param this - The builder
     *
     * @remarks
     * Use it to build several texts in a row without allocating each time.
     *
     * @example
     * ```hx
     * try b.append("abc");
     * b.clear();
     * b.text(); // ""
     * ```
     *
     * @since 1.0.0
     */

    clear(this: *Builder): void {
        this.bytes.clear();
    }
}
