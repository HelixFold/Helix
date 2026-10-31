/**
 * Imports
 */

import { record } from "@models/ast.model";
import { NodeKind } from "@constants/ast.constant";
import { hxIntern } from "@services/intern.service";
import { HxValueFloat } from "@constants/sema.constant";
import { DiagError } from "@constants/diagnostic.constant";
import { hxVecGrowImpl } from "@components/memory.component";
import { files, hxSourceLineCol } from "@models/source.model";
import { HxSource } from "@models/structs/source-model.struct";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { HxTypes, HxType } from "@models/structs/types-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { I128Max, I128Min } from "@modules/sema/constants/base.constant";
import { HxAst, HxNode, HxTernaryData } from "@models/structs/ast-model.struct";
import { hxTypeName, hxTypeOptional, hxTypeFunctionC } from "@models/types.model";
import { hxsResolveAggregate } from "@modules/sema/components/aggregate.component";
import { emitf, hint as diagHint, hintf as diagHintf } from "@models/diagnostic.model";
import { TypeKind, Signed, Readonly, AnyError, CCall } from "@constants/types.constant";
import { hxsIfaceReadonlyOk, hxsImplOf } from "@modules/sema/components/interfaces.component";
import { HxValueInt, HxMemberError, HxValueFunction, HxValueBool, HxValueError } from "@constants/sema.constant";
import { Ctx, HxMember, HxSema, HxValue, HxNodeInfo, HxInstance, HxSymbol, HxAggregate } from "@structs/sema.struct";

/**
 * Gets the checker state that a context works on.
 *
 * @param c - The checker context
 * @returns The checker state, with its symbol, value, and aggregate tables
 *
 * @remarks
 * This file holds the basics that the rest of the checker builds on:
 * access to its tables, diagnostics, node spans, compile-time values, and the type predicates and conversions.
 * The functions with the `hxs` prefix keep C linkage from the time when the checker was written in C.
 *
 * @example
 * ```hx
 * semaOf(c).symbols.len; // the number of symbols so far
 * ```
 *
 * @since 1.0.0
 */

export function semaOf(c: readonly *Ctx): *HxSema {
    return c.sema!;
}

/**
 * Gets the syntax tree that a context checks.
 *
 * @param c - The checker context
 * @returns The syntax tree
 *
 * @remarks
 * Unwraps the tree pointer without a check, so it stops the program when the context has no tree.
 *
 * @example
 * ```hx
 * astOf(c).nodesLen; // the number of nodes in the program
 * ```
 *
 * @since 1.0.0
 */

export function astOf(c: readonly *Ctx): *HxAst {
    return c.ast!;
}

/**
 * Gets the type table of a context.
 *
 * @param c - The checker context
 * @returns The type table
 *
 * @remarks
 * Unwraps the table pointer without a check, so it stops the program when the context has no type table.
 * The table belongs to the checker state, so every context of one check sees the same type ids.
 *
 * @example
 * ```hx
 * types(c).i32; // the id of i32
 * ```
 *
 * @since 1.0.0
 */

export function types(c: readonly *Ctx): *HxTypes {
    return c.types!;
}

/**
 * Copies a node of the syntax tree.
 *
 * @param c - The checker context
 * @param id - The node index
 * @returns The node
 *
 * @remarks
 * Returns a copy rather than a pointer, so the result stays valid while the checker adds nodes.
 * It does not check the index against the length of the node table.
 *
 * @example
 * ```hx
 * nodeOf(c, node).kind; // NodeKind.Binary for a + b
 * ```
 *
 * @since 1.0.0
 */

export function nodeOf(c: readonly *Ctx, id: u32): HxNode {
    unsafe {
        return c.ast!.nodes![id];
    }
}

/**
 * Reads one entry of the extra array of the syntax tree.
 *
 * @param c - The checker context
 * @param index - The index into the extra array
 * @returns The entry, usually a node index
 *
 * @remarks
 * Nodes with a variable number of children, such as a file, keep their child indices in this array.
 * It does not check the index against the length of the array.
 *
 * @example
 * ```hx
 * const file = nodeOf(c, root);
 * extraOf(c, file.a); // the first top-level declaration
 * ```
 *
 * @since 1.0.0
 */

export function extraOf(c: readonly *Ctx, index: u32): u32 {
    unsafe {
        return c.ast!.extra![index];
    }
}

/**
 * Copies the entry of a type.
 *
 * @param c - The checker context
 * @param id - The type id
 * @returns The entry, copied, since adding types can move the table
 *
 * @remarks
 * Use it to read a type, and keep the type id rather than a pointer when the code adds types afterward.
 * It does not check the id against the length of the type table.
 *
 * @example
 * ```hx
 * typeOf(c, types(c).i32).bits; // 32
 * ```
 *
 * @since 1.0.0
 */

export function typeOf(c: readonly *Ctx, id: u32): HxType {
    unsafe {
        return c.types!.items![id];
    }
}

/**
 * Gets the kind of a type.
 *
 * @param c - The checker context
 * @param id - The type id
 * @returns The kind
 *
 * @remarks
 * A shorthand for the most common read of {@link typeOf}, which copies the whole entry to give one field.
 *
 * @example
 * ```hx
 * kindOf(c, types(c).string); // TypeKind.Slice
 * ```
 *
 * @since 1.0.0
 */

export function kindOf(c: readonly *Ctx, id: u32): TypeKind {
    return typeOf(c, id).kind;
}

/**
 * Gets a symbol.
 *
 * @param c - The checker context
 * @param id - The symbol index, where 0 is the reserved empty symbol
 * @returns A pointer to the symbol, which stays valid only until the next symbol is added
 *
 * @remarks
 * Writes through the pointer change the symbol in place.
 * Read it again after anything that may declare a symbol, since the table can move when it grows.
 *
 * @example
 * ```hx
 * symbolOf(c, sym).kind; // HxSymLocal as u8 for a local
 * ```
 *
 * @since 1.0.0
 */

export function symbolOf(c: readonly *Ctx, id: u32): *HxSymbol {
    unsafe {
        return &@ptrCast(HxSymbol[*], semaOf(c).symbols.items)[id];
    }
}

/**
 * Gets the info of a node as seen from inside a generic instance.
 *
 * @param s - The checker state
 * @param instance - The instance number, or 0 outside any instance
 * @param node - The node index
 * @returns A pointer to the info of the node
 *
 * @remarks
 * An instance keeps its own info for the nodes of its declaration,
 * so each instantiation can give the same nodes different types.
 * A node outside that range, or any node when `instance` is 0, reads the shared info table.
 *
 * @example
 * ```hx
 * infoAt(s, 0, node).type;    // the type outside any instance
 * infoAt(s, inst, node).type; // the type inside max<i32>
 * ```
 *
 * @see infoOf
 * @since 1.0.0
 */

export function infoAt(s: readonly *HxSema, instance: u32, node: u32): *HxNodeInfo {
    unsafe {
        if (instance != 0) {
            const inst = &@ptrCast(HxInstance[*], s.instances.items)[instance - 1];
            if (node >= inst.lo && node <= inst.hi) return &@ptrCast(HxNodeInfo[*], inst.info)[node - inst.lo];
        }
        return &@ptrCast(HxNodeInfo[*], s.info)[node];
    }
}

/**
 * Gets the info of a node in the instance that the context is checking.
 *
 * @param c - The checker context
 * @param node - The node index
 * @returns A pointer to the info, which stays valid only until the tables grow
 *
 * @remarks
 * Goes through {@link infoAt} with the instance of the context,
 * so code inside a generic body reads and writes the info of the instantiation that it checks.
 *
 * @example
 * ```hx
 * infoOf(c, node).type; // the type that checking gave the node
 * ```
 *
 * @see infoAt
 * @since 1.0.0
 */

export function infoOf(c: readonly *Ctx, node: u32): *HxNodeInfo {
    return infoAt(semaOf(c), c.instance, node);
}

