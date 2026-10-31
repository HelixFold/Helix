/**
 * Imports
 */

import { MAX_JSON_DEPTH, EMPTY_JSON } from "@constants/json.constant";
import { hx_alloc, hx_realloc, free } from "@components/memory.component";
import { HxJson, Reader } from "@components/structs/json-component.struct";
import { JSON_NULL, JSON_BOOL, JSON_NUMBER, JSON_STRING, JSON_ARRAY, JSON_OBJECT } from "@constants/json.constant";

/**
 * The C library functions that the reader leans on.
 */

extern "C" function strlen(text: readonly u8[*]): usize;
extern "C" function strtod(text: readonly u8[*], end: *?u8[*]): f64;

/**
 * Records the first failure of a run.
 *
 * @param r - The reader state
 * @param offset - The offset in the text that the failure points at
 * @param message - The message, cut to fit the error buffer
 * @returns Always `false`, so that a caller can write `return fail(...)`
 *
 * @remarks
 * A later failure leaves the first message and offset in place.
 */

function fail(r: *Reader, offset: usize, message: string): bool {
    if (!r.failed) {
        const n = message.len < r.error.len ? message.len : r.error.len - 1;
        for (const i of 0..n) r.error[i] = message[i];
        r.error[n] = 0;
        *r.error_offset = @truncate(u32, offset);
        r.failed = true;
    }
    return false;
}

/**
 * Returns the byte at a distance from the current position.
 *
 * @param r - The reader state
 * @param offset - How far past the current position to look
 * @returns The byte there, or 0 past the end of the text
 */

function at(r: *Reader, offset: usize): u8 {
    return r.pos + offset < r.text.len ? r.text[r.pos + offset] : 0;
}

/**
 * Moves past whitespace, line comments, and block comments.
 *
 * @param r - The reader state
 * @returns `false` after an unclosed block comment, otherwise `true`
 */

function skip(r: *Reader): bool {
    while (r.pos < r.text.len) {
        const c = r.text[r.pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            r.pos += 1;
        } else if (c == '/' && at(r, 1) == '/') {
            while (r.pos < r.text.len && r.text[r.pos] != '\n') r.pos += 1;
        } else if (c == '/' && at(r, 1) == '*') {
            const open = r.pos;
            r.pos += 2;
            while (r.pos + 1 < r.text.len && !(r.text[r.pos] == '*' && r.text[r.pos + 1] == '/')) r.pos += 1;
            if (r.pos + 1 >= r.text.len) return fail(r, open, "this comment is never closed");
            r.pos += 2;
        } else {
            break;
        }
    }
    return true;
}

/**
 * Returns the value of a hex digit.
 *
 * @param c - The character to read
 * @returns The value from 0 to 15, or `null` when the character is not a hex digit
 */

function hexDigit(c: u8): ?u32 {
    if (c >= '0' && c <= '9') return (c - '0') as u32;
    if (c >= 'a' && c <= 'f') return (c - 'a' + 10) as u32;
    if (c >= 'A' && c <= 'F') return (c - 'A' + 10) as u32;
    return null;
}

/**
 * Writes a code point as UTF-8.
 *
 * @param cp - The code point to encode
 * @param out - The buffer to write into
 * @param n - The offset in the buffer to write at
 * @returns The offset just past the bytes written
 */

function encodeUtf8(cp: u32, out: u8[], n: usize): usize {
    if (cp < 0x80) {
        out[n] = @truncate(u8, cp);
        return n + 1;
    }
    if (cp < 0x800) {
        out[n] = @truncate(u8, 0xC0 | (cp >> 6));
        out[n + 1] = @truncate(u8, 0x80 | (cp & 0x3F));
        return n + 2;
    }
    if (cp < 0x10000) {
        out[n] = @truncate(u8, 0xE0 | (cp >> 12));
        out[n + 1] = @truncate(u8, 0x80 | ((cp >> 6) & 0x3F));
        out[n + 2] = @truncate(u8, 0x80 | (cp & 0x3F));
        return n + 3;
    }
    out[n] = @truncate(u8, 0xF0 | (cp >> 18));
    out[n + 1] = @truncate(u8, 0x80 | ((cp >> 12) & 0x3F));
    out[n + 2] = @truncate(u8, 0x80 | ((cp >> 6) & 0x3F));
    out[n + 3] = @truncate(u8, 0x80 | (cp & 0x3F));
    return n + 4;
}

/**
 * Reads the four hex digits of a `\u` escape.
 *
 * @param r - The reader state, positioned at the first digit
 * @returns The value of the digits, or `null` after a failure
 */

