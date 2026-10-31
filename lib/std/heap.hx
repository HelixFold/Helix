/**
 * Imports
 */

import * as c from "./c";
import { ArrayList } from "./list";

/**
 * The error that an allocation throws when its allocator has no memory left.
 *
 * @remarks
 * The typed helpers `alloc`, `resize`, and `create` throw it when the allocator's raw method returns null.
 * The raw methods themselves never throw, they return null instead.
 *
 * @example
 * ```hx
 * const items = alloc<u8>(allocator, 64) catch (e) { return e; }; // AllocError.OutOfMemory when it fails
 * ```
 *
 * @since 1.0.0
 */

export error AllocError {
    /**
     * The allocator could not hand out the memory that the call asked for.
     *
     * @remarks
     * It also covers an alignment that the allocator does not support, such as more than 16 bytes from the C heap.
     *
     * @example
     * ```hx
     * expect(alloc<u8>(full, 1)).toThrow(AllocError.OutOfMemory); // passes for an allocator that is out of memory
     * ```
     *
     * @since 1.0.0
     */

    OutOfMemory
}

/**
 * The source of memory for everything that allocates.
 *
 * @remarks
 * Anything that allocates takes a `dyn Allocator`, so a call always shows where its memory comes from.
 * A new kind of allocator implements the three raw methods below.
 * Code that allocates calls the typed helpers `alloc`, `resize`, `free`, `create`, and `destroy` instead,
 * which work in values of `T` and turn a null into `AllocError.OutOfMemory`.
 * The library provides the C heap through {@link cAllocator}, the {@link ArenaAllocator},
 * and the checking {@link DebugAllocator}.
 *
 * @example
 * ```hx
 * const a: dyn Allocator = cAllocator();
 * const items = try alloc<i32>(a, 4);
 * items.len; // 4
 * free(a, items);
 * ```
 *
 * @since 1.0.0
 */

export interface Allocator {
    /**
     * Hands out `size` bytes aligned to `align`.
     *
     * @param this - The allocator
     * @param size - The number of bytes wanted
     * @param align - The alignment in bytes, a power of two
     * @returns A pointer to the start of the bytes, or null when there is no memory left
     *
     * @remarks
     * The bytes are uninitialized.
     * An allocator that cannot meet the alignment returns null as well.
     *
     * @example
     * ```hx
     * const raw = cAllocator().rawAlloc(16, 8); // a pointer to 16 fresh bytes
     * ```
     *
     * @since 1.0.0
     */

    rawAlloc(this: *Self, size: usize, align: usize): ?u8[*];

    /**
     * Grows or shrinks `memory` to `size` bytes and keeps its contents.
     *
     * @param this - The allocator
     * @param memory - Bytes from `rawAlloc` or `rawResize`, at the size they have now
     * @param size - The new size in bytes
     * @param align - The alignment that `memory` was allocated with
     * @returns A pointer to the resized bytes, or null when there is no memory left
     *
     * @remarks
     * The bytes may move, so code must use the returned pointer and drop the old one.
     * A null result leaves `memory` untouched and still owned by the caller.
     *
     * @example
     * ```hx
     * const raw = a.rawResize(bytes, 64, 1); // the same 32 bytes at the front, now 64 long
     * ```
     *
     * @since 1.0.0
     */

    rawResize(this: *Self, memory: u8[], size: usize, align: usize): ?u8[*];

    /**
     * Gives back memory from `rawAlloc` or `rawResize`.
     *
     * @param this - The allocator
     * @param memory - The bytes to give back, at the size they have now
     * @param align - The alignment that `memory` was allocated with
     *
     * @remarks
     * The slice must be exactly what the allocator handed out, with the same pointer and length.
     * The memory must not be used afterwards.
     *
     * @example
     * ```hx
     * a.rawFree(bytes, 1); // bytes is no longer valid
     * ```
     *
     * @since 1.0.0
     */

    rawFree(this: *Self, memory: u8[], align: usize): void;
}

