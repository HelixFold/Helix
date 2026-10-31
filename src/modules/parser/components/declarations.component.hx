/**
 * Imports
 */

import { TokenKind } from "@modules/lexer/constants/token.constant";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { Sync, Members } from "@modules/parser/constants/parser.constant";
import { parseTestItem } from "@modules/parser/components/tests.component";
import { parseBlock } from "@modules/parser/components/statements.component";
import { parseExpr } from "@modules/parser/components/expressions.component";
import { expectName, expectSemicolon } from "@modules/parser/components/report.component";
import { HxImportData, HxFnData, HxContainerData } from "@models/structs/ast-model.struct";
import { atKind, atMethod, atTestItem } from "@modules/parser/components/cursor.component";
import { NodeKind, NoToken, FlagExport, FlagExtern, FlagNamespace } from "@constants/ast.constant";
import { reportDisallowed, expectToken, recover } from "@modules/parser/components/report.component";
import { rejectMethodKeyword, attachHint, attachHintf } from "@modules/parser/components/report.component";
import { invalidNode, listFinish, scratchPush, scratchTop } from "@modules/parser/components/tree.component";
import { errorExpected, errorToken, expectMemberSeparator } from "@modules/parser/components/report.component";
import { startsStatement, tokenSource, canStartExpression } from "@modules/parser/components/cursor.component";
import { addFlaggedNode, addNode, addRecord, emptyFunctionData } from "@modules/parser/components/tree.component";
import { currentKind, isName, peekKind, acceptToken, advanceToken } from "@modules/parser/components/cursor.component";
import { parseFieldDecl, parseGenericParams, parseParams, parseType } from "@modules/parser/components/types.component";

/**
 * Parses a `const` or `let` declaration.
 *
 * @param p - The parser state
 * @param flags - The `Flag` bits of the declaration
 * @returns The index of the `Const` or `Let` node
 *
 * @remarks
 * The type and the initializer are both optional here, and later passes decide whether a missing one is an error.
 * When the name is missing, it stops right there and leaves the rest of the line to error recovery.
 *
 * @example
 * ```hx
 * parseVarDecl(p, 0); // (const MAX usize 1024) for const MAX: usize = 1024;
 * ```
 *
 * @since 1.0.0
 */

export function parseVarDecl(p: *Parser, flags: u8): u32 {
    const kind = atKind(p, TokenKind.KwConst) ? NodeKind.Const : NodeKind.Let;
    void advanceToken(p);
    const name = expectName(p, "a variable name");
    let type: u32 = 0;
    let init: u32 = 0;
    if (name != NoToken) {
        if (acceptToken(p, TokenKind.Colon)) type = parseType(p);
        if (acceptToken(p, TokenKind.Eq)) init = parseExpr(p);
        expectSemicolon(p, "the declaration");
    }
    return addFlaggedNode(p, kind, flags, name, type, init);
}

/**
 * Parses a function declaration from its `function` keyword.
 *
 * @param p - The parser state
 * @param flags - The `Flag` bits of the declaration
 * @param abi - The ABI string token of an `extern` function, or {@link NoToken}
 * @returns The index of the `Function` node
 *
 * @remarks
 * It consumes the `function` keyword and hands the rest to {@link parseFunctionRest}.
 * Modifiers such as `export` and `extern` are read by the caller and arrive in the flags.
 *
 * @example
 * ```hx
 * parseFunction(p, 0, NoToken); // (function run (params) _ (block)) for function run() {}
 * ```
 *
 * @since 1.0.0
 */

export function parseFunction(p: *Parser, flags: u8, abi: u32): u32 {
    void advanceToken(p);
    return parseFunctionRest(p, flags, abi);
}

/**
 * Parses a function from its name on, as in `name<T>(params): ret { body }`.
 *
 * @param p - The parser state
 * @param fnFlags - The `Flag` bits of the declaration
 * @param abi - The ABI string token of an `extern` function, or {@link NoToken}
 * @returns The index of the `Function` node, or an invalid node
 *
 * @remarks
 * Methods are written this way, without `function`.
 * A function without a body ends with a `;`.
 *
 * @example
 * ```hx
 * parseFunctionRest(p, 0, NoToken); // (function name (params (this Color)) _ (block)) for name(this: Color) {}
 * ```
 *
 * @since 1.0.0
 */

