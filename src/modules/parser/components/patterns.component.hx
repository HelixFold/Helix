/**
 * Imports
 */

import { HxCaseData } from "@models/structs/ast-model.struct";
import { Sync } from "@modules/parser/constants/parser.constant";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { parseExpr } from "@modules/parser/components/expressions.component";
import { parseStatement } from "@modules/parser/components/statements.component";
import { currentKind, isName } from "@modules/parser/components/cursor.component";
import { expectSemicolon, expectToken } from "@modules/parser/components/report.component";
import { NodeKind, NoToken, FlagInclusive, FlagExpr, FlagPointer } from "@constants/ast.constant";
import { addNode, addRecord, invalidNode, listFinish } from "@modules/parser/components/tree.component";
import { leaveNesting, recover, attachHint, enterNesting } from "@modules/parser/components/report.component";
import { rangeRecord, scratchPush, scratchTop, addFlaggedNode } from "@modules/parser/components/tree.component";
import { errorExpected, errorToken, expectFieldName, expectName } from "@modules/parser/components/report.component";
import { literalKind, peekKind, acceptToken, advanceToken, atKind } from "@modules/parser/components/cursor.component";

/**
 * Parses a literal, an enum path, or a negative number inside a pattern.
 *
 * @param p - The parser state
 * @returns The index of the value node, or an invalid node
 *
 * @remarks
 * Only constant forms are accepted here, so a call or an operator other than a leading `-` reports an error.
 * A dotted path such as `Role.Admin` becomes a chain of field accesses on the first name.
 *
 * @example
 * ```hx
 * parsePatternValue(p); // (. Role Admin) for Role.Admin
 * ```
 *
 * @since 1.0.0
 */

export function parsePatternValue(p: *Parser): u32 {
    const kind = currentKind(p);
    const literal = literalKind(kind);
    if (literal != NodeKind.None) return addNode(p, literal, advanceToken(p), 0, 0);
    if (kind == TokenKind.Minus) {
        const token = advanceToken(p);
        return addNode(p, NodeKind.Negate, token, parsePatternValue(p), 0);
    }
    if (kind == TokenKind.Dot) {
        void advanceToken(p);
        const name = expectFieldName(p);
        return name == NoToken ? invalidNode(p) : addNode(p, NodeKind.EnumLiteral, name, 0, 0);
    }
    if (isName(kind)) {
        let path = addNode(p, NodeKind.Ident, advanceToken(p), 0, 0);
        while (acceptToken(p, TokenKind.Dot)) {
            const name = expectFieldName(p);
            if (name == NoToken) break;
            path = addNode(p, NodeKind.FieldAccess, name, path, 0);
        }
        return path;
    }
    void errorExpected(p, "a pattern");
    return invalidNode(p);
}

/**
 * Parses a struct pattern such as `{ x: 0, y }`.
 *
 * @param p - The parser state
 * @returns The index of the `PatternStruct` node
 *
 * @remarks
 * It expects the current token to be the `{` and consumes it without checking.
 * A field without a `:` binds the field to a variable of the same name, and its sub-pattern slot stays 0.
 *
 * @example
 * ```hx
 * parseStructPattern(p); // (pstruct (x 0) (y)) for { x: 0, y }
 * ```
 *
 * @since 1.0.0
 */

export function parseStructPattern(p: *Parser): u32 {
    const token = advanceToken(p);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const name = expectName(p, "a field name");
        if (name == NoToken) break;
        const sub = acceptToken(p, TokenKind.Colon) ? parsePattern(p) : 0;
        scratchPush(p, addNode(p, NodeKind.PatternField, name, sub, 0));
        if (!acceptToken(p, TokenKind.Comma)) break;
    }
    void expectToken(p, TokenKind.Rbrace);
    const fields = listFinish(p, top);
    return addNode(p, NodeKind.PatternStruct, token, fields.start, fields.end);
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
 *
 * @example
 * ```hx
 * parsePattern(p); // (bind n) for n
 * parsePattern(p); // (..= 400 499) for 400..=499
 * ```
 *
 * @since 1.0.0
 */

