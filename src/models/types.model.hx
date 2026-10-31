/**
 * Imports
 */

import { hxZalloc, hxVecGrowImpl } from "@components/memory.component";
import { HxType, HxTypes, Out } from "@models/structs/types-model.struct";
import { TypeKind, Signed, Readonly, Variadic, AnyError, CCall } from "@constants/types.constant";

/**
 * The C library functions that release the type table and clear it.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;
extern "C" function memset(to: u8[*], byte: i32, len: usize): ?u8[*];

/**
 * Builds a type entry with only its kind set.
 *
 * @param kind - The kind of the type
 * @returns The entry, with every other field 0 or `null`
 *
 * @remarks
 * Every constructor starts from this entry and sets only the fields that its kind uses,
 * so two equal types always hash and compare the same.
 *
 * @since 1.0.0
 */

function plainType(kind: TypeKind): HxType {
    return HxType { kind, flags: 0, bits: 0, child: 0, len: 0, params: 0, name: null, nameLen: 0 };
}

/**
 * Copies the entry of a type.
 *
 * @param types - The type table
 * @param id - The type id
 * @returns The entry, copied, since adding a type can move the table
 *
 * @remarks
 * It does not check the id against the length of the table.
 *
 * @since 1.0.0
 */

function typeAt(types: readonly *HxTypes, id: u32): HxType {
    unsafe {
        return types.items![id];
    }
}

/**
 * Reads one entry of the shared parameter list.
 *
 * @param types - The type table
 * @param i - The index into the parameter list
 * @returns The parameter type at that index
 *
 * @remarks
 * The parameter types of every function type live in this one list,
 * and each function entry points at its own stretch with `params` and `len`.
 *
 * @since 1.0.0
 */

function paramAt(types: readonly *HxTypes, i: u64): u32 {
    unsafe {
        return types.params![i as usize];
    }
}

/**
 * Hashes a type entry with 64-bit FNV-1a, folded to 32 bits.
 *
 * @param types - The type table, which holds the parameters of a function type
 * @param t - The entry to hash
 * @returns The hash of its kind, flags, bits, child, and length, plus the parameter types of a function
 *
 * @remarks
 * The name of a nominal type is left out, since it is not part of the identity.
 *
 * @since 1.0.0
 */

function hashType(types: readonly *HxTypes, t: readonly *HxType): u32 {
    let hash: u64 = 1469598103934665603;
    const values: u64[5] = [t.kind as u64, t.flags as u64, t.bits as u64, t.child as u64, t.len];
    for (const v of values) hash = (hash ^ v) *% 1099511628211;
    if (t.kind == TypeKind.Function) {
        for (const i of 0..t.len) hash = (hash ^ (paramAt(types, (t.params as u64) + i) as u64)) *% 1099511628211;
    }
    return @truncate(u32, hash ^ (hash >> 32));
}

/**
 * Checks whether two type entries describe the same type.
 *
 * @param types - The type table, which holds the parameters of a function type
 * @param a - The first entry
 * @param b - The second entry
 * @returns `true` when the kind, flags, bits, child, and length match, and for functions the parameters too
 *
 * @remarks
 * Nominal types differ in their length, which holds their aggregate index, so this never mixes two declarations up.
 *
 * @since 1.0.0
 */

function typesEqual(types: readonly *HxTypes, a: readonly *HxType, b: readonly *HxType): bool {
    if (a.kind != b.kind || a.flags != b.flags || a.bits != b.bits || a.child != b.child || a.len != b.len) return false;
    if (a.kind != TypeKind.Function) return true;   // nominal types differ by `len` (their aggregate index)
    for (const i of 0..a.len) {
        if (paramAt(types, (a.params as u64) + i) != paramAt(types, (b.params as u64) + i)) return false;
    }
    return true;
}

/**
 * Doubles the hash table and puts every type back into it.
 *
 * @param types - The type table
 *
 * @remarks
 * The first call makes 256 slots.
 *
 * @since 1.0.0
 */

