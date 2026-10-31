/**
 * Imports
 */

import { HxInterner } from "@services/structs/intern-service.struct";
import { hxInternerInit, hxInternerFree, hxIntern, hxNameText } from "@services/intern.service";

/**
 * Tests
 */

/**
 * Returns the text of an id as a string.
 *
 * @param interner - The interner that handed out the id
 * @param id - The id to look up
 * @returns The text of the id, or an empty string when the text has no bytes
 *
 * @remarks
 * It wraps `hxNameText`, which returns a pointer and a length, so the specs can compare against a string.
 *
 * @since 1.0.0
 */

function textOf(interner: readonly *HxInterner, id: u32): string {
    let len: u32 = 0;
    const text = hxNameText(interner, id, &len);
    unsafe {
        return len > 0 ? text![0..len] : "";
    }
}

describe("hxInternerInit") {
    test("should reserve id 0 for no name") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);

        expect(interner.count).toBe(1);
        hxInternerFree(&interner);
    }
}

describe("hxInternerFree") {
    test("should leave the interner empty") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);
        void hxIntern(&interner, "main", 4);
        hxInternerFree(&interner);

        expect(interner.count).toBe(0);
        expect(interner.chars).toBeNull();
    }
}

describe("hxIntern") {
    test("should hand out ids from 1 in the order that strings arrive") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);

        expect(hxIntern(&interner, "main", 4)).toBe(1);
        expect(hxIntern(&interner, "add", 3)).toBe(2);
        hxInternerFree(&interner);
    }

    test("should give the same text the same id") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);
        const first = hxIntern(&interner, "main", 4);
        void hxIntern(&interner, "add", 3);

        expect(hxIntern(&interner, "main", 4)).toBe(first);
        hxInternerFree(&interner);
    }

    test("should read only the given length of the text") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);
        const short = hxIntern(&interner, "mainline", 4);

        expect(hxIntern(&interner, "main", 4)).toBe(short);
        hxInternerFree(&interner);
    }

    test("should give an empty text an id of its own") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);
        const empty = hxIntern(&interner, "", 0);

        expect(empty).not.toBe(0);
        expect(hxIntern(&interner, "", 0)).toBe(empty);
        hxInternerFree(&interner);
    }

    test("should keep every id after the table and the buffers grow") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);
        let name: u8[4] = ['a', 'a', 'a', 'a'];
        for (const i of 0..2000) {
            name[0] = @truncate(u8, 'a' + i % 26);
            name[1] = @truncate(u8, 'a' + (i / 26) % 26);
            name[2] = @truncate(u8, 'a' + (i / 676) % 26);
            void hxIntern(&interner, &name, 4);
        }

        expect(interner.count).toBe(2001);
        expect(interner.slotsCap > 2048).toBe(true);
        expect(hxIntern(&interner, "aaaa", 4)).toBe(1);
        expect(textOf(&interner, 2)).toBe("baaa");
        hxInternerFree(&interner);
    }
}

describe("hxNameText") {
    test("should return the text and the length of an id") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);
        void hxIntern(&interner, "main", 4);
        const id = hxIntern(&interner, "add", 3);

        expect(textOf(&interner, id)).toBe("add");
        hxInternerFree(&interner);
    }

    test("should return null while the interner holds no text") {
        let interner: HxInterner = undefined;
        hxInternerInit(&interner);
        let len: u32 = 9;

        expect(hxNameText(&interner, 0, &len)).toBeNull();
        expect(len).toBe(0);
        hxInternerFree(&interner);
    }
}
