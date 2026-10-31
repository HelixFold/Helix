/**
 * Imports
 */

import { BinOp } from "@constants/ast.constant";
import { TypeKind } from "@constants/types.constant";
import { hxArenaAlloc } from "@services/arena.service";
import { hxSourceLineCol } from "@models/source.model";
import { hxZalloc, hxVecGrowImpl } from "@components/memory.component";
import { I128Max, I128Min } from "@modules/sema/constants/scope.constant";
import { Ctx, HxValue, HxSema, HxU32Vec, HxScopeEntry, HxSymbol } from "@structs/sema.struct";
import { i128Text, errorNode, errorToken, hint } from "@modules/sema/components/base.component";
import { HxSymLocal, HxScopeUsed, HxValueFloat, HxSymMutable, HxValueInt } from "@constants/sema.constant";
import { HxValueString, HxSymUsed, HxSymParam, HxValueBool, HxSymMutated } from "@constants/sema.constant";
import { emptyValue, hintf, hxsTokName, hxsValueOf, hxsAddValue } from "@modules/sema/components/base.component";
import { typeOf, symbolOf, infoOf, types, tokenText, hxsIntValue } from "@modules/sema/components/base.component";
import { hxsBoolValue, hxsFloatValue, hxsIntMin, tokenStart, typeName } from "@modules/sema/components/base.component";
import { hxsIntMax, hxsIntFits, hxsWrapInt, hxsIsFloat, semaOf, nodeOf } from "@modules/sema/components/base.component";

/**
 * The C library functions that the scope table and the float literals use.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;
extern "C" function strtod(text: readonly u8[*], end: ?*?u8[*]): f64;

/**
 * Appends a value to a vector of `u32`, growing it when it is full.
 *
 * @param vec - The vector to append to
 * @param v - The value to append
 *
 * @remarks
 * The checker keeps its scope stack, scope marks, and symbol lists in this vector type.
 *
 * @example
 * ```hx
 * pushU32(&c.scope, sym);
 * c.scope.len; // one more than before
 * ```
 *
 * @see u32At
 * @since 1.0.0
 */

export function pushU32(vec: *HxU32Vec, v: u32): void {
    unsafe {
        if (vec.len == vec.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &vec.items), &vec.cap, vec.len + 1, 4);
        vec.items![vec.len] = v;
    }
    vec.len += 1;
}

/**
 * Reads the value at an index of a vector of `u32`.
 *
 * @param vec - The vector to read
 * @param i - The index, which must be below the length
 * @returns The value at the index
 *
 * @remarks
 * The index is not checked against the length.
 *
 * @example
 * ```hx
 * pushU32(&vec, 7);
 * u32At(&vec, 0); // 7
 * ```
 *
 * @see pushU32
 * @since 1.0.0
 */

export function u32At(vec: readonly *HxU32Vec, i: u32): u32 {
    unsafe {
        return vec.items![i];
    }
}

/**
 * Views the scope table of the checker as an array of entries.
 *
 * @param s - The checker state that owns the table
 * @returns The entries, `scopesCap` of them
 *
 * @remarks
 * The scope table is a hash table, so some entries are empty, and the caller must stay below `scopesCap`.
 *
 * @since 1.0.0
 */

function entries(s: readonly *HxSema): HxScopeEntry[*] {
    unsafe {
        return @ptrCast(HxScopeEntry[*], s.scopes);
    }
}

/**
 * Builds the key that the module scope table files a name under.
 *
 * @param module - The index of the module that declares the name
 * @param name - The interned name
 * @returns The module plus one in the high 32 bits and the name in the low 32 bits
 *
 * @remarks
 * Adding one to the module keeps the key 0 free, so a key of 0 marks an empty slot.
 *
 * @example
 * ```hx
 * hxsScopeKey(0, 5); // 0x1_0000_0005
 * ```
 *
 * @see hxsScopeSlot
 * @since 1.0.0
 */

export extern "C" function hxsScopeKey(module: u32, name: u32): u64 {
    return (((module + 1) as u64) << 32) | (name as u64);   // module + 1 keeps key 0 free for empty slots
}

/**
 * Finds the slot where the search for a key starts.
 *
 * @param s - The checker state that owns the table
 * @param key - The key from {@link hxsScopeKey}
 * @returns The first slot to probe, below `scopesCap`
 *
 * @remarks
 * The key is multiplied by the 64-bit golden ratio constant, and the top 32 bits of the product pick the slot.
 * The capacity is always a power of two, so a mask keeps the slot inside the table.
 *
 * @example
 * ```hx
 * hxsScopeSlot(s, hxsScopeKey(0, name)); // a slot below scopesCap
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsScopeSlot(s: readonly *HxSema, key: u64): u32 {
    const hash = key *% 0x9E3779B97F4A7C15;
    return @truncate(u32, hash >> 32) & (s.scopesCap - 1);
}

/**
 * Finds the entry of a module-level name.
 *
 * @param s - The checker state that owns the table
 * @param module - The index of the module to look in
 * @param name - The interned name
 * @returns The entry, or `null` when the module has no such name
 *
 * @remarks
 * The table uses open addressing with linear probing, so the search walks forward from the start slot
 * until it meets the key or an empty slot.
 * Imported names live in the same table as the module's own declarations.
 *
 * @example
 * ```hx
 * const entry = hxsScopeFind(s, 0, name);
 * entry?.symbol; // the symbol the name stands for
 * ```
 *
 * @see hxsScopeInsert
 * @since 1.0.0
 */

