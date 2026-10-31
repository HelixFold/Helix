/**
 * Imports
 */

import { Builder } from "std/fmt";
import { cAllocator } from "std/heap";
import { Hex } from "@modules/ide/constants/json.constant";
import { hxFatalMessage } from "@components/memory.component";

/**
 * Stops the compiler after a buffer could not grow.
 *
 * @remarks
 * Every writer in this file calls it when the C heap refuses to grow a buffer.
 * It prints `helix: internal compiler error: out of memory` to stderr and aborts the process.
 *
 * @example
 * ```hx
 * b.write(text) catch outOfMemory(); // never returns when the write fails
 * ```
 *
 * @since 1.0.0
 */

export function outOfMemory(): noreturn {
    hxFatalMessage("out of memory");
}

/**
 * Creates a new, empty buffer on the C heap.
 *
 * @returns The buffer, which every other writer in this file appends to
 *
 * @remarks
 * This file is the one JSON writer of the editor support.
 * The language server, the actions, and the analysis all write their answers into such a buffer.
 *
 * @example
 * ```hx
 * let b = buffer();
 * b.text(); // ''
 * ```
 *
 * @since 1.0.0
 */

export function buffer(): Builder {
    return Builder.init(cAllocator());
}

/**
 * Appends text to a buffer as it is.
 *
 * @param b - The buffer to append to
 * @param text - JSON punctuation, or JSON that some other writer made
 *
 * @remarks
 * Nothing is escaped, so the text must already be valid where it lands.
 * Use {@link quoted} for a string value.
 *
 * @example
 * ```hx
 * raw(&b, "{\"a\":");
 * raw(&b, "1}");
 * b.text(); // '{"a":1}'
 * ```
 *
 * @see quoted
 * @since 1.0.0
 */

export function raw(b: *Builder, text: string): void {
    b.write(text) catch outOfMemory();
}

/**
 * Appends a number to a buffer in decimal.
 *
 * @param b - The buffer to append to
 * @param n - The number to write
 *
 * @remarks
 * The number is unsigned, so the text never has a sign, a fraction, or an exponent.
 * A caller with a signed or fractional value formats it itself and appends it with {@link raw}.
 *
 * @example
 * ```hx
 * number(&b, 42);
 * b.text(); // '42'
 * ```
 *
 * @since 1.0.0
 */

export function number(b: *Builder, n: u64): void {
    b.append(`${n}`) catch outOfMemory();
}

/**
 * Appends text to a buffer as a JSON string, quotes included.
 *
 * @param b - The buffer to append to
 * @param text - The text to write, which may hold any byte
 *
 * @remarks
 * A quote and a backslash get a backslash before them.
 * A newline, a tab, and a carriage return become `\n`, `\t`, and `\r`.
 * Every other byte below 0x20 becomes a `\u00XX` escape with lowercase hex digits.
 * Bytes from 0x20 up, UTF-8 sequences included, are copied unchanged.
 *
 * @example
 * ```hx
 * quoted(&b, "say \"hi\"\n");
 * b.text(); // '"say \"hi\"\n"'
 * ```
 *
 * @see quotedList
 * @since 1.0.0
 */

export function quoted(b: *Builder, text: string): void {
    raw(b, "\"");
    let start: usize = 0;
    for (const c, i of text) {
        if (c != '"' && c != '\\' && c >= 0x20) continue;
        raw(b, text[start..i]);
        if (c == '"') raw(b, "\\\"");
        else if (c == '\\') raw(b, "\\\\");
        else if (c == '\n') raw(b, "\\n");
        else if (c == '\t') raw(b, "\\t");
        else if (c == '\r') raw(b, "\\r");
        else {
            raw(b, "\\u00");
            raw(b, Hex[(c >> 4) as usize..(c >> 4) as usize + 1]);
            raw(b, Hex[(c & 15) as usize..(c & 15) as usize + 1]);
        }
        start = i + 1;
    }
    raw(b, text[start..]);
    raw(b, "\"");
}

/**
 * Appends a list of strings to a buffer as a JSON array.
 *
 * @param b - The buffer to append to
 * @param list - The strings to write, each through {@link quoted}
 *
 * @remarks
 * An empty list writes `[]`.
 * Commas go between the items only, so the array never has a trailing comma.
 *
 * @example
 * ```hx
 * const list: string[2] = ["a", "b"];
 * quotedList(&b, &list);
 * b.text(); // '["a","b"]'
 * ```
 *
 * @see quoted
 * @since 1.0.0
 */

export function quotedList(b: *Builder, list: readonly string[]): void {
    raw(b, "[");
    for (const s, i of list) {
        if (i > 0) raw(b, ",");
        quoted(b, s);
    }
    raw(b, "]");
}

/**
 * Appends the key of an object member to a buffer, with its colon.
 *
 * @param b - The buffer to append to
 * @param name - The name of the member
 * @param first - Whether the member is the first of its object, which leaves out the comma before it
 *
 * @remarks
 * The caller writes the braces and the value itself, so this only covers the separator, the key, and the colon.
 * The name goes through {@link quoted}, so any name gives a valid key.
 *
 * @example
 * ```hx
 * raw(&b, "{");
 * writeKey(&b, "kind", true);
 * quoted(&b, "run");
 * writeKey(&b, "cwd", false);
 * quoted(&b, "/p");
 * raw(&b, "}");
 * b.text(); // '{"kind":"run","cwd":"/p"}'
 * ```
 *
 * @since 1.0.0
 */

export function writeKey(b: *Builder, name: string, first: bool): void {
    if (!first) raw(b, ",");
    quoted(b, name);
    raw(b, ":");
}
