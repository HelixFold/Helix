/**
 * The deepest that expressions, types, patterns, statements, and describe blocks may nest.
 *
 * @remarks
 * The parser is recursive, so the limit keeps hostile input from overflowing the stack.
 * Past it the parser reports one error and returns an invalid node.
 *
 * @example
 * ```ts
 * MAX_DEPTH; // 256
 * ```
 *
 * @since 1.0.0
 */

export const MAX_DEPTH: u32 = 256;

/**
 * The number of tokens that the parser scans after a `<` to decide whether it starts type arguments.
 *
 * @remarks
 * A `<` that the scan cannot settle within this many tokens is read as a less-than.
 *
 * @example
 * ```ts
 * GENERIC_LOOKAHEAD; // 64
 * ```
 *
 * @since 1.0.0
 */

export const GENERIC_LOOKAHEAD: u32 = 64;

/**
 * The most fixed sizes that one array type may stack, as in `f32[3][4]`.
 *
 * @example
 * ```ts
 * MAX_ARRAY_DIMS; // 16
 * ```
 *
 * @since 1.0.0
 */

export const MAX_ARRAY_DIMS: u32 = 16;

/**
 * The diagnostic index that marks an error the parser suppressed while it recovers from an earlier one.
 *
 * @remarks
 * A hint attached to this index is dropped, so callers can attach hints without checking first.
 *
 * @example
 * ```ts
 * const diag = errorExpected(p, "a type"); // NO_DIAG while the parser is recovering
 * hint(p, diag, "...");                    // does nothing for NO_DIAG
 * ```
 *
 * @since 1.0.0
 */

export const NO_DIAG: u32 = 0xFFFF_FFFF;

/**
 * The precedence of `??`, the loosest binary operator.
 *
 * @remarks
 * It is also the only right-associative one, so `a ?? b ?? c` reads as `a ?? (b ?? c)`.
 *
 * @example
 * ```ts
 * PREC_COALESCE; // 1
 * ```
 *
 * @since 1.0.0
 */

export const PREC_COALESCE: u8 = 1;

/**
 * The precedence of `||`.
 *
 * @example
 * ```ts
 * PREC_OR; // 2
 * ```
 *
 * @since 1.0.0
 */

export const PREC_OR: u8 = 2;

/**
 * The precedence of `&&`.
 *
 * @example
 * ```ts
 * PREC_AND; // 3
 * ```
 *
 * @since 1.0.0
 */

export const PREC_AND: u8 = 3;

/**
 * The precedence of the comparisons `==`, `!=`, `<`, `<=`, `>`, and `>=`.
 *
 * @remarks
 * Comparisons do not chain, so `a < b < c` is an error.
 *
 * @example
 * ```ts
 * PREC_COMPARE; // 4
 * ```
 *
 * @since 1.0.0
 */

export const PREC_COMPARE: u8 = 4;

/**
 * The precedence of the bitwise `|`.
 *
 * @remarks
 * Unlike in C, the bitwise operators bind tighter than the comparisons,
 * so `flags & MASK == 0` reads as `(flags & MASK) == 0`.
 *
 * @example
 * ```ts
 * PREC_BIT_OR; // 5
 * ```
 *
 * @since 1.0.0
 */

export const PREC_BIT_OR: u8 = 5;

/**
 * The precedence of the bitwise `^`.
 *
 * @example
 * ```ts
 * PREC_BIT_XOR; // 6
 * ```
 *
 * @since 1.0.0
 */

export const PREC_BIT_XOR: u8 = 6;

/**
 * The precedence of the bitwise `&`.
 *
 * @example
 * ```ts
 * PREC_BIT_AND; // 7
 * ```
 *
 * @since 1.0.0
 */

export const PREC_BIT_AND: u8 = 7;

/**
 * The precedence of the shifts `<<` and `>>`.
 *
 * @example
 * ```ts
 * PREC_SHIFT; // 8
 * ```
 *
 * @since 1.0.0
 */

export const PREC_SHIFT: u8 = 8;

/**
 * The precedence of `+`, `-`, and their wrapping and saturating forms.
 *
 * @example
 * ```ts
 * PREC_ADD; // 9
 * ```
 *
 * @since 1.0.0
 */

export const PREC_ADD: u8 = 9;

/**
 * The precedence of `*`, `/`, `%`, and their wrapping and saturating forms, the tightest binary operators.
 *
 * @example
 * ```ts
 * PREC_MUL; // 10
 * ```
 *
 * @since 1.0.0
 */

export const PREC_MUL: u8 = 10;

/**
 * The kind of list that the parser resynchronizes in after an error.
 *
 * @remarks
 * Each kind names the tokens where parsing can safely resume.
 * A `;` at the outer level always ends the skip, and a `}` ends it everywhere except at the top level.
 *
 * @example
 * ```ts
 * recover(p, Sync.Statement, before); // skip to the next statement
 * ```
 *
 * @since 1.0.0
 */

export enum Sync {
    /**
     * A list of statements, which resumes at a statement keyword, a case, a test, or a hook.
     *
     * @example
     * ```ts
     * recover(p, Sync.Statement, before);
     * ```
     *
     * @since 1.0.0
     */

    Statement,

    /**
     * The top level of a file, which resumes at a declaration keyword or a test.
     *
     * @example
     * ```ts
     * recover(p, Sync.Declaration, before);
     * ```
     *
     * @since 1.0.0
     */

    Declaration,

    /**
     * The body of a struct, an enum, a union, or an interface, which resumes after a `,` or at a method.
     *
     * @example
     * ```ts
     * recover(p, Sync.Member, before);
     * ```
     *
     * @since 1.0.0
     */

    Member,

    /**
     * The body of a switch, which resumes at the next `case` or `default`.
     *
     * @example
     * ```ts
     * recover(p, Sync.Case, before);
     * ```
     *
     * @since 1.0.0
     */

    Case,
}

/**
 * The kind of body that the container parser reads, which decides what each member looks like.
 *
 * @example
 * ```ts
 * parseContainer(p, NodeKind.Enum, Members.Enum, flags);
 * ```
 *
 * @since 1.0.0
 */

export enum Members {
    /**
     * Fields with a type and an optional default, plus methods and constants.
     *
     * @example
     * ```ts
     * struct Point { x: f32 = 0, y: f32 }
     * ```
     *
     * @since 1.0.0
     */

    Struct,

    /**
     * Members with an optional value, plus methods and constants.
     *
     * @example
     * ```ts
     * enum Role: u8 { Admin = 1, User }
     * ```
     *
     * @since 1.0.0
     */

    Enum,

    /**
     * Variants with an optional payload type, plus methods and constants.
     *
     * @example
     * ```ts
     * union Shape { circle: f32, empty }
     * ```
     *
     * @since 1.0.0
     */

    Union,

    /**
     * Method signatures without bodies.
     *
     * @example
     * ```ts
     * interface Writer { write(this: *Self, bytes: readonly u8[]): usize; }
     * ```
     *
     * @since 1.0.0
     */

    Interface,
}