export extern "C" function hxsScopeFind(s: *HxSema, module: u32, name: u32): ?*HxScopeEntry {
    if (s.scopesCap == 0) return null;
    const key = hxsScopeKey(module, name);
    let slot = hxsScopeSlot(s, key);
    unsafe {
        while (true) {
            const entry = &entries(s)[slot];
            if (entry.key == key) return entry;
            if (entry.key == 0) return null;
            slot = (slot + 1) & (s.scopesCap - 1);
        }
    }
}

/**
 * Adds a new entry for a module-level name and returns it for the caller to fill.
 *
 * @param s - The checker state that owns the table
 * @param module - The index of the module that declares the name
 * @param name - The interned name
 * @returns The new entry, with its key set and its symbol, token, and flags at 0
 *
 * @remarks
 * The caller makes sure the name is not in the table yet, since this always takes a fresh slot.
 * The table starts at 1024 slots and doubles whenever it would become more than half full,
 * moving every entry to its slot in the new table and freeing the old one.
 *
 * @example
 * ```hx
 * const entry = hxsScopeInsert(s, c.module, name);
 * entry.symbol = sym;
 * ```
 *
 * @see hxsScopeFind
 * @since 1.0.0
 */

export extern "C" function hxsScopeInsert(s: *HxSema, module: u32, name: u32): *HxScopeEntry {
    if ((s.scopesCount + 1) * 2 > s.scopesCap) {
        const oldCap = s.scopesCap;
        const old = entries(s);
        s.scopesCap = oldCap != 0 ? oldCap * 2 : 1024;
        unsafe {
            s.scopes = @ptrCast(*HxScopeEntry, hxZalloc((s.scopesCap as usize) * @sizeOf(HxScopeEntry)));
            for (const i of 0..oldCap) {
                if (old[i].key == 0) continue;
                let slot = hxsScopeSlot(s, old[i].key);
                while (entries(s)[slot].key != 0) slot = (slot + 1) & (s.scopesCap - 1);
                entries(s)[slot] = old[i];
            }
            if (oldCap != 0) free(@ptrCast(u8[*], old));
        }
    }
    const key = hxsScopeKey(module, name);
    let slot = hxsScopeSlot(s, key);
    unsafe {
        while (entries(s)[slot].key != 0) slot = (slot + 1) & (s.scopesCap - 1);
        entries(s)[slot].key = key;
        s.scopesCount += 1;
        return &entries(s)[slot];
    }
}

/**
 * Finds the symbol that a name refers to at the current point of the check.
 *
 * @param c - The checker context
 * @param name - The interned name
 * @returns The symbol, or 0 when the name is not declared
 *
 * @remarks
 * Locals come first, from the innermost outward, but only down to `scopeBase`,
 * so a function never sees the locals of the function around it.
 * When `globalsOnly` is set, as for member types and global values, locals are skipped entirely.
 * The module scope comes last, and a hit there marks the entry as used for the unused import check.
 *
 * @example
 * ```hx
 * hxsLookup(c, hxsTokName(c, token)); // the symbol, or 0
 * ```
 *
 * @see hxsDeclareLocal
 * @since 1.0.0
 */

export extern "C" function hxsLookup(c: *Ctx, name: u32): u32 {
    if (!c.globalsOnly) {
        let i = c.scope.len;
        while (i > c.scopeBase) {
            const sym = u32At(&c.scope, i - 1);
            if (symbolOf(c, sym).name == name) return sym;
            i -= 1;
        }
    }
    if (const entry = hxsScopeFind(semaOf(c), c.module, name)) {
        entry.flags |= HxScopeUsed as u8;
        return entry.symbol;
    }
    return 0;
}

/**
 * Appends a symbol to the symbol table of the checker.
 *
 * @param c - The checker context
 * @param kind - The symbol kind, such as `HxSymLocal` or `HxSymModule`
 * @param token - The token of the name
 * @param decl - The node that declares the symbol
 * @param type - The type of the symbol, or 0 when it is not known yet
 * @returns The index of the new symbol
 *
 * @remarks
 * The symbol belongs to the current module and starts without flags or a value.
 * It is not put in any scope, which the caller does.
 *
 * @example
 * ```hx
 * const sym = hxsAddSymbol(c, HxSymLocal, token, decl, type);
 * pushU32(&c.scope, sym);
 * ```
 *
 * @see hxsDeclareLocal
 * @since 1.0.0
 */

