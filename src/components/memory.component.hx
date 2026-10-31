/**
 * The C heap functions that the helpers below wrap.
 */

extern "C" function malloc(size: usize): ?u8[*];
extern "C" function calloc(count: usize, size: usize): ?u8[*];
extern "C" function realloc(ptr: ?u8[*], size: usize): ?u8[*];
extern "C" function abort(): noreturn;
extern "C" function strlen(text: readonly u8[*]): usize;

/**
 * Releases a block that {@link hx_alloc}, {@link hx_zalloc}, or {@link hx_realloc} handed out.
 *
 * @param ptr - The block to release, or `null`, which does nothing
 *
 * @remarks
 * This is the C library's `free`, declared here so that the rest of the compiler imports it from one place.
 *
 * @example
 * ```ts
 * const bytes = hx_alloc(16);
 * free(bytes);
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function free(ptr: ?u8[*]): void;

/**
 * Stops the compiler with an internal compiler error.
 *
 * @param message - The NUL-terminated text that follows `internal compiler error:`
 *
 * @remarks
 * An internal compiler error is a bug in the compiler, never a mistake in the program it compiles.
 * The message goes to standard error, and the process aborts without unwinding.
 *
 * @example
 * ```ts
 * hx_fatal_message("unknown node kind");
 * // helix: internal compiler error: unknown node kind
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_fatal_message(message: readonly u8[*]): noreturn {
    unsafe {
        eprint(`helix: internal compiler error: ${message[0..strlen(message)]}\n`);
    }
    abort();
}

/**
 * Stops the compiler after the C heap refused a request.
 *
 * @param size - The number of bytes that the failed request asked for
 *
 * @remarks
 * Every allocation helper funnels its failure here, so a caller never checks for `null`.
 */

function outOfMemory(size: usize): noreturn {
    eprint(`helix: internal compiler error: out of memory (requested ${size} bytes)\n`);
    abort();
}

/**
 * Allocates a block of uninitialized memory.
 *
 * @param size - The number of bytes to allocate, where 0 is treated as 1
 * @returns The new block, never `null`
 *
 * @remarks
 * A failed allocation stops the compiler through an internal compiler error,
 * so the result is always usable.
 * Release the block with {@link free}.
 *
 * @example
 * ```ts
 * const bytes = hx_alloc(64); // 64 bytes, contents undefined
 * free(bytes);
 * ```
 *
 * @see hx_zalloc
 * @since 1.0.0
 */

export extern "C" function hx_alloc(size: usize): u8[*] {
    return malloc(size != 0 ? size : 1) ?? outOfMemory(size);
}

/**
 * Allocates a block of memory filled with zeros.
 *
 * @param size - The number of bytes to allocate, where 0 is treated as 1
 * @returns The new block, never `null`
 *
 * @remarks
 * Choose it over {@link hx_alloc} when the caller relies on every byte starting at zero, as a hash table of empty
 * slots does.
 *
 * @example
 * ```ts
 * const slots = hx_zalloc(1024 * 4); // 1024 slots of 4 bytes, all 0
 * ```
 *
 * @see hx_alloc
 * @since 1.0.0
 */

export extern "C" function hx_zalloc(size: usize): u8[*] {
    return calloc(1, size != 0 ? size : 1) ?? outOfMemory(size);
}

/**
 * Resizes a block, or allocates a new one when the pointer is `null`.
 *
 * @param ptr - The block to resize, or `null` to allocate a fresh one
 * @param size - The new size in bytes, where 0 is treated as 1
 * @returns The resized block, which may have moved
 *
 * @remarks
 * The contents up to the smaller of the old and new sizes are kept.
 * The old pointer is invalid after the call, so callers store the result in its place.
 *
 * @example
 * ```ts
 * let items = hx_realloc(null, 8);  // a new 8-byte block
 * items = hx_realloc(items, 16);    // grown to 16, the first 8 bytes kept
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_realloc(ptr: ?u8[*], size: usize): u8[*] {
    return realloc(ptr, size != 0 ? size : 1) ?? outOfMemory(size);
}

/**
 * Copies the first bytes of a text into a new NUL-terminated block.
 *
 * @param text - The text to copy from
 * @param len - The number of bytes to copy
 * @returns A new block of `len + 1` bytes that ends with a NUL
 *
 * @remarks
 * The copy stops at `len` even when the text holds a NUL earlier, so it also copies binary data.
 *
 * @example
 * ```ts
 * const copy = hx_strndup("main.hx", 4); // 'main', NUL-terminated
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_strndup(text: readonly u8[*], len: usize): u8[*] {
    const copy = hx_alloc(len + 1);
    unsafe {
        for (const i of 0..len) copy[i] = text[i];
        copy[len] = 0;
    }
    return copy;
}

/**
 * Grows a heap array so that it holds at least the given number of elements.
 *
 * @param items - The array pointer, which the call replaces when it grows
 * @param cap - The capacity of the array in elements, which the call updates
 * @param min - The number of elements that the array must hold afterwards
 * @param elem_size - The size of one element in bytes
 *
 * @remarks
 * The capacity at least doubles, or starts at 8 for an empty array,
 * so a run of single pushes costs amortized constant time.
 * Nothing happens when the capacity already reaches `min`.
 * A capacity that would pass the 32-bit range stops the compiler with an internal compiler error.
 *
 * @example
 * ```ts
 * let items: ?u8[*] = null;
 * let cap: u32 = 0;
 * hx_vec_grow_impl(&items, &cap, 1, 4);  // cap: 8
 * hx_vec_grow_impl(&items, &cap, 9, 4);  // cap: 16
 * hx_vec_grow_impl(&items, &cap, 10, 4); // cap: 16, unchanged
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_vec_grow_impl(items: *?u8[*], cap: *u32, min: u32, elem_size: usize): void {
    if (*cap >= min) return;
    let next: u64 = *cap != 0 ? (*cap as u64) * 2 : 8;
    if (next < (min as u64)) next = min as u64;
    if (next > 0xFFFF_FFFF) {
        eprint("helix: internal compiler error: vector capacity overflow\n");
        abort();
    }
    *items = hx_realloc(*items, (next as usize) * elem_size);
    *cap = @truncate(u32, next);
}
