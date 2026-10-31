/**
 * Imports
 */

import * as fmt from "std/fmt";
import { ArrayList } from "std/list";
import { cAllocator } from "std/heap";
import { equal, startsWith, indexOf } from "std/text";
import * as sys from "@modules/driver/bindings/sys.binding";
import * as os from "@modules/driver/components/os.component";
import { hxFatalMessage } from "@components/memory.component";
import { Reserved } from "@modules/driver/constants/translate.constant";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { clangResourceDir, macosSdk } from "@modules/driver/components/libc.component";
import { allocCString, toCString, fromCString, add, strings } from "@modules/driver/components/os.component";
import { TranslateOptions, TranslateContext } from "@modules/driver/components/structs/translate-component.struct";
import { CArgv, FieldWalk, EnumWalk, TopWalk } from "@modules/driver/components/structs/translate-component.struct";

/**
 * Stops the compiler with an out of memory error.
 *
 * @remarks
 * Every failed allocation in the translator ends here, since a run without memory cannot produce a usable binding.
 *
 * @since 1.0.0
 */

function outOfMemory(): noreturn {
    hxFatalMessage("out of memory");
}

/**
 * Appends a text to a builder.
 *
 * @param b - The builder
 * @param text - The text to append
 *
 * @remarks
 * A failed append stops the compiler through {@link outOfMemory}, so the callers never handle an error.
 *
 * @since 1.0.0
 */

function put(b: *fmt.Builder, text: Format): void {
    b.append(text) catch outOfMemory();
}

/**
 * Checks whether a list has a name.
 *
 * @param names - The list to look in
 * @param name - The name to find
 * @returns `true` when the list has an equal name
 *
 * @remarks
 * It is a linear search, which is fast enough for the name lists of one header.
 *
 * @since 1.0.0
 */

function hasName(names: readonly *Strings, name: string): bool {
    for (const item of names.items) {
        if (equal(item, name)) return true;
    }
    return false;
}

/**
 * Adds a copy of a name to a list that does not have it yet.
 *
 * @param names - The list
 * @param name - The name to add
 *
 * @remarks
 * The copy is NUL-terminated and never freed, so the name outlives the libclang string that it came from.
 *
 * @since 1.0.0
 */

function addName(names: *Strings, name: string): void {
    if (!hasName(names, name)) add(names, allocCString(`${name}`));
}

/**
 * Copies a libclang string and disposes of the original.
 *
 * @param s - The libclang string
 * @returns The copy
 *
 * @remarks
 * libclang owns the text of a `CXString` until `clang_disposeString`, so the copy is what stays valid afterward.
 *
 * @since 1.0.0
 */

function clangString(s: sys.CXString): string {
    const text = allocCString(`${fromCString(sys.clang_getCString(s))}`);
    sys.clang_disposeString(s);
    return text;
}

/**
 * Gives a C name that is a Helix keyword or built-in name a `_` after it.
 *
 * @param name - The C name
 * @returns The name, with a `_` after it when it is in {@link Reserved} or names an integer type such as `i32`
 *
 * @remarks
 * Only a name that would clash changes, and the `_` keeps it readable next to the C name.
 * A name such as `i32x` is not an integer type, so it stays as it is.
 *
 * @since 1.0.0
 */

function helixName(name: string): string {
    let clash = false;
    for (const word of Reserved) {
        if (equal(name, word)) clash = true;
    }
    if (name.len >= 2 && (name[0] == 'i' || name[0] == 'u') && name[1] >= '1' && name[1] <= '9') {   // i32, u8, ...
        clash = true;
        for (const c of name[1..]) {
            if (c < '0' || c > '9') clash = false;
        }
    }
    if (clash) return allocCString(`${name}_`);
    return name;
}

/**
 * Checks whether a path is inside a folder.
 *
 * @param path - The path
 * @param dir - The folder
 * @returns `true` when the path starts with the folder and a `/`
 *
 * @remarks
 * The `/` check keeps a sibling folder such as `include2` from counting as inside `include`.
 * The folder itself does not count as inside.
 *
 * @since 1.0.0
 */

function under(path: string, dir: string): bool {
    return startsWith(path, dir) && path.len > dir.len && path[dir.len] == '/';
}

/**
 * Checks whether a declaration comes from a header that this run translates.
 *
 * @param tc - The state of the run
 * @param cursor - The declaration
 * @returns `true` for a declaration in one of the headers of the run
 *
 * @remarks
 * A declaration without a file, such as `__builtin_va_list`, is built into the compiler and never counts.
 * With `all` every other one counts, with `wholeDir` one under the folder of the input,
 * and otherwise one in the `ownFiles` list of the run.
 *
 * @since 1.0.0
 */

function isOwn(tc: *TranslateContext, cursor: sys.CXCursor): bool {
    let file: sys.CXFile = null;
    sys.clang_getExpansionLocation(sys.clang_getCursorLocation(cursor), &file, null, null, null);
    if (file == null) return false;   // built into the compiler, like `__builtin_va_list`: never declared in the output
    if (tc.all) return true;
    const real = os.realPath(clangString(sys.clang_getFileName(file)));
    if (real == null) return false;
    return tc.wholeDir ? under(real, tc.ownDir) : hasName(&tc.ownFiles, real);
}

/**
 * Gives the run state that a libclang visitor gets as its client data.
 *
 * @param data - The client data
 * @returns The state of the run
 *
 * @remarks
 * It only casts the pointer, so the data must be the pointer that the run passed to libclang.
 *
 * @since 1.0.0
 */

function contextOf(data: ?u8[*]): *TranslateContext {
    unsafe {
        return @ptrCast(*TranslateContext, data);
    }
}

/**
 * Gives the field walk that {@link visitField} gets as its client data.
 *
 * @param data - The client data
 * @returns The field walk
 *
 * @remarks
 * It only casts the pointer, so the data must be the pointer that {@link emitRecord} passed to libclang.
 *
 * @since 1.0.0
 */

function fieldWalk(data: ?u8[*]): *FieldWalk {
    unsafe {
        return @ptrCast(*FieldWalk, data);
    }
}

/**
 * Gives the enum walk that {@link visitConstant} gets as its client data.
 *
 * @param data - The client data
 * @returns The enum walk
 *
 * @remarks
 * It only casts the pointer, so the data must be the pointer that {@link emitEnumConstants} passed to libclang.
 *
 * @since 1.0.0
 */

function enumWalk(data: ?u8[*]): *EnumWalk {
    unsafe {
        return @ptrCast(*EnumWalk, data);
    }
}

/**
 * Gives the top-level walk that {@link visitTop} gets as its client data.
 *
 * @param data - The client data
 * @returns The top-level walk
 *
 * @remarks
 * It only casts the pointer, so the data must be the pointer that {@link translateC} passed to libclang.
 *
 * @since 1.0.0
 */

function topWalk(data: ?u8[*]): *TopWalk {
    unsafe {
        return @ptrCast(*TopWalk, data);
    }
}