export extern "C" function hxsAddSymbol(c: *Ctx, kind: u32, token: u32, decl: u32, type: u32): u32 {
    const sym = HxSymbol {
        kind: @truncate(u8, kind), flags: 0, name: hxsTokName(c, token), token, decl, type, value: 0, owner: 0,
        instance: 0, module: c.module, targetModule: 0,
    };
    const symbols = &semaOf(c).symbols;
    unsafe {
        if (symbols.len == symbols.cap) {
            hxVecGrowImpl(@ptrCast(*?u8[*], &symbols.items), &symbols.cap, symbols.len + 1, @sizeOf(HxSymbol));
        }
        @ptrCast(HxSymbol[*], symbols.items)[symbols.len] = sym;
    }
    symbols.len += 1;
    return symbols.len - 1;
}

/**
 * Reports a name declared a second time and points at the first declaration.
 *
 * @param c - The checker context
 * @param token - The token of the second declaration
 * @param previous - The symbol of the first declaration
 *
 * @remarks
 * The hint gives the line of the earlier declaration and says that Helix does not allow shadowing.
 *
 * @example
 * ```hx
 * hxsReportRedeclared(c, token, previous);
 * // error: `a` is already declared
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsReportRedeclared(c: *Ctx, token: u32, previous: u32): void {
    const diag = errorToken(c, token, `\`${tokenText(c, token)}\` is already declared`);
    const at = hxSourceLineCol(semaOf(c).src!, tokenStart(c, symbolOf(c, previous).token));
    hintf(c, diag, `the earlier declaration is at line ${at.line}; Helix doesn't allow shadowing, pick another name`);
}

/**
 * Declares a local or a parameter in the innermost scope.
 *
 * @param c - The checker context
 * @param kind - The symbol kind, `HxSymLocal` or `HxSymParam`
 * @param token - The token of the name, or `0xFFFFFFFF` when the declaration has no name
 * @param decl - The node that declares it
 * @param type - The type of the local
 * @returns The new symbol, or 0 for a declaration without a name
 *
 * @remarks
 * A name that is already visible, as a local or as a module-level name, is reported as redeclared.
 * The local is still added, and it is marked as used and mutated
 * so that the same mistake does not also draw an unused or never reassigned error.
 *
 * @example
 * ```hx
 * const sym = hxsDeclareLocal(c, HxSymLocal, token, decl, type);
 * hxsLookup(c, name); // sym
 * ```
 *
 * @see hxsReportRedeclared
 * @since 1.0.0
 */

export extern "C" function hxsDeclareLocal(c: *Ctx, kind: u32, token: u32, decl: u32, type: u32): u32 {
    if (token == 0xFFFF_FFFF) return 0;
    const previous = hxsLookup(c, hxsTokName(c, token));
    if (previous != 0) hxsReportRedeclared(c, token, previous);
    const sym = hxsAddSymbol(c, kind, token, decl, type);
    if (previous != 0) symbolOf(c, sym).flags |= (HxSymUsed | HxSymMutated) as u16;
    pushU32(&c.scope, sym);
    return sym;
}

/**
 * Opens a block scope.
 *
 * @param c - The checker context
 *
 * @remarks
 * It records the current length of the scope stack, so {@link hxsPopScope} knows which locals the block declared.
 *
 * @example
 * ```hx
 * hxsPushScope(c);
 * // check the statements of the block
 * hxsPopScope(c);
 * ```
 *
 * @see hxsPopScope
 * @since 1.0.0
 */

export extern "C" function hxsPushScope(c: *Ctx): void {
    pushU32(&c.scopeMarks, c.scope.len);
}

