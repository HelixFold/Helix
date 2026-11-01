/**
 * Imports
 */

import * as fmt from "std/fmt";
import { ArrayList } from "std/list";
import { Run } from "../structs/run.struct";
import { Env, Output, CaptureOptions, captureAllWith } from "std/process";
import { equal, indexOf, lines, split, startsWith, endsWith } from "std/text";
import { Dir, Kind, stat, exists, copyFile, deleteTree, makePath, readFile, writeFile } from "std/fs";

/**
 * The folder that this process runs in, written into a buffer of C.
 *
 * @remarks
 * The C library implements it, and it returns null when the buffer is too small.
 *
 * @since 1.0.0
 */

extern "C" function getcwd(buf: u8[*], size: usize): ?u8[*];

/**
 * The number of this process, which keeps the temporary folders of two runs apart.
 *
 * @remarks
 * The C library implements it.
 *
 * @since 1.0.0
 */

extern "C" function getpid(): i32;

/**
 * The machine numbers in an ELF header that the checks look for.
 *
 * @remarks
 * They are the values of `e_machine`: ARM, x86-64, AArch64, and RISC-V.
 *
 * @example
 * ```hx
 * expect(elfMachine(&run, path)).toBe(ElfArm);
 * ```
 *
 * @since 1.0.0
 */

export const ElfArm: u16 = 40;

/**
 * The ELF machine number of x86-64.
 *
 * @example
 * ```hx
 * elfMachine(&run, "app-x86_64"); // 62
 * ```
 *
 * @since 1.0.0
 */

export const ElfX86: u16 = 62;

/**
 * The ELF machine number of AArch64.
 *
 * @example
 * ```hx
 * elfMachine(&run, "app-aarch64"); // 183
 * ```
 *
 * @since 1.0.0
 */

export const ElfAarch64: u16 = 183;

/**
 * The ELF machine number of RISC-V.
 *
 * @example
 * ```hx
 * elfMachine(&run, "kernel-riscv64"); // 243
 * ```
 *
 * @since 1.0.0
 */

export const ElfRiscv: u16 = 243;

/**
 * Records and prints a passing check.
 *
 * @param run - The run
 * @param file - The path of the snippet, or the name of the check
 * @param label - The mode or the target that the check used, or an empty text when it has none
 *
 * @remarks
 * It prints one line in the form of {@link fail}, so the report lists every file that it checked.
 *
 * @example
 * ```hx
 * pass(&run, "e2e/programs/hello.hx", "debug");
 * // ✓ e2e/programs/hello.hx (debug)
 * ```
 *
 * @since 1.0.0
 */

export function pass(run: *Run, file: string, label: string): void {
    run.passed++;
    if (label.len > 0) {
        println(`  ✓ ${file} (${label})`);
    } else {
        println(`  ✓ ${file}`);
    }
}

/**
 * Records and prints a failing check.
 *
 * @param run - The run
 * @param file - The path of the snippet, or the name of the check
 * @param reason - What went wrong, starting with the mode or target when the check has one
 * @param detail - What the compiler or the program printed, or an empty text
 *
 * @remarks
 * The detail prints indented below the reason, at most 20 lines of it.
 *
 * @example
 * ```hx
 * fail(&run, "e2e/programs/hello.hx", "debug: stdout differs", stdout);
 * // ✗ e2e/programs/hello.hx (debug: stdout differs)
 * ```
 *
 * @since 1.0.0
 */

export function fail(run: *Run, file: string, reason: string, detail: string): void {
    run.failed++;
    println(`  ✗ ${file} (${reason})`);
    let rows = lines(detail);
    let shown: usize = 0;
    while (const row = rows.next()) {
        if (shown == 20) break;
        println(`      ${row}`);
        shown++;
    }
}

