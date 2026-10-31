/**
 * Imports
 */

import { readFile, FsError } from "std/fs";
import { cAllocator, free as freeItems } from "std";
import { EmptySource, NoFile } from "@constants/source.constant";
import { hxRealloc, hxStrndup, free } from "@components/memory.component";
import { HxSource, HxSourceFile, HxLineCol } from "@models/structs/source-model.struct";

/**
 * The C library function that measures a NUL-terminated path.
 *
 * @since 1.0.0
 */

extern "C" function strlen(text: readonly u8[*]): usize;

/**
 * Returns the file array of a source.
 *
 * @param src - The source whose files to read
 * @returns The files, indexed from 0 up to `fileCount`
 *
 * @remarks
 * The source stores the array as bytes for its C layout, and this gives it back its type.
 * Only call it once the source holds at least one file.
 *
 * @example
 * ```hx
 * files(&src)[0]; // { path: 'main.hx', start: 0, end: 10, firstLine: 0 }
 * ```
 *
 * @since 1.0.0
 */

export function files(src: readonly *HxSource): HxSourceFile[*] {
    unsafe {
        return @ptrCast(HxSourceFile[*], src.files!);
    }
}

/**
 * Appends the offset of a line start to the line table.
 *
 * @param src - The source whose line table to grow
 * @param offset - The offset of the first byte of the line
 *
 * @remarks
 * The table starts at 256 entries and doubles whenever it is full.
 * It does not keep the offsets sorted, so the callers append lines in the order they appear.
 *
 * @since 1.0.0
 */

function addLine(src: *HxSource, offset: u32): void {
    if (src.lineCount == src.lineCap) {
        src.lineCap = src.lineCap != 0 ? src.lineCap * 2 : 256;
        unsafe {
            src.lineStarts = @ptrCast(u32[*], hxRealloc(@ptrCast(?u8[*], src.lineStarts), (src.lineCap as usize) * 4));
        }
    }
    unsafe {
        src.lineStarts![src.lineCount] = offset;
    }
    src.lineCount += 1;
}

/**
 * Appends the bytes of a file to the buffer and records its lines.
 *
 * @param src - The source to append to
 * @param path - The NUL-terminated path of the file, which the source copies
 * @param bytes - The text of the file
 * @returns The index of the new file
 *
 * @remarks
 * Every file after the first starts after a newline, so each file starts on a line of its own.
 *
 * @since 1.0.0
 */

function appendFile(src: *HxSource, path: readonly u8[*], bytes: readonly u8[]): u32 {
    const start: u32 = src.len != 0 ? src.len + 1 : 0;
    const needed = (start as usize) + bytes.len + 1;
    if (needed > (src.cap as usize)) {
        let cap: usize = src.cap != 0 ? src.cap as usize : 4096;
        while (cap < needed) cap *= 2;
        unsafe {
            src.text = hxRealloc(src.text, cap);
        }
        src.cap = @truncate(u32, cap);
    }
    unsafe {
        const text = src.text!;
        if (start != 0) text[src.len] = '\n';
        for (const b, i of bytes) text[(start as usize) + i] = b;
        src.len = start + @truncate(u32, bytes.len);
        text[src.len] = 0;

        if (src.fileCount == src.fileCap) {
            src.fileCap = src.fileCap != 0 ? src.fileCap * 2 : 8;
            src.files = hxRealloc(src.files, (src.fileCap as usize) * @sizeOf(HxSourceFile));
        }
        files(src)[src.fileCount] = HxSourceFile {
            path: hxStrndup(path, strlen(path)), start, end: src.len, firstLine: src.lineCount,
        };
    }

    addLine(src, start);
    for (const i of start..src.len) {
        unsafe {
            if (src.text![i] == '\n') addLine(src, i + 1);
        }
    }
    const index = src.fileCount;
    src.fileCount += 1;
    return index;
}

/**
 * Describes a file error in the words of the C library.
 *
 * @param e - The error that reading the file raised
 * @returns The static message that the driver prints after `cannot read 'path':`
 *
 * @remarks
 * The messages match what `strerror` prints for the same causes, so the output reads like other command-line tools.
 * Any error outside the four known ones falls back to a generic message.
 *
 * @since 1.0.0
 */

