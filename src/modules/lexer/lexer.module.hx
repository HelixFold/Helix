/**
 * Imports
 */

import { DIAG_ERROR } from "@constants/diagnostic.constant";
import { HxSource } from "@models/structs/source-model.struct";
import { hx_realloc, free } from "@components/memory.component";
import { keyword } from "@modules/lexer/components/token.component";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { emit, emitf, hint as diagHint, hintf } from "@models/diagnostic.model";
import { HxDocComment, HxTokens, Lexer } from "@modules/lexer/structs/lexer-module.struct";
import { TokenKind, MAX_TEMPLATE_DEPTH, PRINTABLE } from "@modules/lexer/constants/token.constant";

/**
 * Checks whether a byte is a decimal digit.
 *
 * @param c - The byte to check
 * @returns `true` for `0` through `9`
 */

function isDigit(c: u8): bool {
    return c >= '0' && c <= '9';
}

/**
 * Checks whether a byte is a hex digit in either case.
 *
 * @param c - The byte to check
 * @returns `true` for a decimal digit or a letter from `a` to `f`
 */

function isHexDigit(c: u8): bool {
    return isDigit(c) || ((c | 0x20) >= 'a' && (c | 0x20) <= 'f');
}

/**
 * Checks whether a byte can start an identifier.
 *
 * @param c - The byte to check
 * @returns `true` for an ASCII letter or `_`
 */

function isIdentStart(c: u8): bool {
    return ((c | 0x20) >= 'a' && (c | 0x20) <= 'z') || c == '_';
}

/**
 * Checks whether a byte can continue an identifier.
 *
 * @param c - The byte to check
 * @returns `true` for an ASCII letter, a digit, or `_`
 */

function isIdentChar(c: u8): bool {
    return isIdentStart(c) || isDigit(c);
}

/**
 * Checks whether a byte is a printable ASCII character.
 *
 * @param c - The byte to check
 * @returns `true` from the space up to `~`
 */

function isPrint(c: u8): bool {
    return c >= 0x20 && c < 0x7f;
}

/**
 * Checks whether a byte is a digit in a base.
 *
 * @param c - The byte to check
 * @param base - The base, which is 2, 8, 10, or 16
 * @returns `true` when the byte is a digit of the base
 */

function isDigitOfBase(c: u8, base: u32): bool {
    return switch (base) {
        case 2: c == '0' || c == '1';
        case 8: c >= '0' && c <= '7';
        case 10: isDigit(c);
        default: isHexDigit(c);
    };
}

/**
 * Returns the length of the UTF-8 sequence that a lead byte starts.
 *
 * @param c - The lead byte
 * @returns The length from 1 to 4, where an invalid lead byte counts as 1 so the lexer always moves on
 */

function utf8Len(c: u8): u32 {
    if (c < 0xC0) return 1;
    if (c < 0xE0) return 2;
    if (c < 0xF0) return 3;
    return 4;
}

/**
 * Returns the byte at a distance from the current position.
 *
 * @param lx - The lexer state
 * @param ahead - How far past the current position to look
 * @returns The byte there, or 0 past the end of the file
 */

function peek(lx: *Lexer, ahead: u32): u8 {
    const index = lx.pos + ahead;
    return index < lx.len ? lx.text[index] : 0;
}

/**
 * Checks whether the lexer has reached the end of its file.
 *
 * @param lx - The lexer state
 * @returns `true` once no bytes are left
 */

function atEnd(lx: *Lexer): bool {
    return lx.pos >= lx.len;
}

/**
 * Moves the current position forward, stopping at the end of the file.
 *
 * @param lx - The lexer state
 * @param count - The number of bytes to move
 */

function advance(lx: *Lexer, count: u32): void {
    lx.pos += count;
    if (lx.pos > lx.len) lx.pos = lx.len;
}

/**
 * Grows the three token arrays to a capacity.
 *
 * @param tokens - The token stream to grow
 * @param cap - The new capacity in tokens
 */

