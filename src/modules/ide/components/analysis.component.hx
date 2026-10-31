/**
 * Imports
 */

import { equal } from "std/text";
import { Builder } from "std/fmt";
import { ArrayList } from "std/list";
import { cAllocator } from "std/heap";
import { files } from "@models/source.model";
import { hxTypeName } from "@models/types.model";
import { hxIntern } from "@services/intern.service";
import { TypeKind } from "@constants/types.constant";
import { node, extraAt, record } from "@models/ast.model";
import { HxType } from "@models/structs/types-model.struct";
import * as os from "@modules/driver/components/os.component";
import { HxDiag } from "@models/structs/diagnostic-model.struct";
import { infoAt } from "@modules/sema/components/base.component";
import { HxSourceFile } from "@models/structs/source-model.struct";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { isKeyword } from "@modules/lexer/components/token.component";
import { DiagError, DiagWarning } from "@constants/diagnostic.constant";
import { NodeKind, NoToken, FlagExport } from "@constants/ast.constant";
import { hxsScopeFind } from "@modules/sema/components/scope.component";
import { HxDocComment } from "@modules/lexer/structs/lexer-module.struct";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { Action } from "@modules/ide/components/structs/actions-component.struct";
import { HxMember, HxAggregate, HxNodeInfo, HxSymbol } from "@structs/sema.struct";
import { Coloring } from "@modules/ide/components/structs/analysis-component.struct";
import { HxNode, HxImportData, HxContainerData } from "@models/structs/ast-model.struct";
import { Compilation } from "@modules/driver/components/structs/compile-component.struct";
import { allocCString, fromCString, strings, add } from "@modules/driver/components/os.component";
import { outOfMemory, buffer, raw, number, quoted } from "@modules/ide/components/json.component";
import { TEnumMember, TFunction, TMethod, TKeyword } from "@modules/ide/constants/analysis.constant";
import { runAction, debugAction, testAction, writeAction } from "@modules/ide/components/actions.component";
import { TInterface, TTypeParameter, TParameter, TVariable } from "@modules/ide/constants/analysis.constant";
import { SEnumMember, SStruct, STypeParameter, MDeclaration } from "@modules/ide/constants/analysis.constant";
import { TokenWriter, Pos, TokenSpan, Target } from "@modules/ide/components/structs/analysis-component.struct";
import { Nowhere, TNamespace, TType, TStruct, TEnum, TProperty } from "@modules/ide/constants/analysis.constant";
import { MReadonly, MDefaultLibrary, TComment, TString, TNumber } from "@modules/ide/constants/analysis.constant";
import { TMacro, TNone, SInterface, SFunction, SVariable, SConstant } from "@modules/ide/constants/analysis.constant";
import { HxSymLocal, HxSymMutable, HxSymParam, HxSymType, HxSymFunction, HxSymModule } from "@constants/sema.constant";
import { MDocumentation, SNamespace, SMethod, SField, SEnum, NoMember } from "@modules/ide/constants/analysis.constant";

/**
 * Reads one file of the source of a compilation.
 *
 * @param c - The compilation
 * @param file - The index of the file, which is also the index of its module
 * @returns The file, with its byte range and first line in the joined source
 *
 * @remarks
 * The read does no bounds check, so the caller passes an index below the file count of the source.
 *
 * @since 1.0.0
 */

function sourceFile(c: readonly *Compilation, file: u32): HxSourceFile {
    unsafe {
        return files(&c.src)[file];
    }
}

/**
 * Gives the whole source of a compilation, every file joined.
 *
 * @param c - The compilation
 * @returns The joined text, which every global byte offset points into
 *
 * @remarks
 * Every byte offset in the token stream and the syntax tree is global,
 * so the helpers slice this one text rather than the text of a single file.
 *
 * @since 1.0.0
 */

function sourceText(c: readonly *Compilation): string {
    unsafe {
        return c.src.text![0..c.src.len];
    }
}

/**
 * Finds the file that holds a byte.
 *
 * @param c - The compilation
 * @param at - The global byte offset
 * @returns The index of the file, or 0 when no file holds the byte
 *
 * @remarks
 * The search is linear over the files and takes the first file whose range holds the byte.
 * An offset equal to the end of a file still counts as inside it, which keeps a cursor at the very end in that file.
 *
 * @since 1.0.0
 */

function fileAt(c: readonly *Compilation, at: u32): u32 {
    for (const i of 0..c.src.fileCount) {
        const f = sourceFile(c, i);
        if (at >= f.start && at <= f.end) return i;
    }
    return 0;
}

/**
 * Counts the UTF-16 code units of UTF-8 text.
 *
 * @param bytes - The UTF-8 text
 * @returns One unit per character, and two for a character outside the BMP, which takes 4 bytes in UTF-8
 *
 * @remarks
 * LSP counts characters in UTF-16 code units, so a column has to come from this count and not from the byte length.
 * Continuation bytes add nothing, and a lead byte from 0xF0 up adds two.
 * The function does not validate the UTF-8.
 *
 * @since 1.0.0
 */

function utf16Len(bytes: readonly u8[]): u32 {
    let n: u32 = 0;
    for (const b of bytes) {
        if ((b & 0xC0) == 0x80) continue;
        n += b >= 0xF0 ? 2 : 1;
    }
    return n;
}

/**
 * Gives the global byte offset where a line of the joined source starts.
 *
 * @param c - The compilation
 * @param line - The line in the joined source
 * @returns The byte offset of its first character
 *
 * @remarks
 * The line counts across the joined source, not within one file.
 * Subtract the first line of the file to get the line that an editor shows.
 *
 * @since 1.0.0
 */

function lineStartAt(c: readonly *Compilation, line: u32): u32 {
    unsafe {
        return c.src.lineStarts![line];
    }
}

/**
 * Turns a global byte offset into a position in its file.
 *
 * @param c - The compilation
 * @param at - The global byte offset
 * @returns The position, with the line counted from the start of the file
 *
 * @remarks
 * A binary search through the table of line starts finds the last line that starts at or before the byte.
 *
 * @since 1.0.0
 */

function posOf(c: readonly *Compilation, at: u32): Pos {
    const f = sourceFile(c, fileAt(c, at));
    let lo: u32 = 0;
    let hi: u32 = c.src.lineCount;
    while (hi - lo > 1) {   // the last line starting at or before `at`
        const mid = lo + (hi - lo) / 2;
        if (lineStartAt(c, mid) <= at) lo = mid;
        else hi = mid;
    }
    const start = lineStartAt(c, lo);
    return Pos { line: lo >= f.firstLine ? lo - f.firstLine : 0, character: utf16Len(sourceText(c)[start..at]) };
}

/**
 * Turns a position in a file into a global byte offset.
 *
 * @param c - The compilation
 * @param file - The index of the file
 * @param pos - The position, in lines and UTF-16 code units
 * @returns The byte offset, which stops at the end of the line or of the file when the position is past it
 *
 * @remarks
 * A character outside the BMP counts as two units, as the protocol counts it.
 *
 * @example
 * ```hx
 * // file 0 is "let a = 1;\nlet bc = 2;\n"
 * offsetOf(c, 0, Pos { line: 1, character: 4 });  // 15, the start of bc
 * offsetOf(c, 0, Pos { line: 0, character: 99 }); // 10, the end of the first line
 * ```
 *
 * @since 1.0.0
 */

export function offsetOf(c: readonly *Compilation, file: u32, pos: Pos): u32 {
    const all = sourceText(c);
    const f = sourceFile(c, file);
    let at = f.start;
    let line: u32 = 0;
    while (line < pos.line && at < f.end) {
        if (all[at] == '\n') line++;
        at++;
    }
    let units: u32 = 0;
    while (at < f.end && all[at] != '\n' && units < pos.character) {
        units += all[at] >= 0xF0 ? 2 : 1;
        at++;
        while (at < f.end && (all[at] & 0xC0) == 0x80) at++;
    }
    return at;
}

/**
 * Appends a position to a buffer as JSON.
 *
 * @param b - The buffer to append to
 * @param p - The position to write
 *
 * @remarks
 * The function writes the LSP `Position` shape, `{"line":L,"character":C}`, with no spaces.
 * The caller converts the byte offset first, through `posOf`.
 *
 * @since 1.0.0
 */

function writePos(b: *Builder, p: Pos): void {
    raw(b, "{\"line\":");
    number(b, p.line);
    raw(b, ",\"character\":");
    number(b, p.character);
    raw(b, "}");
}

/**
 * Appends a range of bytes to a buffer as a JSON range.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param start - The global byte offset where the range starts
 * @param end - The global byte offset just past the range
 *
 * @remarks
 * Both ends go through `posOf`, so the range carries lines and UTF-16 columns relative to the file of each end.
 * The function does not check that both ends sit in the same file.
 *
 * @since 1.0.0
 */

function writeRange(b: *Builder, c: readonly *Compilation, start: u32, end: u32): void {
    raw(b, "{\"start\":");
    writePos(b, posOf(c, start));
    raw(b, ",\"end\":");
    writePos(b, posOf(c, end));
    raw(b, "}");
}

