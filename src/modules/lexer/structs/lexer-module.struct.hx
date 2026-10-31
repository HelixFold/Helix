/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";

/**
 * A doc comment, together with the token that it documents.
 *
 * @remarks
 * A doc comment opens with a slash and two stars, and it documents the next token after it.
 * The empty block comment made of a slash, two stars, and a slash is not one.
 *
 * @example
 * ```ts
 * // a 24-byte doc comment at the start of a file, followed by `function add`
 * // { token: 0, start: 0, len: 24 }, where token 0 is `function`
 * ```
 *
 * @see HxTokens
 * @since 1.0.0
 */

export extern "C" struct HxDocComment {
    /**
     * The index of the token that follows the comment.
     *
     * @example
     * ```ts
     * doc.token; // 0
     * ```
     *
     * @since 1.0.0
     */

    token: u32,

    /**
     * The offset of the first byte of the comment.
     *
     * @example
     * ```ts
     * doc.start; // 0
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The length of the comment in bytes, its delimiters included.
     *
     * @example
     * ```ts
     * doc.len; // 24
     * ```
     *
     * @since 1.0.0
     */

    len: u32,
}

/**
 * The token stream of a program, stored as parallel arrays.
 *
 * @remarks
 * Token `i` has the kind `kinds[i]` and covers the text from `starts[i]` for `lens[i]` bytes.
 * The text is never copied, so a token is read straight from the source buffer.
 * Each file that the lexer reads ends with an end-of-file token.
 * Release the arrays with {@link hx_tokens_free}.
 *
 * @example
 * ```ts
 * // let  x
 * // kinds:  [ KW_LET, IDENT, EOF ]
 * // starts: [ 0, 5, 6 ]
 * // lens:   [ 3, 1, 0 ]
 * ```
 *
 * @see hx_lex
 * @see TokenKind
 *
 * @since 1.0.0
 */

export extern "C" struct HxTokens {
    /**
     * The kind of each token, one {@link TokenKind} per byte.
     *
     * @example
     * ```ts
     * tokens.kinds![0] as TokenKind; // TokenKind.KwLet
     * ```
     *
     * @since 1.0.0
     */

    kinds: ?u8[*],

    /**
     * The offset of the first byte of each token.
     *
     * @example
     * ```ts
     * tokens.starts![1]; // 5
     * ```
     *
     * @since 1.0.0
     */

    starts: ?u32[*],

    /**
     * The length of each token in bytes.
     *
     * @example
     * ```ts
     * tokens.lens![0]; // 3
     * ```
     *
     * @since 1.0.0
     */

    lens: ?u32[*],

    /**
     * The number of tokens, the end-of-file tokens included.
     *
     * @example
     * ```ts
     * tokens.len; // 3
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The capacity of the three token arrays.
     *
     * @example
     * ```ts
     * tokens.cap; // 17 for a 6-byte file
     * ```
     *
     * @since 1.0.0
     */

    cap: u32,

    /**
     * The doc comments, in source order.
     *
     * @example
     * ```ts
     * tokens.docs![0]; // the first doc comment
     * ```
     *
     * @since 1.0.0
     */

    docs: ?HxDocComment[*],

    /**
     * The number of doc comments.
     *
     * @example
     * ```ts
     * tokens.docs_len; // 0 for a file without doc comments
     * ```
     *
     * @since 1.0.0
     */

    docs_len: u32,

    /**
     * The capacity of the doc comment array.
     *
     * @example
     * ```ts
     * tokens.docs_cap; // 16 after the first doc comment
     * ```
     *
     * @since 1.0.0
     */

    docs_cap: u32,
}

/**
 * The state of one run of the lexer over one file.
 *
 * @remarks
 * Template literals need state across tokens.
 * A `${` saves the current brace depth, and the `}` that brings the depth back to it resumes the template
 * instead of closing a block, which handles both braces and further templates inside a substitution.
 */

export struct Lexer {
    /**
     * The source that the diagnostics point into.
     */

    src: readonly *HxSource,

    /**
     * The text of the whole program, of which this run reads up to `len`.
     */

    text: readonly u8[],

    /**
     * The offset where this run stops, which is the end of its file.
     */

    len: u32,

    /**
     * The offset of the next byte to read.
     */

    pos: u32,

    /**
     * The token stream that receives the tokens.
     */

    out: *HxTokens,

    /**
     * The list that receives the diagnostics.
     */

    diags: *HxDiagList,

    /**
     * The number of braces open at the current position.
     */

    brace_depth: u32,

    /**
     * The number of template substitutions open at the current position.
     */

    template_depth: u32,

    /**
     * The brace depth saved by each open substitution.
     */

    template_braces: u32[64],

    /**
     * The offset of the `${` of each open substitution, for the error when one is never closed.
     */

    template_starts: u32[64],
}
