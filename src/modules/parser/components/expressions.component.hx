/**
 * Imports
 */

import { TokenKind } from "@modules/lexer/constants/token.constant";
import { isKeyword } from "@modules/lexer/components/token.component";
import { parseSwitch } from "@modules/parser/components/patterns.component";
import { parseBlock } from "@modules/parser/components/statements.component";
import { parseStructType } from "@modules/parser/components/types.component";
import { BinaryInfo, Parser } from "@modules/parser/structs/parser-module.struct";
import { NodeKind, BinOp, NoToken, FlagInclusive } from "@constants/ast.constant";
import { rangeRecord, scratchPush } from "@modules/parser/components/tree.component";
import { parseType, parseGenericInstance, parseParams } from "@modules/parser/components/types.component";
import { HxTernaryData, HxCatchData, HxRange, HxFnData, HxSliceData } from "@models/structs/ast-model.struct";
import { canStartExpression, currentKind, isName, kindAt } from "@modules/parser/components/cursor.component";
import { PrecMul, PrecBitXor, PrecBitAnd, PrecShift, PrecAdd } from "@modules/parser/constants/parser.constant";
import { emptyFunctionData, invalidNode, listFinish, nodeKind } from "@modules/parser/components/tree.component";
import { PrecCompare, PrecBitOr, PrecCoalesce, PrecOr, PrecAnd } from "@modules/parser/constants/parser.constant";
import { attachHint, enterNesting, errorExpected, errorToken } from "@modules/parser/components/report.component";
import { scratchTop, setOp, addFlaggedNode, addNode, addRecord } from "@modules/parser/components/tree.component";
import { peekKind, acceptToken, adjacent, advanceToken, atKind } from "@modules/parser/components/cursor.component";
import { expectFieldName, expectName, expectToken, leaveNesting } from "@modules/parser/components/report.component";
import { literalKind, looksLikeGenericArgs, looksLikeParameterList } from "@modules/parser/components/cursor.component";

/**
 * Checks whether a node could name a type.
 *
 * @param p - The parser state
 * @param id - The index of the node
 * @returns `true` for an identifier, a field access, or a generic instance
 *
 * @remarks
 * {@link parsePostfix} reads a `<` or a `{` after an expression as type arguments or a struct literal
 * only when this holds.
 * It looks at the node kind alone, so a variable named like a type still passes.
 *
 * @example
 * ```hx
 * isTypeLike(p, id); // true for the node of ArrayList
 * isTypeLike(p, id); // false for the node of f()
 * ```
 *
 * @since 1.0.0
 */

