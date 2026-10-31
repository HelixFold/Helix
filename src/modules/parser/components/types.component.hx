/**
 * Imports
 */

import { DiagError } from "@constants/diagnostic.constant";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { HxRange, HxFnData } from "@models/structs/ast-model.struct";
import { emitf, hintf as diagHintf } from "@models/diagnostic.model";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { emptyFunctionData } from "@modules/parser/components/tree.component";
import { Sync, MaxArrayDims } from "@modules/parser/constants/parser.constant";
import { parseExpr, parsePrimary } from "@modules/parser/components/expressions.component";
import { looksLikeParameterList, peekKind } from "@modules/parser/components/cursor.component";
import { NodeKind, NoToken, FlagExtern, FlagVariadic, FlagComptime } from "@constants/ast.constant";
import { enterNesting, errorExpected, errorToken } from "@modules/parser/components/report.component";
import { scratchPush, addFlaggedNode, addNode, addRecord } from "@modules/parser/components/tree.component";
import { expectToken, leaveNesting, recover, attachHint } from "@modules/parser/components/report.component";
import { scratchTop, invalidNode, listFinish, rangeRecord } from "@modules/parser/components/tree.component";
import { tokenLength, tokenSource, tokenStart, acceptToken } from "@modules/parser/components/cursor.component";
import { expectGenericClose, expectMemberSeparator, expectName } from "@modules/parser/components/report.component";
import { advanceToken, atKind, currentKind, isFieldName, isName } from "@modules/parser/components/cursor.component";

/**
 * Parses a list of type parameters such as `<T, U extends C>`.
 *
 * @param p - The parser state
 * @returns The range of `GenericParam` nodes, which is empty when there is no list
 *
 * @remarks
 * Without a leading `<` it consumes nothing and returns an empty range, so callers invoke it unconditionally.
 * A constraint after `extends` is parsed as a full type, and a missing name ends the list early.
 *
 * @example
 * ```hx
 * parseGenericParams(p); // two GenericParam nodes for <T, U extends Ord>
 * ```
 *
 * @since 1.0.0
 */

export function parseGenericParams(p: *Parser): HxRange {
    const top = scratchTop(p);
    if (acceptToken(p, TokenKind.Lt)) {
        while (true) {
            const name = expectName(p, "a type parameter name");
            if (name == NoToken) break;
            let constraint: u32 = 0;
            if (acceptToken(p, TokenKind.KwExtends)) constraint = parseType(p);
            scratchPush(p, addNode(p, NodeKind.GenericParam, name, constraint, 0));
            if (!acceptToken(p, TokenKind.Comma)) break;
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
 * @param flags - The flags of the function, which gain {@link FlagVariadic} after a trailing `...`
 *
 * @remarks
 * Functions, arrow functions, and function types share it.
 * A parameter without a type is reported without panic mode, since the intent is clear.
 *
 * @example
 * ```hx
 * parseParams(p, &fn, &flags); // two Param nodes for (a: i32, b: i32)
 * ```
 *
 * @since 1.0.0
 */

export function parseParams(p: *Parser, fn: *HxFnData, flags: *u8): void {
    void expectToken(p, TokenKind.Lparen);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rparen) && !atKind(p, TokenKind.Eof)) {
        if (atKind(p, TokenKind.Ellipsis)) {
            void advanceToken(p);
            *flags |= FlagVariadic;
            break;
        }
        const paramFlags = acceptToken(p, TokenKind.KwComptime) ? FlagComptime : 0;
        const name = expectName(p, "a parameter name");
        if (name == NoToken) break;

        let type: u32 = 0;
        if (acceptToken(p, TokenKind.Colon)) {
            type = parseType(p);
        } else {
            // the intent is clear, so report it without entering panic mode and keep parsing the function
            const word = tokenSource(p, name);
            const diag = emitf(p.diags, DiagError, p.src, tokenStart(p, name), tokenLength(p, name), `parameter \`${word}\` needs a type`);
            diagHintf(p.diags, diag, `write it as \`${word}: i32\`; every parameter is typed`);
            type = invalidNode(p);
        }
        scratchPush(p, addFlaggedNode(p, NodeKind.Param, paramFlags, name, type, 0));
        if (!acceptToken(p, TokenKind.Comma)) break;
    }
    void expectToken(p, TokenKind.Rparen);
    const params = listFinish(p, top);
    fn.paramsStart = params.start;
    fn.paramsEnd = params.end;
}

/**
 * Parses a function type such as `(a: i32) => bool`.
 *
 * @param p - The parser state
 * @returns The index of the `TypeFunction` node
 *
 * @remarks
 * The parameters and the return type go into an {@link HxFnData} record in the extra array,
 * which the node points at, and a trailing `...` sets {@link FlagVariadic} on the node.
 * The `=>` is required, so `(a: i32)` alone reports a missing arrow.
 *
 * @example
 * ```hx
 * parseFunctionType(p); // (fn-type (params (a i32)) bool) for (a: i32) => bool
 * ```
 *
 * @since 1.0.0
 */

export function parseFunctionType(p: *Parser): u32 {
    const token = p.pos;
    let fn = emptyFunctionData(NoToken, 0);
    let flags: u8 = 0;
    parseParams(p, &fn, &flags);
    void expectToken(p, TokenKind.Arrow);
    fn.returnType = parseType(p);
    return addFlaggedNode(p, NodeKind.TypeFunction, flags, token, addRecord<HxFnData>(p, fn), 0);
}

/**
 * Parses a field declaration such as `name: Type = default`.
 *
 * @param p - The parser state
 * @returns The index of the `FieldDecl` node, or 0 when the name is missing
 *
 * @remarks
 * Struct bodies and anonymous struct types share it.
 *
 * @example
 * ```hx
 * parseFieldDecl(p); // (field x f32 0) for x: f32 = 0
 * ```
 *
 * @since 1.0.0
 */

export function parseFieldDecl(p: *Parser): u32 {
    const name = expectName(p, "a field name");
    if (name == NoToken) return 0;
    let type: u32 = 0;
    if (expectToken(p, TokenKind.Colon) != NoToken) type = parseType(p);
    const value = acceptToken(p, TokenKind.Eq) ? parseExpr(p) : 0;
    return addNode(p, NodeKind.FieldDecl, name, type, value);
}

/**
 * Parses an anonymous struct type such as `struct { a: i32, b: i32 }`.
 *
 * @param p - The parser state
 * @returns The index of the `TypeStruct` node
 *
 * @remarks
 * It expects the current token to be `struct` and consumes it without checking.
 * Each field goes through {@link parseFieldDecl}, and a broken field resynchronizes at the next member.
 *
 * @example
 * ```hx
 * parseStructType(p); // (struct-type (field a i32)) for struct { a: i32 }
 * ```
 *
 * @since 1.0.0
 */

export function parseStructType(p: *Parser): u32 {
    const token = advanceToken(p);
    void expectToken(p, TokenKind.Lbrace);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const before = p.pos;
        const field = parseFieldDecl(p);
        if (field != 0) scratchPush(p, field);
        if (!p.panicking) expectMemberSeparator(p);
        recover(p, Sync.Member, before);
    }
    void expectToken(p, TokenKind.Rbrace);
    const fields = listFinish(p, top);
    return addNode(p, NodeKind.TypeStruct, token, fields.start, fields.end);
}