/**
 * Turns a path into a `file://` URI.
 *
 * @param path - The absolute path
 * @returns The URI, with every byte that a URI cannot hold percent-encoded in uppercase hex
 *
 * @remarks
 * Letters, digits, and `/-_.~` stay as they are.
 *
 * @example
 * ```hx
 * uriOf("/my project/a.hx"); // 'file:///my%20project/a.hx'
 * ```
 *
 * @since 1.0.0
 */

export function uriOf(path: string): string {
    let b = buffer();
    raw(&b, "file://");
    const hex = "0123456789ABCDEF";
    for (const ch, i of path) {
        const plain = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '/' ||
                      ch == '-' || ch == '_' || ch == '.' || ch == '~';
        if (plain) {
            raw(&b, path[i..i + 1]);
        } else {
            raw(&b, "%");
            raw(&b, hex[(ch >> 4) as usize..(ch >> 4) as usize + 1]);
            raw(&b, hex[(ch & 15) as usize..(ch & 15) as usize + 1]);
        }
    }
    return allocCString(`${b.text()}`);
}

/**
 * Gives the path of a file as the compiler resolved it.
 *
 * @param c - The compilation
 * @param file - The index of the file, which is also the index of its module
 * @returns The real path that the compilation recorded, or the real path of the file's own name
 *
 * @remarks
 * A module that the compilation loaded has its real path recorded already.
 * The fallback resolves the name that the source table holds, and keeps that name when it does not resolve.
 *
 * @since 1.0.0
 */

function filePath(c: readonly *Compilation, file: u32): string {
    if (file < c.realPaths.items.len) return c.realPaths.items[file];
    const path = fromCString(os.asReadonly(sourceFile(c, file).path));
    return os.realPath(path) ?? path;
}

/**
 * Gives the global byte offset where a token starts.
 *
 * @param c - The compilation
 * @param t - The index of the token
 * @returns The byte offset
 *
 * @remarks
 * The read does no bounds check, so the caller passes an index below the token count.
 *
 * @since 1.0.0
 */

function tokenStart(c: readonly *Compilation, t: u32): u32 {
    unsafe {
        return c.tokens.starts![t];
    }
}

/**
 * Gives the global byte offset just past a token.
 *
 * @param c - The compilation
 * @param t - The index of the token
 * @returns The byte offset
 *
 * @remarks
 * The token stream stores the start and the length, and this adds them.
 * The read does no bounds check.
 *
 * @since 1.0.0
 */

function tokenEnd(c: readonly *Compilation, t: u32): u32 {
    unsafe {
        return c.tokens.starts![t] + c.tokens.lens![t];
    }
}

/**
 * Gives the kind of a token.
 *
 * @param c - The compilation
 * @param t - The index of the token
 * @returns The kind, as the byte that the token stream stores
 *
 * @remarks
 * Compare the byte with a `TokenKind` through a cast, or use {@link isTokenKind}.
 *
 * @since 1.0.0
 */

function tokenKind(c: readonly *Compilation, t: u32): u8 {
    unsafe {
        return c.tokens.kinds![t];
    }
}

/**
 * Gives the source text of a token.
 *
 * @param c - The compilation
 * @param t - The index of the token
 * @returns The text
 *
 * @remarks
 * The result is a slice of the joined source, not a copy, so it lives as long as the compilation.
 *
 * @since 1.0.0
 */

function tokenText(c: readonly *Compilation, t: u32): string {
    return sourceText(c)[tokenStart(c, t)..tokenEnd(c, t)];
}

/**
 * Checks the kind of a token.
 *
 * @param c - The compilation
 * @param t - The index of the token
 * @param kind - The kind to compare with
 * @returns `true` when the token is of that kind
 *
 * @remarks
 * The function exists so that callers compare against the enum without casting it to a byte themselves.
 *
 * @since 1.0.0
 */

function isTokenKind(c: readonly *Compilation, t: u32, kind: TokenKind): bool {
    return tokenKind(c, t) == kind as u8;
}

/**
 * Reads a node of the syntax tree.
 *
 * @param c - The compilation
 * @param id - The id of the node
 * @returns The node
 *
 * @remarks
 * The function is a thin wrapper over the AST model, so the queries here read nodes through the compilation.
 *
 * @since 1.0.0
 */

function nodeOf(c: readonly *Compilation, id: u32): HxNode {
    return node(&c.ast, id);
}

/**
 * Reads one entry of the extra array of the syntax tree, which holds the lists of nodes.
 *
 * @param c - The compilation
 * @param i - The index of the entry
 * @returns The entry, usually the id of a node
 *
 * @remarks
 * A node with a list stores the start and the length of its range in this array.
 * The function is a thin wrapper over the AST model.
 *
 * @since 1.0.0
 */

function extra(c: readonly *Compilation, i: u32): u32 {
    return extraAt(&c.ast, i);
}

/**
 * Finds the tokens of a file.
 *
 * @param c - The compilation
 * @param file - The index of the file
 * @returns The span of its tokens, without the end of file token
 *
 * @remarks
 * The tokens of every file sit in one stream in file order, so the span is the run whose start lies inside the file.
 * The end of file token is left out, so a caller can treat every token in the span as text of the file.
 *
 * @since 1.0.0
 */

function fileTokens(c: readonly *Compilation, file: u32): TokenSpan {
    const f = sourceFile(c, file);
    let first: u32 = 0;
    while (first < c.tokens.len && tokenStart(c, first) < f.start) first++;
    let end = first;
    while (end < c.tokens.len && tokenStart(c, end) <= f.end && !isTokenKind(c, end, TokenKind.Eof)) end++;
    return TokenSpan { first, end };
}

/**
 * Finds the token at a byte.
 *
 * @param c - The compilation
 * @param span - The tokens to search
 * @param at - The global byte offset
 * @returns The token that covers the byte, or a name that ends at it, or `NoToken` when there is none
 *
 * @remarks
 * The fallback finds a name when the cursor sits right after it.
 *
 * @since 1.0.0
 */

function tokenAt(c: readonly *Compilation, span: TokenSpan, at: u32): u32 {
    for (const t of span.first..span.end) {
        if (at >= tokenStart(c, t) && at < tokenEnd(c, t)) return t;
    }
    for (const t of span.first..span.end) {
        if (at == tokenEnd(c, t) && (isTokenKind(c, t, TokenKind.Ident) || isTokenKind(c, t, TokenKind.Builtin))) return t;
    }
    return NoToken;
}

/**
 * Gives the FILE node of a module, whose list holds the top-level declarations.
 *
 * @param c - The compilation
 * @param m - The index of the module
 * @returns The node
 *
 * @remarks
 * The module table records the root node of each module, and this reads it through {@link nodeOf}.
 *
 * @since 1.0.0
 */

function fileNode(c: readonly *Compilation, m: u32): HxNode {
    return nodeOf(c, c.modules.items[m].root);
}

/**
 * Finds the first token of the declaration that a name token names.
 *
 * @param c - The compilation
 * @param name - The name token
 * @param first - The first token of the file, which the search does not go past
 * @returns The first of the keywords before the name, such as `export`, `extern "C"`, or `function`
 *
 * @remarks
 * The search walks back while the token before is a declaration keyword.
 * A string counts too when an `extern` sits before it, which covers `extern "C"`.
 * Doc comments are not tokens, so the result never includes them.
 *
 * @since 1.0.0
 */

function declStart(c: readonly *Compilation, name: u32, first: u32): u32 {
    let t = name;
    while (t > first) {
        const prev = t - 1;
        const k = tokenKind(c, prev);
        const lead = k == TokenKind.KwExport as u8 || k == TokenKind.KwExtern as u8 || k == TokenKind.KwFunction as u8 ||
                     k == TokenKind.KwConst as u8 || k == TokenKind.KwLet as u8 || k == TokenKind.KwStruct as u8 ||
                     k == TokenKind.KwEnum as u8 || k == TokenKind.KwUnion as u8 || k == TokenKind.KwInterface as u8 ||
                     k == TokenKind.KwError as u8 || k == TokenKind.KwType as u8 ||
                     (k == TokenKind.String as u8 && prev > first && isTokenKind(c, prev - 1, TokenKind.KwExtern));
        if (!lead) break;
        t = prev;
    }
    return t;
}

/**
 * Finds the first token of the file that holds a token.
 *
 * @param c - The compilation
 * @param t - The token
 * @returns The index of the first token of its file
 *
 * @remarks
 * The search walks back from the token until the token before starts outside its file.
 * Use it when only a token is at hand, and {@link fileTokens} when the file index is known.
 *
 * @since 1.0.0
 */

function firstTokenOfFile(c: readonly *Compilation, t: u32): u32 {
    const f = sourceFile(c, fileAt(c, tokenStart(c, t)));
    let first = t;
    while (first > 0 && tokenStart(c, first - 1) >= f.start) first--;
    return first;
}

