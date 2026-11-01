// expect-error: `toBee` isn't a matcher
// expect-error: `toBe` compares with `==`, which `Point` doesn't have
// expect-error: `toBeNull` needs an optional (`?T`), but this is `integer literal`
// expect-error: `toThrow` needs a call that can fail (`T | Error`), but this is `i32`
// expect-error: `toBeGreaterThan` needs a number, but this is `bool`
// expect-error: `toStartWith` needs a string, but this is `integer literal`
// expect-error: `toHaveLength` needs a slice, array or string, but this is `integer literal`
// expect-error: `toContain` compares items with `==`, which `Point` doesn't have
// expect-error: `toBe` takes one argument
// expect-error: `toBeNull` takes no arguments
// expect-error: `expect` takes the one value to check
// expect-error: `toThrow` takes an error, like `MyError.Case`, but this is `integer literal`
// expect-error: unknown function `expect`
// expect-error: the error from `toBe` is not handled
// expect-error: expected `i64`, found `bool`
// expect-error: unknown function `expect`
// expect-error: unused local `unused`
// expect-error: `expect` checks run with the test, not while compiling

struct Point {
    x: i32,
}

function plain(): i32 {
    expect(1).toBe(1);
    return 1;
}

describe("matchers") {
    let unused: i32 = 0;

    test("should reject what doesn't fit") {
        const p = Point { x: 1 };
        const points: Point[1] = [p];
        const none: ?i32 = null;
        expect(1).toBee(1);
        expect(p).toBe(p);
        expect(1).toBeNull();
        expect(plain()).toThrow();
        expect(true).toBeGreaterThan(false);
        expect(1).toStartWith("a");
        expect(1).toHaveLength(1);
        expect(points).toContain(p);
        expect(1).toBe();
        expect(none).toBeNull(1);
        expect(1, 2).toBe(1);
        expect(plain()).not.toBe(2);
    }

    test("should check arguments") {
        const fails: i32 | Error = 1;
        expect(fails).toThrow(5);
        require(1).toBe(1);
        expect(1).toBe(true);
        expect(1);
        comptime {
            expect(1).toBe(1);
        }
    }
}