/**
 * Reports a local or a parameter that the code never uses, or a `let` that it never reassigns.
 *
 * @param c - The checker context
 * @param id - The symbol to check
 *
 * @remarks
 * A symbol without a type is skipped, since its declaration already failed and was reported.
 * A name that starts with `_` is never reported, and a method may ignore its `this` parameter.
 * An unused local gets a hint to remove it or to rename it with a leading `_`.
 * A `let` local that is used but never assigned again gets a hint to declare it with `const`.
 *
 * @example
 * ```hx
 * // function f(): void { const a: i32 = 1; }
 * hxsCheckUnused(c, sym); // error: unused local `a`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckUnused(c: *Ctx, id: u32): void {
    const sym = symbolOf(c, id);
    if (sym.type == 0) return;   // already reported: its declaration failed
    const name = tokenText(c, sym.token);
    if (name[0] == '_') return;
    if (sym.kind == HxSymParam as u8 && name.len == 4 && name[0] == 't' && name[1] == 'h' && name[2] == 'i' && name[3] == 's') {
        return;   // a method may ignore its receiver
    }
    if ((sym.flags & (HxSymUsed as u16)) == 0) {
        const what = sym.kind == HxSymParam as u8 ? "parameter" : "local";
        const diag = errorToken(c, sym.token, `unused ${what} \`${name}\``);
        hintf(c, diag, `remove it, or rename it to \`_${name}\` to keep it`);
    } else if (sym.kind == HxSymLocal as u8 && (sym.flags & (HxSymMutable as u16)) != 0 &&
               (sym.flags & (HxSymMutated as u16)) == 0) {
        const diag = errorToken(c, sym.token, `\`${name}\` is never reassigned`);
        hint(c, diag, "declare it with `const`");
    }
}

/**
 * Closes the innermost block scope.
 *
 * @param c - The checker context
 *
 * @remarks
 * Every local that the block declared goes through {@link hxsCheckUnused},
 * and the scope stack then drops back to where {@link hxsPushScope} found it.
 *
 * @example
 * ```hx
 * hxsPopScope(c); // the block's locals are out of scope
 * ```
 *
 * @see hxsPushScope
 * @since 1.0.0
 */

export extern "C" function hxsPopScope(c: *Ctx): void {
    c.scopeMarks.len -= 1;
    const mark = u32At(&c.scopeMarks, c.scopeMarks.len);
    for (const i of mark..c.scope.len) hxsCheckUnused(c, u32At(&c.scope, i));
    c.scope.len = mark;
}

/**
 * Decodes one UTF-8 sequence into its code point.
 *
 * @param text - The text to read
 * @param i - The offset of the first byte, which moves past the sequence
 * @returns The code point
 *
 * @remarks
 * The lead byte gives the length of the sequence.
 * The bytes are not validated, since the lexer has already accepted the text.
 *
 * @example
 * ```hx
 * let i: u32 = 0;
 * hxsDecodeCodepoint(text, &i); // 0xE9 for the bytes C3 A9
 * i;                              // 2
 * ```
 *
 * @see hxsEncodeUtf8
 * @since 1.0.0
 */

export extern "C" function hxsDecodeCodepoint(text: readonly u8[*], i: *u32): u32 {
    unsafe {
        const b = text[*i];
        if (b < 0x80) {
            *i += 1;
            return b as u32;
        }
        const count: u32 = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : 1;
        let cp = (b as u32) & ((0x3F as u32) >> count);
        *i += 1;
        for (const _ of 0..count) {
            cp = (cp << 6) | ((text[*i] & 0x3F) as u32);
            *i += 1;
        }
        return cp;
    }
}

/**
 * Gives the value of one hex digit.
 *
 * @param h - The digit, `0` to `9` or a letter `a` to `f` in either case
 * @returns The value from 0 to 15
 *
 * @remarks
 * Any other byte gives a meaningless value, since the lexer has already checked the digits.
 * The integer literals of every base use it, because their digits are a subset of the hex digits.
 *
 * @example
 * ```hx
 * hxsHexValue('7'); // 7
 * hxsHexValue('F'); // 15
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsHexValue(h: u8): u32 {
    return h >= '0' && h <= '9' ? (h - '0') as u32 : ((h | 0x20) - 'a' + 10) as u32;
}

/**
 * Decodes one escape sequence.
 *
 * @param text - The text to read
 * @param i - The offset of the backslash, which moves past the escape
 * @param rawByte - Set to `true` for `\xNN`, which gives a byte rather than a code point
 * @returns The code point, or the byte for `\xNN`
 *
 * @remarks
 * It knows `\n`, `\r`, `\t`, `\0`, `\xNN` with two hex digits, and `\u{...}` with any number of them.
 * Any other escaped character stands for itself, which covers the backslash, the quotes, the backtick, and `$`.
 *
 * @example
 * ```hx
 * let i: u32 = 0;
 * let raw = false;
 * hxsDecodeEscape(text, &i, &raw); // 255 for the text \xFF
 * raw;                               // true
 * ```
 *
 * @see hxsEncodeUtf8
 * @since 1.0.0
 */

export extern "C" function hxsDecodeEscape(text: readonly u8[*], i: *u32, rawByte: *bool): u32 {
    *rawByte = false;
    unsafe {
        *i += 1;
        const e = text[*i];
        *i += 1;
        switch (e) {
            case 'n': return '\n';
            case 'r': return '\r';
            case 't': return '\t';
            case '0': return 0;
            case 'x': {
                const v = hxsHexValue(text[*i]) * 16 + hxsHexValue(text[*i + 1]);
                *i += 2;
                *rawByte = true;
                return v;
            }
            case 'u': {
                *i += 1;   // {
                let v: u32 = 0;
                while (text[*i] != '}') {
                    v = v * 16 + hxsHexValue(text[*i]);
                    *i += 1;
                }
                *i += 1;
                return v;
            }
            default: return e as u32;   // \\ \" \' \` \$
        }
    }
}

