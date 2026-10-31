/**
 * Imports
 */

import { DiagError } from "@constants/diagnostic.constant";
import { NodeKind, NoToken } from "@constants/ast.constant";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { isKeyword, spelling } from "@modules/lexer/components/token.component";
import { NoDiag, Sync, MaxDepth } from "@modules/parser/constants/parser.constant";
import { emit, emitf, hint as diagHint, hintf as diagHintf } from "@models/diagnostic.model";
import { currentKind, isFieldName, isName, kindAt } from "@modules/parser/components/cursor.component";
import { startsDeclaration, startsStatement, acceptToken } from "@modules/parser/components/cursor.component";
import { tokenLength, tokenSource, tokenStart, literalKind } from "@modules/parser/components/cursor.component";
import { advanceToken, atHook, atKind, atMethod, atTestItem } from "@modules/parser/components/cursor.component";

/**
 * Describes a token for the `found` part of a message.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @param out - The buffer that holds the description
 * @param used - The variable that receives the number of bytes used
 * @returns A description such as identifier `x`, keyword `if`, or `)`
 *
 * @remarks
 * Long token text is cut to 40 bytes, so the description fits in the buffer.
 *
 * @example
 * ```hx
 * describeToken(p, token, &buf, &used); // 'identifier `x`'
 * describeToken(p, eof, &buf, &used);   // 'end of file'
 * ```
 *
 * @since 1.0.0
 */

export function describeToken(p: *Parser, token: u32, out: *u8[64], used: *usize): string {
    const kind = kindAt(p, token);
    let word = tokenSource(p, token);
    if (word.len > 40) word = word[0..40];
    const plain = kind == TokenKind.Eof || kind == TokenKind.Invalid || literalKind(kind) != NodeKind.None ||
                  kind == TokenKind.Builtin || ((kind as u8) >= (TokenKind.TemplateFull as u8) &&
                                                (kind as u8) <= (TokenKind.TemplateTail as u8));
    let prefix: string = "`";
    if (kind == TokenKind.Ident) prefix = "identifier `";
    else if (isKeyword(kind)) prefix = "keyword `";
    else if (plain) return spelling(kind);
    else word = spelling(kind);
    // prefix + word + "`" in `out`
    let n: usize = 0;
    for (const c of prefix) {
        out[n] = c;
        n += 1;
    }
    for (const c of word) {
        out[n] = c;
        n += 1;
    }
    out[n] = '`';
    n += 1;
    *used = n;
    return out[0..n];
}

/**
 * Reports a syntax error and enters panic mode.
 *
 * @param p - The parser state
 * @param offset - The offset of the first byte of the span
 * @param len - The length of the span in bytes
 * @param message - The template that gives the message
 * @returns The index of the diagnostic, or {@link NoDiag} while the parser is already recovering
 *
 * @remarks
 * Only the first error until the parser resynchronizes is reported.
 *
 * @example
 * ```hx
 * errorAt(p, 4, 1, `expected ${what}`); // the index of the new diagnostic
 * errorAt(p, 9, 1, `expected ${what}`); // NoDiag, while the parser recovers
 * ```
 *
 * @since 1.0.0
 */

export function errorAt(p: *Parser, offset: u32, len: u32, message: Format): u32 {
    if (p.panicking) return NoDiag;
    p.panicking = true;
    return emitf(p.diags, DiagError, p.src, offset, len, message);
}

/**
 * Attaches a hint to a diagnostic that this run reported.
 *
 * @param p - The parser state
 * @param diag - The index of the diagnostic, where {@link NoDiag} drops the hint
 * @param message - The hint
 *
 * @remarks
 * Dropping the hint on {@link NoDiag} lets a caller attach one right after reporting,
 * even when panic mode suppressed the error itself.
 *
 * @example
 * ```hx
 * attachHint(p, diag, "add a matching `}`");
 * ```
 *
 * @since 1.0.0
 */

export function attachHint(p: *Parser, diag: u32, message: string): void {
    if (diag != NoDiag) diagHint(p.diags, diag, message);
}

