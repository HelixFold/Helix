/**
 * Imports
 */

import { Writer } from "./io";
import { ArrayList } from "./list";
import { Allocator, alloc, free } from "./heap";

/**
 * Converts the decimal number at the start of a C string to a double.
 *
 * @param text - The number, followed by a NUL byte
 * @param end - Receives the address of the first byte after the number
 * @returns The nearest `f64` to the number
 *
 * @remarks
 * The C library implements it, and it rounds correctly, which a hand-written conversion would not.
 * {@link Reader.numberValue} checks the JSON grammar first and only hands over text that is a valid number.
 *
 * @since 1.0.0
 */

extern "C" function strtod(text: readonly u8[*], end: *?u8[*]): f64;

/**
 * The kinds of JSON value.
 *
 * @remarks
 * The kind of a {@link JsonValue} says which of its fields holds the content.
 *
 * @example
 * ```hx
 * parseJson(allocator, "[1]", JsonOptions {}, &problem)!.kind; // JsonKind.Array
 * ```
 *
 * @since 1.0.0
 */

export enum JsonKind {
    /**
     * The `null` literal, which carries no content.
     *
     * @example
     * ```hx
     * parseJson(allocator, "null", options, &problem)!.kind; // JsonKind.Null
     * ```
     *
     * @since 1.0.0
     */

    Null,

    /**
     * The `true` or `false` literal, whose value is in `boolean`.
     *
     * @example
     * ```hx
     * parseJson(allocator, "true", options, &problem)!.boolean; // true
     * ```
     *
     * @since 1.0.0
     */

    Bool,

    /**
     * A number, whose value is in `number`.
     *
     * @example
     * ```hx
     * parseJson(allocator, "2.5e1", options, &problem)!.number; // 25
     * ```
     *
     * @since 1.0.0
     */

    Number,

    /**
     * A string, whose decoded text is in `text`.
     *
     * @example
     * ```hx
     * parseJson(allocator, "\"a\\nb\"", options, &problem)!.text; // "a\nb"
     * ```
     *
     * @since 1.0.0
     */

    String,

    /**
     * An array, whose elements are in `items`.
     *
     * @example
     * ```hx
     * parseJson(allocator, "[1, 2]", options, &problem)!.items.len; // 2
     * ```
     *
     * @since 1.0.0
     */

    Array,

    /**
     * An object, whose names are in `keys` and whose values are in `items`, in the same order.
     *
     * @example
     * ```hx
     * parseJson(allocator, "{\"a\": 1}", options, &problem)!.keys[0]; // "a"
     * ```
     *
     * @since 1.0.0
     */

    Object
}

/**
 * One parsed JSON value, together with the place in the text that it came from.
 *
 * @remarks
 * A single struct holds every kind of value, and `kind` says which fields matter.
 * The fields that the kind does not use hold `false`, `0`, or an empty slice.
 * Its strings and slices point into memory from the allocator passed to {@link parseJson},
 * so the value lives until that allocator frees it.
 * Because `start` and `end` locate every value in the source,
 * a tool can rewrite one value and keep the comments, order, and spacing of the rest of the file.
 *
 * @example
 * ```hx
 * const doc = try parseJson(allocator, "{\"name\": \"hx\"}", JsonOptions {}, &problem);
 * doc.kind;                    // JsonKind.Object
 * doc.get("name")?.text;       // "hx"
 * ```
 *
 * @since 1.0.0
 */

export struct JsonValue {
    /**
     * The kind of the value, which decides the fields that hold its content.
     *
     * @example
     * ```hx
     * doc.kind; // JsonKind.Object
     * ```
     *
     * @since 1.0.0
     */

    kind: JsonKind,

    /**
     * The value of a `Bool`, and `false` for every other kind.
     *
     * @example
     * ```hx
     * doc.get("debug")!.boolean; // true
     * ```
     *
     * @since 1.0.0
     */

    boolean: bool,

    /**
     * The value of a `Number`, and 0 for every other kind.
     *
     * @remarks
     * Every number is an `f64`, so integers beyond 2 to the power of 53 lose precision.
     *
     * @example
     * ```hx
     * doc.get("port")!.number; // 8080
     * ```
     *
     * @since 1.0.0
     */

    number: f64,

