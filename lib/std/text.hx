/**
 * Whether two strings hold the same bytes.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns `true` when both strings have the same length and the same bytes in the same order
 *
 * @remarks
 * A Helix `string` is `readonly u8[]`, which holds UTF-8 bytes and a length,
 * and every function in this module works on those bytes.
 * The comparison is byte by byte, so two spellings of the same character in different Unicode forms are not equal.
 * Strings of different lengths return `false` before any byte is read.
 *
 * @example
 * ```hx
 * equal("main", "main"); // true
 * equal("main", "Main"); // false
 * equal("", "");         // true
 * ```
 *
 * @since 1.0.0
 */

export function equal(a: string, b: string): bool {
    if (a.len != b.len) return false;
    for (const c, i of a) {
        if (c != b[i]) return false;
    }
    return true;
}

/**
 * Whether a string begins with a prefix.
 *
 * @param text - The string to look at
 * @param prefix - The bytes that the string must begin with
 * @returns `true` when the first bytes of `text` equal `prefix`
 *
 * @remarks
 * An empty prefix matches every string.
 * A prefix longer than the text returns `false` without slicing past its end.
 *
 * @example
 * ```hx
 * startsWith("helix.jsonc", "helix"); // true
 * startsWith("helix", "helix.jsonc"); // false
 * ```
 *
 * @see endsWith
 * @since 1.0.0
 */

export function startsWith(text: string, prefix: string): bool {
    return prefix.len <= text.len && equal(text[0..prefix.len], prefix);
}

/**
 * Whether a string ends with a suffix.
 *
 * @param text - The string to look at
 * @param suffix - The bytes that the string must end with
 * @returns `true` when the last bytes of `text` equal `suffix`
 *
 * @remarks
 * An empty suffix matches every string.
 * A suffix longer than the text returns `false` without slicing past its start.
 *
 * @example
 * ```hx
 * endsWith("main.hx", ".hx"); // true
 * endsWith("main.hx", ".c");  // false
 * ```
 *
 * @see startsWith
 * @since 1.0.0
 */

export function endsWith(text: string, suffix: string): bool {
    return suffix.len <= text.len && equal(text[text.len - suffix.len..], suffix);
}

/**
 * Finds the first occurrence of a needle in a string.
 *
 * @param text - The string to search
 * @param needle - The bytes to look for
 * @returns The byte offset of the first match, or `null` when the needle does not occur
 *
 * @remarks
 * The search compares the needle at every offset from the start, so it takes time proportional to both lengths.
 * An empty needle matches at offset 0.
 * A needle longer than the text returns `null` at once.
 *
 * @example
 * ```hx
 * indexOf("a,b,c", ","); // 1
 * indexOf("a,b,c", "x"); // null
 * indexOf("abc", "");    // 0
 * ```
 *
 * @since 1.0.0
 */

export function indexOf(text: string, needle: string): ?usize {
    if (needle.len > text.len) return null;
    for (const i of 0..=text.len - needle.len) {
        if (equal(text[i..i + needle.len], needle)) return i;
    }
    return null;
}

/**
 * Whether a byte is ASCII whitespace.
 *
 * @param c - The byte to classify
 * @returns `true` for a space, a tab, a line feed, or a carriage return
 *
 * @remarks
 * It leaves out the vertical tab, the form feed, and every non-ASCII space, so {@link trim} keeps those.
 *
 * @since 1.0.0
 */

function isSpace(c: u8): bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/**
 * Removes the whitespace at both ends of a string.
 *
 * @param text - The string to trim
 * @returns A slice of `text` without its leading and trailing spaces, tabs, and line breaks
 *
 * @remarks
 * The result points into `text` and copies nothing, so it lives as long as `text` does.
 * A string of only whitespace gives an empty string.
 *
 * @example
 * ```hx
 * trim("  main \r\n"); // "main"
 * trim(" \t ");        // ""
 * ```
 *
 * @since 1.0.0
 */

export function trim(text: string): string {
    let start: usize = 0;
    let end = text.len;
    while (start < end && isSpace(text[start])) start++;
    while (end > start && isSpace(text[end - 1])) end--;
    return text[start..end];
}

