/**
 * Imports
 */

import * as fmt from "std/fmt";
import { ArrayList } from "std/list";
import { alloc, cAllocator } from "std/heap";
import * as sys from "@modules/driver/bindings/sys.binding";
import * as os from "@modules/driver/components/os.component";
import { hxFatalMessage } from "@components/memory.component";
import { equal, startsWith, endsWith, indexOf } from "std/text";
import { HxSha256 } from "@services/structs/sha256-service.struct";
import { WasiPicked } from "@modules/driver/constants/libc.constant";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { Sdk, Job, Jobs } from "@modules/driver/components/structs/libc-component.struct";
import { hxSha256Init, hxSha256Update, hxSha256Finish, hxSha256Hex } from "@services/sha256.service";
import { BottomDirs, OmitMath, OmitComplex, WasiOmitHeaders } from "@modules/driver/constants/libc.constant";
import { Bulk, MallocDirs, FtsDirs, OmitInternal, OmitStdio } from "@modules/driver/constants/libc.constant";
import { allocCString, toCString, fromCString, add, strings } from "@modules/driver/components/os.component";
import { CrtName, CrtUrl, WasiLibcSha256, None, COnly, CAndAsm } from "@modules/driver/constants/libc.constant";
import { OmitString, OmitLocale, MuslVersion, MuslUrl, MuslSha256 } from "@modules/driver/constants/libc.constant";
import { CrtSha256, WasiLibcVersion, WasiLibcUrl, TopDirs, Printscan } from "@modules/driver/constants/libc.constant";

/**
 * Runs a program and waits for it.
 *
 * @param args - The program and its arguments
 * @returns The exit code, 128 plus the signal that killed it, or -1 when the program could not start
 *
 * @remarks
 * It prints nothing when the program cannot start, so the caller reports the failure in its own words.
 * A failed wait gives a code above 255 from the OS layer, which it also turns into -1.
 * It runs `curl`, `tar`, `llvm-ar`, and the other tools of a C library build.
 *
 * @since 1.0.0
 */

function run(args: readonly string[]): i32 {
    if (const child = os.spawn(args, false, null)) {
        const code = os.waitFor(child);
        return code > 255 ? -1 : code as i32;
    }
    return -1;
}

/**
 * Stops the compiler with an out of memory error.
 *
 * @remarks
 * Every failed allocation of a C library build ends here, since the build cannot go on without memory.
 *
 * @since 1.0.0
 */

function outOfMemory(): noreturn {
    hxFatalMessage("out of memory");
}

/**
 * Appends a text to a file being generated.
 *
 * @param b - The builder of the file
 * @param text - The text to append
 *
 * @remarks
 * A failed append stops the compiler through {@link outOfMemory}, so the callers never handle an error.
 *
 * @since 1.0.0
 */

function put(b: *fmt.Builder, text: Format): void {
    b.append(text) catch outOfMemory();
}

/**
 * The functions of host.c that find the LLVM library and the macOS version.
 *
 * @remarks
 * `hx_os_image_of` writes the path of the library that holds a symbol, and returns 0 when it cannot.
 * `hx_os_macos_version` writes the version of macOS this runs on, and returns 0 off macOS or on failure.
 *
 * @since 1.0.0
 */

extern "C" function hx_os_image_of(symbol: extern "C" (a0: i32, a1: i32) => sys.CXIndex, buf: u8[*], cap: usize): i32;
extern "C" function hx_os_macos_version(buf: u8[*], cap: usize): i32;

/**
 * Finds the folder of the libclang that this compiler is linked to.
 *
 * @returns The folder, with symbolic links resolved, or `null` when it cannot be found
 *
 * @remarks
 * It is the folder of the image that holds `clang_createIndex`,
 * which for a compiler linked to a shared LLVM also holds `libLLVM`.
 * A release links LLVM in, so its image is the compiler itself and its folder holds no LLVM library.
 *
 * @example
 * ```hx
 * linkedLlvmLibDir(); // "/opt/homebrew/Cellar/llvm/23.1.4/lib"
 * ```
 *
 * @see llvmLibDir
 * @since 1.0.0
 */

export function linkedLlvmLibDir(): ?string {
    let buf: u8[4096] = undefined;
    if (hx_os_image_of(sys.clang_createIndex, &buf, buf.len) == 0) return null;
    unsafe {
        const lib = os.realPath(fromCString(@ptrCast(readonly u8[*], &buf))) ?? "";
        if (const slash = os.lastIndex(lib, '/')) return lib[0..slash];
    }
    return null;
}

/**
 * Finds the library folder of the LLVM that this compiler uses.
 *
 * @returns The folder, or `null` when it cannot be found
 *
 * @remarks
 * A release has LLVM linked in and its tools in `lib/llvm/bin`, so its folder is `lib/llvm/lib` next to the compiler.
 * Otherwise it is the folder of the libclang that the compiler is linked to, from {@link linkedLlvmLibDir}.
 * {@link llvmTool} finds the LLVM tools next to it.
 *
 * @example
 * ```hx
 * llvmLibDir(); // "/opt/homebrew/Cellar/llvm/23.1.4/lib"
 * ```
 *
 * @see llvmTool
 * @since 1.0.0
 */

export function llvmLibDir(): ?string {
    if (const shipped = os.besideCompiler("lib/llvm/lib")) return shipped;
    return linkedLlvmLibDir();
}

/**
 * Finds an LLVM tool next to the LLVM that this compiler uses.
 *
 * @param name - The name of the tool, such as `clang`, `ld.lld`, or `llvm-ar`
 * @returns The path of the tool, or `null` when the `bin` folder next to the LLVM library folder does not have it
 *
 * @remarks
 * The `bin` folder is resolved, but the tool keeps its own name,
 * since `llvm-dlltool` and `ld.lld` are links to programs that act on the name they run under.
 * A name with `.exe` after it is found as well, for Windows.
 *
 * @example
 * ```hx
 * llvmTool("clang");              // "/opt/homebrew/Cellar/llvm/<version>/bin/clang"
 * llvmTool("helix-no-such-tool"); // null
 * ```
 *
 * @see findTool
 * @since 1.0.0
 */

export function llvmTool(name: string): ?string {
    if (const lib = llvmLibDir()) {
        // resolve the folder but keep the tool's own name: llvm-dlltool and ld.lld are links to binaries that act on
        // the name they're run by
        if (const bin = os.realPath(allocCString(`${lib}/../bin`))) {
            const path = allocCString(`${bin}/${name}`);
            if (os.executable(path)) return path;
            const exe = allocCString(`${bin}/${name}.exe`);
            if (os.executable(exe)) return exe;
        }
    }
    return null;
}

/**
 * Finds an LLVM tool such as `ld.lld`, `ld64.lld`, `wasm-ld`, or `dsymutil`.
 *
 * @param name - The name of the tool
 * @returns The path of the tool, or `null` when it is nowhere
 *
 * @remarks
 * It looks next to the LLVM that Helix links with {@link llvmTool} first,
 * then in `/opt/homebrew/bin`, where the Homebrew lld package puts its linkers.
 *
 * @example
 * ```hx
 * findTool("ld64.lld"); // "/opt/homebrew/bin/ld64.lld"
 * ```
 *
 * @see llvmTool
 * @since 1.0.0
 */

export function findTool(name: string): ?string {
    if (const path = llvmTool(name)) return path;
    const brew = allocCString(`/opt/homebrew/bin/${name}`);   // lld from its own Homebrew package
    if (os.executable(brew)) return brew;
    return null;
}