/**
 * Allocates room for `count` values of `T`.
 *
 * @typeParam T - The type of the values
 * @param allocator - The allocator that the memory comes from
 * @param count - The number of values
 * @returns An uninitialized slice of `count` values, or `AllocError.OutOfMemory`
 *
 * @remarks
 * The memory has the size and alignment of `T`, and the caller gives it back with {@link free}.
 * A count of 0 returns an empty slice without calling the allocator.
 *
 * @example
 * ```hx
 * const items = try alloc<u32>(cAllocator(), 3);
 * items.len; // 3
 * ```
 *
 * @see free
 * @since 1.0.0
 */

export function alloc<T>(allocator: dyn Allocator, count: usize): T[] | AllocError {
    if (count == 0) return [];
    unsafe {
        const raw = allocator.rawAlloc(count * @sizeOf(T), @alignOf(T)) ?? throw AllocError.OutOfMemory;
        const items = @ptrCast(T[*], raw);
        return items[0..count];
    }
}

/**
 * Grows or shrinks `items` to `count` values.
 *
 * @typeParam T - The type of the values
 * @param allocator - The allocator that `items` came from
 * @param items - A slice from `alloc` or `resize`
 * @param count - The new number of values
 * @returns The resized slice, or `AllocError.OutOfMemory`
 *
 * @remarks
 * The values up to the smaller of the two lengths stay as they were, and any new values are uninitialized.
 * The slice may move, so the old one must not be used afterwards.
 * A count of 0 frees `items` and returns an empty slice, and an empty `items` gets a fresh {@link alloc}.
 * When it fails, `items` stays valid and still belongs to the caller.
 *
 * @example
 * ```hx
 * let items = try alloc<u8>(a, 2);
 * items = try resize(a, items, 8);
 * items.len; // 8
 * ```
 *
 * @since 1.0.0
 */

export function resize<T>(allocator: dyn Allocator, items: T[], count: usize): T[] | AllocError {
    if (count == 0) {
        free(allocator, items);
        return [];
    }
    if (items.len == 0) return alloc<T>(allocator, count);
    unsafe {
        const raw = allocator.rawResize(bytes(items), count * @sizeOf(T), @alignOf(T)) ?? throw AllocError.OutOfMemory;
        const resized = @ptrCast(T[*], raw);
        return resized[0..count];
    }
}

/**
 * Gives memory from `alloc` or `resize` back to its allocator.
 *
 * @typeParam T - The type of the values
 * @param allocator - The allocator that `items` came from
 * @param items - The whole slice that `alloc` or `resize` returned
 *
 * @remarks
 * An empty slice is a no-op, which matches `alloc` handing one out without allocating.
 * The slice must keep the length it had when it was allocated, since the allocator gets it back by size.
 *
 * @example
 * ```hx
 * const items = try alloc<u8>(a, 16);
 * free(a, items); // items is no longer valid
 * ```
 *
 * @see alloc
 * @since 1.0.0
 */

export function free<T>(allocator: dyn Allocator, items: T[]): void {
    if (items.len == 0) return;
    allocator.rawFree(bytes(items), @alignOf(T));
}

/**
 * Allocates room for one value of `T`.
 *
 * @typeParam T - The type of the value
 * @param allocator - The allocator that the memory comes from
 * @returns A pointer to an uninitialized `T`, or `AllocError.OutOfMemory`
 *
 * @remarks
 * The caller gives the value back with {@link destroy}.
 * Use it for a single value whose lifetime outlasts the function that makes it, and use `alloc` for many.
 *
 * @example
 * ```hx
 * const point = try create<Point>(a);
 * point.x = 1;
 * point.x; // 1
 * ```
 *
 * @see destroy
 * @since 1.0.0
 */

export function create<T>(allocator: dyn Allocator): *T | AllocError {
    unsafe {
        const raw = allocator.rawAlloc(@sizeOf(T), @alignOf(T)) ?? throw AllocError.OutOfMemory;
        return @ptrCast(*T, raw);
    }
}

/**
 * Gives a value from `create` back to its allocator.
 *
 * @typeParam T - The type of the value
 * @param allocator - The allocator that `item` came from
 * @param item - The pointer that `create` returned
 *
 * @remarks
 * It frees `@sizeOf(T)` bytes at `item`, so `T` must be the type that `create` was called with.
 *
 * @example
 * ```hx
 * const point = try create<Point>(a);
 * destroy(a, point); // point is no longer valid
 * ```
 *
 * @see create
 * @since 1.0.0
 */

