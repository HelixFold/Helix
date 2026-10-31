/**
 * Imports
 */

import { NodeKind, HookNames } from "@constants/ast.constant";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { GenericLookahead } from "@modules/parser/constants/parser.constant";
import { isKeyword, isContextual } from "@modules/lexer/components/token.component";

/**
 * Returns the kind of a token.
 *
 * @param p - The parser state
 * @param index - The index of the token
 * @returns The kind, or the end of file past the last token
 *
 * @remarks
 * Answering `Eof` past the last token lets lookahead run off the end of the stream safely,
 * so no caller has to check the length before peeking.
 *
 * @example
 * ```hx
 * kindAt(p, 0);    // TokenKind.KwConst for const a = 1;
 * kindAt(p, 999);  // TokenKind.Eof
 * ```
 *
 * @since 1.0.0
 */

export function kindAt(p: *Parser, index: u32): TokenKind {
    if (index >= p.tokens.len) return TokenKind.Eof;
    unsafe {
        return @enumFromInt(TokenKind, p.tokens.kinds![index]);
    }
}

/**
 * Returns the kind of the current token.
 *
 * @param p - The parser state
 * @returns The kind of the token at the current position
 *
 * @remarks
 * It goes through {@link kindAt}, so it answers `Eof` once the parser has consumed every token.
 *
 * @example
 * ```hx
 * currentKind(p); // TokenKind.KwConst at the start of const a = 1;
 * ```
 *
 * @since 1.0.0
 */

export function currentKind(p: *Parser): TokenKind {
    return kindAt(p, p.pos);
}

/**
 * Returns the kind of a token ahead of the current one.
 *
 * @param p - The parser state
 * @param ahead - How many tokens past the current one to look
 * @returns The kind of that token
 *
 * @remarks
 * The parser uses it for fixed lookahead, such as telling `(name:` apart from a parenthesized value.
 * A distance past the last token answers `Eof` rather than reading out of bounds.
 *
 * @example
 * ```hx
 * peekKind(p, 1); // TokenKind.Ident, the a of const a = 1;
 * ```
 *
 * @since 1.0.0
 */

export function peekKind(p: *Parser, ahead: u32): TokenKind {
    return kindAt(p, p.pos + ahead);
}

/**
 * Checks whether the current token is of a kind.
 *
 * @param p - The parser state
 * @param kind - The kind to compare with
 * @returns `true` when the current token has that kind
 *
 * @remarks
 * It only compares and never consumes,
 * so use {@link acceptToken} to consume an optional token and {@link expectToken} to require one.
 *
 * @example
 * ```hx
 * atKind(p, TokenKind.KwConst); // true at the start of const a = 1;
 * ```
 *
 * @since 1.0.0
 */

export function atKind(p: *Parser, kind: TokenKind): bool {
    return currentKind(p) == kind;
}

/**
 * Returns the offset where a token starts.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @returns The offset of its first byte
 *
 * @remarks
 * Diagnostics and adjacency checks use the offset to point into the source text.
 * It performs no bounds check, so the index must name a real token.
 *
 * @example
 * ```hx
 * tokenStart(p, 1); // 6, the offset of a in const a = 1;
 * ```
 *
 * @since 1.0.0
 */

export function tokenStart(p: *Parser, token: u32): u32 {
    unsafe {
        return p.tokens.starts![token];
    }
}

/**
 * Returns the length of a token.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @returns Its length in bytes
 *
 * @remarks
 * The length counts the bytes as written in the source, delimiters included for a string or a char.
 * It performs no bounds check, so the index must name a real token.
 *
 * @example
 * ```hx
 * tokenLength(p, 0); // 5, the length of const
 * ```
 *
 * @since 1.0.0
 */

export function tokenLength(p: *Parser, token: u32): u32 {
    unsafe {
        return p.tokens.lens![token];
    }
}

/**
 * Returns the source text of a token.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @returns The text, which is not copied
 *
 * @remarks
 * The slice points into the source buffer, so it stays valid only while the source does.
 * It performs no bounds check, so the index must name a real token.
 *
 * @example
 * ```hx
 * tokenSource(p, 1); // 'a' in const a = 1;
 * ```
 *
 * @since 1.0.0
 */

export function tokenSource(p: *Parser, token: u32): string {
    unsafe {
        const s = p.tokens.starts![token];
        return p.src.text![s..s + p.tokens.lens![token]];
    }
}

