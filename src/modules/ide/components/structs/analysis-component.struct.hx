/**
 * Imports
 */

import { Builder } from "std/fmt";
import { ArrayList } from "std/list";
import { HxMember } from "@structs/sema.struct";

/**
 * A position in a file, as the Language Server Protocol counts it.
 *
 * @remarks
 * Lines start at 0, and characters count UTF-16 code units from the start of the line.
 *
 * @example
 * ```hx
 * posOf(c, at); // Pos { line: 2, character: 4 }
 * ```
 *
 * @since 1.0.0
 */

export struct Pos {
    /**
     * The line, counted from 0 in the file.
     *
     * @example
     * ```hx
     * pos.line; // 0 on the first line
     * ```
     *
     * @since 1.0.0
     */

    line: u32,

    /**
     * The column, in UTF-16 code units from the start of the line.
     *
     * @example
     * ```hx
     * pos.character; // 2 after an emoji, which takes two units
     * ```
     *
     * @since 1.0.0
     */

    character: u32,
}

/**
 * The tokens of one file, as a range of token indices.
 *
 * @remarks
 * The range runs from `first` up to, but not including, `end`, and leaves out the end of file token.
 *
 * @example
 * ```hx
 * const span = fileTokens(c, 0);
 * span.end - span.first; // the number of tokens of module 0
 * ```
 *
 * @since 1.0.0
 */

export struct TokenSpan {
    /**
     * The index of the first token of the file.
     *
     * @example
     * ```hx
     * fileTokens(c, 0).first; // 0
     * ```
     *
     * @since 1.0.0
     */

    first: u32,

    /**
     * The index just past the last token of the file.
     *
     * @example
     * ```hx
     * fileTokens(c, 0).end; // the index of its end of file token
     * ```
     *
     * @since 1.0.0
     */

    end: u32,
}

/**
 * The declaration that a name refers to.
 *
 * @remarks
 * A member of a struct, enum, union, or error set has no symbol, so it carries its member instead.
 *
 * @example
 * ```hx
 * const target = resolve(c, t);
 * target.isMember; // true for the name of a field
 * ```
 *
 * @since 1.0.0
 */

export struct Target {
    /**
     * The name token of the declaration, or `NoToken` when the name refers to nothing.
     *
     * @example
     * ```hx
     * Nowhere.token; // NoToken
     * ```
     *
     * @since 1.0.0
     */

    token: u32,

    /**
     * The symbol of the declaration, or 0 for a member or a name without one.
     *
     * @example
     * ```hx
     * target.symbol; // 0 for a field
     * ```
     *
     * @since 1.0.0
     */

    symbol: u32,

    /**
     * Whether the declaration is a member, whose details are in the member field.
     *
     * @example
     * ```hx
     * target.isMember; // true for `p.x`
     * ```
     *
     * @since 1.0.0
     */

    isMember: bool,

    /**
     * The member, when the declaration is one.
     *
     * @example
     * ```hx
     * target.member.type; // the type of the field
     * ```
     *
     * @since 1.0.0
     */

    member: HxMember,
}

/**
 * The token type and the modifiers of every token, filled in before any token is written.
 *
 * @remarks
 * Both lists hold one entry per token of the compilation, and every entry starts as {@link TNone} with no modifiers.
 * A pass over the declared names fills them in only when the file parsed,
 * and `writeSemanticTokens` falls back to the token kind for every entry left at {@link TNone}.
 *
 * @example
 * ```hx
 * col.types.items[t]; // TFunction for the name of a function
 * ```
 *
 * @since 1.0.0
 */

export struct Coloring {
    /**
     * The token type of each token, or {@link TNone} for one that the token kind colors.
     *
     * @example
     * ```hx
     * col.types.items[t]; // TNone
     * ```
     *
     * @since 1.0.0
     */

    types: ArrayList<u8>,

    /**
     * The modifier bits of each token.
     *
     * @example
     * ```hx
     * col.modifiers.items[t]; // MDeclaration | MReadonly for the name of a const
     * ```
     *
     * @since 1.0.0
     */

    modifiers: ArrayList<u8>,
}

/**
 * The state of the writer that encodes semantic tokens, each relative to the one before it.
 *
 * @remarks
 * LSP encodes each token as five numbers, with the line given as a delta from the previous token.
 * The character is also a delta when the line stays the same, and an absolute column on a new line.
 * The writer keeps the position of the last token for that, and the count decides whether a comma goes first.
 *
 * @example
 * ```hx
 * let w = TokenWriter { b, line: 0, character: 0, count: 0 };
 * ```
 *
 * @since 1.0.0
 */

export struct TokenWriter {
    /**
     * The buffer that the tokens go into.
     *
     * @example
     * ```hx
     * w.b; // the buffer of the answer
     * ```
     *
     * @since 1.0.0
     */

    b: *Builder,

    /**
     * The line of the previous token.
     *
     * @example
     * ```hx
     * w.line; // 0 before the first token
     * ```
     *
     * @since 1.0.0
     */

    line: u32,

    /**
     * The character of the previous token.
     *
     * @example
     * ```hx
     * w.character; // 0 before the first token
     * ```
     *
     * @since 1.0.0
     */

    character: u32,

    /**
     * The number of tokens written so far.
     *
     * @example
     * ```hx
     * w.count; // 0 until the first token
     * ```
     *
     * @since 1.0.0
     */

    count: u32,
}