/**
 * Finds the last token of the declaration that a name token names.
 *
 * @param c - The compilation
 * @param name - The name token
 * @param end - The end of the tokens of the file
 * @returns The `;` that ends the declaration, or the `}` that closes its body, or the last token of the file
 *
 * @remarks
 * A `;` or `{` inside parentheses or brackets does not count.
 *
 * @since 1.0.0
 */

function declEnd(c: readonly *Compilation, name: u32, end: u32): u32 {
    let depth: i32 = 0;
    let t = name;
    while (t < end) {
        if (isTokenKind(c, t, TokenKind.Lparen) || isTokenKind(c, t, TokenKind.Lbracket)) depth++;
        else if (isTokenKind(c, t, TokenKind.Rparen) || isTokenKind(c, t, TokenKind.Rbracket)) depth--;
        else if (depth == 0 && isTokenKind(c, t, TokenKind.Semicolon)) return t;
        else if (depth == 0 && isTokenKind(c, t, TokenKind.Lbrace)) {
            let braces: i32 = 0;
            while (t < end) {
                if (isTokenKind(c, t, TokenKind.Lbrace)) braces++;
                else if (isTokenKind(c, t, TokenKind.Rbrace)) {
                    braces--;
                    if (braces == 0) return t;
                }
                t++;
            }
            return end - 1;
        }
        t++;
    }
    return end - 1;
}

/**
 * Finds the keyword before the name of a describe or test.
 *
 * @param c - The compilation
 * @param t - The string token of the name
 * @param first - The first token of the file, which the search does not go past
 * @returns The nearest identifier before it, `describe` of `describe("x")` or `skip` of `test.skip("x")`
 *
 * @remarks
 * The search walks back past the `(` and stops at the nearest identifier,
 * so for a modified call such as `test.skip("x")` it returns `skip` rather than `test`.
 * The callers use the result only as the start of a range for symbols and code lenses.
 *
 * @since 1.0.0
 */

function testKeyword(c: readonly *Compilation, t: u32, first: u32): u32 {
    let k = t;
    while (k > first && !isTokenKind(c, k, TokenKind.Ident)) k--;
    return k;
}

/**
 * Gives the text of a string token without its quotes.
 *
 * @param c - The compilation
 * @param t - The string token
 * @returns The text between the quotes, with escapes as written
 *
 * @remarks
 * Escapes stay as written, so the text matches what the user typed in the source.
 * A token shorter than two bytes comes back unchanged.
 *
 * @since 1.0.0
 */

function unquoted(c: readonly *Compilation, t: u32): string {
    const s = tokenText(c, t);
    return s.len >= 2 ? s[1..s.len - 1] : s;
}

/**
 * Gives the doc comment right before a token.
 *
 * @param c - The compilation
 * @param t - The token that the comment documents
 * @returns The text of the comment, or an empty string when the token has none
 *
 * @remarks
 * The opening and closing markers, the leading spaces and star of each line, and one space after the star go away.
 * Empty lines at the start and trailing newlines and spaces are dropped.
 *
 * @since 1.0.0
 */

function docBefore(c: readonly *Compilation, t: u32): string {
    for (const i of 0..c.tokens.docsLen) {
        let doc: HxDocComment = undefined;
        unsafe {
            doc = c.tokens.docs![i];
        }
        if (doc.token != t) continue;
        const body = sourceText(c)[doc.start + 3..doc.start + doc.len - 2];
        let b = buffer();
        let start: usize = 0;
        for (const ch, j of body) {
            if (ch != '\n' && j + 1 < body.len) continue;
            const line = body[start..ch == '\n' ? j : j + 1];
            start = j + 1;
            let k: usize = 0;
            while (k < line.len && (line[k] == ' ' || line[k] == '\t')) k++;
            if (k < line.len && line[k] == '*') k++;
            if (k < line.len && line[k] == ' ') k++;
            if (b.text().len == 0 && k == line.len) continue;
            if (b.text().len > 0) raw(&b, "\n");
            raw(&b, line[k..]);
        }
        let text = b.text();
        while (text.len > 0 && (text[text.len - 1] == '\n' || text[text.len - 1] == ' ')) text = text[0..text.len - 1];
        return allocCString(`${text}`);
    }
    return "";
}

/**
 * Reads what the checker recorded for a node.
 *
 * @param c - The compilation
 * @param n - The id of the node
 * @returns The record of module 0, or `null` when the compilation was not checked or the node is out of range
 *
 * @remarks
 * Only module 0 has a record here, so the queries answer for the file that the editor opened.
 * Node 0 is the null node, so it never has a record.
 *
 * @since 1.0.0
 */

function infoOf(c: readonly *Compilation, n: u32): ?*HxNodeInfo {
    if (!c.checked || c.sema.info == null || n == 0 || n >= c.ast.nodesLen) return null;
    return infoAt(&c.sema, 0, n);
}

/**
 * Reads a symbol of the checker.
 *
 * @param c - The compilation
 * @param id - The id of the symbol
 * @returns The symbol
 *
 * @remarks
 * The read does no bounds check, so callers test the id with {@link validSymbol} first.
 *
 * @since 1.0.0
 */

function symbol(c: readonly *Compilation, id: u32): HxSymbol {
    unsafe {
        return @ptrCast(HxSymbol[*], c.sema.symbols.items)[id];
    }
}

/**
 * Checks whether an id names a symbol.
 *
 * @param c - The compilation
 * @param id - The id
 * @returns `true` for an id from 1 up to the number of symbols
 *
 * @remarks
 * Id 0 stands for no symbol, so it never counts.
 *
 * @since 1.0.0
 */

function validSymbol(c: readonly *Compilation, id: u32): bool {
    return id != 0 && id < c.sema.symbols.len;
}

/**
 * Reads a type of the checker.
 *
 * @param c - The compilation
 * @param id - The id of the type
 * @returns The type
 *
 * @remarks
 * The read does no bounds check, so callers test the id with {@link validType} first.
 *
 * @since 1.0.0
 */

function typeOf(c: readonly *Compilation, id: u32): HxType {
    unsafe {
        return c.sema.types.items![id];
    }
}

/**
 * Checks whether an id names a type.
 *
 * @param c - The compilation
 * @param id - The id
 * @returns `true` for an id from 1 up to the number of types
 *
 * @remarks
 * Id 0 stands for no type, so it never counts.
 *
 * @since 1.0.0
 */

function validType(c: readonly *Compilation, id: u32): bool {
    return id != 0 && id < c.sema.types.itemsLen;
}

/**
 * Gives the name of a type as Helix writes it.
 *
 * @param c - The compilation
 * @param id - The id of the type
 * @returns The name, cut at 255 bytes
 *
 * @remarks
 * The name comes from `hxTypeName` through a fixed 256-byte buffer, and the result is a heap copy of it.
 *
 * @since 1.0.0
 */

function typeName(c: readonly *Compilation, id: u32): string {
    let buf: u8[256] = undefined;
    hxTypeName(&c.sema.types, id, &buf, 256);
    unsafe {
        return allocCString(`${fromCString(@ptrCast(readonly u8[*], &buf))}`);
    }
}

/**
 * Finds the members of a struct, enum, union, or error set type.
 *
 * @param c - The compilation
 * @param type - The id of the type
 * @returns The aggregate that lists its members, or `null` for any other type
 *
 * @remarks
 * A nominal type stores the index of its aggregate plus one in its length, so 0 means it has none.
 * The function returns `null` for an invalid id, for a type of any other kind, and for an index out of range.
 *
 * @since 1.0.0
 */

function aggregateOf(c: readonly *Compilation, type: u32): ?HxAggregate {
    if (!validType(c, type)) return null;
    const t = typeOf(c, type);
    const nominal = t.kind == TypeKind.Struct || t.kind == TypeKind.Enum || t.kind == TypeKind.Union || t.kind == TypeKind.ErrorSet;
    if (!nominal || t.len == 0 || t.len > c.sema.aggregates.len as u64) return null;
    unsafe {
        return @ptrCast(HxAggregate[*], c.sema.aggregates.items)[t.len - 1];
    }
}

/**
 * Reads one member of an aggregate.
 *
 * @param c - The compilation
 * @param index - The index of the member in the member table of the checker
 * @returns The member
 *
 * @remarks
 * The index is global to the member table, so a caller adds the start of the aggregate's members to a local index.
 * The read does no bounds check.
 *
 * @since 1.0.0
 */

function member(c: readonly *Compilation, index: u32): HxMember {
    unsafe {
        return @ptrCast(HxMember[*], c.sema.members.items)[index];
    }
}

/**
 * Finds the member of a type that a name token names.
 *
 * @param c - The compilation
 * @param type - The id of the type, which may be one pointer to it
 * @param name - The name token
 * @returns The member with the same name, or `null` when the type has none
 *
 * @remarks
 * The function looks through one level of pointer, so a member access through `*T` finds the members of `T`.
 * The names compare as text, and a member without a valid token never matches.
 * A type without an aggregate gives `null`.
 *
 * @since 1.0.0
 */

