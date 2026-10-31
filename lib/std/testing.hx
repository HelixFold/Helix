/**
 * Imports
 */

import { Allocator, DebugAllocator, cAllocator } from "./heap";

/**
 * The error that `require(...)` returns when its check fails, so `try` stops the test.
 *
 * @remarks
 * `require` works like `expect`, except that a failed check also returns this error,
 * and `try require(...)` then ends the test at that line.
 *
 * @example
 * ```hx
 * try require(list.items.len).toBe(1); // fails with TestError.RequireFailed when the length is not 1
 * ```
 *
 * @since 1.0.0
 */

export error TestError {
    /**
     * A `require` check failed.
     *
     * @example
     * ```hx
     * @errorName(TestError.RequireFailed); // "RequireFailed"
     * ```
     *
     * @since 1.0.0
     */

    RequireFailed
}

/**
 * The leak checker behind {@link allocator}.
 *
 * @remarks
 * {@link beginTest} replaces it before each test and {@link endTest} reports what it still holds after the test.
 *
 * @since 1.0.0
 */

let debug: DebugAllocator = undefined;

/**
 * The allocator for tests, which fails a test that leaks.
 *
 * @remarks
 * A test build makes this module visible as `testing` without an import, so a spec writes `testing.allocator`.
 * Each test gets a fresh one, and memory that the test allocates and does not free fails the test.
 * The `describe`, `test`, `expect`, and `require` forms and the hooks are built into the language, not this module.
 *
 * @example
 * ```hx
 * const bytes = try alloc<u8>(testing.allocator, 8);
 * free(testing.allocator, bytes); // without this line the test fails with a leak
 * ```
 *
 * @since 1.0.0
 */

export let allocator: dyn Allocator = undefined;

/**
 * Starts the leak checker for a test.
 *
 * @remarks
 * A test build calls it before the hooks of each test.
 * It wraps the C heap in a fresh {@link DebugAllocator} and points {@link allocator} at it.
 *
 * @example
 * ```hx
 * beginTest();
 * allocator; // a fresh leak checker
 * ```
 *
 * @since 1.0.0
 */

export function beginTest(): void {
    debug = DebugAllocator.init(cAllocator());
    allocator = debug.allocator();
}

/**
 * Ends the leak checker of a test.
 *
 * @returns The number of allocations that the test never freed
 *
 * @remarks
 * A test build calls it after the hooks of each test, and a count above 0 fails the test.
 * Each leak is reported on stderr and then freed.
 *
 * @example
 * ```hx
 * beginTest();
 * void try alloc<u8>(allocator, 4);
 * endTest(); // 1, and stderr shows "leak: 4 bytes were never freed"
 * ```
 *
 * @since 1.0.0
 */

export function endTest(): usize {
    return debug.deinit();
}
