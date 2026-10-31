/**
 * Imports
 */

import { free, resize } from "./heap";
import { AllocError, ArenaAllocator, CAllocator, DebugAllocator, alloc, cAllocator, create, destroy } from "./heap";

/**
 * Tests
 */

/**
 * An allocator that is always out of memory.
 *
 * @remarks
 * Every raw method that hands out memory returns null, so the typed helpers throw `AllocError.OutOfMemory`.
 * It never hands out memory, so its `rawFree` has nothing to give back.
 *
 * @since 1.0.0
 */

struct Exhausted {
    /**
     * Returns null for every request.
     *
     * @param this - The allocator
     * @param _size - The number of bytes, unused
     * @param _align - The alignment, unused
     * @returns Always null
     *
     * @remarks
     * It stands in for an allocator whose memory has run out.
     *
     * @since 1.0.0
     */

    rawAlloc(this: *Exhausted, _size: usize, _align: usize): ?u8[*] {
        return null;
    }

    /**
     * Returns null for every request.
     *
     * @param this - The allocator
     * @param _memory - The bytes, unused
     * @param _size - The new size, unused
     * @param _align - The alignment, unused
     * @returns Always null
     *
     * @remarks
     * It stands in for an allocator that cannot grow a block.
     *
     * @since 1.0.0
     */

    rawResize(this: *Exhausted, _memory: u8[], _size: usize, _align: usize): ?u8[*] {
        return null;
    }

    /**
     * Does nothing.
     *
     * @param this - The allocator
     * @param _memory - The bytes, unused
     * @param _align - The alignment, unused
     *
     * @remarks
     * Nothing ever comes from this allocator, so there is nothing to give back.
     *
     * @since 1.0.0
     */

    rawFree(this: *Exhausted, _memory: u8[], _align: usize): void {}
}

/**
 * A value with the alignment of a `u64`, for the alignment checks.
 *
 * @remarks
 * It gives `create` and `alloc` a type larger and more aligned than a byte.
 *
 * @since 1.0.0
 */

struct Pair {
    /**
     * The first half.
     *
     * @since 1.0.0
     */

    a: u64,

    /**
     * The second half.
     *
     * @since 1.0.0
     */

    b: u64,
}

/**
 * Returns whether `ptr` is a multiple of `align`.
 *
 * @param ptr - The pointer to check
 * @param align - The alignment in bytes
 * @returns True when the address is aligned
 *
 * @remarks
 * It compares the address as an integer, which is how the allocators round their offsets.
 *
 * @since 1.0.0
 */

function aligned(ptr: u8[*], align: usize): bool {
    return (@intFromPtr(ptr) % align) == 0;
}

describe("AllocError") {
    test("should come from alloc when the allocator has no memory left") {
        let none = Exhausted {};

        expect(alloc<u8>(&none, 1)).toThrow(AllocError.OutOfMemory);
    }
}

describe("alloc") {
    test("should return a slice of the given length") {
        const items = try alloc<u32>(testing.allocator, 5);
        defer free(testing.allocator, items);

        expect(items.len).toBe(5);
    }

    test("should return an empty slice for a count of 0 without calling the allocator") {
        let none = Exhausted {};
        const items = try alloc<u32>(&none, 0);

        expect(items.len).toBe(0);
    }

    test("should hand out memory that holds what the caller writes") {
        const items = try alloc<u64>(testing.allocator, 3);
        defer free(testing.allocator, items);
        items[0] = 1;
        items[2] = 3;

        expect(items[0]).toBe(1);
        expect(items[2]).toBe(3);
    }

    test("should throw OutOfMemory when the allocator returns null") {
        let none = Exhausted {};

        expect(alloc<u64>(&none, 4)).toThrow(AllocError.OutOfMemory);
    }
}