/**
 * Gets a compile-time value.
 *
 * @param c - The checker context
 * @param index - The value index, where 0 means no value
 * @returns A pointer to the value
 *
 * @remarks
 * Index 0 means no value, so callers check the index first or go through {@link hxsValueOf}.
 * The pointer stays valid only until the next value is added, since the table can move when it grows.
 *
 * @example
 * ```hx
 * valueAt(c, infoOf(c, node).value).integer; // 3 for the literal 3
 * ```
 *
 * @since 1.0.0
 */

export function valueAt(c: readonly *Ctx, index: u32): *HxValue {
    unsafe {
        return &@ptrCast(HxValue[*], semaOf(c).values.items)[index];
    }
}

/**
 * Gets a member of an aggregate from the shared member table.
 *
 * @param c - The checker context
 * @param index - The index into the member table
 * @returns A pointer to the member
 *
 * @remarks
 * Every aggregate keeps its members in one run of this table, starting at its `membersStart`.
 * The pointer stays valid only until the next member is added, since the table can move when it grows.
 *
 * @example
 * ```hx
 * const agg = hxsAggregateOf(c, point);
 * memberAt(c, agg.membersStart).name; // the interned name of the first member
 * ```
 *
 * @since 1.0.0
 */

export function memberAt(c: readonly *Ctx, index: u32): *HxMember {
    unsafe {
        return &@ptrCast(HxMember[*], semaOf(c).members.items)[index];
    }
}

/**
 * Gets one parameter type of a function type.
 *
 * @param c - The checker context
 * @param fn - The entry of the function type
 * @param i - The index of the parameter
 * @returns The parameter type
 *
 * @remarks
 * A function type keeps its parameter types in a run of the shared parameter table, starting at its `params` field.
 * It does not check `i` against the parameter count of the function.
 *
 * @example
 * ```hx
 * // fn is (i32, bool) => void
 * paramOf(c, fn, 1); // types(c).boolType
 * ```
 *
 * @since 1.0.0
 */

export function paramOf(c: readonly *Ctx, fn: HxType, i: u64): u32 {
    unsafe {
        return c.types!.params![(fn.params as usize) + (i as usize)];
    }
}

/**
 * Gets the offset of a token in the source text.
 *
 * @param c - The checker context
 * @param token - The token index
 * @returns The offset of its first byte
 *
 * @remarks
 * The offset counts bytes from the start of the whole source, which holds every file of the program.
 *
 * @example
 * ```hx
 * tokenStart(c, nodeOf(c, node).token); // 6 for b in a + b
 * ```
 *
 * @since 1.0.0
 */

export function tokenStart(c: readonly *Ctx, token: u32): u32 {
    unsafe {
        return c.tokens!.starts![token];
    }
}

/**
 * Gets the length of a token.
 *
 * @param c - The checker context
 * @param token - The token index
 * @returns The length in bytes
 *
 * @remarks
 * The length covers every byte that the lexer read for the token, with no terminating NUL.
 *
 * @example
 * ```hx
 * tokenLen(c, nodeOf(c, node).token); // 5 for count
 * ```
 *
 * @since 1.0.0
 */

export function tokenLen(c: readonly *Ctx, token: u32): u32 {
    unsafe {
        return c.tokens!.lens![token];
    }
}

/**
 * Gets the text of a token.
 *
 * @param c - The checker context
 * @param token - The token index
 * @returns The text as a slice of the source
 *
 * @remarks
 * The slice points into the source without a copy, so it stays valid for as long as the source lives.
 *
 * @example
 * ```hx
 * tokenText(c, nodeOf(c, node).token); // 'count'
 * ```
 *
 * @since 1.0.0
 */

export function tokenText(c: readonly *Ctx, token: u32): string {
    const at = tokenStart(c, token);
    unsafe {
        return c.text![at..at + tokenLen(c, token)];
    }
}

/**
 * Gets the text of a token as a pointer and a length, for callers that use C strings.
 *
 * @param c - The checker context
 * @param token - The token index
 * @param len - Receives the length in bytes
 * @returns A pointer to the first byte, which is not NUL-terminated
 *
 * @remarks
 * Gives the same bytes as {@link tokenText} without a copy,
 * and suits callers that still pass a pointer and an `i32` length.
 *
 * @example
 * ```hx
 * let len: i32 = 0;
 * const text = hxsTokText(c, token, &len); // len is 5 for count
 * ```
 *
 * @see tokenText
 * @since 1.0.0
 */

export extern "C" function hxsTokText(c: readonly *Ctx, token: u32, len: *i32): readonly u8[*] {
    *len = tokenLen(c, token) as i32;
    unsafe {
        return @ptrFromInt(u8[*], @intFromPtr(c.text!) + (tokenStart(c, token) as usize));
    }
}

/**
 * Interns the text of a token as a name.
 *
 * @param c - The checker context
 * @param token - The token index
 * @returns The name id, equal for every token with the same text
 *
 * @remarks
 * Interns the text in the name table of the checker, so names compare as numbers afterward.
 * The first token with a new text adds an entry, and every later one gets the same id back.
 *
 * @example
 * ```hx
 * hxsTokName(c, a) == hxsTokName(c, b); // true when both tokens spell count
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsTokName(c: *Ctx, token: u32): u32 {
    unsafe {
        return hxIntern(&semaOf(c).names, @ptrFromInt(u8[*], @intFromPtr(c.text!) + (tokenStart(c, token) as usize)), tokenLen(c, token));
    }
}

/**
 * The four rotating buffers of 160 bytes that type names are written into.
 *
 * @remarks
 * Rotating lets one message name several types before the first name is overwritten.
 *
 * @since 1.0.0
 */

let nameBuffers: u8[640] = undefined;

/**
 * The number of names written so far, whose lowest two bits pick the next buffer.
 *
 * @since 1.0.0
 */

let nextBuffer: usize = 0;

/**
 * Writes the readable name of a type into one of four rotating buffers.
 *
 * @param c - The checker context
 * @param type - The type
 * @returns The NUL-terminated name, valid until four more names are made
 *
 * @remarks
 * A name longer than 159 bytes is cut short.
 *
 * @example
 * ```hx
 * hxsTypeNameText(c, types(c).string); // "string"
 * ```
 *
 * @see typeName
 * @since 1.0.0
 */

export extern "C" function hxsTypeNameText(c: readonly *Ctx, type: u32): readonly u8[*] {
    const at = (nextBuffer & 3) * 160;
    nextBuffer += 1;
    unsafe {
        const buf = @ptrFromInt(u8[*], @intFromPtr(&nameBuffers) + at);
        hxTypeName(types(c), type, buf, 160);
        return buf;
    }
}

/**
 * Gets the readable name of a type, such as `readonly u8[]`.
 *
 * @param c - The checker context
 * @param type - The type
 * @returns The name, valid until four more names are made
 *
 * @remarks
 * Use it in messages that embed a type, which may name up to four types at once.
 *
 * @example
 * ```hx
 * errorNode(c, node, `expected \`${typeName(c, to)}\``); // expected `i32`
 * ```
 *
 * @since 1.0.0
 */

export function typeName(c: readonly *Ctx, type: u32): string {
    const text = hxsTypeNameText(c, type);
    unsafe {
        let n: usize = 0;
        while (text[n] != 0) n += 1;
        return text[0..n];
    }
}

/**
 * Writes an integer in decimal into a buffer.
 *
 * @param v - The integer
 * @param bufPtr - The buffer
 * @param size - The size of the buffer in bytes
 *
 * @remarks
 * The text is NUL-terminated within `size` bytes, and digits that do not fit are dropped from the end.
 * The smallest `i128` prints correctly, since the magnitude is taken as an unsigned number.
 *
 * @example
 * ```hx
 * let buf: u8[48] = undefined;
 * hxsI128Text(-42, &buf, 48); // buf holds -42
 * ```
 *
 * @see i128Text
 * @since 1.0.0
 */