function reserve(tokens: *HxTokens, cap: u32): void {
    unsafe {
        tokens.kinds = @ptrCast(u8[*], hx_realloc(@ptrCast(?u8[*], tokens.kinds), cap as usize));
        tokens.starts = @ptrCast(u32[*], hx_realloc(@ptrCast(?u8[*], tokens.starts), (cap as usize) * 4));
        tokens.lens = @ptrCast(u32[*], hx_realloc(@ptrCast(?u8[*], tokens.lens), (cap as usize) * 4));
    }
    tokens.cap = cap;
}

/**
 * Appends a token to a token stream, doubling the arrays when they are full.
 *
 * @param tokens - The token stream
 * @param kind - The kind of the token
 * @param start - The offset of its first byte
 * @param len - Its length in bytes
 */

function tokensPush(tokens: *HxTokens, kind: TokenKind, start: u32, len: u32): void {
    if (tokens.len == tokens.cap) reserve(tokens, tokens.cap != 0 ? tokens.cap * 2 : 256);
    unsafe {
        tokens.kinds![tokens.len] = kind as u8;
        tokens.starts![tokens.len] = start;
        tokens.lens![tokens.len] = len;
    }
    tokens.len += 1;
}

/**
 * Appends a token that runs from an offset up to the current position.
 *
 * @param lx - The lexer state
 * @param kind - The kind of the token
 * @param start - The offset of its first byte
 */

function push(lx: *Lexer, kind: TokenKind, start: u32): void {
    tokensPush(lx.out, kind, start, lx.pos - start);
}

/**
 * Moves past an operator of a known length and appends it.
 *
 * @param lx - The lexer state
 * @param kind - The kind of the operator
 * @param start - The offset of its first byte
 * @param len - Its length in bytes
 */

function pushOp(lx: *Lexer, kind: TokenKind, start: u32, len: u32): void {
    advance(lx, len);
    push(lx, kind, start);
}

/**
 * Reports an error with a fixed message.
 *
 * @param lx - The lexer state
 * @param start - The offset of the first byte of the span
 * @param len - The length of the span in bytes
 * @param message - The message
 * @returns The index of the diagnostic, for a hint
 */

function error(lx: *Lexer, start: u32, len: u32, message: string): u32 {
    return emit(lx.diags, DIAG_ERROR, lx.src, start, len, message);
}

/**
 * Attaches a hint to a diagnostic that this run reported.
 *
 * @param lx - The lexer state
 * @param diag - The index of the diagnostic
 * @param message - The hint
 */

function hint(lx: *Lexer, diag: u32, message: string): void {
    diagHint(lx.diags, diag, message);
}

/**
 * Returns a printable ASCII character as a one-byte string, for messages.
 *
 * @param c - The character, which must be printable
 * @returns A slice of {@link PRINTABLE} that holds only the character
 */

function charText(c: u8): string {
    return PRINTABLE[c - 32..c - 31];
}

/**
 * Returns the source text between two offsets, for messages.
 *
 * @param lx - The lexer state
 * @param start - The offset of the first byte
 * @param end - The offset one past the last byte
 * @returns The text, which is not copied
 */

function slice(lx: *Lexer, start: u32, end: u32): string {
    return lx.text[start..end];
}

/**
 * Moves past a block comment, which may nest, and records it when it is a doc comment.
 *
 * @param lx - The lexer state, positioned at the slash that opens the comment
 *
 * @remarks
 * Block comments nest, so every opener needs its own closer.
 * A doc comment is recorded against the index of the next token, which the lexer has not pushed yet.
 */

function skipBlockComment(lx: *Lexer): void {
    const start = lx.pos;
    const isDoc = peek(lx, 2) == '*' && peek(lx, 3) != '/';
    advance(lx, 2);

    let depth: u32 = 1;
    while (!atEnd(lx)) {
        const c = lx.text[lx.pos];
        if (c == '/' && peek(lx, 1) == '*') {
            depth += 1;
            advance(lx, 2);
        } else if (c == '*' && peek(lx, 1) == '/') {
            advance(lx, 2);
            depth -= 1;
            if (depth == 0) break;
        } else {
            advance(lx, 1);
        }
    }

    if (depth != 0) {
        const diag = error(lx, start, 2, "unterminated block comment");
        hint(lx, diag, "close it with `*/` (block comments nest, so every `/*` needs its own `*/`)");
        return;
    }

    if (isDoc) {
        const out = lx.out;
        if (out.docs_len == out.docs_cap) {
            out.docs_cap = out.docs_cap != 0 ? out.docs_cap * 2 : 16;
            unsafe {
                out.docs = @ptrCast(HxDocComment[*], hx_realloc(@ptrCast(?u8[*], out.docs), (out.docs_cap as usize) * 12));
            }
        }
        unsafe {
            out.docs![out.docs_len] = HxDocComment { token: out.len, start, len: lx.pos - start };
        }
        out.docs_len += 1;
    }
}