/**
 * Encodes a code point as UTF-8.
 *
 * @param cp - The code point
 * @param out - The buffer to write, which needs room for four bytes
 * @returns The number of bytes written, from 1 to 4
 *
 * @remarks
 * It does not check the code point, so the caller passes one that the decoder accepted.
 * The string literal check uses it to write each `\u{...}` escape into the bytes of the value.
 *
 * @example
 * ```hx
 * let buf: u8[4] = undefined;
 * hxsEncodeUtf8(0x20AC, &buf); // 3
 * ```
 *
 * @see hxsDecodeCodepoint
 * @since 1.0.0
 */

export extern "C" function hxsEncodeUtf8(cp: u32, out: u8[*]): u32 {
    unsafe {
        if (cp < 0x80) {
            out[0] = @truncate(u8, cp);
            return 1;
        }
        if (cp < 0x800) {
            out[0] = @truncate(u8, 0xC0 | (cp >> 6));
            out[1] = @truncate(u8, 0x80 | (cp & 0x3F));
            return 2;
        }
        if (cp < 0x10000) {
            out[0] = @truncate(u8, 0xE0 | (cp >> 12));
            out[1] = @truncate(u8, 0x80 | ((cp >> 6) & 0x3F));
            out[2] = @truncate(u8, 0x80 | (cp & 0x3F));
            return 3;
        }
        out[0] = @truncate(u8, 0xF0 | (cp >> 18));
        out[1] = @truncate(u8, 0x80 | ((cp >> 12) & 0x3F));
        out[2] = @truncate(u8, 0x80 | ((cp >> 6) & 0x3F));
        out[3] = @truncate(u8, 0x80 | (cp & 0x3F));
        return 4;
    }
}

/**
 * Checks an integer literal and records its value.
 *
 * @param c - The checker context
 * @param node - The literal node
 * @returns The `comptimeInt` type, or 0 when the literal is too large
 *
 * @remarks
 * A `0x`, `0o`, or `0b` prefix in either case selects the base, and `_` separators are skipped.
 * A value above {@link I128Max} draws an error that the integer literal is too large.
 *
 * @example
 * ```hx
 * // const x = 0x1_F;
 * hxsCheckIntLiteral(c, node); // comptimeInt, with the value 31
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckIntLiteral(c: *Ctx, node: u32): u32 {
    const text = tokenText(c, nodeOf(c, node).token);
    let base: u128 = 10;
    let i: usize = 0;
    if (text.len > 2 && text[0] == '0') {
        const p = text[1] | 0x20;
        if (p == 'x') base = 16;
        if (p == 'o') base = 8;
        if (p == 'b') base = 2;
        if (base != 10) i = 2;
    }
    let v: u128 = 0;
    for (const ch of text[i..text.len]) {
        if (ch == '_') continue;
        const next = v *% base +% (hxsHexValue(ch) as u128);
        if (next / base != v || next > (I128Max as u128)) {
            void errorNode(c, node, "integer literal is too large");
            return 0;
        }
        v = next;
    }
    infoOf(c, node).value = hxsIntValue(c, v as i128);
    return types(c).comptimeInt;
}

/**
 * Checks a float literal and records its value.
 *
 * @param c - The checker context
 * @param node - The literal node
 * @returns The `comptimeFloat` type
 *
 * @remarks
 * The `_` separators are dropped and C's `strtod` reads the rest.
 * The text goes through a 128-byte buffer, so only its first 127 characters count.
 *
 * @example
 * ```hx
 * // const x = 1_000.5;
 * hxsCheckFloatLiteral(c, node); // comptimeFloat, with the value 1000.5
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckFloatLiteral(c: *Ctx, node: u32): u32 {
    const text = tokenText(c, nodeOf(c, node).token);
    let buf: u8[128] = undefined;
    let n: usize = 0;
    for (const ch of text) {
        if (n >= 127) break;
        if (ch != '_') {
            buf[n] = ch;
            n += 1;
        }
    }
    buf[n] = 0;
    infoOf(c, node).value = hxsFloatValue(c, strtod(&buf, null));
    return types(c).comptimeFloat;
}

/**
 * Checks a character literal and records its code point.
 *
 * @param c - The checker context
 * @param node - The literal node
 * @returns The `comptimeInt` type
 *
 * @remarks
 * The character may be an escape or any UTF-8 sequence, and its value is the code point.
 *
 * @example
 * ```hx
 * // const x = 'A';
 * hxsCheckCharLiteral(c, node); // comptimeInt, with the value 65
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckCharLiteral(c: *Ctx, node: u32): u32 {
    const text = tokenText(c, nodeOf(c, node).token);
    let i: u32 = 1;
    let raw = false;
    const cp = text[1] == '\\' ? hxsDecodeEscape(text.ptr, &i, &raw) : hxsDecodeCodepoint(text.ptr, &i);
    infoOf(c, node).value = hxsIntValue(c, cp as i128);
    return types(c).comptimeInt;
}

/**
 * Checks a string literal and records its decoded bytes.
 *
 * @param c - The checker context
 * @param node - The literal node
 * @returns The `stringLiteral` type
 *
 * @remarks
 * The bytes between the quotes are copied into the checker's arena with their escapes decoded and a NUL after them.
 * An escaped code point is stored as UTF-8, while `\xNN` is stored as the one byte it names.
 * The length of the value leaves out the NUL.
 *
 * @example
 * ```hx
 * // const x = "a\n";
 * hxsCheckStringLiteral(c, node); // stringLiteral, with two bytes
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckStringLiteral(c: *Ctx, node: u32): u32 {
    const text = tokenText(c, nodeOf(c, node).token);
    const bytes = hxArenaAlloc(&semaOf(c).arena, text.len + 1, 1);
    let out: u32 = 0;
    let i: u32 = 1;
    const len = @truncate(u32, text.len);
    unsafe {
        while (i < len - 1) {
            if (text[i] == '\\') {
                let raw = false;
                const cp = hxsDecodeEscape(text.ptr, &i, &raw);
                if (raw) {
                    bytes[out] = @truncate(u8, cp);
                    out += 1;
                } else {
                    out += hxsEncodeUtf8(cp, @ptrFromInt(u8[*], @intFromPtr(bytes) + (out as usize)));
                }
            } else {
                bytes[out] = text[i];
                out += 1;
                i += 1;
            }
        }
        bytes[out] = 0;
    }
    let v = emptyValue(HxValueString as u8);
    v.bytes = bytes;
    v.len = out;
    infoOf(c, node).value = hxsAddValue(c, v);
    return types(c).stringLiteral;
}

/**
 * Checks whether an operator is one of the wrapping operators.
 *
 * @param op - The `BinOp` number
 * @returns `true` for `+%`, `-%`, and `*%`
 *
 * @remarks
 * Constant folding wraps these operators to the width of a concrete integer type instead of reporting an overflow.
 * On a literal type they have no width to wrap at, so the checker reports them there.
 *
 * @example
 * ```hx
 * hxsIsWrapping(BinOp.AddWrap as u32); // true
 * hxsIsWrapping(BinOp.Add as u32);     // false
 * ```
 *
 * @see hxsIsSaturating
 * @since 1.0.0
 */

