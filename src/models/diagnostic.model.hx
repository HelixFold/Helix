/**
 * Imports
 */

import { cAllocator, free as freeItems } from "std";
import * as fmt from "std/fmt";
import { DIAG_ERROR } from "@constants/diagnostic.constant";
import { HxSource } from "@models/structs/source-model.struct";
import { hx_vec_grow_impl, free } from "@components/memory.component";
import { hx_arena_strndup, hx_arena_free } from "@services/arena.service";
import { HxDiag, HxDiagList } from "@models/structs/diagnostic-model.struct";

/**
 * Adds a diagnostic to a list.
 *
 * @param list - The list to add to
 * @param level - The level, one of {@link DIAG_ERROR}, {@link DIAG_WARNING}, or {@link DIAG_NOTE}
 * @param src - The source that the span points into, or `null` for a diagnostic without a location
 * @param start - The offset of the first byte of the span
 * @param len - The length of the span in bytes
 * @param message - The message, which the list copies
 * @returns The index of the new diagnostic, which stays valid for {@link hint}
 *
 * @remarks
 * An error also raises the error count of the list.
 *
 * @example
 * ```ts
 * const diag = emit(&diags, DIAG_ERROR, &src, 40, 7, "unterminated string literal"); // 0
 * hint(&diags, diag, "close it with `\"`");
 * ```
 *
 * @see emitf
 * @since 1.0.0
 */

export function emit(list: *HxDiagList, level: i32, src: ?readonly *HxSource, start: u32, len: u32, message: string): u32 {
    const text = hx_arena_strndup(&list.arena, message.ptr, message.len);
    if (list.items_len == list.items_cap) {
        unsafe {
            hx_vec_grow_impl(@ptrCast(*?u8[*], &list.items), &list.items_cap, list.items_len + 1, @sizeOf(HxDiag));
        }
    }
    unsafe {
        list.items![list.items_len] = HxDiag { level, src, start, len, message: text, hint: null };
    }
    list.items_len += 1;
    if (level == DIAG_ERROR) list.error_count += 1;
    return list.items_len - 1;
}

/**
 * Attaches a hint line to a diagnostic, which is usually the fix.
 *
 * @param list - The list that holds the diagnostic
 * @param index - The index that {@link emit} returned
 * @param message - The hint, which the list copies
 *
 * @remarks
 * A second hint on the same diagnostic replaces the first.
 *
 * @example
 * ```ts
 * hint(&diags, diag, "close it with `\"`");
 * // = hint: close it with `"`
 * ```
 *
 * @see hintf
 * @since 1.0.0
 */

export function hint(list: *HxDiagList, index: u32, message: string): void {
    const text = hx_arena_strndup(&list.arena, message.ptr, message.len);
    unsafe {
        list.items![index].hint = text;
    }
}

/**
 * Releases a list together with every message and hint in it.
 *
 * @param list - The list to release
 *
 * @remarks
 * The list is left empty and can collect new diagnostics afterwards.
 *
 * @example
 * ```ts
 * hx_diag_list_free(&diags);
 * diags.items_len;   // 0
 * diags.error_count; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_diag_list_free(list: *HxDiagList): void {
    unsafe {
        free(@ptrCast(?u8[*], list.items));
    }
    list.items = null;
    list.items_len = 0;
    list.items_cap = 0;
    hx_arena_free(&list.arena);
    list.error_count = 0;
}

/**
 * Adds a diagnostic whose message is a template.
 *
 * @param list - The list to add to
 * @param level - The level, one of {@link DIAG_ERROR}, {@link DIAG_WARNING}, or {@link DIAG_NOTE}
 * @param src - The source that the span points into, or `null` for a diagnostic without a location
 * @param start - The offset of the first byte of the span
 * @param len - The length of the span in bytes
 * @param message - The template that gives the message
 * @returns The index of the new diagnostic
 *
 * @remarks
 * Choose it over {@link emit} when the message embeds a value.
 * When the template cannot be formatted for lack of memory, the diagnostic is still added with an empty message.
 *
 * @example
 * ```ts
 * emitf(&diags, DIAG_ERROR, &src, at, 1, `expected ${what}`);
 * ```
 *
 * @see emit
 * @since 1.0.0
 */

export function emitf(list: *HxDiagList, level: i32, src: ?readonly *HxSource, start: u32, len: u32, message: Format): u32 {
    const a = cAllocator();
    const text = fmt.alloc(a, message) catch [];
    const index = emit(list, level, src, start, len, text);
    if (text.len > 0) freeItems(a, text);
    return index;
}

/**
 * Attaches a hint line whose text is a template.
 *
 * @param list - The list that holds the diagnostic
 * @param index - The index that {@link emit} or {@link emitf} returned
 * @param message - The template that gives the hint
 *
 * @example
 * ```ts
 * hintf(&diags, diag, `write \`${name} { ... }\``);
 * ```
 *
 * @see hint
 * @since 1.0.0
 */

export function hintf(list: *HxDiagList, index: u32, message: Format): void {
    const a = cAllocator();
    const text = fmt.alloc(a, message) catch [];
    hint(list, index, text);
    if (text.len > 0) freeItems(a, text);
}
