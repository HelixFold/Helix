/**
 * Imports
 */

import { CHUNK_SIZE } from "@constants/arena.constant";
import { HxArena } from "@services/structs/arena-service.struct";
import { hx_arena_alloc, hx_arena_strndup, hx_arena_free } from "@services/arena.service";

/**
 * Tests
 */

describe("hx_arena_alloc") {
    test("should create the first chunk on the first request") {
        let arena = HxArena { head: null };
        void hx_arena_alloc(&arena, 24, 8);

        expect(arena.head).not.toBeNull();
        hx_arena_free(&arena);
    }

    test("should align each block by its address") {
        let arena = HxArena { head: null };
        void hx_arena_alloc(&arena, 1, 1);
        const block = hx_arena_alloc(&arena, 16, 16);

        expect(@intFromPtr(block) % 16).toBe(0);
        hx_arena_free(&arena);
    }

    test("should hand out blocks that do not overlap") {
        let arena = HxArena { head: null };
        const a = hx_arena_alloc(&arena, 8, 8);
        const b = hx_arena_alloc(&arena, 8, 8);

        expect(@intFromPtr(b) >= @intFromPtr(a) + 8).toBe(true);
        hx_arena_free(&arena);
    }

    test("should serve small requests from the same chunk") {
        let arena = HxArena { head: null };
        void hx_arena_alloc(&arena, 8, 8);
        const first = arena.head;
        void hx_arena_alloc(&arena, 8, 8);

        expect(arena.head).toBe(first);
        hx_arena_free(&arena);
    }

    test("should give a request larger than a chunk a chunk of its own") {
        let arena = HxArena { head: null };
        void hx_arena_alloc(&arena, CHUNK_SIZE * 2, 8);

        expect(arena.head!.cap >= CHUNK_SIZE * 2).toBe(true);
        hx_arena_free(&arena);
    }

    test("should start a new chunk when the newest one is full") {
        let arena = HxArena { head: null };
        void hx_arena_alloc(&arena, CHUNK_SIZE - 8, 8);
        const first = arena.head;
        void hx_arena_alloc(&arena, 64, 8);

        expect(arena.head).not.toBe(first);
        expect(arena.head!.next).toBe(first);
        hx_arena_free(&arena);
    }
}

describe("hx_arena_strndup") {
    test("should copy only the given number of bytes and end the copy with a NUL") {
        let arena = HxArena { head: null };
        const copy = hx_arena_strndup(&arena, "main.hx", 4);

        unsafe {
            const text: string = copy[0..4];
            expect(text).toBe("main");
            expect(copy[4]).toBe(0);
        }
        hx_arena_free(&arena);
    }
}

describe("hx_arena_free") {
    test("should leave the arena empty") {
        let arena = HxArena { head: null };
        void hx_arena_alloc(&arena, 100, 8);
        hx_arena_free(&arena);

        expect(arena.head).toBeNull();
    }

    test("should leave the arena ready for new requests") {
        let arena = HxArena { head: null };
        void hx_arena_alloc(&arena, 100, 8);
        hx_arena_free(&arena);
        void hx_arena_alloc(&arena, 100, 8);

        expect(arena.head).not.toBeNull();
        hx_arena_free(&arena);
    }
}
