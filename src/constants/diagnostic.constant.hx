/**
 * The level of a diagnostic that stops the compilation.
 *
 * @remarks
 * Only diagnostics at this level count towards the error count of a list.
 *
 * @example
 * ```hx
 * emit(&diags, DiagError, &src, 4, 1, "unexpected character");
 * diags.errorCount; // 1
 * ```
 *
 * @since 1.0.0
 */

export const DiagError: i32 = 0;

/**
 * The level of a diagnostic that points out a likely mistake but lets the compilation go on.
 *
 * @example
 * ```hx
 * emit(&diags, DiagWarning, &src, 4, 1, "unused variable");
 * diags.errorCount; // 0
 * ```
 *
 * @since 1.0.0
 */

export const DiagWarning: i32 = 1;

/**
 * The level of a diagnostic that adds context to another one.
 *
 * @example
 * ```hx
 * emit(&diags, DiagNote, &src, 0, 3, "first declared here");
 * ```
 *
 * @since 1.0.0
 */

export const DiagNote: i32 = 2;

/**
 * The number of columns between tab stops when a source line is printed.
 *
 * @remarks
 * Tabs are expanded to spaces so that the underline lines up with the text above it.
 *
 * @example
 * ```hx
 * TabWidth; // 4
 * ```
 *
 * @since 1.0.0
 */

export const TabWidth: u32 = 4;

/**
 * The ANSI sequence that ends any color or weight.
 *
 * @example
 * ```hx
 * `${Bold}hint:${Reset}`; // bold 'hint:' and plain text after it
 * ```
 *
 * @since 1.0.0
 */

export const Reset = "\x1b[0m";

/**
 * The ANSI sequence that starts bold text.
 *
 * @example
 * ```hx
 * `${Bold}hint:${Reset}`; // bold 'hint:'
 * ```
 *
 * @since 1.0.0
 */

export const Bold = "\x1b[1m";

/**
 * The ANSI sequence that starts the bold blue of the gutter.
 *
 * @example
 * ```hx
 * `${Blue}-->${Reset}`; // a blue arrow
 * ```
 *
 * @since 1.0.0
 */

export const Blue = "\x1b[1;34m";

/**
 * The label printed for each level, indexed by the level.
 *
 * @example
 * ```hx
 * LevelLabels[DiagWarning]; // 'warning'
 * ```
 *
 * @since 1.0.0
 */

export const LevelLabels: string[3] = ["error", "warning", "note"];

/**
 * The ANSI color of each level, indexed by the level.
 *
 * @remarks
 * An error is bold red, a warning is bold yellow, and a note is bold cyan.
 *
 * @example
 * ```hx
 * LevelColors[DiagError]; // bold red
 * ```
 *
 * @since 1.0.0
 */

export const LevelColors: string[3] = ["\x1b[1;31m", "\x1b[1;33m", "\x1b[1;36m"];
