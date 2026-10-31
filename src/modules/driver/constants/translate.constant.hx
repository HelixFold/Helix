/**
 * The Helix keywords and built-in names that a C name may not take as it is.
 *
 * @remarks
 * A C name in this list gets a `_` after it.
 * The integer types such as `i32` and `u8` are matched by their form instead of being listed.
 *
 * @example
 * ```hx
 * Reserved[0]; // "as"
 * ```
 *
 * @since 1.0.0
 */

export const Reserved: readonly string[] = [
    "as", "break", "case", "catch", "comptime", "const", "continue", "default", "defer", "dyn", "else", "enum",
    "errdefer", "error", "export", "extends", "extern", "false", "for", "from", "function", "if", "import",
    "interface", "let", "null", "of", "readonly", "return", "struct", "switch", "throw", "true", "try", "type",
    "undefined", "union", "unreachable", "unsafe", "void", "while", "this", "Self", "bool", "string", "usize",
    "isize", "f32", "f64", "noreturn", "Error", "Format", "print", "println", "eprint", "eprintln",
];