    /**
     * The decoded text of a `String`, and an empty string for every other kind.
     *
     * @remarks
     * The parser resolves escapes and writes each `\u` escape out as UTF-8.
     *
     * @example
     * ```hx
     * doc.get("name")!.text; // "hx"
     * ```
     *
     * @since 1.0.0
     */

    text: string,

    /**
     * The elements of an `Array` or the member values of an `Object`, in the order of the text.
     *
     * @example
     * ```hx
     * doc.get("list")!.items.len; // 3
     * ```
     *
     * @since 1.0.0
     */

    items: JsonValue[],

    /**
     * The member names of an `Object`, in the order of the text.
     *
     * @remarks
     * Name `i` belongs to value `i` of `items`.
     * Duplicate names stay in the list, and {@link JsonValue.get} finds the first.
     *
     * @example
     * ```hx
     * doc.keys[0]; // "name"
     * ```
     *
     * @since 1.0.0
     */

    keys: string[],

    /**
     * The byte offset of the first byte of the value in the text.
     *
     * @remarks
     * It points at the opening quote of a string and the opening bracket of an array or object.
     *
     * @example
     * ```hx
     * doc.get("name")!.start; // 9 in {"name": "hx"}
     * ```
     *
     * @since 1.0.0
     */

    start: usize,

    /**
     * The byte offset just past the last byte of the value in the text.
     *
     * @remarks
     * The value spans `text[start..end]`, closing quote or bracket included.
     *
     * @example
     * ```hx
     * doc.get("name")!.end; // 13 in {"name": "hx"}
     * ```
     *
     * @since 1.0.0
     */

    end: usize,

    /**
     * Looks up a member of an object by name.
     *
     * @param this - The value to search
     * @param key - The member name to find
     * @returns The first member called `key`, or `null` when there is none or the value is not an object
     *
     * @remarks
     * It compares the names byte by byte in order, so a lookup takes time proportional to the number of members.
     * The result points into `items`, so it stays valid as long as the value does.
     *
     * @example
     * ```hx
     * doc.get("name")?.text ?? "unnamed"; // "hx"
     * doc.get("missing");                 // null
     * ```
     *
     * @since 1.0.0
     */

    get(this: readonly *JsonValue, key: string): ?readonly *JsonValue {
        if (this.kind != JsonKind.Object) return null;
        for (const k, i of this.keys) {
            if (same(k, key)) return &this.items[i];
        }
        return null;
    }

    /**
     * Returns the text of a string value.
     *
     * @param this - The value to read
     * @returns The decoded text, or `null` when the value is not a string
     *
     * @remarks
     * Use it to tell an empty string apart from a value of another kind, since both have an empty `text`.
     *
     * @example
     * ```hx
     * doc.get("name")!.string(); // "hx"
     * doc.string();              // null for an object
     * ```
     *
     * @since 1.0.0
     */

    string(this: readonly *JsonValue): ?string {
        if (this.kind != JsonKind.String) return null;
        return this.text;
    }
}

/**
 * The options of {@link parseJson}.
 *
 * @remarks
 * `JsonOptions {}` reads strict JSON, and `JsonOptions { comments: true }` reads JSONC as in `tsconfig.json`.
 *
 * @example
 * ```hx
 * parseJson(allocator, "[1,]", JsonOptions { comments: true }, &problem)!.items.len; // 1
 * ```
 *
 * @since 1.0.0
 */

export struct JsonOptions {
    /**
     * Whether to accept comments and trailing commas.
     *
     * @remarks
     * When `true`, line comments, block comments, and a comma before a closing bracket all pass.
     * When `false`, the default, each of them is a syntax error.
     *
     * @example
     * ```hx
     * JsonOptions {}.comments; // false
     * ```
     *
     * @since 1.0.0
     */

    comments: bool = false,
}

/**
 * The description of a parse error.
 *
 * @remarks
 * {@link parseJson} fills it in for every syntax error and for nesting that goes too deep.
 * It stays as it was when parsing succeeds or when the allocator fails.
 *
 * @example
 * ```hx
 * let problem = JsonProblem { message: "", at: 0 };
 * parseJson(allocator, "[1,]", JsonOptions {}, &problem); // throws JsonError.Syntax
 * problem.message;                                        // "trailing comma"
 * ```
 *
 * @see lineCol
 * @since 1.0.0
 */

