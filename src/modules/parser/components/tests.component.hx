/**
 * Imports
 */

import { TestPanics } from "@constants/ast.constant";
import { HxTestData } from "@models/structs/ast-model.struct";
import { Sync } from "@modules/parser/constants/parser.constant";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { peekKind } from "@modules/parser/components/cursor.component";
import { parseBlock } from "@modules/parser/components/statements.component";
import { parseVarDecl } from "@modules/parser/components/declarations.component";
import { listFinish, scratchPush } from "@modules/parser/components/tree.component";
import { expectToken, leaveNesting } from "@modules/parser/components/report.component";
import { scratchTop, setOp, addNode, addRecord, invalidNode } from "@modules/parser/components/tree.component";
import { HookNames, NodeKind, NoToken, TestPlain, TestSkip, TestOnly, TestTodo } from "@constants/ast.constant";
import { recover, reportDisallowed, attachHint, attachHintf } from "@modules/parser/components/report.component";
import { tokenIs, acceptToken, advanceToken, atKind, atTestItem } from "@modules/parser/components/cursor.component";
import { enterNesting, errorExpected, errorToken, expectSemicolon } from "@modules/parser/components/report.component";

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
 *
 * @example
 * ```hx
 * parseTestItem(p); // (test :skip "a" (block)) for test.skip("a") {}
 * ```
 *
 * @since 1.0.0
 */

export function parseTestItem(p: *Parser): u32 {
    const keyword = advanceToken(p);
    const isDescribe = tokenIs(p, keyword, "describe");
    let mode = TestPlain;
    if (acceptToken(p, TokenKind.Dot)) {
        const names: string[6] = ["", "skip", "only", "todo", "failing", "panics"];
        const modifier = advanceToken(p);
        for (const i of 1..6) {
            if (tokenIs(p, modifier, names[i])) mode = @truncate(u16, i);
        }
        if (mode == TestPlain || (isDescribe && mode != TestSkip && mode != TestOnly)) {
            const diag = reportDisallowed(p, modifier, isDescribe ? "unknown `describe` modifier" : "unknown `test` modifier");
            attachHint(p, diag, isDescribe ? "`describe` takes `.skip` or `.only`" : "use `.skip`, `.only`, `.todo`, `.failing` or `.panics`");
            mode = TestPlain;
        }
    }
    if (expectToken(p, TokenKind.Lparen) == NoToken) return 0;
    let name = NoToken;
    if (atKind(p, TokenKind.String)) {
        name = advanceToken(p);
    } else {
        const diag = errorExpected(p, isDescribe ? "the block's name as a string" : "the test's name as a string");
        attachHintf(p, diag, `write \`${isDescribe ? "describe" : "test"}("should ...") { ... }\``);
        return 0;
    }
    let message = NoToken;
    if (mode == TestPanics) {
        if (expectToken(p, TokenKind.Comma) == NoToken) return 0;
        if (!atKind(p, TokenKind.String)) {
            const diag = errorExpected(p, "the expected panic message");
            attachHint(p, diag, "write `test.panics(\"should stop\", \"index out of bounds\") { ... }`");
            return 0;
        }
        message = advanceToken(p);
    }
    let timeout = NoToken;
    if (!isDescribe && acceptToken(p, TokenKind.Comma)) {   // `{ timeout: 100 }`, the only option so far
        if (!acceptToken(p, TokenKind.Lbrace) || !tokenIs(p, p.pos, "timeout") || peekKind(p, 1) != TokenKind.Colon ||
            peekKind(p, 2) != TokenKind.Int) {
            const diag = errorExpected(p, "test options");
            attachHint(p, diag, "write `{ timeout: 10_000 }` (milliseconds)");
            let depth: u32 = 0;
            while (!atKind(p, TokenKind.Eof) && (depth > 0 || !atKind(p, TokenKind.Rparen))) {   // to the `)`
                if (atKind(p, TokenKind.Lbrace)) depth += 1;
                else if (atKind(p, TokenKind.Rbrace) && depth > 0) depth -= 1;
                void advanceToken(p);
            }
            p.panicking = false;
        } else {
            timeout = p.pos + 2;
            p.pos += 3;
            void acceptToken(p, TokenKind.Comma);
            if (expectToken(p, TokenKind.Rbrace) == NoToken) return 0;
        }
    }
    if (expectToken(p, TokenKind.Rparen) == NoToken) return 0;

    if (isDescribe) {
        const body = parseDescribeBody(p);
        unsafe {
            p.ast.nodes![body].token = name;
            p.ast.nodes![body].op = mode;
        }
        return body;
    }
    let body: u32 = 0;
    if (mode == TestTodo) {
        if (atKind(p, TokenKind.Lbrace)) {
            const diag = reportDisallowed(p, p.pos, "a `test.todo` has no body");
            attachHint(p, diag, "write `test.todo(\"...\");`, or drop `.todo` once the test is written");
            void parseBlock(p);
        } else {
            expectSemicolon(p, "`test.todo(...)`");
        }
    } else {
        body = parseBlock(p);
    }
    const node = addNode(p, NodeKind.Test, name, body, addRecord<HxTestData>(p, HxTestData { messageToken: message, timeoutToken: timeout }));
    setOp(p, node, mode);
    return node;
}

/**
 * Parses a hook such as `beforeEach { ... }`.
 *
 * @param p - The parser state
 * @returns The index of the `Hook` node, or 0 when the current token is not a hook
 *
 * @remarks
 * A hook takes a block, so a hook written with arguments is reported.
 *
 * @example
 * ```hx
 * parseHook(p); // (beforeEach (block (call reset))) for beforeEach { reset(); }
 * ```
 *
 * @since 1.0.0
 */

export function parseHook(p: *Parser): u32 {
    for (const name, i of HookNames) {
        if (!tokenIs(p, p.pos, name)) continue;
        const keyword = advanceToken(p);
        if (atKind(p, TokenKind.Lparen)) {
            const diag = errorToken(p, p.pos, "a hook takes a block, not arguments");
            attachHintf(p, diag, `write \`${name} { ... }\``);
            return 0;
        }
        const node = addNode(p, NodeKind.Hook, keyword, parseBlock(p), 0);
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
 *
 * @example
 * ```hx
 * parseDescribeBody(p); // (describe "s" (test "t" (block))) for the body of describe("s") { test("t") {} }
 * ```
 *
 * @since 1.0.0
 */

export function parseDescribeBody(p: *Parser): u32 {
    const open = p.pos;
    if (expectToken(p, TokenKind.Lbrace) == NoToken) return invalidNode(p);
    if (!enterNesting(p)) return invalidNode(p);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const before = p.pos;
        let item: u32 = 0;
        if (atKind(p, TokenKind.KwLet) || atKind(p, TokenKind.KwConst)) {
            item = parseVarDecl(p, 0);
        } else if (atTestItem(p)) {
            item = parseTestItem(p);
        } else {
            item = parseHook(p);
            if (item == 0 && !p.panicking) {
                const diag = errorExpected(p, "a test, a hook or a `let`/`const`");
                attachHint(p, diag, "a `describe` holds `test(...) { }`, `describe(...) { }`, `beforeEach { }` and the like, and the variables its tests share");
            }
        }
        if (item != 0) scratchPush(p, item);
        recover(p, Sync.Statement, before);
    }
    leaveNesting(p);
    if (!acceptToken(p, TokenKind.Rbrace)) {
        const diag = errorToken(p, open, "this `{` is never closed");
        attachHint(p, diag, "add a matching `}`");
    }
    const items = listFinish(p, top);
    return addNode(p, NodeKind.Describe, open, items.start, items.end);
}
