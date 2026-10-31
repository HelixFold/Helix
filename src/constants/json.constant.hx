/**
 * Imports
 */

import { HxJson } from "@components/structs/json-component.struct";

/**
 * The kind of a JSON `null`.
 *
 * @example
 * ```ts
 * value.kind == JSON_NULL; // true for null
 * ```
 *
 * @since 1.0.0
 */

export const JSON_NULL: u8 = 0;

/**
 * The kind of a JSON `true` or `false`, whose value is in the `boolean` field.
 *
 * @example
 * ```ts
 * value.kind == JSON_BOOL; // true for false
 * ```
 *
 * @since 1.0.0
 */

export const JSON_BOOL: u8 = 1;

/**
 * The kind of a JSON number, whose value is in the `number` field.
 *
 * @example
 * ```ts
 * value.kind == JSON_NUMBER; // true for -2.5e3
 * ```
 *
 * @since 1.0.0
 */

export const JSON_NUMBER: u8 = 2;

/**
 * The kind of a JSON string, whose decoded text is in the `string` field.
 *
 * @example
 * ```ts
 * value.kind == JSON_STRING; // true for "app"
 * ```
 *
 * @since 1.0.0
 */

export const JSON_STRING: u8 = 3;

/**
 * The kind of a JSON array, whose elements are in the `items` field.
 *
 * @example
 * ```ts
 * value.kind == JSON_ARRAY; // true for [1, 2]
 * ```
 *
 * @since 1.0.0
 */

export const JSON_ARRAY: u8 = 4;

/**
 * The kind of a JSON object, whose keys and values are in the `keys` and `items` fields.
 *
 * @example
 * ```ts
 * value.kind == JSON_OBJECT; // true for { "a": 1 }
 * ```
 *
 * @since 1.0.0
 */

export const JSON_OBJECT: u8 = 5;

/**
 * The deepest that arrays and objects may nest before the reader gives up.
 *
 * @remarks
 * The limit keeps a hostile file from exhausting the stack of the recursive reader.
 *
 * @example
 * ```ts
 * MAX_JSON_DEPTH; // 256
 * ```
 *
 * @since 1.0.0
 */

export const MAX_JSON_DEPTH: u32 = 256;

/**
 * A `null` value with no span, which the reader starts every value from.
 *
 * @example
 * ```ts
 * EMPTY_JSON.kind;  // JSON_NULL
 * EMPTY_JSON.count; // 0
 * ```
 *
 * @since 1.0.0
 */

export const EMPTY_JSON = HxJson {
    kind: 0, boolean: false, number: 0, string: null, start: 0, end: 0, count: 0, items: null, keys: null, key_starts: null,
};
