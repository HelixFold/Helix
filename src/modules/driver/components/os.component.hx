/**
 * Imports
 */

import * as fmt from "std/fmt";
import { ArrayList } from "std/list";
import { cAllocator } from "std/heap";
import * as sys from "@modules/driver/bindings/sys.binding";
import { PATH_MAX, S_IFMT } from "@modules/driver/constants/os.constant";
import { hxAlloc, hxStrndup, hxFatalMessage } from "@components/memory.component";
import { Strings, Stat } from "@modules/driver/components/structs/os-component.struct";

/**
 * The functions of host.c that hide what differs between macOS, Linux, and Windows.
 *
 * @remarks
 * Each one takes plain C types and NUL-terminated paths with `/` on every system.
 * Most of them return 1 on success and 0 on failure, with `errno` set for {@link errno} to read.
 * A process is a handle, which is a pid or a Windows process handle.
 *
 * @since 1.0.0
 */

extern "C" function hx_os_errno(): i32;
extern "C" function hx_os_stdout(): ?u8[*];
extern "C" function hx_os_stderr(): ?u8[*];
extern "C" function hx_os_isatty(fd: i32): i32;
extern "C" function hx_os_pid(): i32;
extern "C" function hx_os_cwd(buf: u8[*], cap: usize): i32;
extern "C" function hx_os_chdir(path: readonly u8[*]): i32;
extern "C" function hx_os_realpath(path: readonly u8[*], buf: u8[*], cap: usize): i32;
extern "C" function hx_os_access(path: readonly u8[*], what: i32): i32;
extern "C" function hx_os_stat(path: readonly u8[*], follow: i32, mode: *u32, mtime: *i64): i32;
extern "C" function hx_os_mkdir(path: readonly u8[*], existOk: i32): i32;
extern "C" function hx_os_chmod(path: readonly u8[*], mode: u32): i32;
extern "C" function hx_os_dir_open(path: readonly u8[*]): ?u8[*];
extern "C" function hx_os_dir_next(handle: ?u8[*], buf: u8[*], cap: usize): i32;
extern "C" function hx_os_dir_close(handle: ?u8[*]): void;
extern "C" function hx_os_remove_tree(path: readonly u8[*]): void;
extern "C" function hx_os_spawn(argv: (?u8[*])[*], count: usize, quiet: i32, out: ?readonly u8[*]): i64;
extern "C" function hx_os_wait(child: i64): i64;
extern "C" function hx_os_wait_any(code: *i64): i64;
extern "C" function hx_os_cpu_count(): i64;
extern "C" function hx_os_seconds(): f64;
extern "C" function hx_os_matches(pattern: readonly u8[*], name: readonly u8[*]): i32;
extern "C" function hx_os_exe_path(buf: u8[*], cap: usize): i32;

/**
 * Formats a template into new memory that ends in a NUL.
 *
 * @param text - The template to format
 * @returns The formatted text, whose byte after the end is a NUL so that C can read it
 *
 * @remarks
 * This is how the driver builds every string that it later hands to C.
 * The memory is never freed, which the short-lived driver can afford.
 *
 * @example
 * ```hx
 * const path = allocCString(`${root}/build.hx`); // "/work/app/build.hx", NUL-terminated
 * ```
 *
 * @see toCString
 * @since 1.0.0
 */

export function allocCString(text: Format): string {
    const n = fmt.count(text) catch 0;
    const buf = hxAlloc(n + 1);
    unsafe {
        void (fmt.bufPrint(buf[0..n], text) catch []);
        buf[n] = 0;
        return buf[0..n];
    }
}

/**
 * Copies a string into new memory that ends in a NUL.
 *
 * @param text - The string, which may not end in a NUL
 * @returns The copy as a C string
 *
 * @remarks
 * Use it for a slice of another string, whose next byte is not a NUL.
 *
 * @example
 * ```hx
 * sys.getenv(toCString("HOME")); // the C library reads "HOME" up to the NUL
 * ```
 *
 * @see allocCString
 * @since 1.0.0
 */

export function toCString(text: string): readonly u8[*] {
    return hxStrndup(text.ptr, text.len);
}

/**
 * Treats a C string as one that is only read.
 *
 * @param text - The C string
 * @returns The same pointer, as read-only
 *
 * @remarks
 * Only the type changes, so the result still points into the memory of the C library.
 * Use it where a C function returns a writable pointer that the driver only reads, such as `strerror`.
 *
 * @example
 * ```hx
 * fromCString(asReadonly(sys.strerror(2))); // "No such file or directory"
 * ```
 *
 * @since 1.0.0
 */

export function asReadonly(text: ?u8[*]): ?readonly u8[*] {
    unsafe {
        return @ptrCast(?readonly u8[*], text);
    }
}