export function parseFunctionRest(p: *Parser, fnFlags: u8, abi: u32): u32 {
    let flags = fnFlags;
    const firstNode = p.ast.nodesLen;
    const name = expectName(p, "a function name");
    let fn = emptyFunctionData(abi, firstNode);
    const generics = parseGenericParams(p);
    fn.genericsStart = generics.start;
    fn.genericsEnd = generics.end;
    if (!atKind(p, TokenKind.Lparen)) {
        void errorExpected(p, "`(` to start the parameter list");
        return invalidNode(p);
    }
    parseParams(p, &fn, &flags);
    if (acceptToken(p, TokenKind.Colon)) fn.returnType = parseType(p);
    if (atKind(p, TokenKind.Lbrace)) {
        fn.body = parseBlock(p);
    } else if (!acceptToken(p, TokenKind.Semicolon)) {
        const diag = errorExpected(p, "`{` to start the function body");
        if (atKind(p, TokenKind.Arrow)) attachHint(p, diag, "`=>` is for arrow functions; a `function` body is a `{ ... }` block");
    }
    return addFlaggedNode(p, NodeKind.Function, flags, name, addRecord<HxFnData>(p, fn), 0);
}

/**
 * Parses a method signature of an interface.
 *
 * @param p - The parser state
 * @returns The index of the `Function` node, or 0 after an error
 *
 * @remarks
 * An interface member is a signature only, so it ends with a `;` and takes neither a body nor type parameters.
 * A leading `function` keyword is reported and skipped through {@link rejectMethodKeyword}.
 *
 * @example
 * ```hx
 * parseInterfaceMember(p); // (function close (params (this (pointer Self)))) for close(this: *Self);
 * ```
 *
 * @since 1.0.0
 */

export function parseInterfaceMember(p: *Parser): u32 {
    rejectMethodKeyword(p);
    const name = expectName(p, "a method name");
    if (name == NoToken) return 0;
    let fn = emptyFunctionData(NoToken, 0);
    let flags: u8 = 0;
    if (!atKind(p, TokenKind.Lparen)) {
        void errorExpected(p, "`(` to start the parameter list");
        return 0;
    }
    parseParams(p, &fn, &flags);
    if (acceptToken(p, TokenKind.Colon)) fn.returnType = parseType(p);
    expectSemicolon(p, "the method signature");
    return addFlaggedNode(p, NodeKind.Function, flags, name, addRecord<HxFnData>(p, fn), 0);
}

/**
 * Parses one member of a struct, an enum, a union, or an interface.
 *
 * @param p - The parser state
 * @param kind - The kind of body being parsed
 * @returns The index of the member node, or 0 after an error
 *
 * @remarks
 * Every body except an interface also accepts methods and `const` declarations among its members.
 * A field takes a type after `:`, an enum member takes a value after `=`,
 * and a union variant takes a payload type after `:`.
 *
 * @example
 * ```hx
 * parseMember(p, Members.Enum); // (member Green 2) for Green = 2
 * ```
 *
 * @since 1.0.0
 */