/**
 * Moves past whitespace and comments.
 *
 * @param lx - The lexer state
 */

function skipTrivia(lx: *Lexer): void {
    while (true) {
        const c = peek(lx, 0);
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            advance(lx, 1);
        } else if (c == '/' && peek(lx, 1) == '/') {
            while (!atEnd(lx) && lx.text[lx.pos] != '\n') lx.pos += 1;
        } else if (c == '/' && peek(lx, 1) == '*') {
            skipBlockComment(lx);
        } else {
            return;
        }
    }
}

/**
 * Moves past the digits of a base, with `_` allowed between digits.
 *
 * @param lx - The lexer state
 * @param base - The base, which is 2, 8, 10, or 16
 * @returns The number of digits read, separators not counted
 *
 * @remarks
 * A `_` that does not sit between two digits is reported, and the scan goes on.
 */

function scanDigits(lx: *Lexer, base: u32): u32 {
    let count: u32 = 0;
    while (true) {
        const c = peek(lx, 0);
        if (isDigitOfBase(c, base)) {
            advance(lx, 1);
            count += 1;
        } else if (c == '_') {
            if (count == 0 || !isDigitOfBase(peek(lx, 1), base)) {
                const diag = error(lx, lx.pos, 1, "misplaced `_` in number literal");
                hint(lx, diag, "`_` may only separate digits, as in `1_000_000`");
            }
            advance(lx, 1);
        } else {
            return count;
        }
    }
}

/**
 * Reads an integer or a float literal.
 *
 * @param lx - The lexer state, positioned at the first digit
 * @param start - The offset of the first digit
 *
 * @remarks
 * A fraction needs a digit after the dot, so `0..n` stays a range and `x.0.1` stays a field access.
 * A decimal literal with a leading zero is an error, since it reads like an octal literal in C.
 * Letters or digits that run on after the literal are reported as one invalid stretch.
 */

function lexNumber(lx: *Lexer, start: u32): void {
    let kind = TokenKind.Int;
    const prefix = peek(lx, 1) | 0x20;

    if (peek(lx, 0) == '0' && (prefix == 'x' || prefix == 'o' || prefix == 'b')) {
        const base: u32 = prefix == 'x' ? 16 : prefix == 'o' ? 8 : 2;
        advance(lx, 2);
        if (scanDigits(lx, base) == 0) {
            void emitf(lx.diags, DIAG_ERROR, lx.src, start, lx.pos - start, `missing digits after \`0${charText(prefix)}\``);
        }
    } else {
        void scanDigits(lx, 10);
        if (lx.pos - start > 1 && lx.text[start] == '0' && isDigit(lx.text[start + 1])) {
            const diag = error(lx, start, lx.pos - start, "number literal has a leading zero");
            const digits = slice(lx, start + 1, lx.pos);
            hintf(lx.diags, diag, `remove the zero, or write octal as \`0o${digits}\``);
        }

        if (peek(lx, 0) == '.' && isDigit(peek(lx, 1))) {
            advance(lx, 1);
            void scanDigits(lx, 10);
            kind = TokenKind.Float;
        }
        if ((peek(lx, 0) | 0x20) == 'e') {
            const exponent = lx.pos;
            advance(lx, 1);
            if (peek(lx, 0) == '+' || peek(lx, 0) == '-') advance(lx, 1);
            if (scanDigits(lx, 10) == 0) void error(lx, exponent, lx.pos - exponent, "missing digits in exponent");
            kind = TokenKind.Float;
        }
    }

    if (isIdentChar(peek(lx, 0))) {
        const bad = lx.pos;
        while (isIdentChar(peek(lx, 0))) advance(lx, 1);
        void error(lx, bad, lx.pos - bad, "invalid character in number literal");
    }

    push(lx, kind, start);
}