export function destroy<T>(allocator: dyn Allocator, item: *T): void {
    unsafe {
        const raw = @ptrCast(u8[*], item);
        allocator.rawFree(raw[0..@sizeOf(T)], @alignOf(T));
    }
}

/**
 * Views the memory under a slice as bytes.
 *
 * @typeParam T - The type of the values in the slice
 * @param items - The slice to view
 * @returns The same memory as a byte slice, `items.len * @sizeOf(T)` bytes long
 *
 * @remarks
 * The typed helpers use it to hand a slice of any `T` to the raw allocator methods, which work in bytes.
 * Nothing is copied.
 *
 * @since 1.0.0
 */

function bytes<T>(items: T[]): u8[] {
    unsafe {
        const raw = @ptrCast(u8[*], items.ptr);
        return raw[0..items.len * @sizeOf(T)];
    }
}

/**
 * Copies `source` to the start of `dest`.
 *
 * @param dest - The bytes to copy into, at least as long as `source`
 * @param source - The bytes to copy
 *
 * @remarks
 * Slicing `dest` to the length of `source` first runs the bounds check,
 * so a `dest` that is too short panics instead of letting `memcpy` write past its end.
 * The two slices must not overlap.
 *
 * @since 1.0.0
 */

function copy(dest: u8[], source: readonly u8[]): void {
    const _ = dest[0..source.len];   // bounds check
    unsafe {
        void c.memcpy(dest.ptr, source.ptr, source.len);
    }
}

/* ---- the C heap ---- */

/**
 * The allocator over the C library's `malloc`, `realloc`, and `free`.
 *
 * @remarks
 * It supports alignments up to 16 bytes, which is what `malloc` guarantees, and returns null for anything larger.
 * The struct has no state, so {@link cAllocator} hands out one shared instance.
 *
 * @example
 * ```hx
 * const a = cAllocator();
 * const text = try alloc<u8>(a, 5);
 * text.len; // 5
 * free(a, text);
 * ```
 *
 * @see cAllocator
 * @since 1.0.0
 */

export struct CAllocator {
    /**
     * Allocates `size` bytes with `malloc`.
     *
     * @param this - The C heap
     * @param size - The number of bytes wanted
     * @param align - The alignment in bytes
     * @returns The bytes from `malloc`, or null when `malloc` fails or `align` is over 16
     *
     * @remarks
     * The bytes are uninitialized, as `malloc` leaves them.
     *
     * @example
     * ```hx
     * cHeap.rawAlloc(8, 32); // null, since malloc only promises 16
     * ```
     *
     * @since 1.0.0
     */

    rawAlloc(this: *CAllocator, size: usize, align: usize): ?u8[*] {
        if (align > 16) return null;
        return c.malloc(size);
    }

    /**
     * Resizes `memory` with `realloc`.
     *
     * @param this - The C heap
     * @param memory - Bytes from this allocator
     * @param size - The new size in bytes
     * @param align - The alignment in bytes
     * @returns The resized bytes, or null when `realloc` fails or `align` is over 16
     *
     * @remarks
     * `realloc` keeps the contents up to the smaller size and may move the block.
     * On failure it leaves the old block in place.
     *
     * @example
     * ```hx
     * const raw = cHeap.rawResize(bytes, 64, 1); // bytes grown to 64, maybe at a new address
     * ```
     *
     * @since 1.0.0
     */

    rawResize(this: *CAllocator, memory: u8[], size: usize, align: usize): ?u8[*] {
        if (align > 16) return null;
        return c.realloc(memory.ptr, size);
    }

    /**
     * Gives `memory` back with `free`.
     *
     * @param this - The C heap
     * @param memory - Bytes from this allocator
     * @param _align - The alignment, unused because `free` needs only the pointer
     *
     * @remarks
     * Only the pointer reaches `free`, so the C heap cannot catch a wrong length.
     * The {@link DebugAllocator} checks that.
     *
     * @example
     * ```hx
     * cHeap.rawFree(bytes, 1); // bytes is no longer valid
     * ```
     *
     * @since 1.0.0
     */