function growSlots(types: *HxTypes): void {
    const cap = types.slotsCap != 0 ? types.slotsCap * 2 : 256;
    unsafe {
        const slots = @ptrCast(u32[*], hxZalloc((cap as usize) * 4));
        for (const id of 1..types.itemsLen) {
            let slot = hashType(types, &types.items![id]) & (cap - 1);
            while (slots[slot] != 0) slot = (slot + 1) & (cap - 1);
            slots[slot] = id;
        }
        free(@ptrCast(?u8[*], types.slots));
        types.slots = slots;
    }
    types.slotsCap = cap;
}

/**
 * Appends an entry to the type array without interning it.
 *
 * @param types - The type table
 * @param t - The entry to append
 *
 * @remarks
 * Grows the array by at least one entry when it is full.
 * Only {@link intern} and {@link hxTypesInit} call it,
 * since a type added without interning would break the uniqueness of ids.
 *
 * @since 1.0.0
 */

function pushItem(types: *HxTypes, t: HxType): void {
    unsafe {
        if (types.itemsLen == types.itemsCap) {
            hxVecGrowImpl(@ptrCast(*?u8[*], &types.items), &types.itemsCap, types.itemsLen + 1, @sizeOf(HxType));
        }
        types.items![types.itemsLen] = t;
    }
    types.itemsLen += 1;
}

/**
 * Appends a parameter type to the shared parameter list.
 *
 * @param types - The type table
 * @param id - The parameter type
 *
 * @remarks
 * Grows the list by at least one entry when it is full.
 * The caller pushes all the parameters of a function before it interns the function type.
 *
 * @since 1.0.0
 */

function pushParam(types: *HxTypes, id: u32): void {
    unsafe {
        if (types.paramsLen == types.paramsCap) {
            hxVecGrowImpl(@ptrCast(*?u8[*], &types.params), &types.paramsCap, types.paramsLen + 1, 4);
        }
        types.params![types.paramsLen] = id;
    }
    types.paramsLen += 1;
}

/**
 * Finds the id of a type equal to an entry, or adds the entry as a new type.
 *
 * @param types - The type table
 * @param t - The entry to find or add
 * @returns The id of the existing equal type, or of the new one
 *
 * @remarks
 * For a function type, the caller pushes the parameter types first and points `params` at them.
 * When an equal function type exists, the parameters just pushed are dropped again.
 *
 * @since 1.0.0
 */

function intern(types: *HxTypes, t: HxType): u32 {
    if ((types.itemsLen + 1) * 2 > types.slotsCap) growSlots(types);
    let slot = hashType(types, &t) & (types.slotsCap - 1);
    unsafe {
        const slots = types.slots!;
        while (slots[slot] != 0) {
            const id = slots[slot];
            if (typesEqual(types, &types.items![id], &t)) {
                if (t.kind == TypeKind.Function) types.paramsLen = t.params;   // drop the duplicate params
                return id;
            }
            slot = (slot + 1) & (types.slotsCap - 1);
        }
        pushItem(types, t);
        slots[slot] = types.itemsLen - 1;
    }
    return types.itemsLen - 1;
}

