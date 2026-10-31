/**
 * Imports
 */

import { hxAlloc, hxZalloc, hxRealloc, hxStrndup, hxVecGrowImpl, free } from "@components/memory.component";

/**
 * Tests
 */

describe("hxAlloc") {
    test("should hand out a block that holds what is written to it") {
        const bytes = hxAlloc(4);
        unsafe {
            bytes[0] = 1;
            bytes[3] = 4;
            expect(bytes[0]).toBe(1);
            expect(bytes[3]).toBe(4);
        }

        free(bytes);
    }

    test("should hand out a block for a request of zero bytes") {
        const bytes = hxAlloc(0);

        expect(@intFromPtr(bytes)).not.toBe(0);
        free(bytes);
    }
}

describe("hxZalloc") {
    test("should hand out a block with every byte at zero") {
        const bytes = hxZalloc(64);
        unsafe {
            for (const i of 0..64) expect(bytes[i]).toBe(0);
        }

        free(bytes);
    }
}

describe("hxRealloc") {
    test("should allocate a new block when the pointer is null") {
        const bytes = hxRealloc(null, 8);

        expect(@intFromPtr(bytes)).not.toBe(0);
        free(bytes);
    }

    test("should keep the contents when a block grows") {
        let bytes = hxAlloc(2);
        unsafe {
            bytes[0] = 7;
            bytes[1] = 9;
        }
        bytes = hxRealloc(bytes, 4096);

        unsafe {
            expect(bytes[0]).toBe(7);
            expect(bytes[1]).toBe(9);
        }
        free(bytes);
    }
}

describe("hxStrndup") {
    test("should copy only the given number of bytes and end the copy with a NUL") {
        const copy = hxStrndup("main.hx", 4);

        unsafe {
            const text: string = copy[0..4];
            expect(text).toBe("main");
            expect(copy[4]).toBe(0);
        }
        free(copy);
    }

    test("should copy an empty text as a lone NUL") {
        const copy = hxStrndup("", 0);

        unsafe {
            expect(copy[0]).toBe(0);
        }
        free(copy);
    }
}

describe("hxVecGrowImpl") {
    test("should start an empty array at a capacity of eight") {
        let items: ?u8[*] = null;
        let cap: u32 = 0;
        hxVecGrowImpl(&items, &cap, 1, 4);

        expect(cap).toBe(8);
        free(items);
    }

    test("should at least double the capacity when it grows") {
        let items: ?u8[*] = null;
        let cap: u32 = 0;
        hxVecGrowImpl(&items, &cap, 1, 4);
        hxVecGrowImpl(&items, &cap, 9, 4);

        expect(cap).toBe(16);
        free(items);
    }

    test("should jump straight to the requested capacity when doubling falls short") {
        let items: ?u8[*] = null;
        let cap: u32 = 0;
        hxVecGrowImpl(&items, &cap, 100, 1);

        expect(cap).toBe(100);
        free(items);
    }

    test("should leave an array that is already large enough untouched") {
        let items: ?u8[*] = null;
        let cap: u32 = 0;
        hxVecGrowImpl(&items, &cap, 8, 4);
        const before = @intFromPtr(items);
        hxVecGrowImpl(&items, &cap, 5, 4);

        expect(cap).toBe(8);
        expect(@intFromPtr(items)).toBe(before);
        free(items);
    }
}
