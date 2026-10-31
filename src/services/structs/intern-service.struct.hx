/**
 * The record that an interner keeps for one distinct string.
 *
 * @remarks
 * The text itself lives in the shared character buffer of the interner, at `start` for `len` bytes.
 *
 * @example
 * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
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
 * ```ts
 * let interner: HxInterner = undefined;
 * hx_interner_init(&interner);
 * hx_intern(&interner, "main", 4); // 1
 * hx_intern(&interner, "add", 3);  // 2
 * hx_intern(&interner, "main", 4); // 1 - the same text, the same id
 * hx_interner_free(&interner);
 * ```
 *
 * @see hx_intern
 * @see hx_name_text
 *
 * @since 1.0.0
 */

export extern "C" struct HxInterner {
    /**
     * The text of every interned string, one after another without separators.
     *
     * @example
     * ```ts
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
     * ```ts
     * interner.chars_len; // 7 after 'main' and 'add'
     * ```
     *
     * @since 1.0.0
     */

    chars_len: u32,

    /**
     * The capacity in bytes of the character buffer.
     *
     * @example
     * ```ts
     * interner.chars_cap; // 4096 after the first string
     * ```
     *
     * @since 1.0.0
     */

    chars_cap: u32,

    /**
     * The entry of each id, where entry 0 is unused.
     *
     * @example
     * ```ts
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
     * ```ts
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
     * ```ts
     * interner.entries_cap; // 512
     * ```
     *
     * @since 1.0.0
     */

    entries_cap: u32,

    /**
     * The open-addressing hash table that holds the id of each string, where 0 marks an empty slot.
     *
     * @example
     * ```ts
     * interner.slots[hash & (interner.slots_cap - 1)]; // 1, or the start of a probe
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
     * ```ts
     * interner.slots_cap; // 1024
     * ```
     *
     * @since 1.0.0
     */

    slots_cap: u32,
}
