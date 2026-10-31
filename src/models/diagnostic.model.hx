/**
 * Imports
 */

import * as fmt from "std/fmt";
import { cAllocator, free as freeItems } from "std";
import { DiagError } from "@constants/diagnostic.constant";
import { HxSource } from "@models/structs/source-model.struct";
import { hxVecGrowImpl, free } from "@components/memory.component";
import { hxArenaStrndup, hxArenaFree } from "@services/arena.service";
import { HxDiag, HxDiagList } from "@models/structs/diagnostic-model.struct";

/**
 * Adds a diagnostic to a list.
 *
 * @param list - The list to add to
 * @param level - The level, one of {@link DiagError}, {@link DiagWarning}, or {@link DiagNote}
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
 * ```hx
 * const diag = emit(&diags, DiagError, &src, 40, 7, "unterminated string literal"); // 0
 * hint(&diags, diag, "close it with `\"`");
 * ```
 *
 * @see emitf
 * @since 1.0.0
 */

export function emit(list: *HxDiagList, level: i32, src: ?readonly *HxSource, start: u32, len: u32, message: string): u32 {
    const text = hxArenaStrndup(&list.arena, message.ptr, message.len);
    if (list.itemsLen == list.itemsCap) {
        unsafe {
            hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.itemsCap, list.itemsLen + 1, @sizeOf(HxDiag));
        }
    }
    unsafe {
        list.items![list.itemsLen] = HxDiag { level, src, start, len, message: text, hint: null };
    }
    list.itemsLen += 1;
    if (level == DiagError) list.errorCount += 1;
    return list.itemsLen - 1;
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
 * ```hx
 * hint(&diags, diag, "close it with `\"`");
 * // = hint: close it with `"`
 * ```
 *
 * @see hintf
 * @since 1.0.0
 */

export function hint(list: *HxDiagList, index: u32, message: string): void {
    const text = hxArenaStrndup(&list.arena, message.ptr, message.len);
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
 * ```hx
 * hxDiagListFree(&diags);
 * diags.itemsLen;   // 0
 * diags.errorCount; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxDiagListFree(list: *HxDiagList): void {
    unsafe {
        free(@ptrCast(?u8[*], list.items));
    }
    list.items = null;
    list.itemsLen = 0;
    list.itemsCap = 0;
    hxArenaFree(&list.arena);
    list.errorCount = 0;
}

/**
 * Adds a diagnostic whose message is a template.
 *
 * @param list - The list to add to
 * @param level - The level, one of {@link DiagError}, {@link DiagWarning}, or {@link DiagNote}
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
 * ```hx
 * emitf(&diags, DiagError, &src, at, 1, `expected ${what}`);
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
 * @remarks
 * Choose it over {@link hint} when the hint embeds a value.
 * The formatted text lives only for the call, since {@link hint} copies it into the arena of the list.
 * When the template cannot be formatted for lack of memory, the diagnostic gets an empty hint.
 *
 * @example
 * ```hx
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
