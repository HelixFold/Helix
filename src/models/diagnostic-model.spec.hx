/**
 * Imports
 */

import { strlen } from "std/c";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { hx_source_from_string, hx_source_free } from "@models/source.model";
import { DIAG_ERROR, DIAG_WARNING, DIAG_NOTE } from "@constants/diagnostic.constant";
import { emit, hint, hx_diag_list_free, emitf, hintf } from "@models/diagnostic.model";

/**
 * Tests
 */

/**
 * A NUL-terminated string as a slice.
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * An empty diagnostic list.
 */

function emptyList(): HxDiagList {
    return HxDiagList { items: null, items_len: 0, items_cap: 0, arena: HxArena { head: null }, error_count: 0 };
}

describe("emit") {
    test("should add diagnostics in order and return their indexes") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);

        expect(emit(&diags, DIAG_ERROR, null, 0, 0, "first")).toBe(0);
        expect(emit(&diags, DIAG_NOTE, null, 0, 0, "second")).toBe(1);
        expect(diags.items_len).toBe(2);
        unsafe {
            expect(cString(diags.items![1].message)).toBe("second");
        }
    }

    test("should count only errors") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        void emit(&diags, DIAG_ERROR, null, 0, 0, "an error");
        void emit(&diags, DIAG_WARNING, null, 0, 0, "a warning");
        void emit(&diags, DIAG_NOTE, null, 0, 0, "a note");

        expect(diags.error_count).toBe(1);
    }

    test("should keep the span and the source") {
        let src: HxSource = undefined;
        hx_source_from_string(&src, "main.hx", "let a = 1;", 10);
        defer hx_source_free(&src);
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        void emit(&diags, DIAG_ERROR, &src, 4, 1, "here");

        unsafe {
            expect(diags.items![0].start).toBe(4);
            expect(diags.items![0].len).toBe(1);
            expect(diags.items![0].src).not.toBeNull();
            expect(diags.items![0].hint).toBeNull();
        }
    }

    test("should copy the message, so the caller may reuse its own") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        let message: u8[3] = ['a', 'b', 'c'];
        void emit(&diags, DIAG_ERROR, null, 0, 0, &message);
        message[0] = 'z';

        unsafe {
            expect(cString(diags.items![0].message)).toBe("abc");
        }
    }
}

describe("hint") {
    test("should attach a hint to the diagnostic at the index") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        void emit(&diags, DIAG_ERROR, null, 0, 0, "first");
        const second = emit(&diags, DIAG_ERROR, null, 0, 0, "second");
        hint(&diags, second, "the fix");

        unsafe {
            expect(diags.items![0].hint).toBeNull();
            expect(cString(diags.items![1].hint!)).toBe("the fix");
        }
    }

    test("should replace an earlier hint") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        const diag = emit(&diags, DIAG_ERROR, null, 0, 0, "message");
        hint(&diags, diag, "old");
        hint(&diags, diag, "new");

        unsafe {
            expect(cString(diags.items![0].hint!)).toBe("new");
        }
    }
}

describe("hx_diag_list_free") {
    test("should leave the list empty and ready for reuse") {
        let diags = emptyList();
        void emit(&diags, DIAG_ERROR, null, 0, 0, "message");
        hx_diag_list_free(&diags);

        expect(diags.items_len).toBe(0);
        expect(diags.error_count).toBe(0);
        expect(diags.arena.head).toBeNull();
        expect(emit(&diags, DIAG_ERROR, null, 0, 0, "again")).toBe(0);
        hx_diag_list_free(&diags);
    }
}

describe("emitf") {
    test("should format the message from a template") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        const what = "a name";
        const count: u32 = 2;
        void emitf(&diags, DIAG_ERROR, null, 0, 0, `expected ${what}, found ${count}`);

        unsafe {
            expect(cString(diags.items![0].message)).toBe("expected a name, found 2");
        }
        expect(diags.error_count).toBe(1);
    }
}

describe("hintf") {
    test("should format the hint from a template") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        const diag = emit(&diags, DIAG_ERROR, null, 0, 0, "message");
        const name = "beforeAll";
        hintf(&diags, diag, `write \`${name} { ... }\``);

        unsafe {
            expect(cString(diags.items![0].hint!)).toBe("write `beforeAll { ... }`");
        }
    }
}