/**
 * Gets the id of an integer type.
 *
 * @param types - The type table
 * @param isSigned - Whether the type is signed
 * @param bits - The width in bits
 * @returns The id of `iN` or `uN`
 *
 * @remarks
 * Types are interned, so asking twice for the same signedness and width returns the same id.
 * Any width is accepted, not only the powers of two.
 *
 * @example
 * ```hx
 * hxTypeInt(&types, true, 32) == types.i32; // true
 * hxTypeInt(&types, false, 7);              // the id of u7
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeInt(types: *HxTypes, isSigned: bool, bits: u16): u32 {
    let t = plainType(TypeKind.Int);
    t.flags = isSigned ? Signed : 0;
    t.bits = bits;
    return intern(types, t);
}

/**
 * Gets the id of a pointer-like type.
 *
 * @param types - The type table
 * @param kind - The kind as a number, one of `Pointer`, `ManyPointer`, `Slice`, or `Dyn` of {@link TypeKind}
 * @param child - The pointee or element type
 * @param readonly - Whether to set {@link Readonly}
 * @returns The id of the type
 *
 * @remarks
 * Types are interned, so the same kind, child, and readonly flag always give the same id.
 * The kind is not checked, so passing a kind that is not pointer-like builds a malformed entry.
 *
 * @example
 * ```hx
 * hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, false);   // *i32
 * hxTypePointer(&types, TypeKind.Slice as u32, types.u8, true);       // string
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypePointer(types: *HxTypes, kind: u32, child: u32, readonly: bool): u32 {
    let t = plainType(@enumFromInt(TypeKind, kind));
    t.flags = readonly ? Readonly : 0;
    t.child = child;
    return intern(types, t);
}

/**
 * Gets the id of an array type.
 *
 * @param types - The type table
 * @param child - The element type
 * @param len - The number of elements
 * @returns The id of `T[N]`
 *
 * @remarks
 * Types are interned, so the same element type and length always give the same id.
 * A length of 0 is accepted and gives an array without elements.
 *
 * @example
 * ```hx
 * hxTypeArray(&types, types.u8, 4); // u8[4]
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeArray(types: *HxTypes, child: u32, len: u64): u32 {
    let t = plainType(TypeKind.Array);
    t.child = child;
    t.len = len;
    return intern(types, t);
}

/**
 * Gets the id of a function type with the given flags.
 *
 * @param types - The type table
 * @param ret - The return type
 * @param params - The parameter types
 * @param count - The number of parameters
 * @param flags - The {@link Variadic} and {@link CCall} bits
 * @returns The id of the function type
 *
 * @remarks
 * Pushes the parameter types onto the shared list before interning the function,
 * and drops them again when an equal function type already exists.
 * `params` may be `null` only when `count` is 0.
 *
 * @example
 * ```hx
 * const params: u32[1] = [types.i32];
 * hxTypeFunctionFlags(&types, types.voidType, &params, 1, CCall); // extern "C" (i32) => void
 * ```
 *
 * @see hxTypeFunction
 * @since 1.0.0
 */

export extern "C" function hxTypeFunctionFlags(types: *HxTypes, ret: u32, params: ?readonly u32[*], count: u32, flags: u8): u32 {
    const start = types.paramsLen;
    unsafe {
        for (const i of 0..count) pushParam(types, params![i]);
    }
    let t = plainType(TypeKind.Function);
    t.flags = flags;
    t.child = ret;
    t.len = count as u64;
    t.params = start;
    return intern(types, t);
}

/**
 * Gets the id of a function type with the Helix calling convention.
 *
 * @param types - The type table
 * @param ret - The return type
 * @param params - The parameter types
 * @param count - The number of parameters
 * @param variadic - Whether the parameter list ends with `...`
 * @returns The id of the function type
 *
 * @remarks
 * A shorthand for {@link hxTypeFunctionFlags} that only sets or clears {@link Variadic}.
 * Use the flag form when the type needs the C calling convention.
 *
 * @example
 * ```hx
 * const params: u32[2] = [types.i32, types.i32];
 * hxTypeFunction(&types, types.boolType, &params, 2, false); // (i32, i32) => bool
 * ```
 *
 * @see hxTypeFunctionFlags
 * @since 1.0.0
 */

export extern "C" function hxTypeFunction(types: *HxTypes, ret: u32, params: ?readonly u32[*], count: u32, variadic: bool): u32 {
    return hxTypeFunctionFlags(types, ret, params, count, variadic ? Variadic : 0);
}