/**
 * Consumes the current token.
 *
 * @param p - The parser state
 * @returns The index of the consumed token
 *
 * @remarks
 * It never moves past the end of file, so a loop that keeps advancing stops there.
 *
 * @example
 * ```hx
 * advanceToken(p); // 0, and the parser moves to token 1
 * ```
 *
 * @since 1.0.0
 */

export function advanceToken(p: *Parser): u32 {
    const token = p.pos;
    if (currentKind(p) != TokenKind.Eof) p.pos += 1;
    return token;
}

/**
 * Consumes the current token when it is of a kind.
 *
 * @param p - The parser state
 * @param kind - The kind to accept
 * @returns `true` when the token was consumed
 *
 * @remarks
 * Use it for an optional token such as a trailing comma.
 * When the token is absent, it neither moves the position nor reports an error.
 *
 * @example
 * ```hx
 * acceptToken(p, TokenKind.Comma);     // false, nothing consumed at const
 * acceptToken(p, TokenKind.KwConst);   // true, const consumed
 * ```
 *
 * @since 1.0.0
 */

export function acceptToken(p: *Parser, kind: TokenKind): bool {
    if (!atKind(p, kind)) return false;
    void advanceToken(p);
    return true;
}

/**
 * Checks whether a token ends exactly where the next one starts.
 *
 * @param p - The parser state
 * @param index - The index of the first token
 * @returns `true` when no space separates the two
 *
 * @remarks
 * It joins two `>` tokens into a `>>` shift only when they touch.
 *
 * @example
 * ```hx
 * adjacent(p, 1); // true for the two > of a >> 2
 * adjacent(p, 1); // false for a > > 2
 * ```
 *
 * @since 1.0.0
 */

export function adjacent(p: *Parser, index: u32): bool {
    return index + 1 < p.tokens.len && tokenStart(p, index) + tokenLength(p, index) == tokenStart(p, index + 1);
}

/**
 * Checks whether a token kind can serve as a name.
 *
 * @param kind - The kind to check
 * @returns `true` for an identifier or a contextual keyword such as `type` or `from`
 *
 * @remarks
 * Contextual keywords such as `type` can still name a variable, a field, or a parameter,
 * while a reserved keyword such as `const` cannot.
 *
 * @example
 * ```hx
 * isName(TokenKind.KwType);  // true
 * isName(TokenKind.KwConst); // false
 * ```
 *
 * @since 1.0.0
 */

export function isName(kind: TokenKind): bool {
    return kind == TokenKind.Ident || isContextual(kind);
}

/**
 * Checks whether a token kind can follow a `.` as a field or member name.
 *
 * @param kind - The kind to check
 * @returns `true` for an identifier or any keyword
 *
 * @remarks
 * After a `.` the position already marks a member, so every keyword, reserved ones included, can name a field there.
 * The parser also uses it to accept a keyword as the name after a dot in a qualified type.
 *
 * @example
 * ```hx
 * isFieldName(TokenKind.KwConst); // true, as in x.const
 * isFieldName(TokenKind.Int);     // false
 * ```
 *
 * @since 1.0.0
 */

export function isFieldName(kind: TokenKind): bool {
    return kind == TokenKind.Ident || isKeyword(kind);
}

/**
 * Returns the node kind of a literal token.
 *
 * @param kind - The token kind
 * @returns The literal node kind, or `None` when the token is not a literal
 *
 * @remarks
 * It covers the number, string, and char literals together with the keyword literals `true`, `false`, `null`,
 * `undefined`, and `unreachable`.
 * Template literals are not here, since they span several tokens.
 *
 * @example
 * ```hx
 * literalKind(TokenKind.KwNull); // NodeKind.Null
 * literalKind(TokenKind.Ident);  // NodeKind.None
 * ```
 *
 * @since 1.0.0
 */

export function literalKind(kind: TokenKind): NodeKind {
    return switch (kind) {
        case TokenKind.Int: NodeKind.Int;
        case TokenKind.Float: NodeKind.Float;
        case TokenKind.String: NodeKind.String;
        case TokenKind.Char: NodeKind.Char;
        case TokenKind.KwTrue: NodeKind.True;
        case TokenKind.KwFalse: NodeKind.False;
        case TokenKind.KwNull: NodeKind.Null;
        case TokenKind.KwUndefined: NodeKind.Undefined;
        case TokenKind.KwUnreachable: NodeKind.Unreachable;
        default: NodeKind.None;
    };
}

/**
 * Checks whether a token kind can start an expression.
 *
 * @param kind - The kind to check
 * @returns `true` when an expression may begin with it
 *
 * @remarks
 * It decides whether `return` and `void` take an operand.
 *
 * @example
 * ```hx
 * canStartExpression(TokenKind.Minus);     // true
 * canStartExpression(TokenKind.Semicolon); // false
 * ```
 *
 * @since 1.0.0
 */