function findMember(c: readonly *Compilation, type: u32, name: u32): ?HxMember {
    let t = type;
    if (validType(c, t) && typeOf(c, t).kind == TypeKind.Pointer) t = typeOf(c, t).child;
    const want = tokenText(c, name);
    if (const a = aggregateOf(c, t)) {
        for (const i of a.membersStart..a.membersStart + a.membersCount) {
            const m = member(c, i);
            if (m.token != NoToken && m.token < c.tokens.len && equal(tokenText(c, m.token), want)) return m;
        }
    }
    return null;
}

/**
 * Finds the symbol that a name has in the module scope of its file.
 *
 * @param c - The compilation
 * @param t - The name token
 * @returns The symbol, or 0 when the module scope has no such name
 *
 * @remarks
 * It finds what the checker did not record, such as a type in an annotation.
 *
 * @since 1.0.0
 */

function scopeSymbol(c: *Compilation, t: u32): u32 {
    if (!c.checked || c.sema.scopes == null) return 0;
    const name = tokenText(c, t);
    const id = hxIntern(&c.sema.names, name.ptr, name.len as u32);
    if (const entry = hxsScopeFind(&c.sema, fileAt(c, tokenStart(c, t)), id)) {
        if (validSymbol(c, entry.symbol)) return entry.symbol;
    }
    return 0;
}

/**
 * Per token, the node that names it, or 0.
 *
 * @since 1.0.0
 */

let tokenNodes: ArrayList<u32> = undefined;

/**
 * Per node, the call whose callee it is, or 0.
 *
 * @remarks
 * The checker records the symbol of a method on the call, so the name of the method is found through it.
 *
 * @since 1.0.0
 */

let callers: ArrayList<u32> = undefined;

/**
 * Builds the lookups that every later query uses, once per compilation.
 *
 * @param c - The compilation
 *
 * @remarks
 * It records, per token, the node that names it, and, per callee, the call around it.
 * Every query after that is a lookup.
 * The queries in this file answer what an editor asks about module 0 of the compilation, which is the file asked about,
 * and they write LSP JSON.
 *
 * @example
 * ```hx
 * buildIndex(c);
 * writeHover(&b, c, offsetOf(c, 0, pos)); // now resolves names
 * ```
 *
 * @since 1.0.0
 */

export function buildIndex(c: readonly *Compilation): void {
    tokenNodes = ArrayList<u32>.init(cAllocator());
    callers = ArrayList<u32>.init(cAllocator());
    for (const _ of 0..c.tokens.len) tokenNodes.append(0) catch outOfMemory();
    for (const _ of 0..c.ast.nodesLen) callers.append(0) catch outOfMemory();
    for (const n of 1..c.ast.nodesLen) {
        const nd = nodeOf(c, n);
        const k = nd.kind;
        if (k == NodeKind.Call && nd.a != 0 && nd.a < c.ast.nodesLen) callers.items[nd.a] = n;
        const naming = k == NodeKind.Ident || k == NodeKind.FieldAccess || k == NodeKind.OptionalField ||
                       k == NodeKind.EnumLiteral || k == NodeKind.Function || k == NodeKind.Struct || k == NodeKind.Enum ||
                       k == NodeKind.Union || k == NodeKind.Interface || k == NodeKind.ErrorSet || k == NodeKind.TypeAlias ||
                       k == NodeKind.Const || k == NodeKind.Let || k == NodeKind.Param || k == NodeKind.FieldDecl ||
                       k == NodeKind.EnumMember || k == NodeKind.UnionVariant || k == NodeKind.ErrorMember ||
                       k == NodeKind.GenericParam || k == NodeKind.FieldInit || k == NodeKind.ImportSpec ||
                       k == NodeKind.StructLiteral;
        if (naming && nd.token != NoToken && nd.token < c.tokens.len) tokenNodes.items[nd.token] = n;
    }
}

/**
 * Makes the target of a symbol.
 *
 * @param c - The compilation
 * @param sym - The symbol
 * @returns The target at its name token, or {@link Nowhere} for an invalid symbol or one without a token
 *
 * @remarks
 * A target from a symbol is never a member, so its member is {@link NoMember}.
 * Every query that jumps to a declaration goes through it, so a symbol without a token never gives a location.
 *
 * @since 1.0.0
 */

function toSymbol(c: readonly *Compilation, sym: u32): Target {
    if (!validSymbol(c, sym) || symbol(c, sym).token == NoToken) return Nowhere;
    return Target { token: symbol(c, sym).token, symbol: sym, isMember: false, member: NoMember };
}

/**
 * Finds the declaration that a name token refers to.
 *
 * @param c - The compilation
 * @param t - The name token
 * @returns The target, or {@link Nowhere} when there is none
 *
 * @remarks
 * A name with a symbol that the checker recorded goes to that symbol.
 * A field access first looks for a method through the call around it,
 * then for a field, enum member, or union variant in its own type or in the type of its base.
 * A struct literal goes to the struct that it builds.
 * An identifier without a record, such as a type in an annotation, goes through the module scope.
 * The name of a declaration refers to itself.
 *
 * @since 1.0.0
 */

function resolve(c: *Compilation, t: u32): Target {
    const n = tokenNodes.items[t];
    if (n == 0) return Nowhere;
    const k = nodeOf(c, n).kind;
    let recorded: u32 = 0;
    if (const i = infoOf(c, n)) recorded = i.symbol;
    if (validSymbol(c, recorded) && (k == NodeKind.Ident || k == NodeKind.FieldAccess || k == NodeKind.EnumLiteral ||
                                     k == NodeKind.ImportSpec)) {
        const target = toSymbol(c, recorded);
        if (target.token != NoToken) return target;
    }
    if (k == NodeKind.FieldAccess || k == NodeKind.OptionalField || k == NodeKind.EnumLiteral || k == NodeKind.FieldInit) {
        // a method: the call around it holds the symbol
        if (const ci = infoOf(c, callers.items[n])) {
            const target = toSymbol(c, ci.symbol);
            if (target.token != NoToken) return target;
        }
        // a field, an enum member, a union variant: in the expression's type, or its base's
        let candidates: u32[2] = [0, 0];
        if (const own = infoOf(c, n)) candidates[0] = own.type;
        if (k != NodeKind.EnumLiteral && k != NodeKind.FieldInit) {
            if (const base = infoOf(c, nodeOf(c, n).a)) candidates[1] = base.type;
        }
        for (const type of candidates) {
            if (const m = findMember(c, type, t)) return Target { token: m.token, symbol: 0, isMember: true, member: m };
        }
        return Nowhere;
    }
    if (k == NodeKind.StructLiteral) {   // `Point { ... }`: the struct it builds
        if (const i = infoOf(c, n)) {
            if (const a = aggregateOf(c, i.type)) {
                if (a.decl != 0 && a.decl < c.ast.nodesLen) {
                    const decl = nodeOf(c, a.decl).token;
                    return Target { token: decl, symbol: scopeSymbol(c, decl), isMember: false, member: NoMember };
                }
            }
        }
        return Nowhere;
    }
    if (k == NodeKind.Ident) return toSymbol(c, scopeSymbol(c, t));   // a type in an annotation
    return Target { token: t, symbol: validSymbol(c, recorded) ? recorded : 0, isMember: false, member: NoMember };
}

/**
 * Reads one diagnostic of a compilation.
 *
 * @param c - The compilation
 * @param i - The index of the diagnostic
 * @returns The diagnostic
 *
 * @remarks
 * The read does no bounds check, so the caller loops below the item count of the list.
 *
 * @since 1.0.0
 */

function diagnostic(c: readonly *Compilation, i: u32): HxDiag {
    unsafe {
        return c.diags.items![i];
    }
}

/**
 * Appends the diagnostics of a compilation to a buffer, grouped by file.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 *
 * @remarks
 * The array holds `{ "uri", "diagnostics" }` for every file with a diagnostic, and always for module 0.
 * A diagnostic without a location goes to module 0, as an empty range at its start.
 * The severity is 1 for an error, 2 for a warning, and 3 for anything else.
 * A hint follows the message on a line of its own, after `hint: `.
 *
 * @example
 * ```hx
 * writeDiagnostics(&b, c);
 * b.text(); // '[{"uri":"file:///p/main.hx","diagnostics":[]}]'
 * ```
 *
 * @since 1.0.0
 */