function readHex4(r: *Reader): ?u32 {
    if (r.pos + 4 > r.text.len) {
        void fail(r, r.pos, "`\\u` needs four hex digits");
        return null;
    }
    let v: u32 = 0;
    for (const i of 0..4) {
        const digit = hexDigit(r.text[r.pos + i]);
        if (digit == null) {
            void fail(r, r.pos, "`\\u` needs four hex digits");
            return null;
        }
        v = v * 16 + digit;
    }
    r.pos += 4;
    return v;
}

/**
 * Reads the string literal at the current position and decodes it into the C heap.
 *
 * @param r - The reader state, positioned at the opening quote
 * @returns The decoded, NUL-terminated text, or `null` after a failure
 *
 * @remarks
 * A surrogate pair of `\u` escapes becomes one code point.
 * Decoding never makes a string longer, so one block the size of the rest of the text always fits.
 */

function readString(r: *Reader): ?u8[*] {
    const open = r.pos;
    r.pos += 1;
    const raw = hx_alloc(r.text.len - open + 1);
    let out: u8[] = [];
    unsafe {
        out = raw[0..r.text.len - open + 1];
    }
    let n: usize = 0;
    while (true) {
        if (r.pos >= r.text.len) {
            void fail(r, open, "this string is never closed");
            break;
        }
        const c = r.text[r.pos];
        r.pos += 1;
        if (c == '"') {
            out[n] = 0;
            return raw;
        }
        if (c == '\n') {
            void fail(r, open, "a string can't span lines; write `\\n`");
            break;
        }
        if (c < 0x20) {
            void fail(r, r.pos - 1, "control characters must be escaped in a string");
            break;
        }
        if (c != '\\') {
            out[n] = c;
            n += 1;
            continue;
        }
        if (r.pos >= r.text.len) continue;
        const e = r.text[r.pos];
        r.pos += 1;
        switch (e) {
            case '"', '\\', '/': {
                out[n] = e;
                n += 1;
            }
            case 'b', 'f', 'n', 'r', 't': {
                out[n] = switch (e) {
                    case 'b': 0x08;
                    case 'f': 0x0C;
                    case 'n': '\n';
                    case 'r': '\r';
                    default: '\t';
                };
                n += 1;
            }
            case 'u': {
                if (const first = readHex4(r)) {
                    let cp = first;
                    if (cp >= 0xD800 && cp <= 0xDBFF && at(r, 0) == '\\' && at(r, 1) == 'u') {
                        r.pos += 2;
                        if (const low = readHex4(r)) {
                            if (low >= 0xDC00 && low <= 0xDFFF) cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        }
                    }
                    if (!r.failed) n = encodeUtf8(cp, out, n);
                }
            }
            default: void fail(r, r.pos - 2, "unknown escape in a string");
        }
        if (r.failed) break;
    }
    free(raw);
    return null;
}

/**
 * Compares two NUL-terminated strings.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns `true` when both hold the same bytes
 */

function cEqual(a: readonly u8[*], b: readonly u8[*]): bool {
    unsafe {
        let i: usize = 0;
        while (a[i] == b[i]) {
            if (a[i] == 0) return true;
            i += 1;
        }
    }
    return false;
}

/**
 * Reads the elements of an array or the members of an object.
 *
 * @param r - The reader state, positioned at the opening bracket or brace
 * @param out - The value that receives the elements or members
 * @param object - Whether to read an object rather than an array
 * @returns `false` after a failure, otherwise `true`
 *
 * @remarks
 * A trailing comma before the closing bracket or brace is allowed.
 * A key that appears twice in one object is a failure.
 * Each key is counted as soon as it is read, so a failure further on still releases it.
 */