export extern "C" function hxsI128Text(v: i128, bufPtr: u8[*], size: usize): void {
    let digits: u8[48] = undefined;
    let n: usize = 0;
    let magnitude: u128 = v < 0 ? (0 as u128) -% @truncate(u128, v) : v as u128;
    while (true) {
        digits[n] = '0' + @truncate(u8, magnitude % 10);
        n += 1;
        magnitude /= 10;
        if (magnitude == 0) break;
    }
    let buf: u8[] = [];
    unsafe {
        buf = bufPtr[0..size];
    }
    let used: usize = 0;
    if (v < 0 && used + 1 < size) {
        buf[used] = '-';
        used += 1;
    }
    while (n > 0 && used + 1 < size) {
        n -= 1;
        buf[used] = digits[n];
        used += 1;
    }
    buf[used] = 0;
}

/**
 * Gets an integer as decimal text.
 *
 * @param v - The integer
 * @param buf - The buffer to write into
 * @returns The text, valid until the next call with the same buffer
 *
 * @remarks
 * Writes through {@link hxsI128Text} and then measures the text up to its NUL.
 * Forty-eight bytes hold every `i128` with its sign, so the text is never cut short.
 *
 * @example
 * ```hx
 * let buf: u8[48] = undefined;
 * i128Text(255, &buf); // '255'
 * ```
 *
 * @since 1.0.0
 */

export function i128Text(v: i128, buf: *u8[48]): string {
    hxsI128Text(v, buf, 48);
    let n: usize = 0;
    while (buf[n] != 0) n += 1;
    return buf[0..n];
}

/**
 * Reports an error at a span of the source.
 *
 * @param c - The checker context
 * @param start - The offset of the first byte of the span
 * @param len - The length of the span in bytes
 * @param message - The template that gives the message
 * @returns The index of the diagnostic, for adding a hint
 *
 * @remarks
 * Use it when the span is neither a whole node nor a single token.
 * The error counts toward the error total of the diagnostic list.
 *
 * @example
 * ```hx
 * errorSpan(c, start, 1, `unexpected \`${what}\``);
 * ```
 *
 * @since 1.0.0
 */

export function errorSpan(c: *Ctx, start: u32, len: u32, message: Format): u32 {
    return emitf(semaOf(c).diags!, DiagError, semaOf(c).src, start, len, message);
}

/**
 * Reports an error that covers a whole node, such as a full expression.
 *
 * @param c - The checker context
 * @param node - The node that the error points at
 * @param message - The template that gives the message
 * @returns The index of the diagnostic, for adding a hint
 *
 * @remarks
 * Reaches out to the operands through {@link hxNodeSpan},
 * so the error underlines `a + b` as a whole rather than the `+` alone.
 *
 * @example
 * ```hx
 * const diag = errorNode(c, node, `\`${name}\` is not a function`);
 * hint(c, diag, "call a function instead");
 * ```
 *
 * @see hxNodeSpan
 * @since 1.0.0
 */

export function errorNode(c: *Ctx, node: u32, message: Format): u32 {
    let start: u32 = 0;
    let len: u32 = 0;
    hxNodeSpan(astOf(c), node, &start, &len);
    return emitf(semaOf(c).diags!, DiagError, semaOf(c).src, start, len, message);
}

/**
 * Reports an error at one token.
 *
 * @param c - The checker context
 * @param token - The token that the error points at
 * @param message - The template that gives the message
 * @returns The index of the diagnostic, for adding a hint
 *
 * @remarks
 * Use it when the error is about a name or a keyword rather than the expression around it.
 *
 * @example
 * ```hx
 * errorToken(c, symbol.token, `unused variable \`${name}\``);
 * ```
 *
 * @since 1.0.0
 */

export function errorToken(c: *Ctx, token: u32, message: Format): u32 {
    return errorSpan(c, tokenStart(c, token), tokenLen(c, token), message);
}

/**
 * Attaches a hint to a diagnostic of the checker.
 *
 * @param c - The checker context
 * @param diag - The index that an error function returned
 * @param message - The hint
 *
 * @remarks
 * Copies the text into the arena of the diagnostic list, so the caller may pass a temporary text.
 * A second hint on the same diagnostic replaces the first.
 *
 * @example
 * ```hx
 * hint(c, diag, "declare it with `const`");
 * ```
 *
 * @see hintf
 * @since 1.0.0
 */

export function hint(c: *Ctx, diag: u32, message: string): void {
    diagHint(semaOf(c).diags!, diag, message);
}

/**
 * Attaches a hint whose text is a template to a diagnostic of the checker.
 *
 * @param c - The checker context
 * @param diag - The index that an error function returned
 * @param message - The template that gives the hint
 *
 * @remarks
 * Choose it over {@link hint} when the hint embeds a value, such as a type name.
 *
 * @example
 * ```hx
 * hintf(c, diag, `declare the type as \`?${typeName(c, to)}\``);
 * ```
 *
 * @see hint
 * @since 1.0.0
 */

export function hintf(c: *Ctx, diag: u32, message: Format): void {
    diagHintf(semaOf(c).diags!, diag, message);
}

/**
 * Reports a feature that this alpha does not support yet.
 *
 * @param c - The checker context
 * @param node - The node that uses the feature
 * @param what - The feature as a plural noun phrase, NUL-terminated
 *
 * @remarks
 * The message reads `<what> are not supported yet in this alpha`, with a hint that a later alpha plans it.
 *
 * @example
 * ```hx
 * hxsUnsupported(c, decl, "generic enums");
 * // error: generic enums are not supported yet in this alpha
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsUnsupported(c: *Ctx, node: u32, what: readonly u8[*]): void {
    let text: string = "";
    unsafe {
        let n: usize = 0;
        while (what[n] != 0) n += 1;
        text = what[0..n];
    }
    const diag = errorNode(c, node, `${text} are not supported yet in this alpha`);
    hint(c, diag, "it's planned for a later alpha");
}

/**
 * Gets the kind of a token.
 *
 * @param tokens - The tokens
 * @param i - The token index
 * @returns The kind
 *
 * @remarks
 * The token table stores each kind as a byte, so this converts it back to the enum.
 * It does not check the index against the length of the table.
 *
 * @since 1.0.0
 */

function tokenKind(tokens: readonly *HxTokens, i: u32): TokenKind {
    unsafe {
        return @enumFromInt(TokenKind, tokens.kinds![i]);
    }
}

/**
 * Finds the bracket that closes an opening one.
 *
 * @param a - The syntax tree
 * @param open - The token index of the opening `(`, `[`, or `{`
 * @returns The token index of the matching close, or `open` when there is none
 *
 * @remarks
 * Every kind of bracket counts toward the same depth, which well-formed code keeps balanced.
 *
 * @example
 * ```hx
 * // f(a, (b))
 * hxsMatchingClose(a, 1); // 7, the last )
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsMatchingClose(a: readonly *HxAst, open: u32): u32 {
    let depth: u32 = 0;
    for (const i of open..a.tokens.len) {
        const k = tokenKind(a.tokens, i);
        if (k == TokenKind.Lparen || k == TokenKind.Lbracket || k == TokenKind.Lbrace) depth += 1;
        if (k == TokenKind.Rparen || k == TokenKind.Rbracket || k == TokenKind.Rbrace) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return open;
}

/**
 * Finds the first and the last token of a node.
 *
 * @param a - The syntax tree
 * @param id - The node index
 * @param first - Receives the index of the first token
 * @param last - Receives the index of the last token
 *
 * @remarks
 * Operators, calls, indexing, field access, and the other expression forms reach out to their operands,
 * so the span covers the whole expression.
 * Other nodes span only their own token.
 *
 * @example
 * ```hx
 * // a + f(b)
 * hxsSpanTokens(a, sum, &first, &last); // first is a, last is the )
 * ```
 *
 * @see hxNodeSpan
 * @since 1.0.0
 */