export function writeDiagnostics(b: *Builder, c: readonly *Compilation): void {
    raw(b, "[");
    for (const file of 0..c.src.fileCount) {
        let any = file == 0;
        for (const i of 0..c.diags.itemsLen) {
            const d = diagnostic(c, i);
            if (d.src != null && fileAt(c, d.start) == file) any = true;
        }
        if (!any) continue;
        if (file > 0) raw(b, ",");
        raw(b, "{\"uri\":");
        quoted(b, uriOf(filePath(c, file)));
        raw(b, ",\"diagnostics\":[");
        let first = true;
        for (const i of 0..c.diags.itemsLen) {
            const d = diagnostic(c, i);
            const located = d.src != null;
            if (located && fileAt(c, d.start) != file) continue;
            if (!located && file != 0) continue;
            if (!first) raw(b, ",");
            first = false;
            const start = located ? d.start : sourceFile(c, 0).start;
            raw(b, "{\"range\":");
            writeRange(b, c, start, start + (located ? d.len : 0));
            raw(b, ",\"severity\":");
            number(b, d.level == DiagError ? 1 : d.level == DiagWarning ? 2 : 3);
            raw(b, ",\"source\":\"helix\",\"message\":");
            let message = fromCString(d.message);
            if (const h = d.hint) message = allocCString(`${message}\nhint: ${fromCString(h)}`);
            quoted(b, message);
            raw(b, "}");
        }
        raw(b, "]}");
    }
    raw(b, "]");
}

/**
 * Checks whether a name is a built-in type.
 *
 * @param name - The name
 * @returns `true` for `void`, `bool`, `noreturn`, `usize`, `isize`, `f32`, `f64`, `string`, `Error`, `Format`,
 *   and an integer type from `i1` and `u1` up to five digits
 *
 * @remarks
 * The check is on the text alone, so a user type that shadows one of these names still counts.
 * An integer name must start with a digit from 1 to 9, so `u0` and `i08` do not count.
 *
 * @since 1.0.0
 */

function builtinType(name: string): bool {
    const fixed: string[10] = ["void", "bool", "noreturn", "usize", "isize", "f32", "f64", "string", "Error", "Format"];
    for (const f of fixed) {
        if (equal(f, name)) return true;
    }
    if (name.len < 2 || name.len > 6 || (name[0] != 'u' && name[0] != 'i') || name[1] < '1' || name[1] > '9') return false;
    for (const ch of name[1..]) {
        if (ch < '0' || ch > '9') return false;
    }
    return true;
}

/**
 * Checks whether a name starts with an uppercase ASCII letter.
 *
 * @param name - The name
 * @returns `true` when its first byte is from `A` to `Z`
 *
 * @remarks
 * The coloring treats a capitalized name as a type or an enum member when the checker recorded nothing for it.
 * Bytes outside ASCII never count as uppercase.
 *
 * @since 1.0.0
 */

function capitalized(name: string): bool {
    return name.len > 0 && name[0] >= 'A' && name[0] <= 'Z';
}

/**
 * Gives the token type that colors a type.
 *
 * @param c - The compilation
 * @param type - The id of the type
 * @returns {@link TStruct}, {@link TEnum}, {@link TInterface}, or {@link TType} for any other or an invalid type
 *
 * @remarks
 * A union colors like a struct, and an error set colors like an enum.
 * An invalid id gives {@link TType}, so a name that the checker could not resolve still colors as a type.
 *
 * @since 1.0.0
 */

function typeClass(c: readonly *Compilation, type: u32): u8 {
    if (!validType(c, type)) return TType;
    const k = typeOf(c, type).kind;
    if (k == TypeKind.Struct || k == TypeKind.Union) return TStruct;
    if (k == TypeKind.Enum || k == TypeKind.ErrorSet) return TEnum;
    if (k == TypeKind.Interface) return TInterface;
    return TType;
}

/**
 * Gives the token type that colors what a symbol names.
 *
 * @param c - The compilation
 * @param id - The id of the symbol
 * @param mods - The modifiers, which get {@link MReadonly} for a constant
 * @returns The token type of a function, type, module, parameter, or variable
 *
 * @remarks
 * The function sets {@link MReadonly} only for a variable that is not mutable,
 * and leaves the modifiers alone otherwise.
 * A type symbol takes the color of its type through {@link typeClass}.
 * The read does no bounds check, so the caller tests the id with {@link validSymbol} first.
 *
 * @since 1.0.0
 */

function symbolClass(c: readonly *Compilation, id: u32, mods: *u8): u8 {
    const s = symbol(c, id);
    if (s.kind == HxSymFunction as u8) return TFunction;
    if (s.kind == HxSymType as u8) return typeClass(c, s.type);
    if (s.kind == HxSymModule as u8) return TNamespace;
    if (s.kind == HxSymParam as u8) return TParameter;
    if ((s.flags & (HxSymMutable as u16)) == 0) *mods |= MReadonly;
    return TVariable;
}

/**
 * Sets the color of one token.
 *
 * @param col - The colors
 * @param t - The token, where `NoToken` and an index out of range do nothing
 * @param type - The token type
 * @param modifiers - The modifier bits
 *
 * @remarks
 * A later call for the same token overwrites the earlier one,
 * so the pass over containers can recolor a function as a method.
 *
 * @since 1.0.0
 */

function color(col: *Coloring, t: u32, type: u8, modifiers: u8): void {
    if (t == NoToken || t >= col.types.items.len) return;
    col.types.items[t] = type;
    col.modifiers.items[t] = modifiers;
}

/**
 * Colors every name that the syntax tree and the checker know.
 *
 * @param c - The compilation
 * @param col - The colors to fill in
 *
 * @remarks
 * A declaration colors its name with {@link MDeclaration}.
 * A field access colors as a method when it is a callee, and as an enum member when it is capitalized,
 * unless a recorded symbol says otherwise.
 * An identifier colors through its symbol, and a capitalized one without a record through the module scope.
 * A built-in type gets {@link MDefaultLibrary}, and `this` and `Self` color as keywords.
 * A function declared inside a container colors as a method.
 * Every other token keeps the color of its kind.
 *
 * @since 1.0.0
 */

function colorNames(c: *Compilation, col: *Coloring): void {
    for (const n of 1..c.ast.nodesLen) {
        const nd = nodeOf(c, n);
        const t = nd.token;
        if (t == NoToken || t >= c.tokens.len) continue;
        switch (nd.kind) {
            case NodeKind.Function: color(col, t, TFunction, MDeclaration);
            case NodeKind.Struct, NodeKind.Union: color(col, t, TStruct, MDeclaration);
            case NodeKind.Enum, NodeKind.ErrorSet: color(col, t, TEnum, MDeclaration);
            case NodeKind.Interface: color(col, t, TInterface, MDeclaration);
            case NodeKind.TypeAlias: color(col, t, TType, MDeclaration);
            case NodeKind.FieldDecl: color(col, t, TProperty, MDeclaration);
            case NodeKind.EnumMember, NodeKind.ErrorMember, NodeKind.UnionVariant: color(col, t, TEnumMember, MDeclaration);
            case NodeKind.Param: color(col, t, TParameter, MDeclaration);
            case NodeKind.GenericParam: color(col, t, TTypeParameter, MDeclaration);
            case NodeKind.Const: color(col, t, TVariable, MDeclaration | MReadonly);
            case NodeKind.Let: color(col, t, TVariable, MDeclaration);
            case NodeKind.EnumLiteral: color(col, t, TEnumMember, 0);
            case NodeKind.FieldInit: color(col, t, TProperty, 0);
            case NodeKind.StructLiteral: {
                if (const i = infoOf(c, n)) {
                    if (i.type != 0) color(col, t, typeClass(c, i.type), 0);
                }
            }
            case NodeKind.FieldAccess, NodeKind.OptionalField: {
                let type = capitalized(tokenText(c, t)) ? TEnumMember : TProperty;
                if (callers.items[n] != 0) type = TMethod;
                if (const i = infoOf(c, n)) {
                    if (validSymbol(c, i.symbol)) {
                        let mods: u8 = 0;
                        type = symbolClass(c, i.symbol, &mods);
                    }
                }
                color(col, t, type, 0);
            }
            case NodeKind.Ident: {
                const name = tokenText(c, t);
                let type = TNone;
                let mods: u8 = 0;
                if (builtinType(name)) {
                    type = TType;
                    mods = MDefaultLibrary;
                } else if (equal(name, "this") || equal(name, "Self")) {
                    type = TKeyword;
                } else if (capitalized(name)) {
                    type = TType;
                }
                let sym: u32 = 0;
                if (const i = infoOf(c, n)) sym = i.symbol;
                if (!validSymbol(c, sym) && type == TType && mods == 0) sym = scopeSymbol(c, t);
                if (validSymbol(c, sym)) type = symbolClass(c, sym, &mods);
                if (type != TNone) color(col, t, type, mods);
            }
            default: {}
        }
    }
    // methods declared in a container
    for (const n of 1..c.ast.nodesLen) {
        const k = nodeOf(c, n).kind;
        if (k != NodeKind.Struct && k != NodeKind.Union && k != NodeKind.Enum && k != NodeKind.Interface) continue;
        const data = record<HxContainerData>(&c.ast, nodeOf(c, n).a);
        for (const i of data.membersStart..data.membersEnd) {
            const m = extra(c, i);
            if (nodeOf(c, m).kind == NodeKind.Function) color(col, nodeOf(c, m).token, TMethod, MDeclaration);
        }
    }
}