/**
 * Views a C string as a Helix string without copying it.
 *
 * @param text - The NUL-terminated C string, or `null`
 * @returns The bytes before the NUL, or an empty string for `null`
 *
 * @remarks
 * The result shares the memory of the C string, so it lives exactly as long as that memory does.
 *
 * @example
 * ```hx
 * fromCString(null); // ""
 * ```
 *
 * @since 1.0.0
 */

export function fromCString(text: ?readonly u8[*]): string {
    if (text == null) return "";
    unsafe {
        return text[0..sys.strlen(text)];
    }
}

/**
 * Creates an empty list of strings on the C heap.
 *
 * @returns The empty list
 *
 * @remarks
 * The list uses the C allocator, and the driver never frees it.
 *
 * @example
 * ```hx
 * strings().items.len; // 0
 * ```
 *
 * @see Strings
 * @since 1.0.0
 */

export function strings(): Strings {
    return ArrayList<string>.init(cAllocator());
}

/**
 * Appends a string to a list.
 *
 * @param list - The list to grow
 * @param text - The string to append, which the list keeps without copying it
 *
 * @remarks
 * Running out of memory ends the process with a fatal message.
 *
 * @example
 * ```hx
 * let args = strings();
 * add(&args, "cc"); // args holds [ "cc" ]
 * ```
 *
 * @see Strings
 * @since 1.0.0
 */

export function add(list: *Strings, text: string): void {
    list.append(text) catch hxFatalMessage("out of memory");
}

/**
 * Compares two strings byte by byte, as C's `strcmp` does.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns -1 when `a` sorts first, 1 when `b` does, or 0 when they are equal
 *
 * @remarks
 * A string sorts before every longer string that starts with it.
 *
 * @example
 * ```hx
 * compare("ab", "abc"); // -1
 * ```
 *
 * @see sort
 * @since 1.0.0
 */

export function compare(a: string, b: string): i32 {
    const n = a.len < b.len ? a.len : b.len;
    for (const i of 0..n) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    if (a.len == b.len) return 0;
    return a.len < b.len ? -1 : 1;
}

/**
 * Sorts strings in place in {@link compare} order.
 *
 * @param items - The strings to sort
 *
 * @remarks
 * It uses an insertion sort, since the lists it sorts are folder listings.
 * The order is the same on every system, which makes the output of the driver reproducible.
 *
 * @example
 * ```hx
 * sort(names.items); // [ "a.hx", "b.hx" ] from [ "b.hx", "a.hx" ]
 * ```
 *
 * @see compare
 * @since 1.0.0
 */

export function sort(items: string[]): void {
    let i: usize = 1;
    while (i < items.len) {   // insertion sort: the lists are folder listings
        const x = items[i];
        let j = i;
        while (j > 0 && compare(items[j - 1], x) > 0) {
            items[j] = items[j - 1];
            j--;
        }
        items[j] = x;
        i++;
    }
}

/**
 * Finds the last occurrence of a byte in a string.
 *
 * @param text - The string to search
 * @param c - The byte to find
 * @returns The index of the last match, or `null` when the byte is not there
 *
 * @remarks
 * The search runs from the end, so it stops at the first match it meets there.
 *
 * @example
 * ```hx
 * lastIndex("a/b/c", '/'); // 3
 * ```
 *
 * @see firstIndex
 * @since 1.0.0
 */

export function lastIndex(text: string, c: u8): ?usize {
    let i = text.len;
    while (i > 0) {
        i--;
        if (text[i] == c) return i;
    }
    return null;
}

/**
 * Finds the first occurrence of a byte in a string.
 *
 * @param text - The string to search
 * @param c - The byte to find
 * @returns The index of the first match, or `null` when the byte is not there
 *
 * @remarks
 * The search runs from the start and stops at the first match.
 *
 * @example
 * ```hx
 * firstIndex("a/b/c", '/'); // 1
 * ```
 *
 * @see lastIndex
 * @since 1.0.0
 */

export function firstIndex(text: string, c: u8): ?usize {
    for (const b, i of text) {
        if (b == c) return i;
    }
    return null;
}

/**
 * Returns the last part of a path.
 *
 * @param path - The path, with `/` between its parts
 * @returns The text after the last `/`, or the whole path when it has none
 *
 * @remarks
 * Only `/` separates the parts, so a Windows path goes through {@link slashes} first.
 * The result is a view of the path, not a copy.
 *
 * @example
 * ```hx
 * baseName("src/hello.hx"); // "hello.hx"
 * ```
 *
 * @see fileStem
 * @since 1.0.0
 */

export function baseName(path: string): string {
    if (const slash = lastIndex(path, '/')) return path[slash + 1..];
    return path;
}

