/**
 * Imports
 */

import { strlen } from "std/c";
import { HxTypes } from "@models/structs/types-model.struct";
import { TypeKind, Readonly, Variadic, CCall } from "@constants/types.constant";
import { hxTypeInt, hxTypePointer, hxTypeArray, hxTypeOptional, hxTypesInit } from "@models/types.model";
import { hxTypeFunctionFlags, hxTypeFunction, hxTypeFunctionC, hxTypeErrorUnion } from "@models/types.model";
import { hxTypeNominal, hxTypeReadonly, hxTypesFree, hxTypeBuiltin, hxTypeSize, hxTypeName } from "@models/types.model";

/**
 * Tests
 */

let nameBuffer: u8[160] = undefined;

/**
 * A type table for a target with pointers of the given size.
 *
 * @param pointerBytes - Size of a pointer on the target, in bytes
 * @returns A table that holds the built-in types
 *
 * @remarks
 * The pointer size decides whether `usize` and `isize` are 32 or 64 bits wide,
 * and it sets the size of every pointer, slice, and function type.
 * The caller frees the result with `hxTypesFree`.
 *
 * @since 1.0.0
 */

function tableOf(pointerBytes: u32): HxTypes {
    let types: HxTypes = undefined;
    hxTypesInit(&types, pointerBytes);
    return types;
}

/**
 * The readable name of a type, valid until the next call.
 *
 * @param types - Table that holds the type
 * @param id - Type to name
 * @returns The name that `hxTypeName` wrote into the shared buffer
 *
 * @remarks
 * Every call writes into the same 160-byte module buffer,
 * so a test compares the result before it names another type.
 *
 * @since 1.0.0
 */

function nameOf(types: readonly *HxTypes, id: u32): string {
    hxTypeName(types, id, &nameBuffer, 160);
    unsafe {
        return nameBuffer[0..strlen(&nameBuffer)];
    }
}

/**
 * The flags of a type.
 *
 * @param types - Table that holds the type
 * @param id - Type to inspect
 * @returns The flag bits stored on the type's entry
 *
 * @remarks
 * Reads the entry directly and does not check that the id is in range.
 *
 * @since 1.0.0
 */

function flagsOf(types: readonly *HxTypes, id: u32): u8 {
    unsafe {
        return types.items![id].flags;
    }
}

/**
 * Bytes viewed as a readonly string.
 *
 * @param bytes - Bytes to view
 * @returns The same bytes as a string, without copying them
 *
 * @remarks
 * Lets `toBe` compare a byte slice that a test filled against a string literal.
 *
 * @since 1.0.0
 */

function asText(bytes: readonly u8[]): string {
    return bytes;
}

describe("hxTypeInt") {
    test("should return the built-in id for a built-in width") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeInt(&types, true, 32)).toBe(types.i32);
        expect(hxTypeInt(&types, false, 8)).toBe(types.u8);
    }

    test("should give one id to the same width asked twice") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const first = hxTypeInt(&types, false, 7);

        expect(hxTypeInt(&types, false, 7)).toBe(first);
        expect(nameOf(&types, first)).toBe("u7");
    }

    test("should keep a signed and an unsigned type apart") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeInt(&types, true, 16) == hxTypeInt(&types, false, 16)).toBe(false);
    }
}

describe("hxTypePointer") {
    test("should build each pointer-like kind") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(nameOf(&types, hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, false))).toBe("*i32");
        expect(nameOf(&types, hxTypePointer(&types, TypeKind.ManyPointer as u32, types.u8, true)))
            .toBe("readonly u8[*]");
        expect(nameOf(&types, hxTypePointer(&types, TypeKind.Slice as u32, types.i32, false))).toBe("i32[]");
    }

    test("should return the string id for a readonly slice of u8") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypePointer(&types, TypeKind.Slice as u32, types.u8, true)).toBe(types.string);
    }

    test("should keep a readonly pointer apart from a mutable one") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const mutable = hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, false);
        const readonly = hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, true);

        expect(mutable == readonly).toBe(false);
        expect((flagsOf(&types, readonly) & Readonly) != 0).toBe(true);
    }
}