export struct JsonProblem {
    /**
     * What went wrong, in words.
     *
     * @remarks
     * The messages are static strings, so the problem needs no allocator.
     *
     * @example
     * ```hx
     * problem.message; // "expected `:` after the member name"
     * ```
     *
     * @since 1.0.0
     */

    message: string,

    /**
     * The byte offset in the text where the problem was found.
     *
     * @remarks
     * Pass it to {@link lineCol} for a line and a column.
     *
     * @example
     * ```hx
     * problem.at; // 3 for [1,]
     * ```
     *
     * @since 1.0.0
     */

    at: usize,
}

/**
 * The errors that {@link parseJson} reports about the text.
 *
 * @remarks
 * A failing allocator throws its own error instead, which leaves the {@link JsonProblem} untouched.
 *
 * @example
 * ```hx
 * parseJson(allocator, "{", JsonOptions {}, &problem); // throws JsonError.Syntax
 * ```
 *
 * @since 1.0.0
 */

export error JsonError {
    /**
     * The text breaks the grammar of JSON, or of JSONC when comments are on.
     *
     * @example
     * ```hx
     * parseJson(allocator, "[1 2]", JsonOptions {}, &problem); // throws JsonError.Syntax
     * ```
     *
     * @since 1.0.0
     */

    Syntax,

    /**
     * The arrays and objects nest more than 256 deep.
     *
     * @remarks
     * The limit keeps the recursive parser from running out of stack on hostile input.
     *
     * @example
     * ```hx
     * parseJson(allocator, text, JsonOptions {}, &problem); // throws JsonError.TooDeep for 257 [ in a row
     * ```
     *
     * @since 1.0.0
     */

    TooDeep
}

/**
 * A position in a text as a line and a column.
 *
 * @remarks
 * Both count from 1, which is the form that editors and compiler messages use.
 *
 * @example
 * ```hx
 * const where = lineCol("{\n  x\n}", 4);
 * `${where.line}:${where.col}`; // "2:3"
 * ```
 *
 * @see lineCol
 * @since 1.0.0
 */

export struct LineCol {
    /**
     * The line number, counting from 1.
     *
     * @example
     * ```hx
     * lineCol("a\nb", 2).line; // 2
     * ```
     *
     * @since 1.0.0
     */

    line: usize,

    /**
     * The column number, counting bytes from 1.
     *
     * @remarks
     * It counts bytes and not characters, so a multi-byte UTF-8 character moves it by more than 1.
     *
     * @example
     * ```hx
     * lineCol("a\nbc", 3).col; // 2
     * ```
     *
     * @since 1.0.0
     */

    col: usize,
}

/**
 * Turns a byte offset into a line and a column.
 *
 * @param text - The text that the offset points into
 * @param at - The byte offset, such as `at` of a {@link JsonProblem}
 * @returns The 1-based line and column of the offset
 *
 * @remarks
 * Each `\n` before the offset starts a new line, and every other byte moves the column by one.
 * An offset past the end of the text gives the position just after the last byte.
 *
 * @example
 * ```hx
 * const where = lineCol("{\n  x\n}", 4);
 * where.line; // 2
 * where.col;  // 3
 * ```
 *
 * @since 1.0.0
 */

export function lineCol(text: string, at: usize): LineCol {
    let line: usize = 1;
    let col: usize = 1;
    for (const c, i of text) {
        if (i >= at) break;
        if (c == '\n') {
            line++;
            col = 1;
        } else {
            col++;
        }
    }
    return LineCol { line, col };
}

/**
 * Whether two strings hold the same bytes.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns `true` when both strings have the same length and bytes
 *
 * @remarks
 * It repeats `equal` of `text.hx` so that this module needs no import for one comparison.
 *
 * @since 1.0.0
 */

function same(a: string, b: string): bool {
    if (a.len != b.len) return false;
    for (const c, i of a) {
        if (c != b[i]) return false;
    }
    return true;
}

/**
 * The state of one parse, which walks the text once from the start.
 *
 * @remarks
 * It parses by recursive descent, with one method per part of the grammar,
 * and each method leaves `pos` just after what it read.
 * A method that finds an error records it in `problem` and throws, and nothing catches it until {@link parseJson}.
 *
 * @since 1.0.0
 */

