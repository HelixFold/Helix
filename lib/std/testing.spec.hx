/**
 * Imports
 */

import { alloc, free } from "./heap";
import { TestError, allocator, beginTest, endTest } from "./testing";

/**
 * Tests
 */

describe("TestError") {
    test("should name the failure of a require") {
        const error: Error = TestError.RequireFailed;

        expect(@errorName(error)).toBe("RequireFailed");
    }

    test("should let the test go on after a require that passes") {
        let reached = false;
        try require(1 + 1).toBe(2);
        reached = true;

        expect(reached).toBeTrue();
    }
}

describe("allocator") {
    test("should hand out memory that the test can write and free") {
        const bytes = try alloc<u8>(allocator, 8);
        bytes[0] = 7;
        bytes[7] = 9;

        expect(bytes[0]).toBe(7);
        expect(bytes[7]).toBe(9);
        free(allocator, bytes);
    }

    test("should be the allocator that the implicit testing module hands out") {
        const bytes = try alloc<u8>(testing.allocator, 4);

        expect(bytes.len).toBe(4);
        free(allocator, bytes);
    }
}

describe("beginTest") {
    test("should start a fresh allocator without live allocations") {
        beginTest();
        const leaks = endTest();
        beginTest();

        expect(leaks).toBe(0);
    }
}

describe("endTest") {
    test("should count each allocation that the test never freed") {
        beginTest();
        void try alloc<u8>(allocator, 4);
        void try alloc<u8>(allocator, 16);
        const leaks = endTest();
        beginTest();

        expect(leaks).toBe(2);
    }

    test("should count nothing once the test freed everything") {
        beginTest();
        const bytes = try alloc<u8>(allocator, 4);
        free(allocator, bytes);
        const leaks = endTest();
        beginTest();

        expect(leaks).toBe(0);
    }
}
