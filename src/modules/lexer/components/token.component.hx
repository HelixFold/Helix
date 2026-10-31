/**
 * Imports
 */

import { TokenKind, TOKEN_NAMES, TOKEN_SPELLINGS } from "@modules/lexer/constants/token.constant";

/**
 * Returns the name of a token kind, as `helix tokens` prints it.
 *
 * @param kind - The kind as a number
 * @returns The NUL-terminated name, or `?` for a number that names no kind
 *
 * @example
 * ```ts
 * hx_token_name(TokenKind.KwConst as u32); // 'KW_CONST'
 * hx_token_name(500);                      // '?'
 * ```
 *
 * @see TOKEN_NAMES
 * @since 1.0.0
 */

export extern "C" function hx_token_name(kind: u32): readonly u8[*] {
    return kind < TOKEN_NAMES.len ? TOKEN_NAMES[kind].ptr : "?";
}

/**
 * Returns the spelling of a token kind, as diagnostics print it.
 *
 * @param kind - The kind as a number
 * @returns The NUL-terminated spelling or description, or `?` for a number that names no kind
 *
 * @example
 * ```ts
 * hx_token_spelling(TokenKind.Arrow as u32); // '=>'
 * hx_token_spelling(TokenKind.Ident as u32); // 'identifier'
 * ```
 *
 * @see spelling
 * @since 1.0.0
 */

export extern "C" function hx_token_spelling(kind: u32): readonly u8[*] {
    return kind < TOKEN_SPELLINGS.len ? TOKEN_SPELLINGS[kind].ptr : "?";
}

/**
 * Returns the keyword that a word spells, or `Ident` when it spells none.
 *
 * @param word - The word to look up
 * @returns The keyword kind, or {@link TokenKind.Ident}
 *
 * @remarks
 * A contextual keyword is still returned as a keyword here.
 * The parser decides where {@link isContextual} lets it serve as a name.
 *
 * @example
 * ```ts
 * keyword("const");    // TokenKind.KwConst
 * keyword("constant"); // TokenKind.Ident
 * ```
 *
 * @see hx_keyword_lookup
 * @since 1.0.0
 */

export function keyword(word: string): TokenKind {
    return switch (word) {
        case "as": TokenKind.KwAs;
        case "break": TokenKind.KwBreak;
        case "case": TokenKind.KwCase;
        case "catch": TokenKind.KwCatch;
        case "comptime": TokenKind.KwComptime;
        case "const": TokenKind.KwConst;
        case "continue": TokenKind.KwContinue;
        case "default": TokenKind.KwDefault;
        case "defer": TokenKind.KwDefer;
        case "dyn": TokenKind.KwDyn;
        case "else": TokenKind.KwElse;
        case "enum": TokenKind.KwEnum;
        case "errdefer": TokenKind.KwErrdefer;
        case "error": TokenKind.KwError;
        case "export": TokenKind.KwExport;
        case "extends": TokenKind.KwExtends;
        case "extern": TokenKind.KwExtern;
        case "false": TokenKind.KwFalse;
        case "for": TokenKind.KwFor;
        case "from": TokenKind.KwFrom;
        case "function": TokenKind.KwFunction;
        case "if": TokenKind.KwIf;
        case "import": TokenKind.KwImport;
        case "interface": TokenKind.KwInterface;
        case "let": TokenKind.KwLet;
        case "null": TokenKind.KwNull;
        case "of": TokenKind.KwOf;
        case "readonly": TokenKind.KwReadonly;
        case "return": TokenKind.KwReturn;
        case "struct": TokenKind.KwStruct;
        case "switch": TokenKind.KwSwitch;
        case "throw": TokenKind.KwThrow;
        case "true": TokenKind.KwTrue;
        case "try": TokenKind.KwTry;
        case "type": TokenKind.KwType;
        case "undefined": TokenKind.KwUndefined;
        case "union": TokenKind.KwUnion;
        case "unreachable": TokenKind.KwUnreachable;
        case "unsafe": TokenKind.KwUnsafe;
        case "void": TokenKind.KwVoid;
        case "while": TokenKind.KwWhile;
        default: TokenKind.Ident;
    };
}

/**
 * Returns the keyword that a text spells, as a number.
 *
 * @param text - The first byte of the text
 * @param len - The length of the text in bytes
 * @returns The keyword kind as a number, or the number of {@link TokenKind.Ident}
 *
 * @remarks
 * A text shorter than 2 or longer than 11 bytes is an identifier without a lookup,
 * since `as` is the shortest keyword and `unreachable` the longest.
 *
 * @example
 * ```ts
 * hx_keyword_lookup("while", 5); // TokenKind.KwWhile as u32
 * hx_keyword_lookup("x", 1);     // TokenKind.Ident as u32
 * ```
 *
 * @see keyword
 * @since 1.0.0
 */

export extern "C" function hx_keyword_lookup(text: readonly u8[*], len: u32): u32 {
    if (len < 2 || len > 11) return TokenKind.Ident as u32;
    unsafe {
        return keyword(text[0..len]) as u32;
    }
}

/**
 * Checks whether a token kind is a keyword.
 *
 * @param kind - The kind to check
 * @returns `true` for every keyword, contextual ones included
 *
 * @remarks
 * The keywords sit at the end of {@link TokenKind}, so this is a range check.
 *
 * @example
 * ```ts
 * isKeyword(TokenKind.KwType); // true
 * isKeyword(TokenKind.Ident);  // false
 * ```
 *
 * @see isContextual
 * @since 1.0.0
 */

export function isKeyword(kind: TokenKind): bool {
    return (kind as u8) >= (TokenKind.KwAs as u8) && (kind as u8) <= (TokenKind.KwWhile as u8);
}

/**
 * Checks whether a keyword may also serve as a name.
 *
 * @param kind - The kind to check
 * @returns `true` for `as`, `dyn`, `error`, `extends`, `from`, `of`, `readonly`, and `type`
 *
 * @remarks
 * Fields and variables can still be named after these words, so `let type = 1;` is valid.
 *
 * @example
 * ```ts
 * isContextual(TokenKind.KwType);  // true
 * isContextual(TokenKind.KwConst); // false
 * ```
 *
 * @see isKeyword
 * @since 1.0.0
 */

export function isContextual(kind: TokenKind): bool {
    return switch (kind) {
        case TokenKind.KwAs, TokenKind.KwDyn, TokenKind.KwError, TokenKind.KwExtends, TokenKind.KwFrom, TokenKind.KwOf,
             TokenKind.KwReadonly, TokenKind.KwType: true;
        default: false;
    };
}

/**
 * Returns the spelling of a token kind as a string.
 *
 * @param kind - The kind to spell
 * @returns The spelling or description from {@link TOKEN_SPELLINGS}
 *
 * @example
 * ```ts
 * spelling(TokenKind.Semicolon); // ';'
 * spelling(TokenKind.Eof);       // 'end of file'
 * ```
 *
 * @see hx_token_spelling
 * @since 1.0.0
 */

export function spelling(kind: TokenKind): string {
    return TOKEN_SPELLINGS[kind as usize];
}
