/**
 * Imports
 */

import { HxJson } from "@components/structs/json-component.struct";

/**
 * The kind of a JSON `null`.
 *
 * @example
 * ```hx
 * value.kind == JsonNull; // true for null
 * ```
 *
 * @since 1.0.0
 */

export const JsonNull: u8 = 0;

/**
 * The kind of a JSON `true` or `false`, whose value is in the `boolean` field.
 *
 * @example
 * ```hx
 * value.kind == JsonBool; // true for false
 * ```
 *
 * @since 1.0.0
 */

export const JsonBool: u8 = 1;

/**
 * The kind of a JSON number, whose value is in the `number` field.
 *
 * @example
 * ```hx
 * value.kind == JsonNumber; // true for -2.5e3
 * ```
 *
 * @since 1.0.0
 */

export const JsonNumber: u8 = 2;

/**
 * The kind of a JSON string, whose decoded text is in the `string` field.
 *
 * @example
 * ```hx
 * value.kind == JsonString; // true for "app"
 * ```
 *
 * @since 1.0.0
 */

export const JsonString: u8 = 3;

/**
 * The kind of a JSON array, whose elements are in the `items` field.
 *
 * @example
 * ```hx
 * value.kind == JsonArray; // true for [1, 2]
 * ```
 *
 * @since 1.0.0
 */

export const JsonArray: u8 = 4;

/**
 * The kind of a JSON object, whose keys and values are in the `keys` and `items` fields.
 *
 * @example
 * ```hx
 * value.kind == JsonObject; // true for { "a": 1 }
 * ```
 *
 * @since 1.0.0
 */

export const JsonObject: u8 = 5;

/**
 * The deepest that arrays and objects may nest before the reader gives up.
 *
 * @remarks
 * The limit keeps a hostile file from exhausting the stack of the recursive reader.
 *
 * @example
 * ```hx
 * MaxJsonDepth; // 256
 * ```
 *
 * @since 1.0.0
 */

export const MaxJsonDepth: u32 = 256;

/**
 * A `null` value with no span, which the reader starts every value from.
 *
 * @example
 * ```hx
 * EmptyJson.kind;  // JsonNull
 * EmptyJson.count; // 0
 * ```
 *
 * @since 1.0.0
 */

export const EmptyJson = HxJson {
    kind: 0, boolean: false, number: 0, string: null, start: 0, end: 0, count: 0, items: null, keys: null, keyStarts: null,
};