function describe(e: Error): readonly u8[*] {
    if (e == FsError.NotFound) return "No such file or directory";
    if (e == FsError.AccessDenied) return "Permission denied";
    if (e == FsError.IsDirectory) return "Is a directory";
    if (e == FsError.NameTooLong) return "File name too long";
    return "could not read the whole file";
}

/**
 * Reads a file from disk and appends it to a source.
 *
 * @param src - The source to append to
 * @param path - The NUL-terminated path of the file
 * @param error - The variable that receives a static message when the file cannot be added
 * @returns The index of the new file, or {@link NoFile} on failure
 *
 * @remarks
 * A file of 2 GiB or more is refused,
 * and so is a file that would take the whole program past 4 GiB of source.
 * On failure the source is left as it was.
 *
 * @example
 * ```hx
 * let error: readonly u8[*] = "";
 * hxSourceAddFile(&src, "src/main.hx", &error); // 0
 * hxSourceAddFile(&src, "missing.hx", &error);  // NoFile, error: 'No such file or directory'
 * ```
 *
 * @see addText
 * @see hxSourceLoad
 *
 * @since 1.0.0
 */

export extern "C" function hxSourceAddFile(src: *HxSource, path: readonly u8[*], error: *readonly u8[*]): u32 {
    const a = cAllocator();
    let name: string = "";
    unsafe {
        name = path[0..strlen(path)];
    }
    const bytes = readFile(a, name) catch (e) {
        *error = describe(e);
        return NoFile;
    };
    defer freeItems(a, bytes);
    if (bytes.len >= 0x7FFFFFFF) {
        *error = "file is too large";
        return NoFile;
    }
    if ((src.len as u64) + (bytes.len as u64) + 2 >= 0xFFFF_FFFF) {
        *error = "the program's source is larger than 4 GiB";
        return NoFile;
    }
    return appendFile(src, path, bytes);
}

/**
 * Appends a file whose text is already in memory.
 *
 * @param src - The source to append to
 * @param path - The NUL-terminated path to record for the file
 * @param text - The text of the file, which the source copies
 * @returns The index of the new file
 *
 * @remarks
 * The language server uses it for the unsaved buffer of an editor, which has no current copy on disk.
 *
 * @example
 * ```hx
 * addText(&src, "main.hx", "let a = 1;"); // 0
 * ```
 *
 * @see hxSourceAddFile
 * @since 1.0.0
 */

export function addText(src: *HxSource, path: readonly u8[*], text: string): u32 {
    return appendFile(src, path, text);
}

/**
 * Starts a source with a single file read from disk.
 *
 * @param src - The source to fill, whose previous contents are ignored
 * @param path - The NUL-terminated path of the file
 * @param error - The variable that receives a static message when the file cannot be read
 * @returns `true` when the file was loaded
 *
 * @remarks
 * Resets the source before it reads, so it starts a new program rather than adding to one.
 * Use {@link hxSourceAddFile} for every file after the first.
 * When the file cannot be read, `error` holds the reason and the source stays empty.
 *
 * @example
 * ```hx
 * let src: HxSource = undefined;
 * let error: readonly u8[*] = "";
 * hxSourceLoad(&src, "src/main.hx", &error); // true
 * ```
 *
 * @see hxSourceAddFile
 * @since 1.0.0
 */

export extern "C" function hxSourceLoad(src: *HxSource, path: readonly u8[*], error: *readonly u8[*]): bool {
    *src = EmptySource;
    return hxSourceAddFile(src, path, error) != NoFile;
}

/**
 * Starts a source with a single file whose text is in memory.
 *
 * @param src - The source to fill, whose previous contents are ignored
 * @param path - The NUL-terminated path to record for the file
 * @param text - The first byte of the text, which the source copies
 * @param len - The length of the text in bytes
 *
 * @remarks
 * Tests use it to compile a snippet without a file on disk.
 *
 * @example
 * ```hx
 * let src: HxSource = undefined;
 * hxSourceFromString(&src, "main.hx", "let a = 1;", 10);
 * src.len; // 10
 * ```
 *
 * @see addText
 * @since 1.0.0
 */

export extern "C" function hxSourceFromString(src: *HxSource, path: readonly u8[*], text: readonly u8[*], len: usize): void {
    *src = EmptySource;
    unsafe {
        void appendFile(src, path, len > 0 ? text[0..len] : "");
    }
}