/**
 * Returns the name of a file without its folder and its extension.
 *
 * @param path - The path of the file
 * @returns The base name up to its last `.`
 *
 * @remarks
 * A name that starts with its only `.`, such as `.env`, stays whole.
 *
 * @example
 * ```hx
 * fileStem("src/hello.hx"); // "hello"
 * ```
 *
 * @see baseName
 * @since 1.0.0
 */

export function fileStem(path: string): string {
    const base = baseName(path);
    if (const dot = lastIndex(base, '.')) {
        if (dot > 0) return base[0..dot];
    }
    return base;
}

/**
 * Reads an environment variable.
 *
 * @param name - The name of the variable
 * @returns The value, which may be empty, or `null` when the variable is not set
 *
 * @remarks
 * The value is a view of the environment, not a copy, so changing the variable can change the text.
 *
 * @example
 * ```hx
 * getenv("HOME"); // "/Users/ada"
 * ```
 *
 * @see getenvSet
 * @since 1.0.0
 */

export function getenv(name: string): ?string {
    const value = sys.getenv(toCString(name));
    if (value == null) return null;
    return fromCString(value);
}

/**
 * Reads an environment variable that is set and not empty.
 *
 * @param name - The name of the variable
 * @returns The value, or `null` when the variable is not set or is empty
 *
 * @remarks
 * Use it for a variable where an empty value means the same as no value, such as `NO_COLOR`.
 *
 * @example
 * ```hx
 * // NO_COLOR=
 * getenvSet("NO_COLOR"); // null
 * ```
 *
 * @see getenv
 * @since 1.0.0
 */

export function getenvSet(name: string): ?string {
    if (const value = getenv(name)) {
        if (value.len > 0) return value;
    }
    return null;
}

/**
 * Reads the error code of the last C call that failed.
 *
 * @returns The value of C's `errno`
 *
 * @remarks
 * The value comes from host.c, which reads `errno` on the C side.
 * Read it right after the call that failed, because any later C call may change it.
 *
 * @example
 * ```hx
 * if (!chdir("missing")) strerror(errno()); // "No such file or directory"
 * ```
 *
 * @see strerror
 * @since 1.0.0
 */

export function errno(): i32 {
    return hx_os_errno();
}

/**
 * Describes an error code in words.
 *
 * @param code - The error code, usually from {@link errno}
 * @returns The message of the C library
 *
 * @remarks
 * The text belongs to the C library, so a later call to `strerror` may overwrite it.
 *
 * @example
 * ```hx
 * strerror(2); // "No such file or directory"
 * ```
 *
 * @since 1.0.0
 */

export function strerror(code: i32): string {
    return fromCString(asReadonly(sys.strerror(code)));
}

/**
 * Returns the id of the running process.
 *
 * @returns The process id
 *
 * @remarks
 * It is the pid on macOS and Linux and the process id from `GetCurrentProcessId` on Windows.
 *
 * @example
 * ```hx
 * pid(); // 41231
 * ```
 *
 * @since 1.0.0
 */

export function pid(): i32 {
    return hx_os_pid();
}

/**
 * Returns C's `stdout` as an untyped pointer, which is how the printers of the compiler take it.
 *
 * @returns The `FILE *` of the standard output
 *
 * @remarks
 * Use it to pass the standard output to a C function of the compiler that takes the stream as `?u8[*]`.
 *
 * @example
 * ```hx
 * hxAstPrint(&ast, stdoutFile()); // the tree goes to the standard output
 * ```
 *
 * @see cStdout
 * @since 1.0.0
 */

export function stdoutFile(): ?u8[*] {
    return hx_os_stdout();
}

/**
 * Returns C's `stderr` as an untyped pointer, which is how the printers of the compiler take it.
 *
 * @returns The `FILE *` of the standard error
 *
 * @remarks
 * Use it to pass the standard error to a C function of the compiler that takes the stream as `?u8[*]`.
 *
 * @example
 * ```hx
 * hxDiagRender(&diags, stderrFile(), false); // the errors go to the standard error
 * ```
 *
 * @since 1.0.0
 */

export function stderrFile(): ?u8[*] {
    return hx_os_stderr();
}

/**
 * Returns C's `stdout` as the typed pointer that the functions of sys.hx take.
 *
 * @returns The `FILE *` of the standard output
 *
 * @remarks
 * It casts the same pointer that {@link stdoutFile} returns, so both name one stream.
 *
 * @example
 * ```hx
 * void sys.fflush(cStdout()); // the buffered output is written
 * ```
 *
 * @see stdoutFile
 * @since 1.0.0
 */

export function cStdout(): ?*sys.FILE {
    unsafe {
        return @ptrCast(?*sys.FILE, hx_os_stdout());
    }
}