/**
 * Gives the tokens that `clang_tokenize` returns as an array.
 *
 * @param tokens - The pointer to the first token
 * @returns The tokens as an array
 *
 * @remarks
 * It only casts the pointer, so indexing it past the count from `clang_tokenize` is out of bounds.
 *
 * @since 1.0.0
 */

function tokenArray(tokens: ?*sys.CXToken): sys.CXToken[*] {
    unsafe {
        return @ptrCast(sys.CXToken[*], tokens);
    }
}

/**
 * Gives the kind of a token.
 *
 * @param tokens - The tokens
 * @param i - The index of the token
 * @returns The `CXTokenKind` of the token
 *
 * @remarks
 * It reads the token at the index without a bounds check, so the index must be below the token count.
 *
 * @since 1.0.0
 */

function tokenKind(tokens: sys.CXToken[*], i: u32): u32 {
    unsafe {
        return sys.clang_getTokenKind(tokens[i]);
    }
}

/**
 * Gives a C argument array the read-only type that libclang takes.
 *
 * @param argv - The argument array
 * @returns The same array as a {@link CArgv}
 *
 * @remarks
 * It only casts the pointer, since libclang declares the strings as `const char *const *`.
 *
 * @since 1.0.0
 */

function readonlyArgs(argv: (?u8[*])[*]): CArgv {
    unsafe {
        return @ptrCast(CArgv, argv);
    }
}

/**
 * Passes a pointer to a libclang visitor as its client data.
 *
 * @typeParam T - The type that the pointer points to
 * @param p - The pointer
 * @returns The same pointer as untyped client data
 *
 * @remarks
 * The pointer must stay valid until the visit that receives it returns, so it usually points at a local of the caller.
 *
 * @since 1.0.0
 */

function clientData<T>(p: *T): ?u8[*] {
    unsafe {
        return @ptrCast(?u8[*], p);
    }
}

/**
 * Collects the headers that the input includes directly from its own folder or below.
 *
 * @param file - The included file
 * @param _stack - The include stack, which it does not use
 * @param depth - The depth of the inclusion, where 1 is a header that the input includes
 * @param data - The run state as client data
 *
 * @remarks
 * The input itself is depth 0, which the run adds up front.
 *
 * @since 1.0.0
 */

extern "C" function visitInclusion(file: ?u8[*], _stack: ?*sys.CXSourceLocation, depth: u32, data: ?u8[*]): void {
    const tc = contextOf(data);
    if (depth != 1) return;   // depth 0 is the input itself, which is added up front
    const real = os.realPath(clangString(sys.clang_getFileName(file)));
    if (real == null) return;
    if (under(real, tc.ownDir)) addName(&tc.ownFiles, real);
}

/**
 * Checks whether a record has no name of its own.
 *
 * @param spelling - The spelling of the record
 * @param decl - The declaration of the record
 * @returns `true` when the spelling is empty or has a space, or when libclang calls the record anonymous
 *
 * @remarks
 * clang spells an unnamed record as `struct (unnamed at file.h:3:9)` or something similar.
 *
 * @since 1.0.0
 */

function unnamed(spelling: string, decl: sys.CXCursor): bool {
    return spelling.len == 0 || os.firstIndex(spelling, ' ') != null || sys.clang_Cursor_isAnonymous(decl) != 0;
}

/**
 * Gives the Helix name of a struct, union, or enum.
 *
 * @param tc - The state of the run
 * @param decl - The declaration
 * @returns The tag, with a `_` after a reserved one, or `_anon<n>` for an unnamed record
 *
 * @remarks
 * A tag that a function or variable also takes gets `struct_` before it, as `struct stat` next to `int stat(...)` does.
 *
 * @since 1.0.0
 */

function recordName(tc: *TranslateContext, decl: sys.CXCursor): string {
    const name = clangString(sys.clang_getCursorSpelling(decl));
    if (unnamed(name, decl)) {
        const made = allocCString(`_anon${tc.anonymous}`);
        tc.anonymous++;
        return made;
    }
    const escaped = helixName(name);
    if (hasName(&tc.functionNames, escaped)) return allocCString(`struct_${escaped}`);   // `struct stat` next to `int stat(...)`
    return escaped;
}

/**
 * Gives the Helix name of a system typedef that has one.
 *
 * @param name - The C name of the typedef
 * @returns The Helix type, such as `usize` for `size_t` and `u32` for `uint32_t`, or `null` for any other name
 *
 * @remarks
 * The fixed table maps each C name to its Helix type, so these typedefs never get an alias in the output.
 *
 * @since 1.0.0
 */

function knownTypedef(name: string): ?string {
    const known: string[30] = [
        "size_t", "usize", "ssize_t", "isize", "ptrdiff_t", "isize", "intptr_t", "isize", "uintptr_t", "usize",
        "int8_t", "i8", "int16_t", "i16", "int32_t", "i32", "int64_t", "i64", "uint8_t", "u8", "uint16_t", "u16",
        "uint32_t", "u32", "uint64_t", "u64", "bool", "bool", "_Bool", "bool",
    ];
    let i: usize = 0;
    while (i < known.len) {
        if (equal(name, known[i])) return known[i + 1];
        i += 2;
    }
    return null;
}

/**
 * Checks whether a libclang type kind is a function type.
 *
 * @param kind - The `CXTypeKind`
 * @returns `true` for a function with or without a prototype
 *
 * @remarks
 * A K&R declaration such as `int f()` has `CXType_FunctionNoProto`, which still counts here.
 *
 * @since 1.0.0
 */

function isFunctionKind(kind: u32): bool {
    return kind == sys.CXType_FunctionProto || kind == sys.CXType_FunctionNoProto;
}

/**
 * Writes the Helix spelling of a C function type, which calls with the C calling convention.
 *
 * @param tc - The state of the run
 * @param fn - The function type
 * @param out - The builder that gets the text, such as `extern "C" (a0: i32, a1: ?u8[*], ...) => i32`
 * @param why - Where the reason goes when Helix cannot express the type
 * @returns `false` with `why` set for a function without a prototype or a parameter that Helix cannot express
 *
 * @remarks
 * The parameters are named `a0`, `a1`, and so on, since a function type carries no parameter names.
 * A variadic type ends in `...`, and a `void` result is written as `void`.
 *
 * @since 1.0.0
 */

function functionTypeText(tc: *TranslateContext, fn: sys.CXType, out: *fmt.Builder, why: *string): bool {
    if (fn.kind == sys.CXType_FunctionNoProto) {
        *why = "a function type without a prototype (`int f()`)";
        return false;
    }
    put(out, "extern \"C\" (");
    const count = sys.clang_getNumArgTypes(fn);
    let i: i32 = 0;
    while (i < count) {
        put(out, `${i > 0 ? ", " : ""}a${i}: `);
        if (!typeText(tc, sys.clang_getArgType(fn, i as u32), out, why)) return false;
        i++;
    }
    if (sys.clang_isFunctionTypeVariadic(fn) != 0) put(out, `${count > 0 ? ", ..." : "..."}`);
    put(out, ") => ");
    const ret = sys.clang_getResultType(fn);
    if (ret.kind == sys.CXType_Void) put(out, "void");
    else if (!typeText(tc, ret, out, why)) return false;
    return true;
}