    rawFree(this: *CAllocator, memory: u8[], _align: usize): void {
        c.free(memory.ptr);
    }
}

/**
 * The one shared C heap that `cAllocator` hands out.
 *
 * @remarks
 * A `CAllocator` has no fields, so leaving it undefined is safe and nothing needs to initialize it.
 *
 * @since 1.0.0
 */

let cHeap: CAllocator = undefined;

/**
 * Returns the C heap as an allocator.
 *
 * @returns The shared {@link CAllocator} as a `dyn Allocator`
 *
 * @remarks
 * Every call returns the same allocator, and it never needs to be released.
 * Use it as the backing for an arena or a debug allocator, or directly where memory lives until it is freed.
 *
 * @example
 * ```hx
 * const items = try alloc<i64>(cAllocator(), 2);
 * items.len; // 2
 * ```
 *
 * @since 1.0.0
 */

export function cAllocator(): dyn Allocator {
    return &cHeap;
}

/* ---- arenas ---- */

/**
 * The size in bytes of the first chunk that an arena takes from its backing allocator.
 *
 * @remarks
 * Each later chunk is twice the size of the one before, or the size of the request when that is bigger.
 *
 * @since 1.0.0
 */

const ChunkSize: usize = 4096;

/**
 * An allocator that hands out memory from big chunks and frees it all at once.
 *
 * @remarks
 * It takes chunks from `backing` and bumps through them, so an allocation is cheap and freeing one does nothing.
 * `deinit` gives every chunk back at once.
 * Use it for work whose memory all dies together, such as a request, a frame, or a parse.
 * The first chunk is 4096 bytes, and each new chunk is at least twice the last, so a big arena needs few of them.
 * It supports alignments up to 16 bytes.
 *
 * @example
 * ```hx
 * let arena = ArenaAllocator.init(cAllocator());
 * defer arena.deinit();
 * const a = arena.allocator();
 * const items = try alloc<u8>(a, 100);
 * items.len; // 100
 * ```
 *
 * @since 1.0.0
 */

export struct ArenaAllocator {
    /**
     * The allocator that the chunks come from.
     *
     * @remarks
     * The arena takes each chunk with 16-byte alignment and gives them back in `deinit`.
     *
     * @example
     * ```hx
     * const arena = ArenaAllocator.init(cAllocator());
     * arena.backing; // the C heap
     * ```
     *
     * @since 1.0.0
     */

    backing: dyn Allocator,

    /**
     * The chunks taken so far, oldest first.
     *
     * @remarks
     * Only the last chunk takes new allocations, and the arena never goes back to fill an older one.
     *
     * @example
     * ```hx
     * void try alloc<u8>(arena.allocator(), 10);
     * arena.chunks.items.len; // 1
     * ```
     *
     * @since 1.0.0
     */

    chunks: ArrayList<u8[]>,

    /**
     * The number of bytes taken from the last chunk.
     *
     * @remarks
     * The next allocation starts at this offset, rounded up to its alignment.
     *
     * @example
     * ```hx
     * void try alloc<u8>(arena.allocator(), 10);
     * arena.used; // 10
     * ```
     *
     * @since 1.0.0
     */

    used: usize,

    /**
     * Creates an empty arena over `backing`.
     *
     * @param backing - The allocator that the chunks come from
     * @returns An arena that holds no chunks yet
     *
     * @remarks
     * Nothing allocates until the first allocation.
     *
     * @example
     * ```hx
     * const arena = ArenaAllocator.init(cAllocator());
     * arena.used; // 0
     * ```
     *
     * @since 1.0.0
     */

    init(backing: dyn Allocator): ArenaAllocator {
        return ArenaAllocator { backing, chunks: ArrayList<u8[]>.init(backing), used: 0 };
    }

    /**
     * Returns the arena as an allocator.
     *
     * @param this - The arena
     * @returns The arena as a `dyn Allocator` that points at it
     *
     * @remarks
     * The result holds a pointer to the arena, so the arena must stay in place while the allocator is in use.
     *
     * @example
     * ```hx
     * const a = arena.allocator();
     * const items = try alloc<u8>(a, 4);
     * items.len; // 4
     * ```
     *
     * @since 1.0.0
     */