/**
 * Records why a group of checks cannot run on this machine.
 *
 * @param run - The run
 * @param note - The group and the reason, such as `QEMU: no qemu-system-riscv64`
 * @returns Nothing, or the error of the allocator
 *
 * @remarks
 * `main` prints the notes after the checks, so a run on a machine without a tool says what it left out.
 *
 * @example
 * ```hx
 * try skip(&run, "lldb: not installed");
 * ```
 *
 * @since 1.0.0
 */

export function skip(run: *Run, note: string): void | Error {
    try run.skipped.append(note);
}

/**
 * Formats a text into the arena of the run.
 *
 * @param run - The run
 * @param template - The text to format
 * @returns The formatted text
 *
 * @remarks
 * Every message and path of the checks goes through it, so they all share the arena.
 *
 * @example
 * ```hx
 * try text(&run, `${dir}/${name}`); // "e2e/programs/hello.hx"
 * ```
 *
 * @since 1.0.0
 */

export function text(run: *Run, template: Format): string | Error {
    const bytes = try fmt.alloc(run.a, template);
    return bytes;
}

/**
 * Whether a text holds another one.
 *
 * @param haystack - The text to search
 * @param needle - The text to find
 * @returns `true` when `needle` appears in `haystack`
 *
 * @remarks
 * An empty `needle` appears in every text.
 *
 * @example
 * ```hx
 * contains("error: missing", "missing"); // true
 * ```
 *
 * @since 1.0.0
 */

export function contains(haystack: string, needle: string): bool {
    return indexOf(haystack, needle) != null;
}

/**
 * Reads a file into the arena of the run.
 *
 * @param run - The run
 * @param path - The path of the file
 * @returns The text of the file
 *
 * @remarks
 * Every check reads its snippet once, before it starts the compiler.
 *
 * @example
 * ```hx
 * try readText(&run, "e2e/programs/hello.hx"); // "// expect-stdout: hello from helix: 42\n..."
 * ```
 *
 * @since 1.0.0
 */

export function readText(run: *Run, path: string): string | Error {
    const bytes = try readFile(run.a, path);
    return bytes;
}

/**
 * Writes a text to a file, making its folder first.
 *
 * @param path - The path of the file
 * @param content - The text to write
 * @returns Nothing, or the error that stopped the write
 *
 * @remarks
 * The checks that need a project of their own write its files with it.
 *
 * @example
 * ```hx
 * try writeText(try text(&run, `${dir}/src/main.hx`), "export function main(): void {}\n");
 * ```
 *
 * @since 1.0.0
 */

export function writeText(path: string, content: string): void | Error {
    if (const slash = lastSlash(path)) try makePath(path[0..slash]);
    try writeFile(path, content);
}

/**
 * Finds the last `/` of a path.
 *
 * @param path - The path
 * @returns The index of the last `/`, or null for a path without one
 *
 * @remarks
 * {@link writeText} uses it to find the folder of a file.
 *
 * @since 1.0.0
 */

function lastSlash(path: string): ?usize {
    let at: ?usize = null;
    for (const byte, i of path) {
        if (byte == '/') at = i;
    }
    return at;
}

/**
 * Lists the snippets of a folder in sorted order.
 *
 * @param run - The run, whose filter drops the paths that do not hold it
 * @param dir - The folder to list
 * @param folders - Whether to list the subfolders instead of the `.hx` files
 * @returns The paths of the `.hx` files, or of the subfolders, directly in the folder
 *
 * @remarks
 * The `.hx` listing leaves out subfolders, which hold the modules that the snippets import.
 * The order is by bytes, so a run reports the same snippets in the same order on every machine.
 *
 * @example
 * ```hx
 * try snippets(&run, "e2e/programs", false); // ["e2e/programs/addresses.hx", ...]
 * try snippets(&run, "e2e/projects", true);  // ["e2e/projects/aliases", "e2e/projects/bins", ...]
 * ```
 *
 * @since 1.0.0
 */