export function parsePattern(p: *Parser): u32 {
    if (!enterNesting(p)) return invalidNode(p);
    let result: u32 = 0;
    if (atKind(p, TokenKind.Lbrace)) {
        result = parseStructPattern(p);
    } else if (atKind(p, TokenKind.Star)) {
        void advanceToken(p);
        const name = expectName(p, "a binding name");
        result = addFlaggedNode(p, NodeKind.PatternBind, FlagPointer, name, 0, 0);
    } else if (isName(currentKind(p)) && peekKind(p, 1) != TokenKind.Dot && peekKind(p, 1) != TokenKind.Lparen &&
               peekKind(p, 1) != TokenKind.DotDot && peekKind(p, 1) != TokenKind.DotDotEq) {
        result = addNode(p, NodeKind.PatternBind, advanceToken(p), 0, 0);
    } else {
        const token = p.pos;
        const value = parsePatternValue(p);
        if (atKind(p, TokenKind.Lparen)) {
            void advanceToken(p);
            const payload = parsePattern(p);
            void expectToken(p, TokenKind.Rparen);
            result = addNode(p, NodeKind.PatternTag, token, value, payload);
        } else if (atKind(p, TokenKind.DotDot) || atKind(p, TokenKind.DotDotEq)) {
            const flags = atKind(p, TokenKind.DotDotEq) ? FlagInclusive : 0;
            const range = advanceToken(p);
            result = addFlaggedNode(p, NodeKind.PatternRange, flags, range, value, parsePatternValue(p));
        } else {
            result = addNode(p, NodeKind.PatternValue, token, value, 0);
        }
    }
    leaveNesting(p);
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
 *
 * @example
 * ```hx
 * parseCaseBody(p, true, colon); // the value 1 of case 0: 1;
 * ```
 *
 * @since 1.0.0
 */

export function parseCaseBody(p: *Parser, isExpr: bool, colon: u32): u32 {
    if (isExpr) {
        const value = parseExpr(p);
        expectSemicolon(p, "the case value");
        return value;
    }
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.KwCase) && !atKind(p, TokenKind.KwDefault) && !atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const before = p.pos;
        const stmt = parseStatement(p);
        if (stmt != 0) scratchPush(p, stmt);
        recover(p, Sync.Statement, before);
    }
    const stmts = listFinish(p, top);
    return addNode(p, NodeKind.Block, colon, stmts.start, stmts.end);
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
 *
 * @example
 * ```hx
 * parseCase(p, false); // (case (0) (block (call ok))) for case 0: ok();
 * ```
 *
 * @since 1.0.0
 */

export function parseCase(p: *Parser, isExpr: bool): u32 {
    if (atKind(p, TokenKind.KwDefault)) {
        const token = advanceToken(p);
        const colon = expectToken(p, TokenKind.Colon);
        return addNode(p, NodeKind.DefaultCase, token, parseCaseBody(p, isExpr, colon), 0);
    }
    if (!atKind(p, TokenKind.KwCase)) {
        const diag = errorExpected(p, "`case` or `default`");
        if (atKind(p, TokenKind.KwElse)) attachHint(p, diag, "the catch-all case is written `default:`");
        return 0;
    }
    const token = advanceToken(p);
    const top = scratchTop(p);
    while (true) {
        scratchPush(p, parsePattern(p));
        if (!acceptToken(p, TokenKind.Comma)) break;
    }
    const patterns = listFinish(p, top);
    let data = HxCaseData { patternsStart: patterns.start, patternsEnd: patterns.end, guard: 0, body: 0 };
    if (acceptToken(p, TokenKind.KwIf)) data.guard = parseExpr(p);
    const colon = p.pos;
    if (atKind(p, TokenKind.Arrow)) {
        const diag = errorToken(p, p.pos, "switch cases use `:`, not `=>`");
        attachHint(p, diag, "write `case X: value;`");
    }
    void expectToken(p, TokenKind.Colon);
    data.body = parseCaseBody(p, isExpr, colon);
    return addNode(p, NodeKind.Case, token, addRecord<HxCaseData>(p, data), 0);
}

/**
 * Parses a switch in its statement or expression form.
 *
 * @param p - The parser state
 * @param isExpr - Whether the switch is in its expression form
 * @returns The index of the `Switch` node
 *
 * @remarks
 * The expression form sets {@link FlagExpr} on the node, and each case body is then a value rather than statements.
 * A broken case resynchronizes at the next `case` or `default`, so one bad case does not hide the rest.
 *
 * @example
 * ```hx
 * parseSwitch(p, true); // (switch-expr code (default 0)) for switch (code) { default: 0; }
 * ```
 *
 * @since 1.0.0
 */

export function parseSwitch(p: *Parser, isExpr: bool): u32 {
    const token = advanceToken(p);
    void expectToken(p, TokenKind.Lparen);
    const subject = parseExpr(p);
    void expectToken(p, TokenKind.Rparen);
    void expectToken(p, TokenKind.Lbrace);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const before = p.pos;
        const c = parseCase(p, isExpr);
        if (c != 0) scratchPush(p, c);
        recover(p, Sync.Case, before);
    }
    void expectToken(p, TokenKind.Rbrace);
    const cases = listFinish(p, top);
    return addFlaggedNode(p, NodeKind.Switch, isExpr ? FlagExpr : 0, token, subject, rangeRecord(p, cases));
}