/**
 * Gets the same function type with or without the C calling convention.
 *
 * @param types - The type table
 * @param fn - The function type
 * @param cCall - Whether the result uses the C calling convention
 * @returns The function type with {@link CCall} set as asked, or `fn` itself when it already is
 *
 * @remarks
 * Only the first 256 parameters are copied into the new type.
 *
 * @example
 * ```hx
 * const fn = hxTypeFunction(&types, types.voidType, null, 0, false);
 * hxTypeFunctionC(&types, fn, true); // extern "C" () => void
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeFunctionC(types: *HxTypes, fn: u32, cCall: bool): u32 {
    const t = typeAt(types, fn);
    const flags = (t.flags & ~CCall) | (cCall ? CCall : 0);
    if (flags == t.flags) return fn;
    let params: u32[256] = undefined;
    const count = t.len < 256 ? t.len as usize : 256;
    for (const i of 0..count) params[i] = paramAt(types, (t.params as u64) + (i as u64));
    return hxTypeFunctionFlags(types, t.child, &params, @truncate(u32, count), flags);
}

/**
 * Gets the id of an optional type.
 *
 * @param types - The type table
 * @param child - The payload type
 * @returns The id of `?T`
 *
 * @remarks
 * Types are interned, so the same payload always gives the same id.
 * It does not collapse a nested optional, so `??T` is its own type.
 *
 * @example
 * ```hx
 * hxTypeOptional(&types, types.i32); // ?i32
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeOptional(types: *HxTypes, child: u32): u32 {
    let t = plainType(TypeKind.Optional);
    t.child = child;
    return intern(types, t);
}

/**
 * Gets the id of an error union type.
 *
 * @param types - The type table
 * @param payload - The type of the value on success
 * @param errorSet - The error set type
 * @returns The id of `T | E`
 *
 * @remarks
 * The error set sits in `len` and the payload in `child`,
 * so two unions with the same payload but different sets get different ids.
 * Types are interned, so the same pair always gives the same id.
 *
 * @example
 * ```hx
 * hxTypeErrorUnion(&types, types.i32, types.anyError); // i32 | Error
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeErrorUnion(types: *HxTypes, payload: u32, errorSet: u32): u32 {
    let t = plainType(TypeKind.ErrorUnion);
    t.child = payload;
    t.len = errorSet as u64;
    return intern(types, t);
}

/**
 * Creates the type of a struct, enum, union, error set, or interface declaration.
 *
 * @param types - The type table
 * @param kind - The kind as a number, such as `TypeKind.Struct as u32`
 * @param aggregate - The index of the declaration's aggregate, which makes each declaration its own type
 * @param backing - The backing integer of an enum, or 0
 * @param name - The declared name, or `null` for an anonymous type
 * @param nameLen - The length of the name in bytes
 * @returns The id of the new type
 *
 * @remarks
 * The name is stored on the entry but is not part of its identity.
 * Calling it again with the same aggregate index returns the same id and replaces the stored name.
 *
 * @example
 * ```hx
 * const point = hxTypeNominal(&types, TypeKind.Struct as u32, 0, 0, "Point", 5);
 * hxTypeName(&types, point, &buf, 64); // buf holds Point
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeNominal(types: *HxTypes, kind: u32, aggregate: u32, backing: u32, name: ?readonly u8[*],
                                           nameLen: u32): u32 {
    let t = plainType(@enumFromInt(TypeKind, kind));
    t.child = backing;
    t.len = (aggregate as u64) + 1;
    const id = intern(types, t);
    unsafe {
        types.items![id].name = name;
        types.items![id].nameLen = nameLen;
    }
    return id;
}

/**
 * Gets the readonly form of a pointer-like type.
 *
 * @param types - The type table
 * @param id - The type to make readonly
 * @returns The same type with {@link Readonly} set, or `id` unchanged for a type that is not a pointer,
 * a many-pointer, or a slice
 *
 * @remarks
 * Use it to weaken a mutable pointer for a readonly parameter.
 * An array, an optional, or a nominal type comes back unchanged, since only pointer-like types carry the flag.
 *
 * @example
 * ```hx
 * const p = hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, false);
 * hxTypeReadonly(&types, p);         // readonly *i32
 * hxTypeReadonly(&types, types.i32); // types.i32
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeReadonly(types: *HxTypes, id: u32): u32 {
    let t = typeAt(types, id);
    if (t.kind != TypeKind.Pointer && t.kind != TypeKind.ManyPointer && t.kind != TypeKind.Slice) return id;
    t.flags |= Readonly;
    return intern(types, t);
}

/**
 * Prepares a type table and interns the built-in types.
 *
 * @param types - The table to set up, whose previous contents are ignored
 * @param pointerBytes - The size of a pointer on the target, 8 or 4
 *
 * @remarks
 * Id 0 becomes the invalid type, and the fields such as {@link HxTypes.voidType} get their ids.
 * The size of a pointer decides whether `usize` and `isize` are the 64-bit or the 32-bit integers.
 * Release the table with {@link hxTypesFree}.
 *
 * @example
 * ```hx
 * let types: HxTypes = undefined;
 * hxTypesInit(&types, 4);
 * types.usize == types.u32; // true on a 32-bit target
 * ```
 *
 * @see hxTypesFree
 * @since 1.0.0
 */

