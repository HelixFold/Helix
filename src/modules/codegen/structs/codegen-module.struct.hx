/**
 * Imports
 */

import { Value, Type } from "@modules/codegen/components/structs/base-component.struct";

/**
 * The rows of the test table of a test build, as LLVM constants, while the code generator emits them.
 *
 * @remarks
 * Each row is a `helix.test.entry` struct that matches the `Entry` struct of the runtime:
 * the kind and mode, the title and expected panic message, the test or set-up function,
 * the `beforeEach` and `afterEach` functions, the place as `file:line:col`, and the timeout.
 * The rows become the private constant `helix.tests`, which the C `main` hands to `hx_test_main`.
 *
 * @example
 * ```hx
 * // describe("math") { test("adds") { ... } }
 * table.len; // 3: the describe, the test, and the end of the describe
 * ```
 *
 * @since 1.0.0
 */

export struct TestTable {
    /**
     * The LLVM struct type of a row, named `helix.test.entry`.
     *
     * @example
     * ```hx
     * table.entryType; // %helix.test.entry = type { i32, i32, ptr, ptr, ptr, ptr, ptr, ptr, i64 }
     * ```
     *
     * @since 1.0.0
     */

    entryType: Type,

    /**
     * The rows, on the C heap, or `null` before the first one.
     *
     * @example
     * ```hx
     * table.entries; // null until the first row
     * ```
     *
     * @since 1.0.0
     */

    entries: ?Value[*],

    /**
     * The number of rows.
     *
     * @example
     * ```hx
     * table.len; // 1 after the first test
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The number of rows that fit before the table grows.
     *
     * @example
     * ```hx
     * table.cap; // at least table.len
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,
}