/**
 * Attaches a hint whose text is a template.
 *
 * @param p - The parser state
 * @param diag - The index of the diagnostic, where {@link NoDiag} drops the hint
 * @param message - The template that gives the hint
 *
 * @remarks
 * Use it instead of {@link attachHint} when the hint quotes source text such as a name.
 * Like that function, it drops the hint when the error itself was suppressed.
 *
 * @example
 * ```hx
 * attachHintf(p, diag, `write \`${name} { ... }\``);
 * ```
 *
 * @since 1.0.0
 */

export function attachHintf(p: *Parser, diag: u32, message: Format): void {
    if (diag != NoDiag) diagHintf(p.diags, diag, message);
}

/**
 * Reports a syntax error over a token.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @param message - The message
 * @returns The index of the diagnostic, or {@link NoDiag}
 *
 * @remarks
 * It goes through {@link errorAt}, so it enters panic mode and reports nothing while the parser is already recovering.
 * Use {@link reportDisallowed} instead for a construct that parses fine but is not allowed.
 *
 * @example
 * ```hx
 * errorToken(p, p.pos, "comparison operators cannot be chained");
 * ```
 *
 * @since 1.0.0
 */

export function errorToken(p: *Parser, token: u32, message: string): u32 {
    return errorAt(p, tokenStart(p, token), tokenLength(p, token), `${message}`);
}

/**
 * Reports a construct that the parser understands but does not allow.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @param message - The message
 * @returns The index of the diagnostic
 *
 * @remarks
 * It does not enter panic mode, so the parser goes on normally and still reports any later syntax error.
 * A function declared inside another function is an example.
 *
 * @example
 * ```hx
 * reportDisallowed(p, token, "functions can't be declared inside a function");
 * ```
 *
 * @since 1.0.0
 */

export function reportDisallowed(p: *Parser, token: u32, message: string): u32 {
    return emit(p.diags, DiagError, p.src, tokenStart(p, token), tokenLength(p, token), message);
}

/**
 * Reports that something was expected where the current token stands.
 *
 * @param p - The parser state
 * @param what - What was expected, as it reads after `expected`
 * @returns The index of the diagnostic, or {@link NoDiag}
 *
 * @remarks
 * The found part describes the current token through {@link describeToken}.
 * At the end of the file the token is empty, so the span widens to 1 byte to stay visible.
 *
 * @example
 * ```hx
 * errorExpected(p, "a type"); // error: expected a type, found `)`
 * ```
 *
 * @since 1.0.0
 */

export function errorExpected(p: *Parser, what: string): u32 {
    let buf: u8[64] = undefined;
    let used: usize = 0;
    const found = describeToken(p, p.pos, &buf, &used);
    const len = tokenLength(p, p.pos);
    return errorAt(p, tokenStart(p, p.pos), len != 0 ? len : 1, `expected ${what}, found ${found}`);
}

/**
 * Consumes a token of a kind, or reports that it is missing.
 *
 * @param p - The parser state
 * @param kind - The kind to expect
 * @returns The index of the token, or {@link NoToken} when it is missing
 *
 * @remarks
 * The position does not move when the token is missing, so the caller goes on as if it were there.
 * The expected spelling is quoted with backticks in the message.
 *
 * @example
 * ```hx
 * expectToken(p, TokenKind.Lparen); // the index of the (
 * expectToken(p, TokenKind.Rparen); // NoToken, and error: expected `)`, found `;`
 * ```
 *
 * @since 1.0.0
 */

export function expectToken(p: *Parser, kind: TokenKind): u32 {
    if (atKind(p, kind)) return advanceToken(p);
    let buf: u8[40] = undefined;
    const what = spelling(kind);
    buf[0] = '`';
    for (const c, i of what) buf[i + 1] = c;
    buf[what.len + 1] = '`';
    void errorExpected(p, buf[0..what.len + 2]);
    return NoToken;
}

/**
 * Consumes a name, or reports that one is missing.
 *
 * @param p - The parser state
 * @param what - What the name is for, as it reads after `expected`
 * @returns The index of the name, or {@link NoToken} when it is missing
 *
 * @remarks
 * A reserved keyword in its place draws a hint that says so.
 *
 * @example
 * ```hx
 * expectName(p, "a variable name"); // the index of the name in let count = 0;
 * ```
 *
 * @since 1.0.0
 */

