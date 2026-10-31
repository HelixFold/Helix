/**
 * One parsed JSON value, together with the span of text that it came from.
 *
 * @remarks
 * The `kind` field decides which of the other fields mean something.
 * Every value keeps its byte span in the text,
 * so a tool can change one part of a file and leave the comments, the order, and the spacing of the rest alone.
 * Strings, arrays, and keys come from the C heap, so release a parsed tree with {@link hxJsonFree}.
 *
 * @example
 * ```hx
 * // { "a": [1, true] }
 * // kind: JsonObject, count: 1, keys: [ 'a' ], start: 0, end: 18
 * // items[0]: kind JsonArray, count: 2, start: 7, end: 16
 * ```
 *
 * @see hxJsonParse
 * @since 1.0.0
 */

export extern "C" struct HxJson {
    /**
     * The kind of the value, one of the `Json` kind constants.
     *
     * @example
     * ```hx
     * value.kind; // JsonNumber for 1.5
     * ```
     *
     * @see JsonObject
     * @since 1.0.0
     */

    kind: u8,

    /**
     * The value of a boolean.
     *
     * @example
     * ```hx
     * value.boolean; // true for true
     * ```
     *
     * @since 1.0.0
     */

    boolean: bool,

    /**
     * The value of a number.
     *
     * @example
     * ```hx
     * value.number; // 1.5 for 1.5
     * ```
     *
     * @since 1.0.0
     */

    number: f64,

    /**
     * The decoded, NUL-terminated text of a string, with its escapes resolved.
     *
     * @example
     * ```hx
     * value.string; // 'a\nb' for the literal "a\\nb"
     * ```
     *
     * @since 1.0.0
     */

    string: ?u8[*],

    /**
     * The offset where the text of the value starts.
     *
     * @example
     * ```hx
     * value.start; // 7 for the array in { "a": [1, true] }
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The offset one past the last byte of the value.
     *
     * @example
     * ```hx
     * value.end; // 16 for the array in { "a": [1, true] }
     * ```
     *
     * @since 1.0.0
     */

    end: u32,

    /**
     * The number of elements of an array or members of an object.
     *
     * @example
     * ```hx
     * value.count; // 2 for [1, true]
     * ```
     *
     * @since 1.0.0
     */

    count: u32,

    /**
     * The elements of an array, or the member values of an object.
     *
     * @example
     * ```hx
     * value.items![0]; // the first element or member value
     * ```
     *
     * @since 1.0.0
     */

    items: ?HxJson[*],

    /**
     * The decoded, NUL-terminated keys of an object, in the same order as its values.
     *
     * @example
     * ```hx
     * value.keys![0]; // 'a'
     * ```
     *
     * @since 1.0.0
     */

    keys: ?(u8[*])[*],

    /**
     * The offset of the opening quote of each key of an object.
     *
     * @example
     * ```hx
     * value.keyStarts![0]; // 2 for { "a": 1 }
     * ```
     *
     * @since 1.0.0
     */

    keyStarts: ?u32[*],
}

/**
 * The state of one run of the JSON reader.
 *
 * @remarks
 * Only the first failure is recorded, so later checks after a failure leave the message alone.
 *
 * @example
 * ```hx
 * let r = Reader { text: "", pos: 0, error: [], errorOffset, failed: false, depth: 0 };
 * r.failed; // false until the first failure
 * ```
 *
 * @see hxJsonParse
 * @since 1.0.0
 */

export struct Reader {
    /**
     * The whole text being parsed.
     *
     * @example
     * ```hx
     * r.text; // '{ "a": 1 }'
     * ```
     *
     * @since 1.0.0
     */

    text: readonly u8[],

    /**
     * The offset of the next byte to read.
     *
     * @example
     * ```hx
     * r.pos; // 2 at the key of { "a": 1 }
     * ```
     *
     * @since 1.0.0
     */

    pos: usize,

    /**
     * The buffer that receives the NUL-terminated message of the first failure.
     *
     * @example
     * ```hx
     * r.error; // 'expected a value' after reading [1, x]
     * ```
     *
     * @since 1.0.0
     */

    error: u8[],

    /**
     * The variable that receives the offset of the first failure.
     *
     * @example
     * ```hx
     * *r.errorOffset; // 4 after reading [1, x]
     * ```
     *
     * @since 1.0.0
     */

    errorOffset: *u32,

    /**
     * Whether a failure has been recorded.
     *
     * @example
     * ```hx
     * r.failed; // true once fail has run
     * ```
     *
     * @since 1.0.0
     */

    failed: bool,

    /**
     * The nesting depth of the value being read, which is 1 for the top-level value.
     *
     * @example
     * ```hx
     * r.depth; // 2 while reading the 1 in [1]
     * ```
     *
     * @since 1.0.0
     */

    depth: u32,
}
