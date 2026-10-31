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
 * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
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
 * Release the arrays with {@link hxTokensFree}.
 *
 * @example
 * ```hx
 * // let  x
 * // kinds:  [ KW_LET, IDENT, EOF ]
 * // starts: [ 0, 5, 6 ]
 * // lens:   [ 3, 1, 0 ]
 * ```
 *
 * @see hxLex
 * @see TokenKind
 *
 * @since 1.0.0
 */

export extern "C" struct HxTokens {
    /**
     * The kind of each token, one {@link TokenKind} per byte.
     *
     * @example
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
     * tokens.docsLen; // 0 for a file without doc comments
     * ```
     *
     * @since 1.0.0
     */

    docsLen: u32,

    /**
     * The capacity of the doc comment array.
     *
     * @example
     * ```hx
     * tokens.docsCap; // 16 after the first doc comment
     * ```
     *
     * @since 1.0.0
     */

    docsCap: u32,
}

/**
 * The state of one run of the lexer over one file.
 *
 * @remarks
 * Template literals need state across tokens.
 * A `${` saves the current brace depth, and the `}` that brings the depth back to it resumes the template
 * instead of closing a block, which handles both braces and further templates inside a substitution.
 *
 * @example
 * ```hx
 * let lx = Lexer {
 *     src, text, len: end, pos: start, out, diags,
 *     braceDepth: 0, templateDepth: 0, templateBraces: undefined, templateStarts: undefined,
 * };
 * // inside a substitution, the `{` of an object raises braceDepth and its `}` lowers it again,
 * // and the next `}` at the saved depth resumes the template
 * ```
 *
 * @since 1.0.0
 */

export struct Lexer {
    /**
     * The source that the diagnostics point into.
     *
     * @example
     * ```hx
     * lx.src; // the source that a diagnostic of this run points into
     * ```
     *
     * @since 1.0.0
     */

    src: readonly *HxSource,

    /**
     * The text of the whole program, of which this run reads up to `len`.
     *
     * @example
     * ```hx
     * lx.text; // the bytes of every file of the program
     * ```
     *
     * @since 1.0.0
     */

    text: readonly u8[],

    /**
     * The offset where this run stops, which is the end of its file.
     *
     * @example
     * ```hx
     * lx.len; // 120 for a run over a file that ends at offset 120
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The offset of the next byte to read.
     *
     * @example
     * ```hx
     * lx.pos; // 4 after reading `let ` at the start of a file
     * ```
     *
     * @since 1.0.0
     */

    pos: u32,

    /**
     * The token stream that receives the tokens.
     *
     * @example
     * ```hx
     * lx.out; // the stream that hxLex appends this run's tokens to
     * ```
     *
     * @since 1.0.0
     */

    out: *HxTokens,

    /**
     * The list that receives the diagnostics.
     *
     * @example
     * ```hx
     * lx.diags; // the list that receives an unterminated string error
     * ```
     *
     * @since 1.0.0
     */

    diags: *HxDiagList,

    /**
     * The number of braces open at the current position.
     *
     * @example
     * ```hx
     * lx.braceDepth; // 1 inside `{ a`
     * ```
     *
     * @since 1.0.0
     */

    braceDepth: u32,

    /**
     * The number of template substitutions open at the current position.
     *
     * @example
     * ```hx
     * lx.templateDepth; // 1 inside one open substitution
     * ```
     *
     * @since 1.0.0
     */

    templateDepth: u32,

    /**
     * The brace depth saved by each open substitution.
     *
     * @example
     * ```hx
     * lx.templateBraces[0]; // 0 for a `${` opened at the top level
     * ```
     *
     * @since 1.0.0
     */

    templateBraces: u32[64],

    /**
     * The offset of the `${` of each open substitution, for the error when one is never closed.
     *
     * @example
     * ```hx
     * lx.templateStarts[0]; // 2 when a file opens with a backtick, then `a${`
     * ```
     *
     * @since 1.0.0
     */

    templateStarts: u32[64],
}