/**
 * Finds the record that a type names, through typedefs and `struct x` spellings.
 *
 * @param type - The type
 * @returns The declaration of the record, or a null cursor when the type is not a record
 *
 * @remarks
 * It looks at the canonical type, so every typedef and elaborated spelling resolves to the same record.
 *
 * @since 1.0.0
 */

function recordOf(type: sys.CXType): sys.CXCursor {
    const canonical = sys.clang_getCanonicalType(type);
    if (canonical.kind != sys.CXType_Record) return sys.clang_getNullCursor();
    return sys.clang_getTypeDeclaration(canonical);
}

/**
 * Checks whether a cursor is the null cursor.
 *
 * @param cursor - The cursor
 * @returns `true` for the null cursor
 *
 * @remarks
 * libclang returns the null cursor where nothing matches, as {@link recordOf} does for a type that is not a record.
 *
 * @since 1.0.0
 */

function isNull(cursor: sys.CXCursor): bool {
    return sys.clang_Cursor_isNull(cursor) != 0;
}

/**
 * Writes the name of a struct or union that the output uses.
 *
 * @param tc - The state of the run
 * @param type - The type that names the record
 * @param out - The builder that gets the name
 *
 * @remarks
 * A typedef name such as `FILE` or `z_stream` reads best, so it stands when the typedef comes from another header
 * or has the same name as the record.
 * A record from another header is queued in the `pendingOpaque` list to be declared opaque at the end.
 * A record of these headers that the output has not declared yet is queued in the `pending` list.
 *
 * @since 1.0.0
 */

function recordRef(tc: *TranslateContext, type: sys.CXType, out: *fmt.Builder): void {
    let named = type;
    while (named.kind == sys.CXType_Elaborated) named = sys.clang_Type_getNamedType(named);
    if (named.kind == sys.CXType_Typedef) {   // `FILE`, `z_stream`: the typedef's name reads best
        const decl = sys.clang_getTypeDeclaration(named);
        const name = clangString(sys.clang_getCursorSpelling(decl));
        const rec = recordOf(type);
        const tag = clangString(sys.clang_getCursorSpelling(rec));
        const same = equal(name, tag) || unnamed(tag, rec);
        if (!isOwn(tc, decl) || same) {
            const escaped = helixName(name);
            put(out, `${escaped}`);
            if (!isOwn(tc, decl) && !isOwn(tc, rec)) addName(&tc.pendingOpaque, escaped);
            return;
        }
    }
    const rec = recordOf(type);
    const name = recordName(tc, rec);
    put(out, `${name}`);
    if (!isOwn(tc, rec)) addName(&tc.pendingOpaque, name);
    else if (!hasName(&tc.emitted, name)) tc.pending.append(rec) catch outOfMemory();
}

/**
 * Writes a nullable pointer to many values of a Helix type.
 *
 * @param out - The builder that gets the text
 * @param inner - The Helix type of the values
 * @param isReadonly - Whether the values are read-only
 *
 * @remarks
 * The text is `?T[*]` or `?readonly T[*]`.
 * An optional or function type inside needs parentheses, as in `?(?u8[*])[*]`.
 *
 * @since 1.0.0
 */

function manyPointer(out: *fmt.Builder, inner: string, isReadonly: bool): void {
    const paren = (inner.len > 0 && inner[0] == '?') || indexOf(inner, "=>") != null;
    put(out, `?${isReadonly ? "readonly " : ""}${paren ? "(" : ""}${inner}${paren ? ")" : ""}[*]`);
}

/**
 * Writes the Helix spelling of a C type.
 *
 * @param tc - The state of the run
 * @param type - The C type
 * @param out - The builder that gets the text
 * @param why - Where the reason goes when Helix cannot express the type
 * @returns `false` with `why` set when Helix cannot express the type, so the declaration that uses it becomes a comment
 *
 * @remarks
 * - **Numbers** - C integers become `i` or `u` types of their size, `char` becomes `u8`, and floats become `f32`
 *   or `f64`, while `long double`, `_Float16`, and `_Complex` have no Helix type
 * - **Typedefs** - a known system typedef has a Helix name, a typedef of these headers keeps its name,
 *   and any other one is written as what it stands for
 * - **Enums** - an enum defined in these headers keeps its name and is written when the top level does not reach it,
 *   and any other one is written as its integer type
 * - **Pointers** - every pointer is nullable, since C does not say: `?*T` to a struct, `?u8[*]` for `void *`
 *   and for an enum without a definition, a function type to a function, and `?T[*]` to anything else,
 *   since C also does not say whether it points to one value or many, while `const` becomes `readonly`
 * - **Arrays** - an array with a length becomes `T[n]`, and one without a length has no Helix type
 *
 * Vectors, Apple blocks, and every other type that Helix cannot express set `why`.
 *
 * @since 1.0.0
 */