export extern "C" function hxsSpanTokens(a: readonly *HxAst, id: u32, first: *u32, last: *u32): void {
    let n: HxNode = undefined;
    unsafe {
        n = a.nodes![id];
    }
    let aFirst: u32 = 0;
    let aLast: u32 = 0;
    let bFirst: u32 = 0;
    let bLast: u32 = 0;
    *first = n.token;
    *last = n.token;
    switch (n.kind) {
        case NodeKind.Binary, NodeKind.Assign, NodeKind.Cast, NodeKind.Range: {
            hxsSpanTokens(a, n.a, &aFirst, &aLast);
            hxsSpanTokens(a, n.b, &bFirst, &bLast);
            *first = aFirst;
            *last = bLast;
        }
        case NodeKind.FieldAccess, NodeKind.OptionalField, NodeKind.Unwrap, NodeKind.Increment, NodeKind.Decrement: {
            hxsSpanTokens(a, n.a, &aFirst, &aLast);
            *first = aFirst;
        }
        case NodeKind.Call, NodeKind.Index, NodeKind.Slice: {
            hxsSpanTokens(a, n.a, &aFirst, &aLast);
            *first = aFirst;
            *last = hxsMatchingClose(a, n.token);
        }
        case NodeKind.BuiltinCall: *last = hxsMatchingClose(a, n.token + 1);
        case NodeKind.Negate, NodeKind.Not, NodeKind.BitNot, NodeKind.AddressOf, NodeKind.Deref, NodeKind.Try,
             NodeKind.Discard, NodeKind.Throw, NodeKind.ComptimeExpr: {
            if (n.a != 0) {
                hxsSpanTokens(a, n.a, &aFirst, &aLast);
                *last = aLast;
            }
        }
        case NodeKind.Ternary: {
            const data = record<HxTernaryData>(a, n.b);
            hxsSpanTokens(a, n.a, &aFirst, &aLast);
            hxsSpanTokens(a, data.elseValue, &bFirst, &bLast);
            *first = aFirst;
            *last = bLast;
        }
        case NodeKind.ExprStmt: hxsSpanTokens(a, n.a, first, last);
        default: {}
    }
}

/**
 * Finds the source span that covers a whole expression.
 *
 * @param a - The syntax tree
 * @param node - The node index
 * @param start - Receives the offset of the first byte
 * @param len - Receives the length in bytes
 *
 * @remarks
 * Diagnostics and panic messages use it to point at the full expression.
 *
 * @example
 * ```hx
 * // const x = a + b;
 * hxNodeSpan(a, sum, &start, &len); // start 10, len 5
 * ```
 *
 * @see hxsSpanTokens
 * @since 1.0.0
 */

export extern "C" function hxNodeSpan(a: readonly *HxAst, node: u32, start: *u32, len: *u32): void {
    let first: u32 = 0;
    let last: u32 = 0;
    hxsSpanTokens(a, node, &first, &last);
    unsafe {
        *start = a.tokens.starts![first];
        *len = a.tokens.starts![last] + a.tokens.lens![last] - *start;
    }
}

/**
 * Builds a compile-time value with only its kind set.
 *
 * @param k - The kind, one of the `HxValue` kind constants as a byte
 * @returns The value, with every other field 0 or `null`
 *
 * @remarks
 * Callers set the one field that the kind uses, such as `integer` for an integer,
 * and pass the result to {@link hxsAddValue}.
 *
 * @example
 * ```hx
 * emptyValue(HxValueNull as u8); // the value of null
 * ```
 *
 * @since 1.0.0
 */

export function emptyValue(k: u8): HxValue {
    return HxValue { kind: k, boolean: false, integer: 0, floating: 0, bytes: null, len: 0, elems: 0, count: 0 };
}