describe("resize") {
    test("should keep the values when it grows the slice") {
        let items = try alloc<i32>(testing.allocator, 2);
        items[0] = 10;
        items[1] = 20;
        items = try resize(testing.allocator, items, 6);
        defer free(testing.allocator, items);

        expect(items.len).toBe(6);
        expect(items[0]).toBe(10);
        expect(items[1]).toBe(20);
    }

    test("should keep the leading values when it shrinks the slice") {
        let items = try alloc<i32>(testing.allocator, 3);
        items[0] = 7;
        items = try resize(testing.allocator, items, 1);
        defer free(testing.allocator, items);

        expect(items.len).toBe(1);
        expect(items[0]).toBe(7);
    }

    test("should free the slice and return an empty one for a count of 0") {
        const items = try alloc<i32>(testing.allocator, 3);
        const none = try resize(testing.allocator, items, 0);

        expect(none.len).toBe(0);
    }

    test("should allocate fresh memory for an empty slice") {
        const empty: i32[] = [];
        const items = try resize(testing.allocator, empty, 4);
        defer free(testing.allocator, items);

        expect(items.len).toBe(4);
    }

    test("should throw OutOfMemory when the allocator cannot grow the slice") {
        let none = Exhausted {};
        let one: u8[1] = [1];

        expect(resize<u8>(&none, &one, 2)).toThrow(AllocError.OutOfMemory);
    }
}

describe("free") {
    test("should give the memory back to the allocator") {
        let debug = DebugAllocator.initUnguarded(testing.allocator);
        const a = debug.allocator();
        const items = try alloc<u8>(a, 8);
        free(a, items);

        expect(debug.count()).toBe(0);
        expect(debug.deinit()).toBe(0);
    }

    test("should ignore an empty slice") {
        let none = Exhausted {};
        const empty: u8[] = [];
        free(&none, empty);

        expect(empty.len).toBe(0);
    }
}

describe("create") {
    test("should return a pointer to one writable value") {
        const pair = try create<Pair>(testing.allocator);
        defer destroy(testing.allocator, pair);
        pair.a = 1;
        pair.b = 2;

        expect(pair.a + pair.b).toBe(3);
    }

    test("should align the value for its type") {
        const pair = try create<Pair>(testing.allocator);
        defer destroy(testing.allocator, pair);

        unsafe {
            expect(aligned(@ptrCast(u8[*], pair), @alignOf(Pair))).toBe(true);
        }
    }

    test("should throw OutOfMemory when the allocator returns null") {
        let none = Exhausted {};

        expect(create<Pair>(&none)).toThrow(AllocError.OutOfMemory);
    }
}

describe("destroy") {
    test("should give the value back at the size of its type") {
        let debug = DebugAllocator.initUnguarded(testing.allocator);
        const a = debug.allocator();
        const pair = try create<Pair>(a);
        destroy(a, pair);

        expect(debug.count()).toBe(0);
        expect(debug.deinit()).toBe(0);
    }
}

describe("CAllocator") {
    describe("rawAlloc") {
        test("should hand out memory for an alignment up to 16") {
            let heap = CAllocator {};
            const raw = heap.rawAlloc(32, 16);

            expect(raw).not.toBeNull();
            unsafe {
                heap.rawFree(raw![0..32], 16);
            }
        }

        test("should return null for an alignment over 16") {
            let heap = CAllocator {};

            expect(heap.rawAlloc(32, 32)).toBeNull();
        }
    }

    describe("rawResize") {
        test("should keep the contents when it grows the block") {
            let heap = CAllocator {};
            unsafe {
                const raw = heap.rawAlloc(4, 1)!;
                raw[0] = 42;
                const grown = heap.rawResize(raw[0..4], 64, 1)!;

                expect(grown[0]).toBe(42);
                heap.rawFree(grown[0..64], 1);
            }
        }

        test("should return null for an alignment over 16") {
            let heap = CAllocator {};
            let one: u8[1] = [1];

            expect(heap.rawResize(&one, 2, 32)).toBeNull();
        }
    }

    describe("rawFree") {
        test("should give a block back to the C heap") {
            let heap = CAllocator {};
            const raw = heap.rawAlloc(8, 8);
            unsafe {
                heap.rawFree(raw![0..8], 8);
            }

            expect(raw).not.toBeNull();
        }
    }
}

describe("cAllocator") {
    test("should hand out memory that free gives back") {
        const a = cAllocator();
        const items = try alloc<u64>(a, 4);
        items[3] = 9;

        expect(items[3]).toBe(9);
        free(a, items);
    }
}