function typeText(tc: *TranslateContext, type: sys.CXType, out: *fmt.Builder, why: *string): bool {
    const k = type.kind;
    if (k == sys.CXType_Elaborated) return typeText(tc, sys.clang_Type_getNamedType(type), out, why);
    if (k == sys.CXType_Attributed) return typeText(tc, sys.clang_Type_getModifiedType(type), out, why);
    if (k == sys.CXType_Typedef) {
        const decl = sys.clang_getTypeDeclaration(type);
        const name = clangString(sys.clang_getCursorSpelling(decl));
        const underlying = sys.clang_getTypedefDeclUnderlyingType(decl);
        if (const known = knownTypedef(name)) {
            put(out, `${known}`);
            return true;
        }
        if (!isNull(recordOf(type))) {
            recordRef(tc, type, out);
            return true;
        }
        if (isOwn(tc, decl)) {
            // named where it's declared, unless that declaration is skipped (then so is everything using it)
            let check = fmt.Builder.init(cAllocator());
            defer check.deinit();
            const canonical = sys.clang_getCanonicalType(underlying);
            const ok = isFunctionKind(canonical.kind) ? functionTypeText(tc, canonical, &check, why)
                                                      : typeText(tc, underlying, &check, why);
            if (ok) put(out, `${helixName(name)}`);
            return ok;
        }
        return typeText(tc, underlying, out, why);   // a system typedef of a number: what it stands for
    }
    if (k == sys.CXType_Void) {
        *why = "`void` as a value";
        return false;
    }
    if (k == sys.CXType_Bool) {
        put(out, "bool");
        return true;
    }
    if (k == sys.CXType_Char_S || k == sys.CXType_Char_U || k == sys.CXType_UChar) {
        put(out, "u8");
        return true;
    }
    if (k == sys.CXType_SChar) {
        put(out, "i8");
        return true;
    }
    if (k == sys.CXType_Short || k == sys.CXType_Int || k == sys.CXType_Long || k == sys.CXType_LongLong || k == sys.CXType_Int128) {
        put(out, `i${sys.clang_Type_getSizeOf(type) * 8}`);
        return true;
    }
    if (k == sys.CXType_UShort || k == sys.CXType_UInt || k == sys.CXType_ULong || k == sys.CXType_ULongLong
            || k == sys.CXType_UInt128 || k == sys.CXType_Char16 || k == sys.CXType_Char32 || k == sys.CXType_WChar) {
        put(out, `${k == sys.CXType_WChar ? "i" : "u"}${sys.clang_Type_getSizeOf(type) * 8}`);
        return true;
    }
    if (k == sys.CXType_Float) {
        put(out, "f32");
        return true;
    }
    if (k == sys.CXType_Double) {
        put(out, "f64");
        return true;
    }
    if (k == sys.CXType_LongDouble) {
        *why = "`long double`, which Helix doesn't have";
        return false;
    }
    if (k == sys.CXType_Enum) {
        const decl = sys.clang_getTypeDeclaration(type);
        const def = sys.clang_getCursorDefinition(decl);
        const name = recordName(tc, decl);
        // its own name when it's defined in these headers; written now if the top level doesn't reach it
        const named = !isNull(def) && isOwn(tc, decl) && !startsWith(name, "_anon");
        if (named && !hasName(&tc.emitted, name)) emitEnumDecl(tc, def, null);
        if (named) {
            put(out, `${name}`);
            return true;
        }
        return typeText(tc, sys.clang_getEnumDeclIntegerType(decl), out, why);
    }
    if (k == sys.CXType_Record) {
        recordRef(tc, type, out);
        return true;
    }
    if (k == sys.CXType_Pointer) {
        const pointee = sys.clang_getPointeeType(type);
        const isReadonly = sys.clang_isConstQualifiedType(pointee) != 0;
        const canonical = sys.clang_getCanonicalType(pointee);
        if (isFunctionKind(canonical.kind)) {
            put(out, "?");
            return functionTypeText(tc, canonical, out, why);
        }
        const unknownEnum = canonical.kind == sys.CXType_Enum
                         && isNull(sys.clang_getCursorDefinition(sys.clang_getTypeDeclaration(canonical)));
        if (canonical.kind == sys.CXType_Void || unknownEnum) {   // untyped, or an enum declared but never defined
            put(out, `${isReadonly ? "?readonly u8[*]" : "?u8[*]"}`);
            return true;
        }
        if (canonical.kind == sys.CXType_Record) {
            put(out, `${isReadonly ? "?readonly *" : "?*"}`);
            recordRef(tc, pointee, out);
            return true;
        }
        let inner = fmt.Builder.init(cAllocator());
        defer inner.deinit();
        if (!typeText(tc, pointee, &inner, why)) return false;
        manyPointer(out, inner.text(), isReadonly);
        return true;
    }
    if (k == sys.CXType_ConstantArray) {
        let inner = fmt.Builder.init(cAllocator());
        defer inner.deinit();
        if (!typeText(tc, sys.clang_getArrayElementType(type), &inner, why)) return false;
        const text = inner.text();
        const paren = (text.len > 0 && text[0] == '?') || indexOf(text, "=>") != null;
        put(out, `${paren ? "(" : ""}${text}${paren ? ")" : ""}[${sys.clang_getArraySize(type)}]`);
        return true;
    }
    if (k == sys.CXType_IncompleteArray) {
        *why = "an array without a length (a flexible array member)";
        return false;
    }
    if (isFunctionKind(k)) return functionTypeText(tc, type, out, why);
    if (k == sys.CXType_Vector || k == sys.CXType_ExtVector) {
        *why = "a SIMD vector type";
        return false;
    }
    if (k == sys.CXType_BlockPointer) {
        *why = "an Apple block (`^`), which only Objective-C and clang's C extension can make";
        return false;
    }
    if (k == sys.CXType_Half || k == sys.CXType_Float16) {
        *why = "`_Float16`, which Helix doesn't have";
        return false;
    }
    if (k == sys.CXType_Complex) {
        *why = "a `_Complex` number";
        return false;
    }
    const canonical = sys.clang_getCanonicalType(type);
    if (canonical.kind != k) return typeText(tc, canonical, out, why);
    *why = "a C type Helix can't express";
    return false;
}

/**
 * Leaves a declaration out, with a comment that says why, where it would have gone.
 *
 * @param tc - The state of the run
 * @param what - The kind of declaration, such as `function` or `typedef`
 * @param name - The C name
 * @param why - The reason
 *
 * @remarks
 * The comment reads `// skipped <what> \`<name>\`: <why>`, so the reader of the binding sees the gap.
 * It also counts the skip for the summary at the end of the run.
 *
 * @since 1.0.0
 */

function skip(tc: *TranslateContext, what: string, name: string, why: string): void {
    put(&tc.out, `// skipped ${what} \`${name}\`: ${why}\n\n`);
    tc.skipped++;
}

/**
 * Writes the brief doc comment of a declaration, when it has one.
 *
 * @param tc - The state of the run
 * @param cursor - The declaration
 *
 * @remarks
 * It uses the brief comment that libclang extracts, which is the first sentence or paragraph of the C comment.
 * A declaration without a comment writes nothing.
 *
 * @since 1.0.0
 */

function docComment(tc: *TranslateContext, cursor: sys.CXCursor): void {
    const doc = clangString(sys.clang_Cursor_getBriefCommentText(cursor));
    if (doc.len > 0) put(&tc.out, `/** ${doc} */\n`);
}

/**
 * Writes one field of a struct into its field walk.
 *
 * @param field - The field
 * @param data - The field walk as client data
 * @returns `CXVisit_Continue`, or `CXVisit_Break` after a bit field or a type that Helix cannot express
 *
 * @remarks
 * An unnamed member such as `union { ... };` is spelled like `union glob_t::(anonymous at glob.h:58:2)`,
 * so it gets an `_anon<n>` name.
 * A field of an anonymous record type, such as `struct { int x; } pos;`, gets a struct of its own,
 * named after the owner and the field, as in `owner_pos`.
 *
 * @since 1.0.0
 */

extern "C" function visitField(field: sys.CXCursor, data: ?u8[*]): u32 {
    const w = fieldWalk(data);
    if (sys.clang_Cursor_isBitField(field) != 0) {
        w.why = "bit fields";
        w.ok = false;
        return sys.CXVisit_Break;
    }
    const fieldName = clangString(sys.clang_getCursorSpelling(field));
    const type = sys.clang_getCursorType(field);
    const rec = recordOf(type);
    // an unnamed member (`union { ... };`) is spelled like "union glob_t::(anonymous at glob.h:58:2)"
    let escaped = "";
    if (fieldName.len == 0 || os.firstIndex(fieldName, ' ') != null || os.firstIndex(fieldName, ':') != null
            || os.firstIndex(fieldName, '(') != null) {
        escaped = allocCString(`_anon${w.anon}`);
        w.anon++;
    } else {
        escaped = helixName(fieldName);
    }

    let text = fmt.Builder.init(cAllocator());
    defer text.deinit();
    if (!isNull(rec) && sys.clang_Cursor_isAnonymous(rec) != 0) {
        // `struct { int x; } pos;` or an anonymous `union { ... };`: its own struct, named after the field
        const nested = allocCString(`${w.owner}_${escaped}`);
        emitRecord(w.tc, rec, nested);
        put(&text, `${nested}`);
    } else if (!typeText(w.tc, type, &text, &w.why)) {
        w.ok = false;
        return sys.CXVisit_Break;
    }
    put(&w.fields, `    ${escaped}: ${text.text()},\n`);
    return sys.CXVisit_Continue;
}

