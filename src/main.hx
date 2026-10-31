/**
 * Imports
 */

import { Init } from "std/process";
import { run } from "@modules/driver/driver.module";

/**
 * The entry point of `helix`, the compiler and its command line.
 *
 * @param init - The start state of the process, whose arguments this function reads
 * @returns The exit code of the command that the arguments name
 *
 * @remarks
 * It passes the arguments to `run` of the driver module, where every command lives.
 *
 * @example
 * ```hx
 * // helix check src/main.hx
 * main(init); // 0 when the file checks
 * ```
 *
 * @see run
 * @since 1.0.0
 */

export function main(init: Init): u8 {
    return run(init.args);
}
