/**
 * Imports
 */

import { hxAlloc, hxZalloc, hxRealloc, free } from "@components/memory.component";
import { HxInternEntry, HxInterner } from "@services/structs/intern-service.struct";

/**
 * Hashes a text with 32-bit FNV-1a.
 *
 * @param text - The bytes to hash
 * @returns The hash, which is 2166136261 for an empty text
 *
 * @remarks
 * FNV-1a is short and spreads identifier names well enough for the interner's open-addressed table.
 * The multiply wraps on overflow by design.
 *
 * @since 1.0.0
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
 * Release it with {@link hxInternerFree}.
 *
 * @example
 * ```hx
 * let interner: HxInterner = undefined;
 * hxInternerInit(&interner);
 * interner.count; // 1 - id 0 is reserved
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxInternerInit(interner: *HxInterner): void {
    unsafe {
        interner.slots = @ptrCast(u32[*], hxZalloc(1024 * 4));
        interner.entries = @ptrCast(HxInternEntry[*], hxAlloc(512 * 12));
        interner.entries[0] = HxInternEntry { hash: 0, start: 0, len: 0 };
    }
    interner.chars = null;
    interner.charsLen = 0;
    interner.charsCap = 0;
    interner.count = 1;
    interner.entriesCap = 512;
    interner.slotsCap = 1024;
}

/**
 * Releases the memory of an interner.
 *
 * @param interner - The interner to release
 *
 * @remarks
 * Every id it handed out stops meaning anything, and the interner needs {@link hxInternerInit} before reuse.
 *
 * @example
 * ```hx
 * hxInternerFree(&interner);
 * interner.count; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxInternerFree(interner: *HxInterner): void {
    unsafe {
        free(interner.chars);
        free(@ptrCast(u8[*], interner.entries));
        free(@ptrCast(u8[*], interner.slots));
    }
    interner.chars = null;
    interner.charsLen = 0;
    interner.charsCap = 0;
    interner.count = 0;
    interner.entriesCap = 0;
    interner.slotsCap = 0;
}

/**
 * Doubles the hash table of an interner and places every id again.
 *
 * @param interner - The interner whose table to grow
 *
 * @remarks
 * The ids and the entries stay as they are, and only their slots move.
 *
 * @since 1.0.0
 */

function rehash(interner: *HxInterner): void {
    const cap = interner.slotsCap * 2;
    unsafe {
        const slots = @ptrCast(u32[*], hxZalloc((cap as usize) * 4));
        for (const id of 1..interner.count) {
            let slot = interner.entries[id].hash & (cap - 1);
            while (slots[slot] != 0) slot = (slot + 1) & (cap - 1);
            slots[slot] = id;
        }
        free(@ptrCast(u8[*], interner.slots));
        interner.slots = slots;
    }
    interner.slotsCap = cap;
}

/**
 * Returns the id of a text, handing out a new one the first time the text arrives.
 *
 * @param interner - The interner to look the text up in
 * @param textPtr - The first byte of the text
 * @param len - The length of the text in bytes
 * @returns The id of the text, which is never 0
 *
 * @remarks
 * Equal texts always get the same id, so two names are equal exactly when their ids are.
 * The interner copies the text, so the caller may release its own copy afterwards.
 * An empty text is a valid string of its own and gets an id like any other.
 *
 * @example
 * ```hx
 * hxIntern(&interner, "main", 4); // 1
 * hxIntern(&interner, "add", 3);  // 2
 * hxIntern(&interner, "main", 4); // 1
 * ```
 *
 * @see hxNameText
 * @since 1.0.0
 */

export extern "C" function hxIntern(interner: *HxInterner, textPtr: readonly u8[*], len: u32): u32 {
    let text: readonly u8[] = [];
    unsafe {
        if (len > 0) text = textPtr[0..len];
        const hash = hashText(text);
        let slot = hash & (interner.slotsCap - 1);
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
            slot = (slot + 1) & (interner.slotsCap - 1);
        }

        if (interner.charsLen + len > interner.charsCap) {
            let cap = interner.charsCap != 0 ? interner.charsCap * 2 : 4096;
            while (cap < interner.charsLen + len) cap *= 2;
            interner.chars = hxRealloc(interner.chars, cap as usize);
            interner.charsCap = cap;
        }
        if (len > 0) {
            const chars = interner.chars!;
            for (const i of 0..len) chars[interner.charsLen + i] = text[i];
        }

        if (interner.count == interner.entriesCap) {
            interner.entriesCap *= 2;
            interner.entries = @ptrCast(HxInternEntry[*], hxRealloc(@ptrCast(u8[*], interner.entries), (interner.entriesCap as usize) * 12));
        }
        const id = interner.count;
        interner.count += 1;
        interner.entries[id] = HxInternEntry { hash, start: interner.charsLen, len };
        interner.charsLen += len;
        interner.slots[slot] = id;
    }
    if (interner.count * 2 > interner.slotsCap) rehash(interner);
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
 * The pointer stays valid only until the next {@link hxIntern} call, which may move the character buffer.
 *
 * @example
 * ```hx
 * const id = hxIntern(&interner, "main", 4);
 * let len: u32 = 0;
 * const text = hxNameText(&interner, id, &len); // 'main', len: 4
 * ```
 *
 * @see hxIntern
 * @since 1.0.0
 */

export extern "C" function hxNameText(interner: readonly *HxInterner, name: u32, len: *u32): ?readonly u8[*] {
    unsafe {
        const entry = interner.entries[name];
        *len = entry.len;
        if (const chars = interner.chars) return @ptrFromInt(u8[*], @intFromPtr(chars) + (entry.start as usize));
        return null;
    }
}
