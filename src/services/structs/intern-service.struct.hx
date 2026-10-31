/**
 * The record that an interner keeps for one distinct string.
 *
 * @remarks
 * The text itself lives in the shared character buffer of the interner, at `start` for `len` bytes.
 *
 * @example
 * ```hx
 * // after interning 'main' and then 'add'
 * // entries[1]: { hash, start: 0, len: 4 }   main
 * // entries[2]: { hash, start: 4, len: 3 }   add
 * ```
 *
 * @see HxInterner
 * @since 1.0.0
 */

export extern "C" struct HxInternEntry {
    /**
     * The FNV-1a hash of the text.
     *
     * @remarks
     * A lookup compares the hash and the length first, so most mismatches never compare the bytes.
     *
     * @example
     * ```hx
     * entry.hash; // 2166136261 for the empty string
     * ```
     *
     * @since 1.0.0
     */

    hash: u32,

    /**
     * The offset of the text in the character buffer.
     *
     * @example
     * ```hx
     * entry.start; // 4
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The length of the text in bytes.
     *
     * @example
     * ```hx
     * entry.len; // 3
     * ```
     *
     * @since 1.0.0
     */

    len: u32,
}

/**
 * A string interner that maps each distinct string to a small dense id.
 *
 * @remarks
 * Names then compare with `==` on their ids and can index arrays directly.
 * Id 0 means that there is no name, so the first string gets id 1.
 * Ids are handed out in the order that strings first arrive, and the text of each one is stored once.
 *
 * @example
 * ```hx
 * let interner: HxInterner = undefined;
 * hxInternerInit(&interner);
 * hxIntern(&interner, "main", 4); // 1
 * hxIntern(&interner, "add", 3);  // 2
 * hxIntern(&interner, "main", 4); // 1 - the same text, the same id
 * hxInternerFree(&interner);
 * ```
 *
 * @see hxIntern
 * @see hxNameText
 *
 * @since 1.0.0
 */

export extern "C" struct HxInterner {
    /**
     * The text of every interned string, one after another without separators.
     *
     * @example
     * ```hx
     * // after 'main' and 'add': main add
     * ```
     *
     * @since 1.0.0
     */

    chars: ?u8[*],

    /**
     * The number of bytes of the character buffer in use.
     *
     * @example
     * ```hx
     * interner.charsLen; // 7 after 'main' and 'add'
     * ```
     *
     * @since 1.0.0
     */

    charsLen: u32,

    /**
     * The capacity in bytes of the character buffer.
     *
     * @example
     * ```hx
     * interner.charsCap; // 4096 after the first string
     * ```
     *
     * @since 1.0.0
     */

    charsCap: u32,

    /**
     * The entry of each id, where entry 0 is unused.
     *
     * @example
     * ```hx
     * interner.entries[1]; // { hash, start: 0, len: 4 }
     * ```
     *
     * @since 1.0.0
     */

    entries: HxInternEntry[*],

    /**
     * The number of ids handed out, counting the unused id 0.
     *
     * @remarks
     * The next string that arrives gets this value as its id.
     *
     * @example
     * ```hx
     * interner.count; // 3 after 'main' and 'add'
     * ```
     *
     * @since 1.0.0
     */

    count: u32,

    /**
     * The capacity of the entry array.
     *
     * @example
     * ```hx
     * interner.entriesCap; // 512
     * ```
     *
     * @since 1.0.0
     */

    entriesCap: u32,

    /**
     * The open-addressing hash table that holds the id of each string, where 0 marks an empty slot.
     *
     * @example
     * ```hx
     * interner.slots[hash & (interner.slotsCap - 1)]; // 1, or the start of a probe
     * ```
     *
     * @since 1.0.0
     */

    slots: u32[*],

    /**
     * The number of slots in the hash table, which is always a power of two.
     *
     * @remarks
     * The table doubles once it is half full.
     *
     * @example
     * ```hx
     * interner.slotsCap; // 1024
     * ```
     *
     * @since 1.0.0
     */

    slotsCap: u32,
}