/**
 * Checks one escape sequence and moves past it.
 *
 * @param lx - The lexer state, positioned at the backslash
 *
 * @remarks
 * The lexer only reports bad escapes, and decoding happens later.
 * A `\u{...}` escape takes 1 to 6 hex digits, up to `10FFFF`, and rejects the surrogates.
 * A backslash at the end of a line is left for the caller, which reports the unterminated literal.
 */

function scanEscape(lx: *Lexer): void {
    const start = lx.pos;
    advance(lx, 1);
    const c = peek(lx, 0);

    switch (c) {
        case 'n', 'r', 't', '0', '\\', '"', '\'', '`', '$': advance(lx, 1);
        case 'x': {
            advance(lx, 1);
            for (const _ of 0..2) {
                if (!isHexDigit(peek(lx, 0))) {
                    const diag = error(lx, start, lx.pos - start, "`\\x` escape needs exactly two hex digits");
                    hint(lx, diag, "write a byte as `\\x41`");
                    return;
                }
                advance(lx, 1);
            }
        }
        case 'u': {
            advance(lx, 1);
            if (peek(lx, 0) != '{') {
                const diag = error(lx, start, lx.pos - start, "`\\u` escape needs braces");
                hint(lx, diag, "write a code point as `\\u{1F600}`");
                return;
            }
            advance(lx, 1);

            let digits: u32 = 0;
            let value: u32 = 0;
            while (isHexDigit(peek(lx, 0))) {
                const h = peek(lx, 0);
                if (digits < 8) value = value *% 16 +% (isDigit(h) ? (h - '0') as u32 : ((h | 0x20) - 'a' + 10) as u32);
                digits += 1;
                advance(lx, 1);
            }
            if (peek(lx, 0) != '}') {
                void error(lx, start, lx.pos - start, "unterminated `\\u{...}` escape");
                return;
            }
            advance(lx, 1);
            if (digits == 0 || digits > 6 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
                const diag = error(lx, start, lx.pos - start, "invalid unicode code point");
                hint(lx, diag, "use 1 to 6 hex digits, up to 10FFFF, excluding surrogates D800-DFFF");
            }
        }
        case 0, '\n': {}
        default: {
            if (isPrint(c)) {
                const diag = emitf(lx.diags, DIAG_ERROR, lx.src, start, 2, `unknown escape sequence \`\\${charText(c)}\``);
                hint(lx, diag, "valid escapes: \\n \\r \\t \\0 \\\\ \\\" \\' \\` \\$ \\xNN \\u{N}");
            } else {
                void error(lx, start, 1, "unknown escape sequence");
            }
            advance(lx, utf8Len(c));
        }
    }
}

/**
 * Reads a string literal.
 *
 * @param lx - The lexer state, positioned at the opening quote
 * @param start - The offset of the opening quote
 *
 * @remarks
 * A string cannot span lines, and the hint points to template literals for text that does.
 */

function lexString(lx: *Lexer, start: u32): void {
    advance(lx, 1);
    while (true) {
        const c = peek(lx, 0);
        if (atEnd(lx) || c == '\n') {
            const diag = error(lx, start, lx.pos - start, "unterminated string literal");
            hint(lx, diag, "close it with `\"`; use a template literal (`...`) for multi-line text");
            break;
        }
        if (c == '"') {
            advance(lx, 1);
            break;
        }
        if (c == '\\') scanEscape(lx);
        else advance(lx, 1);
    }
    push(lx, TokenKind.String, start);
}

/**
 * Reads a character literal.
 *
 * @param lx - The lexer state, positioned at the opening quote
 * @param start - The offset of the opening quote
 *
 * @remarks
 * The literal must hold exactly one character, which may be an escape or a multibyte UTF-8 character.
 * Several characters draw a hint toward double quotes, since the author most likely meant a string.
 */