describe("ArenaAllocator") {
    describe("init") {
        test("should start without any chunks") {
            const arena = ArenaAllocator.init(testing.allocator);

            expect(arena.chunks.items.len).toBe(0);
            expect(arena.used).toBe(0);
        }
    }

    describe("allocator") {
        test("should hand out memory from the arena") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const items = try alloc<u8>(arena.allocator(), 10);

            expect(items.len).toBe(10);
            expect(arena.used).toBe(10);
        }
    }

    describe("deinit") {
        test("should give every chunk back and leave the arena empty") {
            let arena = ArenaAllocator.init(testing.allocator);
            void try alloc<u8>(arena.allocator(), 5000);
            void try alloc<u8>(arena.allocator(), 9000);
            arena.deinit();

            expect(arena.chunks.items.len).toBe(0);
            expect(arena.used).toBe(0);
        }

        test("should leave the arena ready for new allocations") {
            let arena = ArenaAllocator.init(testing.allocator);
            void try alloc<u8>(arena.allocator(), 5);
            arena.deinit();
            void try alloc<u8>(arena.allocator(), 7);

            expect(arena.used).toBe(7);
            arena.deinit();
        }
    }

    describe("rawAlloc") {
        test("should take a first chunk of 4096 bytes") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            void arena.rawAlloc(10, 1);

            expect(arena.chunks.items.len).toBe(1);
            expect(arena.chunks.items[0].len).toBe(4096);
        }

        test("should place the next allocation after the last one in the same chunk") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const first = arena.rawAlloc(10, 1)!;
            const second = arena.rawAlloc(6, 1)!;

            expect(@intFromPtr(second) - @intFromPtr(first)).toBe(10);
            expect(arena.chunks.items.len).toBe(1);
        }

        test("should round the offset up to the alignment") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            void arena.rawAlloc(3, 1);
            const raw = arena.rawAlloc(8, 8)!;

            expect(aligned(raw, 8)).toBe(true);
            expect(arena.used).toBe(16);
        }

        test("should take a chunk twice the size of the last one when a request does not fit") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            void arena.rawAlloc(4000, 1);
            void arena.rawAlloc(200, 1);

            expect(arena.chunks.items.len).toBe(2);
            expect(arena.chunks.items[1].len).toBe(8192);
            expect(arena.used).toBe(200);
        }

        test("should take a chunk the size of a request bigger than twice the last chunk") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            void arena.rawAlloc(10000, 1);

            expect(arena.chunks.items[0].len).toBe(10000);
        }

        test("should return null for an alignment over 16") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();

            expect(arena.rawAlloc(8, 32)).toBeNull();
        }

        test("should return null when the backing allocator has no memory left") {
            let none = Exhausted {};
            let arena = ArenaAllocator.init(&none);

            expect(arena.rawAlloc(8, 8)).toBeNull();
            expect(arena.chunks.items.len).toBe(0);
        }
    }

    describe("rawResize") {
        test("should return the same pointer when it shrinks") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            unsafe {
                const raw = arena.rawAlloc(8, 1)!;
                const shrunk = arena.rawResize(raw[0..8], 4, 1)!;

                expect(@intFromPtr(shrunk)).toBe(@intFromPtr(raw));
            }
        }

        test("should copy the bytes into a new allocation when it grows") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            unsafe {
                const raw = arena.rawAlloc(2, 1)!;
                raw[0] = 5;
                raw[1] = 6;
                const grown = arena.rawResize(raw[0..2], 4, 1)!;

                expect(@intFromPtr(grown)).not.toBe(@intFromPtr(raw));
                expect(grown[0]).toBe(5);
                expect(grown[1]).toBe(6);
            }
        }
    }

    describe("rawFree") {
        test("should leave the memory in the arena until deinit") {
            let arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const items = try alloc<u8>(a, 4);
            items[0] = 9;
            free(a, items);

            expect(items[0]).toBe(9);
            expect(arena.used).toBe(4);
        }
    }
}

