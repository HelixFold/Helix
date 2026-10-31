/**
 * The commands that moved to hpm, each followed by its name there.
 *
 * @remarks
 * The list alternates between the old `helix` command and the hpm command that replaces it,
 * so `package` became `hpm pack` and `run-script` became `hpm run`.
 *
 * @example
 * ```hx
 * Moved[8]; // "package"
 * Moved[9]; // "pack"
 * ```
 *
 * @see movedToHpm
 * @since 1.0.0
 */

export const Moved: readonly string[] = ["init", "init", "add", "add", "remove", "remove", "fetch", "fetch", "package", "pack",
                                  "run-script", "run"];