export function canStartExpression(kind: TokenKind): bool {
    if (isName(kind) || literalKind(kind) != NodeKind.None) return true;
    return switch (kind) {
        case TokenKind.TemplateFull, TokenKind.TemplateHead, TokenKind.Builtin, TokenKind.Lparen, TokenKind.Lbracket,
             TokenKind.Lbrace, TokenKind.Dot, TokenKind.Minus, TokenKind.Bang, TokenKind.Tilde, TokenKind.Amp,
             TokenKind.Star, TokenKind.Question, TokenKind.KwTry, TokenKind.KwComptime, TokenKind.KwThrow,
             TokenKind.KwVoid, TokenKind.KwSwitch, TokenKind.KwImport, TokenKind.KwStruct: true;
        default: false;
    };
}

/**
 * Checks whether a token kind starts a statement by itself.
 *
 * @param kind - The kind to check
 * @returns `true` for a statement keyword
 *
 * @remarks
 * Error recovery stops at one of these tokens inside a block, since a new statement can begin there.
 * An identifier or another expression token may also start a statement, but it is not listed here.
 *
 * @example
 * ```hx
 * startsStatement(TokenKind.KwDefer); // true
 * startsStatement(TokenKind.Ident);   // false
 * ```
 *
 * @since 1.0.0
 */

export function startsStatement(kind: TokenKind): bool {
    return switch (kind) {
        case TokenKind.KwConst, TokenKind.KwLet, TokenKind.KwReturn, TokenKind.KwThrow, TokenKind.KwBreak,
             TokenKind.KwContinue, TokenKind.KwIf, TokenKind.KwWhile, TokenKind.KwFor, TokenKind.KwSwitch,
             TokenKind.KwDefer, TokenKind.KwErrdefer, TokenKind.KwUnsafe: true;
        default: false;
    };
}

/**
 * Checks whether a token kind starts a top-level declaration.
 *
 * @param kind - The kind to check
 * @returns `true` for a declaration keyword
 *
 * @remarks
 * Error recovery at the top level stops at one of these tokens, since a new declaration can begin there.
 * The list shares `const` and `let` with {@link startsStatement},
 * since both keywords declare a binding at the top level as well as inside a block.
 *
 * @example
 * ```hx
 * startsDeclaration(TokenKind.KwStruct); // true
 * startsDeclaration(TokenKind.KwReturn); // false
 * ```
 *
 * @since 1.0.0
 */

export function startsDeclaration(kind: TokenKind): bool {
    return switch (kind) {
        case TokenKind.KwImport, TokenKind.KwExport, TokenKind.KwExtern, TokenKind.KwFunction, TokenKind.KwStruct,
             TokenKind.KwEnum, TokenKind.KwUnion, TokenKind.KwInterface, TokenKind.KwConst, TokenKind.KwLet,
             TokenKind.KwComptime: true;
        default: false;
    };
}

/**
 * Checks whether the `(` at the current position starts a parameter list.
 *
 * @param p - The parser state
 * @returns `true` for `()` followed by `=>` or `:`, for `(comptime`, and for `(name:`
 *
 * @remarks
 * Those openings can only start a parameter list, never a parenthesized value.
 *
 * @example
 * ```hx
 * looksLikeParameterList(p); // true at (a: i32) => a
 * looksLikeParameterList(p); // false at (a + b) * c
 * ```
 *
 * @since 1.0.0
 */

export function looksLikeParameterList(p: *Parser): bool {
    // at `(`: `()` or `(name:` or `(comptime` can only be a parameter list, never a parenthesized value
    const first = peekKind(p, 1);
    if (first == TokenKind.Rparen) {
        const after = peekKind(p, 2);
        return after == TokenKind.Arrow || after == TokenKind.Colon;
    }
    if (first == TokenKind.KwComptime) return true;
    return isName(first) && peekKind(p, 2) == TokenKind.Colon;
}

/**
 * Decides whether the `<` after a name starts type arguments or a less-than.
 *
 * @param p - The parser state
 * @returns `true` when the tokens read as type arguments
 *
 * @remarks
 * The tokens up to the matching `>` must all fit in a type,
 * and the `>` must be followed by `.`, `(`, `{`, or a closing token.
 * So `ArrayList<u8>.init(a)` is generic and `a < b && c > d` is not.
 *
 * @example
 * ```hx
 * looksLikeGenericArgs(p); // true at the < of ArrayList<u8>.init(a)
 * looksLikeGenericArgs(p); // false at the < of a < b && c > d
 * ```
 *
 * @since 1.0.0
 */

