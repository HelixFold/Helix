// Each test fails in a different way, and every matcher is made to fail at least once, so a matcher that always
// passed would show up here as a missing failure.
// expect-tests: 13 failed, 1 panicked, 0 passed, 14 total
// expect-output: FAIL
// expect-output: ✗ matchers › should fail toBe
// expect-output: expect(1 + 1).toBe(3)
// expect-output: Expected: 3
// expect-output: Received: 2
// expect-output: Expected: not "ada"
// expect-output: Expected: { x: 1, y: 3 }
// expect-output: Received: { x: 1, y: 2 }
// expect-output: Expected: circle(2)
// expect-output: Expected: [1, 2]
// expect-output: Received: [1, 2, 3]
// expect-output: Expected: null
// expect-output: Expected: a value
// expect-output: Expected: > 9
// expect-output: Expected: close to 3.2
// expect-output: Expected length: 2
// expect-output: Received length: 3
// expect-output: Expected: to contain 9
// expect-output: Expected: to start with "x"
// expect-output: Expected: to match "*.c"
// expect-output: Expected: error Bad
// expect-output: Received: 7
// expect-output: Expected: success
// expect-output: Received: error Empty
// expect-output: error: Empty
// expect-output: panic: integer overflow
// expect-output: testing.allocator: 1 allocation was never freed
// expect-output: leak: 4 bytes were never freed
// expect-output: is marked `.failing`, but it passed
// expect-output: expected a panic with "out of bounds", but the test finished without one
// expect-output: beforeAll or a fixture failed with error: Empty; 2 tests didn't run
// expect-output: printed before the failure
// expect-output: timed out after

import { alloc } from "std";

error ParseError { Empty, Bad }

function parseDigit(text: string): u8 | ParseError {
    if (text.len == 0) throw ParseError.Empty;
    if (text[0] < '0' || text[0] > '9') throw ParseError.Bad;
    return text[0] - '0';
}

struct Point {
    x: i32,
    y: i32,
}

union Shape {
    circle: f64,
    square: f64,
}

function forever(): void {
    let n: u64 = 0;
    while (true) n +%= 1;
}

describe("matchers") {
    test("should fail toBe") {
        expect(1 + 1).toBe(3);
        expect("ada").not.toBe("ada");
        expect(true).toBeFalse();
        expect(false).toBeTrue();
    }

    test("should fail toEqual") {
        expect(Point { x: 1, y: 2 }).toEqual(Point { x: 1, y: 3 });
        const shape: Shape = Shape.square(2.0);
        expect(shape).toEqual(Shape.circle(2.0));
        const items: i32[3] = [1, 2, 3];
        expect(items[0..3]).toEqual([1, 2]);
        expect(items).toContain(9);
        expect(items).toHaveLength(2);
    }

    test("should fail on optionals and numbers") {
        const some: ?i32 = 1;
        const none: ?i32 = null;
        expect(some).toBeNull();
        expect(none).toBeDefined();
        expect(5).toBeGreaterThan(9);
        expect(5).toBeLessThan(2);
        expect(3.14159).toBeCloseTo(3.2);
    }

    test("should fail on strings") {
        expect("hello").toStartWith("x");
        expect("hello").toEndWith("x");
        expect("hello").toInclude("x");
        expect("hello.hx").toMatch("*.c");
    }

    test("should fail on errors") {
        expect(parseDigit("7")).toThrow(ParseError.Bad);
        expect(parseDigit("")).toSucceed();
        expect(parseDigit("")).not.toThrow();
    }
}

describe("outcomes") {
    test("should fail with an escaping error") {
        void try parseDigit("");
    }

    test("should stop at a failed require") {
        println("printed before the failure");
        try require(1).toBe(2);
        println("never printed");
    }

    test("should fail with a panic") {
        let n: u8 = 255;
        n += 1;
    }

    test("should fail with a leak") {
        void try alloc<u8>(testing.allocator, 4);
    }

    test("should fail when it runs too long", { timeout: 100 }) {
        forever();
    }

    test.failing("should fail when a failing test passes") {
        expect(1).toBe(1);
    }

    test.panics("should fail when the panic is missing", "out of bounds") {
        expect(1).toBe(1);
    }
}

describe("setup") {
    beforeAll {
        void try parseDigit("");
    }

    test("should not run") {
        expect(1).toBe(1);
    }

    test("should not run either") {
        expect(1).toBe(1);
    }
}