/**
 * Writes `export extern "C" struct name { ... }` for a struct or union.
 *
 * @param tc - The state of the run
 * @param decl - The declaration of the record
 * @param name - The Helix name of the record
 *
 * @remarks
 * A union, a struct with bit fields, and a struct with a field that Helix cannot express keep only their size
 * and alignment, as an array of the integer of that alignment.
 * A struct without a definition is opaque: it has no fields and is only used behind pointers.
 * The nested records that the fields need are written before it.
 *
 * @since 1.0.0
 */

function emitRecord(tc: *TranslateContext, decl: sys.CXCursor, name: string): void {
    if (hasName(&tc.emitted, name)) return;
    addName(&tc.emitted, name);
    const type = sys.clang_getCursorType(decl);
    const size = sys.clang_Type_getSizeOf(type);
    const align = sys.clang_Type_getAlignOf(type);
    const isUnion = sys.clang_getCursorKind(decl) == sys.CXCursor_UnionDecl;

    const saved = tc.out;   // nested records are written before this one
    tc.out = fmt.Builder.init(cAllocator());
    let w = FieldWalk { tc, fields: fmt.Builder.init(cAllocator()), why: "", ok: true, anon: 0, owner: name };
    defer w.fields.deinit();
    if (size >= 0 && !isUnion) void sys.clang_Type_visitFields(type, visitField, clientData(&w));
    let nested = tc.out;
    tc.out = saved;
    put(&tc.out, `${nested.text()}`);
    nested.deinit();

    docComment(tc, decl);
    if (size < 0) {
        put(&tc.out, `/** Opaque in C: use it only through pointers. */\nexport extern "C" struct ${name} {}\n\n`);
    } else if (isUnion || !w.ok) {
        const unit = align >= 8 ? "u64" : align == 4 ? "u32" : align == 2 ? "u16" : "u8";
        const unitSize: i64 = align >= 8 ? 8 : align == 4 ? 4 : align == 2 ? 2 : 1;
        put(&tc.out, `/** C ${isUnion ? "union" : "struct"} with ${isUnion ? "overlapping fields" : w.why}: only its size (${size} bytes) and alignment (${align}) are kept. */\n`);
        put(&tc.out, `export extern "C" struct ${name} {\n    _bytes: ${unit}[${size / unitSize}],\n}\n\n`);
    } else {
        put(&tc.out, `export extern "C" struct ${name} {\n${w.fields.text()}}\n\n`);
    }
}

/**
 * Writes one enum member as a constant.
 *
 * @param cursor - The child of the enum
 * @param _parent - The enum, which it does not use
 * @param data - The enum walk as client data
 * @returns `CXChildVisit_Continue`
 *
 * @remarks
 * A member whose name is already declared is left out.
 *
 * @since 1.0.0
 */

extern "C" function visitConstant(cursor: sys.CXCursor, _parent: sys.CXCursor, data: ?u8[*]): u32 {
    const w = enumWalk(data);
    if (sys.clang_getCursorKind(cursor) != sys.CXCursor_EnumConstantDecl) return sys.CXChildVisit_Continue;
    const escaped = helixName(clangString(sys.clang_getCursorSpelling(cursor)));
    if (hasName(&w.tc.emitted, escaped)) return sys.CXChildVisit_Continue;
    addName(&w.tc.emitted, escaped);
    if (w.signed) put(&w.tc.out, `export const ${escaped}: ${w.type} = ${sys.clang_getEnumConstantDeclValue(cursor)};\n`);
    else put(&w.tc.out, `export const ${escaped}: ${w.type} = ${sys.clang_getEnumConstantDeclUnsignedValue(cursor)};\n`);
    return sys.CXChildVisit_Continue;
}

/**
 * Writes a constant for each member of an enum.
 *
 * @param tc - The state of the run
 * @param decl - The declaration of the enum
 * @param type - The Helix type of the constants
 *
 * @remarks
 * The integer type of the enum decides whether the values are read as signed or unsigned,
 * so a negative member keeps its sign.
 * A blank line follows the constants.
 *
 * @since 1.0.0
 */

function emitEnumConstants(tc: *TranslateContext, decl: sys.CXCursor, type: string): void {
    const k = sys.clang_getCanonicalType(sys.clang_getEnumDeclIntegerType(decl)).kind;
    const signed = k == sys.CXType_Int || k == sys.CXType_Long || k == sys.CXType_LongLong || k == sys.CXType_Short
                || k == sys.CXType_SChar || k == sys.CXType_Char_S;
    let w = EnumWalk { tc, type, signed };
    void sys.clang_visitChildren(decl, visitConstant, clientData(&w));
    put(&tc.out, "\n");
}

/**
 * Writes an enum as an integer type alias and a constant for each member.
 *
 * @param tc - The state of the run
 * @param decl - The declaration of the enum
 * @param alias - The typedef name of an unnamed enum, or `null` to use the tag
 *
 * @remarks
 * It covers `typedef enum { A, B } name;` and `enum name { ... };`.
 * An unnamed enum without a typedef has no alias, so its constants take its integer type.
 *
 * @since 1.0.0
 */

function emitEnumDecl(tc: *TranslateContext, decl: sys.CXCursor, alias: ?string): void {
    const name = alias ?? recordName(tc, decl);
    const anonymous = alias == null && startsWith(name, "_anon");
    let base = fmt.Builder.init(cAllocator());
    defer base.deinit();
    let why = "";
    if (!typeText(tc, sys.clang_getEnumDeclIntegerType(decl), &base, &why)) {
        skip(tc, "enum", name, why);
        return;
    }
    if (!anonymous && !hasName(&tc.emitted, name)) {
        docComment(tc, decl);
        put(&tc.out, `export type ${name} = ${base.text()};\n`);
        addName(&tc.emitted, name);
    }
    emitEnumConstants(tc, decl, anonymous ? allocCString(`${base.text()}`) : name);
}

/**
 * Writes `export extern "C" function` for a C function.
 *
 * @param tc - The state of the run
 * @param cursor - The declaration of the function
 *
 * @remarks
 * A `static` or `inline` function has no symbol to link to,
 * and a function named like a Helix keyword cannot be named from Helix yet, so both are left out.
 * So is a function without a prototype, `int f()` rather than `int f(void)`.
 * An array parameter such as `double v[]` or `int v[3]` is a pointer in C, so it becomes a many-pointer.
 * An unnamed parameter becomes `a<n>`, and a parameter name that repeats gets its index after it.
 *
 * @since 1.0.0
 */

