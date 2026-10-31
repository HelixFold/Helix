/**
 * Imports
 */

import { Build, Mode, Step } from "std/build";

/**
 * The build script that `helix build` runs for the compiler.
 *
 * @param builder - The builder that records the artifacts and steps of this build
 * @returns Nothing, or the error that stopped the script from recording a step
 *
 * @remarks
 * The compiler is `src/main.hx`.
 * Its C and native libraries are declared in helix.jsonc:
 * `host.c` (what differs between macOS, Linux, and Windows) and LLVM with libclang,
 * which the compiler that runs the build takes from the toolchain's static LLVM for the target,
 * in `lib/llvm/<platform>` beside it or in `$HELIX_HOME/llvm/<platform>`,
 * and otherwise from the folder of the LLVM it is linked to itself.
 * The built compiler finds the standard library in the `lib` folder of this repository, two folders above
 * `helix-out/bin`, and builds its runtime from `lib/rt` the first time it needs it.
 *
 * - **install** - the default step, which builds `helix-out/bin/helix`
 * - **run** - builds the compiler and runs it, passing on the arguments after `--`
 * - **test** - installs the compiler, then runs every spec in the repository with it (`helix-out/bin/helix test`),
 *   so the specs exercise the compiler this build just made
 * - **release** - builds the compiler in release-safe for this machine into `helix-out/release`
 *
 * @example
 * ```bash
 * helix build                   # helix-out/bin/helix
 * helix build run -- version    # helix 1.0.0-alpha.0 (LLVM 23.1.4)
 * helix build test              # helix-out/bin/helix test: Tests:  ... passed
 * helix build release           # helix-out/release/helix
 * ```
 *
 * @see Build
 * @since 1.0.0
 */

export function build(builder: *Build): void | Error {
    const executable = try builder.addExecutable({ name: "helix", root: "src/main.hx" });
    try builder.install(executable);
    try builder.addRunStep(executable);

    const test = try builder.step("test", "Build the compiler, then run every spec with it");
    const specs = try builder.addSystemCommand(["helix-out/bin/helix", "test"]);
    try specs.dependOn(Step { b: builder, index: 0 });   // step 0 is `install`
    try test.dependOn(specs);

    const release = try builder.step("release", "Build the compiler in release-safe for this machine into helix-out/release");
    const released = try builder.addExecutable({ name: "helix", root: "src/main.hx", mode: Mode.ReleaseSafe });
    try release.dependOn(try builder.addInstall(released, "release"));
}