/**
 * Writes out what C has buffered for the standard output.
 *
 * @remarks
 * Call it before starting another program that writes to the same output, so the lines keep their order.
 *
 * @example
 * ```hx
 * flushStdout(); // earlier output comes before the child's output
 * ```
 *
 * @since 1.0.0
 */

export function flushStdout(): void {
    void sys.fflush(cStdout());
}

/**
 * Decides whether to color the output to a file descriptor.
 *
 * @param fd - The descriptor, 1 for the standard output or 2 for the standard error
 * @returns `true` when the descriptor is a terminal and `NO_COLOR` is not set to a value
 *
 * @remarks
 * `NO_COLOR` wins over the terminal check, and an empty `NO_COLOR` does not turn color off.
 *
 * @example
 * ```hx
 * useColor(2); // false when stderr goes to a file
 * ```
 *
 * @since 1.0.0
 */

export function useColor(fd: i32): bool {
    if (getenvSet("NO_COLOR") != null) return false;
    return hx_os_isatty(fd) != 0;
}

/**
 * Returns the folder for temporary files.
 *
 * @returns `$TMPDIR`, else Windows's `%TEMP%` with `/` between its parts, else `/tmp`
 *
 * @remarks
 * Only a variable that is set and not empty counts, so an empty `TMPDIR` falls through to `TEMP`.
 *
 * @example
 * ```hx
 * tempDir(); // "/tmp" when neither variable is set
 * ```
 *
 * @since 1.0.0
 */

export function tempDir(): string {
    if (const dir = getenvSet("TMPDIR")) return dir;
    if (const dir = getenvSet("TEMP")) return slashes(dir);
    return "/tmp";
}

/**
 * Copies a path with every `\` turned into `/`.
 *
 * @param path - The path, which may come from Windows
 * @returns The copy, written the way the compiler writes paths
 *
 * @remarks
 * The copy ends in a NUL, so it can go to C as it is.
 *
 * @example
 * ```hx
 * slashes("C:\\Users\\ada"); // "C:/Users/ada"
 * ```
 *
 * @since 1.0.0
 */

export function slashes(path: string): string {
    const copy = hxStrndup(path.ptr, path.len);
    unsafe {
        for (const i of 0..path.len) {
            if (copy[i] == '\\') copy[i] = '/';
        }
        return copy[0..path.len];
    }
}

/**
 * Returns a folder where Helix keeps what it downloads and builds once.
 *
 * @param sub - The path of the folder inside the Helix home
 * @returns `$HELIX_HOME/<sub>`, or `<home>/.cache/helix/<sub>`
 *
 * @remarks
 * The home is `$HOME`, then Windows's `%USERPROFILE%`, then {@link tempDir}.
 * The folder may not exist yet.
 *
 * @example
 * ```hx
 * helixHome("sdk"); // "/Users/ada/.cache/helix/sdk" when HELIX_HOME is not set
 * ```
 *
 * @since 1.0.0
 */

export function helixHome(sub: string): string {
    if (const home = getenvSet("HELIX_HOME")) return allocCString(`${home}/${sub}`);
    if (const home = getenvSet("HOME")) return allocCString(`${home}/.cache/helix/${sub}`);
    if (const profile = getenvSet("USERPROFILE")) return allocCString(`${slashes(profile)}/.cache/helix/${sub}`);
    return allocCString(`${tempDir()}/.cache/helix/${sub}`);
}

/**
 * Returns the current working folder.
 *
 * @returns The absolute path, or `null` when it cannot be read or is longer than {@link PATH_MAX}
 *
 * @remarks
 * The buffer is {@link PATH_MAX} bytes and never freed.
 * On Windows, host.c turns every `\` in the path into `/`.
 *
 * @example
 * ```hx
 * cwd(); // "/work/app"
 * ```
 *
 * @see chdir
 * @since 1.0.0
 */

export function cwd(): ?string {
    const buf = hxAlloc(PATH_MAX);
    if (hx_os_cwd(buf, PATH_MAX) == 0) return null;
    return fromCString(buf);
}

/**
 * Changes the current working folder.
 *
 * @param path - The folder to change to
 * @returns `true` when the change worked
 *
 * @remarks
 * It changes the folder of the whole process, so every relative path after it resolves against the new folder.
 *
 * @example
 * ```hx
 * chdir("/work/app"); // true
 * ```
 *
 * @see cwd
 * @since 1.0.0
 */

export function chdir(path: string): bool {
    return hx_os_chdir(toCString(path)) != 0;
}

/**
 * Resolves a path to an absolute one without links.
 *
 * @param path - The path to resolve
 * @returns The resolved path, or `null` when nothing exists at the path
 *
 * @remarks
 * It uses `realpath` on macOS and Linux and `GetFinalPathNameByHandleW` on Windows,
 * where the `\\?\` prefix is dropped and every `\` becomes `/`.
 *
 * @example
 * ```hx
 * realPath("."); // "/work/app"
 * ```
 *
 * @since 1.0.0
 */

