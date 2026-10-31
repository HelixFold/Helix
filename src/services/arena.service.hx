/**
 * Imports
 */

import { hxAlloc, free } from "@components/memory.component";
import { CHUNK_SIZE, Header } from "@constants/arena.constant";
import { Chunk, HxArena } from "@services/structs/arena-service.struct";

/**
 * The address of the first data byte of a chunk.
 *
 * @param chunk - The chunk whose data area to locate
 * @returns The address {@link Header} bytes past the start of the chunk
 *
 * @remarks
 * A chunk starts with its header, so the data area begins right after it.
 *
 * @since 1.0.0
 */

function data(chunk: *Chunk): usize {
    return @intFromPtr(chunk) + Header;
}

/**
 * Rounds an address up to the next multiple of an alignment.
 *
 * @param address - The address to round
 * @param align - The alignment, which must be a power of two
 * @returns The smallest multiple of `align` that is not below `address`
 *
 * @remarks
 * It clears the low bits with a mask, so an alignment that is not a power of two gives a wrong result.
 * An address already on the boundary comes back unchanged.
 *
 * @since 1.0.0
 */

function alignUp(address: usize, align: usize): usize {
    return (address + align - 1) & ~(align - 1);
}

/**
 * Hands out a block of memory from an arena.
 *
 * @param arena - The arena to allocate from
 * @param size - The number of bytes to hand out
 * @param align - The alignment of the block, which must be a power of two
 * @returns The new block, which lives until {@link hxArenaFree}
 *
 * @remarks
 * The block is aligned by its address, not by its offset in the chunk, so a type that needs 16 bytes gets them.
 * When the newest chunk has no room left, a new chunk takes its place at the head.
 * A request larger than {@link CHUNK_SIZE} gets a chunk of its own,
 * and the space left in the previous chunk is not used again.
 * The memory is not cleared.
 *
 * @example
 * ```hx
 * let arena = HxArena { head: null };
 * const a = hxArenaAlloc(&arena, 24, 8);  // the first chunk is created
 * const b = hxArenaAlloc(&arena, 16, 16); // from the same chunk, 16-byte aligned
 * hxArenaFree(&arena);
 * ```
 *
 * @see hxArenaStrndup
 * @since 1.0.0
 */

export extern "C" function hxArenaAlloc(arena: *HxArena, size: usize, align: usize): u8[*] {
    if (const chunk = arena.head) {
        const offset = alignUp(data(chunk) + chunk.used, align) - data(chunk);
        if (offset + size <= chunk.cap) {
            chunk.used = offset + size;
            unsafe {
                return @ptrFromInt(u8[*], data(chunk) + offset);
            }
        }
    }

    const cap = size + align > CHUNK_SIZE ? size + align : CHUNK_SIZE;
    let chunk: *Chunk = undefined;
    unsafe {
        chunk = @ptrCast(*Chunk, hxAlloc(Header + cap));
    }
    chunk.next = arena.head;
    chunk.cap = cap;
    arena.head = chunk;
    const offset = alignUp(data(chunk), align) - data(chunk);
    chunk.used = offset + size;
    unsafe {
        return @ptrFromInt(u8[*], data(chunk) + offset);
    }
}

/**
 * Copies the first bytes of a text into an arena as a NUL-terminated string.
 *
 * @param arena - The arena that owns the copy
 * @param text - The text to copy from
 * @param len - The number of bytes to copy
 * @returns The copy, which lives until {@link hxArenaFree}
 *
 * @remarks
 * The copy stops at `len` even when the text holds a NUL earlier.
 *
 * @example
 * ```hx
 * let arena = HxArena { head: null };
 * const name = hxArenaStrndup(&arena, "main.hx", 4); // 'main'
 * hxArenaFree(&arena);
 * ```
 *
 * @see hxArenaAlloc
 * @since 1.0.0
 */

export extern "C" function hxArenaStrndup(arena: *HxArena, text: readonly u8[*], len: usize): u8[*] {
    const copy = hxArenaAlloc(arena, len + 1, 1);
    unsafe {
        for (const i of 0..len) copy[i] = text[i];
        copy[len] = 0;
    }
    return copy;
}

/**
 * Releases every block that an arena handed out.
 *
 * @param arena - The arena to empty
 *
 * @remarks
 * The arena is left empty and ready for new requests, so it can be reused after the call.
 * Every pointer it handed out becomes invalid.
 *
 * @example
 * ```hx
 * let arena = HxArena { head: null };
 * void hxArenaAlloc(&arena, 100, 8);
 * hxArenaFree(&arena);
 * arena.head; // null
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxArenaFree(arena: *HxArena): void {
    let chunk = arena.head;
    while (const c = chunk) {
        chunk = c.next;
        unsafe {
            free(@ptrCast(?u8[*], c));
        }
    }
    arena.head = null;
}