/**
 * Adds the command of a linker to an argument list.
 *
 * @param args - The argument list that gets the command
 * @param name - The linker, `ld.lld`, `ld64.lld`, or `wasm-ld`
 * @returns `true` when the linker or lld was found, `false` when neither was
 *
 * @remarks
 * It adds the linker itself when {@link findTool} finds it.
 * Otherwise it adds lld with `-flavor` and the flavor the name stands for, `darwin`, `wasm`, or `gnu`.
 * A Windows release ships lld in that form,
 * since Windows has no links and a copy of lld for each name would take 75 MB.
 *
 * @example
 * ```hx
 * let args = strings();
 * addLinker(&args, "ld64.lld"); // true, args is [ "/opt/homebrew/bin/ld64.lld" ]
 * ```
 *
 * @since 1.0.0
 */

export function addLinker(args: *Strings, name: string): bool {
    if (const tool = findTool(name)) {
        add(args, tool);
        return true;
    }
    if (const lld = findTool("lld")) {
        add(args, lld);
        add(args, "-flavor");
        add(args, equal(name, "ld64.lld") ? "darwin" : equal(name, "wasm-ld") ? "wasm" : "gnu");
        return true;
    }
    return false;
}

/**
 * Finds the linker of Apple, from the command-line tools or from Xcode.
 *
 * @returns The path of `ld`, or `null` when neither is installed
 *
 * @remarks
 * arm64e programs need it, since ld64.lld cannot write the signed pointers that they hold.
 *
 * @example
 * ```hx
 * appleLinker(); // "/Library/Developer/CommandLineTools/usr/bin/ld"
 * ```
 *
 * @since 1.0.0
 */

export function appleLinker(): ?string {
    const candidates: string[2] = [
        "/Library/Developer/CommandLineTools/usr/bin/ld",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld",
    ];
    for (const path of candidates) {
        if (os.executable(path)) return path;
    }
    return null;
}

/**
 * Finds the macOS SDK without running `xcrun`.
 *
 * @returns The SDK and its version, or `null` when no candidate has a readable version
 *
 * @remarks
 * It tries `$SDKROOT`, then the SDK of Xcode, then the SDK of the command-line tools.
 * The version is the `"Version"` value in the first 8191 bytes of `SDKSettings.json`, where it sits near the top.
 *
 * @example
 * ```hx
 * macosSdk(); // { path: "/Applications/Xcode.app/.../MacOSX.sdk", version: "27.0" }
 * ```
 *
 * @see Sdk
 * @since 1.0.0
 */

export function macosSdk(): ?Sdk {
    const candidates: string[3] = [
        os.getenv("SDKROOT") ?? "",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    ];
    for (const candidate of candidates) {
        if (candidate.len == 0) continue;
        const settings = os.readText(allocCString(`${candidate}/SDKSettings.json`));
        if (settings == null) continue;
        // "Version":"27.0" is near the top of SDKSettings.json
        const text = settings.len > 8191 ? settings[0..8191] : settings;
        const key = indexOf(text, "\"Version\"");
        if (key == null) continue;
        const rest = text[key + 9..];
        const quote = os.firstIndex(rest, '"');
        if (quote == null) continue;
        const end = os.firstIndex(rest[quote + 1..], '"');
        if (end == null) continue;
        return Sdk { path: candidate, version: rest[quote + 1..quote + 1 + end] };
    }
    return null;
}

/**
 * Reads the version of macOS that this runs on.
 *
 * @returns The version, or `null` off macOS
 *
 * @remarks
 * The compiler uses it as the minimum macOS version of the programs that it builds for this machine.
 *
 * @example
 * ```hx
 * macosVersion(); // "27.0"
 * ```
 *
 * @since 1.0.0
 */

export function macosVersion(): ?string {
    let version: u8[64] = undefined;
    if (hx_os_macos_version(&version, version.len) == 0) return null;
    unsafe {
        return allocCString(`${fromCString(@ptrCast(readonly u8[*], &version))}`);
    }
}

/**
 * Finds the folder of the headers that clang brings itself, such as `stddef.h` and `stdarg.h`.
 *
 * @returns The `<LLVM library folder>/clang/<version>` folder, or `null` when there is none
 *
 * @remarks
 * The version folder is the first entry under `clang` whose name starts with a digit.
 *
 * @example
 * ```hx
 * clangResourceDir(); // "/opt/homebrew/Cellar/llvm/<version>/lib/clang/23"
 * ```
 *
 * @since 1.0.0
 */

export function clangResourceDir(): ?string {
    const lib = llvmLibDir();
    if (lib == null) return null;
    const parent = allocCString(`${lib}/clang`);
    const names = os.listDir(parent);
    if (names == null) return null;
    for (const name of names.items) {
        if (name[0] >= '0' && name[0] <= '9') return allocCString(`${parent}/${name}`);
    }
    return null;
}

/**
 * Hashes a file with SHA-256.
 *
 * @param path - The file to hash
 * @returns The hash in lowercase hexadecimal, or `null` when the file cannot be opened
 *
 * @remarks
 * The file goes through a 64 KiB buffer, so an archive of any size hashes in constant memory.
 * {@link sourceTree} compares the result with the expected hash of a download.
 *
 * @since 1.0.0
 */

function fileSha256(path: string): ?string {
    const f = sys.fopen(toCString(path), "rb");
    if (f == null) return null;
    let s: HxSha256 = undefined;
    hxSha256Init(&s);
    let buf: u8[65536] = undefined;
    while (true) {
        const n = sys.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        hxSha256Update(&s, &buf, n);
    }
    void sys.fclose(f);
    let digest: u8[32] = undefined;
    let hex: u8[65] = undefined;
    hxSha256Finish(&s, &digest);
    hxSha256Hex(&digest, &hex);
    return allocCString(`${hex[0..64]}`);
}

/**
 * Gives the unpacked source tree of an archive, which it downloads, checks, and unpacks the first time.
 *
 * @param url - The address of the archive
 * @param sha256 - The pinned SHA-256 of the archive
 * @param folder - The folder that the archive unpacks into
 * @returns The path of `<helix home>/src/<folder>`, or `null` after reporting an error
 *
 * @remarks
 * A `.unpacked` file in the folder marks a tree that is ready.
 * The archive is looked for in `<helix home>/src`, then in the `lib/src` folder of a release,
 * so a release needs no network.
 * Only when neither has the pinned hash does `curl` download the archive.
 * A download with another hash is deleted, and `tar` then unpacks the archive into `<helix home>/src`.
 *
 * @since 1.0.0
 */

function sourceTree(url: string, sha256: string, folder: string): ?string {
    const src = os.helixHome("src");
    const out = allocCString(`${src}/${folder}`);
    const done = allocCString(`${out}/.unpacked`);
    if (os.exists(done)) return out;
    if (!os.makeDirs(src)) return null;

    let file = allocCString(`${src}/${os.baseName(url)}`);
    let hex = fileSha256(file) ?? "";
    if (!equal(hex, sha256)) {   // a release ships the archives (lib/src), so it needs no network
        if (const shipped = os.besideCompiler(allocCString(`lib/src/${os.baseName(url)}`))) {
            if (equal(fileSha256(shipped) ?? "", sha256)) {
                file = shipped;
                hex = sha256;
            }
        }
    }
    if (!equal(hex, sha256)) {
        eprintln(`downloading ${url} (once; it's cached in ${src})`);
        const curl: string[5] = ["curl", "-fsSL", "-o", file, url];
        if (run(&curl) != 0) {
            eprintln(`error: couldn't download ${url}`);
            return null;
        }
        hex = fileSha256(file) ?? "";
        if (!equal(hex, sha256)) {
            eprintln(`error: ${url} doesn't have the expected SHA-256\n  expected ${sha256}\n  found    ${hex}`);
            os.unlink(file);
            return null;
        }
    }
    const tar: string[5] = ["tar", "-xf", file, "-C", src];
    if (run(&tar) != 0 || !os.exists(out)) {
        eprintln(`error: couldn't unpack ${file}`);
        return null;
    }
    void os.writeText(done, "");
    return out;
}

