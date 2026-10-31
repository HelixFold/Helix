/**
 * The header of one block of memory that an arena hands out from.
 *
 * @remarks
 * The data area follows the header at {@link HEADER} bytes from its start.
 * Chunks form a list from the newest to the oldest, and only the newest one takes new requests.
 *
 * @example
 * ```ts
 * // arena head -> Chunk { used: 120, cap: 65536 } -> Chunk { used: 65530, cap: 65536 } -> null
 * ```
 *
 * @see HxArena
 * @since 1.0.0
 */

export struct Chunk {
    /**
     * The chunk that was the newest before this one, or `null` for the first chunk.
     *
     * @example
     * ```ts
     * chunk.next; // null for the first chunk
     * ```
     *
     * @since 1.0.0
     */

    next: ?*Chunk,

    /**
     * The number of bytes of the data area handed out so far, alignment padding included.
     *
     * @example
     * ```ts
     * chunk.used; // 120
     * ```
     *
     * @since 1.0.0
     */

    used: usize,

    /**
     * The size in bytes of the data area after the header.
     *
     * @example
     * ```ts
     * chunk.cap; // 65536
     * ```
     *
     * @since 1.0.0
     */

    cap: usize,
}

/**
 * A region allocator whose allocations all live until one call releases them together.
 *
 * @remarks
 * Reach for it when many small allocations share one lifetime, such as the messages of a diagnostic list.
 * It never frees a single allocation, so it suits data that is built once and dropped as a whole.
 * Start it with `null` as its head, which means it holds no chunks yet.
 *
 * @example
 * ```ts
 * let arena = HxArena { head: null };
 * const name = hx_arena_strndup(&arena, "main", 4);
 * hx_arena_free(&arena); // name is released with everything else
 * ```
 *
 * @see hx_arena_alloc
 * @see hx_arena_free
 *
 * @since 1.0.0
 */

export extern "C" struct HxArena {
    /**
     * The newest chunk, or `null` when the arena holds none.
     *
     * @example
     * ```ts
     * HxArena { head: null }; // an empty arena
     * ```
     *
     * @since 1.0.0
     */

    head: ?*Chunk,
}