/**
 * Parses the type arguments after a generic name.
 *
 * @param p - The parser state
 * @param base - The node of the generic name
 * @returns The index of the `GenericInstance` node
 *
 * @remarks
 * It expects the current token to be the `<` and consumes it without checking,
 * so the caller decides first that the `<` opens type arguments.
 * The argument list must hold at least one type.
 *
 * @example
 * ```hx
 * parseGenericInstance(p, base); // (generic-of List u8) for the <u8> of List<u8>
 * ```
 *
 * @since 1.0.0
 */

export function parseGenericInstance(p: *Parser, base: u32): u32 {
    const token = advanceToken(p);
    const top = scratchTop(p);
    while (true) {
        scratchPush(p, parseType(p));
        if (!acceptToken(p, TokenKind.Comma)) break;
    }
    expectGenericClose(p);
    return addNode(p, NodeKind.GenericInstance, token, base, rangeRecord(p, listFinish(p, top)));
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
 *
 * @example
 * ```hx
 * parsePrimaryType(p); // (. Allocator Error) for Allocator.Error
 * ```
 *
 * @since 1.0.0
 */

export function parsePrimaryType(p: *Parser): u32 {
    const kind = currentKind(p);
    if (isName(kind) || kind == TokenKind.KwVoid) {
        let type = addNode(p, NodeKind.Ident, advanceToken(p), 0, 0);
        while (true) {
            if (atKind(p, TokenKind.Dot) && isFieldName(peekKind(p, 1))) {
                void advanceToken(p);
                type = addNode(p, NodeKind.FieldAccess, advanceToken(p), type, 0);
            } else if (atKind(p, TokenKind.Lt)) {
                type = parseGenericInstance(p, type);
            } else {
                return type;
            }
        }
    }
    switch (kind) {
        case TokenKind.KwExtern: {   // `extern "C" (a: i32) => void`: called with the C calling convention
            if (peekKind(p, 1) == TokenKind.String && peekKind(p, 2) == TokenKind.Lparen) {
                void advanceToken(p);
                const abi = advanceToken(p);
                const fn = parseFunctionType(p);
                unsafe {
                    const node = &p.ast.nodes![fn];
                    node.flags |= FlagExtern;
                    @ptrCast(*HxFnData, &p.ast.extra![node.a]).abiToken = abi;
                }
                return fn;
            }
        }
        case TokenKind.Lparen: {
            if (looksLikeParameterList(p)) return parseFunctionType(p);
            void advanceToken(p);
            const inner = parseType(p);
            void expectToken(p, TokenKind.Rparen);
            return inner;
        }
        case TokenKind.KwStruct: return parseStructType(p);
        case TokenKind.Builtin: return parsePrimary(p);
        default: {}
    }
    const diag = errorExpected(p, "a type");
    if (kind == TokenKind.Lbracket) attachHint(p, diag, "array and slice types put the brackets after the element: `u8[]`");
    if (kind == TokenKind.KwExtern) attachHint(p, diag, "a C function type is `extern \"C\" (a: i32) => void`");
    return invalidNode(p);
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
 *
 * @example
 * ```hx
 * parseTypeSuffixes(p, base); // (array (array f32 4) 3) for the [3][4] of f32[3][4]
 * ```
 *
 * @since 1.0.0
 */

export function parseTypeSuffixes(p: *Parser, base: u32): u32 {
    let type = base;
    let dims: u32[16] = undefined;
    let dimTokens: u32[16] = undefined;
    let dimCount: u32 = 0;
    while (true) {
        const slice = atKind(p, TokenKind.Lbracket) && peekKind(p, 1) == TokenKind.Rbracket;
        const many = atKind(p, TokenKind.Lbracket) && peekKind(p, 1) == TokenKind.Star && peekKind(p, 2) == TokenKind.Rbracket;
        const array = atKind(p, TokenKind.Lbracket) && !slice && !many;
        if (!array) {
            while (dimCount > 0) {
                dimCount -= 1;
                type = addNode(p, NodeKind.TypeArray, dimTokens[dimCount], type, dims[dimCount]);
            }
        }
        if (slice) {
            const token = advanceToken(p);
            void advanceToken(p);
            type = addNode(p, NodeKind.TypeSlice, token, type, 0);
        } else if (many) {
            const token = advanceToken(p);
            void advanceToken(p);
            void advanceToken(p);
            type = addNode(p, NodeKind.TypeManyPointer, token, type, 0);
        } else if (array) {
            const token = advanceToken(p);
            const len = parseExpr(p);
            void expectToken(p, TokenKind.Rbracket);
            if (dimCount == MaxArrayDims) {
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
 *
 * @remarks
 * The `dyn` prefix uses {@link parseTypeSuffixes} directly instead,
 * since its suffixes apply to the whole `dyn` type.
 *
 * @example
 * ```hx
 * parsePostfixType(p); // (slice u8) for u8[]
 * ```
 *
 * @since 1.0.0
 */

export function parsePostfixType(p: *Parser): u32 {
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
 *
 * @example
 * ```hx
 * parsePrefixType(p); // (optional (slice u8)) for ?u8[]
 * ```
 *
 * @since 1.0.0
 */

export function parsePrefixType(p: *Parser): u32 {
    let kind = NodeKind.None;
    switch (currentKind(p)) {
        case TokenKind.Question: kind = NodeKind.TypeOptional;
        case TokenKind.Star: kind = NodeKind.TypePointer;
        case TokenKind.KwReadonly: kind = NodeKind.TypeReadonly;
        case TokenKind.KwDyn: {   // names an interface, so suffixes apply to the `dyn`: `dyn Shape[]` is a slice of them
            const token = advanceToken(p);
            const iface = parsePrimaryType(p);
            return parseTypeSuffixes(p, addNode(p, NodeKind.TypeDyn, token, iface, 0));
        }
        default: return parsePostfixType(p);
    }
    if (!enterNesting(p)) return invalidNode(p);
    const token = advanceToken(p);
    const child = parsePrefixType(p);
    leaveNesting(p);
    return addNode(p, kind, token, child, 0);
}

/**
 * Parses a whole type, with error unions joined by `|`.
 *
 * @param p - The parser state
 * @returns The index of the type node
 *
 * @remarks
 * The `|` joins from left to right, so `A | B | C` nests as `(A | B) | C`.
 * It counts as one level of nesting,
 * so a type nested too deeply turns into an invalid node instead of overflowing the stack.
 *
 * @example
 * ```hx
 * parseType(p); // (error-union (pointer User) DbError) for *User | DbError
 * ```
 *
 * @since 1.0.0
 */

export function parseType(p: *Parser): u32 {
    if (!enterNesting(p)) return invalidNode(p);
    let type = parsePrefixType(p);
    while (atKind(p, TokenKind.Pipe)) {
        const token = advanceToken(p);
        const errorSet = parsePrefixType(p);
        type = addNode(p, NodeKind.TypeErrorUnion, token, type, errorSet);
    }
    leaveNesting(p);
    return type;
}