export extern "C" function hxsIsWrapping(op: u32): bool {
    return op == BinOp.AddWrap as u32 || op == BinOp.SubWrap as u32 || op == BinOp.MulWrap as u32;
}

/**
 * Checks whether an operator is one of the saturating operators.
 *
 * @param op - The `BinOp` number
 * @returns `true` for `+|`, `-|`, and `*|`
 *
 * @remarks
 * Constant folding clamps these operators to the range of a concrete integer type instead of reporting an overflow.
 * On a literal type they have no range to clamp to, so the checker reports them there.
 *
 * @example
 * ```hx
 * hxsIsSaturating(BinOp.SubSat as u32);  // true
 * hxsIsSaturating(BinOp.SubWrap as u32); // false
 * ```
 *
 * @see hxsIsWrapping
 * @since 1.0.0
 */

export extern "C" function hxsIsSaturating(op: u32): bool {
    return op == BinOp.AddSat as u32 || op == BinOp.SubSat as u32 || op == BinOp.MulSat as u32;
}

/**
 * Adds two `i128` values and tells whether the sum overflowed.
 *
 * @param a - The left operand
 * @param b - The right operand
 * @param r - Receives the sum, wrapped on overflow
 * @returns `true` when the true sum does not fit in an `i128`
 *
 * @remarks
 * An overflow happens only when both operands have the same sign and the wrapped sum has the other one.
 *
 * @example
 * ```hx
 * let r: i128 = 0;
 * addOverflows(I128Max, 1, &r); // true
 * r;                             // I128Min
 * ```
 *
 * @see subOverflows
 * @see mulOverflows
 *
 * @since 1.0.0
 */

export function addOverflows(a: i128, b: i128, r: *i128): bool {
    *r = a +% b;
    return (a >= 0) == (b >= 0) && (*r >= 0) != (a >= 0);
}

/**
 * Subtracts two `i128` values and tells whether the difference overflowed.
 *
 * @param a - The left operand
 * @param b - The right operand
 * @param r - Receives the difference, wrapped on overflow
 * @returns `true` when the true difference does not fit in an `i128`
 *
 * @remarks
 * An overflow happens only when the operands have different signs and the result has the sign of `b`.
 *
 * @example
 * ```hx
 * let r: i128 = 0;
 * subOverflows(I128Min, 1, &r); // true
 * ```
 *
 * @see addOverflows
 * @since 1.0.0
 */