    allocator(this: *ArenaAllocator): dyn Allocator {
        return this;
    }

    /**
     * Frees every allocation at once.
     *
     * @param this - The arena
     *
     * @remarks
     * It gives each chunk back to `backing`, then frees the chunk list.
     * The arena is empty afterwards and can take new allocations again.
     *
     * @example
     * ```hx
     * void try alloc<u8>(arena.allocator(), 10);
     * arena.deinit();
     * arena.chunks.items.len; // 0
     * ```
     *
     * @since 1.0.0
     */

    deinit(this: *ArenaAllocator): void {
        for (const chunk of this.chunks.items) this.backing.rawFree(chunk, 16);
        this.chunks.deinit();
        this.used = 0;
    }

    /**
     * Hands out `size` bytes from the last chunk, or from a new one.
     *
     * @param this - The arena
     * @param size - The number of bytes wanted
     * @param align - The alignment in bytes, at most 16
     * @returns A pointer to the bytes, or null when `align` is over 16 or `backing` has no memory left
     *
     * @remarks
     * When the request fits after `used`, rounded up to `align`, it comes from the last chunk.
     * Otherwise the arena takes a new chunk of twice the last one's size, or of `size` when that is bigger,
     * and the request starts at its front.
     * The rest of the old chunk stays unused.
     *
     * @example
     * ```hx
     * const raw = arena.rawAlloc(8, 8); // a pointer 8 bytes past the last allocation, rounded up
     * ```
     *
     * @since 1.0.0
     */

    rawAlloc(this: *ArenaAllocator, size: usize, align: usize): ?u8[*] {
        if (align > 16) return null;
        const count = this.chunks.items.len;
        const start = (this.used + align - 1) / align * align;
        if (count > 0 && start + size <= this.chunks.items[count - 1].len) {
            this.used = start + size;
            return this.chunks.items[count - 1][start..start + size].ptr;
        }

        // A new chunk, at least twice the last one so big arenas need few of them.
        const last = count > 0 ? this.chunks.items[count - 1].len : ChunkSize / 2;
        const wanted = last * 2 > size ? last * 2 : size;
        unsafe {
            const raw = this.backing.rawAlloc(wanted, 16);
            if (raw == null) return null;
            const chunk = raw[0..wanted];
            this.chunks.append(chunk) catch {
                this.backing.rawFree(chunk, 16);
                return null;
            };
            this.used = size;
            return raw;
        }
    }

    /**
     * Grows or shrinks `memory` inside the arena.
     *
     * @param this - The arena
     * @param memory - Bytes from this arena
     * @param size - The new size in bytes
     * @param align - The alignment in bytes
     * @returns A pointer to the resized bytes, or null when a new allocation fails
     *
     * @remarks
     * Shrinking returns the same pointer and keeps the bytes where they are.
     * Growing always takes a new allocation and copies the old bytes into it,
     * and the old bytes stay in the arena until `deinit`.
     *
     * @example
     * ```hx
     * const raw = arena.rawResize(bytes, 4, 1); // the same pointer as bytes, since 4 is not bigger
     * ```
     *
     * @since 1.0.0
     */

    rawResize(this: *ArenaAllocator, memory: u8[], size: usize, align: usize): ?u8[*] {
        if (size <= memory.len) return memory.ptr;
        unsafe {
            const raw = this.rawAlloc(size, align);
            if (raw == null) return null;
            copy(raw[0..size], memory);
            return raw;
        }
    }

    /**
     * Does nothing, since the arena frees everything at once in `deinit`.
     *
     * @param this - The arena
     * @param _memory - The bytes, unused
     * @param _align - The alignment, unused
     *
     * @remarks
     * Calling `free` on arena memory is still correct, and code that takes any allocator can call it freely.
     *
     * @example
     * ```hx
     * arena.rawFree(bytes, 1); // nothing happens, bytes stays readable until deinit
     * ```
     *
     * @since 1.0.0
     */

    rawFree(this: *ArenaAllocator, _memory: u8[], _align: usize): void {}
}