function lexChar(lx: *Lexer, start: u32): void {
    advance(lx, 1);
    let count: u32 = 0;
    while (true) {
        const c = peek(lx, 0);
        if (atEnd(lx) || c == '\n') {
            void error(lx, start, lx.pos - start, "unterminated character literal");
            push(lx, TokenKind.Char, start);
            return;
        }
        if (c == '\'') {
            advance(lx, 1);
            break;
        }
        if (c == '\\') scanEscape(lx);
        else advance(lx, utf8Len(c));
        count += 1;
    }

    if (count == 0) {
        void error(lx, start, lx.pos - start, "empty character literal");
    } else if (count > 1) {
        const diag = error(lx, start, lx.pos - start, "character literal may only contain one character");
        const inner = slice(lx, start + 1, lx.pos - 1);
        hintf(lx.diags, diag, `strings use double quotes: "${inner}"`);
    }
    push(lx, TokenKind.Char, start);
}

/**
 * Reads template text up to the closing backtick or the next `${`.
 *
 * @param lx - The lexer state, positioned just after the backtick or the `}` that closed a substitution
 * @param start - The offset where this part of the template starts
 * @param first - Whether this part opened with a backtick rather than a `}`
 *
 * @remarks
 * The kind of the token depends on both ends of the part: a backtick to a backtick is a full template,
 * a backtick to `${` is a head, `}` to `${` is a middle, and `}` to a backtick is a tail.
 * A `${` saves the brace depth, so that the matching `}` resumes the template.
 */

function lexTemplatePart(lx: *Lexer, start: u32, first: bool): void {
    while (true) {
        const c = peek(lx, 0);
        if (atEnd(lx)) {
            const diag = error(lx, start, 1, "unterminated template literal");
            hint(lx, diag, "close it with a backtick");
            push(lx, first ? TokenKind.TemplateFull : TokenKind.TemplateTail, start);
            return;
        }
        if (c == '`') {
            advance(lx, 1);
            push(lx, first ? TokenKind.TemplateFull : TokenKind.TemplateTail, start);
            return;
        }
        if (c == '$' && peek(lx, 1) == '{') {
            const subst = lx.pos;
            advance(lx, 2);
            if (lx.template_depth == MAX_TEMPLATE_DEPTH) {
                void error(lx, subst, 2, "template literals are nested too deeply");
                lx.brace_depth += 1;
            } else {
                lx.template_braces[lx.template_depth] = lx.brace_depth;
                lx.template_starts[lx.template_depth] = subst;
                lx.template_depth += 1;
            }
            push(lx, first ? TokenKind.TemplateHead : TokenKind.TemplateMiddle, start);
            return;
        }
        if (c == '\\') scanEscape(lx);
        else advance(lx, 1);
    }
}

/**
 * Reads an operator from the `+`, `-`, or `*` family.
 *
 * @param lx - The lexer state, positioned at the operator
 * @param start - The offset of the operator
 * @param base - The plain operator, such as `+`
 * @param baseEq - Its compound assignment, such as `+=`
 * @param wrap - Its wrapping form, such as `+%`
 * @param wrapEq - The compound assignment of the wrapping form, such as `+%=`
 * @param sat - Its saturating form, such as `+|`
 * @param satEq - The compound assignment of the saturating form, such as `+|=`
 *
 * @remarks
 * The longest match wins, so `+%=` comes before `+%`, which comes before `+=` and `+`.
 */

function lexArith(lx: *Lexer, start: u32, base: TokenKind, baseEq: TokenKind, wrap: TokenKind, wrapEq: TokenKind,
                  sat: TokenKind, satEq: TokenKind): void {
    const next = peek(lx, 1);
    const eq = peek(lx, 2) == '=';
    if (next == '%') pushOp(lx, eq ? wrapEq : wrap, start, eq ? 3 : 2);
    else if (next == '|') pushOp(lx, eq ? satEq : sat, start, eq ? 3 : 2);
    else if (next == '=') pushOp(lx, baseEq, start, 2);
    else pushOp(lx, base, start, 1);
}

/**
 * Reports a character that starts no token and pushes an invalid token over it.
 *
 * @param lx - The lexer state, positioned at the character
 * @param start - The offset of the character
 *
 * @remarks
 * A non-ASCII character is taken whole, so the message quotes it and the lexer moves past all its bytes.
 * A control byte is shown in hex.
 */

