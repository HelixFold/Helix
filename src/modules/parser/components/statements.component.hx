/**
 * Imports
 */

import { hint as diagHint } from "@models/diagnostic.model";
import { Sync } from "@modules/parser/constants/parser.constant";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { recover } from "@modules/parser/components/report.component";
import { parseSwitch } from "@modules/parser/components/patterns.component";
import { NodeKind, BinOp, NoToken, FlagInclusive } from "@constants/ast.constant";
import { atKind, currentKind } from "@modules/parser/components/cursor.component";
import { parseCapture, parseExpr } from "@modules/parser/components/expressions.component";
import { addRecord, invalidNode, listFinish } from "@modules/parser/components/tree.component";
import { parseFunction, parseVarDecl } from "@modules/parser/components/declarations.component";
import { HxIfData, HxWhileData, HxForData, HxForOfData } from "@models/structs/ast-model.struct";
import { isName, peekKind, acceptToken, adjacent, advanceToken } from "@modules/parser/components/cursor.component";
import { scratchPush, scratchTop, setOp, addFlaggedNode, addNode } from "@modules/parser/components/tree.component";
import { expectName, expectSemicolon, expectToken, leaveNesting } from "@modules/parser/components/report.component";
import { reportDisallowed, attachHint, enterNesting, errorToken } from "@modules/parser/components/report.component";

/**
 * Parses a block of statements in braces.
 *
 * @param p - The parser state
 * @returns The index of the `Block` node, or an invalid node without an opening brace
 *
 * @remarks
 * A broken statement resynchronizes at the next statement, so one error does not end the block.
 * A missing `}` is reported at the opening brace, where it is easier to find than at the end of the file.
 *
 * @example
 * ```hx
 * parseBlock(p); // (block (call a) (call b)) for { a(); b(); }
 * ```
 *
 * @since 1.0.0
 */

export function parseBlock(p: *Parser): u32 {
    const open = p.pos;
    if (expectToken(p, TokenKind.Lbrace) == NoToken) return invalidNode(p);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const before = p.pos;
        const stmt = parseStatement(p);
        if (stmt != 0) scratchPush(p, stmt);
        recover(p, Sync.Statement, before);
    }
    if (!acceptToken(p, TokenKind.Rbrace)) {
        const diag = errorToken(p, open, "this `{` is never closed");
        attachHint(p, diag, "add a matching `}`");
    }
    const stmts = listFinish(p, top);
    return addNode(p, NodeKind.Block, open, stmts.start, stmts.end);
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
 *
 * @example
 * ```hx
 * assignOp(p, &width); // BinOp.Add with width 1 at +=
 * assignOp(p, &width); // null at ==
 * ```
 *
 * @since 1.0.0
 */

