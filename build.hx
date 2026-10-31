/**
 * Imports
 */

import * as fmt from "std/fmt";
import { Build, Mode } from "std/build";

/**
 * Every OS the compiler is released for.
 *
 * @since 1.0.0
 */

const TARGETS: readonly string[] = [
    "x86_64-linux", "aarch64-linux",
    "x86_64-macos", "aarch64-macos",
    "x86_64-windows", "aarch64-windows",
];

/**
 * The build script that `helix build` runs for the compiler.
 *
 * @param builder - The builder that records the options, artifacts, and steps of this build
 * @returns Nothing, or the error that stopped the script from recording a step
 *
 * @remarks
 * The whole build of the compiler: `src/main.hx` built into one executable named `helix`, for this machine or the
 * OS that `--target` names, and the release, built in release-safe for every OS in {@link TARGETS}.
 *
 * - **install** - the default step, which copies the executable into `helix-out/bin`
 * - **run** - builds the executable and runs it, passing on the arguments after `--`
 * - **test** - runs every spec under `src`
 * - **release** - builds the executable for every OS into `helix-out/release/<target>`
 *
 * @example
 * ```bash
 * helix build                                                # helix-out/bin/helix
 * helix build run                                            # Hello from Helix!
 * helix build test                                           # Tests:  3 passed, 3 total
 * helix build --target x86_64-windows --mode release-safe    # helix-out/bin/helix.exe
 * helix build release                                        # helix-out/release/<target>/helix, for every OS
 * ```
 *
 * @see Build
 * @since 1.0.0
 */

export function build(builder: *Build): void | Error {
    const executable = try builder.addExecutable({ name: "helix", root: "src/main.hx" });
    try builder.install(executable);
    try builder.addRunStep(executable);
    try builder.addTestStep({ root: "src", linkWith: executable });

    const release = try builder.step("release", "Build the compiler for every OS into helix-out/release/<target>");
    for (const target of TARGETS) {
        const released = try builder.addExecutable({ name: "helix", root: "src/main.hx", target, mode: Mode.ReleaseSafe });
        try release.dependOn(try builder.addInstall(released, try fmt.alloc(builder.a, `release/${target}`)));
    }
}