function emitFunction(tc: *TranslateContext, cursor: sys.CXCursor): void {
    const cName = clangString(sys.clang_getCursorSpelling(cursor));
    if (sys.clang_Cursor_getStorageClass(cursor) == sys.CX_SC_Static || sys.clang_Cursor_isFunctionInlined(cursor) != 0) {
        skip(tc, "function", cName, "`static` and `inline` functions have no symbol to link to");
        return;
    }
    const name = helixName(cName);
    if (!equal(name, cName)) {   // a Helix keyword: the C symbol can't be named from Helix yet
        skip(tc, "function", cName, "its name is a Helix keyword");
        return;
    }
    if (hasName(&tc.emitted, name)) return;
    const fn = sys.clang_getCursorType(cursor);
    if (fn.kind == sys.CXType_FunctionNoProto) {
        skip(tc, "function", cName, "it has no prototype (`int f()` rather than `int f(void)`)");
        return;
    }
    let text = fmt.Builder.init(cAllocator());
    defer text.deinit();
    let why = "";
    let ok = true;
    const count = sys.clang_Cursor_getNumArguments(cursor);
    let params = strings();
    defer params.deinit();
    let i: i32 = 0;
    while (i < count && ok) {
        const arg = sys.clang_Cursor_getArgument(cursor, i as u32);
        const argName = clangString(sys.clang_getCursorSpelling(arg));
        let escaped = argName.len > 0 ? helixName(argName) : allocCString(`a${i}`);
        if (hasName(&params, escaped) || equal(escaped, name)) escaped = allocCString(`${escaped}${i}`);
        addName(&params, escaped);
        put(&text, `${i > 0 ? ", " : ""}${escaped}: `);
        const argType = sys.clang_getCursorType(arg);
        if (argType.kind == sys.CXType_ConstantArray || argType.kind == sys.CXType_IncompleteArray) {
            // `double v[]` and `int v[3]` as parameters are pointers in C
            const elem = sys.clang_getArrayElementType(argType);
            let inner = fmt.Builder.init(cAllocator());
            ok = typeText(tc, elem, &inner, &why);
            if (ok) manyPointer(&text, inner.text(), sys.clang_isConstQualifiedType(elem) != 0);
            inner.deinit();
        } else {
            ok = typeText(tc, argType, &text, &why);
        }
        i++;
    }
    if (ok && sys.clang_isFunctionTypeVariadic(fn) != 0) put(&text, `${count > 0 ? ", ..." : "..."}`);
    let ret = fmt.Builder.init(cAllocator());
    defer ret.deinit();
    const result = sys.clang_getResultType(fn);
    if (ok) {
        if (result.kind == sys.CXType_Void) put(&ret, "void");
        else ok = typeText(tc, result, &ret, &why);
    }
    if (ok) {
        docComment(tc, cursor);
        put(&tc.out, `export extern "C" function ${name}(${text.text()}): ${ret.text()};\n\n`);
        addName(&tc.emitted, name);
    } else {
        skip(tc, "function", cName, why);
    }
}

/**
 * Writes `export type name = ...` for a typedef.
 *
 * @param tc - The state of the run
 * @param cursor - The declaration of the typedef
 *
 * @remarks
 * `typedef struct { ... } name;` and `typedef struct name name;` write the struct itself under this name,
 * and a typedef of an unnamed enum writes the enum under this name.
 * A typedef of a function type, rather than a pointer to one, is left out,
 * since its uses become `?extern "C" (...) => ...` where they appear.
 * A known system typedef such as `size_t` is never written.
 *
 * @since 1.0.0
 */

function emitTypedef(tc: *TranslateContext, cursor: sys.CXCursor): void {
    const name = helixName(clangString(sys.clang_getCursorSpelling(cursor)));
    if (hasName(&tc.emitted, name) || knownTypedef(name) != null) return;
    const underlying = sys.clang_getTypedefDeclUnderlyingType(cursor);
    let named = underlying;
    while (named.kind == sys.CXType_Elaborated) named = sys.clang_Type_getNamedType(named);

    // `typedef struct { ... } name;` and `typedef struct name name;`: the struct itself, under this name
    if (named.kind == sys.CXType_Record) {
        const rec = sys.clang_getTypeDeclaration(named);
        const tag = clangString(sys.clang_getCursorSpelling(rec));
        if (unnamed(tag, rec) || equal(tag, name)) {
            const def = sys.clang_getCursorDefinition(rec);
            emitRecord(tc, isNull(def) ? rec : def, name);
            return;
        }
    }
    if (named.kind == sys.CXType_Enum) {
        const en = sys.clang_getTypeDeclaration(named);
        if (unnamed(clangString(sys.clang_getCursorSpelling(en)), en)) {
            emitEnumDecl(tc, en, name);
            return;
        }
    }
    let text = fmt.Builder.init(cAllocator());
    defer text.deinit();
    let why = "";
    let ok = false;
    if (isFunctionKind(sys.clang_getCanonicalType(underlying).kind)) {
        // a function type used through pointers: `fn *` is translated where it's used
        why = "a function type (not a pointer to one); its uses are translated as `?extern \"C\" (...) => ...`";
    } else {
        ok = typeText(tc, underlying, &text, &why);
    }
    if (ok) {
        docComment(tc, cursor);
        put(&tc.out, `export type ${name} = ${text.text()};\n\n`);
        addName(&tc.emitted, name);
    } else {
        skip(tc, "typedef", name, why);
    }
}

/**
 * Writes `export extern "C" let` for a C variable, or `const` when its C type is `const`.
 *
 * @param tc - The state of the run
 * @param cursor - The declaration of the variable
 *
 * @remarks
 * A `static` variable has no symbol to link to, a thread-local one cannot be imported from C yet,
 * and one named like a Helix keyword cannot be named, so each is left out.
 *
 * @since 1.0.0
 */

function emitGlobal(tc: *TranslateContext, cursor: sys.CXCursor): void {
    const cName = clangString(sys.clang_getCursorSpelling(cursor));
    const name = helixName(cName);
    let why = "";
    if (sys.clang_Cursor_getStorageClass(cursor) == sys.CX_SC_Static) why = "a `static` variable has no symbol to link to";
    else if (sys.clang_getCursorTLSKind(cursor) != sys.CXTLS_None) why = "thread-local variables can't be imported from C yet";
    else if (!equal(name, cName)) why = "its name is a Helix keyword";
    if (why.len > 0) {
        skip(tc, "variable", cName, why);
        return;
    }
    if (hasName(&tc.emitted, name)) return;
    const type = sys.clang_getCursorType(cursor);
    let text = fmt.Builder.init(cAllocator());
    defer text.deinit();
    if (typeText(tc, type, &text, &why)) {
        docComment(tc, cursor);
        put(&tc.out, `export extern "C" ${sys.clang_isConstQualifiedType(type) != 0 ? "const" : "let"} ${name}: ${text.text()};\n\n`);
        addName(&tc.emitted, name);
    } else {
        skip(tc, "variable", cName, why);
    }
}

/**
 * Gives the spelling of a token.
 *
 * @param tc - The state of the run
 * @param tokens - The tokens
 * @param i - The index of the token
 * @returns The spelling
 *
 * @remarks
 * The spelling is copied through {@link clangString}, so it stays valid after the tokens are disposed of.
 *
 * @since 1.0.0
 */