export function assignOp(p: *Parser, width: *u32): ?BinOp {
    *width = 1;
    return switch (currentKind(p)) {
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
 *
 * @remarks
 * The lexer has no `>>` or `>>=` token, so that the `>` tokens of nested type arguments close one list each.
 * The two tokens must touch, so `> >=` with a space is not an assignment.
 *
 * @example
 * ```hx
 * shrAssign(p, &width); // BinOp.Shr with width 2 at the > >= of x >>= 1
 * ```
 *
 * @since 1.0.0
 */

export function shrAssign(p: *Parser, width: *u32): ?BinOp {
    if (!adjacent(p, p.pos) || peekKind(p, 1) != TokenKind.GtEq) return null;
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
 *
 * @example
 * ```hx
 * parseSimpleStatement(p, true); // (+= x 1) for x += 1;
 * ```
 *
 * @since 1.0.0
 */

export function parseSimpleStatement(p: *Parser, requireSemicolon: bool): u32 {
    const first = p.pos;
    const target = parseExpr(p);
    let result: u32 = 0;
    let width: u32 = 1;
    if (const op = assignOp(p, &width)) {
        const token = p.pos;
        for (const _ of 0..width) void advanceToken(p);
        result = addNode(p, NodeKind.Assign, token, target, parseExpr(p));
        setOp(p, result, op as u16);
    } else if (atKind(p, TokenKind.PlusPlus) || atKind(p, TokenKind.MinusMinus)) {
        const kind = atKind(p, TokenKind.PlusPlus) ? NodeKind.Increment : NodeKind.Decrement;
        result = addNode(p, kind, advanceToken(p), target, 0);
    } else {
        result = addNode(p, NodeKind.ExprStmt, first, target, 0);
    }
    if (requireSemicolon) expectSemicolon(p, "the statement");
    return result;
}

/**
 * Parses a capture such as `const name =` at the start of an `if` or `while` condition.
 *
 * @param p - The parser state
 * @returns The index of the captured name, or {@link NoToken} when there is no capture
 *
 * @remarks
 * It consumes nothing unless it sees `const`, a name, and `=` in a row,
 * so an ordinary condition is left for the expression parser.
 * The captured name binds the unwrapped value of an optional inside the branch or loop body.
 *
 * @example
 * ```hx
 * parseConditionCapture(p); // the index of v in if (const v = find())
 * ```
 *
 * @since 1.0.0
 */

export function parseConditionCapture(p: *Parser): u32 {
    if (atKind(p, TokenKind.KwConst) && isName(peekKind(p, 1)) && peekKind(p, 2) == TokenKind.Eq) {
        void advanceToken(p);
        const name = advanceToken(p);
        void advanceToken(p);
        return name;
    }
    return NoToken;
}

/**
 * Parses an `if` statement with its optional `else`.
 *
 * @param p - The parser state
 * @returns The index of the `If` node
 *
 * @remarks
 * Each branch is a single statement, which is a block when it starts with `{`,
 * so `else if` needs no rule of its own and is an `if` statement in the else branch.
 * An `else` binds to the nearest `if`.
 *
 * @example
 * ```hx
 * parseIf(p); // (if (> x 0) (call a)) for if (x > 0) a();
 * ```
 *
 * @since 1.0.0
 */

export function parseIf(p: *Parser): u32 {
    const token = advanceToken(p);
    void expectToken(p, TokenKind.Lparen);
    let data = HxIfData { condition: 0, captureToken: parseConditionCapture(p), thenBranch: 0, elseBranch: 0 };
    data.condition = parseExpr(p);
    void expectToken(p, TokenKind.Rparen);
    data.thenBranch = parseStatement(p);
    if (acceptToken(p, TokenKind.KwElse)) data.elseBranch = parseStatement(p);
    return addNode(p, NodeKind.If, token, addRecord<HxIfData>(p, data), 0);
}

/**
 * Parses a `while` loop.
 *
 * @param p - The parser state
 * @param label - The index of the label token, or {@link NoToken}
 * @returns The index of the `While` node
 *
 * @remarks
 * The condition takes the same `const name =` capture as an `if`, which loops while an optional holds a value.
 * The label comes from the caller, which reads it before the `while` keyword.
 *
 * @example
 * ```hx
 * parseWhile(p, NoToken); // (while ok (block)) for while (ok) {}
 * ```
 *
 * @since 1.0.0
 */

export function parseWhile(p: *Parser, label: u32): u32 {
    const token = advanceToken(p);
    void expectToken(p, TokenKind.Lparen);
    let data = HxWhileData { condition: 0, captureToken: parseConditionCapture(p), body: 0, labelToken: label };
    data.condition = parseExpr(p);
    void expectToken(p, TokenKind.Rparen);
    data.body = parseStatement(p);
    return addNode(p, NodeKind.While, token, addRecord<HxWhileData>(p, data), 0);
}

/**
 * Parses a `for-of` loop or a C-style `for` loop.
 *
 * @param p - The parser state
 * @param label - The index of the label token, or {@link NoToken}
 * @returns The index of the `ForOf` or `For` node
 *
 * @remarks
 * A `for-of` binding is always `const`, so `let` there is reported.
 * A range after `of` becomes a `Range` node.
 *
 * @example
 * ```hx
 * parseFor(p, NoToken); // (for-of x items (block)) for for (const x of items) {}
 * ```
 *
 * @since 1.0.0
 */

export function parseFor(p: *Parser, label: u32): u32 {
    const token = advanceToken(p);
    void expectToken(p, TokenKind.Lparen);
    const binding = (atKind(p, TokenKind.KwConst) || atKind(p, TokenKind.KwLet)) && isName(peekKind(p, 1));
    if (binding && (peekKind(p, 2) == TokenKind.KwOf || peekKind(p, 2) == TokenKind.Comma)) {
        if (atKind(p, TokenKind.KwLet)) {
            const diag = reportDisallowed(p, p.pos, "for-of items are always `const`");
            diagHint(p.diags, diag, "write `for (const x of ...)`; to change items, index them: `items[i]`");
        }
        void advanceToken(p);
        let data = HxForOfData { itemToken: advanceToken(p), indexToken: NoToken, iterable: 0, body: 0, labelToken: label };
        if (acceptToken(p, TokenKind.Comma)) data.indexToken = expectName(p, "an index name");
        void expectToken(p, TokenKind.KwOf);
        let iterable = parseExpr(p);
        if (atKind(p, TokenKind.DotDot) || atKind(p, TokenKind.DotDotEq)) {
            const flags = atKind(p, TokenKind.DotDotEq) ? FlagInclusive : 0;
            const range = advanceToken(p);
            iterable = addFlaggedNode(p, NodeKind.Range, flags, range, iterable, parseExpr(p));
        }
        data.iterable = iterable;
        void expectToken(p, TokenKind.Rparen);
        data.body = parseStatement(p);
        return addNode(p, NodeKind.ForOf, token, addRecord<HxForOfData>(p, data), 0);
    }

    let data = HxForData { init: 0, condition: 0, step: 0, body: 0, labelToken: label };
    if (!acceptToken(p, TokenKind.Semicolon)) {
        if (atKind(p, TokenKind.KwConst) || atKind(p, TokenKind.KwLet)) data.init = parseVarDecl(p, 0);
        else data.init = parseSimpleStatement(p, true);
    }
    if (!atKind(p, TokenKind.Semicolon)) data.condition = parseExpr(p);
    void expectToken(p, TokenKind.Semicolon);
    if (!atKind(p, TokenKind.Rparen)) data.step = parseSimpleStatement(p, false);
    void expectToken(p, TokenKind.Rparen);
    data.body = parseStatement(p);
    return addNode(p, NodeKind.For, token, addRecord<HxForData>(p, data), 0);
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
 *
 * @example
 * ```hx
 * parseStatement(p); // (defer (call (. file close))) for defer file.close();
 * ```
 *
 * @since 1.0.0
 */

export function parseStatement(p: *Parser): u32 {
    if (!enterNesting(p)) return invalidNode(p);
    let result: u32 = 0;
    const token = p.pos;
    switch (currentKind(p)) {
        case TokenKind.Semicolon: void advanceToken(p);
        case TokenKind.Lbrace: result = parseBlock(p);
        case TokenKind.KwConst, TokenKind.KwLet: result = parseVarDecl(p, 0);
        case TokenKind.KwReturn: {
            void advanceToken(p);
            const value = atKind(p, TokenKind.Semicolon) || atKind(p, TokenKind.Rbrace) ? 0 : parseExpr(p);
            expectSemicolon(p, "`return`");
            result = addNode(p, NodeKind.Return, token, value, 0);
        }
        case TokenKind.KwThrow: {
            void advanceToken(p);
            const value = parseExpr(p);
            expectSemicolon(p, "`throw`");
            result = addNode(p, NodeKind.Throw, token, value, 0);
        }
        case TokenKind.KwBreak, TokenKind.KwContinue: {
            const kind = atKind(p, TokenKind.KwBreak) ? NodeKind.Break : NodeKind.Continue;
            void advanceToken(p);
            const label = isName(currentKind(p)) ? advanceToken(p) : NoToken;
            expectSemicolon(p, kind == NodeKind.Break ? "`break`" : "`continue`");
            result = addNode(p, kind, token, label, 0);
        }
        case TokenKind.KwIf: result = parseIf(p);
        case TokenKind.KwWhile: result = parseWhile(p, NoToken);
        case TokenKind.KwFor: result = parseFor(p, NoToken);
        case TokenKind.KwSwitch: result = parseSwitch(p, false);
        case TokenKind.KwDefer: {
            void advanceToken(p);
            result = addNode(p, NodeKind.Defer, token, parseStatement(p), 0);
        }
        case TokenKind.KwErrdefer: {
            void advanceToken(p);
            const capture = parseCapture(p);
            result = addNode(p, NodeKind.Errdefer, token, parseStatement(p), capture);
        }
        case TokenKind.KwUnsafe: {
            void advanceToken(p);
            result = addNode(p, NodeKind.UnsafeBlock, token, parseBlock(p), 0);
        }
        case TokenKind.KwComptime: {
            if (peekKind(p, 1) == TokenKind.Lbrace) {
                void advanceToken(p);
                result = addNode(p, NodeKind.ComptimeBlock, token, parseBlock(p), 0);
            } else {
                result = parseSimpleStatement(p, true);
            }
        }
        case TokenKind.KwFunction: {
            const diag = reportDisallowed(p, token, "functions can't be declared inside a function");
            diagHint(p.diags, diag, "move it to the top level, or use an arrow function: `const double = (x: i32): i32 => x * 2;`");
            result = parseFunction(p, 0, NoToken);
        }
        default: {
            if (isName(currentKind(p)) && peekKind(p, 1) == TokenKind.Colon &&
                (peekKind(p, 2) == TokenKind.KwFor || peekKind(p, 2) == TokenKind.KwWhile)) {
                const label = advanceToken(p);
                void advanceToken(p);
                result = atKind(p, TokenKind.KwFor) ? parseFor(p, label) : parseWhile(p, label);
            } else {
                result = parseSimpleStatement(p, true);
            }
        }
    }
    leaveNesting(p);
    return result;
}