export function expectName(p: *Parser, what: string): u32 {
    if (isName(currentKind(p))) return advanceToken(p);
    const diag = errorExpected(p, what);
    if (isKeyword(currentKind(p))) attachHintf(p, diag, `\`${spelling(currentKind(p))}\` is a reserved keyword`);
    return NoToken;
}

/**
 * Consumes a field or member name after a `.`, or reports that one is missing.
 *
 * @param p - The parser state
 * @returns The index of the name, or {@link NoToken} when it is missing
 *
 * @remarks
 * Any keyword is accepted after a dot, so `x.const` reads a field named `const`.
 * It reports through {@link errorExpected} and leaves the position alone when no name follows.
 *
 * @example
 * ```hx
 * expectFieldName(p); // the index of len in buffer.len
 * ```
 *
 * @since 1.0.0
 */

export function expectFieldName(p: *Parser): u32 {
    if (isFieldName(currentKind(p))) return advanceToken(p);
    void errorExpected(p, "a field name");
    return NoToken;
}

/**
 * Consumes a `;`, or reports that one is missing.
 *
 * @param p - The parser state
 * @param after - What the semicolon ends, as it reads after `after`
 *
 * @remarks
 * A missing `;` is reported right after the previous token, where it belongs,
 * rather than at the token that starts the next line.
 *
 * @example
 * ```hx
 * expectSemicolon(p, "the declaration"); // error: expected `;` after the declaration, found ...
 * ```
 *
 * @since 1.0.0
 */

export function expectSemicolon(p: *Parser, after: string): void {
    if (acceptToken(p, TokenKind.Semicolon)) return;
    if (p.panicking) return;
    const prev = p.pos > 0 ? p.pos - 1 : 0;
    const end = tokenStart(p, prev) + tokenLength(p, prev);
    let buf: u8[64] = undefined;
    let used: usize = 0;
    const found = describeToken(p, p.pos, &buf, &used);
    void errorAt(p, end, 1, `expected \`;\` after ${after}, found ${found}`);
}

/**
 * Consumes the `>` that closes a list of type arguments or type parameters.
 *
 * @param p - The parser state
 *
 * @remarks
 * A `>=` there is almost always a `>` followed by `=`, as in `List<u8>= x`, so the hint asks for a space.
 *
 * @example
 * ```hx
 * expectGenericClose(p); // consumes the > of List<u8>
 * ```
 *
 * @since 1.0.0
 */

export function expectGenericClose(p: *Parser): void {
    if (acceptToken(p, TokenKind.Gt)) return;
    if (atKind(p, TokenKind.GtEq)) {
        const diag = errorToken(p, p.pos, "`>=` here is read as one operator");
        attachHint(p, diag, "add a space between `>` and `=`");
        return;
    }
    void errorExpected(p, "`>` to close the type arguments");
}

/**
 * Enters one more level of nesting.
 *
 * @param p - The parser state
 * @returns `false` after reporting that the nesting is too deep
 *
 * @remarks
 * Every successful call is paired with {@link leaveNesting}.
 *
 * @example
 * ```hx
 * if (!enterNesting(p)) return invalidNode(p);
 * // parse the nested construct
 * leaveNesting(p);
 * ```
 *
 * @since 1.0.0
 */

export function enterNesting(p: *Parser): bool {
    p.depth += 1;
    if (p.depth <= MaxDepth) return true;
    void errorToken(p, p.pos, "expression or block is nested too deeply");
    return false;
}

/**
 * Leaves one level of nesting.
 *
 * @param p - The parser state
 *
 * @remarks
 * Call it only after {@link enterNesting} returned `true`,
 * since a failed enter is not paired and the depth then unwinds as the parser returns.
 *
 * @example
 * ```hx
 * leaveNesting(p); // after a successful enterNesting(p)
 * ```
 *
 * @since 1.0.0
 */