/* ---- checking ---- */

/**
 * Takes a block of guarded pages from the runtime in `lib/rt/runtime.c`.
 *
 * @param size - The number of bytes wanted
 * @param align - The alignment in bytes
 * @returns A pointer to the block, or null when the system has no memory left
 *
 * @remarks
 * On macOS and Linux each block gets pages of its own and ends right before an inaccessible page,
 * so a read or write past its end faults.
 * Elsewhere it falls back to `malloc`.
 *
 * @since 1.0.0
 */

extern "C" function hx_guard_alloc(size: usize, align: usize): ?u8[*];

/**
 * Gives a block from `hx_guard_alloc` back to the runtime in `lib/rt/runtime.c`.
 *
 * @param memory - The pointer that `hx_guard_alloc` returned
 * @param size - The size of the block in bytes
 *
 * @remarks
 * On macOS and Linux the pages become inaccessible and wait in a quarantine of the 16384 most recent blocks,
 * so a use after the free faults instead of reading reused memory.
 * Elsewhere it calls `free`.
 *
 * @since 1.0.0
 */

extern "C" function hx_guard_free(memory: u8[*], size: usize): void;

/**
 * An allocator that checks how a program uses its memory.
 *
 * @remarks
 * `deinit` reports every allocation that the program never freed.
 * Freeing memory that it did not hand out, freeing twice, or freeing with the wrong size panics.
 * New memory is filled with 0xAA, the pattern for undefined bytes.
 *
 * By default each block gets pages of its own on macOS and Linux, ending right before an inaccessible page,
 * and freed blocks become inaccessible while they wait in a quarantine.
 * So reading or writing past the end of a block, using memory after freeing it,
 * and keeping a pointer into an `ArrayList` that has grown all fault where they happen, with a stack trace.
 * That costs at least a page per allocation.
 * For programs with many live allocations, `initUnguarded` keeps the other checks and takes memory from `backing`.
 *
 * @example
 * ```hx
 * let debug = DebugAllocator.init(cAllocator());
 * const items = try alloc<u8>(debug.allocator(), 8);
 * items[0];      // 0xAA
 * debug.deinit(); // 1, after it prints "leak: 8 bytes were never freed"
 * ```
 *
 * @since 1.0.0
 */

export struct DebugAllocator {
    /**
     * The allocator that the list of live blocks comes from, and the blocks too when unguarded.
     *
     * @remarks
     * A guarded allocator takes its blocks from the runtime's guarded pages and uses `backing` only for `live`.
     *
     * @example
     * ```hx
     * const debug = DebugAllocator.init(cAllocator());
     * debug.backing; // the C heap
     * ```
     *
     * @since 1.0.0
     */

    backing: dyn Allocator,

    /**
     * The allocations not yet freed.
     *
     * @remarks
     * Each entry is the exact slice that the allocator handed out,
     * so a free or a resize can check both the pointer and the length.
     *
     * @example
     * ```hx
     * void try alloc<u8>(debug.allocator(), 3);
     * debug.live.items.len; // 1
     * ```
     *
     * @since 1.0.0
     */

    live: ArrayList<u8[]>,

    /**
     * Whether blocks come from guarded pages.
     *
     * @remarks
     * `init` sets it, and `initUnguarded` leaves it unset.
     *
     * @example
     * ```hx
     * DebugAllocator.init(cAllocator()).guarded;          // true
     * DebugAllocator.initUnguarded(cAllocator()).guarded; // false
     * ```
     *
     * @since 1.0.0
     */

    guarded: bool,

    /**
     * Creates a debug allocator that puts each block on guarded pages.
     *
     * @param backing - The allocator that the list of live blocks comes from
     * @returns A debug allocator with no live blocks
     *
     * @remarks
     * Use it where catching an overrun or a use after free matters more than memory.
     *
     * @example
     * ```hx
     * let debug = DebugAllocator.init(cAllocator());
     * debug.count(); // 0
     * ```
     *
     * @since 1.0.0
     */

    init(backing: dyn Allocator): DebugAllocator {
        return DebugAllocator { backing, live: ArrayList<u8[]>.init(backing), guarded: true };
    }

