/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { emit, hint, hxDiagListFree } from "@models/diagnostic.model";
import { DiagError, DiagWarning } from "@constants/diagnostic.constant";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { hxDiagRender, hxDiagRenderLocation } from "@components/diagnostic.component";

/**
 * The C library functions that capture the rendered output in memory.
 *
 * @since 1.0.0
 */

extern "C" function open_memstream(buffer: *?u8[*], size: *usize): ?u8[*];
extern "C" function fclose(file: ?u8[*]): i32;
extern "C" function free(ptr: ?u8[*]): void;

/**
 * Tests
 */

let captured: u8[1024] = undefined;
let streamBuffer: ?u8[*] = null;
let streamSize: usize = 0;

/**
 * Opens an in-memory C stream for the renderer to write to.
 *
 * @returns The new stream, which {@link finish} closes
 *
 * @remarks
 * The stream writes into the `streamBuffer` and `streamSize` globals,
 * which must outlive the call because `open_memstream` updates them on every flush.
 *
 * @since 1.0.0
 */

function capture(): ?u8[*] {
    return open_memstream(&streamBuffer, &streamSize);
}

/**
 * Closes the stream and returns everything written to it.
 *
 * @param file - The stream that {@link capture} opened
 * @returns The written text, cut at 1024 bytes
 *
 * @remarks
 * It copies the text into the shared `captured` buffer and frees the stream's buffer,
 * so the next call overwrites the text that this one returned.
 *
 * @since 1.0.0
 */

function finish(file: ?u8[*]): string {
    void fclose(file);
    const n = streamSize < captured.len ? streamSize : captured.len;
    unsafe {
        for (const i of 0..n) captured[i] = streamBuffer![i];
    }
    free(streamBuffer);
    streamBuffer = null;
    return captured[0..n];
}

/**
 * Returns an empty diagnostic list.
 *
 * @returns A list without items, errors, or arena chunks
 *
 * @remarks
 * The specs fill it with `emit` and `hint` and free it with `hxDiagListFree`.
 *
 * @since 1.0.0
 */

function emptyList(): HxDiagList {
    return HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
}

describe("hxDiagRenderLocation") {
    test("should write the location and underline the span without color") {
        let src: HxSource = undefined;
        hxSourceFromString(&src, "main.hx", "let a = 1;", 10);
        defer hxSourceFree(&src);
        const out = capture();
        hxDiagRenderLocation(out, &src, 4, 1);

        expect(finish(out)).toBe(" --> main.hx:1:5\n  |\n1 | let a = 1;\n  |     ^\n");
    }

    test("should underline every byte of a longer span") {
        let src: HxSource = undefined;
        hxSourceFromString(&src, "main.hx", "let name = 1;", 13);
        defer hxSourceFree(&src);
        const out = capture();
        hxDiagRenderLocation(out, &src, 4, 4);

        expect(finish(out)).toInclude("|     ^~~~\n");
    }

    test("should expand tabs so the underline lines up") {
        let src: HxSource = undefined;
        hxSourceFromString(&src, "main.hx", "\tx", 2);
        defer hxSourceFree(&src);
        const out = capture();
        hxDiagRenderLocation(out, &src, 1, 1);

        expect(finish(out)).toInclude("1 |     x\n  |     ^\n");
    }

    test("should underline only the first line of a span over several lines") {
        let src: HxSource = undefined;
        hxSourceFromString(&src, "main.hx", "ab\ncd", 5);
        defer hxSourceFree(&src);
        const out = capture();
        hxDiagRenderLocation(out, &src, 0, 5);

        expect(finish(out)).toInclude("1 | ab\n  | ^~\n");
    }

    test("should widen the gutter for a line number of several digits") {
        let src: HxSource = undefined;
        const text = "\n\n\n\n\n\n\n\n\n\nx";
        hxSourceFromString(&src, "main.hx", text.ptr, text.len);
        defer hxSourceFree(&src);
        const out = capture();
        hxDiagRenderLocation(out, &src, 10, 1);

        expect(finish(out)).toBe("  --> main.hx:11:1\n   |\n11 | x\n   | ^\n");
    }
}

describe("hxDiagRender") {
    test("should write each diagnostic with its level, location and hint") {
        let src: HxSource = undefined;
        hxSourceFromString(&src, "main.hx", "let a = 1;", 10);
        defer hxSourceFree(&src);
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        const diag = emit(&diags, DiagError, &src, 4, 1, "bad name");
        hint(&diags, diag, "rename it");
        const out = capture();
        hxDiagRender(&diags, out, false);

        expect(finish(out)).toBe("error: bad name\n --> main.hx:1:5\n  |\n1 | let a = 1;\n  |     ^\n  = hint: rename it\n\n");
    }

    test("should write only the message of a diagnostic without a location") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        void emit(&diags, DiagWarning, null, 0, 0, "no input files");
        const out = capture();
        hxDiagRender(&diags, out, false);

        expect(finish(out)).toBe("warning: no input files\n\n");
    }

    test("should color the level and the gutter when asked") {
        let diags = emptyList();
        defer hxDiagListFree(&diags);
        void emit(&diags, DiagError, null, 0, 0, "oops");
        const out = capture();
        hxDiagRender(&diags, out, true);

        expect(finish(out)).toBe("\x1b[1;31merror\x1b[0m: \x1b[1moops\x1b[0m\n\n");
    }

    test("should write nothing for an empty list") {
        let diags = emptyList();
        const out = capture();
        hxDiagRender(&diags, out, false);

        expect(finish(out)).toBe("");
    }
}
