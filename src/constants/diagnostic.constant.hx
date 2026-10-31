/**
 * The level of a diagnostic that stops the compilation.
 *
 * @remarks
 * Only diagnostics at this level count towards the error count of a list.
 *
 * @example
 * ```ts
 * emit(&diags, DIAG_ERROR, &src, 4, 1, "unexpected character");
 * diags.error_count; // 1
 * ```
 *
 * @since 1.0.0
 */

export const DIAG_ERROR: i32 = 0;

/**
 * The level of a diagnostic that points out a likely mistake but lets the compilation go on.
 *
 * @example
 * ```ts
 * emit(&diags, DIAG_WARNING, &src, 4, 1, "unused variable");
 * diags.error_count; // 0
 * ```
 *
 * @since 1.0.0
 */

export const DIAG_WARNING: i32 = 1;

/**
 * The level of a diagnostic that adds context to another one.
 *
 * @example
 * ```ts
 * emit(&diags, DIAG_NOTE, &src, 0, 3, "first declared here");
 * ```
 *
 * @since 1.0.0
 */

export const DIAG_NOTE: i32 = 2;

/**
 * The number of columns between tab stops when a source line is printed.
 *
 * @remarks
 * Tabs are expanded to spaces so that the underline lines up with the text above it.
 *
 * @example
 * ```ts
 * TAB_WIDTH; // 4
 * ```
 *
 * @since 1.0.0
 */

export const TAB_WIDTH: u32 = 4;

/**
 * The ANSI sequence that ends any color or weight.
 *
 * @example
 * ```ts
 * `${BOLD}hint:${RESET}`; // bold 'hint:' and plain text after it
 * ```
 *
 * @since 1.0.0
 */

export const RESET = "\x1b[0m";

/**
 * The ANSI sequence that starts bold text.
 *
 * @example
 * ```ts
 * `${BOLD}hint:${RESET}`; // bold 'hint:'
 * ```
 *
 * @since 1.0.0
 */

export const BOLD = "\x1b[1m";

/**
 * The ANSI sequence that starts the bold blue of the gutter.
 *
 * @example
 * ```ts
 * `${BLUE}-->${RESET}`; // a blue arrow
 * ```
 *
 * @since 1.0.0
 */

export const BLUE = "\x1b[1;34m";

/**
 * The label printed for each level, indexed by the level.
 *
 * @example
 * ```ts
 * LEVEL_LABELS[DIAG_WARNING]; // 'warning'
 * ```
 *
 * @since 1.0.0
 */

export const LEVEL_LABELS: string[3] = ["error", "warning", "note"];

/**
 * The ANSI color of each level, indexed by the level.
 *
 * @remarks
 * An error is bold red, a warning is bold yellow, and a note is bold cyan.
 *
 * @example
 * ```ts
 * LEVEL_COLORS[DIAG_ERROR]; // bold red
 * ```
 *
 * @since 1.0.0
 */

export const LEVEL_COLORS: string[3] = ["\x1b[1;31m", "\x1b[1;33m", "\x1b[1;36m"];