struct Reader {
    /**
     * The whole text being parsed.
     *
     * @since 1.0.0
     */

    text: string,

    /**
     * The byte offset of the next byte to read.
     *
     * @since 1.0.0
     */

    pos: usize,

    /**
     * The allocator that every string, array, and object of the result comes from.
     *
     * @since 1.0.0
     */

    allocator: dyn Allocator,

    /**
     * Whether comments and trailing commas are allowed.
     *
     * @since 1.0.0
     */

    comments: bool,

    /**
     * The caller's problem record, which every error fills in.
     *
     * @since 1.0.0
     */

    problem: *JsonProblem,

    /**
     * The number of arrays and objects that enclose the current position.
     *
     * @since 1.0.0
     */

    depth: u32,

    /**
     * Records a syntax error at the current position.
     *
     * @param this - The reader that found the error
     * @param message - The description of the error
     * @returns `JsonError.Syntax`, for the caller to throw
     *
     * @remarks
     * It returns the error instead of throwing it, so each call site reads `throw this.fail(...)`.
     *
     * @since 1.0.0
     */

    fail(this: *Reader, message: string): JsonError {
        this.problem.message = message;
        this.problem.at = this.pos;
        return JsonError.Syntax;
    }

    /**
     * Returns the next byte without consuming it.
     *
     * @param this - The reader to look into
     * @returns The byte at `pos`, or 0 at the end of the text
     *
     * @remarks
     * A NUL byte inside the text therefore looks the same as the end, and the grammar rejects both.
     *
     * @since 1.0.0
     */

    peek(this: readonly *Reader): u8 {
        return this.pos < this.text.len ? this.text[this.pos] : 0;
    }

    /**
     * Moves past whitespace, and past comments when they are allowed.
     *
     * @param this - The reader to advance
     * @returns Nothing, or `JsonError.Syntax` when the comments break the rules
     * @throws JsonError.Syntax - When a comment appears in strict JSON, or a block comment never closes
     *
     * @remarks
     * Whitespace is a space, a tab, a line feed, or a carriage return.
     * A `/` that starts no comment stays in place for the caller to reject.
     *
     * @since 1.0.0
     */

    skip(this: *Reader): void | JsonError {
        while (this.pos < this.text.len) {
            const c = this.text[this.pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                this.pos++;
                continue;
            }
            if (c != '/' || this.pos + 1 >= this.text.len) return;
            if (!this.comments && (this.text[this.pos + 1] == '/' || this.text[this.pos + 1] == '*')) {
                throw this.fail("JSON has no comments (`{ comments: true }` reads JSONC)");
            }
            const next = this.text[this.pos + 1];
            if (next == '/') {
                while (this.pos < this.text.len && this.text[this.pos] != '\n') this.pos++;
            } else if (next == '*') {
                this.pos += 2;
                while (this.pos + 1 < this.text.len && !(this.text[this.pos] == '*' && this.text[this.pos + 1] == '/')) this.pos++;
                if (this.pos + 1 >= this.text.len) throw this.fail("unterminated comment");
                this.pos += 2;
            } else {
                return;
            }
        }
    }

    /**
     * Consumes a fixed word when the text continues with it.
     *
     * @param this - The reader to advance
     * @param w - The word to match, such as `true`
     * @returns `true` and moves past the word on a match, or `false` and stays in place
     *
     * @remarks
     * It checks only the bytes of the word, so `nullx` matches `null` and the next step rejects the `x`.
     *
     * @since 1.0.0
     */

    word(this: *Reader, w: string): bool {
        if (this.pos + w.len > this.text.len || !same(this.text[this.pos..this.pos + w.len], w)) return false;
        this.pos += w.len;
        return true;
    }

    /**
     * Parses one value of any kind.
     *
     * @param this - The reader to advance
     * @returns The value, with `start` and `end` set
     * @throws JsonError.Syntax - When no value starts at the current position
     * @throws JsonError.TooDeep - When the value would open a 257th level of nesting
     *
     * @remarks
     * It skips the whitespace in front, then picks the rule from the first byte.
     * Each array and object raises `depth` for its contents and lowers it after the closing bracket.
     *
     * @since 1.0.0
     */