/**
 * The reasons that {@link parseInt} rejects a string.
 *
 * @example
 * ```hx
 * parseInt("");    // throws ParseIntError.Empty
 * parseInt("1.5"); // throws ParseIntError.InvalidDigit
 * ```
 *
 * @since 1.0.0
 */

export error ParseIntError {
    /**
     * The string has no digits.
     *
     * @remarks
     * It covers the empty string and a lone `-`.
     *
     * @example
     * ```hx
     * parseInt("-"); // throws ParseIntError.Empty
     * ```
     *
     * @since 1.0.0
     */

    Empty,

    /**
     * The string holds a byte that is not a decimal digit.
     *
     * @remarks
     * Only the first byte may be `-`, and a `+`, a space, or a decimal point all count as invalid.
     *
     * @example
     * ```hx
     * parseInt("12a"); // throws ParseIntError.InvalidDigit
     * ```
     *
     * @since 1.0.0
     */

    InvalidDigit,

    /**
     * The number does not fit in an `i64`.
     *
     * @example
     * ```hx
     * parseInt("9223372036854775808"); // throws ParseIntError.Overflow
     * ```
     *
     * @since 1.0.0
     */

    Overflow
}

/**
 * Parses a decimal integer with an optional leading minus sign.
 *
 * @param text - The digits, with an optional `-` in front
 * @returns The value of the number
 * @throws ParseIntError.Empty - When the string has no digits
 * @throws ParseIntError.InvalidDigit - When a byte is not a digit
 * @throws ParseIntError.Overflow - When the number falls outside the range of `i64`
 *
 * @remarks
 * It accumulates the value as a negative number, whose range is one larger,
 * so `-9223372036854775808` parses while `9223372036854775808` overflows.
 * It accepts no surrounding whitespace, so pass the string through {@link trim} first where that matters.
 * It accepts leading zeros.
 *
 * @example
 * ```hx
 * parseInt("42");  // 42
 * parseInt("-07"); // -7
 * parseInt(" 1");  // throws ParseIntError.InvalidDigit
 * ```
 *
 * @since 1.0.0
 */

export function parseInt(text: string): i64 | ParseIntError {
    if (text.len == 0) throw ParseIntError.Empty;
    const negative = text[0] == '-';
    const digits = negative ? text[1..] : text;
    if (digits.len == 0) throw ParseIntError.Empty;

    let value: i64 = 0;
    for (const c of digits) {
        if (c < '0' || c > '9') throw ParseIntError.InvalidDigit;
        const digit = (c - '0') as i64;
        // Accumulate as a negative number: its range is one larger, so the minimum i64 parses too.
        if (value < (-9223372036854775807 - 1 + digit) / 10) throw ParseIntError.Overflow;
        value = value * 10 - digit;
    }
    if (negative) return value;
    if (value == -9223372036854775807 - 1) throw ParseIntError.Overflow;
    return -value;
}

/**
 * Splits a string around each occurrence of a separator.
 *
 * @param text - The string to split
 * @param separator - The bytes between the pieces
 * @returns An iterator over the pieces, from left to right
 *
 * @remarks
 * The pieces are slices of `text`, so splitting allocates nothing.
 * Two separators in a row give an empty piece between them, and the text always gives at least one piece.
 *
 * @example
 * ```hx
 * for (const piece of split("a,b,,c", ",")) print(piece); // "a", "b", "", "c"
 * ```
 *
 * @see Split
 * @since 1.0.0
 */

export function split(text: string, separator: string): Split {
    return Split { rest: text, separator, done: false };
}

/**
 * The iterator that {@link split} returns.
 *
 * @remarks
 * Each call to `next` cuts the next piece off the front of `rest`.
 * The last piece is whatever remains after the last separator, even when that is empty,
 * and an empty separator gives the whole text as one piece.
 *
 * @example
 * ```hx
 * let pieces = split("a=b", "=");
 * pieces.next(); // "a"
 * pieces.next(); // "b"
 * pieces.next(); // null
 * ```
 *
 * @see split
 * @since 1.0.0
 */