function lexInvalid(lx: *Lexer, start: u32): void {
    const c = peek(lx, 0);
    let len = utf8Len(c);
    if (start + len > lx.len) len = lx.len - start;
    if (c >= 0x80) {
        const text = slice(lx, start, start + len);
        const diag = emitf(lx.diags, DIAG_ERROR, lx.src, start, len, `unexpected non-ASCII character \`${text}\``);
        hint(lx, diag, "identifiers and operators are ASCII; non-ASCII text belongs in strings or comments");
    } else if (isPrint(c)) {
        void emitf(lx.diags, DIAG_ERROR, lx.src, start, 1, `unexpected character \`${charText(c)}\``);
    } else {
        const hex = "0123456789ABCDEF";
        void emitf(lx.diags, DIAG_ERROR, lx.src, start, 1, `unexpected byte 0x${hex[c >> 4..(c >> 4) + 1]}${hex[c & 15..(c & 15) + 1]}`);
    }
    pushOp(lx, TokenKind.Invalid, start, len);
}

/**
 * Reads one operator or punctuation token, or reports an invalid character.
 *
 * @param lx - The lexer state, positioned at the token
 * @param start - The offset of the token
 * @param c - The byte at the current position
 * @param next - The byte after it
 *
 * @remarks
 * There is no `>>` token, so the parser joins two adjacent `>` into a shift
 * and `A<B<C>>` still closes two generic lists.
 * The JavaScript operators `===` and `!==` are reported, then read as `==` and `!=` so that parsing goes on.
 * A `}` that matches an open template substitution resumes the template.
 */