/**
 * Writes one token, relative to the one before it, as the protocol encodes them.
 *
 * @param w - The writer
 * @param pos - The position of the token
 * @param length - The length in UTF-16 code units, where 0 writes nothing
 * @param type - The token type
 * @param modifiers - The modifier bits
 *
 * @remarks
 * Each token is five numbers: the line delta, the character delta on the same line or the character on a new one,
 * the length, the type, and the modifiers.
 *
 * @since 1.0.0
 */

function emitToken(w: *TokenWriter, pos: Pos, length: u32, type: u8, modifiers: u8): void {
    if (length == 0) return;
    if (w.count > 0) raw(w.b, ",");
    const dl = pos.line - w.line;
    w.b.append(`${dl},${dl == 0 ? pos.character - w.character : pos.character},${length},${type},${modifiers}`) catch outOfMemory();
    w.line = pos.line;
    w.character = pos.character;
    w.count++;
}

/**
 * Writes a range of bytes as tokens, one per line.
 *
 * @param c - The compilation
 * @param w - The writer
 * @param start - The global byte offset where the range starts
 * @param end - The global byte offset just past the range
 * @param type - The token type
 * @param modifiers - The modifier bits
 *
 * @remarks
 * Clients may not take a token that spans lines, so a block comment or a template goes out a line at a time.
 *
 * @since 1.0.0
 */

function emitSpan(c: readonly *Compilation, w: *TokenWriter, start: u32, end: u32, type: u8, modifiers: u8): void {
    const all = sourceText(c);
    let lineStart = start;
    for (const i of start..end) {
        if (all[i] != '\n') continue;
        emitToken(w, posOf(c, lineStart), utf16Len(all[lineStart..i]), type, modifiers);
        lineStart = i + 1;
    }
    emitToken(w, posOf(c, lineStart), utf16Len(all[lineStart..end]), type, modifiers);
}

/**
 * Writes the comments in the gap between two tokens.
 *
 * @param c - The compilation
 * @param w - The writer
 * @param from - The global byte offset where the gap starts
 * @param to - The global byte offset where the gap ends
 *
 * @remarks
 * Block comments nest, and a block that opens with two stars, other than the empty one, gets
 * {@link MDocumentation}.
 *
 * @since 1.0.0
 */

function emitComments(c: readonly *Compilation, w: *TokenWriter, from: u32, to: u32): void {
    const all = sourceText(c);
    let i = from;
    while (i + 1 < to) {
        if (all[i] == '/' && all[i + 1] == '/') {
            let end = i;
            while (end < to && all[end] != '\n') end++;
            emitSpan(c, w, i, end, TComment, 0);
            i = end;
        } else if (all[i] == '/' && all[i + 1] == '*') {
            const doc = i + 2 < to && all[i + 2] == '*' && !(i + 3 < to && all[i + 3] == '/');
            let depth: u32 = 0;
            let end = i;
            while (end + 1 < to) {
                if (all[end] == '/' && all[end + 1] == '*') {
                    depth++;
                    end += 2;
                } else if (all[end] == '*' && all[end + 1] == '/') {
                    depth--;
                    end += 2;
                    if (depth == 0) break;
                } else {
                    end++;
                }
            }
            emitSpan(c, w, i, end, TComment, doc ? MDocumentation : 0);
            i = end;
        } else {
            i++;
        }
    }
}

/**
 * Appends the semantic tokens of module 0 to a buffer.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 *
 * @remarks
 * Names get their color from {@link colorNames} when the file parsed.
 * Every other token gets one from its kind: numbers, strings, builtins as macros, and keywords.
 * Comments come from the gaps between tokens.
 *
 * @example
 * ```hx
 * // module 0 is "const a = 1;"
 * writeSemanticTokens(&b, c);
 * b.text(); // '{"data":[0,0,5,12,0,0,6,1,7,3,0,4,1,15,0]}'
 * ```
 *
 * @since 1.0.0
 */

export function writeSemanticTokens(b: *Builder, c: *Compilation): void {
    raw(b, "{\"data\":[");
    let col = Coloring { types: ArrayList<u8>.init(cAllocator()), modifiers: ArrayList<u8>.init(cAllocator()) };
    for (const _ of 0..c.tokens.len) {
        col.types.append(TNone) catch outOfMemory();
        col.modifiers.append(0) catch outOfMemory();
    }
    if (c.parsed) colorNames(c, &col);
    const span = fileTokens(c, 0);
    let w = TokenWriter { b, line: 0, character: 0, count: 0 };
    let previousEnd = sourceFile(c, 0).start;
    for (const t of span.first..span.end) {
        emitComments(c, &w, previousEnd, tokenStart(c, t));
        previousEnd = tokenEnd(c, t);
        const k = tokenKind(c, t);
        let type = col.types.items[t];
        if (type == TNone) {
            if (k == TokenKind.Int as u8 || k == TokenKind.Float as u8) type = TNumber;
            else if (k == TokenKind.String as u8 || k == TokenKind.Char as u8 || k == TokenKind.TemplateFull as u8 ||
                     k == TokenKind.TemplateHead as u8 || k == TokenKind.TemplateMiddle as u8 || k == TokenKind.TemplateTail as u8) type = TString;
            else if (k == TokenKind.Builtin as u8) type = TMacro;
            else if (isKeyword(@enumFromInt(TokenKind, k))) type = TKeyword;
        }
        if (type != TNone) emitSpan(c, &w, tokenStart(c, t), tokenEnd(c, t), type, col.modifiers.items[t]);
    }
    emitComments(c, &w, previousEnd, sourceFile(c, 0).end);
    raw(b, "]}");
}

/**
 * Appends the start of a DocumentSymbol to a buffer, without its children and its closing brace.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param name - The name that the outline shows
 * @param kind - The LSP symbol kind
 * @param first - The first token of the whole declaration
 * @param last - The last token of the whole declaration
 * @param nameToken - The token that the editor selects
 *
 * @remarks
 * The object stays open, so the caller appends the `children` member and the closing brace itself.
 * The range covers the whole declaration, and the selection range covers only the name token.
 *
 * @since 1.0.0
 */

function writeSymbolHead(b: *Builder, c: readonly *Compilation, name: string, kind: u32, first: u32, last: u32, nameToken: u32): void {
    raw(b, "{\"name\":");
    quoted(b, name);
    raw(b, ",\"kind\":");
    number(b, kind);
    raw(b, ",\"range\":");
    writeRange(b, c, tokenStart(c, first), tokenEnd(c, last));
    raw(b, ",\"selectionRange\":");
    writeRange(b, c, tokenStart(c, nameToken), tokenEnd(c, nameToken));
}

/**
 * Appends the outline entry of a declaration to a buffer, with its members.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param n - The node of the declaration
 * @param span - The tokens of module 0
 * @param comma - Whether a comma goes before the entry
 * @returns `false`, having written nothing, when the node is not a declaration that the outline shows
 *
 * @remarks
 * A describe lists the describes and tests inside it.
 * A struct, union, enum, or interface lists its fields, members, and methods, and an error set its members.
 *
 * @since 1.0.0
 */

function writeDecl(b: *Builder, c: readonly *Compilation, n: u32, span: TokenSpan, comma: bool): bool {
    const nd = nodeOf(c, n);
    const t = nd.token;
    if (t == NoToken || t < span.first || t >= span.end) return false;
    let kind: u32 = 0;
    switch (nd.kind) {
        case NodeKind.Function: kind = SFunction;
        case NodeKind.Struct, NodeKind.Union: kind = SStruct;
        case NodeKind.Enum, NodeKind.ErrorSet: kind = SEnum;
        case NodeKind.Interface: kind = SInterface;
        case NodeKind.TypeAlias: kind = STypeParameter;
        case NodeKind.Const: kind = SConstant;
        case NodeKind.Let: kind = SVariable;
        case NodeKind.Describe: kind = SNamespace;
        case NodeKind.Test: kind = SMethod;
        default: return false;
    }
    if (comma) raw(b, ",");
    if (nd.kind == NodeKind.Describe || nd.kind == NodeKind.Test) {
        writeSymbolHead(b, c, unquoted(c, t), kind, testKeyword(c, t, span.first), declEnd(c, t, span.end), t);
        if (nd.kind == NodeKind.Describe) {
            raw(b, ",\"children\":[");
            let any = false;
            for (const i of nd.a..nd.b) {
                if (writeDecl(b, c, extra(c, i), span, any)) any = true;
            }
            raw(b, "]");
        }
        raw(b, "}");
        return true;
    }
    writeSymbolHead(b, c, tokenText(c, t), kind, declStart(c, t, span.first), declEnd(c, t, span.end), t);
    if (nd.kind == NodeKind.Struct || nd.kind == NodeKind.Union || nd.kind == NodeKind.Enum || nd.kind == NodeKind.Interface) {
        raw(b, ",\"children\":[");
        const data = record<HxContainerData>(&c.ast, nd.a);
        let any = false;
        for (const i of data.membersStart..data.membersEnd) {
            const m = extra(c, i);
            const mt = nodeOf(c, m).token;
            if (mt == NoToken || mt < span.first || mt >= span.end) continue;
            let mk: u32 = 0;
            switch (nodeOf(c, m).kind) {
                case NodeKind.FieldDecl: mk = SField;
                case NodeKind.EnumMember, NodeKind.UnionVariant: mk = SEnumMember;
                case NodeKind.Function: mk = SMethod;
                default: continue;
            }
            if (any) raw(b, ",");
            any = true;
            writeSymbolHead(b, c, tokenText(c, mt), mk, mt, nodeOf(c, m).kind == NodeKind.Function ? declEnd(c, mt, span.end) : mt, mt);
            raw(b, "}");
        }
        raw(b, "]");
    } else if (nd.kind == NodeKind.ErrorSet) {
        raw(b, ",\"children\":[");
        for (const i of nd.a..nd.b) {
            const mt = nodeOf(c, extra(c, i)).token;
            if (i > nd.a) raw(b, ",");
            writeSymbolHead(b, c, tokenText(c, mt), SEnumMember, mt, mt, mt);
            raw(b, "}");
        }
        raw(b, "]");
    }
    raw(b, "}");
    return true;
}

