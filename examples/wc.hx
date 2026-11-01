/**
 * Imports
 */

import { Init, File, DebugAllocator, cAllocator, free, readFile } from "std";

/**
 * The counts that `wc` prints for one text.
 *
 * @remarks
 * `count` fills it for one text, and `main` adds the counts up for the total.
 *
 * @since 1.0.0
 */

struct Counts {
    /**
     * The number of newline characters.
     *
     * @since 1.0.0
     */

    lines: usize,

    /**
     * The number of runs of characters between spaces, tabs, and line breaks.
     *
     * @since 1.0.0
     */

    words: usize,

    /**
     * The length of the text in bytes.
     *
     * @since 1.0.0
     */

    bytes: usize,
}

/**
 * Counts the lines, words, and bytes of a text.
 *
 * @param text - The bytes to count
 * @returns The three counts
 *
 * @remarks
 * A word starts at each character that is not a space and follows a space or the start of the text.
 *
 * @since 1.0.0
 */

function count(text: readonly u8[]): Counts {
    let counts = Counts { lines: 0, words: 0, bytes: text.len };
    let inWord = false;
    for (const c of text) {
        if (c == '\n') counts.lines += 1;
        const space = c == ' ' || c == '\n' || c == '\t' || c == '\r';
        if (!space && !inWord) counts.words += 1;
        inWord = !space;
    }
    return counts;
}

/**
 * Prints one line of counts, separated by tabs.
 *
 * @param counts - The counts to print
 * @param name - The file that they belong to, or an empty string for stdin
 *
 * @remarks
 * The order of the columns is that of `wc`: lines, words, bytes, then the name.
 *
 * @since 1.0.0
 */

function report(counts: Counts, name: string): void {
    println(`${counts.lines}\t${counts.words}\t${counts.bytes}\t${name}`);
}

/**
 * Counts lines, words, and bytes, as `wc` does.
 *
 * @param init - The command line, whose arguments are the files to count
 * @returns Nothing, or an error from reading stdin
 *
 * @remarks
 * Without arguments it reads stdin.
 * A file that can't be read prints its error and the count goes on with the next one.
 * With more than one file it prints a total line at the end.
 *
 * @example
 * ```bash
 * helix build examples/wc.hx -o wc
 * ./wc examples/hello.hx examples/wc.hx    # a line for each file, then the total
 * echo "a b" | ./wc                        # 1  2  4
 * ```
 *
 * @since 1.0.0
 */

export function main(init: Init): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    defer void debug.deinit();
    const a = debug.allocator();

    if (init.args.len == 0) {
        let input = File.stdin();
        const text = try input.readAll(a);
        defer free(a, text);
        report(count(text), "");
        return;
    }

    let total = Counts { lines: 0, words: 0, bytes: 0 };
    for (const path of init.args) {
        const text = readFile(a, path) catch (e) {
            eprintln(`wc: ${path}: ${e}`);
            continue;
        };
        defer free(a, text);
        const counts = count(text);
        report(counts, path);
        total.lines += counts.lines;
        total.words += counts.words;
        total.bytes += counts.bytes;
    }
    if (init.args.len > 1) report(total, "total");
}