/**
 * Releases the text, the line table, and the files of a source.
 *
 * @param src - The source to release
 *
 * @remarks
 * The source is left empty, so releasing it twice is harmless.
 *
 * @example
 * ```hx
 * hxSourceFree(&src);
 * src.fileCount; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxSourceFree(src: *HxSource): void {
    unsafe {
        for (const i of 0..src.fileCount) free(files(src)[i].path);
        free(src.files);
        free(src.text);
        free(@ptrCast(?u8[*], src.lineStarts));
    }
    *src = EmptySource;
}

/**
 * Finds the line that holds an offset, by binary search over the line table.
 *
 * @param src - The source to search
 * @param offset - The offset to locate
 * @returns The index of the last line that starts at or before the offset
 *
 * @remarks
 * An offset in the middle of a line resolves to that line, and an offset past the end resolves to the last line.
 * It assumes the table holds at least one line, which every loaded file guarantees.
 *
 * @since 1.0.0
 */

function lineIndex(src: readonly *HxSource, offset: u32): u32 {
    let lo: u32 = 0;
    let hi = src.lineCount;
    unsafe {
        const starts = src.lineStarts!;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= offset) lo = mid;
            else hi = mid;
        }
    }
    return lo;
}

/**
 * Finds the file that holds an offset, by binary search over the files.
 *
 * @param src - The source to search
 * @param offset - The offset to locate
 * @returns The index of the last file that starts at or before the offset
 *
 * @remarks
 * The offset of the newline that separates two files resolves to the earlier file.
 * It assumes the source holds at least one file.
 *
 * @since 1.0.0
 */

function fileIndex(src: readonly *HxSource, offset: u32): u32 {
    let lo: u32 = 0;
    let hi = src.fileCount;
    unsafe {
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (files(src)[mid].start <= offset) lo = mid;
            else hi = mid;
        }
    }
    return lo;
}

/**
 * Converts an offset into a file, a line, and a column.
 *
 * @param src - The source that the offset points into
 * @param at - The offset to convert, where anything past the end counts as the end
 * @returns The position of the offset
 *
 * @remarks
 * Lines and columns count from 1 within their file, and a column counts code points, not bytes.
 * Both lookups are binary searches, so the cost grows with the logarithm of the size of the program.
 *
 * @example
 * ```hx
 * // main.hx: let a = 1;\nlet é = 2;
 * hxSourceLineCol(&src, 4);  // { file: 0, line: 1, col: 5, globalLine: 0 }
 * hxSourceLineCol(&src, 17); // { file: 0, line: 2, col: 6, globalLine: 1 }, past the é
 * ```
 *
 * @see hxSourceLine
 * @since 1.0.0
 */

export extern "C" function hxSourceLineCol(src: readonly *HxSource, at: u32): HxLineCol {
    const offset = at > src.len ? src.len : at;
    const index = lineIndex(src, offset);
    const file = fileIndex(src, offset);
    let col: u32 = 1;
    unsafe {
        for (const i of src.lineStarts![index]..offset) {
            if ((src.text![i] & 0xC0) != 0x80) col += 1;
        }
        return HxLineCol { file, line: index - files(src)[file].firstLine + 1, col, globalLine: index };
    }
}

/**
 * Returns where a line starts and how long it is, without its line break.
 *
 * @param src - The source that holds the line
 * @param globalLine - The index of the line in the line table of the whole program
 * @param len - The variable that receives the length of the line in bytes
 * @returns The offset of the first byte of the line
 *
 * @remarks
 * Both a `\n` and a `\r\n` ending are left out of the length.
 *
 * @example
 * ```hx
 * // a\r\nbc
 * let len: u32 = 0;
 * hxSourceLine(&src, 0, &len); // 0, len: 1
 * hxSourceLine(&src, 1, &len); // 3, len: 2
 * ```
 *
 * @see hxSourceLineCol
 * @since 1.0.0
 */

export extern "C" function hxSourceLine(src: readonly *HxSource, globalLine: u32, len: *u32): u32 {
    unsafe {
        const starts = src.lineStarts!;
        const start = starts[globalLine];
        let end = globalLine + 1 < src.lineCount ? starts[globalLine + 1] : src.len;
        const text = src.text!;
        if (end > start && text[end - 1] == '\n') end -= 1;
        if (end > start && text[end - 1] == '\r') end -= 1;
        *len = end - start;
        return start;
    }
}