function readList(r: *Reader, out: *HxJson, object: bool): bool {
    const close: u8 = object ? '}' : ']';
    const open = r.pos;
    r.pos += 1;
    let cap: u32 = 0;
    while (true) {
        if (!skip(r)) return false;
        if (r.pos >= r.text.len) return fail(r, open, object ? "this `{` is never closed" : "this `[` is never closed");
        if (r.text[r.pos] == close) {
            r.pos += 1;
            return true;
        }
        if (out.count == cap) {
            cap = cap != 0 ? cap * 2 : 4;
            unsafe {
                out.items = @ptrCast(HxJson[*], hx_realloc(@ptrCast(?u8[*], out.items), (cap as usize) * @sizeOf(HxJson)));
                if (object) {
                    out.keys = @ptrCast((u8[*])[*], hx_realloc(@ptrCast(?u8[*], out.keys), (cap as usize) * @sizeOf(usize)));
                    out.key_starts = @ptrCast(u32[*], hx_realloc(@ptrCast(?u8[*], out.key_starts), (cap as usize) * 4));
                }
            }
        }
        const i = out.count;
        unsafe {
            out.items![i] = EMPTY_JSON;
            if (object) {
                if (r.text[r.pos] != '"') return fail(r, r.pos, "expected a member name in double quotes");
                out.key_starts![i] = @truncate(u32, r.pos);
                const keyAt = r.pos;
                const read = readString(r);
                if (read == null) return false;
                const key = read;
                for (const j of 0..i) {
                    if (cEqual(out.keys![j], key)) {
                        free(key);
                        return fail(r, keyAt, "this member name appears twice");
                    }
                }
                out.keys![i] = key;
                out.count += 1;
                if (!skip(r)) return false;
                if (r.pos >= r.text.len || r.text[r.pos] != ':') return fail(r, r.pos, "expected `:` after the member name");
                r.pos += 1;
                if (!readValue(r, &out.items![i])) return false;
            } else {
                out.count += 1;
                if (!readValue(r, &out.items![i])) return false;
            }
        }
        if (!skip(r)) return false;
        if (r.pos < r.text.len && r.text[r.pos] == ',') {
            r.pos += 1;
            continue;
        }
        if (r.pos < r.text.len && r.text[r.pos] == close) continue;
        if (r.pos >= r.text.len) return fail(r, open, object ? "this `{` is never closed" : "this `[` is never closed");
        return fail(r, r.pos, object ? "expected `,` or `}`" : "expected `,` or `]`");
    }
}

/**
 * Checks whether the text at the current position starts with a word.
 *
 * @param r - The reader state
 * @param word - The word to look for
 * @returns `true` when the next bytes spell the word
 */

function startsWith(r: *Reader, word: string): bool {
    if (r.text.len - r.pos < word.len) return false;
    for (const c, i of word) {
        if (r.text[r.pos + i] != c) return false;
    }
    return true;
}

/**
 * Reads one value of any kind, with the whitespace and comments before it.
 *
 * @param r - The reader state
 * @param out - The value to fill
 * @returns `false` after a failure, otherwise `true`
 *
 * @remarks
 * A number is read with `strtod`, which stops at the first byte that cannot continue a number.
 * Arrays and objects nested deeper than {@link MAX_JSON_DEPTH} are a failure.
 */

function readValue(r: *Reader, out: *HxJson): bool {
    *out = EMPTY_JSON;
    if (!skip(r)) return false;
    if (r.pos >= r.text.len) return fail(r, r.pos, "expected a value");
    r.depth += 1;
    if (r.depth > MAX_JSON_DEPTH) return fail(r, r.pos, "nested more than 256 deep");
    out.start = @truncate(u32, r.pos);
    const c = r.text[r.pos];
    let ok = true;
    if (c == '{' || c == '[') {
        out.kind = c == '{' ? JSON_OBJECT : JSON_ARRAY;
        ok = readList(r, out, c == '{');
    } else if (c == '"') {
        out.kind = JSON_STRING;
        out.string = readString(r);
        ok = out.string != null;
    } else if (c == '-' || (c >= '0' && c <= '9')) {
        out.kind = JSON_NUMBER;
        const begin = &r.text[r.pos];
        let end: ?u8[*] = null;
        out.number = strtod(begin, &end);
        const used = @intFromPtr(end) - @intFromPtr(begin);
        if (used == 0) ok = fail(r, r.pos, "expected a number");
        else r.pos += used;
    } else if (startsWith(r, "true")) {
        out.kind = JSON_BOOL;
        out.boolean = true;
        r.pos += 4;
    } else if (startsWith(r, "false")) {
        out.kind = JSON_BOOL;
        r.pos += 5;
    } else if (startsWith(r, "null")) {
        out.kind = JSON_NULL;
        r.pos += 4;
    } else {
        ok = fail(r, r.pos, c == '\'' ? "strings use double quotes" : "expected a value");
    }
    out.end = @truncate(u32, r.pos);
    r.depth -= 1;
    return ok;
}

/**
 * Parses JSONC text, which is JSON with comments and trailing commas, as in `tsconfig.json`.
 *
 * @param text - The first byte of the text
 * @param len - The length of the text in bytes
 * @param out - The value that receives the parsed tree
 * @param error - The buffer that receives the NUL-terminated message of a failure
 * @param error_size - The size of the error buffer in bytes
 * @param error_offset - The variable that receives the offset that a failure points at
 * @returns `true` when the whole text is one valid value
 *
 * @remarks
 * Both line and block comments are skipped,
 * and a comma may follow the last element of an array or the last member of an object.
 * Text after the value, other than whitespace and comments, is a failure.
 * On failure the output is an empty `null` value, and nothing needs releasing.
 * On success the caller owns the tree and releases it with {@link hx_json_free}.
 *
 * @example
 * ```ts
 * let json: HxJson = undefined;
 * let error: u8[128] = undefined;
 * let at: u32 = 0;
 * const text = "{ \"name\": \"app\", } // trailing comma";
 * hx_json_parse(text.ptr, text.len, &json, &error, error.len, &at); // true
 * hx_json_free(&json);
 * ```
 *
 * @see hx_json_get
 * @see hx_json_free
 *
 * @since 1.0.0
 */