export struct Split {
    /**
     * The part of the text that the iterator has not handed out yet.
     *
     * @example
     * ```hx
     * let pieces = split("a,b", ",");
     * pieces.next();
     * pieces.rest; // "b"
     * ```
     *
     * @since 1.0.0
     */

    rest: string,

    /**
     * The bytes between the pieces.
     *
     * @example
     * ```hx
     * split("a,b", ",").separator; // ","
     * ```
     *
     * @since 1.0.0
     */

    separator: string,

    /**
     * Whether the iterator has handed out its last piece.
     *
     * @example
     * ```hx
     * let pieces = split("a", ",");
     * pieces.next();
     * pieces.done; // true
     * ```
     *
     * @since 1.0.0
     */

    done: bool,

    /**
     * Returns the next piece.
     *
     * @param this - The iterator to advance
     * @returns The next piece, or `null` after the last one
     *
     * @remarks
     * When `rest` holds no separator, the call returns all of `rest` as the last piece and marks the iterator done.
     *
     * @example
     * ```hx
     * let pieces = split("a,", ",");
     * pieces.next(); // "a"
     * pieces.next(); // ""
     * pieces.next(); // null
     * ```
     *
     * @since 1.0.0
     */

    next(this: *Split): ?string {
        if (this.done) return null;
        if (this.separator.len > 0) {
            if (const at = indexOf(this.rest, this.separator)) {
                const piece = this.rest[0..at];
                this.rest = this.rest[at + this.separator.len..];
                return piece;
            }
        }
        this.done = true;
        return this.rest;
    }
}

/**
 * Splits a string into its lines.
 *
 * @param text - The string to split
 * @returns An iterator over the lines, without their `\n` or `\r\n`
 *
 * @remarks
 * A newline at the very end does not start another line, so `"a\n"` has one line.
 * Each line loses one `\r` at its end, and a `\r` anywhere else stays in the line.
 * The lines are slices of `text`, so the iterator allocates nothing.
 *
 * @example
 * ```hx
 * for (const line of lines("a\r\nb\n")) print(line); // "a", "b"
 * ```
 *
 * @see Lines
 * @since 1.0.0
 */

export function lines(text: string): Lines {
    return Lines { rest: text };
}

/**
 * The iterator that {@link lines} returns.
 *
 * @remarks
 * Each call to `next` cuts the next line and its newline off the front of `rest`,
 * and the iterator ends when `rest` is empty.
 * An empty string therefore has no lines at all.
 *
 * @example
 * ```hx
 * let rows = lines("a\nb");
 * rows.next(); // "a"
 * rows.next(); // "b"
 * rows.next(); // null
 * ```
 *
 * @see lines
 * @since 1.0.0
 */

export struct Lines {
    /**
     * The part of the text that the iterator has not handed out yet.
     *
     * @example
     * ```hx
     * let rows = lines("a\nb");
     * rows.next();
     * rows.rest; // "b"
     * ```
     *
     * @since 1.0.0
     */

    rest: string,

    /**
     * Returns the next line.
     *
     * @param this - The iterator to advance
     * @returns The next line without its newline, or `null` when no text remains
     *
     * @remarks
     * The line ends at the next `\n` or at the end of the text.
     * A `\r` at the end of the line goes with the newline, so Windows line endings read the same as Unix ones.
     *
     * @example
     * ```hx
     * let rows = lines("a\r\n\nb");
     * rows.next(); // "a"
     * rows.next(); // ""
     * rows.next(); // "b"
     * rows.next(); // null
     * ```
     *
     * @since 1.0.0
     */

    next(this: *Lines): ?string {
        if (this.rest.len == 0) return null;
        let end: usize = 0;
        while (end < this.rest.len && this.rest[end] != '\n') end++;
        const line = this.rest[0..end];
        this.rest = end < this.rest.len ? this.rest[end + 1..] : this.rest[end..];
        return endsWith(line, "\r") ? line[0..line.len - 1] : line;
    }
}