export extern "C" function hxTypesInit(types: *HxTypes, pointerBytes: u32): void {
    unsafe {
        void memset(@ptrCast(u8[*], types), 0, @sizeOf(HxTypes));
    }
    types.pointerBytes = pointerBytes;
    pushItem(types, plainType(TypeKind.Invalid));
    growSlots(types);

    types.voidType = intern(types, plainType(TypeKind.Void));
    types.boolType = intern(types, plainType(TypeKind.Bool));
    types.noreturnType = intern(types, plainType(TypeKind.Noreturn));
    types.comptimeInt = intern(types, plainType(TypeKind.ComptimeInt));
    types.comptimeFloat = intern(types, plainType(TypeKind.ComptimeFloat));
    types.undefinedType = intern(types, plainType(TypeKind.Undefined));
    types.stringLiteral = intern(types, plainType(TypeKind.StringLiteral));

    types.u8 = hxTypeInt(types, false, 8);
    types.u16 = hxTypeInt(types, false, 16);
    types.u32 = hxTypeInt(types, false, 32);
    types.u64 = hxTypeInt(types, false, 64);
    types.i8 = hxTypeInt(types, true, 8);
    types.i16 = hxTypeInt(types, true, 16);
    types.i32 = hxTypeInt(types, true, 32);
    types.i64 = hxTypeInt(types, true, 64);
    types.usize = pointerBytes == 4 ? types.u32 : types.u64;
    types.isize = pointerBytes == 4 ? types.i32 : types.i64;
    let float = plainType(TypeKind.Float);
    float.bits = 32;
    types.f32 = intern(types, float);
    float.bits = 64;
    types.f64 = intern(types, float);
    types.string = hxTypePointer(types, TypeKind.Slice as u32, types.u8, true);
    types.nullType = intern(types, plainType(TypeKind.Null));
    types.errorCode = types.u16;
    let anyError = plainType(TypeKind.ErrorSet);
    anyError.flags = AnyError;
    types.anyError = intern(types, anyError);
    unsafe {
        types.items![types.anyError].name = "Error";
        types.items![types.anyError].nameLen = 5;
    }
    types.format = intern(types, plainType(TypeKind.Format));
}

/**
 * Releases the memory of a type table and clears it.
 *
 * @param types - The table to release
 *
 * @remarks
 * Zeroes the whole table after freeing, so every id becomes invalid and releasing it twice is harmless.
 * Names of nominal types are not freed, since the table only borrows them.
 *
 * @example
 * ```hx
 * hxTypesFree(&types);
 * types.itemsLen; // 0
 * ```
 *
 * @see hxTypesInit
 * @since 1.0.0
 */

export extern "C" function hxTypesFree(types: *HxTypes): void {
    unsafe {
        free(@ptrCast(?u8[*], types.items));
        free(@ptrCast(?u8[*], types.params));
        free(@ptrCast(?u8[*], types.slots));
        void memset(@ptrCast(u8[*], types), 0, @sizeOf(HxTypes));
    }
}

