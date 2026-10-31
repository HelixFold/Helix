/**
 * Imports
 */

import { Init } from "./process";
import { runBuild } from "./build";
import { build } from "@build";

/**
 * The `main` of the build runner, which runs the `build` function of a project.
 *
 * @param init - The command line that `helix build` passes to the runner
 * @returns The exit status of the build, or the error that stopped it
 *
 * @remarks
 * `helix build` compiles this file together with the build.hx of the project, which it maps to the package `@build`,
 * or with `default-build.hx` when the project has none.
 * Everything else happens in {@link runBuild}.
 *
 * @example
 * ```bash
 * helix build test --mode release-fast # the runner reads the steps and the options and runs test
 * ```
 *
 * @since 1.0.0
 */

export function main(init: Init): u8 | Error {
    return try runBuild(init, build);
}