/**
 * Runs compile jobs, several at a time.
 *
 * @param jobs - The jobs to run, which get their `failed` flag set
 * @param required - Whether a failure matters, which reports it and shows the output of clang
 * @returns The number of jobs that failed
 *
 * @remarks
 * It runs one job per CPU, at least 2 and at most 32, since Windows waits on at most 64 processes.
 * Optional jobs, such as the compiler-rt files that do not build for a target, run quietly and fail silently.
 *
 * @since 1.0.0
 */

function runJobs(jobs: Jobs, required: bool): u32 {
    const cpus = os.cpuCount();
    const parallel: usize = cpus > 32 ? 32 : cpus > 1 ? cpus as usize : 2;   // Windows waits on at most 64
    const pids = alloc<i64>(cAllocator(), parallel) catch outOfMemory();
    const which = alloc<usize>(cAllocator(), parallel) catch outOfMemory();
    for (const _, i of pids) pids[i] = 0;
    let next: usize = 0;
    let running: usize = 0;
    let failed: u32 = 0;
    while (next < jobs.items.len || running > 0) {
        while (running < parallel && next < jobs.items.len) {
            let slot: usize = 0;
            while (pids[slot] != 0) slot++;
            // optional files (compiler-rt's) that don't build for a target are skipped silently
            const job = &jobs.items[next];
            if (const child = os.spawn(job.args.items, !required, null)) {
                pids[slot] = child;
                which[slot] = next;
                running++;
            } else {
                job.failed = true;
                failed++;
            }
            next++;
        }
        if (running == 0) break;
        let code: i64 = 0;
        const done = os.waitAny(&code);
        if (done == null) break;
        for (const child, slot of pids) {
            if (child != done) continue;
            pids[slot] = 0;
            running--;
            if (code != 0) {
                failed++;
                if (required) eprintln(`error: compiling ${jobs.items[which[slot]].source} failed`);
                jobs.items[which[slot]].failed = true;
            }
        }
    }
    return failed;
}

/**
 * Adds a compile job, `clang <flags...> -c <source> -o <object>`.
 *
 * @param jobs - The list that gets the job
 * @param clang - The path of clang
 * @param flags - The flags that go before `-c`
 * @param source - The source file
 * @param object - The object file
 *
 * @remarks
 * It only queues the command, and {@link runJobs} runs the queue later.
 *
 * @since 1.0.0
 */

function addCompile(jobs: *Jobs, clang: string, flags: readonly *Strings, source: string, object: string): void {
    let args = strings();
    add(&args, clang);
    for (const flag of flags.items) add(&args, flag);
    add(&args, "-c");
    add(&args, source);
    add(&args, "-o");
    add(&args, object);
    jobs.append(Job { args, source, object, failed: false }) catch outOfMemory();
}

/**
 * Makes a static library with `llvm-ar rcs <archive> <objects...>`.
 *
 * @param path - The library to write, which is deleted first
 * @param objects - The object files, where an empty list makes an empty library
 * @returns `true` when `llvm-ar` succeeded
 *
 * @remarks
 * The objects go through a response file next to the library, so the command line stays short.
 *
 * @since 1.0.0
 */

function archive(path: string, objects: readonly string[]): bool {
    const ar = llvmTool("llvm-ar") ?? "llvm-ar";
    const rsp = allocCString(`${path}.rsp`);
    let list = fmt.Builder.init(cAllocator());
    for (const object of objects) put(&list, `${object}\n`);
    if (!os.writeText(rsp, list.text())) return false;
    os.unlink(path);
    const args: string[4] = [ar, "rcs", path, allocCString(`@${rsp}`)];
    const ok = run(&args) == 0;
    os.unlink(rsp);
    return ok;
}

/**
 * Copies the headers of a folder and its subfolders into another folder.
 *
 * @param from - The folder to copy from
 * @param to - The folder to copy into, which is made when it is missing
 * @returns `false` when a folder cannot be listed or a file cannot be copied
 *
 * @remarks
 * Every file whose name contains `.h` is copied, which also takes the `.h.in` templates.
 * Names that start with `.` are skipped.
 *
 * @since 1.0.0
 */

function copyHeaders(from: string, to: string): bool {
    const names = os.listDir(from);
    if (names == null) return false;
    void os.makeDirs(to);
    for (const name of names.items) {
        if (name[0] == '.') continue;
        const a = allocCString(`${from}/${name}`);
        const b = allocCString(`${to}/${name}`);
        const st = os.stat(a, false);
        if (st == null) continue;
        if (os.isDir(st.mode)) {
            if (!copyHeaders(a, b)) return false;
        } else if (indexOf(name, ".h") != null) {
            if (!os.copyFile(a, b, false)) return false;
        }
    }
    return true;
}

/**
 * Lists the files of a folder with one of some extensions.
 *
 * @param dir - The folder to list
 * @param suffixes - The extensions to keep, such as `.c` and `.s`
 * @returns The sorted names, without hidden files, or an empty list when the folder cannot be listed
 *
 * @remarks
 * The sort makes the order of the objects, and so the archive, the same on every system.
 * A name without a `.` never matches.
 *
 * @since 1.0.0
 */

function listFiles(dir: string, suffixes: readonly string[]): Strings {
    let out = strings();
    const names = os.listDir(dir);
    if (names == null) return out;
    for (const name of names.items) {
        const dot = os.lastIndex(name, '.');
        if (dot == null) continue;
        if (name[0] == '.') continue;
        for (const suffix of suffixes) {
            if (equal(name[dot..], suffix)) {
                add(&out, name);
                break;
            }
        }
    }
    os.sort(out.items);
    return out;
}

/**
 * Removes the extension from a file name.
 *
 * @param name - The file name
 * @returns The name without the part from its last `.`
 *
 * @remarks
 * The name is a view of the original, not a copy.
 * A name without a `.` comes back whole.
 *
 * @since 1.0.0
 */

function stem(name: string): string {
    if (const dot = os.lastIndex(name, '.')) return name[0..dot];
    return name;
}

/**
 * Checks whether a list has a file with the same name apart from the extension.
 *
 * @param names - The file names to look in
 * @param name - The file name to find
 * @returns `true` when some name has the same stem
 *
 * @remarks
 * An arch file such as `x86_64/memcpy.s` replaces the generic `memcpy.c` this way.
 *
 * @since 1.0.0
 */

function stemIn(names: readonly *Strings, name: string): bool {
    for (const other of names.items) {
        if (equal(stem(other), stem(name))) return true;
    }
    return false;
}

/**
 * Makes a relative path a flat object file name.
 *
 * @param rel - The relative path
 * @returns A copy of the path with each `/` made `_`
 *
 * @remarks
 * It keeps the objects of files with the same name in different folders apart in one `obj` folder.
 *
 * @since 1.0.0
 */

function flatten(rel: string): string {
    const flat = allocCString(`${rel}`);
    unsafe {
        const bytes = @ptrCast(u8[*], flat.ptr);
        for (const c, i of flat) {
            if (c == '/') bytes[i] = '_';
        }
    }
    return flat;
}

/**
 * Splits a text into lines.
 *
 * @param text - The text to split
 * @param lines - The list that gets the lines, each with its line feed, and a last line without one
 *
 * @remarks
 * The lines are views of the text, so the text must outlive the list.
 * Each line keeps its line feed, which lets a generator write the lines back unchanged.
 *
 * @since 1.0.0
 */

