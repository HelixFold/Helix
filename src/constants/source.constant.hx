/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";

/**
 * A source buffer that holds no files.
 *
 * @example
 * ```hx
 * let src = EmptySource;
 * src.fileCount; // 0
 * ```
 *
 * @since 1.0.0
 */

export const EmptySource = HxSource {
    text: null, len: 0, cap: 0, lineStarts: null, lineCount: 0, lineCap: 0, files: null, fileCount: 0, fileCap: 0,
};

/**
 * The file index that {@link hxSourceAddFile} returns when it cannot add a file.
 *
 * @example
 * ```hx
 * hxSourceAddFile(&src, "missing.hx", &error) == NoFile; // true
 * ```
 *
 * @since 1.0.0
 */

export const NoFile: u32 = 0xFFFF_FFFF;