export extern "C" function hx_json_parse(text: readonly u8[*], len: usize, out: *HxJson, error: u8[*], error_size: usize,
                                         error_offset: *u32): bool {
    let r = Reader { text: "", pos: 0, error: [], error_offset, failed: false, depth: 0 };
    unsafe {
        if (len > 0) r.text = text[0..len];
        r.error = error[0..error_size];
    }
    let ok = readValue(&r, out) && skip(&r);
    if (ok && r.pos < len) ok = fail(&r, r.pos, "unexpected text after the value");
    if (!ok) {
        hx_json_free(out);
        *out = EMPTY_JSON;
    }
    return ok;
}

/**
 * Releases the strings, elements, and keys of a parsed tree.
 *
 * @param json - The root of the tree to release
 *
 * @remarks
 * The value itself is left as an empty shell of its kind, with no children.
 * Releasing an already released value does nothing.
 *
 * @example
 * ```ts
 * hx_json_free(&json);
 * json.count; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_json_free(json: *HxJson): void {
    free(json.string);
    unsafe {
        for (const i of 0..json.count) {
            hx_json_free(&json.items![i]);
            if (const keys = json.keys) free(keys[i]);
        }
        free(@ptrCast(?u8[*], json.items));
        free(@ptrCast(?u8[*], json.keys));
        free(@ptrCast(?u8[*], json.key_starts));
    }
    json.string = null;
    json.items = null;
    json.keys = null;
    json.key_starts = null;
    json.count = 0;
}

/**
 * Looks up a member of an object by its key.
 *
 * @param json - The object to look in, or `null`
 * @param key - The NUL-terminated key to find
 * @returns The value of the member, or `null` when there is no such member
 *
 * @remarks
 * A `null` input or a value that is not an object also gives `null`,
 * so lookups chain without a check in between.
 *
 * @example
 * ```ts
 * // { "c": { "sources": ["host.c"] } }
 * hx_json_get(hx_json_get(&json, "c"), "sources"); // the array
 * hx_json_get(hx_json_get(&json, "x"), "sources"); // null
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_json_get(json: ?readonly *HxJson, key: readonly u8[*]): ?readonly *HxJson {
    if (json == null) return null;
    const object = json;
    if (object.kind != JSON_OBJECT) return null;
    unsafe {
        for (const i of 0..object.count) {
            if (cEqual(object.keys![i], key)) return &object.items![i];
        }
    }
    return null;
}

/**
 * Writes a text as a JSON string literal, with its quotes and escapes.
 *
 * @param text - The NUL-terminated text to quote
 * @param out_ptr - The buffer that receives the NUL-terminated literal
 * @param size - The size of the buffer in bytes
 *
 * @remarks
 * Quotes, backslashes, and line breaks get short escapes, and any other control character becomes `\u00XX`.
 * A text too long for the buffer is cut short, and the literal is still closed.
 * A buffer of fewer than 3 bytes is left untouched.
 *
 * @example
 * ```ts
 * let out: u8[64] = undefined;
 * hx_json_quote("say \"hi\"", &out, out.len); // "say \"hi\"" with its quotes
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_json_quote(text: readonly u8[*], out_ptr: u8[*], size: usize): void {
    if (size < 3) return;
    let out: u8[] = [];
    let input: readonly u8[] = [];
    unsafe {
        out = out_ptr[0..size];
        input = text[0..strlen(text)];
    }
    const digits = "0123456789abcdef";
    let n: usize = 0;
    out[n] = '"';
    n += 1;
    for (const c of input) {
        if (n + 8 >= size) break;
        switch (c) {
            case '"', '\\': {
                out[n] = '\\';
                out[n + 1] = c;
                n += 2;
            }
            case '\n', '\r', '\t': {
                out[n] = '\\';
                out[n + 1] = c == '\n' ? 'n' : c == '\r' ? 'r' : 't';
                n += 2;
            }
            default: {
                if (c < 0x20) {
                    for (const d, i of "\\u00") out[n + i] = d;
                    out[n + 4] = digits[c >> 4];
                    out[n + 5] = digits[c & 15];
                    n += 6;
                } else {
                    out[n] = c;
                    n += 1;
                }
            }
        }
    }
    out[n] = '"';
    out[n + 1] = 0;
}