describe("DebugAllocator") {
    describe("init") {
        test("should start guarded with no live blocks") {
            let debug = DebugAllocator.init(testing.allocator);

            expect(debug.guarded).toBe(true);
            expect(debug.count()).toBe(0);
            expect(debug.deinit()).toBe(0);
        }
    }

    describe("initUnguarded") {
        test("should start unguarded with no live blocks") {
            let debug = DebugAllocator.initUnguarded(testing.allocator);

            expect(debug.guarded).toBe(false);
            expect(debug.count()).toBe(0);
            expect(debug.deinit()).toBe(0);
        }
    }

    describe("allocator") {
        test("should record what it hands out") {
            let debug = DebugAllocator.init(testing.allocator);
            const a = debug.allocator();
            const items = try alloc<u8>(a, 3);

            expect(debug.count()).toBe(1);
            free(a, items);
            expect(debug.deinit()).toBe(0);
        }
    }

    describe("deinit") {
        test("should return the number of leaks and free them") {
            let debug = DebugAllocator.initUnguarded(testing.allocator);
            void try alloc<u8>(debug.allocator(), 4);
            void try alloc<u8>(debug.allocator(), 8);

            expect(debug.deinit()).toBe(2);
            expect(debug.live.items.len).toBe(0);
        }
    }

    describe("count") {
        test("should follow allocations and frees") {
            let debug = DebugAllocator.init(testing.allocator);
            const a = debug.allocator();
            const first = try alloc<u8>(a, 1);
            const second = try alloc<u8>(a, 2);
            free(a, first);

            expect(debug.count()).toBe(1);
            free(a, second);
            expect(debug.deinit()).toBe(0);
        }
    }

    describe("take") {
        test("should not record the block it takes") {
            let debug = DebugAllocator.initUnguarded(testing.allocator);
            const raw = debug.take(8, 8)!;

            expect(debug.count()).toBe(0);
            unsafe {
                debug.release(raw[0..8], 8);
            }
            expect(debug.deinit()).toBe(0);
        }
    }

    describe("release") {
        test("should give an unguarded block back to the backing allocator") {
            let inner = DebugAllocator.initUnguarded(testing.allocator);
            let debug = DebugAllocator.initUnguarded(inner.allocator());
            const raw = debug.take(8, 8)!;
            unsafe {
                debug.release(raw[0..8], 8);
            }

            expect(inner.count()).toBe(0);
            expect(debug.deinit()).toBe(0);
            expect(inner.deinit()).toBe(0);
        }
    }

    describe("rawAlloc") {
        test("should fill new memory with 0xAA") {
            let debug = DebugAllocator.init(testing.allocator);
            const a = debug.allocator();
            const items = try alloc<u8>(a, 4);

            expect(items).toEqual([0xAA, 0xAA, 0xAA, 0xAA]);
            free(a, items);
            expect(debug.deinit()).toBe(0);
        }

        test("should return null when the backing allocator has no memory left") {
            let none = Exhausted {};
            let debug = DebugAllocator.initUnguarded(&none);

            expect(debug.rawAlloc(4, 1)).toBeNull();
            expect(debug.count()).toBe(0);
        }
    }

    describe("rawResize") {
        test("should move the block and keep its contents") {
            let debug = DebugAllocator.init(testing.allocator);
            const a = debug.allocator();
            let items = try alloc<u8>(a, 2);
            items[0] = 1;
            items[1] = 2;
            const before = @intFromPtr(items.ptr);
            items = try resize(a, items, 4);

            expect(@intFromPtr(items.ptr)).not.toBe(before);
            expect(items).toEqual([1, 2, 0xAA, 0xAA]);
            expect(debug.count()).toBe(1);
            free(a, items);
            expect(debug.deinit()).toBe(0);
        }

        test("should move the block when it shrinks") {
            let debug = DebugAllocator.init(testing.allocator);
            const a = debug.allocator();
            let items = try alloc<u8>(a, 4);
            items[0] = 3;
            const before = @intFromPtr(items.ptr);
            items = try resize(a, items, 1);

            expect(@intFromPtr(items.ptr)).not.toBe(before);
            expect(items).toEqual([3]);
            free(a, items);
            expect(debug.deinit()).toBe(0);
        }
    }

    describe("rawFree") {
        test("should keep the other live blocks after it frees one in the middle") {
            let debug = DebugAllocator.initUnguarded(testing.allocator);
            const a = debug.allocator();
            const first = try alloc<u8>(a, 1);
            const second = try alloc<u8>(a, 2);
            const third = try alloc<u8>(a, 3);
            free(a, second);

            expect(debug.count()).toBe(2);
            free(a, first);
            free(a, third);
            expect(debug.deinit()).toBe(0);
        }
    }

    describe("find") {
        test("should return the index of a live block") {
            let debug = DebugAllocator.initUnguarded(testing.allocator);
            const a = debug.allocator();
            const first = try alloc<u8>(a, 1);
            const second = try alloc<u8>(a, 2);

            expect(debug.find(first)).toBe(0);
            expect(debug.find(second)).toBe(1);
            free(a, first);
            free(a, second);
            expect(debug.deinit()).toBe(0);
        }
    }
}