export function snippets(run: *Run, dir: string, folders: bool): string[] | Error {
    let found = ArrayList<string>.init(run.a);
    let folder = try Dir.open(dir);
    defer folder.close();
    while (const name = try folder.next()) {
        const path = try text(run, `${dir}/${name}`);
        const isFolder = (try stat(path)).kind == Kind.Directory;
        if (folders != isFolder || (!folders && !endsWith(name, ".hx"))) continue;
        if (run.filter.len == 0 || contains(path, run.filter)) try found.append(path);
    }
    sortTexts(found.items);
    return found.items;
}

/**
 * Sorts texts by their bytes.
 *
 * @param items - The texts to sort in place
 *
 * @remarks
 * It is an insertion sort, which suits the few dozen names of a folder.
 *
 * @example
 * ```hx
 * sortTexts(names); // ["a.hx", "b.hx"]
 * ```
 *
 * @since 1.0.0
 */

export function sortTexts(items: string[]): void {
    for (const i of 1..items.len) {
        let j = i;
        while (j > 0 && before(items[j], items[j - 1])) {
            const moved = items[j];
            items[j] = items[j - 1];
            items[j - 1] = moved;
            j--;
        }
    }
}

/**
 * Whether one text sorts before another, comparing bytes.
 *
 * @param left - The first text
 * @param right - The second text
 * @returns `true` when `left` comes first
 *
 * @remarks
 * A text that the other starts with comes first.
 *
 * @since 1.0.0
 */

function before(left: string, right: string): bool {
    for (const byte, i of left) {
        if (i == right.len) return false;
        if (byte != right[i]) return byte < right[i];
    }
    return left.len < right.len;
}

/**
 * Collects the values of one kind of `// <key>:` line of a snippet.
 *
 * @param run - The run, whose arena holds the list
 * @param source - The text of the snippet
 * @param key - The kind, such as `expect-stdout`
 * @returns The text after `// <key>:` on each such line, without the one space that follows the colon
 *
 * @remarks
 * A line holding only `// <key>:` gives an empty value, which an `expect-stdout` line uses for an empty output line.
 *
 * @example
 * ```hx
 * try directives(&run, "// expect-exit: 3\n", "expect-exit"); // ["3"]
 * ```
 *
 * @since 1.0.0
 */

export function directives(run: *Run, source: string, key: string): string[] | Error {
    const prefix = try text(run, `// ${key}:`);
    let values = ArrayList<string>.init(run.a);
    let rows = lines(source);
    while (const row = rows.next()) {
        if (!startsWith(row, prefix)) continue;
        const value = row[prefix.len..];
        try values.append(startsWith(value, " ") ? value[1..] : value);
    }
    return values.items;
}

/**
 * Splits a command line into its words at spaces.
 *
 * @param run - The run, whose arena holds the list
 * @param line - The command line, such as `build run -Dgreeting=hi`
 * @returns The words, without empty ones
 *
 * @remarks
 * The command lines of the snippets have no quoted words, so a space always separates two words.
 *
 * @example
 * ```hx
 * try words(&run, "build run -Dloud"); // ["build", "run", "-Dloud"]
 * ```
 *
 * @since 1.0.0
 */

export function words(run: *Run, line: string): string[] | Error {
    let found = ArrayList<string>.init(run.a);
    let parts = split(line, " ");
    while (const part = parts.next()) {
        if (part.len > 0) try found.append(part);
    }
    return found.items;
}

/**
 * Runs a program and captures both of its streams.
 *
 * @param run - The run
 * @param argv - The command line, whose first word is the program
 * @param dir - The folder to start it in, or an empty text for the folder of the run
 * @param timeout - The milliseconds that it may run, or 0 for no limit
 * @returns The exit status and the output
 *
 * @remarks
 * A program that cannot start gives status 127 and the reason as its stderr, as a shell reports it,
 * so the check that started it fails with that reason instead of stopping the run.
 *
 * @example
 * ```hx
 * const output = try command(&run, ["node", "--version"], "", 0);
 * output.status; // 0
 * ```
 *
 * @since 1.0.0
 */