    value(this: *Reader): JsonValue | Error {
        try this.skip();
        let v = JsonValue { kind: JsonKind.Null, boolean: false, number: 0, text: "", items: [], keys: [], start: this.pos, end: this.pos };
        const c = this.peek();
        if (c == '{' || c == '[') {
            this.depth++;
            if (this.depth > 256) {
                this.problem.message = "nested more than 256 deep";
                this.problem.at = this.pos;
                throw JsonError.TooDeep;
            }
            if (c == '{') try this.object(&v);
            else try this.array(&v);
            this.depth--;
        } else if (c == '"') {
            v.kind = JsonKind.String;
            v.text = try this.string();
        } else if (c == '-' || (c >= '0' && c <= '9')) {
            v.kind = JsonKind.Number;
            v.number = try this.numberValue();
        } else if (this.word("true")) {
            v.kind = JsonKind.Bool;
            v.boolean = true;
        } else if (this.word("false")) {
            v.kind = JsonKind.Bool;
        } else if (!this.word("null")) {
            throw this.fail(this.pos >= this.text.len ? "expected a value, found the end" : "expected a value");
        }
        v.end = this.pos;
        return v;
    }

    /**
     * Parses a number.
     *
     * @param this - The reader to advance
     * @returns The number as the nearest `f64`
     * @throws JsonError.Syntax - When a digit is missing after the sign, the `.`, or the exponent
     *
     * @remarks
     * It checks the grammar of JSON itself, then copies the digits with a NUL after them and lets `strtod` convert.
     * The copy comes from the allocator and goes back to it right away.
     * It does not reject leading zeros, which strict JSON forbids, so `01` reads as 1.
     *
     * @since 1.0.0
     */

    numberValue(this: *Reader): f64 | Error {
        const start = this.pos;
        if (this.peek() == '-') this.pos++;
        if (this.peek() < '0' || this.peek() > '9') throw this.fail("expected a digit");
        while (this.peek() >= '0' && this.peek() <= '9') this.pos++;
        if (this.peek() == '.') {
            this.pos++;
            if (this.peek() < '0' || this.peek() > '9') throw this.fail("expected a digit after `.`");
            while (this.peek() >= '0' && this.peek() <= '9') this.pos++;
        }
        if (this.peek() == 'e' || this.peek() == 'E') {
            this.pos++;
            if (this.peek() == '+' || this.peek() == '-') this.pos++;
            if (this.peek() < '0' || this.peek() > '9') throw this.fail("expected a digit in the exponent");
            while (this.peek() >= '0' && this.peek() <= '9') this.pos++;
        }
        // strtod wants a NUL after the number
        const len = this.pos - start;
        const copy = try alloc<u8>(this.allocator, len + 1);
        defer free(this.allocator, copy);
        for (const i of 0..len) copy[i] = this.text[start + i];
        copy[len] = 0;
        let end: ?u8[*] = null;
        return strtod(copy.ptr, &end);
    }

    /**
     * Parses the four hex digits after a `\u`.
     *
     * @param this - The reader to advance
     * @returns The code unit that the digits spell
     * @throws JsonError.Syntax - When one of the four bytes is not a hex digit
     *
     * @remarks
     * It accepts both lowercase and uppercase digits.
     *
     * @since 1.0.0
     */

    hex4(this: *Reader): u32 | JsonError {
        let v: u32 = 0;
        for (const _ of 0..4) {
            const c = this.peek();
            let d: u32 = 0;
            if (c >= '0' && c <= '9') d = (c - '0') as u32;
            else if (c >= 'a' && c <= 'f') d = (c - 'a') as u32 + 10;
            else if (c >= 'A' && c <= 'F') d = (c - 'A') as u32 + 10;
            else throw this.fail("expected 4 hex digits after `\\u`");
            v = v * 16 + d;
            this.pos++;
        }
        return v;
    }

    /**
     * Parses a string and decodes it.
     *
     * @param this - The reader to advance, positioned at the opening quote
     * @returns The decoded text
     * @throws JsonError.Syntax - When the string never closes, holds a raw control byte, or has an unknown escape
     *
     * @remarks
     * It resolves every escape and writes each `\u` code point out as UTF-8.
     * A high surrogate directly followed by another `\u` escape joins it into one code point.
     * A surrogate without its partner becomes three bytes of its own, which is not valid UTF-8.
     * A high surrogate followed by a `\u` escape outside the low surrogates overflows the arithmetic and panics.
     * The parser never trims the `ArrayList` that holds the text, so its storage can be larger than the result.
     *
     * @since 1.0.0
     */