export function looksLikeGenericArgs(p: *Parser): bool {
    let angle: u32 = 0;
    let nest: u32 = 0;
    for (const i of p.pos..p.pos + GenericLookahead) {
        const kind = kindAt(p, i);
        switch (kind) {
            case TokenKind.Lt: angle += 1;
            case TokenKind.Gt: {
                if (nest > 0) return false;
                angle -= 1;
                if (angle == 0) {
                    return switch (kindAt(p, i + 1)) {
                        case TokenKind.Dot, TokenKind.Lparen, TokenKind.Lbrace, TokenKind.Rparen, TokenKind.Comma,
                             TokenKind.Semicolon, TokenKind.Rbracket: true;
                        default: false;
                    };
                }
            }
            case TokenKind.Lparen, TokenKind.Lbracket: nest += 1;
            case TokenKind.Rparen, TokenKind.Rbracket: {
                if (nest == 0) return false;
                nest -= 1;
            }
            case TokenKind.Comma, TokenKind.Question, TokenKind.Star, TokenKind.Dot, TokenKind.Pipe, TokenKind.Int,
                 TokenKind.Colon, TokenKind.Arrow, TokenKind.KwVoid, TokenKind.KwStruct: {}
            default: {
                if (!isName(kind)) return false;
            }
        }
    }
    return false;
}

/**
 * Checks whether the current member is a method.
 *
 * @param p - The parser state
 * @returns `true` when a name is followed by `(` or `<`
 *
 * @remarks
 * Fields, enum members, and variants are followed by `:`, `=`, or `,` instead.
 *
 * @example
 * ```hx
 * atMethod(p); // true at rename(this: *User) { } inside a struct body
 * ```
 *
 * @since 1.0.0
 */

export function atMethod(p: *Parser): bool {
    return isName(currentKind(p)) && (peekKind(p, 1) == TokenKind.Lparen || peekKind(p, 1) == TokenKind.Lt);
}

/**
 * Checks whether a token is an identifier with a given text.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @param word - The text to compare with
 * @returns `true` when the token is that identifier
 *
 * @remarks
 * It matches identifiers only, so it recognizes names such as `describe` and `timeout`
 * that the lexer does not treat as keywords.
 * The comparison is byte by byte and case sensitive.
 *
 * @example
 * ```hx
 * tokenIs(p, 0, "describe"); // true at describe("parser") { }
 * ```
 *
 * @since 1.0.0
 */

export function tokenIs(p: *Parser, token: u32, word: string): bool {
    if (kindAt(p, token) != TokenKind.Ident) return false;
    const t = tokenSource(p, token);
    if (t.len != word.len) return false;
    for (const c, i of word) {
        if (t[i] != c) return false;
    }
    return true;
}

/**
 * Checks whether the current token starts a test item.
 *
 * @param p - The parser state
 * @returns `true` for `describe(`, `test(`, or `it(`, with or without a modifier such as `.skip`
 *
 * @remarks
 * `describe`, `test`, and `it` are plain identifiers, so this lookahead is what tells a test item from a call.
 * The modifier form needs exactly a dot, one identifier, and a `(`.
 *
 * @example
 * ```hx
 * atTestItem(p); // true at test.skip("reads a float") { }
 * ```
 *
 * @since 1.0.0
 */

export function atTestItem(p: *Parser): bool {
    if (!tokenIs(p, p.pos, "describe") && !tokenIs(p, p.pos, "test") && !tokenIs(p, p.pos, "it")) return false;
    return peekKind(p, 1) == TokenKind.Lparen ||
           (peekKind(p, 1) == TokenKind.Dot && peekKind(p, 2) == TokenKind.Ident && peekKind(p, 3) == TokenKind.Lparen);
}

/**
 * Checks whether the current token starts a hook.
 *
 * @param p - The parser state
 * @returns `true` for a hook name followed by `{` or `(`
 *
 * @remarks
 * The hook names come from {@link HookNames} and are plain identifiers,
 * so the lookahead requires a `{` or `(` right after the name to tell a hook from an ordinary expression.
 *
 * @example
 * ```hx
 * atHook(p); // true at beforeEach { reset(); }
 * ```
 *
 * @since 1.0.0
 */

export function atHook(p: *Parser): bool {
    if (peekKind(p, 1) != TokenKind.Lbrace && peekKind(p, 1) != TokenKind.Lparen) return false;
    for (const name of HookNames) {
        if (tokenIs(p, p.pos, name)) return true;
    }
    return false;
}