export function command(run: *Run, argv: readonly string[], dir: string, timeout: u32): Output | Error {
    const output = captureAllWith(run.a, argv, CaptureOptions { dir, timeout }) catch (failure) {
        const reason = try fmt.alloc(run.a, `cannot run ${argv[0]}: ${failure}`);
        return Output { status: 127, stdout: [], stderr: reason };
    };
    return output;
}

/**
 * Runs the compiler under check with some arguments.
 *
 * @param run - The run
 * @param args - The arguments after the compiler
 * @param dir - The folder to start it in, or an empty text for the folder of the run
 * @returns The exit status and the output
 *
 * @remarks
 * It puts {@link Run.compiler} in front of the arguments and runs them with {@link command}, without a time limit.
 *
 * @example
 * ```hx
 * const output = try helix(&run, ["check", "e2e/errors/types.hx"], "");
 * output.status; // 1
 * ```
 *
 * @since 1.0.0
 */

export function helix(run: *Run, args: readonly string[], dir: string): Output | Error {
    let argv = ArrayList<string>.init(run.a);
    try argv.append(run.compiler);
    for (const arg of args) try argv.append(arg);
    return try command(run, argv.items, dir, 0);
}

/**
 * Finds a program in the folders of `PATH`.
 *
 * @param run - The run
 * @param name - The name of the program, such as `node`
 * @returns The path of the program, or null when no folder of `PATH` has it
 *
 * @remarks
 * The checks that need a tool, such as QEMU, Node, or lldb, skip themselves when it gives null.
 *
 * @example
 * ```hx
 * try findTool(&run, "node"); // "/usr/local/bin/node"
 * ```
 *
 * @since 1.0.0
 */

export function findTool(run: *Run, name: string): ?string | Error {
    const path = Env {}.get("PATH") ?? "";
    let dirs = split(path, ":");
    while (const dir = dirs.next()) {
        if (dir.len == 0) continue;
        const candidate = try text(run, `${dir}/${name}`);
        if (exists(candidate)) return candidate;
    }
    return null;
}

/**
 * Whether this machine runs macOS.
 *
 * @returns `true` when the system version file of macOS exists
 *
 * @remarks
 * The arm64e checks need the linker of Apple, which only a Mac has.
 *
 * @example
 * ```hx
 * onMac(); // true on a Mac
 * ```
 *
 * @since 1.0.0
 */

export function onMac(): bool {
    return exists("/System/Library/CoreServices/SystemVersion.plist");
}

/**
 * Gives the absolute form of a path.
 *
 * @param run - The run
 * @param path - The path, absolute or relative to the folder of this process
 * @returns The path, starting with `/`
 *
 * @remarks
 * A path that already starts with `/` comes back as it is.
 *
 * @example
 * ```hx
 * try absolute(&run, "helix-out/bin/helix"); // "/repo/helix-out/bin/helix"
 * ```
 *
 * @since 1.0.0
 */

export function absolute(run: *Run, path: string): string | Error {
    if (startsWith(path, "/")) return path;
    let buf: u8[4096] = undefined;
    if (getcwd(&buf, buf.len) == null) return path;
    let len: usize = 0;
    while (len < buf.len && buf[len] != 0) len++;
    return try text(run, `${buf[0..len]}/${path}`);
}

/**
 * Makes the temporary folder of a run.
 *
 * @param run - The run, whose arena holds the path
 * @returns The path of a new, empty folder under `$TMPDIR`, or under `/tmp` without it
 *
 * @remarks
 * The name holds the number of this process, so two runs at once keep apart, and a folder left by a run before is
 * removed first.
 *
 * @example
 * ```hx
 * try makeTemp(&run); // "/tmp/helix-e2e-4242"
 * ```
 *
 * @since 1.0.0
 */