/**
 * Appends the outline of module 0 to a buffer.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 *
 * @remarks
 * The array is empty when the file did not parse.
 *
 * @example
 * ```hx
 * // module 0 is "function main(): void {}"
 * writeSymbols(&b, c);
 * b.text(); // '[{"name":"main","kind":12,"range":{...},"selectionRange":{...}}]'
 * ```
 *
 * @since 1.0.0
 */

export function writeSymbols(b: *Builder, c: readonly *Compilation): void {
    raw(b, "[");
    if (c.parsed && c.modules.items.len > 0) {
        const span = fileTokens(c, 0);
        const file = fileNode(c, 0);
        let any = false;
        for (const i of file.a..file.b) {
            if (writeDecl(b, c, extra(c, i), span, any)) any = true;
        }
    }
    raw(b, "]");
}

/**
 * Appends the describes and tests of a list to a buffer, as children of the test tree.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param start - The index in the extra array where the list starts
 * @param end - The index in the extra array where the list ends
 * @param outer - The names of the describes around the list, outermost first
 * @param file - The path of the spec
 * @param span - The tokens of module 0
 *
 * @remarks
 * Each item carries its name, kind, ranges, and the action that runs it, and a describe also its children.
 *
 * @since 1.0.0
 */

function writeTestItems(b: *Builder, c: readonly *Compilation, start: u32, end: u32, outer: readonly *Strings, file: string, span: TokenSpan): void {
    raw(b, "[");
    let any = false;
    for (const i of start..end) {
        const nd = nodeOf(c, extra(c, i));
        if (nd.kind != NodeKind.Describe && nd.kind != NodeKind.Test) continue;
        if (nd.token == NoToken || nd.token < span.first || nd.token >= span.end) continue;
        const describe = nd.kind == NodeKind.Describe;
        let names = strings();
        for (const n of outer.items) add(&names, n);
        add(&names, unquoted(c, nd.token));
        if (any) raw(b, ",");
        any = true;
        raw(b, "{\"name\":");
        quoted(b, unquoted(c, nd.token));
        raw(b, describe ? ",\"kind\":\"describe\"" : ",\"kind\":\"test\"");
        raw(b, ",\"range\":");
        writeRange(b, c, tokenStart(c, testKeyword(c, nd.token, span.first)), tokenEnd(c, declEnd(c, nd.token, span.end)));
        raw(b, ",\"selectionRange\":");
        writeRange(b, c, tokenStart(c, nd.token), tokenEnd(c, nd.token));
        raw(b, ",\"action\":");
        const a = testAction(file, names.items, describe);
        writeAction(b, &a);
        if (describe) {
            raw(b, ",\"children\":");
            writeTestItems(b, c, nd.a, nd.b, &names, file, span);
        }
        raw(b, "}");
    }
    raw(b, "]");
}

/**
 * Appends the test tree of module 0 to a buffer.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param file - The path of the spec
 *
 * @remarks
 * The root carries the action that runs the whole file, and its children are the top-level describes and tests.
 * The children are empty when the file did not parse.
 *
 * @example
 * ```hx
 * writeTests(&b, c, "/p/a.spec.hx");
 * b.text(); // '{"action":{"kind":"test",...},"children":[{"name":"parser","kind":"describe",...}]}'
 * ```
 *
 * @since 1.0.0
 */

export function writeTests(b: *Builder, c: readonly *Compilation, file: string): void {
    raw(b, "{\"action\":");
    const all = testAction(file, strings().items, true);
    writeAction(b, &all);
    raw(b, ",\"children\":");
    if (c.parsed && c.modules.items.len > 0) {
        const root = fileNode(c, 0);
        let none = strings();
        writeTestItems(b, c, root.a, root.b, &none, file, fileTokens(c, 0));
    } else {
        raw(b, "[]");
    }
    raw(b, "}");
}

/**
 * Appends one code lens to a buffer, which runs an action through the `helix.action` command.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param at - The token that the lens sits on
 * @param a - The action that the lens runs
 * @param comma - Whether a comma goes before the lens
 *
 * @remarks
 * The lens covers one token, and its command carries the action as its only argument.
 * The editor extensions register `helix.action`, so the server never runs the action itself.
 *
 * @since 1.0.0
 */

function writeLens(b: *Builder, c: readonly *Compilation, at: u32, a: readonly *Action, comma: bool): void {
    if (comma) raw(b, ",");
    raw(b, "{\"range\":");
    writeRange(b, c, tokenStart(c, at), tokenEnd(c, at));
    raw(b, ",\"command\":{\"title\":");
    quoted(b, a.title);
    raw(b, ",\"command\":\"helix.action\",\"arguments\":[");
    writeAction(b, a);
    raw(b, "]}}");
}

/**
 * Appends the lenses of the describes and tests of a list to a buffer, nested ones included.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param start - The index in the extra array where the list starts
 * @param end - The index in the extra array where the list ends
 * @param outer - The names of the describes around the list, outermost first
 * @param file - The path of the spec
 * @param span - The tokens of module 0
 * @param count - The number of lenses written so far, which decides the commas and grows with each lens
 *
 * @remarks
 * The lens of each describe or test sits on its keyword, found through {@link testKeyword}.
 * A describe adds its own name to the outer names and recurses into its body,
 * so every lens runs exactly the test or describe it sits on.
 * A node whose token lies outside module 0 is skipped.
 *
 * @since 1.0.0
 */

function writeTestLenses(b: *Builder, c: readonly *Compilation, start: u32, end: u32, outer: readonly *Strings, file: string, span: TokenSpan, count: *u32): void {
    for (const i of start..end) {
        const nd = nodeOf(c, extra(c, i));
        if (nd.kind != NodeKind.Describe && nd.kind != NodeKind.Test) continue;
        if (nd.token == NoToken || nd.token < span.first || nd.token >= span.end) continue;
        let names = strings();
        for (const n of outer.items) add(&names, n);
        add(&names, unquoted(c, nd.token));
        const describe = nd.kind == NodeKind.Describe;
        const a = testAction(file, names.items, describe);
        writeLens(b, c, testKeyword(c, nd.token, span.first), &a, *count > 0);
        *count += 1;
        if (describe) writeTestLenses(b, c, nd.a, nd.b, &names, file, span, count);
    }
}

/**
 * Appends the code lenses of module 0 to a buffer.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param file - The path of the file
 *
 * @remarks
 * An `export function main` gets a run lens and a debug lens, and each describe and test gets a lens that runs it.
 *
 * @example
 * ```hx
 * // module 0 is "export function main(): void {}"
 * writeLenses(&b, c, "/p/main.hx");
 * b.text(); // '[{"range":{...},"command":{"title":"▶ Run",...}},{"range":{...},"command":{"title":"Debug",...}}]'
 * ```
 *
 * @since 1.0.0
 */

export function writeLenses(b: *Builder, c: readonly *Compilation, file: string): void {
    raw(b, "[");
    let count: u32 = 0;
    if (c.parsed && c.modules.items.len > 0) {
        const span = fileTokens(c, 0);
        const root = fileNode(c, 0);
        for (const i of root.a..root.b) {
            const nd = nodeOf(c, extra(c, i));
            if (nd.kind != NodeKind.Function || (nd.flags & FlagExport) == 0 || nd.token == NoToken) continue;
            if (!equal(tokenText(c, nd.token), "main")) continue;
            const at = declStart(c, nd.token, span.first);
            const run = runAction(file);
            const debug = debugAction(file);
            writeLens(b, c, at, &run, count > 0);
            writeLens(b, c, at, &debug, true);
            count += 2;
        }
        let none = strings();
        writeTestLenses(b, c, root.a, root.b, &none, file, span, &count);
    }
    raw(b, "]");
}

