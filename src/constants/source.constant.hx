/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";

/**
 * A source buffer that holds no files.
 *
 * @example
 * ```ts
 * let src = EMPTY_SOURCE;
 * src.file_count; // 0
 * ```
 *
 * @since 1.0.0
 */

export const EMPTY_SOURCE = HxSource {
    text: null, len: 0, cap: 0, line_starts: null, line_count: 0, line_cap: 0, files: null, file_count: 0, file_cap: 0,
};

/**
 * The file index that {@link hx_source_add_file} returns when it cannot add a file.
 *
 * @example
 * ```ts
 * hx_source_add_file(&src, "missing.hx", &error) == NO_FILE; // true
 * ```
 *
 * @since 1.0.0
 */

export const NO_FILE: u32 = 0xFFFF_FFFF;