export function parseMember(p: *Parser, kind: Members): u32 {
    if (kind == Members.Interface) return parseInterfaceMember(p);
    rejectMethodKeyword(p);
    if (atMethod(p)) return parseFunctionRest(p, 0, NoToken);
    if (atKind(p, TokenKind.KwConst)) return parseVarDecl(p, 0);
    let member: u32 = 0;
    if (kind == Members.Struct) {
        member = parseFieldDecl(p);
    } else {
        const name = expectName(p, kind == Members.Enum ? "an enum member" : "a union variant");
        if (name == NoToken) return 0;
        if (kind == Members.Enum) member = addNode(p, NodeKind.EnumMember, name, acceptToken(p, TokenKind.Eq) ? parseExpr(p) : 0, 0);
        else member = addNode(p, NodeKind.UnionVariant, name, acceptToken(p, TokenKind.Colon) ? parseType(p) : 0, 0);
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
 * @param flags - The `Flag` bits of the declaration
 * @returns The index of the declaration node, or an invalid node
 *
 * @remarks
 * Only an enum takes a backing type after a `:`.
 *
 * @example
 * ```hx
 * parseContainer(p, NodeKind.Enum, Members.Enum, 0); // (enum Role (member Admin)) for enum Role { Admin }
 * ```
 *
 * @since 1.0.0
 */

export function parseContainer(p: *Parser, kind: NodeKind, members: Members, flags: u8): u32 {
    const firstNode = p.ast.nodesLen;
    void advanceToken(p);
    const name = expectName(p, "a type name");
    let data = HxContainerData { genericsStart: 0, genericsEnd: 0, membersStart: 0, membersEnd: 0, backingType: 0, firstNode: firstNode };
    const generics = parseGenericParams(p);
    data.genericsStart = generics.start;
    data.genericsEnd = generics.end;
    if (members == Members.Enum && acceptToken(p, TokenKind.Colon)) data.backingType = parseType(p);
    const open = p.pos;
    if (expectToken(p, TokenKind.Lbrace) == NoToken) return invalidNode(p);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const before = p.pos;
        const member = parseMember(p, members);
        if (member != 0) scratchPush(p, member);
        recover(p, Sync.Member, before);
    }
    if (!acceptToken(p, TokenKind.Rbrace)) {
        const diag = errorToken(p, open, "this `{` is never closed");
        attachHint(p, diag, "add a matching `}`");
    }
    const list = listFinish(p, top);
    data.membersStart = list.start;
    data.membersEnd = list.end;
    return addFlaggedNode(p, kind, flags, name, addRecord<HxContainerData>(p, data), 0);
}

/**
 * Parses an `error` declaration.
 *
 * @param p - The parser state
 * @param flags - The `Flag` bits of the declaration
 * @returns The index of the `ErrorSet` node
 *
 * @remarks
 * The members are bare names separated by commas, and a trailing comma is allowed.
 * A missing member name ends the list and leaves the rest to error recovery.
 *
 * @example
 * ```hx
 * parseErrorSet(p, 0); // (error DbError NotFound Timeout) for error DbError { NotFound, Timeout }
 * ```
 *
 * @since 1.0.0
 */

export function parseErrorSet(p: *Parser, flags: u8): u32 {
    void advanceToken(p);
    const name = expectName(p, "an error set name");
    void expectToken(p, TokenKind.Lbrace);
    const top = scratchTop(p);
    while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
        const member = expectName(p, "an error name");
        if (member == NoToken) break;
        scratchPush(p, addNode(p, NodeKind.ErrorMember, member, 0, 0));
        if (!acceptToken(p, TokenKind.Comma)) break;
    }
    void expectToken(p, TokenKind.Rbrace);
    const members = listFinish(p, top);
    return addFlaggedNode(p, NodeKind.ErrorSet, flags, name, members.start, members.end);
}

/**
 * Parses a `type` declaration.
 *
 * @param p - The parser state
 * @param flags - The `Flag` bits of the declaration
 * @returns The index of the `TypeAlias` node
 *
 * @remarks
 * The type parameters go into an {@link HxContainerData} record with an empty member range,
 * and the aliased type sits in the second slot of the node.
 *
 * @example
 * ```hx
 * parseTypeAlias(p, 0); // (type Bytes (slice u8)) for type Bytes = u8[];
 * ```
 *
 * @since 1.0.0
 */

