/**
 * Imports
 */

import { hx_ast_init } from "@models/ast.model";
import { DIAG_ERROR } from "@constants/diagnostic.constant";
import { HxSource } from "@models/structs/source-model.struct";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hx_vec_grow_impl, free } from "@components/memory.component";
import { BinaryInfo, Parser } from "@modules/parser/structs/parser-module.struct";
import { PREC_COMPARE, PREC_BIT_OR } from "@modules/parser/constants/parser.constant";
import { emit, emitf, hint as diagHint, hintf as diagHintf } from "@models/diagnostic.model";
import { isKeyword, isContextual, spelling } from "@modules/lexer/components/token.component";
import { HxTernaryData, HxCatchData, HxTestData, HxCaseData } from "@models/structs/ast-model.struct";
import { NO_DIAG, Sync, PREC_COALESCE, PREC_OR, PREC_AND } from "@modules/parser/constants/parser.constant";
import { NodeKind, BinOp, NO_TOKEN, FLAG_EXPORT, FLAG_EXTERN, FLAG_NAMESPACE } from "@constants/ast.constant";
import { TEST_PLAIN, TEST_SKIP, TEST_ONLY, TEST_TODO, TEST_PANICS, HOOK_NAMES } from "@constants/ast.constant";
import { FLAG_VARIADIC, FLAG_COMPTIME, FLAG_INCLUSIVE, FLAG_EXPR, FLAG_POINTER } from "@constants/ast.constant";
import { HxIfData, HxWhileData, HxForData, HxForOfData, HxAst, HxNode } from "@models/structs/ast-model.struct";
import { HxRange, HxImportData, HxFnData, HxContainerData, HxSliceData } from "@models/structs/ast-model.struct";
import { PREC_MUL, MAX_DEPTH, GENERIC_LOOKAHEAD, MAX_ARRAY_DIMS } from "@modules/parser/constants/parser.constant";
import { Members, PREC_BIT_XOR, PREC_BIT_AND, PREC_SHIFT, PREC_ADD } from "@modules/parser/constants/parser.constant";

/**
 * Returns the kind of a token.
 *
 * @param p - The parser state
 * @param index - The index of the token
 * @returns The kind, or the end of file past the last token
 */

