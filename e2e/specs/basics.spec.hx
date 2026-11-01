// Everything here passes: fixtures and hooks, each matcher (and `.not`), `require`, `testing.allocator`, and the
// modifiers that change what passing means.
// expect-tests: 2 skipped, 1 todo, 17 passed, 20 total
// expect-output: PASS

import { ArrayList, alloc, free } from "std";

// top-level variables are globals, not fixtures
const BASE: i32 = 40;
let calls: i32 = 0;

error ParseError { Empty, Bad }

function parseDigit(text: string): u8 | ParseError {
    if (text.len == 0) throw ParseError.Empty;
    if (text[0] < '0' || text[0] > '9') throw ParseError.Bad;
    return text[0] - '0';
}

function check(text: string): void | ParseError {
    void try parseDigit(text);
}

struct Point {
    x: i32,
    y: i32,
}

union Shape {
    circle: f64,
    square: f64,
    dot,
}

enum Color { Red, Green }

test("should run a test outside any describe") {
    expect(1 + 1).toBe(2);
}

describe("fixtures") {
    let count: i32 = 1;
    let base: i32 = 0;

    beforeAll {
        base = BASE;
        calls += 1;
    }

    beforeEach {
        count += 1;
    }

    test("should see what beforeAll and beforeEach did") {
        expect(base).toBe(40);
        expect(count).toBe(2);
        expect(calls).toBe(1);
        count = 100;
        base = 100;
    }

    test("should get a fresh copy in every test") {
        expect(count).toBe(2);
        expect(base).toBe(40);
    }

    describe("nested") {
        let steps: i32 = 0;

        beforeEach {
            steps = count * 10;
        }

        it("should run outer beforeEach before inner") {
            expect(steps).toBe(20);
        }
    }
}

describe("ArrayList") {
    let list: ArrayList<i32> = undefined;

    beforeEach {
        list = ArrayList<i32>.init(testing.allocator);
    }

    afterEach {
        list.deinit();
    }

    test("should start empty") {
        expect(list.items).toHaveLength(0);
    }

    test("should keep items in insertion order") {
        try list.append(1);
        try list.append(2);
        expect(list.items).toEqual([1, 2]);
        expect(list.items).toContain(2);
        expect(list.items).not.toContain(3);
    }

    test("should free what it allocates") {
        const bytes = try alloc<u8>(testing.allocator, 32);
        free(testing.allocator, bytes);
    }

    test.panics("should stop on a read past the end", "index out of bounds") {
        void list.items[5];
    }
}

describe("matchers") {
    test("should compare scalars with toBe") {
        expect(3).toBe(3);
        expect(3).not.toBe(4);
        expect(2.5).toBe(2.5);
        expect(true).toBe(true);
        expect(Color.Green).toBe(Color.Green);
        expect("ada").toBe("ada");
        expect("ada").not.toBe("bob");
        const maybe: ?i32 = 5;
        expect(maybe).toBe(5);
    }

    test("should compare structures with toEqual") {
        expect(Point { x: 1, y: 2 }).toEqual(Point { x: 1, y: 2 });
        expect(Point { x: 1, y: 2 }).not.toEqual(Point { x: 2, y: 1 });
        const a: Shape = Shape.circle(1.5);
        expect(a).toEqual(Shape.circle(1.5));
        expect(a).not.toEqual(Shape.square(1.5));
        expect(Shape.dot).toEqual(Shape.dot);
        const grid: i32[2][2] = [[1, 2], [3, 4]];
        expect(grid).toEqual([[1, 2], [3, 4]]);
        const words: string[2] = ["a", "b"];
        expect(words).toEqual(["a", "b"]);
        expect(words).toContainEqual("b");
        const points: Point[1] = [Point { x: 0, y: 0 }];
        expect(points).toContainEqual(Point { x: 0, y: 0 });
    }

    test("should check optionals and bools") {
        const none: ?Point = null;
        const some: ?Point = Point { x: 1, y: 1 };
        expect(none).toBeNull();
        expect(some).toBeDefined();
        expect(some).not.toBeNull();
        expect(some).toEqual(Point { x: 1, y: 1 });
        expect(1 < 2).toBeTrue();
        expect(1 > 2).toBeFalse();
    }

    test("should compare numbers") {
        expect(5).toBeGreaterThan(4);
        expect(5).toBeGreaterThanOrEqual(5);
        expect(-1).toBeLessThan(0);
        expect(0.1 + 0.2).not.toBe(0.3);
        expect(0.1 + 0.2).toBeCloseTo(0.3);
        expect(3.14159).toBeCloseTo(3.14, 2);
        expect(3.14159).not.toBeCloseTo(3.14, 4);
    }

    test("should check strings") {
        expect("hello.hx").toStartWith("hello");
        expect("hello.hx").toEndWith(".hx");
        expect("hello.hx").toInclude("lo.h");
        expect("hello.hx").toMatch("*.hx");
        expect("hello.hx").not.toMatch("*.c");
        expect("hello").toHaveLength(5);
    }

    test("should check errors") {
        expect(parseDigit("")).toThrow(ParseError.Empty);
        expect(parseDigit("x")).toThrow();
        expect(parseDigit("x")).not.toThrow(ParseError.Empty);
        expect(parseDigit("7")).toSucceed();
        expect(parseDigit("7")).toEqual(7);
        expect(check("")).toThrow(ParseError.Empty);
        expect(try parseDigit("7")).toBe(7);
    }

    test("should go on after require passes") {
        const digits: u8[3] = [1, 2, 3];
        try require(digits).toHaveLength(3);
        expect(digits[2]).toBe(3);
    }
}

describe("modifiers") {
    test.skip("should not run a skipped test") {
        expect(1).toBe(2);
    }

    test.todo("should list a todo");

    test.failing("should pass when a known bug still fails") {
        expect(1 + 1).toBe(3);
    }

    test.panics("should pass when the panic matches", "integer overflow") {
        let n: u8 = 255;
        n += 1;
    }

    describe.skip("skipped block") {
        test("should not run either") {
            expect(1).toBe(2);
        }
    }
}