function eachLine(text: string, lines: *Strings): void {
    let start: usize = 0;
    for (const c, i of text) {
        if (c != '\n') continue;
        add(lines, text[start..i + 1]);
        start = i + 1;
    }
    if (start < text.len) add(lines, text[start..]);
}

/**
 * Writes musl's `bits/alltypes.h` as its `tools/mkalltypes.sed` would.
 *
 * @param musl - The musl source tree
 * @param arch - The musl name of the architecture
 * @param outPath - The header to write
 * @returns `false` when an input cannot be read or the header cannot be written
 *
 * @remarks
 * The inputs are `arch/<arch>/bits/alltypes.h.in` and then the generic `include/alltypes.h.in`.
 * Each `TYPEDEF <type> <name>;` line becomes a typedef guarded by `__NEED_<name>` and `__DEFINED_<name>`.
 * `STRUCT` and `UNION` lines become guarded definitions in the same way, and other lines stay as they are.
 *
 * @since 1.0.0
 */

function writeAlltypes(musl: string, arch: string, outPath: string): bool {
    let out = fmt.Builder.init(cAllocator());
    const inputs: string[2] = [allocCString(`${musl}/arch/${arch}/bits/alltypes.h.in`), allocCString(`${musl}/include/alltypes.h.in`)];
    for (const input of inputs) {
        const text = os.readText(input);
        if (text == null) return false;
        let lines = strings();
        eachLine(text, &lines);
        for (const line of lines.items) {
            const body = endsWith(line, "\n") ? line[0..line.len - 1] : line;
            const len = body.len;
            // TYPEDEF <type> <name>;   STRUCT <name> <body>;   UNION <name> <body>;
            if (startsWith(body, "TYPEDEF ") && len > 9 && body[len - 1] == ';') {
                const decl = body[0..len - 1];
                const space = os.lastIndex(decl, ' ') ?? 0;
                const name = decl[space + 1..];
                const type = decl[8..space];
                put(&out, `#if defined(__NEED_${name}) && !defined(__DEFINED_${name})\ntypedef ${type} ${name};\n#define __DEFINED_${name}\n#endif\n\n`);
            } else if ((startsWith(body, "STRUCT ") || startsWith(body, "UNION ")) && len > 0 && body[len - 1] == ';') {
                const isStruct = body[0] == 'S';
                let p: usize = isStruct ? 7 : 6;
                while (p < len && body[p] == ' ') p++;
                const space = os.firstIndex(body[p..], ' ');
                if (space == null) {
                    put(&out, `${line}`);
                    continue;
                }
                const name = body[p..p + space];
                const rest = body[p + space + 1..len - 1];
                const kind = isStruct ? "struct" : "union";
                put(&out, `#if defined(__NEED_${kind}_${name}) && !defined(__DEFINED_${kind}_${name})\n${kind} ${name} ${rest};\n#define __DEFINED_${kind}_${name}\n#endif\n\n`);
            } else {
                put(&out, `${line}`);
            }
        }
    }
    return os.writeText(outPath, out.text());
}

/**
 * Writes musl's `bits/syscall.h`.
 *
 * @param musl - The musl source tree
 * @param arch - The musl name of the architecture
 * @param outPath - The header to write
 * @returns `false` when the input cannot be read or the header cannot be written
 *
 * @remarks
 * The header is `arch/<arch>/bits/syscall.h.in`, then each line with `__NR_x` again with `SYS_x` in its place.
 *
 * @since 1.0.0
 */

function writeSyscallH(musl: string, arch: string, outPath: string): bool {
    const text = os.readText(allocCString(`${musl}/arch/${arch}/bits/syscall.h.in`));
    if (text == null) return false;
    let out = fmt.Builder.init(cAllocator());
    let renamed = fmt.Builder.init(cAllocator());
    let lines = strings();
    eachLine(text, &lines);
    for (const line of lines.items) {
        put(&out, `${line}`);
        const nr = indexOf(line, "__NR_");
        if (nr == null) continue;
        put(&renamed, `${line[0..nr]}SYS_${line[nr + 5..]}`);
    }
    put(&out, `${renamed.text()}`);
    return os.writeText(outPath, out.text());
}

/**
 * Adds the sources of one musl folder, with arch files in place of the generic files that they replace.
 *
 * @param musl - The musl source tree
 * @param dir - The folder, relative to the tree
 * @param arch - The musl name of the architecture
 * @param out - The list that gets the paths, relative to the tree
 *
 * @remarks
 * The generic files are the `.c` files of the folder.
 * The arch files are the `.c`, `.s`, and `.S` files of its `<arch>` subfolder.
 *
 * @since 1.0.0
 */

function muslSources(musl: string, dir: string, arch: string, out: *Strings): void {
    const generic = listFiles(allocCString(`${musl}/${dir}`), [".c"]);
    const specific = listFiles(allocCString(`${musl}/${dir}/${arch}`), [".c", ".s", ".S"]);
    for (const name of generic.items) {
        if (!stemIn(&specific, name)) add(out, allocCString(`${dir}/${name}`));
    }
    for (const name of specific.items) add(out, allocCString(`${dir}/${arch}/${name}`));
}

/**
 * Checks whether a target has no OS.
 *
 * @param triple - The LLVM target triple
 * @returns `true` for `<arch>-unknown-none-elf` and a Cortex-M `thumb...-none-eabi` or `-none-eabihf`
 *
 * @remarks
 * A target without an OS gets the compiler-rt builtins and no C library.
 *
 * @example
 * ```hx
 * bareMetal("thumbv7em-none-eabihf");      // true
 * bareMetal("x86_64-unknown-linux-musl");  // false
 * ```
 *
 * @see bareMetalFlags
 * @since 1.0.0
 */

export function bareMetal(triple: string): bool {
    return endsWith(triple, "-unknown-none-elf") || indexOf(triple, "-none-eabi") != null;
}

/**
 * Adds the clang flags that C for a target without an OS compiles with.
 *
 * @param flags - The list that gets the flags
 * @param triple - The LLVM target triple
 *
 * @remarks
 * The flags make the C match the freestanding Helix code that it links with:
 *
 * - **riscv64** - `-march=rv64gc`, `-mabi=lp64d`, and `-mcmodel=medany`
 * - **x86_64** - `-mno-red-zone`, since an interrupt handler would overwrite the red zone
 * - **aarch64** - `-mno-outline-atomics`
 * - **thumb** - `-mthumb` and the Cortex-M architecture, with `-mfloat-abi=hard` and the FPU for `-eabihf`,
 *   which passes floats in FPU registers, or `-mfloat-abi=soft` otherwise
 *
 * Any other architecture gets no flags.
 *
 * @example
 * ```hx
 * let flags = strings();
 * bareMetalFlags(&flags, "thumbv6m-none-eabi"); // flags is [ "-mthumb", "-march=armv6-m", "-mfloat-abi=soft" ]
 * ```
 *
 * @see bareMetal
 * @since 1.0.0
 */