/**
 * Appends a compile-time value to the value table.
 *
 * @param c - The checker context
 * @param v - The value
 * @returns The index of the new value, never 0
 *
 * @remarks
 * Grows the table when it is full, so pointers from {@link valueAt} taken before the call may dangle afterward.
 * Index 0 belongs to the reserved empty value, so a new value never gets it.
 *
 * @example
 * ```hx
 * infoOf(c, node).value = hxsAddValue(c, emptyValue(HxValueUndefined as u8));
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsAddValue(c: *Ctx, v: HxValue): u32 {
    const values = &semaOf(c).values;
    unsafe {
        if (values.len == values.cap) {
            hxVecGrowImpl(@ptrCast(*?u8[*], &values.items), &values.cap, values.len + 1, @sizeOf(HxValue));
        }
        @ptrCast(HxValue[*], values.items)[values.len] = v;
    }
    values.len += 1;
    return values.len - 1;
}

/**
 * Gets the compile-time value of a node.
 *
 * @param c - The checker context
 * @param node - The node index
 * @returns A pointer to the value, or `null` when the value is only known at run time
 *
 * @remarks
 * Reads the value index from the info of the node in the current instance,
 * so a node inside a generic body can have a value in one instantiation and none in another.
 *
 * @example
 * ```hx
 * hxsValueOf(c, literal).integer; // 3 for the literal 3
 * hxsValueOf(c, call);            // null for a call that runs at run time
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsValueOf(c: readonly *Ctx, node: u32): ?*HxValue {
    const index = infoOf(c, node).value;
    return index != 0 ? valueAt(c, index) : null;
}

/**
 * Adds an integer value to the value table.
 *
 * @param c - The checker context
 * @param v - The integer
 * @returns The index of the new value
 *
 * @remarks
 * Takes the value as given and does not check that it fits any type.
 * The caller checks the range with {@link hxsIntFits} where that matters.
 *
 * @example
 * ```hx
 * valueAt(c, hxsIntValue(c, 7)).integer; // 7
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIntValue(c: *Ctx, v: i128): u32 {
    let x = emptyValue(HxValueInt as u8);
    x.integer = v;
    return hxsAddValue(c, x);
}

/**
 * Adds a boolean value to the value table.
 *
 * @param c - The checker context
 * @param v - The boolean
 * @returns The index of the new value
 *
 * @remarks
 * Every call adds a new entry, so two equal booleans get two different indices.
 *
 * @example
 * ```hx
 * valueAt(c, hxsBoolValue(c, true)).boolean; // true
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsBoolValue(c: *Ctx, v: bool): u32 {
    let x = emptyValue(HxValueBool as u8);
    x.boolean = v;
    return hxsAddValue(c, x);
}

/**
 * Adds a float value to the value table.
 *
 * @param c - The checker context
 * @param v - The number
 * @returns The index of the new value
 *
 * @remarks
 * Stores every float as an `f64`, whatever the width of the type that the value belongs to.
 *
 * @example
 * ```hx
 * valueAt(c, hxsFloatValue(c, 0.5)).floating; // 0.5
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsFloatValue(c: *Ctx, v: f64): u32 {
    let x = emptyValue(HxValueFloat as u8);
    x.floating = v;
    return hxsAddValue(c, x);
}

/**
 * Adds an error value to the value table.
 *
 * @param c - The checker context
 * @param code - The error code, which numbers the error by name across the program
 * @returns The index of the new value
 *
 * @remarks
 * The code goes into the integer field of the value, since an error value carries no other data.
 *
 * @example
 * ```hx
 * valueAt(c, hxsErrorValue(c, 2)).kind; // HxValueError as u8
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsErrorValue(c: *Ctx, code: i128): u32 {
    let x = emptyValue(HxValueError as u8);
    x.integer = code;
    return hxsAddValue(c, x);
}

/**
 * Gets the smallest value of an integer type.
 *
 * @param c - The checker context
 * @param type - The integer type
 * @returns The smallest value, which is 0 for an unsigned type
 *
 * @remarks
 * Reads only the width and the sign flag of the type, so the caller passes an integer type.
 * A signed type of 128 bits or more gives {@link I128Min}.
 *
 * @example
 * ```hx
 * hxsIntMin(c, types(c).i8); // -128
 * hxsIntMin(c, types(c).u8); // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIntMin(c: readonly *Ctx, type: u32): i128 {
    const t = typeOf(c, type);
    if ((t.flags & Signed) == 0) return 0;
    if (t.bits >= 128) return I128Min;
    return -((1 as i128) << (t.bits - 1));
}

/**
 * Gets the largest value of an integer type.
 *
 * @param c - The checker context
 * @param type - The integer type
 * @returns The largest value, capped at {@link I128Max}
 *
 * @remarks
 * A `u128` beyond {@link I128Max} cannot be a compile-time value in this alpha, so its maximum is capped there.
 *
 * @example
 * ```hx
 * hxsIntMax(c, types(c).i8); // 127
 * hxsIntMax(c, types(c).u8); // 255
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIntMax(c: readonly *Ctx, type: u32): i128 {
    const t = typeOf(c, type);
    const magnitude: u16 = (t.flags & Signed) != 0 ? t.bits - 1 : t.bits;
    if (magnitude >= 127) return I128Max;   // u128 beyond i128 is not representable in the alpha
    return ((1 as i128) << magnitude) - 1;
}

/**
 * Checks whether an integer fits in an integer type.
 *
 * @param c - The checker context
 * @param type - The integer type
 * @param v - The integer
 * @returns `true` when the value lies between the smallest and the largest value of the type
 *
 * @remarks
 * The bounds come from {@link hxsIntMin} and {@link hxsIntMax},
 * so a `u128` above {@link I128Max} never fits, since no compile-time value can hold it.
 *
 * @example
 * ```hx
 * hxsIntFits(c, types(c).u8, 255); // true
 * hxsIntFits(c, types(c).u8, 256); // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIntFits(c: readonly *Ctx, type: u32, v: i128): bool {
    return v >= hxsIntMin(c, type) && v <= hxsIntMax(c, type);
}

/**
 * Wraps an integer around to the width of an integer type, as wrapping arithmetic does.
 *
 * @param c - The checker context
 * @param type - The integer type
 * @param v - The integer
 * @returns The value that the low bits of `v` mean in the type
 *
 * @remarks
 * A signed type takes the top bit as the sign, and a type of 128 bits or more leaves the value unchanged.
 *
 * @example
 * ```hx
 * hxsWrapInt(c, types(c).u8, 256); // 0
 * hxsWrapInt(c, types(c).i8, 128); // -128
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsWrapInt(c: readonly *Ctx, type: u32, v: i128): i128 {
    const t = typeOf(c, type);
    if (t.bits >= 128) return v;
    const mask: u128 = ((1 as u128) << t.bits) -% 1;
    const bits = @truncate(u128, v) & mask;
    if ((t.flags & Signed) != 0 && ((bits >> (t.bits - 1)) & 1) != 0) return @truncate(i128, bits | ~mask);
    return @truncate(i128, bits);
}

/**
 * Checks whether a type is the type of an integer or a float literal.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns `true` for the types that a literal has before it meets a concrete type
 *
 * @remarks
 * A literal keeps such a type until it meets a concrete number type, which then decides its width.
 *
 * @example
 * ```hx
 * hxsIsComptimeNumber(c, types(c).comptimeInt); // true
 * hxsIsComptimeNumber(c, types(c).i32);          // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIsComptimeNumber(c: readonly *Ctx, t: u32): bool {
    const k = kindOf(c, t);
    return k == TypeKind.ComptimeInt || k == TypeKind.ComptimeFloat;
}

/**
 * Checks whether a type is a number.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns `true` for integers, floats, and the types of number literals
 *
 * @remarks
 * It accepts both integers and floats, unlike {@link hxsIsInteger} and {@link hxsIsFloat}.
 * It rejects pointers, booleans, and enums.
 *
 * @example
 * ```hx
 * hxsIsNumeric(c, types(c).f32);       // true
 * hxsIsNumeric(c, types(c).boolType); // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIsNumeric(c: readonly *Ctx, t: u32): bool {
    const k = kindOf(c, t);
    return k == TypeKind.Int || k == TypeKind.Float || k == TypeKind.ComptimeInt || k == TypeKind.ComptimeFloat;
}

/**
 * Checks whether a type is an integer.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns `true` for integer types and the type of an integer literal
 *
 * @remarks
 * Use it where an operator takes integers only, such as a bitwise operator, which rejects floats.
 *
 * @example
 * ```hx
 * hxsIsInteger(c, types(c).comptimeInt); // true
 * hxsIsInteger(c, types(c).f64);          // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIsInteger(c: readonly *Ctx, t: u32): bool {
    const k = kindOf(c, t);
    return k == TypeKind.Int || k == TypeKind.ComptimeInt;
}

/**
 * Checks whether a type is a float.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns `true` for float types and the type of a float literal
 *
 * @remarks
 * Reads only the kind, so it covers `f32` and `f64` alike.
 *
 * @example
 * ```hx
 * hxsIsFloat(c, types(c).f64); // true
 * hxsIsFloat(c, types(c).i32); // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsIsFloat(c: readonly *Ctx, t: u32): bool {
    const k = kindOf(c, t);
    return k == TypeKind.Float || k == TypeKind.ComptimeFloat;
}

/**
 * Gets the array that a pointer type points to.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns The array type for a pointer to an array, or 0 for any other type
 *
 * @remarks
 * A pointer to an array, such as `*u8[4]`, indexes and slices like the array itself.
 *
 * @example
 * ```hx
 * hxsPointedArray(c, pointerToBytes); // u8[4] for *u8[4]
 * hxsPointedArray(c, types(c).i32);   // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsPointedArray(c: readonly *Ctx, t: u32): u32 {
    const type = typeOf(c, t);
    if (type.kind == TypeKind.Pointer && kindOf(c, type.child) == TypeKind.Array) return type.child;
    return 0;
}

/**
 * Gets the aggregate of a nominal type.
 *
 * @param c - The checker context
 * @param type - A struct, enum, union, error set, or interface type
 * @returns A pointer to its aggregate, which stays valid only until the next aggregate is declared
 *
 * @remarks
 * The aggregate index comes from the type's length field, which holds the index plus one.
 * The caller makes sure that the type is nominal, since any other type reads the wrong entry.
 *
 * @example
 * ```hx
 * hxsAggregateOf(c, point).fieldCount; // 2 for struct Point { x: i32, y: i32 }
 * ```
 *
 * @see hxsIsAggregate
 * @since 1.0.0
 */

export extern "C" function hxsAggregateOf(c: readonly *Ctx, type: u32): *HxAggregate {
    unsafe {
        return &@ptrCast(HxAggregate[*], semaOf(c).aggregates.items)[(typeOf(c, type).len as usize) - 1];
    }
}

/**
 * Checks whether a type has an aggregate with members.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns `true` for structs, enums, unions, interfaces, and declared error sets, but not for `Error`
 *
 * @remarks
 * `Error` has no aggregate, since it stands for every error of the program rather than a declared set.
 * Call it before {@link hxsAggregateOf}, which reads the wrong entry for any other type.
 *
 * @example
 * ```hx
 * hxsIsAggregate(c, point);            // true
 * hxsIsAggregate(c, types(c).anyError); // false
 * ```
 *
 * @see hxsAggregateOf
 * @since 1.0.0
 */

export extern "C" function hxsIsAggregate(c: readonly *Ctx, t: u32): bool {
    const type = typeOf(c, t);
    return switch (type.kind) {
        case TypeKind.Struct, TypeKind.Enum, TypeKind.Union, TypeKind.Interface: true;
        case TypeKind.ErrorSet: (type.flags & AnyError) == 0;
        default: false;
    };
}