export function realPath(path: string): ?string {
    const buf = hxAlloc(PATH_MAX);
    if (hx_os_realpath(toCString(path), buf, PATH_MAX) == 0) return null;
    return fromCString(buf);
}

/**
 * Checks whether anything exists at a path.
 *
 * @param path - The path to check
 * @returns `true` for a file, a folder, or anything else the system can reach there
 *
 * @remarks
 * It calls `access` with mode 0 on macOS and Linux and reads the file attributes on Windows.
 *
 * @example
 * ```hx
 * exists("helix.jsonc"); // true in a project folder
 * ```
 *
 * @since 1.0.0
 */

export function exists(path: string): bool {
    return hx_os_access(toCString(path), 0) != 0;
}

/**
 * Checks whether the process may read a path.
 *
 * @param path - The path to check
 * @returns `true` when the path exists and is readable
 *
 * @remarks
 * On Windows, host.c only checks that the path exists, since the attributes do not describe read access.
 *
 * @example
 * ```hx
 * readable("build.hx"); // false when the project has no build.hx
 * ```
 *
 * @since 1.0.0
 */

export function readable(path: string): bool {
    return hx_os_access(toCString(path), 4) != 0;
}

/**
 * Checks whether the process may run a path.
 *
 * @param path - The path to check
 * @returns `true` when the path exists and has execute permission
 *
 * @remarks
 * On Windows, any path that exists and is not a folder counts as executable.
 *
 * @example
 * ```hx
 * executable("/usr/bin/cc"); // true
 * ```
 *
 * @since 1.0.0
 */

export function executable(path: string): bool {
    return hx_os_access(toCString(path), 1) != 0;
}

/**
 * Reads the type, permissions, and change time of a path.
 *
 * @param path - The path to read
 * @param link - Whether to describe a symbolic link itself, as `lstat` does, instead of what it points at
 * @returns The facts, or `null` when nothing exists at the path
 *
 * @remarks
 * The mode has the POSIX bits on every system.
 *
 * @example
 * ```hx
 * isFile(stat("main.hx", false)!.mode); // true
 * ```
 *
 * @see Stat
 * @since 1.0.0
 */

export function stat(path: string, link: bool): ?Stat {
    let mode: u32 = 0;
    let mtime: i64 = 0;
    if (hx_os_stat(toCString(path), link ? 0 : 1, &mode, &mtime) == 0) return null;
    return Stat { mode: mode, mtime: mtime };
}

/**
 * Checks whether a mode belongs to a folder.
 *
 * @param mode - The mode from {@link stat}
 * @returns `true` for a folder
 *
 * @remarks
 * It compares the kind bits under `S_IFMT` with `0o040000`, so the permission bits do not matter.
 *
 * @example
 * ```hx
 * isDir(0o040755); // true
 * ```
 *
 * @see isDirectory
 * @since 1.0.0
 */

export function isDir(mode: u32): bool {
    return (mode & S_IFMT) == 0o040000;
}

/**
 * Checks whether a mode belongs to a regular file.
 *
 * @param mode - The mode from {@link stat}
 * @returns `true` for a regular file
 *
 * @remarks
 * It compares the kind bits under `S_IFMT` with `0o100000`, so the permission bits do not matter.
 *
 * @example
 * ```hx
 * isFile(0o100644); // true
 * ```
 *
 * @since 1.0.0
 */

export function isFile(mode: u32): bool {
    return (mode & S_IFMT) == 0o100000;
}

/**
 * Checks whether a mode belongs to a symbolic link.
 *
 * @param mode - The mode from {@link stat} with `link` set
 * @returns `true` for a symbolic link
 *
 * @remarks
 * It compares the kind bits under `S_IFMT` with `0o120000`.
 * A mode read with `link` unset follows the link and never has these bits.
 *
 * @example
 * ```hx
 * isLink(0o120755); // true
 * ```
 *
 * @since 1.0.0
 */

export function isLink(mode: u32): bool {
    return (mode & S_IFMT) == 0o120000;
}

/**
 * Checks whether a path is a folder, following links.
 *
 * @param path - The path to check
 * @returns `true` for a folder or a link to one, and `false` when nothing exists at the path
 *
 * @remarks
 * It combines {@link stat} without `link` and {@link isDir}, so a path that cannot be read also gives `false`.
 *
 * @example
 * ```hx
 * isDirectory("src"); // true
 * ```
 *
 * @since 1.0.0
 */

export function isDirectory(path: string): bool {
    if (const st = stat(path, false)) return isDir(st.mode);
    return false;
}

