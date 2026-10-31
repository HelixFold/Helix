/**
 * Imports
 */

import { ArrayList } from "std/list";
import { Strings } from "@modules/driver/components/structs/os-component.struct";

/**
 * A macOS SDK and its version.
 *
 * @remarks
 * The SDK holds the headers and the `.tbd` stubs of the system libraries that a macOS program links with.
 *
 * @example
 * ```hx
 * macosSdk(); // { path: "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk", version: "27.0" }
 * ```
 *
 * @see macosSdk
 * @since 1.0.0
 */

export struct Sdk {
    /**
     * The folder of the SDK.
     *
     * @example
     * ```hx
     * sdk.path; // "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
     * ```
     *
     * @since 1.0.0
     */

    path: string,

    /**
     * The version of the SDK, from the `Version` key of its `SDKSettings.json`.
     *
     * @example
     * ```hx
     * sdk.version; // "27.0"
     * ```
     *
     * @since 1.0.0
     */

    version: string,
}

/**
 * A clang command that compiles one source file into one object file.
 *
 * @remarks
 * {@link addCompile} queues each job,
 * and {@link runJobs} runs them several at a time and sets `failed` on each one that fails.
 *
 * @example
 * ```hx
 * job.args;   // [ "clang", "-target", ..., "-c", "src/string/memcpy.c", "-o", "obj/src_string_memcpy.c.o" ]
 * job.failed; // false once the command has exited with 0
 * ```
 *
 * @see Jobs
 * @since 1.0.0
 */

export struct Job {
    /**
     * The whole command, `clang <flags...> -c <source> -o <object>`.
     *
     * @example
     * ```hx
     * job.args.items[0]; // the path of clang
     * ```
     *
     * @since 1.0.0
     */

    args: Strings,

    /**
     * The source file that the job compiles.
     *
     * @example
     * ```hx
     * job.source; // "<musl>/src/string/memcpy.c"
     * ```
     *
     * @since 1.0.0
     */

    source: string,

    /**
     * The object file that the job writes.
     *
     * @example
     * ```hx
     * job.object; // "<out>/obj/src_string_memcpy.c.o"
     * ```
     *
     * @since 1.0.0
     */

    object: string,

    /**
     * Whether the command could not start or exited with an error.
     *
     * @example
     * ```hx
     * job.failed; // true for a compiler-rt file that does not build for the target
     * ```
     *
     * @since 1.0.0
     */

    failed: bool,
}

/**
 * A list of compile jobs that run several at a time.
 *
 * @example
 * ```hx
 * let jobs: Jobs = ArrayList<Job>.init(cAllocator());
 * ```
 *
 * @see Job
 * @since 1.0.0
 */

export type Jobs = ArrayList<Job>;
