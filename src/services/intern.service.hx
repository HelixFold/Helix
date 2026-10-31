/**
 * Imports
 */

import { HxInternEntry, HxInterner } from "@services/structs/intern-service.struct";
import { hx_alloc, hx_zalloc, hx_realloc, free } from "@components/memory.component";

/**
 * Hashes a text with 32-bit FNV-1a.
 *
 * @param text - The bytes to hash
 * @returns The hash, which is 2166136261 for an empty text
 */

function hashText(text: readonly u8[]): u32 {
    let hash: u32 = 2166136261;
    for (const b of text) {
        hash ^= b as u32;
        hash *%= 16777619;
    }
    return hash;
}

/**
 * Prepares an interner for use.
 *
 * @param interner - The interner to set up, whose previous contents are ignored
 *
 * @remarks
 * It starts with room for 512 entries and a table of 1024 slots, and both grow on demand.
 * Release it with {@link hx_interner_free}.
 *
 * @example
 * ```ts
 * let interner: HxInterner = undefined;
 * hx_interner_init(&interner);
 * interner.count; // 1 - id 0 is reserved
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_interner_init(interner: *HxInterner): void {
    unsafe {
        interner.slots = @ptrCast(u32[*], hx_zalloc(1024 * 4));
        interner.entries = @ptrCast(HxInternEntry[*], hx_alloc(512 * 12));
        interner.entries[0] = HxInternEntry { hash: 0, start: 0, len: 0 };
    }
    interner.chars = null;
    interner.chars_len = 0;
    interner.chars_cap = 0;
    interner.count = 1;
    interner.entries_cap = 512;
    interner.slots_cap = 1024;
}

/**
 * Releases the memory of an interner.
 *
 * @param interner - The interner to release
 *
 * @remarks
 * Every id it handed out stops meaning anything, and the interner needs {@link hx_interner_init} before reuse.
 *
 * @example
 * ```ts
 * hx_interner_free(&interner);
 * interner.count; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_interner_free(interner: *HxInterner): void {
    unsafe {
        free(interner.chars);
        free(@ptrCast(u8[*], interner.entries));
        free(@ptrCast(u8[*], interner.slots));
    }
    interner.chars = null;
    interner.chars_len = 0;
    interner.chars_cap = 0;
    interner.count = 0;
    interner.entries_cap = 0;
    interner.slots_cap = 0;
}

/**
 * Doubles the hash table of an interner and places every id again.
 *
 * @param interner - The interner whose table to grow
 *
 * @remarks
 * The ids and the entries stay as they are, and only their slots move.
 */

function rehash(interner: *HxInterner): void {
    const cap = interner.slots_cap * 2;
    unsafe {
        const slots = @ptrCast(u32[*], hx_zalloc((cap as usize) * 4));
        for (const id of 1..interner.count) {
            let slot = interner.entries[id].hash & (cap - 1);
            while (slots[slot] != 0) slot = (slot + 1) & (cap - 1);
            slots[slot] = id;
        }
        free(@ptrCast(u8[*], interner.slots));
        interner.slots = slots;
    }
    interner.slots_cap = cap;
}

/**
 * Returns the id of a text, handing out a new one the first time the text arrives.
 *
 * @param interner - The interner to look the text up in
 * @param text_ptr - The first byte of the text
 * @param len - The length of the text in bytes
 * @returns The id of the text, which is never 0
 *
 * @remarks
 * Equal texts always get the same id, so two names are equal exactly when their ids are.
 * The interner copies the text, so the caller may release its own copy afterwards.
 * An empty text is a valid string of its own and gets an id like any other.
 *
 * @example
 * ```ts
 * hx_intern(&interner, "main", 4); // 1
 * hx_intern(&interner, "add", 3);  // 2
 * hx_intern(&interner, "main", 4); // 1
 * ```
 *
 * @see hx_name_text
 * @since 1.0.0
 */

export extern "C" function hx_intern(interner: *HxInterner, text_ptr: readonly u8[*], len: u32): u32 {
    let text: readonly u8[] = [];
    unsafe {
        if (len > 0) text = text_ptr[0..len];
        const hash = hashText(text);
        let slot = hash & (interner.slots_cap - 1);
        while (interner.slots[slot] != 0) {
            const id = interner.slots[slot];
            const entry = interner.entries[id];
            if (entry.hash == hash && entry.len == len) {
                let same = true;
                for (const i of 0..len) {
                    if (interner.chars![entry.start + i] != text[i]) {
                        same = false;
                        break;
                    }
                }
                if (same) return id;
            }
            slot = (slot + 1) & (interner.slots_cap - 1);
        }

        if (interner.chars_len + len > interner.chars_cap) {
            let cap = interner.chars_cap != 0 ? interner.chars_cap * 2 : 4096;
            while (cap < interner.chars_len + len) cap *= 2;
            interner.chars = hx_realloc(interner.chars, cap as usize);
            interner.chars_cap = cap;
        }
        if (len > 0) {
            const chars = interner.chars!;
            for (const i of 0..len) chars[interner.chars_len + i] = text[i];
        }

        if (interner.count == interner.entries_cap) {
            interner.entries_cap *= 2;
            interner.entries = @ptrCast(HxInternEntry[*], hx_realloc(@ptrCast(u8[*], interner.entries), (interner.entries_cap as usize) * 12));
        }
        const id = interner.count;
        interner.count += 1;
        interner.entries[id] = HxInternEntry { hash, start: interner.chars_len, len };
        interner.chars_len += len;
        interner.slots[slot] = id;
    }
    if (interner.count * 2 > interner.slots_cap) rehash(interner);
    return interner.count - 1;
}

/**
 * Returns the text of an id.
 *
 * @param interner - The interner that handed out the id
 * @param name - The id to look up
 * @param len - The variable that receives the length of the text in bytes
 * @returns The first byte of the text, or `null` while the interner holds no text at all
 *
 * @remarks
 * The text is not NUL-terminated, so read exactly the length written to `len`.
 * The pointer stays valid only until the next {@link hx_intern} call, which may move the character buffer.
 *
 * @example
 * ```ts
 * const id = hx_intern(&interner, "main", 4);
 * let len: u32 = 0;
 * const text = hx_name_text(&interner, id, &len); // 'main', len: 4
 * ```
 *
 * @see hx_intern
 * @since 1.0.0
 */

export extern "C" function hx_name_text(interner: readonly *HxInterner, name: u32, len: *u32): ?readonly u8[*] {
    unsafe {
        const entry = interner.entries[name];
        *len = entry.len;
        if (const chars = interner.chars) return @ptrFromInt(u8[*], @intFromPtr(chars) + (entry.start as usize));
        return null;
    }
}
