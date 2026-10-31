/**
 * Imports
 */

import * as fmt from "std/fmt";
import { cAllocator, free as freeItems } from "std";
import { HxSource } from "@models/structs/source-model.struct";
import { HxDiag, HxDiagList } from "@models/structs/diagnostic-model.struct";
import { files, hx_source_line_col, hx_source_line } from "@models/source.model";
import { TAB_WIDTH, RESET, BOLD, BLUE, LEVEL_LABELS, LEVEL_COLORS } from "@constants/diagnostic.constant";

/**
 * The C library functions that the renderer writes through.
 */

extern "C" function strlen(text: readonly u8[*]): usize;
extern "C" function fwrite(bytes: readonly u8[*], size: usize, count: usize, file: ?u8[*]): usize;

/**
 * Writes text to a C stream, through stdio like the rest of the output of the compiler.
 *
 * @param out - The C `FILE` to write to
 * @param text - The text to write, where an empty text writes nothing
 */

function put(out: ?u8[*], text: string): void {
    if (text.len > 0) void fwrite(text.ptr, 1, text.len, out);
}

/**
 * Formats a template and writes it to a C stream.
 *
 * @param out - The C `FILE` to write to
 * @param text - The template to format
 *
 * @remarks
 * Out of memory loses this one piece of output and nothing else.
 */

function putf(out: ?u8[*], text: Format): void {
    const a = cAllocator();
    const bytes = fmt.alloc(a, text) catch [];
    put(out, bytes);
    if (bytes.len > 0) freeItems(a, bytes);
}

/**
 * Writes a run of spaces to a C stream.
 *
 * @param out - The C `FILE` to write to
 * @param count - The number of spaces
 */

function spaces(out: ?u8[*], count: u32): void {
    for (const _ of 0..count) put(out, " ");
}

/**
 * Returns a NUL-terminated string as a slice.
 *
 * @param text - The string to measure
 * @returns The bytes before the NUL
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * Counts the decimal digits of a number.
 *
 * @param value - The number to measure
 * @returns The number of digits, which is 1 for 0
 */

function digitCount(value: u32): u32 {
    let count: u32 = 1;
    let v = value;
    while (v >= 10) {
        v /= 10;
        count += 1;
    }
    return count;
}

/**
 * Measures how many columns a stretch of text takes on screen.
 *
 * @param text - The text that holds the stretch
 * @param from - The offset where the stretch starts
 * @param to - The offset one past where the stretch ends
 * @returns The width in columns, with tabs expanded and each code point counted once
 */

function displayWidth(text: readonly u8[], from: u32, to: u32): u32 {
    let width: u32 = 0;
    for (const c of text[from..to]) {
        if (c == '\t') width += TAB_WIDTH - (width % TAB_WIDTH);
        else if ((c & 0xC0) != 0x80) width += 1;
    }
    return width;
}

/**
 * Writes a source line with its tabs expanded to spaces.
 *
 * @param out - The C `FILE` to write to
 * @param line - The line, without its line break
 */

function printLine(out: ?u8[*], line: readonly u8[]): void {
    let width: u32 = 0;
    for (const c, i of line) {
        if (c == '\t') {
            const n = TAB_WIDTH - (width % TAB_WIDTH);
            width += n;
            spaces(out, n);
        } else {
            if ((c & 0xC0) != 0x80) width += 1;
            put(out, line[i..i + 1]);
        }
    }
}

/**
 * Writes the location line and the underlined source line of a span.
 *
 * @param out - The C `FILE` to write to
 * @param src - The source that the span points into
 * @param start - The offset of the first byte of the span
 * @param len - The length of the span in bytes
 * @param underline - The color of the underline, or an empty string for none
 * @param gutter - The color of the gutter, or an empty string for none
 * @param reset - The sequence that ends a color, or an empty string for none
 * @returns The width of the gutter, which the hint line lines up with
 *
 * @remarks
 * A span that runs over several lines is underlined on its first line only.
 */

