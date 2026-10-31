/**
 * The names of the test matchers, in the order of {@link Matcher}.
 *
 * @remarks
 * The order also matches `HxMatcher` in the C header `sema.h`,
 * since the checker stores the index of the matcher for code generation.
 *
 * @example
 * ```hx
 * Matchers[0];  // "toBe"
 * Matchers[19]; // "toSucceed"
 * ```
 *
 * @see Matcher
 * @since 1.0.0
 */

export const Matchers: string[20] = [
    "toBe", "toEqual", "toBeNull", "toBeDefined", "toBeTrue", "toBeFalse", "toBeGreaterThan", "toBeGreaterThanOrEqual",
    "toBeLessThan", "toBeLessThanOrEqual", "toBeCloseTo", "toHaveLength", "toContain", "toContainEqual", "toStartWith",
    "toEndWith", "toInclude", "toMatch", "toThrow", "toSucceed",
];

/**
 * The test matchers, numbered in the order of {@link Matchers}.
 *
 * @remarks
 * The checker records the number of the matcher on the call node,
 * together with the flags for `.not` and `require`.
 *
 * @example
 * ```hx
 * Matcher.ToBe as u32;    // 0
 * Matcher.Succeed as u32; // 19
 * ```
 *
 * @see Matchers
 * @since 1.0.0
 */

export enum Matcher: u32 {
    /**
     * The `toBe` matcher, which checks that the value equals the argument with `==`.
     *
     * @remarks
     * It needs a type that `==` compares, and points to `toEqual` for one that only compares field by field.
     *
     * @example
     * ```hx
     * expect(count).toBe(3);   // Matcher.ToBe, number 0
     * ```
     *
     * @since 1.0.0
     */

    ToBe,

    /**
     * The `toEqual` matcher, which checks that the value equals the argument field by field or element by element.
     *
     * @example
     * ```hx
     * expect(point).toEqual(Point { x: 1, y: 2 });   // Matcher.ToEqual, number 1
     * ```
     *
     * @since 1.0.0
     */

    ToEqual,

    /**
     * The `toBeNull` matcher, which checks that an optional holds `null`.
     *
     * @remarks
     * It takes no argument, and the value must be an optional.
     *
     * @example
     * ```hx
     * expect(find(id)).toBeNull();   // Matcher.ToBeNull, number 2
     * ```
     *
     * @since 1.0.0
     */

    ToBeNull,

    /**
     * The `toBeDefined` matcher, which checks that an optional holds a value.
     *
     * @remarks
     * It takes no argument, and the value must be an optional.
     *
     * @example
     * ```hx
     * expect(find(id)).toBeDefined();   // Matcher.ToBeDefined, number 3
     * ```
     *
     * @since 1.0.0
     */

    ToBeDefined,

    /**
     * The `toBeTrue` matcher, which checks that a `bool` is `true`.
     *
     * @example
     * ```hx
     * expect(ready).toBeTrue();   // Matcher.ToBeTrue, number 4
     * ```
     *
     * @since 1.0.0
     */

    ToBeTrue,

    /**
     * The `toBeFalse` matcher, which checks that a `bool` is `false`.
     *
     * @example
     * ```hx
     * expect(ready).toBeFalse();   // Matcher.ToBeFalse, number 5
     * ```
     *
     * @since 1.0.0
     */

    ToBeFalse,

    /**
     * The `toBeGreaterThan` matcher, which checks that a number is greater than the argument.
     *
     * @example
     * ```hx
     * expect(size).toBeGreaterThan(0);   // Matcher.Greater, number 6
     * ```
     *
     * @since 1.0.0
     */

    Greater,

    /**
     * The `toBeGreaterThanOrEqual` matcher, which checks that a number is greater than or equal to the argument.
     *
     * @example
     * ```hx
     * expect(size).toBeGreaterThanOrEqual(1);   // Matcher.GreaterEqual, number 7
     * ```
     *
     * @since 1.0.0
     */

    GreaterEqual,

    /**
     * The `toBeLessThan` matcher, which checks that a number is less than the argument.
     *
     * @example
     * ```hx
     * expect(size).toBeLessThan(10);   // Matcher.Less, number 8
     * ```
     *
     * @since 1.0.0
     */

    Less,

    /**
     * The `toBeLessThanOrEqual` matcher, which checks that a number is less than or equal to the argument.
     *
     * @example
     * ```hx
     * expect(size).toBeLessThanOrEqual(9);   // Matcher.LessEqual, number 9
     * ```
     *
     * @since 1.0.0
     */

    LessEqual,

    /**
     * The `toBeCloseTo` matcher, which checks that a float is close to the argument.
     *
     * @remarks
     * An optional second argument gives the number of digits to compare.
     *
     * @example
     * ```hx
     * expect(ratio).toBeCloseTo(0.33, 2);   // Matcher.CloseTo, number 10
     * ```
     *
     * @since 1.0.0
     */

    CloseTo,

    /**
     * The `toHaveLength` matcher, which checks the length of a slice, an array, or a string.
     *
     * @example
     * ```hx
     * expect(items).toHaveLength(3);   // Matcher.Length, number 11
     * ```
     *
     * @since 1.0.0
     */

    Length,

    /**
     * The `toContain` matcher, which checks that a slice or an array holds an item equal to the argument with `==`.
     *
     * @example
     * ```hx
     * expect(ids).toContain(7);   // Matcher.Contain, number 12
     * ```
     *
     * @since 1.0.0
     */

    Contain,

    /**
     * The `toContainEqual` matcher,
     * which checks that a slice or an array holds an item equal to the argument field by field.
     *
     * @example
     * ```hx
     * expect(points).toContainEqual(Point { x: 1, y: 2 });   // Matcher.ContainEqual, number 13
     * ```
     *
     * @since 1.0.0
     */

    ContainEqual,

    /**
     * The `toStartWith` matcher, which checks that a string starts with the argument.
     *
     * @example
     * ```hx
     * expect(path).toStartWith("src/");   // Matcher.StartWith, number 14
     * ```
     *
     * @since 1.0.0
     */

    StartWith,

    /**
     * The `toEndWith` matcher, which checks that a string ends with the argument.
     *
     * @example
     * ```hx
     * expect(path).toEndWith(".hx");   // Matcher.EndWith, number 15
     * ```
     *
     * @since 1.0.0
     */

    EndWith,

    /**
     * The `toInclude` matcher, which checks that a string contains the argument.
     *
     * @example
     * ```hx
     * expect(message).toInclude("never closed");   // Matcher.Include, number 16
     * ```
     *
     * @since 1.0.0
     */

    Include,

    /**
     * The `toMatch` matcher, which checks that a string matches the argument.
     *
     * @example
     * ```hx
     * expect(version).toMatch("1.0");   // Matcher.Match, number 17
     * ```
     *
     * @since 1.0.0
     */

    Match,

    /**
     * The `toThrow` matcher, which checks that a call that can fail returns an error.
     *
     * @remarks
     * The argument, when given, is the error that it must return.
     *
     * @example
     * ```hx
     * expect(parse("")).toThrow(ParseError.Empty);   // Matcher.Throw, number 18
     * ```
     *
     * @since 1.0.0
     */

    Throw,

    /**
     * The `toSucceed` matcher, which checks that a call that can fail returns a value.
     *
     * @remarks
     * It takes no argument.
     *
     * @example
     * ```hx
     * expect(parse("1")).toSucceed();   // Matcher.Succeed, number 19
     * ```
     *
     * @since 1.0.0
     */

    Succeed,
}
