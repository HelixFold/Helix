/**
 * One parsed JSON value, together with the span of text that it came from.
 *
 * @remarks
 * The `kind` field decides which of the other fields mean something.
 * Every value keeps its byte span in the text,
 * so a tool can change one part of a file and leave the comments, the order, and the spacing of the rest alone.
 * Strings, arrays, and keys come from the C heap, so release a parsed tree with {@link hx_json_free}.
 *
 * @example
 * ```ts
 * // { "a": [1, true] }
 * // kind: JSON_OBJECT, count: 1, keys: [ 'a' ], start: 0, end: 18
 * // items[0]: kind JSON_ARRAY, count: 2, start: 7, end: 16
 * ```
 *
 * @see hx_json_parse
 * @since 1.0.0
 */

export extern "C" struct HxJson {
    /**
     * The kind of the value, one of the `JSON_` constants.
     *
     * @example
     * ```ts
     * value.kind; // JSON_NUMBER for 1.5
     * ```
     *
     * @see JSON_OBJECT
     * @since 1.0.0
     */

    kind: u8,

    /**
     * The value of a boolean.
     *
     * @example
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
     * value.key_starts![0]; // 2 for { "a": 1 }
     * ```
     *
     * @since 1.0.0
     */

    key_starts: ?u32[*],
}

/**
 * The state of one run of the JSON reader.
 *
 * @remarks
 * Only the first failure is recorded, so later checks after a failure leave the message alone.
 */

export struct Reader {
    /**
     * The whole text being parsed.
     */

    text: readonly u8[],

    /**
     * The offset of the next byte to read.
     */

    pos: usize,

    /**
     * The buffer that receives the NUL-terminated message of the first failure.
     */

    error: u8[],

    /**
     * The variable that receives the offset of the first failure.
     */

    error_offset: *u32,

    /**
     * Whether a failure has been recorded.
     */

    failed: bool,

    /**
     * The number of arrays and objects that enclose the current value.
     */

    depth: u32,
}