export function isTypeLike(p: *Parser, id: u32): bool {
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
 *
 * @example
 * ```hx
 * parseExprList(p, TokenKind.Rparen); // two expressions for a, b)
 * ```
 *
 * @since 1.0.0
 */

export function parseExprList(p: *Parser, closing: TokenKind): HxRange {
    const top = scratchTop(p);
    while (!atKind(p, closing) && !atKind(p, TokenKind.Eof)) {
        scratchPush(p, parseExpr(p));
        if (!acceptToken(p, TokenKind.Comma)) break;
    }
    void expectToken(p, closing);
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
 *
 * @example
 * ```hx
 * parseStructLiteral(p, type); // (struct-literal User (id 1) (name name)) for { id: 1, name }
 * ```
 *
 * @since 1.0.0
 */

export function parseStructLiteral(p: *Parser, type: u32): u32 {
    const token = advanceToken(p);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const name = expectName(p, "a field name");
        if (name == NoToken) break;
        // `{ name }` is `{ name: name }`: the value is the name's own token, read like any other use of it
        const value = acceptToken(p, TokenKind.Colon) ? parseExpr(p) : addNode(p, NodeKind.Ident, name, 0, 0);
        scratchPush(p, addNode(p, NodeKind.FieldInit, name, value, 0));
        if (!acceptToken(p, TokenKind.Comma)) break;
    }
    void expectToken(p, TokenKind.Rbrace);
    return addNode(p, NodeKind.StructLiteral, token, type, rangeRecord(p, listFinish(p, top)));
}

/**
 * Parses a template literal into its text segments and interpolated values.
 *
 * @param p - The parser state
 * @returns The index of the `Template` node
 *
 * @remarks
 * A template without substitutions is a single token, so the node holds one text part.
 * Otherwise the parts alternate between text and expression,
 * and a well-formed template starts and ends with text.
 * A substitution that is not followed by the rest of the template is reported, and the parts parsed so far are kept.
 *
 * @example
 * ```hx
 * parseTemplate(p); // (template `id-${ id }`) for `id-${id}`
 * ```
 *
 * @since 1.0.0
 */

export function parseTemplate(p: *Parser): u32 {
    const first = p.pos;
    const top = scratchTop(p);
    scratchPush(p, addNode(p, NodeKind.TemplateText, advanceToken(p), 0, 0));
    if (kindAt(p, first) == TokenKind.TemplateHead) {
        while (true) {
            scratchPush(p, parseExpr(p));
            if (atKind(p, TokenKind.TemplateMiddle)) {
                scratchPush(p, addNode(p, NodeKind.TemplateText, advanceToken(p), 0, 0));
                continue;
            }
            if (atKind(p, TokenKind.TemplateTail)) {
                scratchPush(p, addNode(p, NodeKind.TemplateText, advanceToken(p), 0, 0));
                break;
            }
            void errorExpected(p, "`}` to close the template substitution");
            break;
        }
    }
    const parts = listFinish(p, top);
    return addNode(p, NodeKind.Template, first, parts.start, parts.end);
}

/**
 * Parses an arrow function such as `(x: i32): i32 => x * 2`.
 *
 * @param p - The parser state
 * @returns The index of the `ArrowFunction` node
 *
 * @remarks
 * The body is a block or a single expression.
 *
 * @example
 * ```hx
 * parseArrowFunction(p); // (arrow (params (x i32)) i32 (* x 2)) for (x: i32): i32 => x * 2
 * ```
 *
 * @since 1.0.0
 */

export function parseArrowFunction(p: *Parser): u32 {
    const token = p.pos;
    let fn = emptyFunctionData(NoToken, p.ast.nodesLen);
    let flags: u8 = 0;
    parseParams(p, &fn, &flags);
    if (acceptToken(p, TokenKind.Colon)) fn.returnType = parseType(p);
    void expectToken(p, TokenKind.Arrow);
    fn.body = atKind(p, TokenKind.Lbrace) ? parseBlock(p) : parseExpr(p);
    return addFlaggedNode(p, NodeKind.ArrowFunction, flags, token, addRecord<HxFnData>(p, fn), 0);
}

/**
 * Parses a literal, a name, or a bracketed construct that starts an expression.
 *
 * @param p - The parser state
 * @returns The index of the expression node, or an invalid node
 *
 * @remarks
 * A `(` starts an arrow function only when {@link looksLikeParameterList} says so,
 * and it opens a parenthesized value otherwise.
 * A parenthesized value adds no node of its own, so the inner expression is returned directly.
 * Any other token reports that an expression was expected and yields an invalid node.
 *
 * @example
 * ```hx
 * parsePrimary(p); // (array-literal 1 2 3) for [1, 2, 3]
 * ```
 *
 * @since 1.0.0
 */

export function parsePrimary(p: *Parser): u32 {
    const kind = currentKind(p);
    const literal = literalKind(kind);
    if (literal != NodeKind.None) return addNode(p, literal, advanceToken(p), 0, 0);
    if (isName(kind) || kind == TokenKind.KwVoid) return addNode(p, NodeKind.Ident, advanceToken(p), 0, 0);

    switch (kind) {
        case TokenKind.TemplateFull, TokenKind.TemplateHead: return parseTemplate(p);
        case TokenKind.Builtin: {
            const token = advanceToken(p);
            if (expectToken(p, TokenKind.Lparen) == NoToken) return invalidNode(p);
            const args = parseExprList(p, TokenKind.Rparen);
            return addNode(p, NodeKind.BuiltinCall, token, args.start, args.end);
        }
        case TokenKind.Lparen: {
            if (looksLikeParameterList(p)) return parseArrowFunction(p);
            void advanceToken(p);
            const inner = parseExpr(p);
            void expectToken(p, TokenKind.Rparen);
            return inner;
        }
        case TokenKind.Lbracket: {
            const token = advanceToken(p);
            const elements = parseExprList(p, TokenKind.Rbracket);
            return addNode(p, NodeKind.ArrayLiteral, token, elements.start, elements.end);
        }
        case TokenKind.Lbrace: return parseStructLiteral(p, 0);
        case TokenKind.Dot: {
            void advanceToken(p);
            const name = expectFieldName(p);
            return name == NoToken ? invalidNode(p) : addNode(p, NodeKind.EnumLiteral, name, 0, 0);
        }
        case TokenKind.KwSwitch: return parseSwitch(p, true);
        case TokenKind.KwImport: {
            void advanceToken(p);
            void expectToken(p, TokenKind.Lparen);
            const path = expectToken(p, TokenKind.String);
            void expectToken(p, TokenKind.Rparen);
            return path == NoToken ? invalidNode(p) : addNode(p, NodeKind.ImportExpr, path, 0, 0);
        }
        case TokenKind.KwStruct: return parseStructType(p);
        default: {
            void errorExpected(p, "an expression");
            return invalidNode(p);
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
 *
 * @example
 * ```hx
 * parseIndexSuffix(p, base); // (slice-of buf 0 n) for the [0..n] of buf[0..n]
 * ```
 *
 * @since 1.0.0
 */

export function parseIndexSuffix(p: *Parser, base: u32): u32 {
    const token = advanceToken(p);
    if (acceptToken(p, TokenKind.Rbracket)) return addNode(p, NodeKind.TypeSlice, token, base, 0);
    if (atKind(p, TokenKind.Star) && peekKind(p, 1) == TokenKind.Rbracket) {
        void advanceToken(p);
        void advanceToken(p);
        return addNode(p, NodeKind.TypeManyPointer, token, base, 0);
    }
    let first: u32 = 0;
    if (!atKind(p, TokenKind.DotDot) && !atKind(p, TokenKind.DotDotEq)) first = parseExpr(p);
    if (atKind(p, TokenKind.DotDot) || atKind(p, TokenKind.DotDotEq)) {
        const flags = atKind(p, TokenKind.DotDotEq) ? FlagInclusive : 0;
        void advanceToken(p);
        const end = atKind(p, TokenKind.Rbracket) ? 0 : parseExpr(p);
        const slice = HxSliceData { start: first, end };
        void expectToken(p, TokenKind.Rbracket);
        return addFlaggedNode(p, NodeKind.Slice, flags, token, base, addRecord<HxSliceData>(p, slice));
    }
    void expectToken(p, TokenKind.Rbracket);
    return addNode(p, NodeKind.Index, token, base, first);
}

/**
 * Parses a primary expression and its calls, indexes, field accesses, and unwraps.
 *
 * @param p - The parser state
 * @returns The index of the expression node
 *
 * @remarks
 * A `<` or `{` after a type-like expression starts type arguments or a struct literal.
 *
 * @example
 * ```hx
 * parsePostfix(p); // (index (call (. a b) 1) 2) for a.b(1)[2]
 * ```
 *
 * @since 1.0.0
 */

export function parsePostfix(p: *Parser): u32 {
    let expr = parsePrimary(p);
    while (true) {
        switch (currentKind(p)) {
            case TokenKind.Lparen: {
                const token = advanceToken(p);
                const args = parseExprList(p, TokenKind.Rparen);
                expr = addNode(p, NodeKind.Call, token, expr, rangeRecord(p, args));
            }
            case TokenKind.Lbracket: expr = parseIndexSuffix(p, expr);
            case TokenKind.Dot, TokenKind.QuestionDot: {
                const kind = atKind(p, TokenKind.Dot) ? NodeKind.FieldAccess : NodeKind.OptionalField;
                void advanceToken(p);
                const name = expectFieldName(p);
                if (name == NoToken) return expr;
                expr = addNode(p, kind, name, expr, 0);
            }
            case TokenKind.Bang: expr = addNode(p, NodeKind.Unwrap, advanceToken(p), expr, 0);
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
 *
 * @example
 * ```hx
 * parseUnary(p); // (neg a) for -a
 * ```
 *
 * @since 1.0.0
 */

export function parseUnary(p: *Parser): u32 {
    let kind = NodeKind.None;
    let whole = false;
    switch (currentKind(p)) {
        // `x ?? return 0`, `x ?? break`, `f() catch return`: leaving as an expression, which never has a value
        case TokenKind.KwReturn: {
            const token = advanceToken(p);
            const value = canStartExpression(currentKind(p)) ? parseExpr(p) : 0;
            return addNode(p, NodeKind.Return, token, value, 0);
        }
        case TokenKind.KwBreak, TokenKind.KwContinue: {
            const kindOf = atKind(p, TokenKind.KwBreak) ? NodeKind.Break : NodeKind.Continue;
            const token = advanceToken(p);
            const label = isName(currentKind(p)) ? advanceToken(p) : NoToken;
            return addNode(p, kindOf, token, label, 0);
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
            if (!canStartExpression(peekKind(p, 1))) return parsePostfix(p);   // `void` as a type name
            kind = NodeKind.Discard;
            whole = true;
        }
        case TokenKind.KwReadonly, TokenKind.KwDyn: {
            if (!isName(peekKind(p, 1)) && peekKind(p, 1) != TokenKind.Star) return parsePostfix(p);
            kind = atKind(p, TokenKind.KwReadonly) ? NodeKind.TypeReadonly : NodeKind.TypeDyn;
        }
        default: return parsePostfix(p);
    }
    if (!enterNesting(p)) return invalidNode(p);
    const token = advanceToken(p);
    const operand = whole ? parseExpr(p) : parseUnary(p);
    leaveNesting(p);
    return addNode(p, kind, token, operand, 0);
}

/**
 * Parses an expression and its `as` casts.
 *
 * @param p - The parser state
 * @returns The index of the expression node
 *
 * @remarks
 * A cast binds tighter than any binary operator, so `a * b as u64` reads as `a * (b as u64)`.
 *
 * @example
 * ```hx
 * parseCast(p); // (as b u64) for b as u64
 * ```
 *
 * @since 1.0.0
 */

export function parseCast(p: *Parser): u32 {
    let value = parseUnary(p);
    while (atKind(p, TokenKind.KwAs)) {
        const token = advanceToken(p);
        value = addNode(p, NodeKind.Cast, token, value, parseType(p));
    }
    return value;
}

/**
 * Returns the operator info of a left-associative binary operator of one token.
 *
 * @param prec - The precedence
 * @param op - The operator
 * @returns The operator info
 *
 * @remarks
 * It builds the common case for {@link currentBinaryOperator}.
 * The right-associative `??` and the two-token `>>` build their info directly instead.
 *
 * @example
 * ```hx
 * binaryOperator(PrecAdd, BinOp.Add); // { prec: 9, op: BinOp.Add, right: false, width: 1 }
 * ```
 *
 * @since 1.0.0
 */

export function binaryOperator(prec: u8, op: BinOp): BinaryInfo {
    return BinaryInfo { prec, op, right: false, width: 1 };
}

/**
 * Returns how the current token acts as a binary operator.
 *
 * @param p - The parser state
 * @returns The operator info, with a precedence of 0 when the token is not one
 *
 * @remarks
 * Two adjacent `>` tokens form a `>>` shift,
 * and a `>` touching a `>=` is the start of `>>=`, which ends the expression.
 *
 * @example
 * ```hx
 * currentBinaryOperator(p); // { prec: PrecShift, op: BinOp.Shr, width: 2 } at the >> of a >> 2
 * ```
 *
 * @since 1.0.0
 */

export function currentBinaryOperator(p: *Parser): BinaryInfo {
    return switch (currentKind(p)) {
        case TokenKind.QuestionQuestion: BinaryInfo { prec: PrecCoalesce, op: BinOp.Coalesce, right: true, width: 1 };
        case TokenKind.PipePipe: binaryOperator(PrecOr, BinOp.Or);
        case TokenKind.AmpAmp: binaryOperator(PrecAnd, BinOp.And);
        case TokenKind.EqEq: binaryOperator(PrecCompare, BinOp.Eq);
        case TokenKind.BangEq: binaryOperator(PrecCompare, BinOp.Ne);
        case TokenKind.Lt: binaryOperator(PrecCompare, BinOp.Lt);
        case TokenKind.LtEq: binaryOperator(PrecCompare, BinOp.Le);
        case TokenKind.GtEq: binaryOperator(PrecCompare, BinOp.Ge);
        case TokenKind.Gt:
            adjacent(p, p.pos) && peekKind(p, 1) == TokenKind.Gt ? BinaryInfo { prec: PrecShift, op: BinOp.Shr, right: false, width: 2 }
            : adjacent(p, p.pos) && peekKind(p, 1) == TokenKind.GtEq ? binaryOperator(0, BinOp.None)   // `>>=` assignment
            : binaryOperator(PrecCompare, BinOp.Gt);
        case TokenKind.Pipe: binaryOperator(PrecBitOr, BinOp.BitOr);
        case TokenKind.Caret: binaryOperator(PrecBitXor, BinOp.BitXor);
        case TokenKind.Amp: binaryOperator(PrecBitAnd, BinOp.BitAnd);
        case TokenKind.LtLt: binaryOperator(PrecShift, BinOp.Shl);
        case TokenKind.Plus: binaryOperator(PrecAdd, BinOp.Add);
        case TokenKind.Minus: binaryOperator(PrecAdd, BinOp.Sub);
        case TokenKind.PlusPercent: binaryOperator(PrecAdd, BinOp.AddWrap);
        case TokenKind.MinusPercent: binaryOperator(PrecAdd, BinOp.SubWrap);
        case TokenKind.PlusPipe: binaryOperator(PrecAdd, BinOp.AddSat);
        case TokenKind.MinusPipe: binaryOperator(PrecAdd, BinOp.SubSat);
        case TokenKind.Star: binaryOperator(PrecMul, BinOp.Mul);
        case TokenKind.Slash: binaryOperator(PrecMul, BinOp.Div);
        case TokenKind.Percent: binaryOperator(PrecMul, BinOp.Mod);
        case TokenKind.StarPercent: binaryOperator(PrecMul, BinOp.MulWrap);
        case TokenKind.StarPipe: binaryOperator(PrecMul, BinOp.MulSat);
        default: binaryOperator(0, BinOp.None);
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
 *
 * @example
 * ```hx
 * parseBinary(p, PrecCoalesce); // (+ a (* b c)) for a + b * c
 * ```
 *
 * @since 1.0.0
 */

export function parseBinary(p: *Parser, minPrec: u8): u32 {
    let lhs = parseCast(p);
    while (true) {
        const op = currentBinaryOperator(p);
        if (op.prec == 0 || op.prec < minPrec) return lhs;
        const token = p.pos;
        for (const _ of 0..op.width) void advanceToken(p);
        const rhs = parseBinary(p, op.right ? op.prec : op.prec + 1);
        lhs = addNode(p, NodeKind.Binary, token, lhs, rhs);
        setOp(p, lhs, op.op as u16);
        if (op.prec == PrecCompare && currentBinaryOperator(p).prec == PrecCompare) {
            const diag = errorToken(p, p.pos, "comparison operators cannot be chained");
            attachHint(p, diag, "combine the comparisons with `&&`, as in `a < b && b < c`");
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
 *
 * @example
 * ```hx
 * startsCaptureBody(TokenKind.Lbrace); // true, as in catch (e) { ... }
 * startsCaptureBody(TokenKind.Plus);   // false, as in catch (fallback) + 1
 * ```
 *
 * @since 1.0.0
 */

export function startsCaptureBody(kind: TokenKind): bool {
    return kind == TokenKind.Lbrace || kind == TokenKind.Ident || isKeyword(kind) || literalKind(kind) != NodeKind.None ||
           kind == TokenKind.Builtin || kind == TokenKind.TemplateFull || kind == TokenKind.TemplateHead;
}

/**
 * Parses a capture such as `(e)` after `catch` or `errdefer`.
 *
 * @param p - The parser state
 * @returns The index of the captured name, or {@link NoToken} when there is no capture
 *
 * @remarks
 * It consumes nothing unless the `(name)` is followed by a token that can start the handler,
 * so `x catch (fallback) + 1` keeps `(fallback)` as a parenthesized value.
 * The check uses {@link startsCaptureBody} on the token after the `)`.
 *
 * @example
 * ```hx
 * parseCapture(p); // the index of e in catch (e) { log(e); }
 * ```
 *
 * @since 1.0.0
 */

export function parseCapture(p: *Parser): u32 {
    if (atKind(p, TokenKind.Lparen) && isName(peekKind(p, 1)) && peekKind(p, 2) == TokenKind.Rparen && startsCaptureBody(peekKind(p, 3))) {
        void advanceToken(p);
        const name = advanceToken(p);
        void advanceToken(p);
        return name;
    }
    return NoToken;
}

/**
 * Parses binary expressions joined by `catch`.
 *
 * @param p - The parser state
 * @returns The index of the expression node
 *
 * @remarks
 * The handler is a block or a binary expression, so a ternary after `catch` needs parentheses.
 * Several `catch` clauses chain from left to right, each wrapping the expression before it.
 *
 * @example
 * ```hx
 * parseCatch(p); // (catch (call parse s) _ 8080) for parse(s) catch 8080
 * ```
 *
 * @since 1.0.0
 */

export function parseCatch(p: *Parser): u32 {
    let lhs = parseBinary(p, PrecCoalesce);
    while (atKind(p, TokenKind.KwCatch)) {
        const token = advanceToken(p);
        const capture = parseCapture(p);
        const body = atKind(p, TokenKind.Lbrace) ? parseBlock(p) : parseBinary(p, PrecCoalesce);
        lhs = addNode(p, NodeKind.Catch, token, lhs, addRecord<HxCatchData>(p, HxCatchData { captureToken: capture, body }));
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
 *
 * @example
 * ```hx
 * parseExpr(p); // (? (< x lo) lo x) for x < lo ? lo : x
 * ```
 *
 * @since 1.0.0
 */

export function parseExpr(p: *Parser): u32 {
    if (!enterNesting(p)) return invalidNode(p);
    let cond = parseCatch(p);
    if (atKind(p, TokenKind.Question)) {
        const token = advanceToken(p);
        const thenValue = parseExpr(p);
        void expectToken(p, TokenKind.Colon);
        const elseValue = parseExpr(p);
        cond = addNode(p, NodeKind.Ternary, token, cond, addRecord<HxTernaryData>(p, HxTernaryData { thenValue: thenValue, elseValue: elseValue }));
    }
    leaveNesting(p);
    return cond;
}