function tokenText(tc: *TranslateContext, tokens: sys.CXToken[*], i: u32): string {
    unsafe {
        return clangString(sys.clang_getTokenSpelling(tc.tu, tokens[i]));
    }
}

/**
 * Writes a C number literal as Helix writes it.
 *
 * @param literal - The C literal
 * @param negative - Whether a `-` came before the literal
 * @returns The Helix literal, or an empty string when the literal is not one that Helix can read
 *
 * @remarks
 * The suffixes `u`, `l`, `ll`, and `f` for a float are dropped.
 * A C number token can hold more than a number, as in `5union`, so only a whole number is kept.
 * A float, hex floats included, is written in decimal with `.0` after a whole value, and infinity or NaN gives nothing.
 * An octal literal such as `017` becomes `0o17`.
 *
 * @since 1.0.0
 */

function numberText(literal: string, negative: bool): string {
    const hex = literal.len > 2 && literal[0] == '0' && (literal[1] == 'x' || literal[1] == 'X');
    let floating = false;
    for (const c of literal) {
        if (hex && (c == '.' || c == 'p' || c == 'P')) floating = true;
        if (!hex && (c == '.' || c == 'e' || c == 'E')) floating = true;
    }
    // suffixes: u, l, ll (and f for a float); a hex integer's digits can end in f
    let len = literal.len;
    while (len > 0) {
        const c = literal[len - 1];
        if (c == 'u' || c == 'U' || c == 'l' || c == 'L' || (floating && (c == 'f' || c == 'F'))) len--;
        else break;
    }
    const digits = toCString(literal[0..len]);
    let end: ?u8[*] = null;   // a C number token can hold more (`5union`): only whole numbers are kept
    if (floating) void sys.strtod(digits, &end);
    else void sys.strtoull(digits, &end, 0);
    unsafe {
        if (end == null || end![0] != 0 || @intFromPtr(end) == @intFromPtr(digits)) return "";
    }
    if (floating) {   // hex floats (`0x1.fffffep+127`) and the rest, written in decimal
        const v = sys.strtod(digits, null);
        let buf: u8[64] = undefined;
        void sys.snprintf(&buf, 64, "%.17g", negative ? -v : v);
        let text = "";
        unsafe {
            text = fromCString(@ptrCast(readonly u8[*], &buf));
        }
        let plain = true;   // no `.`, exponent or `nan`: add `.0`
        let special = false;
        for (const c of text) {
            if (c == '.' || c == 'e' || c == 'E' || c == 'n') plain = false;
            if (c == 'n' || c == 'i') special = true;
        }
        if (special) return "";   // inf or nan
        return plain ? allocCString(`${text}.0`) : allocCString(`${text}`);
    }
    const octal = len > 1 && literal[0] == '0' && literal[1] >= '0' && literal[1] <= '7';
    return allocCString(`${negative ? "-" : ""}${octal ? "0o" : ""}${literal[(octal ? 1 : 0)..len]}`);
}

/**
 * Writes `export const NAME = literal;` for a `#define` of a literal.
 *
 * @param tc - The state of the run
 * @param cursor - The macro definition
 *
 * @remarks
 * The literal may be a number, a string, or a character, which is a number in C.
 * It may be negated or in parentheses.
 * Function-like macros, built-in macros, names that start with `_`, and anything else are left out without a comment.
 *
 * @since 1.0.0
 */

function emitMacro(tc: *TranslateContext, cursor: sys.CXCursor): void {
    if (sys.clang_Cursor_isMacroFunctionLike(cursor) != 0 || sys.clang_Cursor_isMacroBuiltin(cursor) != 0) return;
    let tokenList: ?*sys.CXToken = null;
    let count: u32 = 0;
    sys.clang_tokenize(tc.tu, sys.clang_getCursorExtent(cursor), &tokenList, &count);
    defer sys.clang_disposeTokens(tc.tu, tokenList, count);
    if (count < 2) return;
    const tokens = tokenArray(tokenList);
    const cName = tokenText(tc, tokens, 0);
    let first: u32 = 1;
    let last = count;
    if (last - first >= 3 && equal(tokenText(tc, tokens, first), "(") && equal(tokenText(tc, tokens, last - 1), ")")) {
        first++;
        last--;
    }
    let negative = false;
    if (last - first == 2) {
        negative = equal(tokenText(tc, tokens, first), "-");
        if (negative) first++;
    }
    const name = helixName(cName);
    const literalKind = tokenKind(tokens, first);
    if (last - first != 1 || literalKind != sys.CXToken_Literal || hasName(&tc.emitted, name) || !equal(name, cName)
            || cName[0] == '_') {
        return;
    }
    const literal = tokenText(tc, tokens, first);
    let value = "";
    if (literal[0] == '"') {
        if (literal.len >= 2 && literal[literal.len - 1] == '"') value = literal;
    } else if (literal[0] == '\'') {
        if (literal.len == 3) value = allocCString(`${literal[1]}`);   // 'a' is a number in C
    } else {
        value = numberText(literal, negative);
    }
    if (value.len > 0) {
        put(&tc.out, `export const ${name} = ${value};\n`);
        addName(&tc.emitted, name);
    }
}

/**
 * Writes one top-level declaration, or collects its name in the first pass.
 *
 * @param cursor - The declaration
 * @param _parent - The translation unit, which it does not use
 * @param data - The top-level walk as client data
 * @returns `CXChildVisit_Continue`
 *
 * @remarks
 * Only declarations of the headers of the run count.
 * The first pass collects the names of functions and variables.
 * The second one writes structs, unions, enums, typedefs, functions, variables, and macros.
 * A forward declaration of a defined record is left for the definition,
 * and an unnamed record is left for the typedef that names it.
 *
 * @since 1.0.0
 */

extern "C" function visitTop(cursor: sys.CXCursor, _parent: sys.CXCursor, data: ?u8[*]): u32 {
    const w = topWalk(data);
    const tc = w.tc;
    if (!isOwn(tc, cursor)) return sys.CXChildVisit_Continue;
    const kind = sys.clang_getCursorKind(cursor);
    if (w.functionsOnly) {
        if (kind == sys.CXCursor_FunctionDecl || kind == sys.CXCursor_VarDecl) addName(&tc.functionNames, clangString(sys.clang_getCursorSpelling(cursor)));
        return sys.CXChildVisit_Continue;
    }
    if (kind == sys.CXCursor_StructDecl || kind == sys.CXCursor_UnionDecl) {
        if (sys.clang_Cursor_isAnonymous(cursor) != 0) return sys.CXChildVisit_Continue;
        const def = sys.clang_getCursorDefinition(cursor);
        if (!isNull(def) && sys.clang_equalCursors(def, cursor) == 0) return sys.CXChildVisit_Continue;   // a forward declaration
        const name = recordName(tc, cursor);
        if (!startsWith(name, "_anon")) emitRecord(tc, cursor, name);   // unnamed ones come with their typedef
    } else if (kind == sys.CXCursor_EnumDecl) {
        emitEnumDecl(tc, cursor, null);   // an unnamed one: just its constants
    } else if (kind == sys.CXCursor_TypedefDecl) {
        emitTypedef(tc, cursor);
    } else if (kind == sys.CXCursor_FunctionDecl) {
        emitFunction(tc, cursor);
    } else if (kind == sys.CXCursor_VarDecl) {
        emitGlobal(tc, cursor);
    } else if (kind == sys.CXCursor_MacroDefinition) {
        emitMacro(tc, cursor);
    }
    return sys.CXChildVisit_Continue;
}

