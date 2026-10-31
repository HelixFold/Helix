/**
 * Imports
 */

import { HxInterner } from "@services/structs/intern-service.struct";
import { hx_interner_init, hx_interner_free, hx_intern, hx_name_text } from "@services/intern.service";

/**
 * Tests
 */

/**
 * The text of an id, as a string.
 */

function textOf(interner: readonly *HxInterner, id: u32): string {
    let len: u32 = 0;
    const text = hx_name_text(interner, id, &len);
    unsafe {
        return len > 0 ? text![0..len] : "";
    }
}

describe("hx_interner_init") {
    test("should reserve id 0 for no name") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);

        expect(interner.count).toBe(1);
        hx_interner_free(&interner);
    }
}

describe("hx_interner_free") {
    test("should leave the interner empty") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);
        void hx_intern(&interner, "main", 4);
        hx_interner_free(&interner);

        expect(interner.count).toBe(0);
        expect(interner.chars).toBeNull();
    }
}

describe("hx_intern") {
    test("should hand out ids from 1 in the order that strings arrive") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);

        expect(hx_intern(&interner, "main", 4)).toBe(1);
        expect(hx_intern(&interner, "add", 3)).toBe(2);
        hx_interner_free(&interner);
    }

    test("should give the same text the same id") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);
        const first = hx_intern(&interner, "main", 4);
        void hx_intern(&interner, "add", 3);

        expect(hx_intern(&interner, "main", 4)).toBe(first);
        hx_interner_free(&interner);
    }

    test("should read only the given length of the text") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);
        const short = hx_intern(&interner, "mainline", 4);

        expect(hx_intern(&interner, "main", 4)).toBe(short);
        hx_interner_free(&interner);
    }

    test("should give an empty text an id of its own") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);
        const empty = hx_intern(&interner, "", 0);

        expect(empty).not.toBe(0);
        expect(hx_intern(&interner, "", 0)).toBe(empty);
        hx_interner_free(&interner);
    }

    test("should keep every id after the table and the buffers grow") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);
        let name: u8[4] = ['a', 'a', 'a', 'a'];
        for (const i of 0..2000) {
            name[0] = @truncate(u8, 'a' + i % 26);
            name[1] = @truncate(u8, 'a' + (i / 26) % 26);
            name[2] = @truncate(u8, 'a' + (i / 676) % 26);
            void hx_intern(&interner, &name, 4);
        }

        expect(interner.count).toBe(2001);
        expect(interner.slots_cap > 2048).toBe(true);
        expect(hx_intern(&interner, "aaaa", 4)).toBe(1);
        expect(textOf(&interner, 2)).toBe("baaa");
        hx_interner_free(&interner);
    }
}

describe("hx_name_text") {
    test("should return the text and the length of an id") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);
        void hx_intern(&interner, "main", 4);
        const id = hx_intern(&interner, "add", 3);

        expect(textOf(&interner, id)).toBe("add");
        hx_interner_free(&interner);
    }

    test("should return null while the interner holds no text") {
        let interner: HxInterner = undefined;
        hx_interner_init(&interner);
        let len: u32 = 9;

        expect(hx_name_text(&interner, 0, &len)).toBeNull();
        expect(len).toBe(0);
        hx_interner_free(&interner);
    }
}