export function parseTypeAlias(p: *Parser, flags: u8): u32 {
    void advanceToken(p);
    const name = expectName(p, "a type name");
    const generics = parseGenericParams(p);
    const data = HxContainerData {
        genericsStart: generics.start, genericsEnd: generics.end, membersStart: 0, membersEnd: 0, backingType: 0, firstNode: 0,
    };
    void expectToken(p, TokenKind.Eq);
    const type = parseType(p);
    expectSemicolon(p, "the type alias");
    return addFlaggedNode(p, NodeKind.TypeAlias, flags, name, addRecord<HxContainerData>(p, data), type);
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
 *
 * @example
 * ```hx
 * parseImport(p, false); // (import "std" (a) (b as c)) for import { a, b as c } from "std";
 * ```
 *
 * @since 1.0.0
 */

export function parseImport(p: *Parser, reexport: bool): u32 {
    const token = advanceToken(p);
    let data = HxImportData { pathToken: NoToken, aliasToken: NoToken, specsStart: 0, specsEnd: 0 };
    let flags = reexport ? FlagExport : 0;
    const top = scratchTop(p);
    if (!reexport && atKind(p, TokenKind.String)) {   // `import "./x";`: loaded for what it exports to C, names nothing
        data.pathToken = advanceToken(p);
        expectSemicolon(p, "the import");
        return addFlaggedNode(p, NodeKind.Import, flags, token, addRecord<HxImportData>(p, data), 0);
    }
    if (acceptToken(p, TokenKind.Star)) {
        flags |= FlagNamespace;
        if (!reexport && expectToken(p, TokenKind.KwAs) != NoToken) data.aliasToken = expectName(p, "a namespace name");
    } else if (acceptToken(p, TokenKind.Lbrace)) {
        while (!atKind(p, TokenKind.Rbrace) && !atKind(p, TokenKind.Eof)) {
            const name = expectName(p, "an imported name");
            if (name == NoToken) break;
            const alias = acceptToken(p, TokenKind.KwAs) ? expectName(p, "an alias") : NoToken;
            scratchPush(p, addNode(p, NodeKind.ImportSpec, name, alias, 0));
            if (!acceptToken(p, TokenKind.Comma)) break;
        }
        void expectToken(p, TokenKind.Rbrace);
    } else if (isName(currentKind(p))) {
        const word = tokenSource(p, p.pos);
        const diag = errorToken(p, p.pos, "Helix has no default imports");
        attachHintf(p, diag, `import names in braces, \`import { ${word} } from ...\`, or a namespace, \`import * as ${word} from ...\``);
    } else {
        void errorExpected(p, "`{` or `*`");
    }
    const specs = listFinish(p, top);
    data.specsStart = specs.start;
    data.specsEnd = specs.end;
    if (expectToken(p, TokenKind.KwFrom) != NoToken) data.pathToken = expectToken(p, TokenKind.String);
    expectSemicolon(p, "the import");
    return addFlaggedNode(p, NodeKind.Import, flags, token, addRecord<HxImportData>(p, data), 0);
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
 *
 * @example
 * ```hx
 * parseDeclaration(p); // (const :export a _ 1) for export const a = 1;
 * ```
 *
 * @since 1.0.0
 */

export function parseDeclaration(p: *Parser): u32 {
    let flags: u8 = 0;
    let abi = NoToken;
    if (atKind(p, TokenKind.KwExport)) {
        if (peekKind(p, 1) == TokenKind.Lbrace || peekKind(p, 1) == TokenKind.Star) return parseImport(p, true);
        void advanceToken(p);
        flags |= FlagExport;
    }
    if (atKind(p, TokenKind.KwExtern)) {
        void advanceToken(p);
        flags |= FlagExtern;
        if (atKind(p, TokenKind.String)) {
            abi = advanceToken(p);
        } else {
            const diag = errorExpected(p, "an ABI string");
            attachHint(p, diag, "write `extern \"C\" function ...`");
            return 0;
        }
        if (!atKind(p, TokenKind.KwFunction) && !atKind(p, TokenKind.KwStruct) && !atKind(p, TokenKind.KwLet) && !atKind(p, TokenKind.KwConst)) {
            void errorExpected(p, "`function`, `struct`, `let` or `const` after `extern`");
            return 0;
        }
        if (atKind(p, TokenKind.KwLet) || atKind(p, TokenKind.KwConst)) {   // a C global: `extern "C" let errno_value: i32;`
            const abiText = tokenSource(p, abi);
            if (abiText.len != 3 || abiText[1] != 'C') void reportDisallowed(p, abi, "only `extern \"C\"` is supported");
            return parseVarDecl(p, flags);
        }
    }
    switch (currentKind(p)) {
        case TokenKind.KwImport: {
            if ((flags & FlagExport) != 0) {
                const diag = errorToken(p, p.pos, "`export import` is not valid");
                attachHint(p, diag, "re-export with `export { name } from \"...\";`");
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
            if (isName(peekKind(p, 1))) return parseErrorSet(p, flags);
        }
        case TokenKind.KwType: {
            if (isName(peekKind(p, 1))) return parseTypeAlias(p, flags);
        }
        case TokenKind.KwComptime: {
            if (peekKind(p, 1) == TokenKind.Lbrace) {
                const token = advanceToken(p);
                return addNode(p, NodeKind.ComptimeBlock, token, parseBlock(p), 0);
            }
        }
        case TokenKind.Ident: {
            if (flags == 0 && atTestItem(p)) return parseTestItem(p);
        }
        default: {}
    }
    const diag = errorExpected(p, "a declaration");
    if (startsStatement(currentKind(p)) || canStartExpression(currentKind(p))) {
        attachHint(p, diag, "statements belong inside a function; a file holds only declarations");
    }
    return 0;
}