/**
 * Lists the names in a folder.
 *
 * @param path - The folder to list
 * @returns The names without `.` and `..`, or `null` when the folder cannot be read
 *
 * @remarks
 * The names come in the order that the system lists them, so callers that need a stable order {@link sort} them.
 *
 * @example
 * ```hx
 * listDir("src")!.items; // [ "main.hx", "modules" ]
 * ```
 *
 * @since 1.0.0
 */

export function listDir(path: string): ?Strings {
    const d = hx_os_dir_open(toCString(path));
    if (d == null) return null;
    let names = strings();
    let buf: u8[1024] = undefined;
    while (hx_os_dir_next(d, &buf, buf.len) != 0) {
        unsafe {
            const name = fromCString(@ptrCast(readonly u8[*], &buf));
            if (name.len == 0 || (name[0] == '.' && (name.len == 1 || (name.len == 2 && name[1] == '.')))) continue;
            add(&names, hxStrndup(name.ptr, name.len)[0..name.len]);
        }
    }
    hx_os_dir_close(d);
    return names;
}

/**
 * Creates a folder and every missing folder above it, as `mkdir -p` does.
 *
 * @param path - The folder to create
 * @returns `true` when the folder exists afterward, whether this call made it or not
 *
 * @remarks
 * The drive of a Windows path such as `C:/` is left alone.
 *
 * @example
 * ```hx
 * makeDirs(".helix-cache/obj"); // true, and both folders exist
 * ```
 *
 * @see makeDir
 * @since 1.0.0
 */

export function makeDirs(path: string): bool {
    const buf = hxStrndup(path.ptr, path.len);
    unsafe {
        for (const i of 1..path.len) {
            if (buf[i] != '/') continue;
            if (i == 2 && buf[1] == ':') continue;   // `C:/`: the drive is there
            buf[i] = 0;
            void hx_os_mkdir(buf, 1);
            buf[i] = '/';
        }
    }
    return hx_os_mkdir(buf, 1) != 0;
}

/**
 * Creates one folder.
 *
 * @param path - The folder to create
 * @returns `true` when this call made it, and `false` when it already exists or its parent is missing
 *
 * @remarks
 * The failure when the folder exists lets several processes agree on which one claims a folder.
 *
 * @example
 * ```hx
 * makeDir("out"); // true
 * makeDir("out"); // false
 * ```
 *
 * @see makeDirs
 * @since 1.0.0
 */

export function makeDir(path: string): bool {
    return hx_os_mkdir(toCString(path), 0) != 0;
}

/**
 * Removes a file or a folder with everything in it, as `rm -rf` does.
 *
 * @param path - The path to remove
 *
 * @remarks
 * A symbolic link is removed itself, never what it points at.
 * A path where nothing exists is left alone.
 *
 * @example
 * ```hx
 * removeTree(".helix-cache"); // the folder and its contents are gone
 * ```
 *
 * @since 1.0.0
 */

export function removeTree(path: string): void {
    hx_os_remove_tree(toCString(path));
}

/**
 * Removes a file, ignoring a failure.
 *
 * @param path - The file to remove
 *
 * @remarks
 * It calls `unlink` of C and drops the result, so use it only where a missing file is fine.
 * It does not remove a folder, which {@link removeTree} does.
 *
 * @example
 * ```hx
 * unlink("a.o"); // a.o is gone, or was never there
 * ```
 *
 * @since 1.0.0
 */

export function unlink(path: string): void {
    void sys.unlink(toCString(path));
}

/**
 * Moves a file or a folder to a new path.
 *
 * @param from - The current path
 * @param to - The new path, where the move replaces an existing file
 * @returns `true` when the move worked
 *
 * @remarks
 * It calls `rename` of C, so a move across file systems fails.
 *
 * @example
 * ```hx
 * rename("out.tmp", "out"); // true
 * ```
 *
 * @since 1.0.0
 */

export function rename(from: string, to: string): bool {
    return sys.rename(toCString(from), toCString(to)) == 0;
}

/**
 * Reads a whole file.
 *
 * @param path - The file to read
 * @returns The bytes of the file followed by a NUL outside the string, or `null` when the file cannot be opened
 *
 * @remarks
 * The trailing NUL lets the text go to C without a copy.
 *
 * @example
 * ```hx
 * readText("helix.jsonc"); // "{ \"name\": \"app\" }"
 * ```
 *
 * @see writeText
 * @since 1.0.0
 */

export function readText(path: string): ?string {
    const f = sys.fopen(toCString(path), "rb");
    if (f == null) return null;
    void sys.fseek(f, 0, sys.SEEK_END);
    const size = sys.ftell(f);
    void sys.fseek(f, 0, 0);
    const want: usize = size < 0 ? 0 : size as usize;
    const text = hxAlloc(want + 1);
    const n = want > 0 ? sys.fread(text, 1, want, f) : 0;
    unsafe {
        text[n] = 0;
    }
    void sys.fclose(f);
    unsafe {
        return text[0..n];
    }
}

