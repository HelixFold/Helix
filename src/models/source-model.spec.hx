/**
 * Imports
 */

import { strlen } from "std/c";
import { writeFile, deleteFile } from "std/fs";
import { NoFile } from "@constants/source.constant";
import { HxSource } from "@models/structs/source-model.struct";
import { hxSourceLine, files, addText } from "@models/source.model";
import { hxSourceAddFile, hxSourceLoad, hxSourceFromString, hxSourceFree, hxSourceLineCol } from "@models/source.model";

/**
 * Tests
 */

const TempPath = "source-model-spec.tmp";

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
 * A source that holds one file with the given text.
 *
 * @param text - Contents of the file
 * @returns A source with the single file `main.hx`
 *
 * @remarks
 * Builds the source with `hxSourceFromString`, so no file on disk is involved.
 * The caller frees the result with `hxSourceFree`.
 *
 * @since 1.0.0
 */

function sourceOf(text: string): HxSource {
    let src: HxSource = undefined;
    hxSourceFromString(&src, "main.hx", text.ptr, text.len);
    return src;
}

describe("files") {
    test("should return the files in the order they were added") {
        let src = sourceOf("a");
        defer hxSourceFree(&src);
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
        defer hxSourceFree(&src);
        const index = addText(&src, "b.hx", "b");

        expect(index).toBe(1);
        unsafe {
            const text: string = src.text![0..src.len];
            expect(text).toBe("a\nb");
            expect(files(&src)[1].start).toBe(2);
            expect(files(&src)[1].end).toBe(3);
            expect(files(&src)[1].firstLine).toBe(1);
        }
    }

    test("should copy the path, so the caller may reuse its own") {
        let src = sourceOf("a");
        defer hxSourceFree(&src);
        let path: u8[5] = ['b', '.', 'h', 'x', 0];
        void addText(&src, &path, "b");
        path[0] = 'z';

        unsafe {
            expect(cString(files(&src)[1].path)).toBe("b.hx");
        }
    }
}

describe("hxSourceAddFile") {
    test("should append a file read from disk") {
        try writeFile(TempPath, "let a = 1;\n");
        defer deleteFile(TempPath) catch {};
        let src = sourceOf("x");
        defer hxSourceFree(&src);
        let error: readonly u8[*] = "";

        expect(hxSourceAddFile(&src, TempPath.ptr, &error)).toBe(1);
        expect(src.fileCount).toBe(2);
    }

    test("should report a missing file in the words of the C library") {
        let src = sourceOf("x");
        defer hxSourceFree(&src);
        let error: readonly u8[*] = "";

        expect(hxSourceAddFile(&src, "no-such-file.hx", &error)).toBe(NoFile);
        expect(cString(error)).toBe("No such file or directory");
        expect(src.fileCount).toBe(1);
    }
}

describe("hxSourceLoad") {
    test("should start a source with one file read from disk") {
        try writeFile(TempPath, "abc");
        defer deleteFile(TempPath) catch {};
        let src: HxSource = undefined;
        let error: readonly u8[*] = "";

        expect(hxSourceLoad(&src, TempPath.ptr, &error)).toBe(true);
        expect(src.len).toBe(3);
        hxSourceFree(&src);
    }

    test("should return false for a missing file") {
        let src: HxSource = undefined;
        let error: readonly u8[*] = "";

        expect(hxSourceLoad(&src, "no-such-file.hx", &error)).toBe(false);
    }
}

describe("hxSourceFromString") {
    test("should hold the text with a NUL after it") {
        let src = sourceOf("let a = 1;");
        defer hxSourceFree(&src);

        expect(src.len).toBe(10);
        unsafe {
            expect(src.text![10]).toBe(0);
        }
    }

    test("should hold an empty text as one empty line") {
        let src = sourceOf("");
        defer hxSourceFree(&src);

        expect(src.len).toBe(0);
        expect(src.lineCount).toBe(1);
    }
}

describe("hxSourceFree") {
    test("should leave the source empty") {
        let src = sourceOf("a\nb");
        hxSourceFree(&src);

        expect(src.fileCount).toBe(0);
        expect(src.text).toBeNull();
    }
}

describe("hxSourceLineCol") {
    test("should count lines and columns from 1") {
        let src = sourceOf("let a = 1;\nlet b = 2;");
        defer hxSourceFree(&src);
        const pos = hxSourceLineCol(&src, 15);

        expect(pos.line).toBe(2);
        expect(pos.col).toBe(5);
        expect(pos.globalLine).toBe(1);
    }

    test("should count a multibyte character as one column") {
        let src = sourceOf("let \u{E9} = 2;");
        defer hxSourceFree(&src);

        expect(hxSourceLineCol(&src, 6).col).toBe(6);
    }

    test("should count lines within the file that holds the offset") {
        let src = sourceOf("a\nb");
        defer hxSourceFree(&src);
        void addText(&src, "c.hx", "c\nd");
        const pos = hxSourceLineCol(&src, 6);

        expect(pos.file).toBe(1);
        expect(pos.line).toBe(2);
        expect(pos.globalLine).toBe(3);
    }

    test("should treat an offset past the end as the end") {
        let src = sourceOf("abc");
        defer hxSourceFree(&src);

        expect(hxSourceLineCol(&src, 100).col).toBe(4);
    }
}

describe("hxSourceLine") {
    test("should leave the line break out of the length") {
        let src = sourceOf("a\r\nbc");
        defer hxSourceFree(&src);
        let len: u32 = 0;

        expect(hxSourceLine(&src, 0, &len)).toBe(0);
        expect(len).toBe(1);
        expect(hxSourceLine(&src, 1, &len)).toBe(3);
        expect(len).toBe(2);
    }
}
