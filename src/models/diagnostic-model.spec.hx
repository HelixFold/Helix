/**
 * Imports
 */

import { strlen } from "std/c";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { DiagError, DiagWarning, DiagNote } from "@constants/diagnostic.constant";
import { emit, hint, hxDiagListFree, emitf, hintf } from "@models/diagnostic.model";

/**
 * Tests
 */

/**
 * A NUL-terminated string as a slice.
 *
 * @param text - Pointer to the first byte of a NUL-terminated string
 * @returns The bytes before the terminator, without copying them
 *
 * @remarks
 * Measures the string with `strlen`, so the slice borrows the original memory
 * and stays valid only as long as that memory does.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * An empty diagnostic list.
 *
 * @returns A list without items, an empty arena, and an error count of zero
 *
 * @remarks
 * Allocates nothing, so a test may free it with `hxDiagListFree` whether or not it emitted anything.
 *
 * @since 1.0.0
 */

function emptyList(): HxDiagList {
    return HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
}

describe("emit") {
    test("should add diagnostics in order and return their indexes") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);

        expect(emit(&diags, DiagError, null, 0, 0, "first")).toBe(0);
        expect(emit(&diags, DiagNote, null, 0, 0, "second")).toBe(1);
        expect(diags.itemsLen).toBe(2);
        unsafe {
            expect(cString(diags.items![1].message)).toBe("second");
        }
    }

    test("should count only errors") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        void emit(&diags, DiagError, null, 0, 0, "an error");
        void emit(&diags, DiagWarning, null, 0, 0, "a warning");
        void emit(&diags, DiagNote, null, 0, 0, "a note");

        expect(diags.errorCount).toBe(1);
    }

    test("should keep the span and the source") {
        let src: HxSource = undefined;
        hxSourceFromString(&src, "main.hx", "let a = 1;", 10);
        defer hxSourceFree(&src);
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        void emit(&diags, DiagError, &src, 4, 1, "here");

        unsafe {
            expect(diags.items![0].start).toBe(4);
            expect(diags.items![0].len).toBe(1);
            expect(diags.items![0].src).not.toBeNull();
            expect(diags.items![0].hint).toBeNull();
        }
    }

    test("should copy the message, so the caller may reuse its own") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        let message: u8[3] = ['a', 'b', 'c'];
        void emit(&diags, DiagError, null, 0, 0, &message);
        message[0] = 'z';

        unsafe {
            expect(cString(diags.items![0].message)).toBe("abc");
        }
    }
}

describe("hint") {
    test("should attach a hint to the diagnostic at the index") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        void emit(&diags, DiagError, null, 0, 0, "first");
        const second = emit(&diags, DiagError, null, 0, 0, "second");
        hint(&diags, second, "the fix");

        unsafe {
            expect(diags.items![0].hint).toBeNull();
            expect(cString(diags.items![1].hint!)).toBe("the fix");
        }
    }

    test("should replace an earlier hint") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        const diag = emit(&diags, DiagError, null, 0, 0, "message");
        hint(&diags, diag, "old");
        hint(&diags, diag, "new");

        unsafe {
            expect(cString(diags.items![0].hint!)).toBe("new");
        }
    }
}

describe("hxDiagListFree") {
    test("should leave the list empty and ready for reuse") {
        let diags = emptyList();
        void emit(&diags, DiagError, null, 0, 0, "message");
        hxDiagListFree(&diags);

        expect(diags.itemsLen).toBe(0);
        expect(diags.errorCount).toBe(0);
        expect(diags.arena.head).toBeNull();
        expect(emit(&diags, DiagError, null, 0, 0, "again")).toBe(0);
        hxDiagListFree(&diags);
    }
}

describe("emitf") {
    test("should format the message from a template") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        const what = "a name";
        const count: u32 = 2;
        void emitf(&diags, DiagError, null, 0, 0, `expected ${what}, found ${count}`);

        unsafe {
            expect(cString(diags.items![0].message)).toBe("expected a name, found 2");
        }
        expect(diags.errorCount).toBe(1);
    }
}

describe("hintf") {
    test("should format the hint from a template") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        const diag = emit(&diags, DiagError, null, 0, 0, "message");
        const name = "beforeAll";
        hintf(&diags, diag, `write \`${name} { ... }\``);

        unsafe {
            expect(cString(diags.items![0].hint!)).toBe("write `beforeAll { ... }`");
        }
    }
}