/**
 * Finds the built-in type that a name stands for.
 *
 * @param types - The type table
 * @param text - The name
 * @param len - The length of the name in bytes
 * @returns The id of the type, or 0 when the name is not a built-in type
 *
 * @remarks
 * The names are `void`, `bool`, `noreturn`, `usize`, `isize`, `f32`, `f64`, `string`, `Error`, and `Format`,
 * plus `uN` and `iN` for any width from 1 to 65535 written without leading zeros.
 *
 * @example
 * ```hx
 * hxTypeBuiltin(&types, "i32", 3);  // types.i32
 * hxTypeBuiltin(&types, "u7", 2);   // the id of u7
 * hxTypeBuiltin(&types, "u07", 3);  // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeBuiltin(types: *HxTypes, text: readonly u8[*], len: u32): u32 {
    let name: string = "";
    unsafe {
        if (len > 0) name = text[0..len];
    }
    switch (name) {
        case "void": return types.voidType;
        case "bool": return types.boolType;
        case "noreturn": return types.noreturnType;
        case "usize": return types.usize;
        case "isize": return types.isize;
        case "f32": return types.f32;
        case "f64": return types.f64;
        case "string": return types.string;
        case "Error": return types.anyError;
        case "Format": return types.format;
        default: {}
    }
    // uN / iN for any width 1..65535, without leading zeros
    if (len >= 2 && len <= 6 && (name[0] == 'u' || name[0] == 'i') && name[1] >= '1' && name[1] <= '9') {
        let bits: u32 = 0;
        for (const c of name[1..name.len]) {
            if (c < '0' || c > '9') return 0;
            bits = bits * 10 + ((c - '0') as u32);
        }
        if (bits > 65535) return 0;
        return hxTypeInt(types, name[0] == 'i', @truncate(u16, bits));
    }
    return 0;
}

/**
 * Gets the size in bytes of a type as it is laid out in memory.
 *
 * @param types - The type table
 * @param id - The type
 * @returns The size in bytes, or 0 for a type that this function does not size
 *
 * @remarks
 * Integers and floats round up to a power of two bytes, as in C.
 * A slice, a `dyn`, and a `Format` take two pointers, and a function takes one.
 * Structs, unions, optionals, and error unions give 0, since their layout depends on the checker.
 *
 * @example
 * ```hx
 * hxTypeSize(&types, types.i32);                                // 4
 * hxTypeSize(&types, hxTypeInt(&types, false, 24));          // 4
 * hxTypeSize(&types, types.string);                             // 16 on a 64-bit target
 * hxTypeSize(&types, hxTypeArray(&types, types.u16, 3));     // 6
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeSize(types: readonly *HxTypes, id: u32): u64 {
    const t = typeAt(types, id);
    switch (t.kind) {
        case TypeKind.Bool: return 1;
        case TypeKind.Int, TypeKind.Float: {
            let bytes: u64 = 1;
            while (bytes * 8 < (t.bits as u64)) bytes *= 2;
            return bytes;
        }
        case TypeKind.Pointer, TypeKind.ManyPointer, TypeKind.Function: return types.pointerBytes as u64;
        case TypeKind.Slice, TypeKind.Dyn, TypeKind.Format: return 2 * (types.pointerBytes as u64);
        case TypeKind.Array: return t.len * hxTypeSize(types, t.child);
        default: return 0;
    }
}

/**
 * Appends text to a buffer, dropping what does not fit.
 *
 * @param out - The buffer
 * @param text - The text to append
 *
 * @remarks
 * Always keeps room for the NUL terminator and writes it after the text,
 * so the buffer holds a valid C string even when the name is cut short.
 *
 * @since 1.0.0
 */

function putText(out: *Out, text: string): void {
    for (const c of text) {
        if (out.used + 1 >= out.buf.len) break;
        out.buf[out.used] = c;
        out.used += 1;
    }
    out.buf[out.used] = 0;
}

/**
 * Appends a number in decimal to a buffer.
 *
 * @param out - The buffer
 * @param value - The number to append
 *
 * @remarks
 * Builds the digits from the right into a 20-byte scratch array, which fits any `u64`,
 * then passes them to {@link putText}, so a long number is cut short like any other text.
 *
 * @since 1.0.0
 */

function putNumber(out: *Out, value: u64): void {
    let digits: u8[20] = undefined;
    let n: usize = 0;
    let v = value;
    while (true) {
        digits[19 - n] = '0' + @truncate(u8, v % 10);
        n += 1;
        v /= 10;
        if (v == 0) break;
    }
    putText(out, digits[20 - n..20]);
}

/**
 * Writes the readable name of a type into a buffer.
 *
 * @param types - The type table
 * @param id - The type
 * @param out - The buffer
 *
 * @remarks
 * The id of `string` prints as `string`, which reads better than `readonly u8[]`.
 * A nominal type without a name prints as `anonymous struct` or `anonymous type`.
 *
 * @since 1.0.0
 */

