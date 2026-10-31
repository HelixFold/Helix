/**
 * Imports
 */

import { free, malloc, memcpy, realloc, strlen } from "./c";

/**
 * Tests
 */

describe("free") {
    test("should accept null and do nothing") {
        free(null);

        expect(true).toBeTrue();
    }
}

describe("malloc") {
    test("should return writable memory of the given size") {
        const raw = malloc(4);

        expect(raw).toBeDefined();
        unsafe {
            raw![0] = 9;
            raw![3] = 8;
            expect(raw![0]).toBe(9);
            expect(raw![3]).toBe(8);
        }
        free(raw);
    }
}

describe("strlen") {
    test("should count the bytes before the first NUL") {
        const text = "abc\0def";

        expect(strlen(text.ptr)).toBe(3);
    }

    test("should return 0 for a string that starts with a NUL") {
        const text = "\0abc";

        expect(strlen(text.ptr)).toBe(0);
    }
}

describe("realloc") {
    test("should keep the contents when it grows the memory") {
        const raw = malloc(2);
        unsafe {
            raw![0] = 5;
            raw![1] = 6;
        }
        const grown = realloc(raw, 64);

        unsafe {
            expect(grown![0]).toBe(5);
            expect(grown![1]).toBe(6);
        }
        free(grown);
    }

    test("should allocate fresh memory for a null pointer") {
        const raw = realloc(null, 8);

        expect(raw).toBeDefined();
        free(raw);
    }
}

describe("memcpy") {
    test("should copy the given count of bytes and return the destination") {
        let buffer: u8[4] = [0, 0, 0, 0];
        const dest: u8[] = buffer[0..4];
        const source: string = "wxyz";
        const back = memcpy(dest.ptr, source.ptr, 3);
        const text: string = dest;

        expect(text).toBe("wxy\0");
        unsafe {
            expect(back == dest.ptr).toBeTrue();
        }
    }
}