export function subOverflows(a: i128, b: i128, r: *i128): bool {
    *r = a -% b;
    return (a >= 0) != (b >= 0) && (*r >= 0) != (a >= 0);
}

/**
 * Multiplies two `i128` values and tells whether the product overflowed.
 *
 * @param a - The left operand
 * @param b - The right operand
 * @param r - Receives the product, wrapped on overflow
 * @returns `true` when the true product does not fit in an `i128`
 *
 * @remarks
 * Dividing the wrapped product by `a` gives `b` back only when nothing was lost.
 * The case of -1 times {@link I128Min} gets its own test, since that division would overflow as well.
 *
 * @example
 * ```hx
 * let r: i128 = 0;
 * mulOverflows(-3, 4, &r);       // false
 * r;                             // -12
 * mulOverflows(I128Max, 2, &r); // true
 * ```
 *
 * @see addOverflows
 * @since 1.0.0
 */

export function mulOverflows(a: i128, b: i128, r: *i128): bool {
    *r = a *% b;
    if (a == 0) return false;
    if (a == -1) return b == I128Min;
    return *r / a != b;
}

/**
 * Folds an integer operation on two values known at compile time.
 *
 * @param c - The checker context
 * @param node - The node to report an error against
 * @param opNumber - The `BinOp` number of the operation
 * @param a - The left operand
 * @param b - The right operand
 * @param type - The operand type, a sized integer or `comptimeInt`
 * @param out - Receives the result
 * @returns `true` with the result in `out`, or `false` after an error was reported
 *
 * @remarks
 * On a sized integer type, a wrapping operator wraps the result to the width of the type,
 * and a saturating operator clamps it to the range of the type.
 * Every other operation works on `i128` and reports an integer overflow when the result leaves `i128`
 * or the range of a sized type, with a hint that gives the range and suggests a wider type or a wrapping operator.
 * Division and remainder by zero are errors, and so is a shift by a negative amount or by the width of the type,
 * which is 127 for `comptimeInt`.
 * The right shift is arithmetic.
 * The left shift drops the bits it moves out of a sized type, as in C,
 * and on `comptimeInt` it overflows like the matching multiplication.
 *
 * @example
 * ```hx
 * // const x: u8 = (200 as u8) + 100;
 * hxsFoldInt(c, node, BinOp.Add as u32, 200, 100, u8, &r); // false: integer overflow
 * ```
 *
 * @see hxsFoldBinary
 * @since 1.0.0
 */

export extern "C" function hxsFoldInt(c: *Ctx, node: u32, opNumber: u32, a: i128, b: i128, type: u32, out: *i128): bool {
    const op = @enumFromInt(BinOp, opNumber);
    const concrete = typeOf(c, type).kind == TypeKind.Int;
    if (concrete && hxsIsWrapping(opNumber)) {
        let r: i128 = 0;
        if (op == BinOp.AddWrap) r = a +% b;
        else if (op == BinOp.SubWrap) r = a -% b;
        else r = a *% b;
        *out = hxsWrapInt(c, type, r);
        return true;
    }

    let r: i128 = 0;
    let overflow = false;
    switch (op) {
        case BinOp.Add, BinOp.AddSat: overflow = addOverflows(a, b, &r);
        case BinOp.Sub, BinOp.SubSat: overflow = subOverflows(a, b, &r);
        case BinOp.Mul, BinOp.MulSat: overflow = mulOverflows(a, b, &r);
        case BinOp.Div, BinOp.Mod: {
            if (b == 0) {
                void errorNode(c, node, "division by zero in a constant expression");
                return false;
            }
            if (a == I128Min && b == -1) overflow = true;
            else r = op == BinOp.Div ? a / b : a % b;
        }
        case BinOp.BitAnd: r = a & b;
        case BinOp.BitOr: r = a | b;
        case BinOp.BitXor: r = a ^ b;
        case BinOp.Shl, BinOp.Shr: {
            const limit: i128 = concrete ? typeOf(c, type).bits as i128 : 127;
            if (b < 0 || b >= limit) {
                let buf: u8[48] = undefined;
                void errorNode(c, node, `shift amount ${i128Text(b, &buf)} is too large for \`${typeName(c, type)}\``);
                return false;
            }
            const amount = @truncate(u8, b);
            if (op == BinOp.Shr) {
                *out = a >> amount;
                return true;
            }
            if (concrete) {   // `<<` drops the bits shifted out, as in C
                *out = hxsWrapInt(c, type, @truncate(i128, @truncate(u128, a) << amount));
                return true;
            }
            overflow = mulOverflows(a, (1 as i128) << amount, &r);
        }
        default: unreachable;
    }

    if (concrete && hxsIsSaturating(opNumber)) {
        if (overflow) {
            const negative = op == BinOp.MulSat ? (a < 0) != (b < 0) : op == BinOp.SubSat ? b > 0 : b < 0;
            r = negative ? hxsIntMin(c, type) : hxsIntMax(c, type);
        }
        const lo = hxsIntMin(c, type);
        const hi = hxsIntMax(c, type);
        *out = r < lo ? lo : r > hi ? hi : r;
        return true;
    }
    if (overflow || (concrete && !hxsIntFits(c, type, r))) {
        const diag = errorNode(c, node, "integer overflow in a constant expression");
        if (concrete) {
            let lo: u8[48] = undefined;
            let hi: u8[48] = undefined;
            hintf(c, diag, `the result doesn't fit in \`${typeName(c, type)}\` (${i128Text(hxsIntMin(c, type), &lo)} to ${i128Text(hxsIntMax(c, type), &hi)}); use a wider type or a wrapping operator like \`+%\``);
        }
        return false;
    }
    *out = r;
    return true;
}