    string(this: *Reader): string | Error {
        this.pos++;   // the opening quote
        let out = ArrayList<u8>.init(this.allocator);
        while (true) {
            if (this.pos >= this.text.len) throw this.fail("unterminated string");
            const c = this.text[this.pos];
            if (c == '"') break;
            if (c < 0x20) throw this.fail("a control character in a string must be escaped");
            this.pos++;
            if (c != '\\') {
                try out.append(c);
                continue;
            }
            const e = this.peek();
            this.pos++;
            if (e == '"' || e == '\\' || e == '/') try out.append(e);
            else if (e == 'n') try out.append('\n');
            else if (e == 't') try out.append('\t');
            else if (e == 'r') try out.append('\r');
            else if (e == 'b') try out.append(8);
            else if (e == 'f') try out.append(12);
            else if (e == 'u') {
                let code = try this.hex4();
                if (code >= 0xD800 && code < 0xDC00 && this.word("\\u")) {   // a surrogate pair
                    const low = try this.hex4();
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                }
                if (code < 0x80) {
                    try out.append(@truncate(u8, code));
                } else if (code < 0x800) {
                    try out.append(@truncate(u8, 0xC0 | (code >> 6)));
                    try out.append(@truncate(u8, 0x80 | (code & 0x3F)));
                } else if (code < 0x10000) {
                    try out.append(@truncate(u8, 0xE0 | (code >> 12)));
                    try out.append(@truncate(u8, 0x80 | ((code >> 6) & 0x3F)));
                    try out.append(@truncate(u8, 0x80 | (code & 0x3F)));
                } else {
                    try out.append(@truncate(u8, 0xF0 | (code >> 18)));
                    try out.append(@truncate(u8, 0x80 | ((code >> 12) & 0x3F)));
                    try out.append(@truncate(u8, 0x80 | ((code >> 6) & 0x3F)));
                    try out.append(@truncate(u8, 0x80 | (code & 0x3F)));
                }
            } else {
                this.pos--;
                throw this.fail("unknown escape in a string");
            }
        }
        this.pos++;   // the closing quote
        return out.items;
    }

    /**
     * Reads what follows an item of an array or object.
     *
     * @param this - The reader to advance
     * @param close - The closing bracket of the container, `]` or `}`
     * @returns `true` after a comma that another item follows, or `false` at the closing bracket
     * @throws JsonError.Syntax - When neither a comma nor the bracket follows, or on a trailing comma in strict JSON
     *
     * @remarks
     * It leaves `pos` on the closing bracket and does not consume it, so the caller moves past it.
     *
     * @since 1.0.0
     */

    separator(this: *Reader, close: u8): bool | Error {
        try this.skip();
        if (this.peek() == ',') {
            this.pos++;
            try this.skip();
            if (this.peek() == close) {
                if (!this.comments) throw this.fail("trailing comma");
                return false;
            }
            return true;
        }
        if (this.peek() != close) throw this.fail(close == ']' ? "expected `,` or `]`" : "expected `,` or `}`");
        return false;
    }

    /**
     * Parses the elements of an array into a value.
     *
     * @param this - The reader to advance, positioned at the `[`
     * @param v - The value to fill in as an array
     * @returns Nothing, or the error of an element, of a separator, or of the allocator
     *
     * @remarks
     * The elements collect in an `ArrayList` from the allocator, and the value keeps its items.
     *
     * @since 1.0.0
     */

    array(this: *Reader, v: *JsonValue): void | Error {
        v.kind = JsonKind.Array;
        this.pos++;
        let items = ArrayList<JsonValue>.init(this.allocator);
        try this.skip();
        if (this.peek() != ']') {
            while (true) {
                try items.append(try this.value());
                if (!try this.separator(']')) break;
            }
        }
        this.pos++;
        v.items = items.items;
    }

    /**
     * Parses the members of an object into a value.
     *
     * @param this - The reader to advance, positioned at the `{`
     * @param v - The value to fill in as an object
     * @returns Nothing, or the error of a member, of a separator, or of the allocator
     *
     * @remarks
     * The names and the values collect in two lists side by side, so name `i` belongs to value `i`.
     * It keeps duplicate names as they are.
     *
     * @since 1.0.0
     */