/**
 * Replaces the contents of a file, creating it when it is missing.
 *
 * @param path - The file to write
 * @param text - The new contents
 * @returns `true` when every byte was written and the file closed cleanly
 *
 * @remarks
 * The file opens in binary mode, so Windows writes the bytes without turning `\n` into `\r\n`.
 *
 * @example
 * ```hx
 * writeText(".helix-cache/packages.txt", ""); // true
 * ```
 *
 * @see readText
 * @since 1.0.0
 */

export function writeText(path: string, text: string): bool {
    const f = sys.fopen(toCString(path), "wb");
    if (f == null) return false;
    const ok = sys.fwrite(text.ptr, 1, text.len, f) == text.len;
    return sys.fclose(f) == 0 && ok;
}

/**
 * Copies the bytes of a file to another path.
 *
 * @param from - The file to copy
 * @param to - The path of the copy, which replaces any file there
 * @param keepMode - Whether to give the copy the permission bits of the original too
 * @returns `true` when the copy is complete
 *
 * @remarks
 * The bytes go through a 64 KiB buffer.
 * A copy that cannot open its target leaves the original untouched and returns `false`.
 *
 * @example
 * ```hx
 * copyFile("build/app", "bin/app", true); // true, and bin/app is executable
 * ```
 *
 * @since 1.0.0
 */

export function copyFile(from: string, to: string, keepMode: bool): bool {
    const input = sys.fopen(toCString(from), "rb");
    if (input == null) return false;
    const mode = stat(from, false);
    const output = sys.fopen(toCString(to), "wb");
    if (output == null) {
        void sys.fclose(input);
        return false;
    }
    let buf: u8[65536] = undefined;
    let ok = true;
    while (true) {
        const n = sys.fread(&buf, 1, buf.len, input);
        if (n == 0) break;
        if (sys.fwrite(&buf, 1, n, output) != n) ok = false;
    }
    void sys.fclose(input);
    ok = sys.fclose(output) == 0 && ok;
    if (keepMode) {
        if (const st = mode) void hx_os_chmod(toCString(to), st.mode & 0o777);
    }
    return ok;
}

/**
 * Builds a C `argv` array from strings.
 *
 * @param args - The arguments
 * @returns An array of NUL-terminated copies, followed by a `null` entry
 *
 * @remarks
 * Every argument is copied, since a Helix string does not end in a NUL.
 * Neither the array nor the copies are ever freed.
 *
 * @example
 * ```hx
 * cArgs([ "cc", "-c" ]); // { "cc", "-c", NULL }
 * ```
 *
 * @since 1.0.0
 */

export function cArgs(args: readonly string[]): (?u8[*])[*] {
    unsafe {
        const argv = @ptrCast((?u8[*])[*], hxAlloc((args.len + 1) * @sizeOf(?u8[*])));
        for (const arg, i of args) argv[i] = hxStrndup(arg.ptr, arg.len);
        argv[args.len] = null;
        return argv;
    }
}

/**
 * Starts a program without waiting for it.
 *
 * @param args - The program, looked up in `PATH`, followed by its arguments
 * @param quiet - Whether to send the standard error of the program nowhere
 * @param out - A file to send the standard output of the program to, or `null` to keep it
 * @returns The process handle, or `null` when the program cannot start
 *
 * @remarks
 * It uses `posix_spawnp` on macOS and Linux and `CreateProcessW` on Windows.
 * The output file is created or emptied before the program starts.
 * The reason for a failure is left in {@link errno}.
 *
 * @example
 * ```hx
 * const child = spawn([ "cc", "-c", "a.c" ], false, null);
 * waitFor(child!); // 0
 * ```
 *
 * @see waitFor
 * @see waitAny
 *
 * @since 1.0.0
 */

export function spawn(args: readonly string[], quiet: bool, out: ?string): ?i64 {
    let outFile: ?readonly u8[*] = null;
    if (const file = out) outFile = toCString(file);
    const child = hx_os_spawn(cArgs(args), args.len, quiet ? 1 : 0, outFile);
    if (child < 0) return null;
    return child;
}

/**
 * Waits for a started program to end.
 *
 * @param child - The handle from {@link spawn}
 * @returns The exit code, 128 plus the signal that killed it, or -1 when waiting failed
 *
 * @remarks
 * It retries a wait that a signal interrupts, so it returns only once the program ends or the wait fails.
 *
 * @example
 * ```hx
 * waitFor(spawn([ "false" ], false, null)!); // 1
 * ```
 *
 * @since 1.0.0
 */

export function waitFor(child: i64): i64 {
    return hx_os_wait(child);
}