/**
 * Reads a C header with libclang and writes the Helix declarations to call it.
 *
 * @param options - What to translate and where to write it
 * @returns The exit status, 0 on success and 1 after an error
 *
 * @remarks
 * This is `helix translate-c`.
 * Each C declaration becomes a Helix one:
 *
 * - `int f(const char *s, ...);` becomes `export extern "C" function f(s: ?readonly u8[*], ...): i32;`
 * - `struct point { int x, y; };` becomes `export extern "C" struct point { x: i32, y: i32 }`
 * - `struct handle;` without a definition becomes the opaque `export extern "C" struct handle {}`
 * - a union, or a struct with bit fields, keeps its size and alignment as `_bytes`
 * - `typedef unsigned int uInt;` becomes `export type uInt = u32;`
 * - `typedef int (*cb)(int);` becomes `export type cb = ?extern "C" (a0: i32) => i32;`
 * - `extern int count;` becomes `export extern "C" let count: i32;`
 * - `enum color { RED };` becomes `export type color = u32;` and `export const RED: color = 0;`
 * - `#define Version "1.2"` becomes `export const Version = "1.2";`
 *
 * Types from system headers are mapped, such as `size_t` to `usize`, resolved to what they stand for,
 * or declared opaque.
 * The output is a file to commit and read, so anything that cannot be translated becomes a comment that says why.
 * clang gets C17, the target, the clang resource folder, the macOS SDK, and then the options of the user.
 * A header that does not compile as C prints the errors of clang and fails.
 *
 * @example
 * ```hx
 * translateC(options); // 0, and stderr says "wrote src/zlib.hx: 120 declarations, 3 skipped (see the comments)"
 * ```
 *
 * @see TranslateOptions
 * @since 1.0.0
 */

export function translateC(options: TranslateOptions): u8 {
    const header = os.realPath(options.header);
    if (header == null) {
        eprintln(`error: cannot read '${options.header}'`);
        return 1;
    }
    const slash = os.lastIndex(header, '/') ?? header.len;
    let tc = TranslateContext {
        tu: null, ownDir: header[0..slash], ownFiles: strings(), all: options.all, wholeDir: options.wholeDir,
        out: fmt.Builder.init(cAllocator()), emitted: strings(), functionNames: strings(), pendingOpaque: strings(),
        pending: ArrayList<sys.CXCursor>.init(cAllocator()), skipped: 0, anonymous: 0,
    };

    // clang's own arguments: the language, the target, the macOS SDK for system headers, then the user's
    let args = strings();
    add(&args, "-x");
    add(&args, "c");
    add(&args, "-std=c17");
    if (const triple = options.triple) {
        add(&args, "-target");
        add(&args, triple);
    }
    if (const resources = clangResourceDir()) {   // libclang doesn't always find its own headers by itself
        add(&args, "-resource-dir");
        add(&args, resources);
    }
    if (const sdk = macosSdk()) {
        add(&args, "-isysroot");
        add(&args, sdk.path);
    }
    for (const arg of options.clangArgs) add(&args, arg);

    const index = sys.clang_createIndex(0, 0);
    defer sys.clang_disposeIndex(index);
    let tu: sys.CXTranslationUnit = null;
    const argv = readonlyArgs(os.cArgs(args.items));
    const err = sys.clang_parseTranslationUnit2(index, toCString(header), argv, args.items.len as i32, null, 0,
                                              sys.CXTranslationUnit_DetailedPreprocessingRecord | sys.CXTranslationUnit_SkipFunctionBodies,
                                              &tu);
    if (err != sys.CXError_Success) {
        eprintln(`error: libclang couldn't read '${options.header}' (error ${err})`);
        return 1;
    }
    defer sys.clang_disposeTranslationUnit(tu);
    tc.tu = tu;
    addName(&tc.ownFiles, header);
    sys.clang_getInclusions(tu, visitInclusion, clientData(&tc));
    let errors: u32 = 0;
    for (const i of 0..sys.clang_getNumDiagnostics(tu)) {
        const d = sys.clang_getDiagnostic(tu, i);
        if (sys.clang_getDiagnosticSeverity(d) >= sys.CXDiagnostic_Error) {
            eprintln(`${clangString(sys.clang_formatDiagnostic(d, sys.clang_defaultDiagnosticDisplayOptions()))}`);
            errors++;
        }
        sys.clang_disposeDiagnostic(d);
    }
    if (errors > 0) {
        eprintln("error: the header doesn't compile as C; pass -I and -D options as for a C compiler");
        return 1;
    }

    put(&tc.out, `// Generated by \`${options.command}\`.\n// Regenerate it rather than editing it; wrap it in a Helix API in another file.\n\n`);
    const headerLen = tc.out.text().len;
    let pass = TopWalk { tc: &tc, functionsOnly: true };
    void sys.clang_visitChildren(sys.clang_getTranslationUnitCursor(tu), visitTop, clientData(&pass));
    pass.functionsOnly = false;
    void sys.clang_visitChildren(sys.clang_getTranslationUnitCursor(tu), visitTop, clientData(&pass));
    let i: usize = 0;
    while (i < tc.pending.items.len) {   // nested definitions; writing one can queue more
        const rec = tc.pending.items[i];
        const def = sys.clang_getCursorDefinition(rec);
        const name = recordName(&tc, rec);
        if (!hasName(&tc.emitted, name)) emitRecord(&tc, isNull(def) ? rec : def, name);
        i++;
    }
    for (const name of tc.pendingOpaque.items) {   // structs the output uses from other headers
        if (hasName(&tc.emitted, name)) continue;
        addName(&tc.emitted, name);
        put(&tc.out, `/** Opaque here (it's declared in another header): use it only through pointers. */\nexport extern "C" struct ${name} {}\n\n`);
    }
    if (tc.out.text().len == headerLen) put(&tc.out, "// (the header declares nothing Helix can use)\n");
    let text = tc.out.text();
    while (text.len >= 2 && text[text.len - 1] == '\n' && text[text.len - 2] == '\n') text = text[0..text.len - 1];

    if (const output = options.output) {
        if (!os.writeText(output, text)) {
            eprintln(`error: cannot write '${output}'`);
            return 1;
        }
        eprint(`wrote ${output}: ${tc.emitted.items.len} declarations`);
        if (tc.skipped > 0) eprint(`, ${tc.skipped} skipped (see the comments)`);
        eprintln("");
    } else {
        void sys.fwrite(text.ptr, 1, text.len, os.cStdout());
    }
    return 0;
}