function renderLocation(out: ?u8[*], src: readonly *HxSource, start: u32, len: u32, underline: string, gutter: string,
                        reset: string): u32 {
    const pos = hx_source_line_col(src, start);
    const pad = digitCount(pos.line);
    let lineLen: u32 = 0;
    const lineStart = hx_source_line(src, pos.global_line, &lineLen);
    const lineEnd = lineStart + lineLen;
    let text: readonly u8[] = [];
    unsafe {
        text = src.text![0..src.len];
    }

    const spanStart = start < lineEnd ? start : lineEnd;
    const spanEnd = start + len > lineEnd ? lineEnd : start + len;
    const caretCol = displayWidth(text, lineStart, spanStart);
    const caretLen = spanEnd > spanStart ? displayWidth(text, spanStart, spanEnd) : 1;
    let path: string = "";
    unsafe {
        path = cString(files(src)[pos.file].path);
    }

    spaces(out, pad);
    putf(out, `${gutter}-->${reset} ${path}:${pos.line}:${pos.col}\n`);
    spaces(out, pad);
    putf(out, ` ${gutter}|${reset}\n`);
    putf(out, `${gutter}${pos.line} |${reset} `);
    printLine(out, text[lineStart..lineEnd]);
    put(out, "\n");
    spaces(out, pad);
    putf(out, ` ${gutter}|${reset} `);
    spaces(out, caretCol);
    putf(out, `${underline}^`);
    for (const _ of 1..caretLen) put(out, "~");
    putf(out, `${reset}\n`);
    return pad;
}

/**
 * Writes the location line and the underlined source line of a span, without color.
 *
 * @param out - The C `FILE` to write to
 * @param src - The source that the span points into
 * @param start - The offset of the first byte of the span
 * @param len - The length of the span in bytes
 *
 * @remarks
 * Panic messages use it to show where a running program stopped.
 *
 * @example
 * ```ts
 * hx_diag_render_location(stderr, &src, 4, 1);
 * //  --> main.hx:1:5
 * //   |
 * // 1 | let a = 1;
 * //   |     ^
 * ```
 *
 * @see hx_diag_render
 * @since 1.0.0
 */

export extern "C" function hx_diag_render_location(out: ?u8[*], src: readonly *HxSource, start: u32, len: u32): void {
    void renderLocation(out, src, start, len, "", "", "");
}

/**
 * Writes one diagnostic with its location and its hint.
 *
 * @param diag - The diagnostic to write
 * @param out - The C `FILE` to write to
 * @param color - Whether to color the output with ANSI sequences
 */

function renderOne(diag: readonly *HxDiag, out: ?u8[*], color: bool): void {
    const level = diag.level as usize;
    const levelColor = color ? LEVEL_COLORS[level] : "";
    const bold = color ? BOLD : "";
    const gutter = color ? BLUE : "";
    const reset = color ? RESET : "";

    putf(out, `${levelColor}${LEVEL_LABELS[level]}${reset}: ${bold}${cString(diag.message)}${reset}\n`);
    let pad: u32 = 1;
    if (const src = diag.src) pad = renderLocation(out, src, diag.start, diag.len, levelColor, gutter, reset);
    if (const text = diag.hint) {
        spaces(out, pad);
        putf(out, ` ${gutter}=${reset} ${bold}hint:${reset} ${cString(text)}\n`);
    }
}

/**
 * Writes every diagnostic of a list with its source line and an underline.
 *
 * @param list - The diagnostics to write
 * @param out - The C `FILE` to write to
 * @param color - Whether to color the output with ANSI sequences
 *
 * @remarks
 * Each diagnostic is followed by a blank line.
 * A diagnostic without a location prints only its message and its hint.
 * Tabs in the source line are expanded, so the underline sits under the right characters.
 *
 * @example
 * ```ts
 * hx_diag_render(&diags, stderr, false);
 * // error: unterminated string literal
 * //  --> src/main.hx:3:15
 * //   |
 * // 3 |     const s = "hello;
 * //   |               ^~~~~~~
 * //   = hint: close it with `"`
 * ```
 *
 * @see hx_diag_render_location
 * @since 1.0.0
 */

export extern "C" function hx_diag_render(list: readonly *HxDiagList, out: ?u8[*], color: bool): void {
    for (const i of 0..list.items_len) {
        unsafe {
            renderOne(&list.items![i], out, color);
        }
        put(out, "\n");
    }
}