describe("hxTypeArray") {
    test("should give arrays of different lengths different ids") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const four = hxTypeArray(&types, types.u8, 4);

        expect(hxTypeArray(&types, types.u8, 4)).toBe(four);
        expect(hxTypeArray(&types, types.u8, 5) == four).toBe(false);
        expect(nameOf(&types, four)).toBe("u8[4]");
    }
}

describe("hxTypeFunctionFlags") {
    test("should keep the flags it is given") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const params: u32[1] = [types.i32];
        const fn = hxTypeFunctionFlags(&types, types.voidType, &params, 1, CCall | Variadic);

        expect(nameOf(&types, fn)).toBe("extern \"C\" (i32, ...) => void");
    }
}

describe("hxTypeFunction") {
    test("should give one id to equal signatures") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const params: u32[2] = [types.i32, types.i32];
        const first = hxTypeFunction(&types, types.boolType, &params, 2, false);
        const before = types.paramsLen;

        expect(hxTypeFunction(&types, types.boolType, &params, 2, false)).toBe(first);
        expect(types.paramsLen).toBe(before);
        expect(nameOf(&types, first)).toBe("(i32, i32) => bool");
    }

    test("should tell signatures apart by their parameters") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const a: u32[1] = [types.i32];
        const b: u32[1] = [types.i64];

        expect(hxTypeFunction(&types, types.voidType, &a, 1, false) ==
               hxTypeFunction(&types, types.voidType, &b, 1, false)).toBe(false);
    }

    test("should name a variadic function without parameters") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(nameOf(&types, hxTypeFunction(&types, types.i32, null, 0, true))).toBe("(...) => i32");
    }
}

describe("hxTypeFunctionC") {
    test("should switch a function type to the C calling convention and back") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const params: u32[1] = [types.u8];
        const fn = hxTypeFunction(&types, types.voidType, &params, 1, false);
        const c = hxTypeFunctionC(&types, fn, true);

        expect((flagsOf(&types, c) & CCall) != 0).toBe(true);
        expect(hxTypeFunctionC(&types, c, false)).toBe(fn);
    }

    test("should return the same id when the convention already matches") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const fn = hxTypeFunction(&types, types.voidType, null, 0, false);

        expect(hxTypeFunctionC(&types, fn, false)).toBe(fn);
    }
}

describe("hxTypeOptional") {
    test("should name the optional after its payload") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const opt = hxTypeOptional(&types, types.string);

        expect(hxTypeOptional(&types, types.string)).toBe(opt);
        expect(nameOf(&types, opt)).toBe("?string");
    }
}

describe("hxTypeErrorUnion") {
    test("should name the payload and the error set") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(nameOf(&types, hxTypeErrorUnion(&types, types.i32, types.anyError))).toBe("i32 | Error");
    }
}

describe("hxTypeNominal") {
    test("should make each aggregate its own type even with the same name") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const a = hxTypeNominal(&types, TypeKind.Struct as u32, 0, 0, "Point", 5);
        const b = hxTypeNominal(&types, TypeKind.Struct as u32, 1, 0, "Point", 5);

        expect(a == b).toBe(false);
        expect(nameOf(&types, a)).toBe("Point");
    }

    test("should name an anonymous struct and an anonymous enum") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(nameOf(&types, hxTypeNominal(&types, TypeKind.Struct as u32, 0, 0, null, 0))).toBe("anonymous struct");
        expect(nameOf(&types, hxTypeNominal(&types, TypeKind.Enum as u32, 1, types.u8, null, 0)))
            .toBe("anonymous type");
    }
}