export function bareMetalFlags(flags: *Strings, triple: string): void {
    if (startsWith(triple, "riscv64")) {
        add(flags, "-march=rv64gc");
        add(flags, "-mabi=lp64d");
        add(flags, "-mcmodel=medany");
    } else if (startsWith(triple, "x86_64")) {
        add(flags, "-mno-red-zone");   // an interrupt handler would overwrite it
    } else if (startsWith(triple, "aarch64")) {
        add(flags, "-mno-outline-atomics");
    } else if (startsWith(triple, "thumb")) {
        const arch = startsWith(triple, "thumbv6m") ? "armv6-m" : startsWith(triple, "thumbv7em") ? "armv7e-m"
                   : startsWith(triple, "thumbv7m") ? "armv7-m" : "armv8-m.main";
        add(flags, "-mthumb");
        add(flags, allocCString(`-march=${arch}`));
        if (endsWith(triple, "eabihf")) {
            add(flags, "-mfloat-abi=hard");
            add(flags, startsWith(triple, "thumbv8m") ? "-mfpu=fpv5-sp-d16" : "-mfpu=fpv4-sp-d16");
        } else {
            add(flags, "-mfloat-abi=soft");
        }
    }
}

/**
 * Adds the flags that every compile for a target shares.
 *
 * @param flags - The list that gets the flags
 * @param triple - The LLVM target triple
 * @param include - The headers of the C library being built, or `null` for none
 * @param resources - The clang resource folder
 *
 * @remarks
 * The flags give the target, and they put the headers of clang and of this C library in place of the host headers.
 * aarch64 also gets `-mno-outline-atomics`, since there are no libgcc helpers,
 * and a target without an OS gets {@link bareMetalFlags}, as freestanding Helix code is built.
 *
 * @since 1.0.0
 */

function targetFlags(flags: *Strings, triple: string, include: ?string, resources: string): void {
    add(flags, "-target");
    add(flags, triple);
    add(flags, "-nostdinc");
    add(flags, allocCString(`-isystem${resources}/include`));   // clang's own headers: stddef.h, stdarg.h, ...
    if (const dir = include) add(flags, allocCString(`-isystem${dir}`));
    if (startsWith(triple, "aarch64")) add(flags, "-mno-outline-atomics");   // no libgcc helpers
    if (bareMetal(triple)) bareMetalFlags(flags, triple);   // as freestanding Helix code is built
}

/**
 * Copies a list of strings.
 *
 * @param from - The list to copy
 * @returns A new list with the same items
 *
 * @remarks
 * Only the list is new, and the items still share their memory with the original.
 * Use it to extend a set of flags without changing the original, as the crt files do with `-DCRT`.
 *
 * @since 1.0.0
 */

function copyStrings(from: readonly *Strings): Strings {
    let out = strings();
    for (const s of from.items) add(&out, s);
    return out;
}

/**
 * Builds musl into a C library folder.
 *
 * @param musl - The musl source tree
 * @param arch - The musl name of the architecture
 * @param triple - The LLVM target triple
 * @param resources - The clang resource folder
 * @param out - The folder that gets `include/`, `lib/`, and the build files in `obj/`
 * @returns `true` when every step succeeded
 *
 * @remarks
 * Its own build scripts never run.
 * It writes the headers that the musl build makes, `bits/alltypes.h`, `bits/syscall.h`, and `version.h`,
 * and compiles every file with the flags of the musl Makefile and configure script.
 * The files are those of every folder of `src`, of `src/malloc/mallocng`, and of `crt/`,
 * where only `crt1.o`, `crti.o`, and `crtn.o` are built, with `-DCRT`, since a static program needs no others.
 * The objects become `libc.a`, and empty `libm.a`, `librt.a`, `libpthread.a`, and the like let `-lm` link.
 * The headers are `include/`, with the generic and arch `bits` and then the generated ones over it.
 *
 * @since 1.0.0
 */

function buildMusl(musl: string, arch: string, triple: string, resources: string, out: string): bool {
    const obj = allocCString(`${out}/obj`);
    const include = allocCString(`${out}/include`);
    const lib = allocCString(`${out}/lib`);
    const gen = allocCString(`${out}/obj/include/bits`);
    if (!os.makeDirs(gen) || !os.makeDirs(lib) || !os.makeDirs(include)) return false;

    // generated headers: bits/alltypes.h, bits/syscall.h, and src/internal/version.h
    if (!writeAlltypes(musl, arch, allocCString(`${gen}/alltypes.h`))) return false;
    if (!writeSyscallH(musl, arch, allocCString(`${gen}/syscall.h`))) return false;
    void os.makeDirs(allocCString(`${out}/obj/src/internal`));
    if (!os.writeText(allocCString(`${out}/obj/src/internal/version.h`), allocCString(`#define VERSION "${MuslVersion}"\n`))) return false;

    // the flags of musl's Makefile and configure, for clang
    let flags = strings();
    targetFlags(&flags, triple, null, resources);
    const fixed: string[15] = [
        "-std=c99", "-ffreestanding", "-fexcess-precision=standard", "-frounding-math", "-fno-strict-aliasing",
        "-Wa,--noexecstack", "-D_XOPEN_SOURCE=700", "-O2", "-fomit-frame-pointer", "-fno-unwind-tables",
        "-fno-asynchronous-unwind-tables", "-ffunction-sections", "-fdata-sections", "-fno-stack-protector", "-w",
    ];
    for (const flag of fixed) add(&flags, flag);
    add(&flags, allocCString(`-I${musl}/arch/${arch}`));
    add(&flags, allocCString(`-I${musl}/arch/generic`));
    add(&flags, allocCString(`-I${out}/obj/src/internal`));
    add(&flags, allocCString(`-I${musl}/src/include`));
    add(&flags, allocCString(`-I${musl}/src/internal`));
    add(&flags, allocCString(`-I${out}/obj/include`));
    add(&flags, allocCString(`-I${musl}/include`));

    // every source: src/*, src/malloc/mallocng, and crt/
    let sources = strings();
    const dirs = os.listDir(allocCString(`${musl}/src`)) ?? strings();
    for (const dir of dirs.items) {
        if (dir[0] != '.') muslSources(musl, allocCString(`src/${dir}`), arch, &sources);
    }
    muslSources(musl, "src/malloc/mallocng", arch, &sources);
    const libcCount = sources.items.len;
    muslSources(musl, "crt", arch, &sources);

    const clang = llvmTool("clang") ?? "clang";
    let crtFlags = copyStrings(&flags);   // crt files are built with -DCRT
    add(&crtFlags, "-DCRT");
    let jobs = ArrayList<Job>.init(cAllocator());
    let objects = strings();
    for (const rel, i of sources.items) {
        const crt = i >= libcCount;
        if (crt && (indexOf(rel, "rcrt1") != null || indexOf(rel, "Scrt1") != null)) continue;   // static programs need only crt1, crti, crtn
        const source = allocCString(`${musl}/${rel}`);
        if (crt) {
            addCompile(&jobs, clang, &crtFlags, source, allocCString(`${lib}/${stem(os.baseName(rel))}.o`));
        } else {
            const object = allocCString(`${obj}/${flatten(rel)}.o`);
            add(&objects, object);
            addCompile(&jobs, clang, &flags, source, object);
        }
    }
    eprintln(`building musl ${MuslVersion} for ${triple} (${jobs.items.len} files, once)`);
    let ok = runJobs(jobs, true) == 0;

    if (ok) ok = archive(allocCString(`${lib}/libc.a`), objects.items);
    // musl's empty libraries, so `-lm` and `-lpthread` link: everything is in libc.a
    const empty: string[8] = ["m", "rt", "pthread", "crypt", "util", "xnet", "resolv", "dl"];
    for (const name of empty) {
        if (ok) ok = archive(allocCString(`${lib}/lib${name}.a`), None);
    }
    // headers: include/, then arch/generic/bits and arch/<arch>/bits over it, then the generated ones
    const bits = allocCString(`${include}/bits`);
    ok = ok && copyHeaders(allocCString(`${musl}/include`), include);
    ok = ok && copyHeaders(allocCString(`${musl}/arch/generic/bits`), bits);
    ok = ok && copyHeaders(allocCString(`${musl}/arch/${arch}/bits`), bits);
    ok = ok && copyHeaders(gen, bits);
    return ok;
}