/**
 * Reads a compile-time number as a float.
 *
 * @param v - The value, a float or an integer
 * @returns The float, or the integer converted to one
 *
 * @remarks
 * The caller has already checked that the value is a number, since any other kind reads as its integer field.
 *
 * @since 1.0.0
 */

function asFloat(v: *HxValue): f64 {
    return v.kind == HxValueFloat as u8 ? v.floating : v.integer as f64;
}

/**
 * Folds a binary expression whose operands are both known at compile time.
 *
 * @param c - The checker context
 * @param node - The binary expression node, which receives the folded value
 * @param opNumber - The `BinOp` number of the operation
 * @param operandType - The type the operands were checked as
 *
 * @remarks
 * Nothing happens when either operand has no compile-time value.
 * `&&` and `||` fold booleans.
 * The comparisons fold booleans, integers, and floats,
 * where an integer compared with a float is converted first, and other kinds of values stay unfolded.
 * On a float type, `+`, `-`, `*`, and `/` fold, and other operators stay unfolded.
 * The integer operators go through {@link hxsFoldInt}, which reports overflow and division by zero.
 *
 * @example
 * ```hx
 * // const x = 2 + 3 * 4;
 * hxsFoldBinary(c, node, BinOp.Add as u32, comptimeInt); // the node's value is 14
 * ```
 *
 * @see hxsFoldInt
 * @since 1.0.0
 */

export extern "C" function hxsFoldBinary(c: *Ctx, node: u32, opNumber: u32, operandType: u32): void {
    const n = nodeOf(c, node);
    const a = hxsValueOf(c, n.a);
    const b = hxsValueOf(c, n.b);
    if (a == null || b == null) return;
    const op = @enumFromInt(BinOp, opNumber);
    switch (op) {
        case BinOp.And: {
            infoOf(c, node).value = hxsBoolValue(c, a.boolean && b.boolean);
            return;
        }
        case BinOp.Or: {
            infoOf(c, node).value = hxsBoolValue(c, a.boolean || b.boolean);
            return;
        }
        case BinOp.Eq, BinOp.Ne, BinOp.Lt, BinOp.Le, BinOp.Gt, BinOp.Ge: {
            let cmp: i32 = 0;
            if (a.kind == HxValueBool as u8) {
                const x: i32 = a.boolean ? 1 : 0;
                const y: i32 = b.boolean ? 1 : 0;
                cmp = x - y;
            } else if (a.kind == HxValueFloat as u8 || b.kind == HxValueFloat as u8) {
                const x = asFloat(a);
                const y = asFloat(b);
                cmp = x < y ? -1 : x > y ? 1 : 0;
            } else if (a.kind == HxValueInt as u8) {
                cmp = a.integer < b.integer ? -1 : a.integer > b.integer ? 1 : 0;
            } else {
                return;
            }
            const result = switch (op) {
                case BinOp.Eq: cmp == 0;
                case BinOp.Ne: cmp != 0;
                case BinOp.Lt: cmp < 0;
                case BinOp.Le: cmp <= 0;
                case BinOp.Gt: cmp > 0;
                default: cmp >= 0;
            };
            infoOf(c, node).value = hxsBoolValue(c, result);
            return;
        }
        default: {}
    }
    if (hxsIsFloat(c, operandType)) {
        const x = asFloat(a);
        const y = asFloat(b);
        let r: f64 = 0;
        switch (op) {
            case BinOp.Add: r = x + y;
            case BinOp.Sub: r = x - y;
            case BinOp.Mul: r = x * y;
            case BinOp.Div: r = x / y;
            default: return;
        }
        infoOf(c, node).value = hxsFloatValue(c, r);
        return;
    }
    let r: i128 = 0;
    if (hxsFoldInt(c, node, opNumber, a.integer, b.integer, operandType, &r)) infoOf(c, node).value = hxsIntValue(c, r);
}
