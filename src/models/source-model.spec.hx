/**
 * Imports
 */

import { strlen } from "std/c";
import { writeFile, deleteFile } from "std/fs";
import { NO_FILE } from "@constants/source.constant";
import { HxSource } from "@models/structs/source-model.struct";
import { hx_source_add_file, hx_source_load, hx_source_from_string } from "@models/source.model";
import { hx_source_free, hx_source_line_col, hx_source_line, files, addText } from "@models/source.model";

/**
 * Tests
 */

const TEMP_PATH = "source-model-spec.tmp";

/**
 * A NUL-terminated string as a slice.
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * A source that holds one file with the given text.
 */

function sourceOf(text: string): HxSource {
    let src: HxSource = undefined;
    hx_source_from_string(&src, "main.hx", text.ptr, text.len);
    return src;
}

describe("files") {
    test("should return the files in the order they were added") {
        let src = sourceOf("a");
        defer hx_source_free(&src);
        void addText(&src, "b.hx", "b");

        unsafe {
            expect(cString(files(&src)[0].path)).toBe("main.hx");
            expect(cString(files(&src)[1].path)).toBe("b.hx");
        }
    }
}

describe("addText") {
    test("should start each later file after a newline") {
        let src = sourceOf("a");
        defer hx_source_free(&src);
        const index = addText(&src, "b.hx", "b");

        expect(index).toBe(1);
        unsafe {
            const text: string = src.text![0..src.len];
            expect(text).toBe("a\nb");
            expect(files(&src)[1].start).toBe(2);
            expect(files(&src)[1].end).toBe(3);
            expect(files(&src)[1].first_line).toBe(1);
        }
    }

    test("should copy the path, so the caller may reuse its own") {
        let src = sourceOf("a");
        defer hx_source_free(&src);
        let path: u8[5] = ['b', '.', 'h', 'x', 0];
        void addText(&src, &path, "b");
        path[0] = 'z';

        unsafe {
            expect(cString(files(&src)[1].path)).toBe("b.hx");
        }
    }
}

describe("hx_source_add_file") {
    test("should append a file read from disk") {
        try writeFile(TEMP_PATH, "let a = 1;\n");
        defer deleteFile(TEMP_PATH) catch {};
        let src = sourceOf("x");
        defer hx_source_free(&src);
        let error: readonly u8[*] = "";

        expect(hx_source_add_file(&src, TEMP_PATH.ptr, &error)).toBe(1);
        expect(src.file_count).toBe(2);
    }

    test("should report a missing file in the words of the C library") {
        let src = sourceOf("x");
        defer hx_source_free(&src);
        let error: readonly u8[*] = "";

        expect(hx_source_add_file(&src, "no-such-file.hx", &error)).toBe(NO_FILE);
        expect(cString(error)).toBe("No such file or directory");
        expect(src.file_count).toBe(1);
    }
}

describe("hx_source_load") {
    test("should start a source with one file read from disk") {
        try writeFile(TEMP_PATH, "abc");
        defer deleteFile(TEMP_PATH) catch {};
        let src: HxSource = undefined;
        let error: readonly u8[*] = "";

        expect(hx_source_load(&src, TEMP_PATH.ptr, &error)).toBe(true);
        expect(src.len).toBe(3);
        hx_source_free(&src);
    }

    test("should return false for a missing file") {
        let src: HxSource = undefined;
        let error: readonly u8[*] = "";

        expect(hx_source_load(&src, "no-such-file.hx", &error)).toBe(false);
    }
}

describe("hx_source_from_string") {
    test("should hold the text with a NUL after it") {
        let src = sourceOf("let a = 1;");
        defer hx_source_free(&src);

        expect(src.len).toBe(10);
        unsafe {
            expect(src.text![10]).toBe(0);
        }
    }

    test("should hold an empty text as one empty line") {
        let src = sourceOf("");
        defer hx_source_free(&src);

        expect(src.len).toBe(0);
        expect(src.line_count).toBe(1);
    }
}

describe("hx_source_free") {
    test("should leave the source empty") {
        let src = sourceOf("a\nb");
        hx_source_free(&src);

        expect(src.file_count).toBe(0);
        expect(src.text).toBeNull();
    }
}

describe("hx_source_line_col") {
    test("should count lines and columns from 1") {
        let src = sourceOf("let a = 1;\nlet b = 2;");
        defer hx_source_free(&src);
        const pos = hx_source_line_col(&src, 15);

        expect(pos.line).toBe(2);
        expect(pos.col).toBe(5);
        expect(pos.global_line).toBe(1);
    }

    test("should count a multibyte character as one column") {
        let src = sourceOf("let \u{E9} = 2;");
        defer hx_source_free(&src);

        expect(hx_source_line_col(&src, 6).col).toBe(6);
    }

    test("should count lines within the file that holds the offset") {
        let src = sourceOf("a\nb");
        defer hx_source_free(&src);
        void addText(&src, "c.hx", "c\nd");
        const pos = hx_source_line_col(&src, 6);

        expect(pos.file).toBe(1);
        expect(pos.line).toBe(2);
        expect(pos.global_line).toBe(3);
    }

    test("should treat an offset past the end as the end") {
        let src = sourceOf("abc");
        defer hx_source_free(&src);

        expect(hx_source_line_col(&src, 100).col).toBe(4);
    }
}

describe("hx_source_line") {
    test("should leave the line break out of the length") {
        let src = sourceOf("a\r\nbc");
        defer hx_source_free(&src);
        let len: u32 = 0;

        expect(hx_source_line(&src, 0, &len)).toBe(0);
        expect(len).toBe(1);
        expect(hx_source_line(&src, 1, &len)).toBe(3);
        expect(len).toBe(2);
    }
}