/**
 * Strips the optional and error union layers off a type.
 *
 * @param c - The checker context
 * @param type - The expected type
 * @returns The innermost type, which a literal such as `.Admin` or `{ ... }` builds
 *
 * @remarks
 * Unwraps any number of layers in any order, and gives 0 when the expected type is 0.
 * Literals that infer their type from the context, such as `.Admin` and `{ ... }`, use it to find the type to build.
 *
 * @example
 * ```hx
 * // ?Role | Error
 * hxsExpectedBase(c, expected); // Role
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsExpectedBase(c: readonly *Ctx, type: u32): u32 {
    let t = type;
    while (t != 0 && (kindOf(c, t) == TypeKind.Optional || kindOf(c, t) == TypeKind.ErrorUnion)) t = typeOf(c, t).child;
    return t;
}

/**
 * Checks whether every error of one set is also in another.
 *
 * @param c - The checker context
 * @param a - The error set that must fit
 * @param b - The error set that must hold it
 * @returns `true` when every error of `a` is in `b`
 *
 * @remarks
 * Every set fits in `Error`, and `Error` fits only in itself.
 * Errors match by code, which numbers them by name across the program.
 *
 * @example
 * ```hx
 * // error ReadError { NotFound }   error IoError { NotFound, Denied }
 * hxsSetSubset(c, readError, ioError); // true
 * hxsSetSubset(c, ioError, readError); // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsSetSubset(c: *Ctx, a: u32, b: u32): bool {
    if (a == b || (typeOf(c, b).flags & AnyError) != 0) return true;
    if ((typeOf(c, a).flags & AnyError) != 0) return false;
    hxsResolveAggregate(c, a);
    hxsResolveAggregate(c, b);
    const sa = hxsAggregateOf(c, a);
    const sb = hxsAggregateOf(c, b);
    for (const i of 0..sa.membersCount) {
        const m = memberAt(c, sa.membersStart + i);
        if (m.kind != HxMemberError as u8) continue;
        let found = false;
        for (const j of 0..sb.membersCount) {
            const o = memberAt(c, sb.membersStart + j);
            if (o.kind == HxMemberError as u8 && o.value == m.value) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/**
 * Checks whether a value converts to another type implicitly, without losing information.
 *
 * @param c - The checker context
 * @param from - The type of the value
 * @param to - The type it converts to
 * @returns `true` when the conversion is allowed
 *
 * @remarks
 * The allowed conversions are:
 * - **Wrapping** - a value or `null` into an optional, and a value or an error into an error union
 * - **Widening** - an integer to a wider one that holds every value, and a float to a wider float
 * - **Error sets** - a set into one that holds all of its errors
 * - **Readonly** - a pointer, a many-pointer, or a slice into its readonly form
 * - **Arrays** - `&array` into a many-pointer or a slice of its elements, and `*T` into `T[*]`
 * - **Interfaces** - a pointer to a type that implements an interface into a `dyn` of it
 * - **Strings** - a string literal into `readonly u8[]`, `readonly u8[*]`, or `Format`
 * - **Functions** - a function type into the same signature with the other calling convention
 *
 * Type 0, `noreturn`, and `undefined` convert to anything, so one error does not cause more.
 * The conversions of number literals happen in {@link hxsCoerce} instead.
 *
 * @example
 * ```hx
 * hxsImplicitOk(c, types(c).u8, types(c).i16); // true
 * hxsImplicitOk(c, types(c).i16, types(c).u8); // false
 * ```
 *
 * @see hxsCoerce
 * @since 1.0.0
 */

export extern "C" function hxsImplicitOk(c: *Ctx, from: u32, to: u32): bool {
    if (from == to || from == 0 || to == 0) return true;
    const f = typeOf(c, from);
    const t = typeOf(c, to);
    const tys = types(c);
    if (f.kind == TypeKind.Noreturn || f.kind == TypeKind.Undefined) return true;
    if (t.kind == TypeKind.Optional) {
        if (f.kind == TypeKind.Null) return true;
        if (f.kind == TypeKind.Optional) return f.child == t.child;
        return hxsImplicitOk(c, from, t.child);
    }
    if (t.kind == TypeKind.ErrorUnion) {
        if (f.kind == TypeKind.ErrorSet) return hxsSetSubset(c, from, @truncate(u32, t.len));
        if (f.kind == TypeKind.ErrorUnion) return f.child == t.child && hxsSetSubset(c, @truncate(u32, f.len), @truncate(u32, t.len));
        return hxsImplicitOk(c, from, t.child);
    }
    if (f.kind == TypeKind.ErrorSet && t.kind == TypeKind.ErrorSet) return hxsSetSubset(c, from, to);
    if (f.kind == TypeKind.Int && t.kind == TypeKind.Int) {
        const fromSigned = (f.flags & Signed) != 0;
        const toSigned = (t.flags & Signed) != 0;
        if (fromSigned == toSigned) return t.bits >= f.bits;
        return !fromSigned && toSigned && t.bits > f.bits;
    }
    if (f.kind == TypeKind.Float && t.kind == TypeKind.Float) return t.bits >= f.bits;

    // a Helix function and a C function pointer with the same signature (coerce checks the calling convention)
    if (f.kind == TypeKind.Function && t.kind == TypeKind.Function && (f.flags & CCall) != (t.flags & CCall)) {
        return hxTypeFunctionC(tys, from, (t.flags & CCall) != 0) == to;
    }
    if (f.kind == TypeKind.StringLiteral) {
        if (t.kind == TypeKind.Format) return true;   // a template without substitutions
        return (t.kind == TypeKind.Slice || t.kind == TypeKind.ManyPointer) && t.child == tys.u8 && (t.flags & Readonly) != 0;
    }
    // `*File` -> `dyn Writer` when `File` implements `Writer`; a readonly pointer only if no method changes it
    if (t.kind == TypeKind.Dyn) {
        if (f.kind != TypeKind.Pointer || !hxsIsAggregate(c, f.child)) return false;
        if ((f.flags & Readonly) != 0 && !hxsIfaceReadonlyOk(c, t.child)) return false;
        return hxsImplOf(c, f.child, t.child, 0xFFFF_FFFF, c.coerceSite) != 0;
    }
    const pointerLike = f.kind == TypeKind.Pointer || f.kind == TypeKind.ManyPointer || f.kind == TypeKind.Slice;
    if (pointerLike && f.kind == t.kind && f.child == t.child) return (t.flags & Readonly) != 0;

    // for C: `&x` and `&array` are many-pointers to the same address (`*T` -> `T[*]`, `*T[N]` -> `T[*]`)
    if (f.kind == TypeKind.Pointer && t.kind == TypeKind.ManyPointer) {
        if ((f.flags & Readonly) != 0 && (t.flags & Readonly) == 0) return false;
        const items = hxsPointedArray(c, from);
        return f.child == t.child || (items != 0 && typeOf(c, items).child == t.child);
    }
    // `&array` coerces to a slice of the whole array
    const array = hxsPointedArray(c, from);
    if (array != 0 && t.kind == TypeKind.Slice && typeOf(c, array).child == t.child) {
        return (f.flags & Readonly) == 0 || (t.flags & Readonly) != 0;
    }
    return false;
}

/**
 * Finds where a struct, enum, or union is declared, to tell apart two types with one name.
 *
 * @param c - The checker context
 * @param type - The type
 * @returns The folder that hpm installed its package in, such as `http@2.3.0+7a5700fd`, else the path of its file,
 * or an empty string for any other kind of type
 *
 * @remarks
 * Messages use it when two types print the same name, so the reader can tell where each one comes from.
 * A path inside `/helix-modules/.hpm/` shortens to the folder of its package.
 *
 * @since 1.0.0
 */

function declaredIn(c: *Ctx, type: u32): string {
    const k = typeOf(c, type).kind;
    if (k != TypeKind.Struct && k != TypeKind.Enum && k != TypeKind.Union) return "";
    let start: u32 = 0;
    let len: u32 = 0;
    hxNodeSpan(astOf(c), hxsAggregateOf(c, type).decl, &start, &len);
    const src: readonly *HxSource = semaOf(c).src!;
    let path = "";
    unsafe {
        const p = files(src)[hxSourceLineCol(src, start).file].path;
        let n: usize = 0;
        while (p[n] != 0) n += 1;
        path = p[0..n];
    }
    const marker = "/helix-modules/.hpm/";
    for (const i of 0..path.len) {
        if (i + marker.len > path.len) break;
        if (!sameText(path[i..i + marker.len], marker)) continue;
        let end = i + marker.len;
        while (end < path.len && path[end] != '/') end += 1;
        return path[i + marker.len..end];
    }
    return path;
}