function kindAt(p: *Parser, index: u32): TokenKind {
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
 */

function cur(p: *Parser): TokenKind {
    return kindAt(p, p.pos);
}

/**
 * Returns the kind of a token ahead of the current one.
 *
 * @param p - The parser state
 * @param ahead - How many tokens past the current one to look
 * @returns The kind of that token
 */

function peek(p: *Parser, ahead: u32): TokenKind {
    return kindAt(p, p.pos + ahead);
}

/**
 * Checks whether the current token is of a kind.
 *
 * @param p - The parser state
 * @param kind - The kind to compare with
 * @returns `true` when the current token has that kind
 */

function at(p: *Parser, kind: TokenKind): bool {
    return cur(p) == kind;
}

/**
 * Returns the offset where a token starts.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @returns The offset of its first byte
 */

function start(p: *Parser, token: u32): u32 {
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
 */

function length(p: *Parser, token: u32): u32 {
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
 */

function text(p: *Parser, token: u32): string {
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
 */

function advance(p: *Parser): u32 {
    const token = p.pos;
    if (cur(p) != TokenKind.Eof) p.pos += 1;
    return token;
}

/**
 * Consumes the current token when it is of a kind.
 *
 * @param p - The parser state
 * @param kind - The kind to accept
 * @returns `true` when the token was consumed
 */

function accept(p: *Parser, kind: TokenKind): bool {
    if (!at(p, kind)) return false;
    void advance(p);
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
 */

function adjacent(p: *Parser, index: u32): bool {
    return index + 1 < p.tokens.len && start(p, index) + length(p, index) == start(p, index + 1);
}

/**
 * Checks whether a token kind can serve as a name.
 *
 * @param kind - The kind to check
 * @returns `true` for an identifier or a contextual keyword such as `type` or `from`
 */

function isName(kind: TokenKind): bool {
    return kind == TokenKind.Ident || isContextual(kind);
}

/**
 * Checks whether a token kind can follow a `.` as a field or member name.
 *
 * @param kind - The kind to check
 * @returns `true` for an identifier or any keyword
 */

function isFieldName(kind: TokenKind): bool {
    return kind == TokenKind.Ident || isKeyword(kind);
}

/**
 * Returns the node kind of a literal token.
 *
 * @param kind - The token kind
 * @returns The literal node kind, or `None` when the token is not a literal
 */

function literalKind(kind: TokenKind): NodeKind {
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
 */

function canStartExpression(kind: TokenKind): bool {
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
 */

function startsStatement(kind: TokenKind): bool {
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
 */

function startsDeclaration(kind: TokenKind): bool {
    return switch (kind) {
        case TokenKind.KwImport, TokenKind.KwExport, TokenKind.KwExtern, TokenKind.KwFunction, TokenKind.KwStruct,
             TokenKind.KwEnum, TokenKind.KwUnion, TokenKind.KwInterface, TokenKind.KwConst, TokenKind.KwLet,
             TokenKind.KwComptime: true;
        default: false;
    };
}

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
 */

function describeToken(p: *Parser, token: u32, out: *u8[64], used: *usize): string {
    const kind = kindAt(p, token);
    let word = text(p, token);
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
 * @param at_ - The offset of the first byte of the span
 * @param len - The length of the span in bytes
 * @param message - The template that gives the message
 * @returns The index of the diagnostic, or {@link NO_DIAG} while the parser is already recovering
 *
 * @remarks
 * Only the first error until the parser resynchronizes is reported.
 */

function errorAt(p: *Parser, at_: u32, len: u32, message: Format): u32 {
    if (p.panicking) return NO_DIAG;
    p.panicking = true;
    return emitf(p.diags, DIAG_ERROR, p.src, at_, len, message);
}

/**
 * Attaches a hint to a diagnostic that this run reported.
 *
 * @param p - The parser state
 * @param diag - The index of the diagnostic, where {@link NO_DIAG} drops the hint
 * @param message - The hint
 */

function hint(p: *Parser, diag: u32, message: string): void {
    if (diag != NO_DIAG) diagHint(p.diags, diag, message);
}

/**
 * Attaches a hint whose text is a template.
 *
 * @param p - The parser state
 * @param diag - The index of the diagnostic, where {@link NO_DIAG} drops the hint
 * @param message - The template that gives the hint
 */

function hintf(p: *Parser, diag: u32, message: Format): void {
    if (diag != NO_DIAG) diagHintf(p.diags, diag, message);
}

/**
 * Reports a syntax error over a token.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @param message - The message
 * @returns The index of the diagnostic, or {@link NO_DIAG}
 */

function errorToken(p: *Parser, token: u32, message: string): u32 {
    return errorAt(p, start(p, token), length(p, token), `${message}`);
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
 */

function report(p: *Parser, token: u32, message: string): u32 {
    return emit(p.diags, DIAG_ERROR, p.src, start(p, token), length(p, token), message);
}

/**
 * Reports that something was expected where the current token stands.
 *
 * @param p - The parser state
 * @param what - What was expected, as it reads after `expected`
 * @returns The index of the diagnostic, or {@link NO_DIAG}
 */

function errorExpected(p: *Parser, what: string): u32 {
    let buf: u8[64] = undefined;
    let used: usize = 0;
    const found = describeToken(p, p.pos, &buf, &used);
    const len = length(p, p.pos);
    return errorAt(p, start(p, p.pos), len != 0 ? len : 1, `expected ${what}, found ${found}`);
}

/**
 * Consumes a token of a kind, or reports that it is missing.
 *
 * @param p - The parser state
 * @param kind - The kind to expect
 * @returns The index of the token, or {@link NO_TOKEN} when it is missing
 */

function expect(p: *Parser, kind: TokenKind): u32 {
    if (at(p, kind)) return advance(p);
    let buf: u8[40] = undefined;
    const what = spelling(kind);
    buf[0] = '`';
    for (const c, i of what) buf[i + 1] = c;
    buf[what.len + 1] = '`';
    void errorExpected(p, buf[0..what.len + 2]);
    return NO_TOKEN;
}

/**
 * Consumes a name, or reports that one is missing.
 *
 * @param p - The parser state
 * @param what - What the name is for, as it reads after `expected`
 * @returns The index of the name, or {@link NO_TOKEN} when it is missing
 *
 * @remarks
 * A reserved keyword in its place draws a hint that says so.
 */

function expectName(p: *Parser, what: string): u32 {
    if (isName(cur(p))) return advance(p);
    const diag = errorExpected(p, what);
    if (isKeyword(cur(p))) hintf(p, diag, `\`${spelling(cur(p))}\` is a reserved keyword`);
    return NO_TOKEN;
}

/**
 * Consumes a field or member name after a `.`, or reports that one is missing.
 *
 * @param p - The parser state
 * @returns The index of the name, or {@link NO_TOKEN} when it is missing
 */

function expectFieldName(p: *Parser): u32 {
    if (isFieldName(cur(p))) return advance(p);
    void errorExpected(p, "a field name");
    return NO_TOKEN;
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
 */

function expectSemicolon(p: *Parser, after: string): void {
    if (accept(p, TokenKind.Semicolon)) return;
    if (p.panicking) return;
    const prev = p.pos > 0 ? p.pos - 1 : 0;
    const end = start(p, prev) + length(p, prev);
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
 */

function expectGenericClose(p: *Parser): void {
    if (accept(p, TokenKind.Gt)) return;
    if (at(p, TokenKind.GtEq)) {
        const diag = errorToken(p, p.pos, "`>=` here is read as one operator");
        hint(p, diag, "add a space between `>` and `=`");
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
 * Every successful call is paired with {@link leave}.
 */

function enter(p: *Parser): bool {
    p.depth += 1;
    if (p.depth <= MAX_DEPTH) return true;
    void errorToken(p, p.pos, "expression or block is nested too deeply");
    return false;
}

/**
 * Leaves one level of nesting.
 *
 * @param p - The parser state
 */

function leave(p: *Parser): void {
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
 */

function sync(p: *Parser, mode: Sync): void {
    let depth: u32 = 0;
    while (true) {
        const kind = cur(p);
        if (kind == TokenKind.Eof) return;
        if (depth == 0) {
            if (kind == TokenKind.Semicolon) {
                void advance(p);
                return;
            }
            if (kind == TokenKind.Comma && mode == Sync.Member) {
                void advance(p);
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
        void advance(p);
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
 */

function recover(p: *Parser, mode: Sync, before: u32): void {
    if (p.panicking) {
        sync(p, mode);
        p.panicking = false;
    }
    if (p.pos == before) void advance(p);
}

/**
 * Appends a node with flags to the tree.
 *
 * @param p - The parser state
 * @param kind - The kind of the node
 * @param flags - The `FLAG_` bits of the node
 * @param token - The main token of the node
 * @param a - The first slot
 * @param b - The second slot
 * @returns The index of the new node
 */

function addFlags(p: *Parser, kind: NodeKind, flags: u8, token: u32, a: u32, b: u32): u32 {
    const ast = p.ast;
    unsafe {
        if (ast.nodes_len == ast.nodes_cap) {
            hx_vec_grow_impl(@ptrCast(*?u8[*], &ast.nodes), &ast.nodes_cap, ast.nodes_len + 1, @sizeOf(HxNode));
        }
        ast.nodes![ast.nodes_len] = HxNode { kind, flags, op: 0, token, a, b };
    }
    ast.nodes_len += 1;
    return ast.nodes_len - 1;
}

/**
 * Appends a node without flags to the tree.
 *
 * @param p - The parser state
 * @param kind - The kind of the node
 * @param token - The main token of the node
 * @param a - The first slot
 * @param b - The second slot
 * @returns The index of the new node
 */

function add(p: *Parser, kind: NodeKind, token: u32, a: u32, b: u32): u32 {
    return addFlags(p, kind, 0, token, a, b);
}

/**
 * Sets the operator field of a node.
 *
 * @param p - The parser state
 * @param id - The index of the node
 * @param op - The operator, or the mode of a test or a hook
 */

function setOp(p: *Parser, id: u32, op: u16): void {
    unsafe {
        p.ast.nodes![id].op = op;
    }
}

/**
 * Appends an invalid node at the current token.
 *
 * @param p - The parser state
 * @returns The index of the new node
 *
 * @remarks
 * Later passes skip invalid nodes, which stand in for a construct that failed to parse.
 */

function invalid(p: *Parser): u32 {
    return add(p, NodeKind.Invalid, p.pos, 0, 0);
}

/**
 * Returns the kind of a node that this run already added.
 *
 * @param p - The parser state
 * @param id - The index of the node
 * @returns The kind of the node
 */

function nodeKind(p: *Parser, id: u32): NodeKind {
    unsafe {
        return p.ast.nodes![id].kind;
    }
}

/**
 * Makes room in the extra array for more words.
 *
 * @param p - The parser state
 * @param count - The number of words to make room for
 */

function reserveExtra(p: *Parser, count: u32): void {
    const ast = p.ast;
    if (ast.extra_len + count > ast.extra_cap) {
        unsafe {
            hx_vec_grow_impl(@ptrCast(*?u8[*], &ast.extra), &ast.extra_cap, ast.extra_len + count, 4);
        }
    }
}

/**
 * Copies a record into the extra array.
 *
 * @typeParam T - The record type, one of the `Data` structs or {@link HxRange}
 * @param p - The parser state
 * @param data - The record, whose fields are all 32-bit
 * @returns The index of the first word of the record
 */

function record<T>(p: *Parser, data: T): u32 {
    const count = @truncate(u32, @sizeOf(T) / 4);
    reserveExtra(p, count);
    const index = p.ast.extra_len;
    unsafe {
        const words = @ptrCast(u32[*], &data);
        for (const i of 0..count) p.ast.extra![index + i] = words[i];
    }
    p.ast.extra_len += count;
    return index;
}

/**
 * Returns the top of the scratch stack, where a new list starts.
 *
 * @param p - The parser state
 * @returns The number of entries on the stack
 */

function scratchTop(p: *Parser): u32 {
    return p.scratch_len;
}

/**
 * Pushes a child onto the scratch stack.
 *
 * @param p - The parser state
 * @param id - The index of the child node
 */

function scratchPush(p: *Parser, id: u32): void {
    unsafe {
        if (p.scratch_len == p.scratch_cap) {
            hx_vec_grow_impl(@ptrCast(*?u8[*], &p.scratch), &p.scratch_cap, p.scratch_len + 1, 4);
        }
        p.scratch![p.scratch_len] = id;
    }
    p.scratch_len += 1;
}

/**
 * Moves the children pushed since a mark into the extra array.
 *
 * @param p - The parser state
 * @param top - The mark that {@link scratchTop} returned when the list started
 * @returns The range of the children in the extra array
 *
 * @remarks
 * The stack drops back to the mark, so the enclosing list goes on where it left off.
 */

function listFinish(p: *Parser, top: u32): HxRange {
    const count = p.scratch_len - top;
    const range = HxRange { start: p.ast.extra_len, end: p.ast.extra_len + count };
    reserveExtra(p, count);
    unsafe {
        for (const i of 0..count) p.ast.extra![range.start + i] = p.scratch![top + i];
    }
    p.ast.extra_len = range.end;
    p.scratch_len = top;
    return range;
}

/**
 * Stores a range as a record in the extra array.
 *
 * @param p - The parser state
 * @param range - The range to store
 * @returns The index of the record
 */

function rangeRecord(p: *Parser, range: HxRange): u32 {
    return record<HxRange>(p, range);
}

/**
 * Parses a list of type parameters such as `<T, U extends C>`.
 *
 * @param p - The parser state
 * @returns The range of `GenericParam` nodes, which is empty when there is no list
 */

function parseGenericParams(p: *Parser): HxRange {
    const top = scratchTop(p);
    if (accept(p, TokenKind.Lt)) {
        while (true) {
            const name = expectName(p, "a type parameter name");
            if (name == NO_TOKEN) break;
            let constraint: u32 = 0;
            if (accept(p, TokenKind.KwExtends)) constraint = parseType(p);
            scratchPush(p, add(p, NodeKind.GenericParam, name, constraint, 0));
            if (!accept(p, TokenKind.Comma)) break;
        }
        expectGenericClose(p);
    }
    return listFinish(p, top);
}

/**
 * Parses a parameter list from `(` through `)`.
 *
 * @param p - The parser state
 * @param fn - The record that receives the range of `Param` nodes
 * @param flags - The flags of the function, which gain {@link FLAG_VARIADIC} after a trailing `...`
 *
 * @remarks
 * Functions, arrow functions, and function types share it.
 * A parameter without a type is reported without panic mode, since the intent is clear.
 */

function parseParams(p: *Parser, fn: *HxFnData, flags: *u8): void {
    void expect(p, TokenKind.Lparen);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rparen) && !at(p, TokenKind.Eof)) {
        if (at(p, TokenKind.Ellipsis)) {
            void advance(p);
            *flags |= FLAG_VARIADIC;
            break;
        }
        const paramFlags = accept(p, TokenKind.KwComptime) ? FLAG_COMPTIME : 0;
        const name = expectName(p, "a parameter name");
        if (name == NO_TOKEN) break;

        let type: u32 = 0;
        if (accept(p, TokenKind.Colon)) {
            type = parseType(p);
        } else {
            // the intent is clear, so report it without entering panic mode and keep parsing the function
            const word = text(p, name);
            const diag = emitf(p.diags, DIAG_ERROR, p.src, start(p, name), length(p, name), `parameter \`${word}\` needs a type`);
            diagHintf(p.diags, diag, `write it as \`${word}: i32\`; every parameter is typed`);
            type = invalid(p);
        }
        scratchPush(p, addFlags(p, NodeKind.Param, paramFlags, name, type, 0));
        if (!accept(p, TokenKind.Comma)) break;
    }
    void expect(p, TokenKind.Rparen);
    const params = listFinish(p, top);
    fn.params_start = params.start;
    fn.params_end = params.end;
}

/**
 * Checks whether the `(` at the current position starts a parameter list.
 *
 * @param p - The parser state
 * @returns `true` for `()` followed by `=>` or `:`, for `(comptime`, and for `(name:`
 *
 * @remarks
 * Those openings can only start a parameter list, never a parenthesized value.
 */

function looksLikeParameterList(p: *Parser): bool {
    // at `(`: `()` or `(name:` or `(comptime` can only be a parameter list, never a parenthesized value
    const first = peek(p, 1);
    if (first == TokenKind.Rparen) {
        const after = peek(p, 2);
        return after == TokenKind.Arrow || after == TokenKind.Colon;
    }
    if (first == TokenKind.KwComptime) return true;
    return isName(first) && peek(p, 2) == TokenKind.Colon;
}

/**
 * Returns a function record with every range empty.
 *
 * @param abi - The ABI string token, or {@link NO_TOKEN}
 * @param firstNode - The index of the first node of the declaration
 * @returns The record
 */

function emptyFn(abi: u32, firstNode: u32): HxFnData {
    return HxFnData {
        generics_start: 0, generics_end: 0, params_start: 0, params_end: 0, return_type: 0, body: 0, abi_token: abi,
        first_node: firstNode,
    };
}

/**
 * Parses a function type such as `(a: i32) => bool`.
 *
 * @param p - The parser state
 * @returns The index of the `TypeFunction` node
 */

function parseFunctionType(p: *Parser): u32 {
    const token = p.pos;
    let fn = emptyFn(NO_TOKEN, 0);
    let flags: u8 = 0;
    parseParams(p, &fn, &flags);
    void expect(p, TokenKind.Arrow);
    fn.return_type = parseType(p);
    return addFlags(p, NodeKind.TypeFunction, flags, token, record<HxFnData>(p, fn), 0);
}

/**
 * Parses a field declaration such as `name: Type = default`.
 *
 * @param p - The parser state
 * @returns The index of the `FieldDecl` node, or 0 when the name is missing
 *
 * @remarks
 * Struct bodies and anonymous struct types share it.
 */

function parseFieldDecl(p: *Parser): u32 {
    const name = expectName(p, "a field name");
    if (name == NO_TOKEN) return 0;
    let type: u32 = 0;
    if (expect(p, TokenKind.Colon) != NO_TOKEN) type = parseType(p);
    const value = accept(p, TokenKind.Eq) ? parseExpr(p) : 0;
    return add(p, NodeKind.FieldDecl, name, type, value);
}

/**
 * Consumes the `,` or `;` after a member.
 *
 * @param p - The parser state
 *
 * @remarks
 * Nothing is needed before the closing `}`.
 */

function expectMemberSeparator(p: *Parser): void {
    if (accept(p, TokenKind.Comma) || accept(p, TokenKind.Semicolon)) return;
    if (at(p, TokenKind.Rbrace)) return;
    void errorExpected(p, "`,` after the member");
}

/**
 * Parses an anonymous struct type such as `struct { a: i32, b: i32 }`.
 *
 * @param p - The parser state
 * @returns The index of the `TypeStruct` node
 */

function parseStructType(p: *Parser): u32 {
    const token = advance(p);
    void expect(p, TokenKind.Lbrace);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const before = p.pos;
        const field = parseFieldDecl(p);
        if (field != 0) scratchPush(p, field);
        if (!p.panicking) expectMemberSeparator(p);
        recover(p, Sync.Member, before);
    }
    void expect(p, TokenKind.Rbrace);
    const fields = listFinish(p, top);
    return add(p, NodeKind.TypeStruct, token, fields.start, fields.end);
}

/**
 * Parses the type arguments after a generic name.
 *
 * @param p - The parser state
 * @param base - The node of the generic name
 * @returns The index of the `GenericInstance` node
 */

function parseGenericInstance(p: *Parser, base: u32): u32 {
    const token = advance(p);
    const top = scratchTop(p);
    while (true) {
        scratchPush(p, parseType(p));
        if (!accept(p, TokenKind.Comma)) break;
    }
    expectGenericClose(p);
    return add(p, NodeKind.GenericInstance, token, base, rangeRecord(p, listFinish(p, top)));
}

/**
 * Parses a type name, a parenthesized type, a function type, or an anonymous struct type.
 *
 * @param p - The parser state
 * @returns The index of the type node, or an invalid node
 *
 * @remarks
 * A dotted path and type arguments are read as part of the name.
 * `extern "C"` before a function type marks it as a C function type.
 */

function parsePrimaryType(p: *Parser): u32 {
    const kind = cur(p);
    if (isName(kind) || kind == TokenKind.KwVoid) {
        let type = add(p, NodeKind.Ident, advance(p), 0, 0);
        while (true) {
            if (at(p, TokenKind.Dot) && isFieldName(peek(p, 1))) {
                void advance(p);
                type = add(p, NodeKind.FieldAccess, advance(p), type, 0);
            } else if (at(p, TokenKind.Lt)) {
                type = parseGenericInstance(p, type);
            } else {
                return type;
            }
        }
    }
    switch (kind) {
        case TokenKind.KwExtern: {   // `extern "C" (a: i32) => void`: called with the C calling convention
            if (peek(p, 1) == TokenKind.String && peek(p, 2) == TokenKind.Lparen) {
                void advance(p);
                const abi = advance(p);
                const fn = parseFunctionType(p);
                unsafe {
                    const node = &p.ast.nodes![fn];
                    node.flags |= FLAG_EXTERN;
                    @ptrCast(*HxFnData, &p.ast.extra![node.a]).abi_token = abi;
                }
                return fn;
            }
        }
        case TokenKind.Lparen: {
            if (looksLikeParameterList(p)) return parseFunctionType(p);
            void advance(p);
            const inner = parseType(p);
            void expect(p, TokenKind.Rparen);
            return inner;
        }
        case TokenKind.KwStruct: return parseStructType(p);
        case TokenKind.Builtin: return parsePrimary(p);
        default: {}
    }
    const diag = errorExpected(p, "a type");
    if (kind == TokenKind.Lbracket) hint(p, diag, "array and slice types put the brackets after the element: `u8[]`");
    if (kind == TokenKind.KwExtern) hint(p, diag, "a C function type is `extern \"C\" (a: i32) => void`");
    return invalid(p);
}

/**
 * Parses the `[]`, `[*]`, and `[N]` suffixes after a type.
 *
 * @param p - The parser state
 * @param base - The node of the type before the suffixes
 * @returns The index of the outermost type node
 *
 * @remarks
 * A run of fixed sizes reads in C order, so `f32[3][4]` is 3 rows of 4 and `grid[2][3]` indexes it.
 * Slices and many-item pointers apply left to right, so `u8[4][]` is a slice of `u8[4]`.
 */

function parseTypeSuffixes(p: *Parser, base: u32): u32 {
    let type = base;
    let dims: u32[16] = undefined;
    let dimTokens: u32[16] = undefined;
    let dimCount: u32 = 0;
    while (true) {
        const slice = at(p, TokenKind.Lbracket) && peek(p, 1) == TokenKind.Rbracket;
        const many = at(p, TokenKind.Lbracket) && peek(p, 1) == TokenKind.Star && peek(p, 2) == TokenKind.Rbracket;
        const array = at(p, TokenKind.Lbracket) && !slice && !many;
        if (!array) {
            while (dimCount > 0) {
                dimCount -= 1;
                type = add(p, NodeKind.TypeArray, dimTokens[dimCount], type, dims[dimCount]);
            }
        }
        if (slice) {
            const token = advance(p);
            void advance(p);
            type = add(p, NodeKind.TypeSlice, token, type, 0);
        } else if (many) {
            const token = advance(p);
            void advance(p);
            void advance(p);
            type = add(p, NodeKind.TypeManyPointer, token, type, 0);
        } else if (array) {
            const token = advance(p);
            const len = parseExpr(p);
            void expect(p, TokenKind.Rbracket);
            if (dimCount == MAX_ARRAY_DIMS) {
                void errorToken(p, token, "too many array dimensions");
            } else {
                dims[dimCount] = len;
                dimTokens[dimCount] = token;
                dimCount += 1;
            }
        } else {
            return type;
        }
    }
}

/**
 * Parses a primary type and its suffixes.
 *
 * @param p - The parser state
 * @returns The index of the type node
 */

function parsePostfixType(p: *Parser): u32 {
    return parseTypeSuffixes(p, parsePrimaryType(p));
}

/**
 * Parses a type with its prefix operators `?`, `*`, `readonly`, and `dyn`.
 *
 * @param p - The parser state
 * @returns The index of the type node
 *
 * @remarks
 * Prefix operators bind looser than suffixes, so `?u8[]` is an optional slice.
 * A `dyn` names an interface, so the suffixes apply to it and `dyn Shape[]` is a slice of them.
 */

function parsePrefixType(p: *Parser): u32 {
    let kind = NodeKind.None;
    switch (cur(p)) {
        case TokenKind.Question: kind = NodeKind.TypeOptional;
        case TokenKind.Star: kind = NodeKind.TypePointer;
        case TokenKind.KwReadonly: kind = NodeKind.TypeReadonly;
        case TokenKind.KwDyn: {   // names an interface, so suffixes apply to the `dyn`: `dyn Shape[]` is a slice of them
            const token = advance(p);
            const iface = parsePrimaryType(p);
            return parseTypeSuffixes(p, add(p, NodeKind.TypeDyn, token, iface, 0));
        }
        default: return parsePostfixType(p);
    }
    if (!enter(p)) return invalid(p);
    const token = advance(p);
    const child = parsePrefixType(p);
    leave(p);
    return add(p, kind, token, child, 0);
}

/**
 * Parses a whole type, with error unions joined by `|`.
 *
 * @param p - The parser state
 * @returns The index of the type node
 */

function parseType(p: *Parser): u32 {
    if (!enter(p)) return invalid(p);
    let type = parsePrefixType(p);
    while (at(p, TokenKind.Pipe)) {
        const token = advance(p);
        const errorSet = parsePrefixType(p);
        type = add(p, NodeKind.TypeErrorUnion, token, type, errorSet);
    }
    leave(p);
    return type;
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
 */

function looksLikeGenericArgs(p: *Parser): bool {
    let angle: u32 = 0;
    let nest: u32 = 0;
    for (const i of p.pos..p.pos + GENERIC_LOOKAHEAD) {
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
 * Checks whether a node could name a type.
 *
 * @param p - The parser state
 * @param id - The index of the node
 * @returns `true` for an identifier, a field access, or a generic instance
 */

function isTypeLike(p: *Parser, id: u32): bool {
    const kind = nodeKind(p, id);
    return kind == NodeKind.Ident || kind == NodeKind.FieldAccess || kind == NodeKind.GenericInstance;
}

/**
 * Parses expressions separated by commas up to a closing token.
 *
 * @param p - The parser state
 * @param closing - The token that closes the list, which is consumed
 * @returns The range of the expression nodes
 *
 * @remarks
 * A trailing comma is allowed.
 */

function parseExprList(p: *Parser, closing: TokenKind): HxRange {
    const top = scratchTop(p);
    while (!at(p, closing) && !at(p, TokenKind.Eof)) {
        scratchPush(p, parseExpr(p));
        if (!accept(p, TokenKind.Comma)) break;
    }
    void expect(p, closing);
    return listFinish(p, top);
}

/**
 * Parses a struct literal such as `{ name: value, other }`.
 *
 * @param p - The parser state
 * @param type - The node of the type before the braces, or 0 for an anonymous literal
 * @returns The index of the `StructLiteral` node
 *
 * @remarks
 * A field written alone, as in `{ name }`, takes the value of the variable with the same name.
 */

function parseStructLiteral(p: *Parser, type: u32): u32 {
    const token = advance(p);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const name = expectName(p, "a field name");
        if (name == NO_TOKEN) break;
        // `{ name }` is `{ name: name }`: the value is the name's own token, read like any other use of it
        const value = accept(p, TokenKind.Colon) ? parseExpr(p) : add(p, NodeKind.Ident, name, 0, 0);
        scratchPush(p, add(p, NodeKind.FieldInit, name, value, 0));
        if (!accept(p, TokenKind.Comma)) break;
    }
    void expect(p, TokenKind.Rbrace);
    return add(p, NodeKind.StructLiteral, token, type, rangeRecord(p, listFinish(p, top)));
}

/**
 * Parses a template literal into its text segments and interpolated values.
 *
 * @param p - The parser state
 * @returns The index of the `Template` node
 */

function parseTemplate(p: *Parser): u32 {
    const first = p.pos;
    const top = scratchTop(p);
    scratchPush(p, add(p, NodeKind.TemplateText, advance(p), 0, 0));
    if (kindAt(p, first) == TokenKind.TemplateHead) {
        while (true) {
            scratchPush(p, parseExpr(p));
            if (at(p, TokenKind.TemplateMiddle)) {
                scratchPush(p, add(p, NodeKind.TemplateText, advance(p), 0, 0));
                continue;
            }
            if (at(p, TokenKind.TemplateTail)) {
                scratchPush(p, add(p, NodeKind.TemplateText, advance(p), 0, 0));
                break;
            }
            void errorExpected(p, "`}` to close the template substitution");
            break;
        }
    }
    const parts = listFinish(p, top);
    return add(p, NodeKind.Template, first, parts.start, parts.end);
}

/**
 * Parses an arrow function such as `(x: i32): i32 => x * 2`.
 *
 * @param p - The parser state
 * @returns The index of the `ArrowFunction` node
 *
 * @remarks
 * The body is a block or a single expression.
 */

function parseArrowFunction(p: *Parser): u32 {
    const token = p.pos;
    let fn = emptyFn(NO_TOKEN, p.ast.nodes_len);
    let flags: u8 = 0;
    parseParams(p, &fn, &flags);
    if (accept(p, TokenKind.Colon)) fn.return_type = parseType(p);
    void expect(p, TokenKind.Arrow);
    fn.body = at(p, TokenKind.Lbrace) ? parseBlock(p) : parseExpr(p);
    return addFlags(p, NodeKind.ArrowFunction, flags, token, record<HxFnData>(p, fn), 0);
}

/**
 * Parses a literal, a name, or a bracketed construct that starts an expression.
 *
 * @param p - The parser state
 * @returns The index of the expression node, or an invalid node
 */

function parsePrimary(p: *Parser): u32 {
    const kind = cur(p);
    const literal = literalKind(kind);
    if (literal != NodeKind.None) return add(p, literal, advance(p), 0, 0);
    if (isName(kind) || kind == TokenKind.KwVoid) return add(p, NodeKind.Ident, advance(p), 0, 0);

    switch (kind) {
        case TokenKind.TemplateFull, TokenKind.TemplateHead: return parseTemplate(p);
        case TokenKind.Builtin: {
            const token = advance(p);
            if (expect(p, TokenKind.Lparen) == NO_TOKEN) return invalid(p);
            const args = parseExprList(p, TokenKind.Rparen);
            return add(p, NodeKind.BuiltinCall, token, args.start, args.end);
        }
        case TokenKind.Lparen: {
            if (looksLikeParameterList(p)) return parseArrowFunction(p);
            void advance(p);
            const inner = parseExpr(p);
            void expect(p, TokenKind.Rparen);
            return inner;
        }
        case TokenKind.Lbracket: {
            const token = advance(p);
            const elements = parseExprList(p, TokenKind.Rbracket);
            return add(p, NodeKind.ArrayLiteral, token, elements.start, elements.end);
        }
        case TokenKind.Lbrace: return parseStructLiteral(p, 0);
        case TokenKind.Dot: {
            void advance(p);
            const name = expectFieldName(p);
            return name == NO_TOKEN ? invalid(p) : add(p, NodeKind.EnumLiteral, name, 0, 0);
        }
        case TokenKind.KwSwitch: return parseSwitch(p, true);
        case TokenKind.KwImport: {
            void advance(p);
            void expect(p, TokenKind.Lparen);
            const path = expect(p, TokenKind.String);
            void expect(p, TokenKind.Rparen);
            return path == NO_TOKEN ? invalid(p) : add(p, NodeKind.ImportExpr, path, 0, 0);
        }
        case TokenKind.KwStruct: return parseStructType(p);
        default: {
            void errorExpected(p, "an expression");
            return invalid(p);
        }
    }
}

/**
 * Parses what follows a `[` after an expression.
 *
 * @param p - The parser state
 * @param base - The node of the expression before the bracket
 * @returns The index of an `Index`, a `Slice`, or a type suffix node
 *
 * @remarks
 * It reads an index `a[i]`, a slice `a[i..j]`, or a type suffix `T[]` or `T[*]` in an expression.
 */

function parseIndexSuffix(p: *Parser, base: u32): u32 {
    const token = advance(p);
    if (accept(p, TokenKind.Rbracket)) return add(p, NodeKind.TypeSlice, token, base, 0);
    if (at(p, TokenKind.Star) && peek(p, 1) == TokenKind.Rbracket) {
        void advance(p);
        void advance(p);
        return add(p, NodeKind.TypeManyPointer, token, base, 0);
    }
    let first: u32 = 0;
    if (!at(p, TokenKind.DotDot) && !at(p, TokenKind.DotDotEq)) first = parseExpr(p);
    if (at(p, TokenKind.DotDot) || at(p, TokenKind.DotDotEq)) {
        const flags = at(p, TokenKind.DotDotEq) ? FLAG_INCLUSIVE : 0;
        void advance(p);
        const end = at(p, TokenKind.Rbracket) ? 0 : parseExpr(p);
        const slice = HxSliceData { start: first, end };
        void expect(p, TokenKind.Rbracket);
        return addFlags(p, NodeKind.Slice, flags, token, base, record<HxSliceData>(p, slice));
    }
    void expect(p, TokenKind.Rbracket);
    return add(p, NodeKind.Index, token, base, first);
}

/**
 * Parses a primary expression and its calls, indexes, field accesses, and unwraps.
 *
 * @param p - The parser state
 * @returns The index of the expression node
 *
 * @remarks
 * A `<` or `{` after a type-like expression starts type arguments or a struct literal.
 */

function parsePostfix(p: *Parser): u32 {
    let expr = parsePrimary(p);
    while (true) {
        switch (cur(p)) {
            case TokenKind.Lparen: {
                const token = advance(p);
                const args = parseExprList(p, TokenKind.Rparen);
                expr = add(p, NodeKind.Call, token, expr, rangeRecord(p, args));
            }
            case TokenKind.Lbracket: expr = parseIndexSuffix(p, expr);
            case TokenKind.Dot, TokenKind.QuestionDot: {
                const kind = at(p, TokenKind.Dot) ? NodeKind.FieldAccess : NodeKind.OptionalField;
                void advance(p);
                const name = expectFieldName(p);
                if (name == NO_TOKEN) return expr;
                expr = add(p, kind, name, expr, 0);
            }
            case TokenKind.Bang: expr = add(p, NodeKind.Unwrap, advance(p), expr, 0);
            case TokenKind.Lt: {
                if (!isTypeLike(p, expr) || !looksLikeGenericArgs(p)) return expr;
                expr = parseGenericInstance(p, expr);
            }
            case TokenKind.Lbrace: {
                if (!isTypeLike(p, expr)) return expr;
                expr = parseStructLiteral(p, expr);
            }
            default: return expr;
        }
    }
}

/**
 * Parses an expression with its prefix operators.
 *
 * @param p - The parser state
 * @returns The index of the expression node
 *
 * @remarks
 * `comptime`, `throw`, and `void` take a whole expression, and the other prefix operators take one operand.
 * `return`, `break`, and `continue` are expressions here too, as in `x ?? return 0`.
 */

function parseUnary(p: *Parser): u32 {
    let kind = NodeKind.None;
    let whole = false;
    switch (cur(p)) {
        // `x ?? return 0`, `x ?? break`, `f() catch return`: leaving as an expression, which never has a value
        case TokenKind.KwReturn: {
            const token = advance(p);
            const value = canStartExpression(cur(p)) ? parseExpr(p) : 0;
            return add(p, NodeKind.Return, token, value, 0);
        }
        case TokenKind.KwBreak, TokenKind.KwContinue: {
            const kindOf = at(p, TokenKind.KwBreak) ? NodeKind.Break : NodeKind.Continue;
            const token = advance(p);
            const label = isName(cur(p)) ? advance(p) : NO_TOKEN;
            return add(p, kindOf, token, label, 0);
        }
        case TokenKind.Minus: kind = NodeKind.Negate;
        case TokenKind.Bang: kind = NodeKind.Not;
        case TokenKind.Tilde: kind = NodeKind.BitNot;
        case TokenKind.Amp: kind = NodeKind.AddressOf;
        case TokenKind.Star: kind = NodeKind.Deref;
        case TokenKind.KwTry: kind = NodeKind.Try;
        case TokenKind.Question: kind = NodeKind.TypeOptional;
        case TokenKind.KwComptime: {
            kind = NodeKind.ComptimeExpr;
            whole = true;
        }
        case TokenKind.KwThrow: {
            kind = NodeKind.Throw;
            whole = true;
        }
        case TokenKind.KwVoid: {
            if (!canStartExpression(peek(p, 1))) return parsePostfix(p);   // `void` as a type name
            kind = NodeKind.Discard;
            whole = true;
        }
        case TokenKind.KwReadonly, TokenKind.KwDyn: {
            if (!isName(peek(p, 1)) && peek(p, 1) != TokenKind.Star) return parsePostfix(p);
            kind = at(p, TokenKind.KwReadonly) ? NodeKind.TypeReadonly : NodeKind.TypeDyn;
        }
        default: return parsePostfix(p);
    }
    if (!enter(p)) return invalid(p);
    const token = advance(p);
    const operand = whole ? parseExpr(p) : parseUnary(p);
    leave(p);
    return add(p, kind, token, operand, 0);
}

/**
 * Parses an expression and its `as` casts.
 *
 * @param p - The parser state
 * @returns The index of the expression node
 *
 * @remarks
 * A cast binds tighter than any binary operator, so `a * b as u64` reads as `a * (b as u64)`.
 */

function parseCast(p: *Parser): u32 {
    let value = parseUnary(p);
    while (at(p, TokenKind.KwAs)) {
        const token = advance(p);
        value = add(p, NodeKind.Cast, token, value, parseType(p));
    }
    return value;
}

/**
 * Returns the operator info of a left-associative binary operator of one token.
 *
 * @param prec - The precedence
 * @param op - The operator
 * @returns The operator info
 */

function info(prec: u8, op: BinOp): BinaryInfo {
    return BinaryInfo { prec, op, right: false, width: 1 };
}

/**
 * Returns how the current token acts as a binary operator.
 *
 * @param p - The parser state
 * @returns The operator info, with a precedence of 0 when the token is not one
 *
 * @remarks
 * Two adjacent `>` tokens form a `>>` shift, and a `>` touching a `>=` is the start of `>>=`, which ends the expression.
 */

function binaryInfo(p: *Parser): BinaryInfo {
    return switch (cur(p)) {
        case TokenKind.QuestionQuestion: BinaryInfo { prec: PREC_COALESCE, op: BinOp.Coalesce, right: true, width: 1 };
        case TokenKind.PipePipe: info(PREC_OR, BinOp.Or);
        case TokenKind.AmpAmp: info(PREC_AND, BinOp.And);
        case TokenKind.EqEq: info(PREC_COMPARE, BinOp.Eq);
        case TokenKind.BangEq: info(PREC_COMPARE, BinOp.Ne);
        case TokenKind.Lt: info(PREC_COMPARE, BinOp.Lt);
        case TokenKind.LtEq: info(PREC_COMPARE, BinOp.Le);
        case TokenKind.GtEq: info(PREC_COMPARE, BinOp.Ge);
        case TokenKind.Gt:
            adjacent(p, p.pos) && peek(p, 1) == TokenKind.Gt ? BinaryInfo { prec: PREC_SHIFT, op: BinOp.Shr, right: false, width: 2 }
            : adjacent(p, p.pos) && peek(p, 1) == TokenKind.GtEq ? info(0, BinOp.None)   // `>>=` assignment
            : info(PREC_COMPARE, BinOp.Gt);
        case TokenKind.Pipe: info(PREC_BIT_OR, BinOp.BitOr);
        case TokenKind.Caret: info(PREC_BIT_XOR, BinOp.BitXor);
        case TokenKind.Amp: info(PREC_BIT_AND, BinOp.BitAnd);
        case TokenKind.LtLt: info(PREC_SHIFT, BinOp.Shl);
        case TokenKind.Plus: info(PREC_ADD, BinOp.Add);
        case TokenKind.Minus: info(PREC_ADD, BinOp.Sub);
        case TokenKind.PlusPercent: info(PREC_ADD, BinOp.AddWrap);
        case TokenKind.MinusPercent: info(PREC_ADD, BinOp.SubWrap);
        case TokenKind.PlusPipe: info(PREC_ADD, BinOp.AddSat);
        case TokenKind.MinusPipe: info(PREC_ADD, BinOp.SubSat);
        case TokenKind.Star: info(PREC_MUL, BinOp.Mul);
        case TokenKind.Slash: info(PREC_MUL, BinOp.Div);
        case TokenKind.Percent: info(PREC_MUL, BinOp.Mod);
        case TokenKind.StarPercent: info(PREC_MUL, BinOp.MulWrap);
        case TokenKind.StarPipe: info(PREC_MUL, BinOp.MulSat);
        default: info(0, BinOp.None);
    };
}

/**
 * Parses binary operators by precedence climbing.
 *
 * @param p - The parser state
 * @param minPrec - The loosest precedence that this call may take
 * @returns The index of the expression node
 *
 * @remarks
 * Comparisons do not chain, so `a < b < c` is reported.
 */

function parseBinary(p: *Parser, minPrec: u8): u32 {
    let lhs = parseCast(p);
    while (true) {
        const op = binaryInfo(p);
        if (op.prec == 0 || op.prec < minPrec) return lhs;
        const token = p.pos;
        for (const _ of 0..op.width) void advance(p);
        const rhs = parseBinary(p, op.right ? op.prec : op.prec + 1);
        lhs = add(p, NodeKind.Binary, token, lhs, rhs);
        setOp(p, lhs, op.op as u16);
        if (op.prec == PREC_COMPARE && binaryInfo(p).prec == PREC_COMPARE) {
            const diag = errorToken(p, p.pos, "comparison operators cannot be chained");
            hint(p, diag, "combine the comparisons with `&&`, as in `a < b && b < c`");
        }
    }
}

/**
 * Checks whether a token can start the body that follows a `catch` capture.
 *
 * @param kind - The kind to check
 * @returns `true` when the token can start a block or a value
 *
 * @remarks
 * It lets `x catch (e) body` capture the error while `x catch (fallback) + 1` still reads a parenthesized value.
 */

function startsCaptureBody(kind: TokenKind): bool {
    return kind == TokenKind.Lbrace || kind == TokenKind.Ident || isKeyword(kind) || literalKind(kind) != NodeKind.None ||
           kind == TokenKind.Builtin || kind == TokenKind.TemplateFull || kind == TokenKind.TemplateHead;
}

/**
 * Parses a capture such as `(e)` after `catch` or `errdefer`.
 *
 * @param p - The parser state
 * @returns The index of the captured name, or {@link NO_TOKEN} when there is no capture
 */

function parseCapture(p: *Parser): u32 {
    if (at(p, TokenKind.Lparen) && isName(peek(p, 1)) && peek(p, 2) == TokenKind.Rparen && startsCaptureBody(peek(p, 3))) {
        void advance(p);
        const name = advance(p);
        void advance(p);
        return name;
    }
    return NO_TOKEN;
}

/**
 * Parses binary expressions joined by `catch`.
 *
 * @param p - The parser state
 * @returns The index of the expression node
 */

function parseCatch(p: *Parser): u32 {
    let lhs = parseBinary(p, PREC_COALESCE);
    while (at(p, TokenKind.KwCatch)) {
        const token = advance(p);
        const capture = parseCapture(p);
        const body = at(p, TokenKind.Lbrace) ? parseBlock(p) : parseBinary(p, PREC_COALESCE);
        lhs = add(p, NodeKind.Catch, token, lhs, record<HxCatchData>(p, HxCatchData { capture_token: capture, body }));
    }
    return lhs;
}

/**
 * Parses a whole expression.
 *
 * @param p - The parser state
 * @returns The index of the expression node
 *
 * @remarks
 * A ternary groups to the right and sits above `catch`, which sits above the binary operators.
 */

function parseExpr(p: *Parser): u32 {
    if (!enter(p)) return invalid(p);
    let cond = parseCatch(p);
    if (at(p, TokenKind.Question)) {
        const token = advance(p);
        const thenValue = parseExpr(p);
        void expect(p, TokenKind.Colon);
        const elseValue = parseExpr(p);
        cond = add(p, NodeKind.Ternary, token, cond, record<HxTernaryData>(p, HxTernaryData { then_value: thenValue, else_value: elseValue }));
    }
    leave(p);
    return cond;
}

/**
 * Parses a literal, an enum path, or a negative number inside a pattern.
 *
 * @param p - The parser state
 * @returns The index of the value node, or an invalid node
 */

function parsePatternValue(p: *Parser): u32 {
    const kind = cur(p);
    const literal = literalKind(kind);
    if (literal != NodeKind.None) return add(p, literal, advance(p), 0, 0);
    if (kind == TokenKind.Minus) {
        const token = advance(p);
        return add(p, NodeKind.Negate, token, parsePatternValue(p), 0);
    }
    if (kind == TokenKind.Dot) {
        void advance(p);
        const name = expectFieldName(p);
        return name == NO_TOKEN ? invalid(p) : add(p, NodeKind.EnumLiteral, name, 0, 0);
    }
    if (isName(kind)) {
        let path = add(p, NodeKind.Ident, advance(p), 0, 0);
        while (accept(p, TokenKind.Dot)) {
            const name = expectFieldName(p);
            if (name == NO_TOKEN) break;
            path = add(p, NodeKind.FieldAccess, name, path, 0);
        }
        return path;
    }
    void errorExpected(p, "a pattern");
    return invalid(p);
}

/**
 * Parses a struct pattern such as `{ x: 0, y }`.
 *
 * @param p - The parser state
 * @returns The index of the `PatternStruct` node
 */

function parseStructPattern(p: *Parser): u32 {
    const token = advance(p);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const name = expectName(p, "a field name");
        if (name == NO_TOKEN) break;
        const sub = accept(p, TokenKind.Colon) ? parsePattern(p) : 0;
        scratchPush(p, add(p, NodeKind.PatternField, name, sub, 0));
        if (!accept(p, TokenKind.Comma)) break;
    }
    void expect(p, TokenKind.Rbrace);
    const fields = listFinish(p, top);
    return add(p, NodeKind.PatternStruct, token, fields.start, fields.end);
}

/**
 * Parses one pattern of a case.
 *
 * @param p - The parser state
 * @returns The index of the pattern node
 *
 * @remarks
 * A bare name is a new binding, as in `case n if n > 5`.
 * Enum members are always qualified or dotted, as in `Role.Admin` or `.Admin`, so the two never clash.
 */

function parsePattern(p: *Parser): u32 {
    if (!enter(p)) return invalid(p);
    let result: u32 = 0;
    if (at(p, TokenKind.Lbrace)) {
        result = parseStructPattern(p);
    } else if (at(p, TokenKind.Star)) {
        void advance(p);
        const name = expectName(p, "a binding name");
        result = addFlags(p, NodeKind.PatternBind, FLAG_POINTER, name, 0, 0);
    } else if (isName(cur(p)) && peek(p, 1) != TokenKind.Dot && peek(p, 1) != TokenKind.Lparen &&
               peek(p, 1) != TokenKind.DotDot && peek(p, 1) != TokenKind.DotDotEq) {
        result = add(p, NodeKind.PatternBind, advance(p), 0, 0);
    } else {
        const token = p.pos;
        const value = parsePatternValue(p);
        if (at(p, TokenKind.Lparen)) {
            void advance(p);
            const payload = parsePattern(p);
            void expect(p, TokenKind.Rparen);
            result = add(p, NodeKind.PatternTag, token, value, payload);
        } else if (at(p, TokenKind.DotDot) || at(p, TokenKind.DotDotEq)) {
            const flags = at(p, TokenKind.DotDotEq) ? FLAG_INCLUSIVE : 0;
            const range = advance(p);
            result = addFlags(p, NodeKind.PatternRange, flags, range, value, parsePatternValue(p));
        } else {
            result = add(p, NodeKind.PatternValue, token, value, 0);
        }
    }
    leave(p);
    return result;
}

/**
 * Parses the body of a case.
 *
 * @param p - The parser state
 * @param isExpr - Whether the switch is in its expression form
 * @param colon - The index of the `:` token, which the block node points at
 * @returns The index of the block of statements, or of the value of an expression switch
 *
 * @remarks
 * A statement switch takes statements up to the next case, and an expression switch takes one value and a `;`.
 */

function parseCaseBody(p: *Parser, isExpr: bool, colon: u32): u32 {
    if (isExpr) {
        const value = parseExpr(p);
        expectSemicolon(p, "the case value");
        return value;
    }
    const top = scratchTop(p);
    while (!at(p, TokenKind.KwCase) && !at(p, TokenKind.KwDefault) && !at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const before = p.pos;
        const stmt = parseStatement(p);
        if (stmt != 0) scratchPush(p, stmt);
        recover(p, Sync.Statement, before);
    }
    const stmts = listFinish(p, top);
    return add(p, NodeKind.Block, colon, stmts.start, stmts.end);
}

/**
 * Parses a `case` or the `default` case of a switch.
 *
 * @param p - The parser state
 * @param isExpr - Whether the switch is in its expression form
 * @returns The index of the case node, or 0 after an error
 *
 * @remarks
 * An `=>` in place of the `:` is reported with a hint, since other languages use it.
 */

function parseCase(p: *Parser, isExpr: bool): u32 {
    if (at(p, TokenKind.KwDefault)) {
        const token = advance(p);
        const colon = expect(p, TokenKind.Colon);
        return add(p, NodeKind.DefaultCase, token, parseCaseBody(p, isExpr, colon), 0);
    }
    if (!at(p, TokenKind.KwCase)) {
        const diag = errorExpected(p, "`case` or `default`");
        if (at(p, TokenKind.KwElse)) hint(p, diag, "the catch-all case is written `default:`");
        return 0;
    }
    const token = advance(p);
    const top = scratchTop(p);
    while (true) {
        scratchPush(p, parsePattern(p));
        if (!accept(p, TokenKind.Comma)) break;
    }
    const patterns = listFinish(p, top);
    let data = HxCaseData { patterns_start: patterns.start, patterns_end: patterns.end, guard: 0, body: 0 };
    if (accept(p, TokenKind.KwIf)) data.guard = parseExpr(p);
    const colon = p.pos;
    if (at(p, TokenKind.Arrow)) {
        const diag = errorToken(p, p.pos, "switch cases use `:`, not `=>`");
        hint(p, diag, "write `case X: value;`");
    }
    void expect(p, TokenKind.Colon);
    data.body = parseCaseBody(p, isExpr, colon);
    return add(p, NodeKind.Case, token, record<HxCaseData>(p, data), 0);
}

/**
 * Parses a switch in its statement or expression form.
 *
 * @param p - The parser state
 * @param isExpr - Whether the switch is in its expression form
 * @returns The index of the `Switch` node
 */

function parseSwitch(p: *Parser, isExpr: bool): u32 {
    const token = advance(p);
    void expect(p, TokenKind.Lparen);
    const subject = parseExpr(p);
    void expect(p, TokenKind.Rparen);
    void expect(p, TokenKind.Lbrace);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const before = p.pos;
        const c = parseCase(p, isExpr);
        if (c != 0) scratchPush(p, c);
        recover(p, Sync.Case, before);
    }
    void expect(p, TokenKind.Rbrace);
    const cases = listFinish(p, top);
    return addFlags(p, NodeKind.Switch, isExpr ? FLAG_EXPR : 0, token, subject, rangeRecord(p, cases));
}

/**
 * Parses a block of statements in braces.
 *
 * @param p - The parser state
 * @returns The index of the `Block` node, or an invalid node without an opening brace
 */

function parseBlock(p: *Parser): u32 {
    const open = p.pos;
    if (expect(p, TokenKind.Lbrace) == NO_TOKEN) return invalid(p);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const before = p.pos;
        const stmt = parseStatement(p);
        if (stmt != 0) scratchPush(p, stmt);
        recover(p, Sync.Statement, before);
    }
    if (!accept(p, TokenKind.Rbrace)) {
        const diag = errorToken(p, open, "this `{` is never closed");
        hint(p, diag, "add a matching `}`");
    }
    const stmts = listFinish(p, top);
    return add(p, NodeKind.Block, open, stmts.start, stmts.end);
}

/**
 * Returns the assignment operator at the current token.
 *
 * @param p - The parser state
 * @param width - The variable that receives the number of tokens that the operator takes
 * @returns The operator that the assignment applies, or `null` when the token is not an assignment
 *
 * @remarks
 * A `>>=` arrives as a `>` and a `>=`, and it is joined here.
 */

function assignOp(p: *Parser, width: *u32): ?BinOp {
    *width = 1;
    return switch (cur(p)) {
        case TokenKind.Eq: BinOp.None;
        case TokenKind.PlusEq: BinOp.Add;
        case TokenKind.MinusEq: BinOp.Sub;
        case TokenKind.StarEq: BinOp.Mul;
        case TokenKind.SlashEq: BinOp.Div;
        case TokenKind.PercentEq: BinOp.Mod;
        case TokenKind.PlusPercentEq: BinOp.AddWrap;
        case TokenKind.MinusPercentEq: BinOp.SubWrap;
        case TokenKind.StarPercentEq: BinOp.MulWrap;
        case TokenKind.PlusPipeEq: BinOp.AddSat;
        case TokenKind.MinusPipeEq: BinOp.SubSat;
        case TokenKind.StarPipeEq: BinOp.MulSat;
        case TokenKind.AmpEq: BinOp.BitAnd;
        case TokenKind.PipeEq: BinOp.BitOr;
        case TokenKind.CaretEq: BinOp.BitXor;
        case TokenKind.LtLtEq: BinOp.Shl;
        case TokenKind.QuestionQuestionEq: BinOp.Coalesce;
        case TokenKind.Gt: shrAssign(p, width);
        default: null;
    };
}

/**
 * Recognizes a `>>=` made of a `>` touching a `>=`.
 *
 * @param p - The parser state
 * @param width - The variable that receives 2 when the operator matches
 * @returns {@link BinOp.Shr}, or `null` when the tokens do not form a `>>=`
 */

function shrAssign(p: *Parser, width: *u32): ?BinOp {
    if (!adjacent(p, p.pos) || peek(p, 1) != TokenKind.GtEq) return null;
    *width = 2;
    return BinOp.Shr;
}

/**
 * Parses an expression statement, an assignment, or an increment or decrement.
 *
 * @param p - The parser state
 * @param requireSemicolon - Whether the statement must end with a `;`
 * @returns The index of the statement node
 *
 * @remarks
 * The `;` is optional so that the step of a C-style `for` can reuse it.
 */

function parseSimpleStatement(p: *Parser, requireSemicolon: bool): u32 {
    const first = p.pos;
    const target = parseExpr(p);
    let result: u32 = 0;
    let width: u32 = 1;
    if (const op = assignOp(p, &width)) {
        const token = p.pos;
        for (const _ of 0..width) void advance(p);
        result = add(p, NodeKind.Assign, token, target, parseExpr(p));
        setOp(p, result, op as u16);
    } else if (at(p, TokenKind.PlusPlus) || at(p, TokenKind.MinusMinus)) {
        const kind = at(p, TokenKind.PlusPlus) ? NodeKind.Increment : NodeKind.Decrement;
        result = add(p, kind, advance(p), target, 0);
    } else {
        result = add(p, NodeKind.ExprStmt, first, target, 0);
    }
    if (requireSemicolon) expectSemicolon(p, "the statement");
    return result;
}

/**
 * Parses a capture such as `const name =` at the start of an `if` or `while` condition.
 *
 * @param p - The parser state
 * @returns The index of the captured name, or {@link NO_TOKEN} when there is no capture
 */

function parseConditionCapture(p: *Parser): u32 {
    if (at(p, TokenKind.KwConst) && isName(peek(p, 1)) && peek(p, 2) == TokenKind.Eq) {
        void advance(p);
        const name = advance(p);
        void advance(p);
        return name;
    }
    return NO_TOKEN;
}

/**
 * Parses an `if` statement with its optional `else`.
 *
 * @param p - The parser state
 * @returns The index of the `If` node
 */

function parseIf(p: *Parser): u32 {
    const token = advance(p);
    void expect(p, TokenKind.Lparen);
    let data = HxIfData { condition: 0, capture_token: parseConditionCapture(p), then_branch: 0, else_branch: 0 };
    data.condition = parseExpr(p);
    void expect(p, TokenKind.Rparen);
    data.then_branch = parseStatement(p);
    if (accept(p, TokenKind.KwElse)) data.else_branch = parseStatement(p);
    return add(p, NodeKind.If, token, record<HxIfData>(p, data), 0);
}

/**
 * Parses a `while` loop.
 *
 * @param p - The parser state
 * @param label - The index of the label token, or {@link NO_TOKEN}
 * @returns The index of the `While` node
 */

function parseWhile(p: *Parser, label: u32): u32 {
    const token = advance(p);
    void expect(p, TokenKind.Lparen);
    let data = HxWhileData { condition: 0, capture_token: parseConditionCapture(p), body: 0, label_token: label };
    data.condition = parseExpr(p);
    void expect(p, TokenKind.Rparen);
    data.body = parseStatement(p);
    return add(p, NodeKind.While, token, record<HxWhileData>(p, data), 0);
}

/**
 * Parses a `for-of` loop or a C-style `for` loop.
 *
 * @param p - The parser state
 * @param label - The index of the label token, or {@link NO_TOKEN}
 * @returns The index of the `ForOf` or `For` node
 *
 * @remarks
 * A `for-of` binding is always `const`, so `let` there is reported.
 * A range after `of` becomes a `Range` node.
 */

function parseFor(p: *Parser, label: u32): u32 {
    const token = advance(p);
    void expect(p, TokenKind.Lparen);
    const binding = (at(p, TokenKind.KwConst) || at(p, TokenKind.KwLet)) && isName(peek(p, 1));
    if (binding && (peek(p, 2) == TokenKind.KwOf || peek(p, 2) == TokenKind.Comma)) {
        if (at(p, TokenKind.KwLet)) {
            const diag = report(p, p.pos, "for-of items are always `const`");
            diagHint(p.diags, diag, "write `for (const x of ...)`; to change items, index them: `items[i]`");
        }
        void advance(p);
        let data = HxForOfData { item_token: advance(p), index_token: NO_TOKEN, iterable: 0, body: 0, label_token: label };
        if (accept(p, TokenKind.Comma)) data.index_token = expectName(p, "an index name");
        void expect(p, TokenKind.KwOf);
        let iterable = parseExpr(p);
        if (at(p, TokenKind.DotDot) || at(p, TokenKind.DotDotEq)) {
            const flags = at(p, TokenKind.DotDotEq) ? FLAG_INCLUSIVE : 0;
            const range = advance(p);
            iterable = addFlags(p, NodeKind.Range, flags, range, iterable, parseExpr(p));
        }
        data.iterable = iterable;
        void expect(p, TokenKind.Rparen);
        data.body = parseStatement(p);
        return add(p, NodeKind.ForOf, token, record<HxForOfData>(p, data), 0);
    }

    let data = HxForData { init: 0, condition: 0, step: 0, body: 0, label_token: label };
    if (!accept(p, TokenKind.Semicolon)) {
        if (at(p, TokenKind.KwConst) || at(p, TokenKind.KwLet)) data.init = parseVarDecl(p, 0);
        else data.init = parseSimpleStatement(p, true);
    }
    if (!at(p, TokenKind.Semicolon)) data.condition = parseExpr(p);
    void expect(p, TokenKind.Semicolon);
    if (!at(p, TokenKind.Rparen)) data.step = parseSimpleStatement(p, false);
    void expect(p, TokenKind.Rparen);
    data.body = parseStatement(p);
    return add(p, NodeKind.For, token, record<HxForData>(p, data), 0);
}

/**
 * Parses one statement.
 *
 * @param p - The parser state
 * @returns The index of the statement node, or 0 for an empty statement
 *
 * @remarks
 * A function declared inside a function is reported, then parsed anyway so that its body is still checked.
 * A name followed by `:` and a loop keyword is a loop label.
 */

function parseStatement(p: *Parser): u32 {
    if (!enter(p)) return invalid(p);
    let result: u32 = 0;
    const token = p.pos;
    switch (cur(p)) {
        case TokenKind.Semicolon: void advance(p);
        case TokenKind.Lbrace: result = parseBlock(p);
        case TokenKind.KwConst, TokenKind.KwLet: result = parseVarDecl(p, 0);
        case TokenKind.KwReturn: {
            void advance(p);
            const value = at(p, TokenKind.Semicolon) || at(p, TokenKind.Rbrace) ? 0 : parseExpr(p);
            expectSemicolon(p, "`return`");
            result = add(p, NodeKind.Return, token, value, 0);
        }
        case TokenKind.KwThrow: {
            void advance(p);
            const value = parseExpr(p);
            expectSemicolon(p, "`throw`");
            result = add(p, NodeKind.Throw, token, value, 0);
        }
        case TokenKind.KwBreak, TokenKind.KwContinue: {
            const kind = at(p, TokenKind.KwBreak) ? NodeKind.Break : NodeKind.Continue;
            void advance(p);
            const label = isName(cur(p)) ? advance(p) : NO_TOKEN;
            expectSemicolon(p, kind == NodeKind.Break ? "`break`" : "`continue`");
            result = add(p, kind, token, label, 0);
        }
        case TokenKind.KwIf: result = parseIf(p);
        case TokenKind.KwWhile: result = parseWhile(p, NO_TOKEN);
        case TokenKind.KwFor: result = parseFor(p, NO_TOKEN);
        case TokenKind.KwSwitch: result = parseSwitch(p, false);
        case TokenKind.KwDefer: {
            void advance(p);
            result = add(p, NodeKind.Defer, token, parseStatement(p), 0);
        }
        case TokenKind.KwErrdefer: {
            void advance(p);
            const capture = parseCapture(p);
            result = add(p, NodeKind.Errdefer, token, parseStatement(p), capture);
        }
        case TokenKind.KwUnsafe: {
            void advance(p);
            result = add(p, NodeKind.UnsafeBlock, token, parseBlock(p), 0);
        }
        case TokenKind.KwComptime: {
            if (peek(p, 1) == TokenKind.Lbrace) {
                void advance(p);
                result = add(p, NodeKind.ComptimeBlock, token, parseBlock(p), 0);
            } else {
                result = parseSimpleStatement(p, true);
            }
        }
        case TokenKind.KwFunction: {
            const diag = report(p, token, "functions can't be declared inside a function");
            diagHint(p.diags, diag, "move it to the top level, or use an arrow function: `const double = (x: i32): i32 => x * 2;`");
            result = parseFunction(p, 0, NO_TOKEN);
        }
        default: {
            if (isName(cur(p)) && peek(p, 1) == TokenKind.Colon &&
                (peek(p, 2) == TokenKind.KwFor || peek(p, 2) == TokenKind.KwWhile)) {
                const label = advance(p);
                void advance(p);
                result = at(p, TokenKind.KwFor) ? parseFor(p, label) : parseWhile(p, label);
            } else {
                result = parseSimpleStatement(p, true);
            }
        }
    }
    leave(p);
    return result;
}

/**
 * Parses a `const` or `let` declaration.
 *
 * @param p - The parser state
 * @param flags - The `FLAG_` bits of the declaration
 * @returns The index of the `Const` or `Let` node
 */

function parseVarDecl(p: *Parser, flags: u8): u32 {
    const kind = at(p, TokenKind.KwConst) ? NodeKind.Const : NodeKind.Let;
    void advance(p);
    const name = expectName(p, "a variable name");
    let type: u32 = 0;
    let init: u32 = 0;
    if (name != NO_TOKEN) {
        if (accept(p, TokenKind.Colon)) type = parseType(p);
        if (accept(p, TokenKind.Eq)) init = parseExpr(p);
        expectSemicolon(p, "the declaration");
    }
    return addFlags(p, kind, flags, name, type, init);
}

/**
 * Parses a function declaration from its `function` keyword.
 *
 * @param p - The parser state
 * @param flags - The `FLAG_` bits of the declaration
 * @param abi - The ABI string token of an `extern` function, or {@link NO_TOKEN}
 * @returns The index of the `Function` node
 */

function parseFunction(p: *Parser, flags: u8, abi: u32): u32 {
    void advance(p);
    return parseFunctionRest(p, flags, abi);
}

/**
 * Parses a function from its name on, as in `name<T>(params): ret { body }`.
 *
 * @param p - The parser state
 * @param fnFlags - The `FLAG_` bits of the declaration
 * @param abi - The ABI string token of an `extern` function, or {@link NO_TOKEN}
 * @returns The index of the `Function` node, or an invalid node
 *
 * @remarks
 * Methods are written this way, without `function`.
 * A function without a body ends with a `;`.
 */

function parseFunctionRest(p: *Parser, fnFlags: u8, abi: u32): u32 {
    let flags = fnFlags;
    const firstNode = p.ast.nodes_len;
    const name = expectName(p, "a function name");
    let fn = emptyFn(abi, firstNode);
    const generics = parseGenericParams(p);
    fn.generics_start = generics.start;
    fn.generics_end = generics.end;
    if (!at(p, TokenKind.Lparen)) {
        void errorExpected(p, "`(` to start the parameter list");
        return invalid(p);
    }
    parseParams(p, &fn, &flags);
    if (accept(p, TokenKind.Colon)) fn.return_type = parseType(p);
    if (at(p, TokenKind.Lbrace)) {
        fn.body = parseBlock(p);
    } else if (!accept(p, TokenKind.Semicolon)) {
        const diag = errorExpected(p, "`{` to start the function body");
        if (at(p, TokenKind.Arrow)) hint(p, diag, "`=>` is for arrow functions; a `function` body is a `{ ... }` block");
    }
    return addFlags(p, NodeKind.Function, flags, name, record<HxFnData>(p, fn), 0);
}

/**
 * Reports a `function` keyword in front of a method, then moves past it.
 *
 * @param p - The parser state
 *
 * @remarks
 * Methods are written like the methods of a TypeScript class.
 */

function rejectMethodKeyword(p: *Parser): void {
    if (!at(p, TokenKind.KwFunction)) return;
    const diag = report(p, p.pos, "methods are written without `function`");
    hint(p, diag, "write `name(...) { ... }`, as in a TypeScript class");
    void advance(p);
}

/**
 * Checks whether the current member is a method.
 *
 * @param p - The parser state
 * @returns `true` when a name is followed by `(` or `<`
 *
 * @remarks
 * Fields, enum members, and variants are followed by `:`, `=`, or `,` instead.
 */

function atMethod(p: *Parser): bool {
    return isName(cur(p)) && (peek(p, 1) == TokenKind.Lparen || peek(p, 1) == TokenKind.Lt);
}

/**
 * Parses a method signature of an interface.
 *
 * @param p - The parser state
 * @returns The index of the `Function` node, or 0 after an error
 */

function parseInterfaceMember(p: *Parser): u32 {
    rejectMethodKeyword(p);
    const name = expectName(p, "a method name");
    if (name == NO_TOKEN) return 0;
    let fn = emptyFn(NO_TOKEN, 0);
    let flags: u8 = 0;
    if (!at(p, TokenKind.Lparen)) {
        void errorExpected(p, "`(` to start the parameter list");
        return 0;
    }
    parseParams(p, &fn, &flags);
    if (accept(p, TokenKind.Colon)) fn.return_type = parseType(p);
    expectSemicolon(p, "the method signature");
    return addFlags(p, NodeKind.Function, flags, name, record<HxFnData>(p, fn), 0);
}

/**
 * Parses one member of a struct, an enum, a union, or an interface.
 *
 * @param p - The parser state
 * @param kind - The kind of body being parsed
 * @returns The index of the member node, or 0 after an error
 */

function parseMember(p: *Parser, kind: Members): u32 {
    if (kind == Members.Interface) return parseInterfaceMember(p);
    rejectMethodKeyword(p);
    if (atMethod(p)) return parseFunctionRest(p, 0, NO_TOKEN);
    if (at(p, TokenKind.KwConst)) return parseVarDecl(p, 0);
    let member: u32 = 0;
    if (kind == Members.Struct) {
        member = parseFieldDecl(p);
    } else {
        const name = expectName(p, kind == Members.Enum ? "an enum member" : "a union variant");
        if (name == NO_TOKEN) return 0;
        if (kind == Members.Enum) member = add(p, NodeKind.EnumMember, name, accept(p, TokenKind.Eq) ? parseExpr(p) : 0, 0);
        else member = add(p, NodeKind.UnionVariant, name, accept(p, TokenKind.Colon) ? parseType(p) : 0, 0);
    }
    if (member != 0 && !p.panicking) expectMemberSeparator(p);
    return member;
}

/**
 * Parses a `struct`, `enum`, `union`, or `interface` declaration.
 *
 * @param p - The parser state
 * @param kind - The node kind of the declaration
 * @param members - The kind of body to parse
 * @param flags - The `FLAG_` bits of the declaration
 * @returns The index of the declaration node, or an invalid node
 *
 * @remarks
 * Only an enum takes a backing type after a `:`.
 */

function parseContainer(p: *Parser, kind: NodeKind, members: Members, flags: u8): u32 {
    const firstNode = p.ast.nodes_len;
    void advance(p);
    const name = expectName(p, "a type name");
    let data = HxContainerData { generics_start: 0, generics_end: 0, members_start: 0, members_end: 0, backing_type: 0, first_node: firstNode };
    const generics = parseGenericParams(p);
    data.generics_start = generics.start;
    data.generics_end = generics.end;
    if (members == Members.Enum && accept(p, TokenKind.Colon)) data.backing_type = parseType(p);
    const open = p.pos;
    if (expect(p, TokenKind.Lbrace) == NO_TOKEN) return invalid(p);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const before = p.pos;
        const member = parseMember(p, members);
        if (member != 0) scratchPush(p, member);
        recover(p, Sync.Member, before);
    }
    if (!accept(p, TokenKind.Rbrace)) {
        const diag = errorToken(p, open, "this `{` is never closed");
        hint(p, diag, "add a matching `}`");
    }
    const list = listFinish(p, top);
    data.members_start = list.start;
    data.members_end = list.end;
    return addFlags(p, kind, flags, name, record<HxContainerData>(p, data), 0);
}

/**
 * Parses an `error` declaration.
 *
 * @param p - The parser state
 * @param flags - The `FLAG_` bits of the declaration
 * @returns The index of the `ErrorSet` node
 */

function parseErrorSet(p: *Parser, flags: u8): u32 {
    void advance(p);
    const name = expectName(p, "an error set name");
    void expect(p, TokenKind.Lbrace);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const member = expectName(p, "an error name");
        if (member == NO_TOKEN) break;
        scratchPush(p, add(p, NodeKind.ErrorMember, member, 0, 0));
        if (!accept(p, TokenKind.Comma)) break;
    }
    void expect(p, TokenKind.Rbrace);
    const members = listFinish(p, top);
    return addFlags(p, NodeKind.ErrorSet, flags, name, members.start, members.end);
}

/**
 * Parses a `type` declaration.
 *
 * @param p - The parser state
 * @param flags - The `FLAG_` bits of the declaration
 * @returns The index of the `TypeAlias` node
 */

function parseTypeAlias(p: *Parser, flags: u8): u32 {
    void advance(p);
    const name = expectName(p, "a type name");
    const generics = parseGenericParams(p);
    const data = HxContainerData {
        generics_start: generics.start, generics_end: generics.end, members_start: 0, members_end: 0, backing_type: 0, first_node: 0,
    };
    void expect(p, TokenKind.Eq);
    const type = parseType(p);
    expectSemicolon(p, "the type alias");
    return addFlags(p, NodeKind.TypeAlias, flags, name, record<HxContainerData>(p, data), type);
}

/**
 * Parses an import or a re-export.
 *
 * @param p - The parser state
 * @param reexport - Whether the declaration starts with `export` rather than `import`
 * @returns The index of the `Import` node
 *
 * @remarks
 * It reads `import { a, b as c } from "x";`, `import * as ns from "x";`, and `import "x";`,
 * and the re-export forms `export { a } from "x";` and `export * from "x";`.
 * A default import is reported, since Helix has none.
 */

function parseImport(p: *Parser, reexport: bool): u32 {
    const token = advance(p);
    let data = HxImportData { path_token: NO_TOKEN, alias_token: NO_TOKEN, specs_start: 0, specs_end: 0 };
    let flags = reexport ? FLAG_EXPORT : 0;
    const top = scratchTop(p);
    if (!reexport && at(p, TokenKind.String)) {   // `import "./x";`: loaded for what it exports to C, names nothing
        data.path_token = advance(p);
        expectSemicolon(p, "the import");
        return addFlags(p, NodeKind.Import, flags, token, record<HxImportData>(p, data), 0);
    }
    if (accept(p, TokenKind.Star)) {
        flags |= FLAG_NAMESPACE;
        if (!reexport && expect(p, TokenKind.KwAs) != NO_TOKEN) data.alias_token = expectName(p, "a namespace name");
    } else if (accept(p, TokenKind.Lbrace)) {
        while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
            const name = expectName(p, "an imported name");
            if (name == NO_TOKEN) break;
            const alias = accept(p, TokenKind.KwAs) ? expectName(p, "an alias") : NO_TOKEN;
            scratchPush(p, add(p, NodeKind.ImportSpec, name, alias, 0));
            if (!accept(p, TokenKind.Comma)) break;
        }
        void expect(p, TokenKind.Rbrace);
    } else if (isName(cur(p))) {
        const word = text(p, p.pos);
        const diag = errorToken(p, p.pos, "Helix has no default imports");
        hintf(p, diag, `import names in braces, \`import { ${word} } from ...\`, or a namespace, \`import * as ${word} from ...\``);
    } else {
        void errorExpected(p, "`{` or `*`");
    }
    const specs = listFinish(p, top);
    data.specs_start = specs.start;
    data.specs_end = specs.end;
    if (expect(p, TokenKind.KwFrom) != NO_TOKEN) data.path_token = expect(p, TokenKind.String);
    expectSemicolon(p, "the import");
    return addFlags(p, NodeKind.Import, flags, token, record<HxImportData>(p, data), 0);
}

/**
 * Checks whether a token is an identifier with a given text.
 *
 * @param p - The parser state
 * @param token - The index of the token
 * @param word - The text to compare with
 * @returns `true` when the token is that identifier
 */

function tokenIs(p: *Parser, token: u32, word: string): bool {
    if (kindAt(p, token) != TokenKind.Ident) return false;
    const t = text(p, token);
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
 */

function atTestItem(p: *Parser): bool {
    if (!tokenIs(p, p.pos, "describe") && !tokenIs(p, p.pos, "test") && !tokenIs(p, p.pos, "it")) return false;
    return peek(p, 1) == TokenKind.Lparen ||
           (peek(p, 1) == TokenKind.Dot && peek(p, 2) == TokenKind.Ident && peek(p, 3) == TokenKind.Lparen);
}

/**
 * Parses a `describe` block or a test with its modifier and options.
 *
 * @param p - The parser state
 * @returns The index of the `Describe` or `Test` node, or 0 after an error
 *
 * @remarks
 * A test takes `.skip`, `.only`, `.todo`, `.failing`, or `.panics`, and a `describe` takes `.skip` or `.only`.
 * A `test.panics` takes the expected message after the name, and a test may end with `{ timeout: N }`.
 * A `test.todo` has no body.
 */

function parseTestItem(p: *Parser): u32 {
    const keyword = advance(p);
    const isDescribe = tokenIs(p, keyword, "describe");
    let mode = TEST_PLAIN;
    if (accept(p, TokenKind.Dot)) {
        const names: string[6] = ["", "skip", "only", "todo", "failing", "panics"];
        const modifier = advance(p);
        for (const i of 1..6) {
            if (tokenIs(p, modifier, names[i])) mode = @truncate(u16, i);
        }
        if (mode == TEST_PLAIN || (isDescribe && mode != TEST_SKIP && mode != TEST_ONLY)) {
            const diag = report(p, modifier, isDescribe ? "unknown `describe` modifier" : "unknown `test` modifier");
            hint(p, diag, isDescribe ? "`describe` takes `.skip` or `.only`" : "use `.skip`, `.only`, `.todo`, `.failing` or `.panics`");
            mode = TEST_PLAIN;
        }
    }
    if (expect(p, TokenKind.Lparen) == NO_TOKEN) return 0;
    let name = NO_TOKEN;
    if (at(p, TokenKind.String)) {
        name = advance(p);
    } else {
        const diag = errorExpected(p, isDescribe ? "the block's name as a string" : "the test's name as a string");
        hintf(p, diag, `write \`${isDescribe ? "describe" : "test"}("should ...") { ... }\``);
        return 0;
    }
    let message = NO_TOKEN;
    if (mode == TEST_PANICS) {
        if (expect(p, TokenKind.Comma) == NO_TOKEN) return 0;
        if (!at(p, TokenKind.String)) {
            const diag = errorExpected(p, "the expected panic message");
            hint(p, diag, "write `test.panics(\"should stop\", \"index out of bounds\") { ... }`");
            return 0;
        }
        message = advance(p);
    }
    let timeout = NO_TOKEN;
    if (!isDescribe && accept(p, TokenKind.Comma)) {   // `{ timeout: 100 }`, the only option so far
        if (!accept(p, TokenKind.Lbrace) || !tokenIs(p, p.pos, "timeout") || peek(p, 1) != TokenKind.Colon ||
            peek(p, 2) != TokenKind.Int) {
            const diag = errorExpected(p, "test options");
            hint(p, diag, "write `{ timeout: 10_000 }` (milliseconds)");
            let depth: u32 = 0;
            while (!at(p, TokenKind.Eof) && (depth > 0 || !at(p, TokenKind.Rparen))) {   // to the `)`
                if (at(p, TokenKind.Lbrace)) depth += 1;
                else if (at(p, TokenKind.Rbrace) && depth > 0) depth -= 1;
                void advance(p);
            }
            p.panicking = false;
        } else {
            timeout = p.pos + 2;
            p.pos += 3;
            void accept(p, TokenKind.Comma);
            if (expect(p, TokenKind.Rbrace) == NO_TOKEN) return 0;
        }
    }
    if (expect(p, TokenKind.Rparen) == NO_TOKEN) return 0;

    if (isDescribe) {
        const body = parseDescribeBody(p);
        unsafe {
            p.ast.nodes![body].token = name;
            p.ast.nodes![body].op = mode;
        }
        return body;
    }
    let body: u32 = 0;
    if (mode == TEST_TODO) {
        if (at(p, TokenKind.Lbrace)) {
            const diag = report(p, p.pos, "a `test.todo` has no body");
            hint(p, diag, "write `test.todo(\"...\");`, or drop `.todo` once the test is written");
            void parseBlock(p);
        } else {
            expectSemicolon(p, "`test.todo(...)`");
        }
    } else {
        body = parseBlock(p);
    }
    const node = add(p, NodeKind.Test, name, body, record<HxTestData>(p, HxTestData { message_token: message, timeout_token: timeout }));
    setOp(p, node, mode);
    return node;
}

/**
 * Checks whether the current token starts a hook.
 *
 * @param p - The parser state
 * @returns `true` for a hook name followed by `{` or `(`
 */

function atHook(p: *Parser): bool {
    if (peek(p, 1) != TokenKind.Lbrace && peek(p, 1) != TokenKind.Lparen) return false;
    for (const name of HOOK_NAMES) {
        if (tokenIs(p, p.pos, name)) return true;
    }
    return false;
}

/**
 * Parses a hook such as `beforeEach { ... }`.
 *
 * @param p - The parser state
 * @returns The index of the `Hook` node, or 0 when the current token is not a hook
 *
 * @remarks
 * A hook takes a block, so a hook written with arguments is reported.
 */

function parseHook(p: *Parser): u32 {
    for (const name, i of HOOK_NAMES) {
        if (!tokenIs(p, p.pos, name)) continue;
        const keyword = advance(p);
        if (at(p, TokenKind.Lparen)) {
            const diag = errorToken(p, p.pos, "a hook takes a block, not arguments");
            hintf(p, diag, `write \`${name} { ... }\``);
            return 0;
        }
        const node = add(p, NodeKind.Hook, keyword, parseBlock(p), 0);
        setOp(p, node, @truncate(u16, i));
        return node;
    }
    return 0;
}

/**
 * Parses the body of a `describe` block.
 *
 * @param p - The parser state
 * @returns The index of the `Describe` node
 *
 * @remarks
 * The body holds fixtures declared with `let` or `const`, hooks, tests, and nested `describe` blocks.
 */

function parseDescribeBody(p: *Parser): u32 {
    const open = p.pos;
    if (expect(p, TokenKind.Lbrace) == NO_TOKEN) return invalid(p);
    if (!enter(p)) return invalid(p);
    const top = scratchTop(p);
    while (!at(p, TokenKind.Rbrace) && !at(p, TokenKind.Eof)) {
        const before = p.pos;
        let item: u32 = 0;
        if (at(p, TokenKind.KwLet) || at(p, TokenKind.KwConst)) {
            item = parseVarDecl(p, 0);
        } else if (atTestItem(p)) {
            item = parseTestItem(p);
        } else {
            item = parseHook(p);
            if (item == 0 && !p.panicking) {
                const diag = errorExpected(p, "a test, a hook or a `let`/`const`");
                hint(p, diag, "a `describe` holds `test(...) { }`, `describe(...) { }`, `beforeEach { }` and the like, and the variables its tests share");
            }
        }
        if (item != 0) scratchPush(p, item);
        recover(p, Sync.Statement, before);
    }
    leave(p);
    if (!accept(p, TokenKind.Rbrace)) {
        const diag = errorToken(p, open, "this `{` is never closed");
        hint(p, diag, "add a matching `}`");
    }
    const items = listFinish(p, top);
    return add(p, NodeKind.Describe, open, items.start, items.end);
}

/**
 * Parses one top-level declaration.
 *
 * @param p - The parser state
 * @returns The index of the declaration node, or 0 after an error
 *
 * @remarks
 * A statement at the top level draws a hint that statements belong inside a function.
 * An `extern "C"` variable declares a C global.
 */

function parseDeclaration(p: *Parser): u32 {
    let flags: u8 = 0;
    let abi = NO_TOKEN;
    if (at(p, TokenKind.KwExport)) {
        if (peek(p, 1) == TokenKind.Lbrace || peek(p, 1) == TokenKind.Star) return parseImport(p, true);
        void advance(p);
        flags |= FLAG_EXPORT;
    }
    if (at(p, TokenKind.KwExtern)) {
        void advance(p);
        flags |= FLAG_EXTERN;
        if (at(p, TokenKind.String)) {
            abi = advance(p);
        } else {
            const diag = errorExpected(p, "an ABI string");
            hint(p, diag, "write `extern \"C\" function ...`");
            return 0;
        }
        if (!at(p, TokenKind.KwFunction) && !at(p, TokenKind.KwStruct) && !at(p, TokenKind.KwLet) && !at(p, TokenKind.KwConst)) {
            void errorExpected(p, "`function`, `struct`, `let` or `const` after `extern`");
            return 0;
        }
        if (at(p, TokenKind.KwLet) || at(p, TokenKind.KwConst)) {   // a C global: `extern "C" let errno_value: i32;`
            const abiText = text(p, abi);
            if (abiText.len != 3 || abiText[1] != 'C') void report(p, abi, "only `extern \"C\"` is supported");
            return parseVarDecl(p, flags);
        }
    }
    switch (cur(p)) {
        case TokenKind.KwImport: {
            if ((flags & FLAG_EXPORT) != 0) {
                const diag = errorToken(p, p.pos, "`export import` is not valid");
                hint(p, diag, "re-export with `export { name } from \"...\";`");
                return 0;
            }
            return parseImport(p, false);
        }
        case TokenKind.KwConst, TokenKind.KwLet: return parseVarDecl(p, flags);
        case TokenKind.KwFunction: return parseFunction(p, flags, abi);
        case TokenKind.KwStruct: return parseContainer(p, NodeKind.Struct, Members.Struct, flags);   // `extern "C"` is the EXTERN flag
        case TokenKind.KwEnum: return parseContainer(p, NodeKind.Enum, Members.Enum, flags);
        case TokenKind.KwUnion: return parseContainer(p, NodeKind.Union, Members.Union, flags);
        case TokenKind.KwInterface: return parseContainer(p, NodeKind.Interface, Members.Interface, flags);
        case TokenKind.KwError: {
            if (isName(peek(p, 1))) return parseErrorSet(p, flags);
        }
        case TokenKind.KwType: {
            if (isName(peek(p, 1))) return parseTypeAlias(p, flags);
        }
        case TokenKind.KwComptime: {
            if (peek(p, 1) == TokenKind.Lbrace) {
                const token = advance(p);
                return add(p, NodeKind.ComptimeBlock, token, parseBlock(p), 0);
            }
        }
        case TokenKind.Ident: {
            if (flags == 0 && atTestItem(p)) return parseTestItem(p);
        }
        default: {}
    }
    const diag = errorExpected(p, "a declaration");
    if (startsStatement(cur(p)) || canStartExpression(cur(p))) {
        hint(p, diag, "statements belong inside a function; a file holds only declarations");
    }
    return 0;
}

/**
 * Parses one file of a program into a tree.
 *
 * @param ast - The tree that receives the nodes, which may already hold other files
 * @param first_token - The index of the first token of the file
 * @param diags - The list that receives the syntax errors
 * @param ok - The variable that is set to `false` after an error and left alone otherwise
 * @returns The index of the `File` node of the file
 *
 * @remarks
 * The parser reads up to the end-of-file token of the file, so each file of a program parses on its own.
 * It never stops at an error.
 * It reports the first error of each statement, skips to a point where it can resume,
 * and still returns a whole tree, with invalid nodes where a construct failed.
 *
 * @example
 * ```ts
 * let ok = true;
 * const file = hx_parse_module(&ast, firstToken, &diags, &ok);
 * node(&ast, file).kind; // NodeKind.File
 * ```
 *
 * @see hx_parse
 * @since 1.0.0
 */

export extern "C" function hx_parse_module(ast: *HxAst, first_token: u32, diags: *HxDiagList, ok: *bool): u32 {
    let p = Parser {
        src: ast.src, tokens: ast.tokens, ast, diags, pos: first_token, depth: 0, panicking: false,
        scratch: null, scratch_len: 0, scratch_cap: 0,
    };
    const errorsBefore = diags.error_count;
    while (!at(&p, TokenKind.Eof)) {
        const before = p.pos;
        const decl = parseDeclaration(&p);
        if (decl != 0) scratchPush(&p, decl);
        recover(&p, Sync.Declaration, before);
    }
    const decls = listFinish(&p, 0);
    const file = add(&p, NodeKind.File, first_token, decls.start, decls.end);
    unsafe {
        free(@ptrCast(?u8[*], p.scratch));
    }
    if (diags.error_count != errorsBefore) *ok = false;
    return file;
}

/**
 * Parses a single-file program into a new tree.
 *
 * @param src - The source that the tokens point into
 * @param tokens - The tokens of the file
 * @param ast - The tree to set up and fill, whose previous contents are ignored
 * @param diags - The list that receives the syntax errors
 * @returns `true` when the file parsed without an error
 *
 * @remarks
 * The root of the tree is the `File` node of the file.
 * Release the tree with {@link hx_ast_free}, whether or not parsing succeeded.
 *
 * @example
 * ```ts
 * let ast: HxAst = undefined;
 * hx_parse(&src, &tokens, &ast, &diags); // true for 'const a = 1;'
 * node(&ast, ast.root).kind;            // NodeKind.File
 * hx_ast_free(&ast);
 * ```
 *
 * @see hx_parse_module
 * @since 1.0.0
 */

export extern "C" function hx_parse(src: readonly *HxSource, tokens: readonly *HxTokens, ast: *HxAst, diags: *HxDiagList): bool {
    hx_ast_init(ast, src, tokens);
    let ok = true;
    ast.root = hx_parse_module(ast, 0, diags, &ok);
    return ok;
}