/**
 * Adds the sources of a folder and its subfolders.
 *
 * @param root - The source tree
 * @param rel - The folder, relative to the tree
 * @param asmToo - Whether `.s` files count as well as `.c` files
 * @param out - The list that gets the paths, relative to the tree
 *
 * @remarks
 * Hidden files and folders are skipped.
 * The sorted files of a folder come before those of its subfolders,
 * which follow in the order that the system lists them.
 *
 * @since 1.0.0
 */

function listTree(root: string, rel: string, asmToo: bool, out: *Strings): void {
    const dir = allocCString(`${root}/${rel}`);
    const files = listFiles(dir, asmToo ? &CAndAsm : &COnly);
    for (const name of files.items) add(out, allocCString(`${rel}/${name}`));
    let subdirs = strings();
    if (const names = os.listDir(dir)) {
        for (const name of names.items) {
            if (name[0] == '.') continue;
            if (os.isDirectory(allocCString(`${dir}/${name}`))) add(&subdirs, name);
        }
    }
    for (const sub of subdirs.items) listTree(root, allocCString(`${rel}/${sub}`), asmToo, out);
}

/**
 * Checks whether a list has a string.
 *
 * @param list - The list to look in
 * @param word - The string to find
 * @returns `true` when the list has an equal string
 *
 * @remarks
 * It compares whole strings, so it fits file names and omit lists.
 *
 * @since 1.0.0
 */

function hasWord(list: readonly string[], word: string): bool {
    for (const item of list) {
        if (equal(item, word)) return true;
    }
    return false;
}

/**
 * Adds the `.c` files of a folder of musl's `src` in wasi-libc, without its arch subfolders.
 *
 * @param wasi - The wasi-libc source tree
 * @param dir - The folder under `libc-top-half/musl/src`
 * @param omit - The file names to leave out
 * @param out - The list that gets the paths, relative to the tree
 *
 * @remarks
 * It lists only the folder itself, so the arch subfolders of musl, which do not apply to WASI, stay out.
 *
 * @since 1.0.0
 */

function muslDir(wasi: string, dir: string, omit: readonly string[], out: *Strings): void {
    const files = listFiles(allocCString(`${wasi}/libc-top-half/musl/src/${dir}`), [".c"]);
    for (const name of files.items) {
        if (!hasWord(omit, name)) add(out, allocCString(`libc-top-half/musl/src/${dir}/${name}`));
    }
}

/**
 * Makes the flags of one part of wasi-libc.
 *
 * @param base - The flags that every file shares
 * @param wasi - The wasi-libc source tree
 * @param dirs - The include folders of the part, relative to the tree
 * @param extra - The other flags of the part
 * @returns The base flags, then `-I<wasi>/<dir>` for each folder, then the extra flags
 *
 * @remarks
 * Each part of wasi-libc compiles with its own include folders,
 * so the parts start from a copy of the base flags and never change the base list itself.
 *
 * @since 1.0.0
 */

function wasiFlags(base: readonly *Strings, wasi: string, dirs: readonly string[], extra: readonly string[]): Strings {
    let flags = copyStrings(base);
    for (const dir of dirs) add(&flags, allocCString(`-I${wasi}/${dir}`));
    for (const flag of extra) add(&flags, flag);
    return flags;
}

/**
 * Builds wasi-libc into a C library folder.
 *
 * @param wasi - The wasi-libc source tree
 * @param triple - The LLVM target triple
 * @param resources - The clang resource folder
 * @param out - The folder that gets `include/`, `lib/`, and the build files in `obj/`
 * @returns `true` when every step succeeded
 *
 * @remarks
 * wasi-libc is the upper half of musl over a lower half that calls WASI.
 * The file lists of its Makefile for a single-threaded wasip1 `libc.a` are reproduced here, and its scripts never run.
 *
 * - **Headers** - laid out as `scripts/install-include-headers.sh` does, without {@link WasiOmitHeaders}
 * - **Lower half** - cloudlibc and `sources/`, without the files only for WASIp2, and with `chdir.c` last
 * - **Upper half** - {@link WasiPicked}, the musl folders without their omitted files,
 *   `thread-stub`, and the wasi-libc `sources/` with assembly
 * - **Others** - dlmalloc and fts, each with its own include folders
 *
 * Every part gets its own flags, and the printing and bulk memory files get theirs.
 * The start files `crt1.o`, `crt1-command.o` for a program with `main`, and `crt1-reactor.o` for a library
 * go into `lib/`, with `libc.a` and empty `libm.a`, `libpthread.a`, and the like.
 *
 * @since 1.0.0
 */