/**
 * Checks whether two texts are equal.
 *
 * @param a - The first text
 * @param b - The second text
 * @returns `true` when both have the same bytes
 *
 * @remarks
 * Compares byte by byte after the lengths match, so it is exact and treats letters of different case as different.
 *
 * @since 1.0.0
 */

function sameText(a: string, b: string): bool {
    if (a.len != b.len) return false;
    for (const x, i of a) {
        if (x != b[i]) return false;
    }
    return true;
}

/**
 * Reports that a value of one type was found where another type was expected, with a hint for the usual fix.
 *
 * @param c - The checker context
 * @param node - The node of the value
 * @param from - The type of the value
 * @param to - The expected type
 *
 * @remarks
 * Two different types with the same name, usually from two copies of one package,
 * get a message that names where each one comes from.
 * The hint then depends on the pair of types, for example:
 * - an error union where its payload was expected suggests `try` or `catch`
 * - an optional where a `bool` was expected explains that Helix has no truthiness
 * - `null` where a type that is not optional was expected suggests declaring the type as optional
 * - two different number types suggest an explicit `as`
 * - a value where a `dyn` was expected tells what keeps it from converting
 *
 * @example
 * ```hx
 * hxsMismatch(c, node, optionalInt, types(c).i32);
 * // error: expected `i32`, found `?i32`
 * // hint: this may be null; use `x ?? fallback`, `x!`, or check `x != null` first
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsMismatch(c: *Ctx, node: u32, from: u32, to: u32): void {
    const toWhere = declaredIn(c, to);
    const fromWhere = declaredIn(c, from);
    if (toWhere.len > 0 && fromWhere.len > 0 && sameText(typeName(c, to), typeName(c, from))) {
        // the same name from two places: usually two copies of one package
        const name = typeName(c, to);
        const diag = errorNode(c, node, `expected \`${name}\` from ${toWhere}, found \`${name}\` from ${fromWhere}`);
        hint(c, diag, "two different types with one name: two copies of a package? `hpm why <package>` shows who brings each; a package whose API uses another's types should list it in peerDependencies");
        return;
    }
    const diag = errorNode(c, node, `expected \`${typeName(c, to)}\`, found \`${typeName(c, from)}\``);
    const f = typeOf(c, from);
    const t = typeOf(c, to);
    if (f.kind == TypeKind.ErrorUnion && (f.child == to || t.kind != TypeKind.ErrorUnion)) {
        hint(c, diag, "this can fail; pass the error on with `try`, or handle it with `catch`");
    } else if (f.kind == TypeKind.Optional && t.kind == TypeKind.Bool) {
        hint(c, diag, "Helix has no truthiness; compare with null: `x != null`");
    } else if (f.kind == TypeKind.Optional && f.child == to) {
        hint(c, diag, "this may be null; use `x ?? fallback`, `x!`, or check `x != null` first");
    } else if (f.kind == TypeKind.Null) {
        hintf(c, diag, `only optionals can be null; declare the type as \`?${typeName(c, to)}\``);
    } else if ((f.kind == TypeKind.Int || f.kind == TypeKind.Float) && (t.kind == TypeKind.Int || t.kind == TypeKind.Float)) {
        hintf(c, diag, `convert explicitly with \`as ${typeName(c, to)}\` (checked at runtime in safe builds)`);
    } else if (f.kind == TypeKind.Slice && t.kind == TypeKind.ManyPointer) {
        hint(c, diag, "pass the slice's pointer with `.ptr`");
    } else if (f.kind == TypeKind.Int && t.kind == TypeKind.Bool) {
        hint(c, diag, "Helix has no truthiness; compare explicitly, e.g. `x != 0`");
    } else if (t.kind == TypeKind.Dyn) {
        const iface = t.child;
        if (f.kind == TypeKind.Pointer && hxsIsAggregate(c, f.child)) {
            const readonly = (f.flags & Readonly) != 0;
            if (hxsImplOf(c, f.child, iface, diag, node) == 0) return;
            if (readonly) hintf(c, diag, `\`${typeName(c, iface)}\` has methods that change the value, so it needs a mutable pointer`);
        } else if (hxsIsAggregate(c, from)) {
            hint(c, diag, "`dyn` holds a pointer; pass the value's address with `&`");
        } else {
            hintf(c, diag, `only pointers to structs, unions and enums that implement \`${typeName(c, iface)}\` convert to it`);
        }
    } else if (f.kind == TypeKind.ErrorSet && (t.kind == TypeKind.ErrorSet || t.kind == TypeKind.ErrorUnion)) {
        hint(c, diag, "add the error to the function's error set, or return `Error`");
    } else if (t.kind != TypeKind.Invalid && (t.flags & Readonly) == 0 && (f.flags & Readonly) != 0) {
        hint(c, diag, "a readonly pointer can't become a mutable one");
    }
}

/**
 * Converts a checked expression to the type that its place needs, or reports why it cannot.
 *
 * @param c - The checker context
 * @param node - The expression, already checked
 * @param to - The type that its place needs
 * @returns `true` when the expression converts, and `false` after reporting an error
 *
 * @remarks
 * A conversion is recorded in the `coerce` field of the node's info, and code generation applies it there.
 * Number literals convert to the innermost type, so `5` can become an `i32`, a `?i32`, or an `i32 | Error`.
 * An integer literal that does not fit in its target is an error that names the range of the target.
 * A ternary or an arithmetic expression on literal branches converts each branch or operand instead,
 * since its literal type has no form at run time.
 * Any other conversion must pass {@link hxsImplicitOk} and, between calling conventions,
 * {@link hxsCCallConvertible}.
 *
 * @example
 * ```hx
 * // const x: u8 = 300;
 * hxsCoerce(c, literal, types(c).u8); // false
 * // error: integer 300 does not fit in `u8`
 * ```
 *
 * @see hxsImplicitOk
 * @see hxsMismatch
 *
 * @since 1.0.0
 */

export extern "C" function hxsCoerce(c: *Ctx, node: u32, to: u32): bool {
    const info = infoOf(c, node);
    const from = info.type;
    if (from == to || from == 0 || to == 0) return true;
    c.coerceSite = node;
    const fromKind = kindOf(c, from);

    // `cond ? 1 : 2` or `cond ? "a" : "b"`: the literal type has no runtime form, so each branch converts instead
    if (nodeOf(c, node).kind == NodeKind.Ternary &&
        (hxsIsComptimeNumber(c, from) || fromKind == TypeKind.StringLiteral || fromKind == TypeKind.Null)) {
        const data = record<HxTernaryData>(astOf(c), nodeOf(c, node).b);
        let ok = hxsCoerce(c, data.thenValue, to);
        ok = hxsCoerce(c, data.elseValue, to) && ok;
        const again = infoOf(c, node);   // coercing the branches can grow the tables
        again.type = to;
        again.coerce = 0;
        again.value = 0;
        return ok;
    }

    // arithmetic on such branches (`(a ? 1 : 0) - (b ? 1 : 0)`) isn't known while compiling either: its operands
    // convert, and the operation happens in the target type
    if (hxsIsComptimeNumber(c, from) && hxsValueOf(c, node) == null) {
        const n = nodeOf(c, node);
        if (n.kind == NodeKind.Binary || n.kind == NodeKind.Negate) {
            let ok = hxsCoerce(c, n.a, to);
            if (n.kind == NodeKind.Binary) ok = hxsCoerce(c, n.b, to) && ok;
            const again = infoOf(c, node);
            again.type = to;
            again.coerce = 0;
            return ok;
        }
    }

    // literals convert to the innermost type: `5` can become an `i32`, a `?i32` or an `i32 | Error`
    const inner = hxsExpectedBase(c, to);
    const innerKind = kindOf(c, inner);
    if (fromKind == TypeKind.ComptimeInt && (innerKind == TypeKind.Int || innerKind == TypeKind.Float)) {
        if (const v = hxsValueOf(c, node)) {
            if (innerKind == TypeKind.Int && !hxsIntFits(c, inner, v.integer)) {
                let a: u8[48] = undefined;
                let b: u8[48] = undefined;
                let d: u8[48] = undefined;
                const diag = errorNode(c, node, `integer ${i128Text(v.integer, &a)} does not fit in \`${typeName(c, inner)}\``);
                hintf(c, diag, `\`${typeName(c, inner)}\` holds ${i128Text(hxsIntMin(c, inner), &b)} to ${i128Text(hxsIntMax(c, inner), &d)}`);
                return false;
            }
        }
        infoOf(c, node).coerce = to;
        return true;
    }
    if (fromKind == TypeKind.ComptimeFloat && innerKind == TypeKind.Float) {
        infoOf(c, node).coerce = to;
        return true;
    }
    if (fromKind == TypeKind.StringLiteral && inner != to && hxsImplicitOk(c, from, inner)) {
        infoOf(c, node).coerce = to;
        return true;
    }
    if (hxsImplicitOk(c, from, to)) {
        if (!hxsCCallConvertible(c, node, from, inner)) return false;
        infoOf(c, node).coerce = to;
        return true;
    }
    hxsMismatch(c, node, from, to);
    return false;
}