function lexOperator(lx: *Lexer, start: u32, c: u8, next: u8): void {
    switch (c) {
        case '(': pushOp(lx, TokenKind.Lparen, start, 1);
        case ')': pushOp(lx, TokenKind.Rparen, start, 1);
        case '[': pushOp(lx, TokenKind.Lbracket, start, 1);
        case ']': pushOp(lx, TokenKind.Rbracket, start, 1);
        case ',': pushOp(lx, TokenKind.Comma, start, 1);
        case ';': pushOp(lx, TokenKind.Semicolon, start, 1);
        case ':': pushOp(lx, TokenKind.Colon, start, 1);
        case '~': pushOp(lx, TokenKind.Tilde, start, 1);

        case '{': {
            lx.brace_depth += 1;
            pushOp(lx, TokenKind.Lbrace, start, 1);
        }
        case '}': {
            if (lx.template_depth > 0 && lx.brace_depth == lx.template_braces[lx.template_depth - 1]) {
                lx.template_depth -= 1;
                advance(lx, 1);
                lexTemplatePart(lx, start, false);
            } else {
                if (lx.brace_depth > 0) lx.brace_depth -= 1;
                pushOp(lx, TokenKind.Rbrace, start, 1);
            }
        }

        case '.': {
            if (next == '.' && peek(lx, 2) == '.') pushOp(lx, TokenKind.Ellipsis, start, 3);
            else if (next == '.' && peek(lx, 2) == '=') pushOp(lx, TokenKind.DotDotEq, start, 3);
            else if (next == '.') pushOp(lx, TokenKind.DotDot, start, 2);
            else pushOp(lx, TokenKind.Dot, start, 1);
        }

        case '?': {
            if (next == '?' && peek(lx, 2) == '=') pushOp(lx, TokenKind.QuestionQuestionEq, start, 3);
            else if (next == '?') pushOp(lx, TokenKind.QuestionQuestion, start, 2);
            else if (next == '.') pushOp(lx, TokenKind.QuestionDot, start, 2);
            else pushOp(lx, TokenKind.Question, start, 1);
        }

        case '=': {
            if (next == '=' && peek(lx, 2) == '=') {
                const diag = error(lx, start, 3, "`===` does not exist in Helix");
                hint(lx, diag, "use `==`; Helix never coerces types, so `==` is already strict");
                pushOp(lx, TokenKind.EqEq, start, 3);
            } else if (next == '=') {
                pushOp(lx, TokenKind.EqEq, start, 2);
            } else if (next == '>') {
                pushOp(lx, TokenKind.Arrow, start, 2);
            } else {
                pushOp(lx, TokenKind.Eq, start, 1);
            }
        }

        case '!': {
            if (next == '=' && peek(lx, 2) == '=') {
                const diag = error(lx, start, 3, "`!==` does not exist in Helix");
                hint(lx, diag, "use `!=`; Helix never coerces types, so `!=` is already strict");
                pushOp(lx, TokenKind.BangEq, start, 3);
            } else if (next == '=') {
                pushOp(lx, TokenKind.BangEq, start, 2);
            } else {
                pushOp(lx, TokenKind.Bang, start, 1);
            }
        }

        case '+': {
            if (next == '+') pushOp(lx, TokenKind.PlusPlus, start, 2);
            else lexArith(lx, start, TokenKind.Plus, TokenKind.PlusEq, TokenKind.PlusPercent, TokenKind.PlusPercentEq,
                          TokenKind.PlusPipe, TokenKind.PlusPipeEq);
        }
        case '-': {
            if (next == '-') pushOp(lx, TokenKind.MinusMinus, start, 2);
            else lexArith(lx, start, TokenKind.Minus, TokenKind.MinusEq, TokenKind.MinusPercent, TokenKind.MinusPercentEq,
                          TokenKind.MinusPipe, TokenKind.MinusPipeEq);
        }
        case '*': lexArith(lx, start, TokenKind.Star, TokenKind.StarEq, TokenKind.StarPercent, TokenKind.StarPercentEq,
                           TokenKind.StarPipe, TokenKind.StarPipeEq);

        case '/': pushOp(lx, next == '=' ? TokenKind.SlashEq : TokenKind.Slash, start, next == '=' ? 2 : 1);
        case '%': pushOp(lx, next == '=' ? TokenKind.PercentEq : TokenKind.Percent, start, next == '=' ? 2 : 1);
        case '^': pushOp(lx, next == '=' ? TokenKind.CaretEq : TokenKind.Caret, start, next == '=' ? 2 : 1);

        case '&': {
            if (next == '&') pushOp(lx, TokenKind.AmpAmp, start, 2);
            else if (next == '=') pushOp(lx, TokenKind.AmpEq, start, 2);
            else pushOp(lx, TokenKind.Amp, start, 1);
        }
        case '|': {
            if (next == '|') pushOp(lx, TokenKind.PipePipe, start, 2);
            else if (next == '=') pushOp(lx, TokenKind.PipeEq, start, 2);
            else pushOp(lx, TokenKind.Pipe, start, 1);
        }

        case '<': {
            if (next == '<' && peek(lx, 2) == '=') pushOp(lx, TokenKind.LtLtEq, start, 3);
            else if (next == '<') pushOp(lx, TokenKind.LtLt, start, 2);
            else if (next == '=') pushOp(lx, TokenKind.LtEq, start, 2);
            else pushOp(lx, TokenKind.Lt, start, 1);
        }
        case '>': pushOp(lx, next == '=' ? TokenKind.GtEq : TokenKind.Gt, start, next == '=' ? 2 : 1);

        case '@': {
            if (isIdentStart(next)) {
                advance(lx, 1);
                while (isIdentChar(peek(lx, 0))) advance(lx, 1);
                push(lx, TokenKind.Builtin, start);
            } else {
                const diag = error(lx, start, 1, "expected a builtin name after `@`");
                hint(lx, diag, "builtins look like `@sizeOf(T)`");
                pushOp(lx, TokenKind.Invalid, start, 1);
            }
        }

        default: lexInvalid(lx, start);
    }
}

/**
 * Reads the next token, after the trivia before it has been skipped.
 *
 * @param lx - The lexer state, positioned at the token
 *
 * @remarks
 * Only words of 2 to 11 bytes are looked up as keywords, since no keyword is shorter or longer.
 */

function lexToken(lx: *Lexer): void {
    const start = lx.pos;
    const c = peek(lx, 0);

    if (isIdentStart(c)) {
        while (isIdentChar(peek(lx, 0))) advance(lx, 1);
        const word = slice(lx, start, lx.pos);
        push(lx, word.len >= 2 && word.len <= 11 ? keyword(word) : TokenKind.Ident, start);
        return;
    }
    if (isDigit(c)) {
        lexNumber(lx, start);
        return;
    }
    switch (c) {
        case '"': lexString(lx, start);
        case '\'': lexChar(lx, start);
        case '`': {
            advance(lx, 1);
            lexTemplatePart(lx, start, true);
        }
        default: lexOperator(lx, start, c, peek(lx, 1));
    }
}

