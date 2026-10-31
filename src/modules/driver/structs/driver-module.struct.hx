/**
 * The numbers of tests by result, for one spec or for a whole `helix test` run.
 *
 * @remarks
 * Each test binary writes its counts to a summary file, and the driver adds them up across specs.
 *
 * @example
 * ```hx
 * const counts = TestCounts { passed: 3, failed: 0, panicked: 0, skipped: 1, todo: 0 };
 * ```
 *
 * @since 1.0.0
 */

export struct TestCounts {
    /**
     * The number of tests that passed.
     *
     * @example
     * ```hx
     * counts.passed; // 3
     * ```
     *
     * @since 1.0.0
     */

    passed: i64,

    /**
     * The number of tests with a failing expectation.
     *
     * @example
     * ```hx
     * counts.failed; // 0
     * ```
     *
     * @since 1.0.0
     */

    failed: i64,

    /**
     * The number of tests that panicked.
     *
     * @example
     * ```hx
     * counts.panicked; // 0
     * ```
     *
     * @since 1.0.0
     */

    panicked: i64,

    /**
     * The number of tests marked to skip.
     *
     * @example
     * ```hx
     * counts.skipped; // 1
     * ```
     *
     * @since 1.0.0
     */

    skipped: i64,

    /**
     * The number of tests marked as todo.
     *
     * @example
     * ```hx
     * counts.todo; // 0
     * ```
     *
     * @since 1.0.0
     */

    todo: i64,
}
