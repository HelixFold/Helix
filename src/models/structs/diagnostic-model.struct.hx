/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";

/**
 * One error, warning, or note, with the span of source that it points at.
 *
 * @example
 * ```ts
 * // error: unterminated string literal
 * //  --> src/main.hx:3:15
 * // { level: DIAG_ERROR, start: 40, len: 7, message: 'unterminated string literal', hint: 'close it with `"`' }
 * ```
 *
 * @see HxDiagList
 * @since 1.0.0
 */

export extern "C" struct HxDiag {
    /**
     * The level, one of {@link DIAG_ERROR}, {@link DIAG_WARNING}, or {@link DIAG_NOTE}.
     *
     * @example
     * ```ts
     * diag.level; // DIAG_ERROR
     * ```
     *
     * @since 1.0.0
     */

    level: i32,

    /**
     * The source that the span points into, or `null` for a diagnostic without a location.
     *
     * @example
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
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
 * Start it zeroed, and release it with {@link hx_diag_list_free}.
 *
 * @example
 * ```ts
 * let diags = HxDiagList { items: null, items_len: 0, items_cap: 0, arena: HxArena { head: null }, error_count: 0 };
 * emit(&diags, DIAG_ERROR, &src, 4, 1, "unexpected character");
 * hx_diag_render(&diags, stderr, true);
 * hx_diag_list_free(&diags);
 * ```
 *
 * @see emit
 * @see hx_diag_render
 *
 * @since 1.0.0
 */

export extern "C" struct HxDiagList {
    /**
     * The diagnostics, oldest first.
     *
     * @example
     * ```ts
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
     * ```ts
     * diags.items_len; // 2
     * ```
     *
     * @since 1.0.0
     */

    items_len: u32,

    /**
     * The capacity of the diagnostic array.
     *
     * @example
     * ```ts
     * diags.items_cap; // 8 after the first diagnostic
     * ```
     *
     * @since 1.0.0
     */

    items_cap: u32,

    /**
     * The arena that holds every message and hint.
     *
     * @example
     * ```ts
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
     * ```ts
     * diags.error_count; // 1 after one error and one warning
     * ```
     *
     * @since 1.0.0
     */

    error_count: u32,
}