    /**
     * Creates a debug allocator that takes its blocks from `backing`.
     *
     * @param backing - The allocator that the blocks and the list of live blocks come from
     * @returns A debug allocator with no live blocks and no page guards
     *
     * @remarks
     * It keeps the leak, double free, and size checks, and fills freed memory with 0xAA before giving it back.
     * Use it for programs with too many live allocations to give each one pages of its own.
     *
     * @example
     * ```hx
     * let debug = DebugAllocator.initUnguarded(cAllocator());
     * debug.guarded; // false
     * ```
     *
     * @since 1.0.0
     */

    initUnguarded(backing: dyn Allocator): DebugAllocator {
        return DebugAllocator { backing, live: ArrayList<u8[]>.init(backing), guarded: false };
    }

    /**
     * Returns the debug allocator as an allocator.
     *
     * @param this - The debug allocator
     * @returns The debug allocator as a `dyn Allocator` that points at it
     *
     * @remarks
     * The result holds a pointer to the debug allocator, so the debug allocator must stay in place while in use.
     *
     * @example
     * ```hx
     * const a = debug.allocator();
     * free(a, try alloc<u8>(a, 1));
     * debug.count(); // 0
     * ```
     *
     * @since 1.0.0
     */

    allocator(this: *DebugAllocator): dyn Allocator {
        return this;
    }

    /**
     * Reports each leak, frees it, and returns how many there were.
     *
     * @param this - The debug allocator
     * @returns The number of allocations that were still live
     *
     * @remarks
     * It prints `leak: N bytes were never freed` on stderr for each live block, then frees the block.
     * Afterwards the list of live blocks is empty and freed as well.
     *
     * @example
     * ```hx
     * void try alloc<u8>(debug.allocator(), 4);
     * debug.deinit(); // 1
     * ```
     *
     * @since 1.0.0
     */

    deinit(this: *DebugAllocator): usize {
        const leaks = this.live.items.len;
        for (const memory of this.live.items) {
            eprintln(`leak: ${memory.len} bytes were never freed`);
            this.release(memory, 16);
        }
        this.live.deinit();
        return leaks;
    }

    /**
     * Returns how many allocations are live right now.
     *
     * @param this - The debug allocator
     * @returns The number of blocks handed out and not yet freed
     *
     * @remarks
     * A resize keeps the count, since it replaces one live block with another.
     *
     * @example
     * ```hx
     * const items = try alloc<u8>(debug.allocator(), 2);
     * debug.count(); // 1
     * ```
     *
     * @since 1.0.0
     */

    count(this: readonly *DebugAllocator): usize {
        return this.live.items.len;
    }

    /**
     * Takes a block from the guarded pages, or from `backing` when unguarded.
     *
     * @param this - The debug allocator
     * @param size - The number of bytes wanted
     * @param align - The alignment in bytes
     * @returns A pointer to the block, or null when there is no memory left
     *
     * @remarks
     * It does not record the block, and `rawAlloc` and `rawResize` do that after it succeeds.
     *
     * @example
     * ```hx
     * const raw = debug.take(16, 8); // a block that is not in live yet
     * ```
     *
     * @since 1.0.0
     */

    take(this: *DebugAllocator, size: usize, align: usize): ?u8[*] {
        if (this.guarded) return hx_guard_alloc(size, align);
        return this.backing.rawAlloc(size, align);
    }

    /**
     * Gives a block back to the guarded pages, or to `backing` when unguarded.
     *
     * @param this - The debug allocator
     * @param memory - The block to give back
     * @param align - The alignment that the block was taken with
     *
     * @remarks
     * A guarded block goes to the runtime's quarantine and is inaccessible from then on.
     * An unguarded block is filled with 0xAA first, so a use after free reads the undefined pattern.
     * It does not touch `live`.
     *
     * @example
     * ```hx
     * debug.release(block, 8); // block is no longer valid
     * ```
     *
     * @since 1.0.0
     */

    release(this: *DebugAllocator, memory: u8[], align: usize): void {
        if (this.guarded) {
            hx_guard_free(memory.ptr, memory.len);
            return;
        }
        fill(memory);
        this.backing.rawFree(memory, align);
    }