function writeName(types: readonly *HxTypes, id: u32, out: *Out): void {
    if (id == types.string) {   // the built-in alias reads better than `readonly u8[]`
        putText(out, "string");
        return;
    }
    const t = typeAt(types, id);
    switch (t.kind) {
        case TypeKind.Invalid: putText(out, "<invalid>");
        case TypeKind.Void: putText(out, "void");
        case TypeKind.Bool: putText(out, "bool");
        case TypeKind.Noreturn: putText(out, "noreturn");
        case TypeKind.ComptimeInt: putText(out, "integer literal");
        case TypeKind.ComptimeFloat: putText(out, "float literal");
        case TypeKind.Undefined: putText(out, "undefined");
        case TypeKind.StringLiteral: putText(out, "string literal");
        case TypeKind.Format: putText(out, "Format");
        case TypeKind.Null: putText(out, "null");
        case TypeKind.Int: {
            putText(out, (t.flags & Signed) != 0 ? "i" : "u");
            putNumber(out, t.bits as u64);
        }
        case TypeKind.Float: {
            putText(out, "f");
            putNumber(out, t.bits as u64);
        }
        case TypeKind.Pointer, TypeKind.ManyPointer, TypeKind.Slice: {
            if ((t.flags & Readonly) != 0) putText(out, "readonly ");
            if (t.kind == TypeKind.Pointer) putText(out, "*");
            writeName(types, t.child, out);
            if (t.kind == TypeKind.Slice) putText(out, "[]");
            if (t.kind == TypeKind.ManyPointer) putText(out, "[*]");
        }
        case TypeKind.Array: {
            writeName(types, t.child, out);
            putText(out, "[");
            putNumber(out, t.len);
            putText(out, "]");
        }
        case TypeKind.Optional: {
            putText(out, "?");
            writeName(types, t.child, out);
        }
        case TypeKind.ErrorUnion: {
            writeName(types, t.child, out);
            putText(out, " | ");
            writeName(types, @truncate(u32, t.len), out);
        }
        case TypeKind.Struct, TypeKind.Enum, TypeKind.Union, TypeKind.ErrorSet, TypeKind.Interface: {
            if (const name = t.name) {
                unsafe {
                    putText(out, name[0..t.nameLen]);
                }
            } else {
                putText(out, t.kind == TypeKind.Struct ? "anonymous struct" : "anonymous type");
            }
        }
        case TypeKind.Dyn: {
            putText(out, "dyn ");
            writeName(types, t.child, out);
        }
        case TypeKind.Function: {
            putText(out, (t.flags & CCall) != 0 ? "extern \"C\" (" : "(");
            for (const i of 0..t.len) {
                if (i > 0) putText(out, ", ");
                writeName(types, paramAt(types, (t.params as u64) + i), out);
            }
            if ((t.flags & Variadic) != 0) putText(out, t.len > 0 ? ", ..." : "...");
            putText(out, ") => ");
            writeName(types, t.child, out);
        }
        default: {}
    }
}

/**
 * Writes the readable name of a type, such as `readonly u8[]` or `(i32, i32) => i32`.
 *
 * @param types - The type table
 * @param id - The type
 * @param buf - The buffer to write into
 * @param size - The size of the buffer in bytes
 *
 * @remarks
 * The name is NUL-terminated within the first `size` bytes, and what does not fit is dropped.
 * A size of 0 writes nothing.
 * Literal types print as `integer literal`, `float literal`, and `string literal`, and id 0 prints as `<invalid>`.
 *
 * @example
 * ```hx
 * let buf: u8[64] = undefined;
 * hxTypeName(&types, hxTypeOptional(&types, types.string), &buf, 64); // buf holds ?string
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxTypeName(types: readonly *HxTypes, id: u32, buf: u8[*], size: usize): void {
    if (size == 0) return;
    let out = Out { buf: [], used: 0 };
    unsafe {
        out.buf = buf[0..size];
    }
    out.buf[0] = 0;
    writeName(types, id, &out);
}