function buildWasi(wasi: string, triple: string, resources: string, out: string): bool {
    const obj = allocCString(`${out}/obj`);
    const include = allocCString(`${out}/include`);
    const lib = allocCString(`${out}/lib`);
    if (!os.makeDirs(obj) || !os.makeDirs(lib) || !os.makeDirs(include)) return false;

    // headers, as scripts/install-include-headers.sh lays them out
    const musl = allocCString(`${wasi}/libc-top-half/musl`);
    const bits = allocCString(`${include}/bits`);
    let ok = copyHeaders(allocCString(`${wasi}/libc-bottom-half/headers/public`), include);
    ok = ok && copyHeaders(allocCString(`${musl}/include`), include);
    ok = ok && copyHeaders(allocCString(`${musl}/arch/generic/bits`), bits);
    ok = ok && copyHeaders(allocCString(`${musl}/arch/wasm32/bits`), bits);
    ok = ok && writeAlltypes(musl, "wasm32", allocCString(`${include}/bits/alltypes.h`));
    ok = ok && os.copyFile(allocCString(`${wasi}/fts/musl-fts/fts.h`), allocCString(`${include}/fts.h`), false);
    if (!ok) return false;
    for (const header of WasiOmitHeaders) os.unlink(allocCString(`${include}/${header}`));

    // the flags of the Makefile: every file, then each part's own
    let base = strings();
    targetFlags(&base, triple, include, resources);
    const common: string[7] = [
        "-O2", "-DNDEBUG", "-fno-trapping-math", "-mthread-model", "single", "-w",
        allocCString(`-I${wasi}/libc-bottom-half/cloudlibc/src`),
    ];
    for (const flag of common) add(&base, flag);
    const bottom = wasiFlags(&base, wasi, &BottomDirs, None);
    const top = wasiFlags(&base, wasi, &TopDirs, None);
    const topPrintscan = wasiFlags(&top, wasi, None, &Printscan);
    const topBulk = wasiFlags(&top, wasi, None, &Bulk);
    const mallocFlags = wasiFlags(&base, wasi, &MallocDirs, None);
    const fts = wasiFlags(&base, wasi, &FtsDirs, None);

    // the lower half: cloudlibc and sources/, without what's only for WASIp2 (chdir.c goes last, as in the Makefile)
    let lower = strings();
    listTree(wasi, "libc-bottom-half/cloudlibc/src", false, &lower);
    listTree(wasi, "libc-bottom-half/sources", false, &lower);
    const p2Only: string[16] = [
        "wasip2.c", "descriptor_table.c", "connect.c", "socket.c", "send.c", "recv.c", "sockets_utils.c", "bind.c",
        "listen.c", "accept-wasip2.c", "shutdown.c", "sockopt.c", "poll-wasip2.c", "getsockpeername.c", "netdb.c",
        "chdir.c",
    ];
    let bottomSources = strings();
    for (const rel of lower.items) {
        if (startsWith(rel, "libc-bottom-half/sources/") && hasWord(&p2Only, os.baseName(rel))) continue;
        add(&bottomSources, rel);
    }
    add(&bottomSources, "libc-bottom-half/sources/chdir.c");

    // the upper half: musl's portable parts, and wasi-libc's own sources/
    let topSources = strings();
    for (const picked of WasiPicked) add(&topSources, allocCString(`libc-top-half/musl/src/${picked}`));
    muslDir(wasi, "internal", &OmitInternal, &topSources);
    muslDir(wasi, "stdio", &OmitStdio, &topSources);
    muslDir(wasi, "string", &OmitString, &topSources);
    muslDir(wasi, "locale", &OmitLocale, &topSources);
    const whole: string[8] = ["stdlib", "search", "multibyte", "regex", "prng", "conf", "ctype", "crypt"];
    for (const dir of whole) muslDir(wasi, dir, None, &topSources);
    muslDir(wasi, "math", &OmitMath, &topSources);
    muslDir(wasi, "complex", &OmitComplex, &topSources);
    listTree(wasi, "thread-stub", false, &topSources);
    listTree(wasi, "libc-top-half/sources", true, &topSources);

    const clang = llvmTool("clang") ?? "clang";
    let jobs = ArrayList<Job>.init(cAllocator());
    let objects = strings();
    for (const part of 0..4) {
        let single = strings();
        if (part == 2) add(&single, "dlmalloc/src/dlmalloc.c");
        if (part == 3) add(&single, "fts/musl-fts/fts.c");
        const sources = part == 0 ? &bottomSources : part == 1 ? &topSources : &single;
        for (const rel of sources.items) {
            let flags = part == 0 ? &bottom : part == 2 ? &mallocFlags : part == 3 ? &fts : &top;
            if (part == 1 && (endsWith(rel, "/stdio/vfprintf.c") || endsWith(rel, "/stdio/vfwprintf.c")
                    || endsWith(rel, "/stdio/vfscanf.c") || endsWith(rel, "/stdlib/strtod.c")
                    || endsWith(rel, "/stdlib/wcstod.c") || endsWith(rel, "/internal/floatscan.c"))) {
                flags = &topPrintscan;
            }
            if (part == 1 && (endsWith(rel, "/string/memcpy.c") || endsWith(rel, "/string/memmove.c")
                    || endsWith(rel, "/string/memset.c"))) {
                flags = &topBulk;
            }
            const object = allocCString(`${obj}/${flatten(rel)}.o`);
            add(&objects, object);
            addCompile(&jobs, clang, flags, allocCString(`${wasi}/${rel}`), object);
        }
    }
    // the start files: crt1-command.o (a program with `main`) and crt1-reactor.o (a library)
    const crt: string[3] = ["crt1", "crt1-command", "crt1-reactor"];
    for (const name of crt) {
        addCompile(&jobs, clang, &bottom, allocCString(`${wasi}/libc-bottom-half/crt/${name}.c`), allocCString(`${lib}/${name}.o`));
    }
    eprintln(`building wasi-libc ${WasiLibcVersion} for ${triple} (${jobs.items.len} files, once)`);
    ok = runJobs(jobs, true) == 0;
    if (ok) ok = archive(allocCString(`${lib}/libc.a`), objects.items);
    const empty: string[7] = ["m", "rt", "pthread", "crypt", "util", "xnet", "resolv"];
    for (const name of empty) {
        if (ok) ok = archive(allocCString(`${lib}/lib${name}.a`), None);
    }
    return ok;
}

/**
 * Builds the compiler-rt builtins into `lib/libcompiler_rt.a`.
 *
 * @param crt - The compiler-rt source tree
 * @param arch - The compiler-rt name of the architecture, such as `arm` for a Cortex-M
 * @param triple - The LLVM target triple
 * @param resources - The clang resource folder
 * @param out - The C library folder, whose `include/` is used when it exists
 * @returns `true` when more than 50 files built and the library was made
 *
 * @remarks
 * It compiles the generic `.c` files, with the `.c` and `.S` files of the arch folder in place of those they replace.
 * Files that need an OS or another platform are left out, such as emulated TLS, Darwin files, and outline atomics,
 * and so are the Windows stack probes unless the target is Windows.
 * A file that does not apply to the target simply does not build.
 * An arch file that does not build falls back to its generic C file,
 * as on a Cortex-M0, whose Thumb-1 lacks `clz`.
 *
 * @since 1.0.0
 */

function buildBuiltins(crt: string, arch: string, triple: string, resources: string, out: string): bool {
    const builtins = allocCString(`${crt}/lib/builtins`);
    const obj = allocCString(`${out}/obj/builtins`);
    const include = allocCString(`${out}/include`);
    if (!os.makeDirs(obj)) return false;

    let flags = strings();
    targetFlags(&flags, triple, os.exists(include) ? include : null, resources);   // Windows: clang's headers only
    const fixed: string[8] = [
        "-O2", "-std=c11", "-fno-builtin", "-ffreestanding", "-fvisibility=hidden", "-fomit-frame-pointer",
        "-fno-stack-protector", "-w",
    ];
    for (const flag of fixed) add(&flags, flag);

    // the generic files, with the arch's in place of those they replace; files that need an OS or another
    // platform (emulated TLS, Darwin, outline atomics) are left out, and Windows' stack probes unless it's Windows
    const windows = indexOf(triple, "-windows-") != null;
    const skip: string[10] = [
        "emutls.c", "enable_execute_stack.c", "gcc_personality_v0.c", "os_version_check.c", "trampoline_setup.c",
        "atomic.c", "clear_cache.c", "lse.S", "chkstk.S", "chkstk2.S",
    ];
    const skipped = windows ? skip[0..8] : skip[0..10];
    const archDir = allocCString(`${builtins}/${arch}`);
    const generic = listFiles(builtins, [".c"]);
    const specific = listFiles(archDir, [".c", ".S"]);
    let jobs = ArrayList<Job>.init(cAllocator());
    const clang = llvmTool("clang") ?? "clang";
    for (const pass of 0..2) {
        const names = pass == 1 ? &specific : &generic;
        for (const name of names.items) {
            let skipIt = false;
            for (const s of skipped) {
                if (equal(name, s)) skipIt = true;
            }
            if (skipIt || (pass == 0 && stemIn(&specific, name))) continue;
            const source = allocCString(`${pass == 1 ? archDir : builtins}/${name}`);
            const object = allocCString(`${obj}/${pass == 1 ? "arch_" : ""}${name}.o`);
            addCompile(&jobs, clang, &flags, source, object);
        }
    }
    eprintln(`building compiler-rt builtins for ${triple} (${jobs.items.len} files, once)`);
    void runJobs(jobs, false);   // a file that doesn't apply to this target simply doesn't build
    // an arch file that didn't build (Cortex-M0's Thumb-1 lacks `clz`, say) falls back to the generic C one
    let fallbacks = ArrayList<Job>.init(cAllocator());
    for (const job of jobs.items) {
        if (!job.failed || indexOf(job.source, archDir) == null) continue;
        const name = os.baseName(job.source);
        for (const g of generic.items) {
            if (!equal(stem(g), stem(name))) continue;
            addCompile(&fallbacks, clang, &flags, allocCString(`${builtins}/${g}`), allocCString(`${obj}/${g}.o`));
        }
    }
    if (fallbacks.items.len > 0) void runJobs(fallbacks, false);
    let objects = strings();
    for (const job of jobs.items) {
        if (!job.failed) add(&objects, job.object);
    }
    for (const job of fallbacks.items) {
        if (!job.failed) add(&objects, job.object);
    }
    const ok = objects.items.len > 50 && archive(allocCString(`${out}/lib/libcompiler_rt.a`), objects.items);
    if (!ok) eprintln(`error: compiler-rt's builtins didn't build for ${triple}`);
    return ok;
}

