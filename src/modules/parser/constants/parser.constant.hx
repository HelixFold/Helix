/**
 * The deepest that expressions, types, patterns, statements, and describe blocks may nest.
 *
 * @remarks
 * The parser is recursive, so the limit keeps hostile input from overflowing the stack.
 * Past it the parser reports one error and returns an invalid node.
 *
 * @example
 * ```hx
 * MaxDepth; // 256
 * ```
 *
 * @since 1.0.0
 */

export const MaxDepth: u32 = 256;

/**
 * The number of tokens that the parser scans after a `<` to decide whether it starts type arguments.
 *
 * @remarks
 * A `<` that the scan cannot settle within this many tokens is read as a less-than.
 *
 * @example
 * ```hx
 * GenericLookahead; // 64
 * ```
 *
 * @since 1.0.0
 */

export const GenericLookahead: u32 = 64;

/**
 * The most fixed sizes that one array type may stack, as in `f32[3][4]`.
 *
 * @example
 * ```hx
 * MaxArrayDims; // 16
 * ```
 *
 * @since 1.0.0
 */

export const MaxArrayDims: u32 = 16;

/**
 * The diagnostic index that marks an error the parser suppressed while it recovers from an earlier one.
 *
 * @remarks
 * A hint attached to this index is dropped, so callers can attach hints without checking first.
 *
 * @example
 * ```hx
 * const diag = errorExpected(p, "a type"); // NoDiag while the parser is recovering
 * attachHint(p, diag, "...");              // does nothing for NoDiag
 * ```
 *
 * @since 1.0.0
 */

export const NoDiag: u32 = 0xFFFF_FFFF;

/**
 * The precedence of `??`, the loosest binary operator.
 *
 * @remarks
 * It is also the only right-associative one, so `a ?? b ?? c` reads as `a ?? (b ?? c)`.
 *
 * @example
 * ```hx
 * PrecCoalesce; // 1
 * ```
 *
 * @since 1.0.0
 */

export const PrecCoalesce: u8 = 1;

/**
 * The precedence of `||`.
 *
 * @example
 * ```hx
 * PrecOr; // 2
 * ```
 *
 * @since 1.0.0
 */

export const PrecOr: u8 = 2;

/**
 * The precedence of `&&`.
 *
 * @example
 * ```hx
 * PrecAnd; // 3
 * ```
 *
 * @since 1.0.0
 */

export const PrecAnd: u8 = 3;

/**
 * The precedence of the comparisons `==`, `!=`, `<`, `<=`, `>`, and `>=`.
 *
 * @remarks
 * Comparisons do not chain, so `a < b < c` is an error.
 *
 * @example
 * ```hx
 * PrecCompare; // 4
 * ```
 *
 * @since 1.0.0
 */

export const PrecCompare: u8 = 4;

/**
 * The precedence of the bitwise `|`.
 *
 * @remarks
 * Unlike in C, the bitwise operators bind tighter than the comparisons,
 * so `flags & MASK == 0` reads as `(flags & MASK) == 0`.
 *
 * @example
 * ```hx
 * PrecBitOr; // 5
 * ```
 *
 * @since 1.0.0
 */

export const PrecBitOr: u8 = 5;

/**
 * The precedence of the bitwise `^`.
 *
 * @example
 * ```hx
 * PrecBitXor; // 6
 * ```
 *
 * @since 1.0.0
 */

export const PrecBitXor: u8 = 6;

/**
 * The precedence of the bitwise `&`.
 *
 * @example
 * ```hx
 * PrecBitAnd; // 7
 * ```
 *
 * @since 1.0.0
 */

export const PrecBitAnd: u8 = 7;

/**
 * The precedence of the shifts `<<` and `>>`.
 *
 * @example
 * ```hx
 * PrecShift; // 8
 * ```
 *
 * @since 1.0.0
 */

export const PrecShift: u8 = 8;

/**
 * The precedence of `+`, `-`, and their wrapping and saturating forms.
 *
 * @example
 * ```hx
 * PrecAdd; // 9
 * ```
 *
 * @since 1.0.0
 */

export const PrecAdd: u8 = 9;

/**
 * The precedence of `*`, `/`, `%`, and their wrapping and saturating forms, the tightest binary operators.
 *
 * @example
 * ```hx
 * PrecMul; // 10
 * ```
 *
 * @since 1.0.0
 */

export const PrecMul: u8 = 10;

/**
 * The kind of list that the parser resynchronizes in after an error.
 *
 * @remarks
 * Each kind names the tokens where parsing can safely resume.
 * A `;` at the outer level always ends the skip, and a `}` ends it everywhere except at the top level.
 *
 * @example
 * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
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
 * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
     * interface Writer { write(this: *Self, bytes: readonly u8[]): usize; }
     * ```
     *
     * @since 1.0.0
     */

    Interface,
}
