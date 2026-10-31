/**
 * Imports
 */

import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { DIAG_ERROR, DIAG_WARNING } from "@constants/diagnostic.constant";
import { emit, hint, hx_diag_list_free } from "@models/diagnostic.model";
import { hx_source_from_string, hx_source_free } from "@models/source.model";
import { hx_diag_render, hx_diag_render_location } from "@components/diagnostic.component";

/**
 * The C library functions that capture the rendered output in memory.
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
 * Opens an in-memory C stream that writes into the globals above, which outlive the call.
 */

function capture(): ?u8[*] {
    return open_memstream(&streamBuffer, &streamSize);
}

/**
 * Closes the stream and returns everything written to it.
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
 * An empty diagnostic list.
 */

function emptyList(): HxDiagList {
    return HxDiagList { items: null, items_len: 0, items_cap: 0, arena: HxArena { head: null }, error_count: 0 };
}

describe("hx_diag_render_location") {
    test("should write the location and underline the span without color") {
        let src: HxSource = undefined;
        hx_source_from_string(&src, "main.hx", "let a = 1;", 10);
        defer hx_source_free(&src);
        const out = capture();
        hx_diag_render_location(out, &src, 4, 1);

        expect(finish(out)).toBe(" --> main.hx:1:5\n  |\n1 | let a = 1;\n  |     ^\n");
    }

    test("should underline every byte of a longer span") {
        let src: HxSource = undefined;
        hx_source_from_string(&src, "main.hx", "let name = 1;", 13);
        defer hx_source_free(&src);
        const out = capture();
        hx_diag_render_location(out, &src, 4, 4);

        expect(finish(out)).toInclude("|     ^~~~\n");
    }

    test("should expand tabs so the underline lines up") {
        let src: HxSource = undefined;
        hx_source_from_string(&src, "main.hx", "\tx", 2);
        defer hx_source_free(&src);
        const out = capture();
        hx_diag_render_location(out, &src, 1, 1);

        expect(finish(out)).toInclude("1 |     x\n  |     ^\n");
    }

    test("should underline only the first line of a span over several lines") {
        let src: HxSource = undefined;
        hx_source_from_string(&src, "main.hx", "ab\ncd", 5);
        defer hx_source_free(&src);
        const out = capture();
        hx_diag_render_location(out, &src, 0, 5);

        expect(finish(out)).toInclude("1 | ab\n  | ^~\n");
    }

    test("should widen the gutter for a line number of several digits") {
        let src: HxSource = undefined;
        const text = "\n\n\n\n\n\n\n\n\n\nx";
        hx_source_from_string(&src, "main.hx", text.ptr, text.len);
        defer hx_source_free(&src);
        const out = capture();
        hx_diag_render_location(out, &src, 10, 1);

        expect(finish(out)).toBe("  --> main.hx:11:1\n   |\n11 | x\n   | ^\n");
    }
}

describe("hx_diag_render") {
    test("should write each diagnostic with its level, location and hint") {
        let src: HxSource = undefined;
        hx_source_from_string(&src, "main.hx", "let a = 1;", 10);
        defer hx_source_free(&src);
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        const diag = emit(&diags, DIAG_ERROR, &src, 4, 1, "bad name");
        hint(&diags, diag, "rename it");
        const out = capture();
        hx_diag_render(&diags, out, false);

        expect(finish(out)).toBe("error: bad name\n --> main.hx:1:5\n  |\n1 | let a = 1;\n  |     ^\n  = hint: rename it\n\n");
    }

    test("should write only the message of a diagnostic without a location") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        void emit(&diags, DIAG_WARNING, null, 0, 0, "no input files");
        const out = capture();
        hx_diag_render(&diags, out, false);

        expect(finish(out)).toBe("warning: no input files\n\n");
    }

    test("should color the level and the gutter when asked") {
        let diags = emptyList();
        defer hx_diag_list_free(&diags);
        void emit(&diags, DIAG_ERROR, null, 0, 0, "oops");
        const out = capture();
        hx_diag_render(&diags, out, true);

        expect(finish(out)).toBe("\x1b[1;31merror\x1b[0m: \x1b[1moops\x1b[0m\n\n");
    }

    test("should write nothing for an empty list") {
        let diags = emptyList();
        const out = capture();
        hx_diag_render(&diags, out, false);

        expect(finish(out)).toBe("");
    }
}
