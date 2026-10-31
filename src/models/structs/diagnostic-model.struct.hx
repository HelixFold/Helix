/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";

/**
 * One error, warning, or note, with the span of source that it points at.
 *
 * @remarks
 * The message and the hint live in the arena of the list that holds the diagnostic,
 * so they stay valid until that list is released.
 * A diagnostic without a source has no position, so the printer shows no location for it.
 *
 * @example
 * ```hx
 * // error: unterminated string literal
 * //  --> src/main.hx:3:15
 * // { level: DiagError, start: 40, len: 7, message: 'unterminated string literal', hint: 'close it with `"`' }
 * ```
 *
 * @see HxDiagList
 * @since 1.0.0
 */

export extern "C" struct HxDiag {
    /**
     * The level, one of {@link DiagError}, {@link DiagWarning}, or {@link DiagNote}.
     *
     * @example
     * ```hx
     * diag.level; // DiagError
     * ```
     *
     * @since 1.0.0
     */

    level: i32,

    /**
     * The source that the span points into, or `null` for a diagnostic without a location.
     *
     * @example
     * ```hx
     * diag.src; // null for a problem with the command line
     * ```
     *
     * @since 1.0.0
     */

    src: ?readonly *HxSource,

    /**
     * The offset of the first byte of the span.
     *
     * @example
     * ```hx
     * diag.start; // 40
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The length of the span in bytes.
     *
     * @remarks
     * A length of 0 still prints a single caret.
     *
     * @example
     * ```hx
     * diag.len; // 7
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The NUL-terminated message, which lives in the arena of the list.
     *
     * @example
     * ```hx
     * diag.message; // 'unterminated string literal'
     * ```
     *
     * @since 1.0.0
     */

    message: readonly u8[*],

    /**
     * The NUL-terminated hint, usually the fix, or `null` when there is none.
     *
     * @example
     * ```hx
     * diag.hint; // 'close it with `"`'
     * ```
     *
     * @since 1.0.0
     */

    hint: ?readonly u8[*],
}

/**
 * The diagnostics of one compilation, in the order they were reported.
 *
 * @remarks
 * Every message and hint lives in the arena of the list, so the caller may release its own text after each call.
 * Start it zeroed, and release it with {@link hxDiagListFree}.
 *
 * @example
 * ```hx
 * let diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
 * emit(&diags, DiagError, &src, 4, 1, "unexpected character");
 * hxDiagRender(&diags, stderr, true);
 * hxDiagListFree(&diags);
 * ```
 *
 * @see emit
 * @see hxDiagRender
 *
 * @since 1.0.0
 */

export extern "C" struct HxDiagList {
    /**
     * The diagnostics, oldest first.
     *
     * @example
     * ```hx
     * diags.items![0]; // the first diagnostic reported
     * ```
     *
     * @since 1.0.0
     */

    items: ?HxDiag[*],

    /**
     * The number of diagnostics in the list.
     *
     * @example
     * ```hx
     * diags.itemsLen; // 2
     * ```
     *
     * @since 1.0.0
     */

    itemsLen: u32,

    /**
     * The capacity of the diagnostic array.
     *
     * @example
     * ```hx
     * diags.itemsCap; // 8 after the first diagnostic
     * ```
     *
     * @since 1.0.0
     */

    itemsCap: u32,

    /**
     * The arena that holds every message and hint.
     *
     * @example
     * ```hx
     * diags.arena.head; // null before the first diagnostic
     * ```
     *
     * @since 1.0.0
     */

    arena: HxArena,

    /**
     * The number of diagnostics at the error level.
     *
     * @remarks
     * A pass compares it before and after its run to learn whether it reported an error.
     *
     * @example
     * ```hx
     * diags.errorCount; // 1 after one error and one warning
     * ```
     *
     * @since 1.0.0
     */

    errorCount: u32,
}
