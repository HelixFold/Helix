/**
 * The names of the build modes, indexed by their number.
 *
 * @remarks
 * {@link hxModeParse} reads a name by its place in this list.
 *
 * @example
 * ```hx
 * ModeNames[ModeReleaseSafe]; // "release-safe"
 * ```
 *
 * @see ModeCnames
 * @since 1.0.0
 */

export const ModeNames: string[4] = ["debug", "release-safe", "release-fast", "release-small"];

/**
 * The names of the build modes as C strings, indexed by their number.
 *
 * @remarks
 * {@link hxModeName} hands these to C callers.
 *
 * @example
 * ```hx
 * ModeCnames[ModeDebug]; // "debug"
 * ```
 *
 * @see ModeNames
 * @since 1.0.0
 */

export const ModeCnames: (readonly u8[*])[4] = ["debug", "release-safe", "release-fast", "release-small"];

/**
 * The kind of a test table row that opens a `describe`.
 *
 * @remarks
 * The kinds match the `ENTRY_` values of the test runtime.
 *
 * @example
 * ```hx
 * TestEntryDescribe; // 0
 * ```
 *
 * @see TestEntryEnd
 * @since 1.0.0
 */

export const TestEntryDescribe: u32 = 0;

/**
 * The kind of a test table row that closes a `describe` and carries its `afterAll` hooks.
 *
 * @example
 * ```hx
 * TestEntryEnd; // 1
 * ```
 *
 * @see TestEntryDescribe
 * @since 1.0.0
 */

export const TestEntryEnd: u32 = 1;

/**
 * The kind of a test table row that holds one test.
 *
 * @example
 * ```hx
 * TestEntryTest; // 2
 * ```
 *
 * @since 1.0.0
 */

export const TestEntryTest: u32 = 2;

/**
 * The operator of a `beforeAll` hook node.
 *
 * @remarks
 * The parser numbers the hooks `beforeAll`, `afterAll`, `beforeEach`, and `afterEach`,
 * so the `afterAll` hook is 1 and is whatever the other three are not.
 *
 * @example
 * ```hx
 * HookBeforeAll; // 0
 * ```
 *
 * @since 1.0.0
 */

export const HookBeforeAll: u16 = 0;

/**
 * The operator of a `beforeEach` hook node.
 *
 * @example
 * ```hx
 * HookBeforeEach; // 2
 * ```
 *
 * @since 1.0.0
 */

export const HookBeforeEach: u16 = 2;

/**
 * The operator of an `afterEach` hook node.
 *
 * @example
 * ```hx
 * HookAfterEach; // 3
 * ```
 *
 * @since 1.0.0
 */

export const HookAfterEach: u16 = 3;
