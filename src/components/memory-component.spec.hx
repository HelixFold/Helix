/**
 * Imports
 */

import { hx_alloc, hx_zalloc, hx_realloc, hx_strndup, hx_vec_grow_impl, free } from "@components/memory.component";

/**
 * Tests
 */

describe("hx_alloc") {
    test("should hand out a block that holds what is written to it") {
        const bytes = hx_alloc(4);
        unsafe {
            bytes[0] = 1;
            bytes[3] = 4;
            expect(bytes[0]).toBe(1);
            expect(bytes[3]).toBe(4);
        }

        free(bytes);
    }

    test("should hand out a block for a request of zero bytes") {
        const bytes = hx_alloc(0);

        expect(@intFromPtr(bytes)).not.toBe(0);
        free(bytes);
    }
}

describe("hx_zalloc") {
    test("should hand out a block with every byte at zero") {
        const bytes = hx_zalloc(64);
        unsafe {
            for (const i of 0..64) expect(bytes[i]).toBe(0);
        }

        free(bytes);
    }
}

describe("hx_realloc") {
    test("should allocate a new block when the pointer is null") {
        const bytes = hx_realloc(null, 8);

        expect(@intFromPtr(bytes)).not.toBe(0);
        free(bytes);
    }

    test("should keep the contents when a block grows") {
        let bytes = hx_alloc(2);
        unsafe {
            bytes[0] = 7;
            bytes[1] = 9;
        }
        bytes = hx_realloc(bytes, 4096);

        unsafe {
            expect(bytes[0]).toBe(7);
            expect(bytes[1]).toBe(9);
        }
        free(bytes);
    }
}

describe("hx_strndup") {
    test("should copy only the given number of bytes and end the copy with a NUL") {
        const copy = hx_strndup("main.hx", 4);

        unsafe {
            const text: string = copy[0..4];
            expect(text).toBe("main");
            expect(copy[4]).toBe(0);
        }
        free(copy);
    }

    test("should copy an empty text as a lone NUL") {
        const copy = hx_strndup("", 0);

        unsafe {
            expect(copy[0]).toBe(0);
        }
        free(copy);
    }
}

describe("hx_vec_grow_impl") {
    test("should start an empty array at a capacity of eight") {
        let items: ?u8[*] = null;
        let cap: u32 = 0;
        hx_vec_grow_impl(&items, &cap, 1, 4);

        expect(cap).toBe(8);
        free(items);
    }

    test("should at least double the capacity when it grows") {
        let items: ?u8[*] = null;
        let cap: u32 = 0;
        hx_vec_grow_impl(&items, &cap, 1, 4);
        hx_vec_grow_impl(&items, &cap, 9, 4);

        expect(cap).toBe(16);
        free(items);
    }

    test("should jump straight to the requested capacity when doubling falls short") {
        let items: ?u8[*] = null;
        let cap: u32 = 0;
        hx_vec_grow_impl(&items, &cap, 100, 1);

        expect(cap).toBe(100);
        free(items);
    }

    test("should leave an array that is already large enough untouched") {
        let items: ?u8[*] = null;
        let cap: u32 = 0;
        hx_vec_grow_impl(&items, &cap, 8, 4);
        const before = @intFromPtr(items);
        hx_vec_grow_impl(&items, &cap, 5, 4);

        expect(cap).toBe(8);
        expect(@intFromPtr(items)).toBe(before);
        free(items);
    }
}