    /**
     * Hands out `size` bytes, filled with 0xAA, and records them as live.
     *
     * @param this - The debug allocator
     * @param size - The number of bytes wanted
     * @param align - The alignment in bytes
     * @returns A pointer to the bytes, or null when there is no memory left
     *
     * @remarks
     * When recording the block fails, it gives the block back and returns null.
     *
     * @example
     * ```hx
     * const raw = debug.rawAlloc(4, 1);
     * debug.count(); // 1
     * ```
     *
     * @since 1.0.0
     */

    rawAlloc(this: *DebugAllocator, size: usize, align: usize): ?u8[*] {
        unsafe {
            const raw = this.take(size, align);
            if (raw == null) return null;
            const memory = raw[0..size];
            this.live.append(memory) catch {
                this.release(memory, align);
                return null;
            };
            fill(memory);
            return raw;
        }
    }

    /**
     * Moves `memory` to a new block of `size` bytes and keeps its contents.
     *
     * @param this - The debug allocator
     * @param memory - A live block from this allocator
     * @param size - The new size in bytes
     * @param align - The alignment in bytes
     * @returns A pointer to the new block, or null when there is no memory left
     *
     * @remarks
     * It always moves, even when shrinking, so code that keeps the old slice faults or reads 0xAA right away.
     * Bytes past the old length are 0xAA.
     * It panics when `memory` is not a live block of this allocator at its exact size.
     *
     * @example
     * ```hx
     * const raw = debug.rawResize(bytes, 8, 1); // a new address, never the one in bytes
     * ```
     *
     * @since 1.0.0
     */

    rawResize(this: *DebugAllocator, memory: u8[], size: usize, align: usize): ?u8[*] {
        const index = this.find(memory);
        unsafe {
            const raw = this.take(size, align);
            if (raw == null) return null;
            const moved = raw[0..size];
            fill(moved);
            copy(moved, size < memory.len ? memory[0..size] : memory);
            this.release(memory, align);
            this.live.items[index] = moved;   // always moves, so code that keeps the old slice breaks right away
            return raw;
        }
    }

    /**
     * Gives `memory` back and drops it from the live blocks.
     *
     * @param this - The debug allocator
     * @param memory - A live block from this allocator
     * @param align - The alignment that the block was allocated with
     *
     * @remarks
     * It panics when `memory` is not a live block of this allocator at its exact size,
     * which catches a double free, a foreign pointer, and a wrong length.
     * The last live entry moves into the freed slot, so the order of `live` changes.
     *
     * @example
     * ```hx
     * debug.rawFree(bytes, 1);
     * debug.count(); // 0
     * ```
     *
     * @since 1.0.0
     */

    rawFree(this: *DebugAllocator, memory: u8[], align: usize): void {
        const index = this.find(memory);
        this.release(memory, align);
        const last = this.live.pop() ?? unreachable;
        if (index < this.live.items.len) this.live.items[index] = last;
    }

    /**
     * Finds `memory` in the live blocks.
     *
     * @param this - The debug allocator
     * @param memory - The block to look for
     * @returns The index of the block in `live`
     *
     * @remarks
     * It matches by pointer, then panics when the length differs from the recorded one.
     * It panics as well when no live block starts at the pointer, which means a double free or a foreign block.
     *
     * @example
     * ```hx
     * debug.find(bytes); // 0, for the first live block
     * ```
     *
     * @since 1.0.0
     */

    find(this: readonly *DebugAllocator, memory: u8[]): usize {
        for (const live, i of this.live.items) {
            if (live.ptr != memory.ptr) continue;
            if (live.len != memory.len) @panic("memory freed or resized with a different size than it has");
            return i;
        }
        @panic("memory freed twice, or not from this allocator");
    }
}

/**
 * Fills `memory` with 0xAA, the pattern for undefined bytes.
 *
 * @param memory - The bytes to fill
 *
 * @remarks
 * The debug allocator fills new memory with it, so a read of uninitialized bytes shows a telltale value,
 * and fills unguarded memory with it before freeing.
 *
 * @since 1.0.0
 */

function fill(memory: u8[]): void {
    for (const _, i of memory) memory[i] = 0xAA;
}