export function makeTemp(run: *Run): string | Error {
    let base = Env {}.get("TMPDIR") ?? "/tmp";
    while (endsWith(base, "/")) base = base[0..base.len - 1];
    const dir = try text(run, `${base}/helix-e2e-${getpid()}`);
    if (exists(dir)) try deleteFolder(dir);
    try makePath(dir);
    return dir;
}

/**
 * Removes a folder and everything in it.
 *
 * @param dir - The folder
 * @returns Nothing, or the error that stopped the removal
 *
 * @remarks
 * It goes through `deleteTree` of `std/fs`, and exists so that the checks name what they remove.
 *
 * @example
 * ```hx
 * try deleteFolder(run.temp);
 * ```
 *
 * @since 1.0.0
 */

export function deleteFolder(dir: string): void | Error {
    try deleteTree(dir);
}

/**
 * Copies a folder and everything in it.
 *
 * @param run - The run
 * @param from - The folder to copy
 * @param to - The new folder
 * @returns Nothing, or the error that stopped the copy
 *
 * @remarks
 * It leaves out `helix-out` and `.helix-cache`, which a build of a project leaves behind.
 *
 * @example
 * ```hx
 * try copyTree(&run, "e2e/projects/bins", try text(&run, `${run.temp}/bins`));
 * ```
 *
 * @since 1.0.0
 */

export function copyTree(run: *Run, from: string, to: string): void | Error {
    try makePath(to);
    let folder = try Dir.open(from);
    defer folder.close();
    while (const name = try folder.next()) {
        if (equal(name, "helix-out") || equal(name, ".helix-cache")) continue;
        const source = try text(run, `${from}/${name}`);
        const target = try text(run, `${to}/${name}`);
        if ((try stat(source)).kind == Kind.Directory) {
            try copyTree(run, source, target);
        } else {
            try copyFile(source, target);
        }
    }
}

/**
 * Reads the machine of an ELF executable.
 *
 * @param run - The run
 * @param path - The path of the file
 * @param bits - The width that the file must have, 32 or 64
 * @returns The `e_machine` of the header, or null when the file is not an ELF file of that width
 *
 * @remarks
 * It reads the header itself, so the checks need no `file` command.
 *
 * @example
 * ```hx
 * try elfMachine(&run, "fw", 32); // 40, an ARM executable
 * ```
 *
 * @since 1.0.0
 */

export function elfMachine(run: *Run, path: string, bits: u8): ?u16 | Error {
    const bytes = readFile(run.a, path) catch return null;
    if (bytes.len < 20 || bytes[0] != 0x7f || bytes[1] != 'E' || bytes[2] != 'L' || bytes[3] != 'F') return null;
    if (bytes[4] != (bits == 32 ? 1 : 2)) return null;
    return (bytes[18] as u16) | ((bytes[19] as u16) << 8);
}

/**
 * Whether a file is a Windows executable.
 *
 * @param run - The run
 * @param path - The path of the file
 * @returns `true` when the file starts with `MZ` and its PE header is where that header says
 *
 * @remarks
 * The offset of the PE header is the 32-bit number at byte 60.
 *
 * @example
 * ```hx
 * try isWindowsExe(&run, "spec.exe"); // true
 * ```
 *
 * @since 1.0.0
 */

export function isWindowsExe(run: *Run, path: string): bool | Error {
    const bytes = readFile(run.a, path) catch return false;
    if (bytes.len < 64 || bytes[0] != 'M' || bytes[1] != 'Z') return false;
    const at = (bytes[60] as usize) | ((bytes[61] as usize) << 8) | ((bytes[62] as usize) << 16);
    return at + 4 <= bytes.len && bytes[at] == 'P' && bytes[at + 1] == 'E' && bytes[at + 2] == 0 && bytes[at + 3] == 0;
}