describe("hxTypeReadonly") {
    test("should set the readonly flag on a pointer") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        const p = hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, false);

        expect(hxTypeReadonly(&types, p)).toBe(hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, true));
    }

    test("should leave a type that is not pointer-like unchanged") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeReadonly(&types, types.i32)).toBe(types.i32);
    }
}

describe("hxTypesInit") {
    test("should reserve id 0 for the invalid type") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(nameOf(&types, 0)).toBe("<invalid>");
    }

    test("should make usize the 64-bit integer on a 64-bit target") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(types.usize).toBe(types.u64);
        expect(types.isize).toBe(types.i64);
    }

    test("should make usize the 32-bit integer on a 32-bit target") {
        let types = tableOf(4);
        defer hxTypesFree(&types);

        expect(types.usize).toBe(types.u32);
        expect(types.pointerBytes).toBe(4);
    }

    test("should use u16 for the error code") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(types.errorCode).toBe(types.u16);
    }
}

describe("hxTypesFree") {
    test("should leave the table empty") {
        let types = tableOf(8);
        hxTypesFree(&types);

        expect(types.itemsLen).toBe(0);
        expect(types.slotsCap).toBe(0);
    }
}

describe("hxTypeBuiltin") {
    test("should find the named built-in types") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeBuiltin(&types, "string", 6)).toBe(types.string);
        expect(hxTypeBuiltin(&types, "Error", 5)).toBe(types.anyError);
        expect(hxTypeBuiltin(&types, "usize", 5)).toBe(types.usize);
    }

    test("should accept any integer width written without leading zeros") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeBuiltin(&types, "i32", 3)).toBe(types.i32);
        expect(hxTypeBuiltin(&types, "u65535", 6)).toBe(hxTypeInt(&types, false, 65535));
    }

    test("should return 0 for a name that is not a built-in type") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeBuiltin(&types, "u07", 3)).toBe(0);
        expect(hxTypeBuiltin(&types, "u65536", 6)).toBe(0);
        expect(hxTypeBuiltin(&types, "u8x", 3)).toBe(0);
        expect(hxTypeBuiltin(&types, "Point", 5)).toBe(0);
    }
}

describe("hxTypeSize") {
    test("should round integers up to a power of two bytes") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeSize(&types, types.u8)).toBe(1);
        expect(hxTypeSize(&types, hxTypeInt(&types, false, 24))).toBe(4);
        expect(hxTypeSize(&types, types.f64)).toBe(8);
    }

    test("should size pointers and slices after the target") {
        let types = tableOf(4);
        defer hxTypesFree(&types);
        const p = hxTypePointer(&types, TypeKind.Pointer as u32, types.i32, false);

        expect(hxTypeSize(&types, p)).toBe(4);
        expect(hxTypeSize(&types, types.string)).toBe(8);
    }

    test("should multiply the element size of an array") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeSize(&types, hxTypeArray(&types, types.u16, 3))).toBe(6);
    }

    test("should return 0 for an optional") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(hxTypeSize(&types, hxTypeOptional(&types, types.i32))).toBe(0);
    }
}

describe("hxTypeName") {
    test("should name the literal types") {
        let types = tableOf(8);
        defer hxTypesFree(&types);

        expect(nameOf(&types, types.comptimeInt)).toBe("integer literal");
        expect(nameOf(&types, types.stringLiteral)).toBe("string literal");
    }

    test("should write a whole name that fits in the buffer") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        let small: u8[8] = undefined;
        hxTypeName(&types, hxTypePointer(&types, TypeKind.Slice as u32, types.u8, false), &small, 8);

        unsafe {
            expect(asText(small[0..strlen(&small)])).toBe("u8[]");
        }
    }

    test("should cut a long name at the buffer size") {
        let types = tableOf(8);
        defer hxTypesFree(&types);
        let small: u8[4] = undefined;
        hxTypeName(&types, types.stringLiteral, &small, 4);

        unsafe {
            expect(asText(small[0..strlen(&small)])).toBe("str");
        }
    }
}
