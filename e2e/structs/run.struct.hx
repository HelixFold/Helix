/**
 * Imports
 */

import { Allocator } from "std/heap";
import { ArrayList } from "std/list";

/**
 * The state of one run of the end-to-end checks.
 *
 * @remarks
 * Every check adds to `passed` or `failed`, or notes why it was skipped,
 * and `main` ends with a failing status when `failed` is not 0.
 * All memory comes from one arena that lives as long as the run.
 *
 * @example
 * ```hx
 * let run = Run { a, compiler: "/repo/.helix-out/bin/helix", filter: "", temp: "/tmp/helix-e2e-42", ... };
 * pass(&run, "e2e/programs/hello.hx", "debug");
 * run.passed; // 1
 * ```
 *
 * @since 1.0.0
 */

export struct Run {
    /**
     * The allocator of the run, an arena that `main` frees at the end.
     *
     * @example
     * ```hx
     * const text = try fmt.alloc(run.a, `${count}`);
     * ```
     *
     * @since 1.0.0
     */

    a: dyn Allocator,

    /**
     * The absolute path of the compiler under check.
     *
     * @remarks
     * It is absolute so that the checks that start the compiler in a project folder find it too.
     *
     * @example
     * ```hx
     * run.compiler; // "/repo/.helix-out/bin/helix"
     * ```
     *
     * @since 1.0.0
     */

    compiler: string,

    /**
     * The text that the path of a snippet must hold for its checks to run, or an empty text for every snippet.
     *
     * @example
     * ```hx
     * run.filter; // "panic-"
     * ```
     *
     * @since 1.0.0
     */

    filter: string,

    /**
     * The folder for what the checks build and copy, which `main` removes at the end.
     *
     * @example
     * ```hx
     * run.temp; // "/tmp/helix-e2e-4242"
     * ```
     *
     * @since 1.0.0
     */

    temp: string,

    /**
     * The number of checks that passed.
     *
     * @example
     * ```hx
     * run.passed; // 412
     * ```
     *
     * @since 1.0.0
     */

    passed: usize,

    /**
     * The number of checks that failed.
     *
     * @example
     * ```hx
     * run.failed; // 0
     * ```
     *
     * @since 1.0.0
     */

    failed: usize,

    /**
     * Why each group of checks that this machine cannot run was skipped, such as a missing QEMU.
     *
     * @example
     * ```hx
     * run.skipped.items; // ["freestanding programs in QEMU: no qemu-system-riscv64"]
     * ```
     *
     * @since 1.0.0
     */

    skipped: ArrayList<string>,
}