/**
 * Waits for any started program to end.
 *
 * @param code - Where to store the exit code of the program that ended
 * @returns The handle of that program, or `null` when none is running or waiting failed
 *
 * @remarks
 * Use it to run several programs at once and start the next one as each ends.
 *
 * @example
 * ```hx
 * let code: i64 = 0;
 * waitAny(&code); // the handle of the first child to end, with its exit code in code
 * ```
 *
 * @see spawn
 * @since 1.0.0
 */

export function waitAny(code: *i64): ?i64 {
    const child = hx_os_wait_any(code);
    if (child < 0) return null;
    return child;
}

/**
 * Runs a program and waits for it to end.
 *
 * @param args - The program, looked up in `PATH`, followed by its arguments
 * @returns The exit code, 128 plus the signal that killed it, or -1 when it could not start
 *
 * @remarks
 * A program that cannot start is reported on the standard error with the reason.
 *
 * @example
 * ```hx
 * run([ "true" ]); // 0
 * ```
 *
 * @see spawn
 * @since 1.0.0
 */

export function run(args: readonly string[]): i32 {
    if (const child = spawn(args, false, null)) return waitFor(child) as i32;
    eprintln(`error: cannot run '${args[0]}': ${strerror(errno())}`);
    return -1;
}

/**
 * Returns the number of processors that the system has online.
 *
 * @returns The processor count
 *
 * @remarks
 * It reads `_SC_NPROCESSORS_ONLN` on macOS and Linux and `GetSystemInfo` on Windows.
 * The driver uses it to decide how many jobs to run at once.
 *
 * @example
 * ```hx
 * cpuCount(); // 10
 * ```
 *
 * @since 1.0.0
 */

export function cpuCount(): i64 {
    return hx_os_cpu_count();
}

/**
 * Reads a clock for measuring how long something takes.
 *
 * @returns The current time in seconds, as a fraction
 *
 * @remarks
 * Only the difference between two readings has a meaning.
 *
 * @example
 * ```hx
 * const start = secondsNow();
 * secondsNow() - start; // 0.27
 * ```
 *
 * @since 1.0.0
 */

export function secondsNow(): f64 {
    return hx_os_seconds();
}

/**
 * Checks whether a name matches a shell pattern.
 *
 * @param pattern - The pattern, with `*`, `?`, and `[...]`
 * @param name - The name to match
 * @returns `true` when the whole name matches
 *
 * @remarks
 * It uses `fnmatch` without flags on macOS and Linux and a matcher in host.c with the same rules on Windows.
 * A `*` matches a `/` too, since no flag asks for path matching.
 *
 * @example
 * ```hx
 * matches("*.spec.hx", "os-component.spec.hx"); // true
 * ```
 *
 * @since 1.0.0
 */

export function matches(pattern: string, name: string): bool {
    return hx_os_matches(toCString(pattern), toCString(name)) != 0;
}

/**
 * Returns the path of the running compiler.
 *
 * @returns The absolute path of the executable with links resolved, or `null` when the system cannot tell
 *
 * @remarks
 * The path of the executable comes from `_NSGetExecutablePath` on macOS, `/proc/self/exe` on Linux,
 * and `GetModuleFileNameW` on Windows.
 * {@link realPath} then resolves it, so a link to the compiler gives the real install folder.
 *
 * @example
 * ```hx
 * compilerPath(); // "/opt/helix/bin/helix"
 * ```
 *
 * @see besideCompiler
 * @since 1.0.0
 */

export function compilerPath(): ?string {
    let buf: u8[4096] = undefined;
    if (hx_os_exe_path(&buf, buf.len) == 0) return null;
    unsafe {
        return realPath(fromCString(@ptrCast(readonly u8[*], &buf)));
    }
}

/**
 * Finds a file that ships in the folder of the compiler.
 *
 * @param relative - The path of the file inside that folder
 * @returns `<folder of helix>/<relative>`, or the same path two folders up, or `null` when neither is readable
 *
 * @remarks
 * It is how the compiler finds its standard library and runtime files next to the installed executable.
 * A compiler built from the repository runs from `.helix-out/bin`,
 * so it also looks two folders up, where the repository keeps its own `lib`.
 *
 * @example
 * ```hx
 * besideCompiler("lib/std/build-runner.hx"); // "/opt/helix/bin/lib/std/build-runner.hx"
 * ```
 *
 * @see compilerPath
 * @since 1.0.0
 */

export function besideCompiler(relative: string): ?string {
    if (const exe = compilerPath()) {
        if (const slash = lastIndex(exe, '/')) {
            const path = allocCString(`${exe[0..slash]}/${relative}`);
            if (readable(path)) return path;
            const repository = allocCString(`${exe[0..slash]}/../../${relative}`);
            if (readable(repository)) return realPath(repository) ?? repository;
        }
    }
    return null;
}