/**
 * Builds the libraries of a Windows target.
 *
 * @param crt - The compiler-rt source tree
 * @param rtDir - The runtime source folder, whose `windows/` has the `.def` files
 * @param arch - The architecture, `x86_64` or `aarch64`
 * @param triple - The LLVM target triple
 * @param resources - The clang resource folder
 * @param out - The C library folder
 * @returns `true` when both steps succeeded
 *
 * @remarks
 * Windows programs import msvcrt.dll and kernel32.dll, which every Windows has,
 * so `lib/` gets their import libraries and the compiler-rt builtins, which have the stack probe `___chkstk_ms`.
 * There is no `include/` yet.
 *
 * @since 1.0.0
 */

function buildWindows(crt: string, rtDir: string, arch: string, triple: string, resources: string, out: string): bool {
    return buildImports(rtDir, arch, out, false) && buildBuiltins(crt, arch, triple, resources, out);
}

/**
 * Makes the import libraries for msvcrt.dll and kernel32.dll with `llvm-dlltool`.
 *
 * @param rtDir - The runtime source folder, whose `windows/` has the `.def` files
 * @param arch - The architecture, where `x86_64` makes x86-64 libraries and any other makes arm64 ones
 * @param out - The C library folder, whose `lib/` gets `libmsvcrt.a` and `libkernel32.a`
 * @param onlyStale - Whether to make only the libraries older than their `.def` file
 * @returns `false` after reporting a library that `llvm-dlltool` could not make
 *
 * @remarks
 * A `.def` file gains a function now and then, so a cached library folder is refreshed with `onlyStale`.
 *
 * @since 1.0.0
 */

function buildImports(rtDir: string, arch: string, out: string, onlyStale: bool): bool {
    const lib = allocCString(`${out}/lib`);
    if (!os.makeDirs(lib)) return false;
    const dlltool = llvmTool("llvm-dlltool") ?? "llvm-dlltool";
    const dlls: string[2] = ["msvcrt", "kernel32"];
    for (const dll of dlls) {
        const def = allocCString(`${rtDir}/windows/${dll}.def`);
        const a = allocCString(`${lib}/lib${dll}.a`);
        if (onlyStale) {
            if (const built = os.stat(a, false)) {
                if (const source = os.stat(def, false)) {
                    if (built.mtime >= source.mtime) continue;
                }
            }
        }
        const args: string[7] = [dlltool, "-m", equal(arch, "x86_64") ? "i386:x86-64" : "arm64", "-d", def, "-l", a];
        if (run(&args) != 0) {
            eprintln(`error: llvm-dlltool couldn't make ${a} from ${def}`);
            return false;
        }
    }
    return true;
}

/**
 * Gives the C library folder of a target, which it builds the first time.
 *
 * @param triple - The LLVM target triple
 * @param rtDir - The runtime source folder next to the compiler, where the Windows `.def` files are
 * @returns The folder with `include/` and `lib/`, or `null` after reporting an error
 *
 * @remarks
 * It provides the C library for targets that the machine does not have one for:
 *
 * - **Linux with `-musl`** - musl and the compiler-rt builtins, for x86_64, aarch64, and riscv64
 * - **Windows with `-windows-gnu`** - import libraries for msvcrt.dll and kernel32.dll, and the builtins
 * - **`wasm32-unknown-wasip1`** - wasi-libc and the builtins
 * - **No OS** - the builtins only, with no C library
 *
 * A release ships the C library of the machine that it runs on in `lib/libc/<triple>`.
 * Any other one is built once into `<helix home>/libc/<triple>`, which a `.built` file marks as ready,
 * with the sources downloaded once into `<helix home>/src` and checked against their pinned SHA-256.
 * The build goes to `<triple>.partial`, and only a finished build takes the place of the old folder.
 * Another target, such as `-linux-gnu`, is refused with a hint to use `-musl`.
 *
 * @example
 * ```hx
 * libcEnsure("x86_64-unknown-linux-musl", rtDir); // "~/.cache/helix/libc/x86_64-unknown-linux-musl"
 * libcEnsure("x86_64-unknown-linux-gnu", rtDir);  // null, with a hint to use the -musl target
 * ```
 *
 * @since 1.0.0
 */

export function libcEnsure(triple: string, rtDir: string): ?string {
    const arch = triple[0..os.firstIndex(triple, '-') ?? triple.len];
    const musl = indexOf(triple, "-linux-musl") != null;
    const windows = indexOf(triple, "-windows-gnu") != null;
    const wasi = equal(triple, "wasm32-unknown-wasip1");
    const bare = bareMetal(triple);   // no OS: compiler-rt's builtins, no C library
    const knownArch = equal(arch, "x86_64") || equal(arch, "aarch64") || ((musl || bare) && equal(arch, "riscv64")) || wasi ||
                      (bare && startsWith(arch, "thumb"));
    if ((!musl && !windows && !wasi && !bare) || !knownArch) {
        eprintln(`error: Helix can't provide a C library for ${triple} yet`);
        if (indexOf(triple, "-linux-gnu") != null) {
            eprintln("  = hint: use the `-musl` target instead: a static program that runs on any Linux");
        }
        return null;
    }
    // a release ships the C library of the machine it runs on (lib/libc/<triple>); others are built once
    if (const shipped = os.besideCompiler(allocCString(`lib/libc/${triple}/.built`))) return shipped[0..shipped.len - 7];
    const out = allocCString(`${os.helixHome("libc")}/${triple}`);
    const done = allocCString(`${out}/.built`);
    if (os.exists(done)) {
        if (windows && !buildImports(rtDir, arch, out, true)) return null;
        return out;
    }

    const resources = clangResourceDir();
    if (resources == null) {
        eprintln("error: can't find clang's resource folder next to libclang");
        return null;
    }
    let muslTree = "";
    let wasiTree = "";
    if (musl) {
        const tree = sourceTree(MuslUrl, MuslSha256, allocCString(`musl-${MuslVersion}`));
        if (tree == null) return null;
        muslTree = tree;
    }
    if (wasi) {
        const tree = sourceTree(WasiLibcUrl, WasiLibcSha256, allocCString(`wasi-libc-${WasiLibcVersion}`));
        if (tree == null) return null;
        wasiTree = tree;
    }
    const crtTree = sourceTree(CrtUrl, CrtSha256, CrtName);
    if (crtTree == null) return null;
    const building = allocCString(`${out}.partial`);
    os.removeTree(building);
    let ok = false;
    if (windows) ok = buildWindows(crtTree, rtDir, arch, triple, resources, building);
    else if (bare) {   // a Cortex-M's builtins are compiler-rt's `arm` ones, built for Thumb
        const crtArch = startsWith(arch, "thumb") ? "arm" : arch;
        ok = os.makeDirs(allocCString(`${building}/lib`)) && buildBuiltins(crtTree, crtArch, triple, resources, building);
    }
    else if (wasi) ok = buildWasi(wasiTree, triple, resources, building) && buildBuiltins(crtTree, arch, triple, resources, building);
    else ok = buildMusl(muslTree, arch, triple, resources, building) && buildBuiltins(crtTree, arch, triple, resources, building);
    if (ok) {
        os.removeTree(allocCString(`${building}/obj`));
        os.removeTree(out);
        ok = os.rename(building, out);
        if (ok) void os.writeText(done, "");
    }
    if (!ok) {
        eprintln(`error: couldn't build the C library for ${triple}`);
        return null;
    }
    return out;
}