    object(this: *Reader, v: *JsonValue): void | Error {
        v.kind = JsonKind.Object;
        this.pos++;
        let keys = ArrayList<string>.init(this.allocator);
        let values = ArrayList<JsonValue>.init(this.allocator);
        try this.skip();
        if (this.peek() != '}') {
            while (true) {
                try this.skip();
                if (this.peek() != '"') throw this.fail("expected a member name in quotes");
                try keys.append(try this.string());
                try this.skip();
                if (this.peek() != ':') throw this.fail("expected `:` after the member name");
                this.pos++;
                try values.append(try this.value());
                if (!try this.separator('}')) break;
            }
        }
        this.pos++;
        v.keys = keys.items;
        v.items = values.items;
    }
}

/**
 * Parses JSON, or JSONC when comments are on.
 *
 * @param allocator - The allocator that every string, array, and object of the result comes from
 * @param text - The text to parse
 * @param options - Whether to accept comments and trailing commas
 * @param problem - Receives the message and the byte offset of a syntax error
 * @returns The value that the text holds
 * @throws JsonError.Syntax - When the text breaks the grammar or holds more than one value
 * @throws JsonError.TooDeep - When arrays and objects nest more than 256 deep
 *
 * @remarks
 * The result holds many separate allocations, so pass an arena and free them all at once with its `deinit`.
 * Each value records where it is in the text (`start`, `end`),
 * so a tool can change one part of a file and leave the comments, order, and spacing of the rest as they were.
 * Whitespace and, with comments on, comments may surround the value, and anything else after it is an error.
 *
 * @example
 * ```hx
 * let arena = ArenaAllocator.init(cAllocator());
 * defer arena.deinit();
 * let problem = JsonProblem { message: "", at: 0 };
 * const doc = parseJson(arena.allocator(), text, JsonOptions { comments: true }, &problem) catch {
 *     const where = lineCol(text, problem.at);
 *     eprintln(`config.json:${where.line}:${where.col}: ${problem.message}`);
 *     return;
 * };
 * const name = doc.get("name")?.text ?? "unnamed"; // "hx"
 * ```
 *
 * @since 1.0.0
 */

export function parseJson(allocator: dyn Allocator, text: string, options: JsonOptions, problem: *JsonProblem): JsonValue | Error {
    let r = Reader { text, pos: 0, allocator, comments: options.comments, problem, depth: 0 };
    const v = try r.value();
    try r.skip();
    if (r.pos < text.len) throw r.fail("expected the end after the value");
    return v;
}

/**
 * Writes a string as a JSON string literal.
 *
 * @param w - The writer that receives the literal
 * @param text - The string to write
 * @returns Nothing, or the error of the writer
 * @throws Error - When the writer fails
 *
 * @remarks
 * It adds the quotes and escapes `"`, `\`, and every byte below 0x20.
 * A line feed, a tab, and a carriage return get their short escapes, and other control bytes get `\u00XX`.
 * Every other byte passes through unchanged, so UTF-8 stays as it is.
 * It writes the unescaped runs as whole slices, so the writer sees few calls.
 *
 * @example
 * ```hx
 * try writeJsonString(stdout(), "say \"hi\"\n"); // prints "say \"hi\"\n"
 * ```
 *
 * @since 1.0.0
 */

export function writeJsonString(w: dyn Writer, text: string): void | Error {
    const digits = "0123456789abcdef";
    try w.write("\"");
    let start: usize = 0;
    for (const c, i of text) {
        if (c != '"' && c != '\\' && c >= 0x20) continue;
        try w.write(text[start..i]);
        start = i + 1;
        if (c == '"') try w.write("\\\"");
        else if (c == '\\') try w.write("\\\\");
        else if (c == '\n') try w.write("\\n");
        else if (c == '\t') try w.write("\\t");
        else if (c == '\r') try w.write("\\r");
        else {
            const escape: u8[6] = ['\\', 'u', '0', '0', digits[c >> 4], digits[c & 15]];
            try w.write(&escape);
        }
    }
    try w.write(text[start..]);
    try w.write("\"");
}