/**
 * Splits the whole text of a source into tokens.
 *
 * @param src - The source to read
 * @param out - The token stream to fill, whose previous contents are ignored
 * @param diags - The list that receives the lexical errors
 * @returns `true` when the run reported no error
 *
 * @remarks
 * The lexer never stops early.
 * Invalid input produces a diagnostic and an invalid token, and the run goes on,
 * so a single run reports every lexical error in the file.
 * Release the tokens with {@link hx_tokens_free}, whether or not the run succeeded.
 *
 * @example
 * ```ts
 * let tokens: HxTokens = undefined;
 * hx_lex(&src, &tokens, &diags); // true for 'let a = 1;'
 * tokens.len;                    // 6, the end-of-file token included
 * hx_tokens_free(&tokens);
 * ```
 *
 * @see hx_lex_append
 * @since 1.0.0
 */

export extern "C" function hx_lex(src: readonly *HxSource, out: *HxTokens, diags: *HxDiagList): bool {
    *out = HxTokens { kinds: null, starts: null, lens: null, len: 0, cap: 0, docs: null, docs_len: 0, docs_cap: 0 };
    return hx_lex_append(src, 0, src.len, out, diags);
}

/**
 * Splits one file of a program into tokens and appends them to a token stream.
 *
 * @param src - The source that holds the file
 * @param start - The offset where the file starts
 * @param end - The offset one past where the file ends
 * @param out - The token stream to append to
 * @param diags - The list that receives the lexical errors
 * @returns `true` when this run reported no error, whatever earlier runs reported
 *
 * @remarks
 * The appended tokens end with an end-of-file token at `end`, so every file of a program closes on its own.
 * Room for about one token per 4 bytes is reserved up front, which avoids most regrowth.
 * A template substitution still open at the end of the file is reported once for each level.
 *
 * @example
 * ```ts
 * // two files in one source
 * hx_lex_append(&src, files(&src)[0].start, files(&src)[0].end, &tokens, &diags);
 * hx_lex_append(&src, files(&src)[1].start, files(&src)[1].end, &tokens, &diags);
 * // tokens: ... EOF ... EOF
 * ```
 *
 * @see hx_lex
 * @since 1.0.0
 */

export extern "C" function hx_lex_append(src: readonly *HxSource, start: u32, end: u32, out: *HxTokens,
                                         diags: *HxDiagList): bool {
    const errorsBefore = diags.error_count;
    let text: readonly u8[] = [];
    unsafe {
        text = src.text![0..end];
    }
    let lx = Lexer {
        src, text, len: end, pos: start, out, diags,
        brace_depth: 0, template_depth: 0, template_braces: undefined, template_starts: undefined,
    };

    const estimate = out.len + (end - start) / 4 + 16;
    if (out.cap < estimate) reserve(out, estimate);

    while (true) {
        skipTrivia(&lx);
        if (atEnd(&lx)) break;
        lexToken(&lx);
    }

    while (lx.template_depth > 0) {
        lx.template_depth -= 1;
        const diag = error(&lx, lx.template_starts[lx.template_depth], 2, "unterminated `${` in template literal");
        hint(&lx, diag, "close the substitution with `}` and the template with a backtick");
    }

    tokensPush(out, TokenKind.Eof, end, 0);
    return diags.error_count == errorsBefore;
}

/**
 * Releases the arrays of a token stream.
 *
 * @param tokens - The token stream to release
 *
 * @remarks
 * The stream is left empty, so releasing it twice is harmless.
 *
 * @example
 * ```ts
 * hx_tokens_free(&tokens);
 * tokens.len; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_tokens_free(tokens: *HxTokens): void {
    unsafe {
        free(@ptrCast(?u8[*], tokens.kinds));
        free(@ptrCast(?u8[*], tokens.starts));
        free(@ptrCast(?u8[*], tokens.lens));
        free(@ptrCast(?u8[*], tokens.docs));
    }
    *tokens = HxTokens { kinds: null, starts: null, lens: null, len: 0, cap: 0, docs: null, docs_len: 0, docs_cap: 0 };
}
