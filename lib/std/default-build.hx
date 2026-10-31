/**
 * Imports
 */

import { Build } from "./build";

/**
 * The build.hx of a project without one, which adds nothing.
 *
 * @param _b - The build, unused
 * @returns Nothing, since it never fails
 *
 * @remarks
 * `helix build` compiles this file in place of a missing build.hx.
 * The runner already gives every project the steps that helix.jsonc implies,
 * which are building and installing each `bin`, `run` for the first one, and `test` for `src/`,
 * so the project needs nothing more.
 *
 * @example
 * ```hx
 * build(&b); // b keeps only the steps of the runner
 * ```
 *
 * @since 1.0.0
 */

export function build(_b: *Build): void | Error {}