/**
 * Checks whether passing a type by value works differently in C than between Helix functions.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns `true` for structs, unions, arrays, slices, `dyn`, `Format`, string literals,
 * optionals of anything but a pointer or a function, and error unions with a payload
 *
 * @remarks
 * Code generation lowers these types differently for the C calling convention.
 *
 * @example
 * ```hx
 * hxsCAbiDiffers(c, types(c).i32);    // false
 * hxsCAbiDiffers(c, types(c).string); // true
 * ```
 *
 * @see hxsCCallConvertible
 * @since 1.0.0
 */

export extern "C" function hxsCAbiDiffers(c: *Ctx, t: u32): bool {
    const type = typeOf(c, t);
    switch (type.kind) {
        case TypeKind.Struct, TypeKind.Union, TypeKind.Array, TypeKind.Slice, TypeKind.Dyn, TypeKind.Format,
             TypeKind.StringLiteral: return true;
        case TypeKind.Optional: {
            const child = kindOf(c, type.child);
            return child != TypeKind.Pointer && child != TypeKind.ManyPointer && child != TypeKind.Function;
        }
        case TypeKind.ErrorUnion: return type.child != types(c).voidType;
        default: return false;
    }
}

/**
 * Checks a conversion between a Helix function type and a C one, written `extern "C" (...) => T`.
 *
 * @param c - The checker context
 * @param node - The expression being converted
 * @param from - The function type of the expression
 * @param to - The function type it converts to
 * @returns `true` when the conversion works, and `false` after reporting an error
 *
 * @remarks
 * The conversion is fine when no parameter and not the result travel differently in C.
 * Otherwise only a named function can become a C callback, since the compiler can give it a C entry point.
 * A function pointer from a variable cannot, and a C function pointer cannot become a Helix one.
 *
 * @example
 * ```hx
 * hxsCCallConvertible(c, node, helixFn, cFn); // true for a named function
 * ```
 *
 * @see hxsCAbiDiffers
 * @since 1.0.0
 */

export extern "C" function hxsCCallConvertible(c: *Ctx, node: u32, from: u32, to: u32): bool {
    const f = typeOf(c, from);
    const t = typeOf(c, to);
    if (f.kind != TypeKind.Function || t.kind != TypeKind.Function || (f.flags & CCall) == (t.flags & CCall)) return true;
    let differs = hxsCAbiDiffers(c, f.child);
    for (const i of 0..f.len) {
        if (differs) break;
        differs = hxsCAbiDiffers(c, paramOf(c, f, i));
    }
    if (!differs) return true;
    if (const v = hxsValueOf(c, node)) {
        if ((t.flags & CCall) != 0 && v.kind == HxValueFunction as u8) return true;
    }
    const diag = errorNode(c, node, `\`${typeName(c, from)}\` and \`${typeName(c, to)}\` pass structs by value differently`);
    hint(c, diag, (t.flags & CCall) != 0 ? "pass a named function, which the compiler can give a C entry point"
                                          : "call it where it has its C type; the calling conventions differ");
    return false;
}

/**
 * Finds the common type of the two operands of a binary operator and converts both to it.
 *
 * @param c - The checker context
 * @param a - The left operand, already checked
 * @param b - The right operand, already checked
 * @param opNode - The operator node, where a mismatch is reported
 * @returns The common type, or 0 after an error
 *
 * @remarks
 * A `null` operand makes the common type the optional of the other operand.
 * Two number literals stay a literal type, and the float one wins.
 * A literal next to a concrete type converts to that type.
 * Otherwise the operand whose type converts implicitly to the other's converts.
 *
 * @example
 * ```hx
 * // x + 1   x is an i32
 * hxsPeer(c, x, one, plus); // types(c).i32
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsPeer(c: *Ctx, a: u32, b: u32, opNode: u32): u32 {
    const ta = infoOf(c, a).type;
    const tb = infoOf(c, b).type;
    if (ta == 0 || tb == 0) return 0;
    if (ta == tb) return ta;
    const tys = types(c);
    if (kindOf(c, ta) == TypeKind.Null || kindOf(c, tb) == TypeKind.Null) {
        const other = kindOf(c, ta) == TypeKind.Null ? tb : ta;
        if (kindOf(c, other) == TypeKind.Null) return 0;
        const optional = kindOf(c, other) == TypeKind.Optional ? other : hxTypeOptional(tys, other);
        let ok = hxsCoerce(c, a, optional);
        ok = hxsCoerce(c, b, optional) && ok;
        return ok ? optional : 0;
    }
    const ca = hxsIsComptimeNumber(c, ta);
    const cb = hxsIsComptimeNumber(c, tb);
    if (ca && cb) return ta == tys.comptimeFloat || tb == tys.comptimeFloat ? tys.comptimeFloat : tys.comptimeInt;
    if (ca) return hxsCoerce(c, a, tb) ? tb : 0;
    if (cb) return hxsCoerce(c, b, ta) ? ta : 0;
    if (kindOf(c, ta) == TypeKind.StringLiteral && kindOf(c, tb) == TypeKind.StringLiteral) return ta;
    if (hxsImplicitOk(c, ta, tb)) return hxsCoerce(c, a, tb) ? tb : 0;
    if (hxsImplicitOk(c, tb, ta)) return hxsCoerce(c, b, ta) ? ta : 0;
    const diag = errorNode(c, opNode, `mismatched operand types \`${typeName(c, ta)}\` and \`${typeName(c, tb)}\``);
    hintf(c, diag, `convert one side with \`as\`, e.g. \`a as ${typeName(c, tb)}\``);
    return 0;
}

/**
 * Reports a `Format` used anywhere other than as the type of a parameter.
 *
 * @param c - The checker context
 * @param t - The type in question
 * @param where - The node to report at
 * @returns `true` when `t` is `Format` and an error was reported
 *
 * @remarks
 * A `Format` refers to values on the caller's stack, so it cannot be stored or returned.
 *
 * @example
 * ```hx
 * // struct Line { text: Format }
 * hxsFormatEscapes(c, fieldType, node); // true
 * // error: a `Format` can only be a parameter's type
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsFormatEscapes(c: *Ctx, t: u32, where: u32): bool {
    if (t != types(c).format) return false;
    const diag = errorNode(c, where, "a `Format` can only be a parameter's type");
    hint(c, diag, "it points at the caller's values, so it can't be stored or returned; format it into a writer instead");
    return true;
}