export function leaveNesting(p: *Parser): void {
    p.depth -= 1;
}

/**
 * Skips tokens until parsing can resume in a list.
 *
 * @param p - The parser state
 * @param mode - The kind of list being recovered
 *
 * @remarks
 * Brackets are skipped as a whole, so a `;` inside a nested block does not end the skip.
 * It may stop without moving when the error left the parser right at a new item,
 * and {@link recover} then makes sure the enclosing loop still moves forward.
 *
 * @example
 * ```hx
 * synchronize(p, Sync.Statement); // skips let = 1 and stops after its ;
 * ```
 *
 * @since 1.0.0
 */

export function synchronize(p: *Parser, mode: Sync): void {
    let depth: u32 = 0;
    while (true) {
        const kind = currentKind(p);
        if (kind == TokenKind.Eof) return;
        if (depth == 0) {
            if (kind == TokenKind.Semicolon) {
                void advanceToken(p);
                return;
            }
            if (kind == TokenKind.Comma && mode == Sync.Member) {
                void advanceToken(p);
                return;
            }
            if (kind == TokenKind.Rbrace && mode != Sync.Declaration) return;
            switch (mode) {
                case Sync.Statement: {
                    if (startsStatement(kind) || kind == TokenKind.KwCase || kind == TokenKind.KwDefault) return;
                    if (atTestItem(p) || atHook(p)) return;   // inside a `describe`
                }
                case Sync.Declaration: {
                    if (startsDeclaration(kind) || atTestItem(p)) return;
                }
                case Sync.Member: {
                    if (kind == TokenKind.KwFunction || kind == TokenKind.KwConst || atMethod(p)) return;
                }
                case Sync.Case: {
                    if (kind == TokenKind.KwCase || kind == TokenKind.KwDefault) return;
                }
            }
        }
        if (kind == TokenKind.Lbrace || kind == TokenKind.Lparen || kind == TokenKind.Lbracket) {
            depth += 1;
        } else if ((kind == TokenKind.Rbrace || kind == TokenKind.Rparen || kind == TokenKind.Rbracket) && depth > 0) {
            depth -= 1;
        }
        void advanceToken(p);
    }
}

/**
 * Resynchronizes after an item of a list and makes sure the list loop moves forward.
 *
 * @param p - The parser state
 * @param mode - The kind of list being parsed
 * @param before - The token position where the item started
 *
 * @remarks
 * It leaves panic mode, so the next error is reported again.
 *
 * @example
 * ```hx
 * recover(p, Sync.Member, before); // resumes at the next member of the body
 * ```
 *
 * @since 1.0.0
 */

export function recover(p: *Parser, mode: Sync, before: u32): void {
    if (p.panicking) {
        synchronize(p, mode);
        p.panicking = false;
    }
    if (p.pos == before) void advanceToken(p);
}

/**
 * Consumes the `,` or `;` after a member.
 *
 * @param p - The parser state
 *
 * @remarks
 * Nothing is needed before the closing `}`.
 *
 * @example
 * ```hx
 * expectMemberSeparator(p); // consumes the , between x: f32 and y: f32
 * ```
 *
 * @since 1.0.0
 */

export function expectMemberSeparator(p: *Parser): void {
    if (acceptToken(p, TokenKind.Comma) || acceptToken(p, TokenKind.Semicolon)) return;
    if (atKind(p, TokenKind.Rbrace)) return;
    void errorExpected(p, "`,` after the member");
}

/**
 * Reports a `function` keyword in front of a method, then moves past it.
 *
 * @param p - The parser state
 *
 * @remarks
 * Methods are written like the methods of a TypeScript class.
 *
 * @example
 * ```hx
 * rejectMethodKeyword(p); // reports the function of function rename() {} inside a struct
 * ```
 *
 * @since 1.0.0
 */

export function rejectMethodKeyword(p: *Parser): void {
    if (!atKind(p, TokenKind.KwFunction)) return;
    const diag = reportDisallowed(p, p.pos, "methods are written without `function`");
    attachHint(p, diag, "write `name(...) { ... }`, as in a TypeScript class");
    void advanceToken(p);
}