/**
 * Finds the module that an import loaded.
 *
 * @param c - The compilation
 * @param t - The path string token of the import
 * @returns The index of the module, or `null` when no import has that token or it loaded nothing
 *
 * @remarks
 * The program records the target of each import node as the module index plus one, so 0 means it loaded nothing.
 * The search is linear over every node, which is fine for a single query.
 *
 * @since 1.0.0
 */

function importedModule(c: readonly *Compilation, t: u32): ?u32 {
    if (c.program.importTargets == null) return null;
    for (const n of 1..c.ast.nodesLen) {
        if (nodeOf(c, n).kind != NodeKind.Import) continue;
        if (record<HxImportData>(&c.ast, nodeOf(c, n).a).pathToken != t) continue;
        unsafe {
            const target = c.program.importTargets![n];
            if (target != 0) return target - 1;
        }
    }
    return null;
}

/**
 * Appends the location of what a byte of module 0 refers to.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param at - The global byte offset of the cursor
 *
 * @remarks
 * The path string of an import goes to the start of the file it loaded.
 * A name goes to the name token of its declaration, through {@link resolve}.
 * Anything else writes `null`.
 *
 * @example
 * ```hx
 * writeDefinition(&b, c, offsetOf(c, 0, pos));
 * b.text(); // '{"uri":"file:///p/main.hx","range":{"start":{"line":0,"character":6},...}}'
 * ```
 *
 * @since 1.0.0
 */

export function writeDefinition(b: *Builder, c: *Compilation, at: u32): void {
    const t = tokenAt(c, fileTokens(c, 0), at);
    if (t == NoToken || !c.parsed) {
        raw(b, "null");
        return;
    }
    if (isTokenKind(c, t, TokenKind.String)) {   // an import's path: the file
        if (const m = importedModule(c, t)) {
            raw(b, "{\"uri\":");
            quoted(b, uriOf(filePath(c, m)));
            raw(b, ",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
            return;
        }
    }
    const target = resolve(c, t);
    if (target.token == NoToken || target.token >= c.tokens.len) {
        raw(b, "null");
        return;
    }
    const start = tokenStart(c, target.token);
    raw(b, "{\"uri\":");
    quoted(b, uriOf(filePath(c, fileAt(c, start))));
    raw(b, ",\"range\":");
    writeRange(b, c, start, tokenEnd(c, target.token));
    raw(b, "}");
}

/**
 * Gives the source of a declaration up to its body, on one line.
 *
 * @param c - The compilation
 * @param name - The name token of the declaration
 * @returns The text, such as `export function f(a: i32): bool` or `struct User`, with each run of whitespace
 *   turned into one space
 *
 * @remarks
 * It stops at the first `{`, `;`, `=`, `,`, or `}` outside parentheses and brackets.
 *
 * @since 1.0.0
 */

function header(c: readonly *Compilation, name: u32): string {
    const start = declStart(c, name, firstTokenOfFile(c, name));
    let depth: i32 = 0;
    let t = name;
    while (t < c.tokens.len && !isTokenKind(c, t, TokenKind.Eof)) {
        if (isTokenKind(c, t, TokenKind.Lparen) || isTokenKind(c, t, TokenKind.Lbracket)) depth++;
        else if (isTokenKind(c, t, TokenKind.Rparen) || isTokenKind(c, t, TokenKind.Rbracket)) depth--;
        else if (depth == 0 && (isTokenKind(c, t, TokenKind.Lbrace) || isTokenKind(c, t, TokenKind.Semicolon) || isTokenKind(c, t, TokenKind.Eq) ||
                                 isTokenKind(c, t, TokenKind.Comma) || isTokenKind(c, t, TokenKind.Rbrace))) break;
        t++;
    }
    const end = t > name ? tokenEnd(c, t - 1) : tokenEnd(c, name);
    let b = buffer();
    let space = false;
    const text = sourceText(c)[tokenStart(c, start)..end];
    for (const ch, i of text) {
        if (ch == '\n' || ch == ' ' || ch == '\t' || ch == '\r') {
            space = true;
            continue;
        }
        if (space && b.text().len > 0) raw(&b, " ");
        space = false;
        raw(&b, text[i..i + 1]);
    }
    return allocCString(`${b.text()}`);
}

/**
 * Builds the hover text of a name token.
 *
 * @param c - The compilation
 * @param t - The name token
 * @returns Markdown with the declaration in a `helix` code block and its doc comment below,
 *   or an empty string when there is nothing to show
 *
 * @remarks
 * A member shows its name and type.
 * A const, let, parameter, or local shows its keyword, name, and type.
 * Any other declaration shows its {@link header}.
 * An expression without a declaration shows its type.
 *
 * @since 1.0.0
 */

function hoverText(c: *Compilation, t: u32): string {
    const target = resolve(c, t);
    let code = "";
    let doc = "";
    if (target.isMember) {
        const m = target.member;
        code = m.type != 0 ? allocCString(`${tokenText(c, m.token)}: ${typeName(c, m.type)}`) : tokenText(c, m.token);
        doc = docBefore(c, m.token);
    } else if (target.token != NoToken) {
        const decl = tokenNodes.items[target.token];
        const k = decl != 0 ? nodeOf(c, decl).kind : NodeKind.None;
        const type = target.symbol != 0 ? symbol(c, target.symbol).type : 0;
        const name = tokenText(c, target.token);
        const local = target.symbol != 0 && (symbol(c, target.symbol).kind == HxSymLocal as u8 ||
                                             symbol(c, target.symbol).kind == HxSymParam as u8);
        if (k == NodeKind.Const || k == NodeKind.Let || k == NodeKind.Param) {
            const keyword = k == NodeKind.Const ? "const " : k == NodeKind.Let ? "let " : "";
            code = type != 0 ? allocCString(`${keyword}${name}: ${typeName(c, type)}`) : header(c, target.token);
        } else if (local) {
            code = type != 0 ? allocCString(`${name}: ${typeName(c, type)}`) : name;
        } else {
            code = header(c, target.token);
        }
        doc = docBefore(c, declStart(c, target.token, firstTokenOfFile(c, target.token)));
    } else if (const i = infoOf(c, tokenNodes.items[t])) {   // an expression without a declaration: its type
        if (i.type != 0) code = typeName(c, i.type);
    }
    if (code.len == 0) return "";
    if (doc.len == 0) return allocCString(`\`\`\`helix\n${code}\n\`\`\``);
    return allocCString(`\`\`\`helix\n${code}\n\`\`\`\n\n${doc}`);
}

/**
 * Appends the hover of a byte of module 0 to a buffer.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param at - The global byte offset of the cursor
 *
 * @remarks
 * Only an identifier or a keyword gets a hover, and `null` is written when there is nothing to show.
 *
 * @example
 * ```hx
 * // module 0 is "const a: i32 = 1;"
 * writeHover(&b, c, 6);
 * b.text(); // '{"contents":{"kind":"markdown","value":"```helix\nconst a: i32\n```"},"range":{...}}'
 * ```
 *
 * @since 1.0.0
 */

export function writeHover(b: *Builder, c: *Compilation, at: u32): void {
    const t = tokenAt(c, fileTokens(c, 0), at);
    if (t == NoToken || !c.parsed || !(isTokenKind(c, t, TokenKind.Ident) || isKeyword(@enumFromInt(TokenKind, tokenKind(c, t))))) {
        raw(b, "null");
        return;
    }
    const value = hoverText(c, t);
    if (value.len == 0) {
        raw(b, "null");
        return;
    }
    raw(b, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
    quoted(b, value);
    raw(b, "},\"range\":");
    writeRange(b, c, tokenStart(c, t), tokenEnd(c, t));
    raw(b, "}");
}

/**
 * Appends everything about module 0 that does not depend on a cursor, from one compilation.
 *
 * @param b - The buffer to append to
 * @param c - The compilation
 * @param file - The path of the file
 *
 * @remarks
 * The sections are separated by NUL: diagnostics, tokens, symbols, lenses, and tests, as JSON each,
 * then the real path of every file that the compilation read, one per line.
 * The server learns from the paths which changes make the summary stale.
 * NUL never occurs in JSON, so the sections split without parsing.
 *
 * @example
 * ```hx
 * writeSummary(&b, c, "/p/main.hx");
 * b.text(); // '[...]\0{"data":[...]}\0[...]\0[...]\0{"action":...}\0/p/main.hx\n'
 * ```
 *
 * @since 1.0.0
 */

export function writeSummary(b: *Builder, c: *Compilation, file: string): void {
    const nul: u8[1] = [0];
    writeDiagnostics(b, c);
    b.write(&nul) catch outOfMemory();
    writeSemanticTokens(b, c);
    b.write(&nul) catch outOfMemory();
    writeSymbols(b, c);
    b.write(&nul) catch outOfMemory();
    writeLenses(b, c, file);
    b.write(&nul) catch outOfMemory();
    writeTests(b, c, file);
    b.write(&nul) catch outOfMemory();
    for (const path of c.realPaths.items) {
        raw(b, path);
        raw(b, "\n");
    }
}
