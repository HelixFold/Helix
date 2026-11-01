/**
 * Imports
 */

import { ArrayList } from "std/list";
import { cAllocator } from "std/heap";
import { HxModule } from "@structs/sema.struct";
import { hxJsonFree } from "@components/json.component";
import { DiagError } from "@constants/diagnostic.constant";
import { NodeKind, NoToken } from "@constants/ast.constant";
import * as os from "@modules/driver/components/os.component";
import { hxParseModule } from "@modules/parser/parser.module";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { JsonArray, JsonBool } from "@constants/json.constant";
import { HxImportData } from "@models/structs/ast-model.struct";
import { equal, startsWith, endsWith, indexOf } from "std/text";
import { hxDiagRender } from "@components/diagnostic.component";
import { hxCodegenObject } from "@modules/codegen/codegen.module";
import { HxSha256 } from "@services/structs/sha256-service.struct";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { ModeDebug } from "@modules/codegen/constants/base.constant";
import { itemAt } from "@modules/driver/components/manifest.component";
import { emitf, hintf, hxDiagListFree } from "@models/diagnostic.model";
import { hxLexAppend, hxTokensFree } from "@modules/lexer/lexer.module";
import { hxZalloc, hxFatalMessage } from "@components/memory.component";
import { LayoutVersion } from "@modules/driver/constants/compile.constant";
import { HxSource, HxSourceFile } from "@models/structs/source-model.struct";
import { node, extraAt, record, hxAstInit, hxAstFree } from "@models/ast.model";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { files, addText, hxSourceAddFile, hxSourceFree } from "@models/source.model";
import { Manifest } from "@modules/driver/components/structs/manifest-component.struct";
import { HxCodegenOptions } from "@modules/codegen/components/structs/base-component.struct";
import { hxSha256Init, hxSha256Update, hxSha256Finish, hxSha256Hex } from "@services/sha256.service";
import { macosSdk, macosVersion, linkedLlvmLibDir } from "@modules/driver/components/libc.component";
import { llvmTool, findTool, lldLibDir, libcEnsure } from "@modules/driver/components/libc.component";
import { clangResourceDir, bareMetalFlags, appleLinker } from "@modules/driver/components/libc.component";
import { allocCString, toCString, fromCString, add, strings } from "@modules/driver/components/os.component";
import { Target, PackageArg, KnownPackage } from "@modules/driver/components/structs/compile-component.struct";
import { Compilation, ImportTarget, Chip, Options } from "@modules/driver/components/structs/compile-component.struct";
import { text as jsonText, loadManifest, contains, parse, member } from "@modules/driver/components/manifest.component";

/**
 * The C library function that releases what the compilation and the code generator allocate.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;

/**
 * The function of lld.c that links with the lld inside the compiler.
 *
 * @remarks
 * `argv[0]` picks the linker, as the name of an lld program does, and the result is lld's exit code.
 *
 * @since 1.0.0
 */

extern "C" function hx_lld_link(argv: (?u8[*])[*], count: usize): i32;

/**
 * Creates the options of a command line that sets nothing.
 *
 * @returns The options in debug mode for this machine, with no file and an empty link list
 *
 * @remarks
 * Every command starts from these options and lets {@link parseCompileOption} and the manifest change them.
 * The link list is new on each call, so two option sets never share it.
 *
 * @example
 * ```hx
 * const options = defaultOptions();
 * options.mode;   // 0, the debug mode
 * options.target; // null, this machine
 * ```
 *
 * @since 1.0.0
 */

export function defaultOptions(): Options {
    return Options {
        file: "", output: null, mode: ModeDebug, runArgs: [], test: false, target: null, cpu: null, strip: false,
        emitObject: false, links: strings(), linkerScript: null, flash: null, ram: null, chip: null,
    };
}

/**
 * Reads one of the options that every compiling command takes.
 *
 * @param args - The command line arguments
 * @param i - The index of the argument to read, which moves past a value that the option takes
 * @param options - The options that get the value
 * @returns 1 when the argument was such an option, 0 when it was not, and -1 after reporting an error
 *
 * @remarks
 * The options are `--target`, `--cpu`, `--strip`, `--emit obj`, `--pkg`, `--pkg-in`, `--link`, `-l<name>`,
 * `--linker-script`, `--flash`, `--ram`, and `--chip`.
 * An option that needs a value it does not get counts as not one of them, so the caller reports it.
 * `--emit` with a value other than `obj`, a `--pkg` without `name=path`,
 * and a `--flash` or `--ram` without a `:` are errors.
 *
 * @example
 * ```hx
 * let i: usize = 0;
 * parseCompileOption(["--target", "x86_64-linux"], &i, &options); // 1, with i at 1
 * parseCompileOption(["--emit", "asm"], &i, &options);            // -1, error: --emit takes `obj`
 * parseCompileOption(["-o", "out"], &i, &options);                // 0
 * ```
 *
 * @since 1.0.0
 */

export function parseCompileOption(args: readonly string[], i: *usize, options: *Options): i32 {
    const arg = args[*i];
    const hasValue = *i + 1 < args.len;
    if (equal(arg, "--target") && hasValue) {
        *i += 1;
        options.target = args[*i];
    } else if (equal(arg, "--cpu") && hasValue) {
        *i += 1;
        options.cpu = args[*i];
    } else if (equal(arg, "--strip")) {
        options.strip = true;
    } else if (equal(arg, "--emit") && hasValue) {
        *i += 1;
        if (!equal(args[*i], "obj")) {
            eprintln("error: --emit takes `obj`");
            return -1;
        }
        options.emitObject = true;
    } else if (equal(arg, "--pkg") && hasValue) {
        *i += 1;
        if (!addPackageArg(null, args[*i])) return -1;
    } else if (equal(arg, "--pkg-in") && *i + 2 < args.len) {
        *i += 2;
        if (!addPackageArg(args[*i - 1], args[*i])) return -1;
    } else if (equal(arg, "--link") && hasValue) {
        *i += 1;
        add(&options.links, args[*i]);
    } else if (startsWith(arg, "-l") && arg.len > 2) {
        add(&options.links, arg);
    } else if (equal(arg, "--linker-script") && hasValue) {
        *i += 1;
        options.linkerScript = args[*i];
    } else if (equal(arg, "--chip") && hasValue) {
        *i += 1;
        options.chip = args[*i];
    } else if ((equal(arg, "--flash") || equal(arg, "--ram")) && hasValue) {
        *i += 1;
        if (os.firstIndex(args[*i], ':') == null) {
            eprintln(`error: ${arg} takes <origin>:<size>, like 0x08000000:512K`);
            return -1;
        }
        if (equal(arg, "--flash")) options.flash = args[*i];
        else options.ram = args[*i];
    } else {
        return 0;
    }
    return 1;
}

/**
 * Turns a target such as `aarch64-macos` or `x86_64-linux-gnu` into an LLVM triple.
 *
 * @param text - The target as `arch-os[-abi]`, `native`, or `null` for this machine
 * @returns The target, or `null` after reporting one that Helix cannot compile for
 *
 * @remarks
 * This machine is the host target on a Mac.
 * On Linux and Windows it builds as for any other machine of that system, as a static musl or a MinGW program.
 * `arm64` means `aarch64`, and the systems give these triples:
 * - **macos** - `<arch>-apple-macosx11.0`, with `arm64` for `aarch64`, which runs on any Mac with that CPU
 * - **linux** - `<arch>-unknown-linux-<abi>`, with `musl` when the ABI is left out
 * - **windows** - `<arch>-w64-windows-<abi>`, with `gnu` when the ABI is left out
 * - **wasi** - `wasm32-unknown-wasip1`
 * - **freestanding** - `<arch>-unknown-none-elf`, or `<arch>-none-eabi` and `-eabihf` for Cortex-M
 *
 * The architectures are x86_64, aarch64, arm64e (macOS only), riscv64 (Linux or freestanding),
 * wasm32 (WASI or freestanding), and the Cortex-M ones, which are freestanding only:
 * thumbv6m (M0, M0+), thumbv7m (M3), thumbv7em (M4, M7), and thumbv8m.main (M33).
 * The `eabihf` ABI passes floats in FPU registers, so thumbv6m and thumbv7m, which have no FPU, reject it.
 *
 * @example
 * ```hx
 * parseTarget("aarch64-macos").triple;            // "arm64-apple-macosx11.0"
 * parseTarget("x86_64-windows").triple;           // "x86_64-w64-windows-gnu"
 * parseTarget("thumbv7em-freestanding").triple;   // "thumbv7em-none-eabi"
 * parseTarget("sparc-linux");                     // null, error: unknown target 'sparc-linux'
 * ```
 *
 * @since 1.0.0
 */

export function parseTarget(text: ?string): ?Target {
    const hostMessage = llvm.LLVMGetDefaultTargetTriple();
    const host = allocCString(`${fromCString(os.asReadonly(hostMessage))}`);
    llvm.LLVMDisposeMessage(hostMessage);
    const hostApple = indexOf(host, "apple") != null;
    let hostArch = host[0..os.firstIndex(host, '-') ?? host.len];
    if (equal(hostArch, "arm64")) hostArch = "aarch64";
    let t = Target { triple: host, host: false, apple: false, musl: false, windows: false, wasi: false, freestanding: false, pointerBytes: 8 };
    let native = true;   // `native`: this machine, said explicitly
    if (const given = text) native = equal(given, "native");
    if (native && !hostApple) {   // Linux and Windows build as they do for any machine: static musl, mingw
        return parseTarget(allocCString(`${hostArch}-${indexOf(host, "windows") != null ? "windows" : "linux"}`));
    }
    if (native) {
        t.host = true;
        t.apple = hostApple;
        return t;
    }
    let spec = "";
    if (const given = text) spec = given;

    let arch = "";
    let system = "";
    let abi = "";
    if (const first = os.firstIndex(spec, '-')) {
        arch = spec[0..first];
        const rest = spec[first + 1..];
        if (const second = os.firstIndex(rest, '-')) {
            system = rest[0..second];
            abi = rest[second + 1..];
        } else {
            system = rest;
        }
    }
    if (equal(arch, "arm64")) arch = "aarch64";
    // Cortex-M: thumbv6m (M0, M0+), thumbv7m (M3), thumbv7em (M4, M7), thumbv8m.main (M33)
    const cortexM = equal(arch, "thumbv6m") || equal(arch, "thumbv7m") || equal(arch, "thumbv7em") || equal(arch, "thumbv8m.main");
    const knownArch = equal(arch, "x86_64") || equal(arch, "aarch64") || equal(arch, "riscv64") || equal(arch, "wasm32")
                   || equal(arch, "arm64e") || cortexM;
    if (!knownArch) {
        eprintln(`error: unknown target '${spec}'`);
        eprintln("  = hint: targets look like aarch64-macos, x86_64-linux, x86_64-windows, wasm32-wasi, thumbv7em-freestanding");
        return null;
    }
    t.pointerBytes = equal(arch, "wasm32") || cortexM ? 4 : 8;
    if (cortexM) {   // microcontrollers: no OS; `-eabihf` passes floats in FPU registers (a Cortex-M4F, M7, M33 with an FPU)
        if (!equal(system, "freestanding") || (abi.len > 0 && !equal(abi, "eabi") && !equal(abi, "eabihf")) ||
            (equal(abi, "eabihf") && equal(arch, "thumbv6m")) || (equal(abi, "eabihf") && equal(arch, "thumbv7m"))) {
            const fpu = equal(arch, "thumbv7em") || equal(arch, "thumbv8m.main") ? allocCString(` or ${arch}-freestanding-eabihf (with an FPU)`) : "";
            eprintln(`error: Cortex-M targets are ${arch}-freestanding${fpu}, not '${spec}'`);
            return null;
        }
        t.triple = allocCString(`${arch}-none-${abi.len > 0 ? abi : "eabi"}`);
        t.freestanding = true;
        return t;
    }
    if (equal(arch, "arm64e") && !equal(system, "macos")) {   // pointer authentication, as Apple's own code uses
        eprintln("error: arm64e is a macOS target: arm64e-macos");
        return null;
    }
    if (equal(arch, "riscv64") && !equal(system, "linux") && !equal(system, "freestanding")) {   // no RISC-V macOS or Windows
        eprintln(`error: riscv64 targets are riscv64-linux or riscv64-freestanding, not '${spec}'`);
        return null;
    }
    if (equal(arch, "wasm32") && !equal(system, "wasi") && !equal(system, "freestanding")) {
        eprintln(`error: wasm32 targets are wasm32-wasi or wasm32-freestanding, not '${spec}'`);
        return null;
    }
    if (equal(system, "wasi")) {
        if (!equal(arch, "wasm32")) {
            eprintln("error: WASI is a wasm32 target: wasm32-wasi");
            return null;
        }
        t.triple = "wasm32-unknown-wasip1";
        t.wasi = true;
    } else if (equal(system, "macos")) {
        t.apple = true;
        t.triple = allocCString(`${equal(arch, "aarch64") ? "arm64" : arch}-apple-macosx11.0`);
        t.host = false;   // named: for any Mac with that CPU (macOS 11 and later), not tuned for this one
    } else if (equal(system, "linux")) {   // musl unless asked: a static program that runs on any Linux
        t.triple = allocCString(`${arch}-unknown-linux-${abi.len > 0 ? abi : "musl"}`);
        t.musl = abi.len == 0 || equal(abi, "musl");
    } else if (equal(system, "windows")) {
        t.triple = allocCString(`${arch}-w64-windows-${abi.len > 0 ? abi : "gnu"}`);
        t.windows = abi.len == 0 || equal(abi, "gnu");
    } else if (equal(system, "freestanding")) {
        t.triple = allocCString(`${arch}-unknown-none-elf`);
        t.freestanding = true;
    } else {
        eprintln(`error: unknown operating system in target '${spec}' (use macos, linux, windows, wasi or freestanding)`);
        return null;
    }
    return t;
}

/**
 * The meanings that `--pkg` and `--pkg-in` gave, of which the first {@link packageArgCount} are in use.
 *
 * @since 1.0.0
 */

let packageArgs: PackageArg[1024] = undefined;

/**
 * The number of entries of {@link packageArgs} in use.
 *
 * @since 1.0.0
 */

let packageArgCount: usize = 0;

/**
 * Forgets every meaning that `--pkg` and `--pkg-in` gave.
 *
 * @remarks
 * The project build calls it before it compiles the build runner with its own `@build` package.
 *
 * @example
 * ```hx
 * clearPackageArgs();
 * addPackageArg(null, "@build=build.hx"); // the only package left
 * ```
 *
 * @since 1.0.0
 */

export function clearPackageArgs(): void {
    packageArgCount = 0;
}

/**
 * Adds a meaning for a bare import, as `--pkg` and `--pkg-in` give it.
 *
 * @param scope - The root module of the importing package, or `null` for the program's own code
 * @param text - The meaning as `name=path`
 * @returns `false` after reporting text without a name or a path, or more than 1024 meanings
 *
 * @remarks
 * The scope is stored as its real path when it exists, so that it matches the paths of the loaded modules.
 * A later meaning does not replace an earlier one, since the first match wins.
 *
 * @example
 * ```hx
 * addPackageArg(null, "json=lib/json.hx"); // true
 * addPackageArg(null, "json");             // false, error: --pkg takes name=path, found 'json'
 * ```
 *
 * @since 1.0.0
 */

export function addPackageArg(scope: ?string, text: string): bool {
    const eq = os.firstIndex(text, '=') ?? 0;
    if (eq == 0 || eq + 1 == text.len) {
        eprintln(`error: --pkg takes name=path, found '${text}'`);
        return false;
    }
    if (packageArgCount == packageArgs.len) {
        eprintln("error: too many --pkg options");
        return false;
    }
    let realScope: ?string = null;
    if (const dir = scope) realScope = os.realPath(dir) ?? dir;
    packageArgs[packageArgCount] = PackageArg { scope: realScope, name: text[0..eq], path: text[eq + 1..] };
    packageArgCount++;
    return true;
}

/**
 * Finds the folder of the package that a file belongs to.
 *
 * @param root - The file, such as the root module of the package
 * @returns The real path of the nearest folder above the file with a `helix.jsonc`, or `null` when there is none
 *
 * @remarks
 * The search starts at the folder of the file and goes up to the root of the file system.
 * It also gives `null` for a file that does not exist.
 *
 * @example
 * ```hx
 * // /work/app/helix.jsonc and /work/app/src/main.hx
 * packageDir("/work/app/src/main.hx"); // "/work/app"
 * ```
 *
 * @since 1.0.0
 */

export function packageDir(root: string): ?string {
    const real = os.realPath(root);
    if (real == null) return null;
    let dir: string = real;
    while (true) {
        const slash = os.lastIndex(dir, '/') ?? 0;
        if (slash == 0) return null;
        dir = dir[0..slash];
        if (os.readable(allocCString(`${dir}/helix.jsonc`))) return allocCString(`${dir}`);
    }
}

/**
 * The folder of the program being compiled, which holds the `helix.jsonc` of its root file, or empty.
 *
 * @since 1.0.0
 */

let programDir: string = "";

/**
 * Finds the dependency that an importing module is part of.
 *
 * @param importer - The real path of the importing module
 * @returns The root module of the `--pkg` dependency whose folder holds the importer, or `null` for the program's code
 *
 * @remarks
 * The deepest such folder wins.
 * A package whose folder is the program's own folder, such as the one that `addOptions` in `build.hx` gives,
 * belongs to the program and is passed over.
 *
 * @since 1.0.0
 */

function importerScope(importer: string): ?string {
    let best: usize = 0;
    let found: ?string = null;
    for (const arg of packageArgs[0..packageArgCount]) {
        const root = os.realPath(arg.path);
        if (root == null) continue;
        const dir = packageDir(root);
        if (dir == null) continue;
        // a module of the program's own folder (like build.hx's `addOptions`) is the program's, not a package
        if (programDir.len > 0 && equal(dir, programDir)) continue;
        if (dir.len > best && startsWith(importer, dir) && importer.len > dir.len && importer[dir.len] == '/') {
            best = dir.len;
            found = root;
        }
    }
    return found;
}

/**
 * The packages that this compilation read, of which the first {@link knownCount} are in use.
 *
 * @since 1.0.0
 */

let knownPackages: KnownPackage[1024] = undefined;

/**
 * The number of entries of {@link knownPackages} in use.
 *
 * @since 1.0.0
 */

let knownCount: usize = 0;

/**
 * The folders whose `helix.jsonc` did not read, which are reported once instead of at every import.
 *
 * @since 1.0.0
 */

let brokenPackages: Strings = undefined;

/**
 * The readable module names that the symbols of package exports get, one per entry of {@link packageLabelPaths}.
 *
 * @since 1.0.0
 */

let packageLabels: Strings = undefined;

/**
 * The real paths of the modules that packages export, one per entry of {@link packageLabels}.
 *
 * @since 1.0.0
 */

let packageLabelPaths: Strings = undefined;

/**
 * Whether this is a test build, in which a package may import its devDependencies.
 *
 * @since 1.0.0
 */

let testBuild = false;

/**
 * Why the last package import failed, which becomes the error at the import.
 *
 * @since 1.0.0
 */

let importError: string = "";

/**
 * The hint for {@link importError}, or empty when there is none.
 *
 * @since 1.0.0
 */

let importHint: string = "";

/**
 * Forgets the packages that an earlier compilation read.
 *
 * @param test - Whether the new compilation is a test build
 *
 * @remarks
 * The package table, the list of broken packages, and the module names of packages live for the whole process,
 * so a second compilation in the same run would otherwise see the first one's packages.
 *
 * @since 1.0.0
 */

function resetPackages(test: bool): void {
    knownCount = 0;
    brokenPackages = strings();
    packageLabels = strings();
    packageLabelPaths = strings();
    testBuild = test;
}

/**
 * Finds a package folder, reading its `helix.jsonc` on first use.
 *
 * @param dir - The real path of the package folder
 * @returns The package, or `null` when its `helix.jsonc` does not read
 *
 * @remarks
 * A `helix.jsonc` that does not read is reported the first time only.
 * More than 1024 packages stop the compiler.
 *
 * @since 1.0.0
 */

function knownPackage(dir: string): ?*KnownPackage {
    for (const i of 0..knownCount) {
        if (equal(knownPackages[i].dir, dir)) return &knownPackages[i];
    }
    if (contains(&brokenPackages, dir)) return null;
    if (knownCount == knownPackages.len) hxFatalMessage("more than 1024 packages");
    const m = loadManifest(dir, true);
    if (m == null) {
        add(&brokenPackages, dir);
        return null;
    }
    knownPackages[knownCount] = KnownPackage { dir, manifest: m, imported: false, checked: false };
    knownCount++;
    return &knownPackages[knownCount - 1];
}

/**
 * Records why a package import failed.
 *
 * @param error - The error at the import
 * @param hint - The hint below it
 * @returns `null`, so that a resolver can return the call
 *
 * @remarks
 * The error and the hint stay in {@link importError} and {@link importHint} until the next failure,
 * and {@link loadProgram} turns them into a diagnostic at the import.
 *
 * @since 1.0.0
 */

function failImport(error: Format, hint: Format): ?string {
    importError = allocCString(error);
    importHint = allocCString(hint);
    return null;
}

/**
 * Checks the `helix-modules` folder of a package once.
 *
 * @param p - The package
 * @returns `false` when a newer hpm laid out the folder, with {@link importError} set
 *
 * @remarks
 * It also warns when `helix.jsonc` changed after `hpm install` wrote `.hpm/state.json`.
 *
 * @since 1.0.0
 */

function checkLayout(p: *KnownPackage): bool {
    if (p.checked) return true;
    p.checked = true;
    const modules = allocCString(`${p.dir}/helix-modules/.hpm`);
    if (const text = os.readText(allocCString(`${modules}/layout`))) {
        let version: i64 = 0;
        for (const c of text) {
            if (c >= '0' && c <= '9') version = version * 10 + (c - '0') as i64;
        }
        if (version > LayoutVersion) {
            importError = allocCString(`${p.dir}/helix-modules was laid out by a newer hpm (layout ${version})`);
            importHint = allocCString(`this compiler reads layout ${LayoutVersion}; update helix, or install with the hpm that came with it`);
            return false;
        }
    }
    const manifest = os.stat(allocCString(`${p.dir}/helix.jsonc`), false);
    const state = os.stat(allocCString(`${modules}/state.json`), false);
    if (manifest != null && state != null && manifest.mtime > state.mtime) {
        eprintln(`warning: ${p.dir}/helix.jsonc changed since \`hpm install\`; run it again if dependencies changed`);
    }
    return true;
}

/**
 * Checks whether a module may import the devDependencies of its package.
 *
 * @param importer - The path of the importing module
 * @returns `true` in a test build, in a `.spec.hx` file, and in `build.hx`
 *
 * @remarks
 * A devDependency serves tests and the build script only, so a module of the program itself cannot import one.
 *
 * @since 1.0.0
 */

function devAllowed(importer: string): bool {
    return testBuild || endsWith(importer, ".spec.hx") || equal(os.baseName(importer), "build.hx");
}

/**
 * Makes a readable module name for an export of a package, such as `tls`, `tls.x509`, or `acme_tls`.
 *
 * @param name - The package name, with or without an `@scope/`
 * @param sub - The export path, `.` for the root or `./x` for a sub-path
 * @returns The name without a leading `@`, with `/`, `-`, and `.` turned into `_`, followed by the sub-path
 *
 * @remarks
 * {@link moduleLabel} adds `.2`, `.3`, and so on when an earlier module has the label, so the label need not be unique.
 *
 * @since 1.0.0
 */

function packageLabel(name: string, sub: string): string {
    const start: usize = name.len > 0 && name[0] == '@' ? 1 : 0;
    const label = allocCString(`${name[start..]}`);
    unsafe {
        const bytes = @ptrCast(u8[*], label.ptr);
        for (const c, i of label) {
            if (c == '/' || c == '-' || c == '.') bytes[i] = '_';
        }
    }
    if (equal(sub, ".")) return label;
    return allocCString(`${label}.${sub[2..]}`);
}

/**
 * Finds the file that a bare import names, through `helix-modules`.
 *
 * @param spec - The import, `name`, `name/sub`, `@scope/name`, or `@scope/name/sub`
 * @param importer - The real path of the importing module
 * @returns The real path of the file, or `null` with {@link importError} set
 *
 * @remarks
 * In a file of package R, the import names `R/helix-modules/name`.
 * When R is itself installed in a `helix-modules` folder, a missing one there falls back to its sibling `name`.
 * R's `helix.jsonc` must list the package as a dependency or a peer dependency,
 * or as a devDependency for an importer that {@link devAllowed} lets use one.
 * The package must export the sub-path, `.` for a bare name.
 * The package then counts as imported, and its file gets the name that {@link packageLabel} makes.
 *
 * @since 1.0.0
 */

function resolvePackage(spec: string, importer: string): ?string {
    // `name/sub` or `@scope/name/sub`
    let cut = spec.len;
    let slashes: u32 = 0;
    for (const c, i of spec) {
        if (c != '/') continue;
        slashes++;
        if (spec[0] != '@' || slashes == 2) {
            cut = i;
            break;
        }
    }
    const name = spec[0..cut];
    const sub = cut == spec.len ? "." : allocCString(`.${spec[cut..]}`);

    const ownerDir = packageDir(importer);
    if (ownerDir == null) {
        return failImport(`unknown package "${name}"`,
                          `a bare import names a dependency in helix.jsonc, and there's none above this file (\`hpm init\` starts one)`);
    }
    const owner = knownPackage(ownerDir);
    if (owner == null) return failImport(`cannot read ${ownerDir}/helix.jsonc`, "the error above says why");
    const m = &owner.manifest;
    if (!contains(&m.deps, name) && !contains(&m.peerDeps, name)) {
        if (contains(&m.devDeps, name)) {
            if (!devAllowed(importer)) {
                return failImport(`"${name}" is a devDependency, which only tests and build.hx can import`,
                                  `move it to \`dependencies\` in ${ownerDir}/helix.jsonc if this code needs it`);
            }
        } else {
            if (name[0] == '@') {   // `@diag/x` is a scoped package, or a folder through an alias that isn't there
                const scope = name[0..os.firstIndex(name, '/') ?? name.len];
                return failImport(`"${name}" is neither an alias nor a package in ${ownerDir}/helix.jsonc`,
                                  `for a folder of this package, add "aliases": { "${scope}": "src/..." }; for a package, \`hpm add ${name}\``);
            }
            return failImport(`package "${name}" isn't in ${ownerDir}/helix.jsonc`, `\`hpm add ${name}\` adds it`);
        }
    }

    let found: ?string = null;
    const own = allocCString(`${ownerDir}/helix-modules/${name}`);
    if (os.exists(own)) {
        if (!checkLayout(owner)) return null;
        found = os.realPath(own);
    } else {
        // an installed package's dependencies are its siblings: <helix-modules>/[@scope/]<owner> next to <name>
        let modules = ownerDir[0..os.lastIndex(ownerDir, '/') ?? 0];
        if (os.baseName(modules).len > 0 && os.baseName(modules)[0] == '@') modules = modules[0..os.lastIndex(modules, '/') ?? 0];
        if (equal(os.baseName(modules), "helix-modules")) found = os.realPath(allocCString(`${modules}/${name}`));
    }
    if (found == null) {
        return failImport(`package "${name}" isn't installed`, `${ownerDir}/helix.jsonc lists it; run \`hpm install\``);
    }
    const dir: string = found ?? "";
    const p = knownPackage(dir);
    if (p == null) return failImport(`cannot read ${dir}/helix.jsonc`, "the error above says why");
    for (const path, i of p.manifest.exportPaths.items) {
        if (!equal(path, sub)) continue;
        const file = p.manifest.exportFiles.items[i];
        const real = readableReal(file);
        if (real == null) return failImport(`"${name}" exports "${sub}" as '${file}', which doesn't exist`, "the package is broken; report it to its author");
        p.imported = true;
        add(&packageLabelPaths, real);
        add(&packageLabels, packageLabel(name, sub));
        return real;
    }
    let list = "";
    for (const path of p.manifest.exportPaths.items) list = list.len == 0 ? path : allocCString(`${list}, ${path}`);
    return failImport(`"${name}" doesn't export "${sub}"`, `it exports ${list}`);
}

/**
 * Collects the linker inputs of the packages that the program uses.
 *
 * @param options - The options of the build
 * @param target - The target of the build
 * @param links - The list that gets the compiled C objects and the `-l<name>` of each system library
 * @returns `false` after reporting a C file that does not compile
 *
 * @remarks
 * The program's own package counts as imported, so its C files, such as hpm's `c/host.c`, are linked as well.
 *
 * @since 1.0.0
 */

function packageLinks(options: readonly *Options, target: Target, links: *Strings): bool {
    // the program's own package's C (hpm's c/host.c), like a dependency's
    if (programDir.len > 0) {
        if (const own = knownPackage(programDir)) own.imported = true;
    }
    for (const i of 0..knownCount) {
        const p = &knownPackages[i];
        if (!p.imported) continue;
        for (const source of p.manifest.cSources.items) {
            const object = compilePackageC(options, target, &p.manifest, source);
            if (object == null) return false;
            add(links, object);
        }
        for (const lib of p.manifest.systemLibraries.items) add(links, allocCString(`-l${lib}`));
    }
    return true;
}

/**
 * Hashes a text with SHA-256.
 *
 * @param text - The text to hash
 * @returns The hash as 64 lowercase hex digits
 *
 * @remarks
 * {@link compilePackageC} uses it to name a cached object after its source, its command, and its include folders,
 * so any change to them gives a new object.
 *
 * @since 1.0.0
 */

function sha256Hex(text: string): string {
    let state: HxSha256 = undefined;
    hxSha256Init(&state);
    hxSha256Update(&state, text.ptr, text.len);
    let digest: u8[32] = undefined;
    let hex: u8[65] = undefined;
    hxSha256Finish(&state, &digest);
    hxSha256Hex(&digest, &hex);
    return allocCString(`${hex[0..64]}`);
}

/**
 * Compiles one of a package's C files, or finds it in the cache.
 *
 * @param options - The options of the build, whose mode sets the optimization level
 * @param target - The target of the build
 * @param m - The package's `helix.jsonc`, with its include folders and C flags
 * @param source - The C file
 * @returns The object file, or `null` after reporting
 *
 * @remarks
 * The cache is `$HELIX_HOME/c`, and the key is a hash of what goes in:
 * the source, the command, and the names and times of the files in the include folders.
 * The object goes to a file named after the process first and is renamed into place,
 * so that two builds at once never see half a file.
 *
 * @since 1.0.0
 */

function compilePackageC(options: readonly *Options, target: Target, m: readonly *Manifest, source: string): ?string {
    const cc = cCompiler(target);
    if (cc == null) return null;
    let args: Strings = cc;
    add(&args, "-c");
    add(&args, source);
    add(&args, options.mode == ModeDebug ? "-O0" : options.mode == 3 ? "-Os" : options.mode == 2 ? "-O3" : "-O2");
    if (options.mode == ModeDebug) add(&args, "-g");
    for (const dir of m.includeDirs.items) add(&args, allocCString(`-I${dir}`));
    for (const flag of m.cFlags.items) add(&args, flag);

    const text = os.readText(source);
    if (text == null) {
        eprintln(`error: cannot read '${source}', a C source of ${m.dir}/helix.jsonc: ${os.strerror(os.errno())}`);
        return null;
    }
    let key = allocCString(`${text}`);
    for (const arg of args.items) key = allocCString(`${key}\x00${arg}`);
    for (const dir of m.includeDirs.items) {
        for (const name of (os.listDir(dir) ?? strings()).items) {
            if (const st = os.stat(allocCString(`${dir}/${name}`), false)) key = allocCString(`${key}\x00${name}:${st.mtime}`);
        }
    }
    const cache = os.helixHome("c");
    const object = allocCString(`${cache}/${sha256Hex(key)}-${os.fileStem(source)}.o`);
    if (os.exists(object)) return object;
    if (!os.makeDirs(cache)) {
        eprintln(`error: cannot create ${cache}: ${os.strerror(os.errno())}`);
        return null;
    }
    const partial = allocCString(`${object}.${os.pid()}`);
    add(&args, "-o");
    add(&args, partial);
    if (os.run(args.items) != 0 || !os.rename(partial, object)) {
        eprintln(`error: compiling '${source}' (from ${m.dir}/helix.jsonc) failed`);
        os.unlink(partial);
        return null;
    }
    return object;
}

/**
 * Builds the command of the C compiler for a target, with its system headers.
 *
 * @param target - The target to compile for
 * @returns The command and its first arguments, or `null` after reporting
 *
 * @remarks
 * It is always LLVM's clang, or `clang` from `PATH` without one.
 * For musl and WASI it uses the C library that Helix builds instead of the host's headers.
 * For macOS it uses the SDK's headers, and a freestanding target gets none.
 * Windows is an error, since Helix does not set up the mingw-w64 headers yet.
 *
 * @example
 * ```hx
 * cCompiler(parseTarget("x86_64-windows")); // null, error: compiling C for Windows needs the mingw-w64 headers
 * cCompiler(parseTarget("riscv64-freestanding")).items; // [ clang, "-target", "riscv64-unknown-none-elf" ]
 * ```
 *
 * @since 1.0.0
 */

export function cCompiler(target: Target): ?Strings {
    let cc = strings();
    const clang = llvmTool("clang") ?? "clang";
    if (target.windows) {
        eprintln("error: compiling C for Windows needs the mingw-w64 headers, which Helix doesn't set up yet");
        eprintln("  = hint: Helix code builds for Windows; packages with C sources don't yet");
        return null;
    }
    if (target.musl || target.wasi) {   // the LLVM clang, with the musl (or wasi-libc) Helix builds, not the host's headers
        const libc = targetLibc(target.triple);
        if (libc == null) return null;
        const resources = clangResourceDir();
        if (resources == null) return null;
        add(&cc, clang);
        add(&cc, "-target");
        add(&cc, target.triple);
        add(&cc, "-nostdinc");
        add(&cc, allocCString(`-isystem${resources}/include`));
        add(&cc, allocCString(`-isystem${libc}/include`));
        if (startsWith(target.triple, "aarch64")) add(&cc, "-mno-outline-atomics");
    } else {   // the LLVM clang; for macOS with the SDK's headers, elsewhere (freestanding) with none
        add(&cc, clang);
        if (!target.host) {
            add(&cc, "-target");
            add(&cc, target.triple);
        }
        if (target.apple) {
            const sdk = macosSdk();
            if (sdk == null) {
                eprintln("error: can't find the macOS SDK");
                eprintln("  = hint: install the command-line tools (`xcode-select --install`), or set SDKROOT");
                return null;
            }
            add(&cc, "-isysroot");
            add(&cc, sdk.path);
        }
    }
    return cc;
}

/**
 * Finds the real path of a file that can be read.
 *
 * @param path - The path of the file
 * @returns The real path, or `null` when the file does not exist or cannot be read
 *
 * @remarks
 * The real path is what names a module, so two spellings of one file load it only once.
 *
 * @since 1.0.0
 */

function readableReal(path: string): ?string {
    const real = os.realPath(path);
    if (real == null) return null;
    if (!os.readable(real)) return null;
    return real;
}

/**
 * Resolves an import through an alias of the importing package.
 *
 * @param spec - The import, such as `@diag/x`
 * @param importer - The real path of the importing module
 * @returns The path that the alias makes, or `null` when no alias of the package matches
 *
 * @remarks
 * The aliases come from `"aliases": { "@diag": "src/diag" }` in the `helix.jsonc` of the importer's package.
 * An alias matches the whole import or a prefix of it that ends at a `/`.
 *
 * @since 1.0.0
 */

function aliasTarget(spec: string, importer: string): ?string {
    if (spec.len == 0 || spec[0] != '@') return null;
    const dir = packageDir(importer);
    if (dir == null) return null;
    const p = knownPackage(dir);
    if (p == null) return null;
    for (const name, i of p.manifest.aliasNames.items) {
        if (equal(spec, name)) return p.manifest.aliasPaths.items[i];
        if (startsWith(spec, name) && spec[name.len] == '/') return allocCString(`${p.manifest.aliasPaths.items[i]}${spec[name.len..]}`);
    }
    return null;
}

/**
 * Finds the file that an import names.
 *
 * @param spec - The import
 * @param importer - The real path of the importing module
 * @param isStd - Set to whether the import names the standard library, even when it fails
 * @returns The real path of the file, or `null` when there is none
 *
 * @remarks
 * - `./x` and `../x` are relative to the importing file
 * - `std` and `std/x` are in the standard library next to the compiler
 * - `@x` goes through an alias, and a missing file sets {@link importError}
 * - anything else is a `--pkg` meaning of the importer's package, or else a package in `helix-modules`
 *
 * It tries `x.hx` and then `x/index.hx`, and a path that already ends in `.hx` is tried as it is.
 *
 * @since 1.0.0
 */

function resolveImport(spec: string, importer: string, isStd: *bool): ?string {
    *isStd = false;
    let base = "";
    if (startsWith(spec, "./") || startsWith(spec, "../")) {
        if (const slash = os.lastIndex(importer, '/')) base = allocCString(`${importer[0..slash]}/${spec}`);
        else base = allocCString(`./${spec}`);
    } else if (equal(spec, "std") || startsWith(spec, "std/")) {
        const stdDir = os.besideCompiler("lib/std");
        if (stdDir == null) return null;
        base = allocCString(`${stdDir}${spec[3..]}`);
        *isStd = true;
    } else if (const aliased = aliasTarget(spec, importer)) {
        if (const real = readableReal(endsWith(aliased, ".hx") ? aliased : allocCString(`${aliased}.hx`))) return real;
        if (const real = readableReal(allocCString(`${aliased}/index.hx`))) return real;
        const shown = programDir.len > 0 && startsWith(aliased, programDir) ? aliased[programDir.len + 1..] : aliased;
        return failImport(`cannot find module "${spec}"`, `the alias makes it ${shown}: looked for \`${shown}.hx\` and \`${shown}/index.hx\``);
    } else {
        const scope = importerScope(importer);
        let found: ?string = null;
        for (const arg of packageArgs[0..packageArgCount]) {
            let sameScope = false;
            if (const want = scope) {
                if (const has = arg.scope) sameScope = equal(has, want);
            } else {
                sameScope = arg.scope == null;
            }
            if (sameScope && equal(arg.name, spec)) {
                found = arg.path;
                break;
            }
        }
        if (const path = found) base = path;
        else return resolvePackage(spec, importer);
    }
    if (const real = readableReal(endsWith(base, ".hx") ? base : allocCString(`${base}.hx`))) return real;
    return readableReal(allocCString(`${base}/index.hx`));
}

/**
 * Makes a readable, unique prefix for the symbols of a module, such as `main`, `geometry`, `std.text`, or `tls`.
 *
 * @param c - The compilation
 * @param path - The real path of the module
 * @param isStd - Whether the module is part of the standard library
 * @returns The name, with `.2`, `.3`, and so on added when an earlier module has it
 *
 * @remarks
 * The name is the file name without `.hx`, or the folder name for an `index.hx`.
 * A `--pkg` root module takes the name of its package, and a package export takes the one from {@link packageLabel}.
 *
 * @since 1.0.0
 */

function moduleLabel(c: *Compilation, path: string, isStd: bool): string {
    let stem = os.fileStem(path);
    for (const arg of packageArgs[0..packageArgCount]) {
        if (const real = os.realPath(arg.path)) {
            if (equal(real, path)) stem = arg.name;
        }
    }
    for (const labelPath, i of packageLabelPaths.items) {
        if (equal(labelPath, path)) stem = packageLabels.items[i];
    }
    if (equal(stem, "index")) {   // `dir/index.hx` is named after `dir`
        stem = os.fileStem(path[0..os.lastIndex(path, '/') ?? path.len]);
    }
    const label = isStd && !equal(stem, "std") ? allocCString(`std.${stem}`) : stem;

    let unique = label;
    let n: u32 = 2;
    while (true) {
        let taken = false;
        for (const m of c.modules.items) {
            if (equal(fromCString(m.name), unique)) taken = true;
        }
        if (!taken) break;
        unique = allocCString(`${label}.${n}`);
        n++;
    }
    return allocCString(`${unique}`);
}

/**
 * The real paths of the files that editors hold open, one per entry of {@link overlayTexts}.
 *
 * @remarks
 * For editors, open files replace what is on disk, since they may not be saved.
 *
 * @since 1.0.0
 */

let overlayPaths: Strings = undefined;

/**
 * The texts that replace the files of {@link overlayPaths}.
 *
 * @since 1.0.0
 */

let overlayTexts: Strings = undefined;

/**
 * The number of files that have a replacement text.
 *
 * @since 1.0.0
 */

let overlayCount: usize = 0;

/**
 * Whether diagnostics stay in the compilation for an editor instead of being printed.
 *
 * @since 1.0.0
 */

let quietDiagnostics = false;

/**
 * Reads a file as the given text instead of its contents on disk.
 *
 * @param real - The real path of the file
 * @param text - The text to read instead
 *
 * @remarks
 * Editors use it for files that are open and may not be saved, and the build uses it for `std/target`.
 * The last text set for a path wins.
 *
 * @example
 * ```hx
 * setOverlay("/work/app/main.hx", "export function main(): void {}");
 * compileFront("/work/app/main.hx", true, false, null, &ok); // checks the text, not the file
 * ```
 *
 * @since 1.0.0
 */

export function setOverlay(real: string, text: string): void {
    if (overlayCount == 0) {
        overlayPaths = strings();
        overlayTexts = strings();
    }
    for (const i of 0..overlayCount) {
        if (equal(overlayPaths.items[i], real)) {
            overlayTexts.items[i] = text;
            return;
        }
    }
    add(&overlayPaths, real);
    add(&overlayTexts, text);
    overlayCount++;
}

/**
 * Sets `std/target` to the target that the build is for.
 *
 * @param target - The target of the build
 *
 * @remarks
 * The module is `lib/std/target.hx` with `export const target: Target` given the target's system, architecture,
 * and pointer size, much as Zig writes `builtin`.
 * So `comptime target.os == Os.Windows` is known while compiling.
 * Without `lib/std/target.hx` next to the compiler it does nothing.
 *
 * @since 1.0.0
 */

function writeTargetModule(target: Target): void {
    const path = os.besideCompiler("lib/std/target.hx");
    if (path == null) return;
    const real = os.realPath(path) ?? path;
    const source = os.readText(real);
    if (source == null) return;
    const text: string = source;
    const marker = "export const target: Target";
    const at = indexOf(text, marker);
    if (at == null) return;
    const arch = target.triple[0..os.firstIndex(target.triple, '-') ?? target.triple.len];
    const archName = startsWith(arch, "thumb") ? "Thumb" : equal(arch, "x86_64") ? "X86_64" : equal(arch, "arm64e") ? "Arm64e"
                   : equal(arch, "aarch64") || equal(arch, "arm64") ? "Aarch64" : equal(arch, "riscv64") ? "Riscv64" : "Wasm32";
    const osName = target.freestanding ? "Freestanding" : target.wasi ? "Wasi" : target.apple ? "Macos"
                 : target.windows || indexOf(target.triple, "-windows") != null ? "Windows" : "Linux";
    setOverlay(real, allocCString(`${text[0..at]}${marker} = Target { os: Os.${osName}, arch: Arch.${archName}, pointerBits: ${target.pointerBytes * 8} };\n`));
}

/**
 * Keeps diagnostics in the compilation instead of printing them.
 *
 * @param quiet - Whether to keep them
 *
 * @remarks
 * The language server sets it, so that it can send the diagnostics to the editor.
 *
 * @example
 * ```hx
 * setQuiet(true);
 * const c = compileFront("main.hx", true, false, null, &ok);
 * c.diags.itemsLen; // the diagnostics, none of them printed
 * ```
 *
 * @since 1.0.0
 */

export function setQuiet(quiet: bool): void {
    quietDiagnostics = quiet;
}

/**
 * Finds the replacement text of a file.
 *
 * @param real - The real path of the file
 * @returns The text from {@link setOverlay}, or `null` when the file has none
 *
 * @remarks
 * Editors set overlays for the files that they have open, and the build sets one for `std/target`.
 * It is a linear search, since there are only a few overlays.
 *
 * @since 1.0.0
 */

function overlayFor(real: string): ?string {
    for (const i of 0..overlayCount) {
        if (equal(overlayPaths.items[i], real)) return overlayTexts.items[i];
    }
    return null;
}

/**
 * Adds a file as a module and lexes it.
 *
 * @param c - The compilation
 * @param path - The path that diagnostics show
 * @param real - The real path, which finds a replacement text and names the module
 * @param isStd - Whether the module is part of the standard library
 * @param error - Set to why the file does not read
 * @returns The index of the module, or `null` when the file does not read
 *
 * @remarks
 * The root of the module is its first token until the module is parsed.
 *
 * @since 1.0.0
 */

function addModule(c: *Compilation, path: string, real: string, isStd: bool, error: *readonly u8[*]): ?u32 {
    let file: u32 = 0;
    if (const text = overlayFor(real)) file = addText(&c.src, toCString(path), text);
    else file = hxSourceAddFile(&c.src, toCString(path), error);
    if (file == 0xFFFF_FFFF) return null;
    const firstToken = c.tokens.len;
    const f = sourceFile(&c.src, file);
    void hxLexAppend(&c.src, f.start, f.end, &c.tokens, &c.diags);
    // root is the first token until parsed
    c.modules.append(HxModule { root: firstToken, name: toCString(moduleLabel(c, real, isStd)) }) catch hxFatalMessage("out of memory");
    add(&c.realPaths, real);
    return (c.modules.items.len - 1) as u32;
}

/**
 * Finds a file of the source.
 *
 * @param src - The source
 * @param file - The index of the file
 * @returns The file, with where its text starts and ends
 *
 * @remarks
 * It does not check the index, so the file must come from the same source.
 *
 * @since 1.0.0
 */

function sourceFile(src: readonly *HxSource, file: u32): HxSourceFile {
    unsafe {
        return files(src)[file];
    }
}

/**
 * Finds the text of a token.
 *
 * @param c - The compilation
 * @param token - The index of the token
 * @returns The text that the token covers
 *
 * @remarks
 * The text is a view of the source, so it lives as long as the compilation does.
 *
 * @since 1.0.0
 */

function tokenSource(c: *Compilation, token: u32): string {
    unsafe {
        const start = c.tokens.starts![token];
        return c.src.text![start..start + c.tokens.lens![token]];
    }
}

/**
 * Loads and parses the root file and everything that it imports, directly or not.
 *
 * @param c - The compilation to fill
 * @param rootPath - The root file
 * @param test - Whether this is a test build, which also loads `std/testing`
 * @returns `false` when a file does not read or parse, or an import names no file
 *
 * @remarks
 * Each file loads once, by its real path, and the module list grows as imports are found.
 * An import that names no file is an error at the import.
 * Afterwards each import node maps to its module plus one in the program's import targets.
 *
 * @since 1.0.0
 */

function loadProgram(c: *Compilation, rootPath: string, test: bool): bool {
    const real = os.realPath(rootPath);
    if (real == null) {
        eprintln(`error: cannot read '${rootPath}': ${os.strerror(os.errno())}`);
        return false;
    }
    let error: readonly u8[*] = "";
    if (addModule(c, rootPath, real, false, &error) == null) {
        eprintln(`error: cannot read '${rootPath}': ${fromCString(error)}`);
        return false;
    }
    programDir = packageDir(real) ?? "";
    if (test) {
        let isStd = false;
        const testing = resolveImport("std/testing", real, &isStd);
        let added = false;
        if (const path = testing) added = addModule(c, path, path, true, &error) != null;
        if (!added) {
            eprintln("error: the standard library's testing.hx is missing next to the compiler");
            return false;
        }
        c.program.test = true;
        c.program.testingModule = c.modules.items.len as u32;
    }
    c.loaded = true;
    hxAstInit(&c.ast, &c.src, &c.tokens);
    c.parsed = true;

    let ok = c.diags.errorCount == 0;
    let targets = ArrayList<ImportTarget>.init(cAllocator());
    defer targets.deinit();
    let m: usize = 0;
    while (m < c.modules.items.len) {   // grows as imports are found
        const root = hxParseModule(&c.ast, c.modules.items[m].root, &c.diags, &ok);
        c.modules.items[m].root = root;

        const fileNode = node(&c.ast, root);
        for (const i of fileNode.a..fileNode.b) {
            const decl = extraAt(&c.ast, i);
            const n = node(&c.ast, decl);
            if (n.kind != NodeKind.Import) continue;
            const data = record<HxImportData>(&c.ast, n.a);
            if (data.pathToken == NoToken) continue;

            const quoted = tokenSource(c, data.pathToken);
            const spec = allocCString(`${quoted[1..quoted.len - 1]}`);
            const start = tokenStart(c, data.pathToken);
            const len = quoted.len as u32;
            let isStd = false;
            const found = resolveImport(spec, c.realPaths.items[m], &isStd);
            if (found == null) {
                const relative = spec[0] == '.';
                if (relative || isStd) {
                    const diag = emitf(&c.diags, DiagError, &c.src, start, len, `cannot find module "${spec}"`);
                    hintf(&c.diags, diag, `looked for \`${spec}.hx\` and \`${spec}/index.hx\``);
                } else {
                    const diag = emitf(&c.diags, DiagError, &c.src, start, len, `${importError}`);
                    if (importHint.len > 0) hintf(&c.diags, diag, `${importHint}`);
                }
                ok = false;
                continue;
            }
            let target: ?u32 = null;
            for (const path, j of c.realPaths.items) {
                if (equal(path, found)) {
                    target = j as u32;
                    break;
                }
            }
            if (target == null) {
                target = addModule(c, found, found, isStd, &error);
                if (target == null) {
                    void emitf(&c.diags, DiagError, &c.src, start, len, `cannot read "${spec}": ${fromCString(error)}`);
                    ok = false;
                    continue;
                }
                if (c.diags.errorCount > 0) ok = false;
            }
            targets.append(ImportTarget { node: decl, module: target ?? 0 }) catch hxFatalMessage("out of memory");
        }
        m++;
    }

    c.ast.root = c.modules.items[0].root;
    unsafe {
        c.program.modules = @ptrCast(?*HxModule, c.modules.items.ptr);
        const importTargets = @ptrCast(u32[*], hxZalloc(c.ast.nodesLen as usize * 4 + 4));
        for (const t of targets.items) importTargets[t.node] = t.module + 1;
        c.program.importTargets = importTargets;
    }
    c.program.count = c.modules.items.len as u32;
    return ok;
}

/**
 * Finds where a token starts.
 *
 * @param c - The compilation
 * @param token - The index of the token
 * @returns The byte offset of the token in the source
 *
 * @remarks
 * Diagnostics at an import use it with the length from {@link tokenSource} to underline the path.
 *
 * @since 1.0.0
 */

function tokenStart(c: *Compilation, token: u32): u32 {
    unsafe {
        return c.tokens.starts![token];
    }
}

/**
 * Allocates an empty compilation on the heap.
 *
 * @returns The compilation, which must stay where it is, since the syntax tree points into it
 *
 * @remarks
 * The memory starts zeroed, so every count and flag of the compilation starts at 0 or `false`.
 * Only the module list and the list of real paths need a start of their own.
 *
 * @since 1.0.0
 */

function newCompilation(): *Compilation {
    unsafe {
        const c = @ptrCast(*Compilation, hxZalloc(@sizeOf(Compilation)));
        c.modules = ArrayList<HxModule>.init(cAllocator());
        c.realPaths = strings();
        return c;
    }
}

/**
 * Loads, parses, and optionally checks a program, then prints its diagnostics.
 *
 * @param path - The root file
 * @param check - Whether to run the checker after loading
 * @param test - Whether this is a test build
 * @param target - The target, or `null` for this machine
 * @param ok - Set to whether there were no errors
 * @returns The compilation, which the caller releases with {@link compilationFree}
 *
 * @remarks
 * It first sets `std/target` to the target and forgets the packages of an earlier compilation.
 * The checker runs only when loading succeeded.
 * The diagnostics go to stderr with a count of the errors, unless {@link setQuiet} keeps them.
 *
 * @example
 * ```hx
 * let ok = false;
 * const c = compileFront("main.hx", true, false, null, &ok);
 * ok; // false when main.hx has errors, which are printed
 * compilationFree(c);
 * ```
 *
 * @since 1.0.0
 */

export function compileFront(path: string, check: bool, test: bool, target: ?Target, ok: *bool): *Compilation {
    const c = newCompilation();
    if (const t = target) writeTargetModule(t);
    else if (const host = parseTarget(null)) writeTargetModule(host);
    resetPackages(test);
    *ok = loadProgram(c, path, test);
    c.program.pointerBytes = 8;
    if (const t = target) c.program.pointerBytes = t.pointerBytes;
    if (*ok && check) {
        *ok = hxSemaCheck(&c.sema, &c.ast, &c.program, &c.diags);
        c.checked = true;
    }

    if (quietDiagnostics) return c;
    hxDiagRender(&c.diags, os.stderrFile(), os.useColor(2));
    const errors = c.diags.errorCount;
    if (errors > 0) eprintln(`${errors} error${errors == 1 ? "" : "s"}`);
    return c;
}

/**
 * Releases a compilation and everything that it holds.
 *
 * @param c - The compilation from {@link compileFront}
 *
 * @remarks
 * Only the stages that ran are released, since `checked` and `parsed` record how far the compilation got.
 * The pointer is freed too, so the caller must not use it afterward.
 *
 * @example
 * ```hx
 * compilationFree(c); // c can no longer be used
 * ```
 *
 * @since 1.0.0
 */

export function compilationFree(c: *Compilation): void {
    if (c.checked) hxSemaFree(&c.sema);
    if (c.parsed) hxAstFree(&c.ast);
    hxTokensFree(&c.tokens);
    hxSourceFree(&c.src);
    c.modules.deinit();
    c.realPaths.deinit();
    unsafe {
        free(@ptrCast(?u8[*], c.program.importTargets));
    }
    hxDiagListFree(&c.diags);
    unsafe {
        free(@ptrCast(?u8[*], c));
    }
}

/**
 * Makes the flag that adds the headers of clang's resource folder.
 *
 * @returns `-isystem<resource folder>/include`, or `null` when clang's resource folder is not found
 *
 * @remarks
 * The runtime builds that pass `-nostdinc` use it,
 * so they still find `stddef.h`, `stdarg.h`, and the other headers of clang.
 *
 * @since 1.0.0
 */

function resourceFlag(): ?string {
    const resources = clangResourceDir();
    if (resources == null) return null;
    return allocCString(`-isystem${resources}/include`);
}

/**
 * Finds the C library that Helix builds for a target, building it the first time.
 *
 * @param triple - The LLVM triple of the target
 * @returns The folder of the C library, or `null` after reporting
 *
 * @remarks
 * The sources come from `lib/rt` next to the compiler, so it gives `null` without them.
 *
 * @example
 * ```hx
 * targetLibc("x86_64-unknown-linux-musl"); // the folder with include/ and lib/libc.a
 * ```
 *
 * @since 1.0.0
 */

export function targetLibc(triple: string): ?string {
    const rtDir = os.besideCompiler("lib/rt");
    if (rtDir == null) return null;
    return libcEnsure(triple, rtDir);
}

/**
 * Finds the object file of a part of the Helix runtime for a target, compiling it when needed.
 *
 * @param target - The target
 * @param name - The part: `runtime`, `test` for the test runner, or `start` for freestanding start code
 * @returns The object file, or `null` after reporting
 *
 * @remarks
 * For the host it is `lib/helix_rt.o` or `lib/helix_test.o` next to the compiler when a release ships them.
 * Otherwise, and for every other target, it compiles the runtime's C source with `clang -target`
 * and caches it in `$HELIX_HOME/rt/<triple>`, named after a hash of the source and the files that it includes.
 * So a changed runtime builds a new object, and two compilers with different runtimes never share one.
 * A freestanding target uses `lib/rt/freestanding.c`, with `cortex_m.c` or `freestanding_start.S` as start code.
 * The test runner cannot build for WASI or for a target without an OS.
 *
 * @since 1.0.0
 */

function runtimeObject(target: Target, name: string): ?string {
    if (target.host) {
        const file = allocCString(`lib/${equal(name, "runtime") ? "helix_rt" : "helix_test"}.o`);
        if (const path = os.besideCompiler(file)) return path;
    }
    if (target.wasi && equal(name, "test")) {
        eprintln("error: `helix test` can't build for WASI yet: its runner starts a process for each test");
        return null;
    }
    if (target.freestanding && equal(name, "test")) {
        eprintln("error: `helix test` can't build for a target without an OS");
        return null;
    }
    // freestanding: the runtime and the start code (`_start`) of programs without an OS
    const cortexM = startsWith(target.triple, "thumb");
    const file = target.freestanding ? (equal(name, "start") ? (cortexM ? "lib/rt/cortex_m.c" : "lib/rt/freestanding_start.S") : "lib/rt/freestanding.c")
               : allocCString(`lib/rt/${name}${target.windows ? "_windows" : ""}.c`);
    const source = os.besideCompiler(file);
    if (source == null) {
        eprintln(`error: the runtime's source (${file}) is missing next to the compiler`);
        return null;
    }
    // named after the text it's built from, so compilers that ship different runtimes never share an object
    let key = "";
    const parts: string[3] = [file, "lib/rt/format.inc", "lib/rt/test_core.inc"];
    for (const part of parts) {
        if (const path = os.besideCompiler(part)) key = allocCString(`${key}\x00${os.readText(path) ?? ""}`);
    }
    const dir = allocCString(`${os.helixHome("rt")}/${target.triple}`);
    const out = allocCString(`${dir}/${name}-${sha256Hex(key)[0..16]}.o`);
    if (os.exists(out)) return out;

    const partial = allocCString(`${out}.${os.pid()}`);
    const clang = llvmTool("clang") ?? "clang";
    let args = strings();
    add(&args, clang);
    add(&args, "-target");
    add(&args, target.triple);
    if (target.freestanding) {   // no C library: clang's own headers, and nothing turned into calls to itself
        const resources = resourceFlag();
        if (resources == null) return null;
        add(&args, "-nostdinc");
        add(&args, resources);
        add(&args, "-std=gnu17");
        add(&args, "-O2");
        add(&args, "-ffreestanding");
        add(&args, "-fno-stack-protector");
        bareMetalFlags(&args, target.triple);
    } else if (target.windows) {   // runtime_windows.c needs only clang's own headers
        const resources = resourceFlag();
        if (resources == null) return null;
        add(&args, "-nostdinc");
        add(&args, resources);
        add(&args, "-std=gnu17");
        add(&args, "-O2");
        add(&args, "-fno-builtin");   // it defines snprintf itself
    } else if (target.musl || target.wasi) {   // against the musl (or wasi-libc) Helix builds, with the LLVM clang
        const libc = targetLibc(target.triple);
        if (libc == null) return null;
        const resources = resourceFlag();
        if (resources == null) return null;
        add(&args, "-nostdinc");
        add(&args, resources);
        add(&args, allocCString(`-isystem${libc}/include`));
        add(&args, "-D_GNU_SOURCE");
        add(&args, "-std=gnu17");
        add(&args, "-O2");
        add(&args, "-fno-omit-frame-pointer");   // the stack trace follows frame pointers on musl
        if (startsWith(target.triple, "aarch64")) add(&args, "-mno-outline-atomics");
    } else if (target.apple) {   // the LLVM clang, with the macOS SDK's headers
        const sdk = macosSdk();
        if (sdk == null) {
            eprintln("error: can't find the macOS SDK");
            eprintln("  = hint: install the command-line tools (`xcode-select --install`), or set SDKROOT");
            return null;
        }
        add(&args, "-isysroot");
        add(&args, sdk.path);
        add(&args, "-std=gnu17");
        add(&args, "-O2");
    } else {
        eprintln(`error: Helix has no runtime for ${target.triple}`);
        return null;
    }
    add(&args, "-c");
    add(&args, source);
    add(&args, "-o");
    add(&args, partial);
    if (!os.makeDirs(dir) || os.run(args.items) != 0 || !os.rename(partial, out)) {
        eprintln(`error: couldn't compile the Helix runtime for ${target.triple}`);
        os.unlink(partial);
        return null;
    }
    return out;
}

/**
 * Returns the platform name of a target, as the folders of the toolchain's LLVM are named.
 *
 * @param target - The target of the build
 * @returns A name such as `x86_64-linux` or `aarch64-macos`, or an empty string for a target without one
 *
 * @remarks
 * The architecture comes from the triple, with `arm64` spelled `aarch64`,
 * and the system is `macos`, `linux`, or `windows`, the same names a release of Helix uses.
 *
 * @example
 * ```hx
 * platformOf(parseTarget("x86_64-linux")!); // "x86_64-linux"
 * platformOf(parseTarget(null)!);           // "aarch64-macos" on an Apple-silicon Mac
 * ```
 *
 * @since 1.0.0
 */

export function platformOf(target: Target): string {
    let arch = target.triple[0..os.firstIndex(target.triple, '-') ?? target.triple.len];
    if (equal(arch, "arm64")) arch = "aarch64";
    const system = target.apple ? "macos" : target.musl ? "linux" : target.windows ? "windows" : "";
    if (system.len == 0) return "";
    return allocCString(`${arch}-${system}`);
}

/**
 * Finds the static LLVM that the Helix toolchain ships for a target.
 *
 * @param target - The target of the build
 * @returns The folder that holds the archives, or `null` when the toolchain has none for the target
 *
 * @remarks
 * A release keeps it in `lib/llvm/<platform>/lib` next to the compiler.
 * A toolchain installed by hand can keep it in `$HELIX_HOME/llvm/<platform>/lib` instead.
 * The folder holds LLVM's and libclang's archives, the C++ runtime they need for the target,
 * and the objects that a C++ program links in, such as the one that defines `__dso_handle`.
 *
 * @example
 * ```hx
 * toolchainLlvmDir(parseTarget("x86_64-linux")!); // "/opt/helix/lib/llvm/x86_64-linux/lib"
 * ```
 *
 * @see platformOf
 * @since 1.0.0
 */

export function toolchainLlvmDir(target: Target): ?string {
    const platform = platformOf(target);
    if (platform.len == 0) return null;
    if (const shipped = os.besideCompiler(allocCString(`lib/llvm/${platform}/lib/libLLVMCore.a`))) {
        if (const slash = os.lastIndex(shipped, '/')) return shipped[0..slash];
    }
    const home = allocCString(`${os.helixHome("llvm")}/${platform}/lib`);
    if (os.readable(allocCString(`${home}/libLLVMCore.a`))) return home;
    return null;
}

/**
 * Checks whether a link asks for LLVM, libclang, or lld.
 *
 * @param link - One `--link` file or `-l` library of the program
 * @returns `true` for `-lLLVM...`, `-lclang`, and `-llld...`
 *
 * @remarks
 * The compiler declares them in its helix.jsonc, and they come from the toolchain rather than from the system.
 *
 * @since 1.0.0
 */

function isLlvmLink(link: string): bool {
    return startsWith(link, "-lLLVM") || equal(link, "-lclang") || startsWith(link, "-llld");
}

/**
 * Adds the toolchain's static LLVM for a target to a linker command line, when the program links LLVM or libclang.
 *
 * @param args - The linker command line to extend
 * @param links - The `--link` files and `-l` libraries of the program
 * @param target - The target of the build
 * @param group - Whether to wrap the archives in `--start-group` and `--end-group`, which an ELF linker needs
 * @returns `true` when the archives went in, so the caller leaves out the `-l` names they replace
 *
 * @remarks
 * Every archive and object in {@link toolchainLlvmDir} goes in.
 * The archives depend on each other in no fixed order, so an ELF link takes them as one group.
 *
 * @see toolchainLlvmDir
 * @since 1.0.0
 */

function addToolchainLlvm(args: *Strings, links: readonly *Strings, target: Target, group: bool): bool {
    let wanted = false;
    for (const link of links.items) wanted = wanted || isLlvmLink(link);
    if (!wanted) return false;
    const dir = toolchainLlvmDir(target);
    if (dir == null) return false;
    const names = os.listDir(dir);
    if (names == null) return false;
    if (group) add(args, "--start-group");
    for (const name of names.items) {
        if (endsWith(name, ".a") || endsWith(name, ".o")) add(args, allocCString(`${dir}/${name}`));
    }
    if (group) add(args, "--end-group");
    return true;
}

/**
 * Checks that every `-l<name>` exists for the target, not only on this machine.
 *
 * @param options - The options with the link list
 * @param target - The target
 * @param libc - The folder of the target's C library
 * @returns `false` after reporting a library that is not in `<libc>/lib`
 *
 * @remarks
 * A library of this machine cannot go into a program for another one, so the error suggests building it as a package.
 * Every other link entry, such as an object file, is left to the linker.
 *
 * @since 1.0.0
 */

function targetLibrariesExist(options: readonly *Options, target: Target, libc: string): bool {
    const toolchainLlvm = toolchainLlvmDir(target) != null;
    for (const link of options.links.items) {
        if (!startsWith(link, "-l")) continue;
        if (toolchainLlvm && isLlvmLink(link)) continue;
        if (os.readable(allocCString(`${libc}/lib/lib${link[2..]}.a`))) continue;
        eprintln(`error: there's no ${link[2..]} library for ${target.triple}`);
        eprintln("  = hint: a system library of this machine can't be linked into a program for another one; build it from");
        eprintln("    source instead, as a package with `module.cSources` (or `addCSources`), so it's compiled for the target");
        return false;
    }
    return true;
}

/**
 * Runs a linker command.
 *
 * @param args - The command, whose first item names the linker
 * @returns `false` after reporting that linking failed
 *
 * @remarks
 * `ld.lld`, `ld64.lld`, and `wasm-ld` are lld, which is linked into the compiler and runs in this process,
 * so no linker needs to be installed.
 * Any other linker, such as Apple's `ld` for arm64e, runs as a program.
 * The linker prints its own errors, so the message here only says that the step failed.
 *
 * @since 1.0.0
 */

function runLinker(args: readonly *Strings): bool {
    const linker = args.items[0];
    const lld = equal(linker, "ld.lld") || equal(linker, "ld64.lld") || equal(linker, "wasm-ld");
    const code = lld ? hx_lld_link(os.cArgs(args.items), args.items.len) : os.run(args.items);
    if (code != 0) {
        eprintln("error: linking failed");
        return false;
    }
    return true;
}

/**
 * Links a Windows program with ld.lld in MinGW mode.
 *
 * @param options - The options of the build
 * @param target - The target
 * @param object - The object file of the program
 * @param output - The executable to write
 * @returns `false` after reporting
 *
 * @remarks
 * The inputs are the program, the Windows runtime, which has the entry point, what `--link` and `-l` add,
 * the import libraries of msvcrt.dll and kernel32.dll, and compiler-rt's builtins.
 *
 * @since 1.0.0
 */

function linkWindows(options: readonly *Options, target: Target, object: string, output: string): bool {
    const libc = targetLibc(target.triple);
    if (libc == null) return false;
    const runtime = runtimeObject(target, "runtime");
    if (runtime == null) return false;
    let testRuntime = "";
    if (options.test) {
        const path = runtimeObject(target, "test");
        if (path == null) return false;
        testRuntime = path;
    }
    if (!targetLibrariesExist(options, target, libc)) return false;
    let args = strings();
    add(&args, "ld.lld");
    add(&args, "-m");
    add(&args, startsWith(target.triple, "aarch64") ? "arm64pe" : "i386pep");
    add(&args, "--subsystem");
    add(&args, "console");
    add(&args, "-e");
    add(&args, "mainCRTStartup");
    add(&args, "--gc-sections");
    add(&args, "-o");
    add(&args, output);
    add(&args, object);
    add(&args, runtime);
    if (options.test) add(&args, testRuntime);
    add(&args, allocCString(`-L${libc}/lib`));
    for (const link of options.links.items) add(&args, link);
    add(&args, "-lmsvcrt");
    add(&args, "-lkernel32");
    add(&args, allocCString(`${libc}/lib/libcompiler_rt.a`));
    if (options.strip) add(&args, "--strip-all");
    return runLinker(&args);
}

/**
 * Links a static program for a Linux musl target with ld.lld.
 *
 * @param options - The options of the build
 * @param target - The target
 * @param object - The object file of the program
 * @param output - The executable to write
 * @returns `false` after reporting
 *
 * @remarks
 * The inputs are musl's startup files, the program, the Helix runtime, what `--link` and `-l` add,
 * then libc and compiler-rt's builtins.
 *
 * @since 1.0.0
 */

function linkMusl(options: readonly *Options, target: Target, object: string, output: string): bool {
    const libc = targetLibc(target.triple);
    if (libc == null) return false;
    const runtime = runtimeObject(target, "runtime");
    if (runtime == null) return false;
    let testRuntime = "";
    if (options.test) {
        const path = runtimeObject(target, "test");
        if (path == null) return false;
        testRuntime = path;
    }
    if (!targetLibrariesExist(options, target, libc)) return false;
    let args = strings();
    add(&args, "ld.lld");
    add(&args, "-static");
    add(&args, "--gc-sections");
    add(&args, "-o");
    add(&args, output);
    add(&args, allocCString(`${libc}/lib/crt1.o`));
    add(&args, allocCString(`${libc}/lib/crti.o`));
    add(&args, object);
    add(&args, runtime);
    if (options.test) add(&args, testRuntime);
    add(&args, allocCString(`-L${libc}/lib`));
    const llvmLinked = addToolchainLlvm(&args, &options.links, target, true);
    for (const link of options.links.items) {
        if (!(llvmLinked && isLlvmLink(link))) add(&args, link);
    }
    add(&args, "--start-group");
    add(&args, allocCString(`${libc}/lib/libc.a`));
    add(&args, allocCString(`${libc}/lib/libcompiler_rt.a`));
    add(&args, "--end-group");
    add(&args, allocCString(`${libc}/lib/crtn.o`));
    if (options.strip) add(&args, "--strip-all");
    return runLinker(&args);
}

/**
 * Links a program without an operating system with ld.lld.
 *
 * @param options - The options of the build
 * @param target - The target
 * @param object - The object file of the program
 * @param output - The ELF file to write
 * @returns `false` after reporting
 *
 * @remarks
 * The inputs are the start code, the program, the freestanding runtime, what `--link` adds, and compiler-rt's builtins.
 * `--linker-script` places them in memory, or else the target's default.
 * That default is `lib/rt/freestanding-<arch>.ld` for QEMU's `virt` board,
 * or a script made from the flash and RAM of a Cortex-M chip, which is deleted after linking.
 * The result is an ELF file that a bootloader or `qemu -kernel` loads.
 * It links riscv64, aarch64, x86_64, and Cortex-M.
 *
 * @since 1.0.0
 */

function linkFreestanding(options: readonly *Options, target: Target, object: string, output: string): bool {
    const arch = target.triple[0..os.firstIndex(target.triple, '-') ?? target.triple.len];
    const cortexM = startsWith(arch, "thumb");
    const known = equal(arch, "riscv64") || equal(arch, "aarch64") || equal(arch, "x86_64") || cortexM;
    if (!known) {
        eprintln(`error: linking for ${arch}-freestanding isn't supported yet (riscv64, aarch64, x86_64 and Cortex-M are)`);
        eprintln("  = hint: `--emit obj` writes the object file");
        return false;
    }
    let script = "";
    if (const own = options.linkerScript) {
        script = own;
    } else if (cortexM) {   // a microcontroller: the script comes from its flash and RAM
        const generated = cortexMScript(options, output);
        if (generated == null) return false;
        script = generated;
    } else if (const builtin = os.besideCompiler(allocCString(`lib/rt/freestanding-${arch}.ld`))) {
        script = builtin;
    }
    if (script.len == 0 || !os.readable(script)) {
        eprintln(`error: cannot read the linker script '${script}'`);
        return false;
    }
    const rtDir = os.besideCompiler("lib/rt");
    if (rtDir == null) return false;
    const builtins = libcEnsure(target.triple, rtDir);
    if (builtins == null) return false;
    const start = runtimeObject(target, "start");
    const runtime = runtimeObject(target, "runtime");
    if (start == null || runtime == null) return false;
    let args = strings();
    add(&args, "ld.lld");
    add(&args, "-static");
    add(&args, "-nostdlib");
    add(&args, "--gc-sections");
    add(&args, "-T");
    add(&args, script);
    add(&args, "-o");
    add(&args, output);
    add(&args, start);
    add(&args, object);
    add(&args, runtime);
    for (const link of options.links.items) add(&args, link);
    add(&args, allocCString(`${builtins}/lib/libcompiler_rt.a`));
    if (options.strip) add(&args, "--strip-all");
    const linked = runLinker(&args);
    if (cortexM && options.linkerScript == null) os.unlink(script);
    return linked;
}

/**
 * Writes the linker script of a Cortex-M program from its flash and RAM.
 *
 * @param options - The options with `--flash` and `--ram`, or the values of the package's chip
 * @param output - The executable, next to which the script goes as `<output>.ld`
 * @returns The script, or `null` after reporting
 *
 * @remarks
 * The vector table is at the start of flash, followed by code and constants.
 * `.data` lives in RAM with its first values in flash, which `Reset_Handler` copies.
 * `.bss` follows it, and the stack starts at the top of RAM.
 *
 * @since 1.0.0
 */

function cortexMScript(options: readonly *Options, output: string): ?string {
    const flash = options.flash ?? "";
    const ram = options.ram ?? "";
    if (flash.len == 0 || ram.len == 0) {
        eprintln("error: a Cortex-M program needs its chip's flash and RAM");
        eprintln("  = hint: `--flash 0x08000000:512K --ram 0x20000000:128K`, or `\"chip\"` in helix.jsonc (docs/design/build.md)");
        return null;
    }
    const f = os.firstIndex(flash, ':') ?? 0;
    const r = os.firstIndex(ram, ':') ?? 0;
    const script = allocCString(`${output}.ld`);
    const text = allocCString(`/* generated by helix for --flash ${flash} --ram ${ram} */
MEMORY
{
    FLASH (rx) : ORIGIN = ${flash[0..f]}, LENGTH = ${flash[f + 1..]}
    RAM (rwx) : ORIGIN = ${ram[0..r]}, LENGTH = ${ram[r + 1..]}
}
ENTRY(Reset_Handler)
SECTIONS
{
    .vectors : { KEEP(*(.vectors)) } > FLASH
    .text : { *(.text .text.*) } > FLASH
    .rodata : ALIGN(4) { *(.rodata .rodata.*) } > FLASH
    .data : ALIGN(4) { __data_start = .; *(.data .data.*) . = ALIGN(4); __data_end = .; } > RAM AT > FLASH
    __data_load = LOADADDR(.data);
    .bss (NOLOAD) : ALIGN(4) { __bss_start = .; *(.bss .bss.* COMMON) . = ALIGN(4); __bss_end = .; } > RAM
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment) }
}
`);
    if (!os.writeText(script, text)) {
        eprintln(`error: cannot write ${script}: ${os.strerror(os.errno())}`);
        return null;
    }
    return script;
}

/**
 * Finds the Cortex-M target of a core.
 *
 * @param cpu - The core, such as `cortex-m4`
 * @param fpu - Whether the chip has an FPU
 * @returns The target, such as `thumbv7em-freestanding-eabihf` for a `cortex-m4` with an FPU,
 * or `null` for another core
 *
 * @remarks
 * An FPU only counts on thumbv7em and thumbv8m.main, the architectures with an `eabihf` target.
 *
 * @since 1.0.0
 */

function cortexMTarget(cpu: string, fpu: bool): ?string {
    let arch = "";
    if (equal(cpu, "cortex-m0") || equal(cpu, "cortex-m0plus") || equal(cpu, "cortex-m1")) arch = "thumbv6m";
    else if (equal(cpu, "cortex-m3")) arch = "thumbv7m";
    else if (equal(cpu, "cortex-m4") || equal(cpu, "cortex-m7")) arch = "thumbv7em";
    else if (equal(cpu, "cortex-m33") || equal(cpu, "cortex-m35p") || equal(cpu, "cortex-m55")) arch = "thumbv8m.main";
    else return null;
    return fpu && !equal(arch, "thumbv6m") && !equal(arch, "thumbv7m") ? allocCString(`${arch}-freestanding-eabihf`) : allocCString(`${arch}-freestanding`);
}

/**
 * Reads every chip of the JSON tables in `lib/chips` next to the compiler.
 *
 * @returns The chips, or an empty list when there are no tables
 *
 * @remarks
 * `tools/chips` makes the tables.
 * Each one has a `chips` array with one row per chip: name, cpu, fpu, flash, and ram.
 * A file that does not parse and a row with fewer than five items are passed over.
 *
 * @example
 * ```hx
 * chipTable().items[0]; // Chip { name: "ATSAMD21G18A", cpu: "cortex-m0plus", ... }
 * ```
 *
 * @since 1.0.0
 */

export function chipTable(): ArrayList<Chip> {
    let chips = ArrayList<Chip>.init(cAllocator());
    const dir = os.besideCompiler("lib/chips");
    if (dir == null) return chips;
    const names = os.listDir(dir);
    if (names == null) return chips;
    for (const file of names.items) {
        if (!endsWith(file, ".json")) continue;
        const source = os.readText(allocCString(`${dir}/${file}`));
        if (source == null) continue;
        let parsed = parse(source);
        defer hxJsonFree(&parsed.json);
        if (!parsed.ok) continue;
        const rows = member(&parsed.json, "chips");
        if (rows == null || rows.kind != JsonArray) continue;
        const list = rows;
        for (const i of 0..list.count) {
            const row = itemAt(list, i);
            if (row.kind != JsonArray || row.count < 5) continue;
            chips.append(Chip {
                name: jsonText(itemAt(row, 0)), cpu: jsonText(itemAt(row, 1)), fpu: itemAt(row, 2).kind == JsonBool && itemAt(row, 2).boolean,
                flash: jsonText(itemAt(row, 3)), ram: jsonText(itemAt(row, 4)),
            }) catch hxFatalMessage("out of memory");
        }
    }
    return chips;
}

/**
 * Copies a text with its ASCII letters in capitals.
 *
 * @param text - The text to copy
 * @returns The new text
 *
 * @remarks
 * Only `a` to `z` change, so letters outside ASCII stay as they are.
 * It lets chip names match in any case.
 *
 * @since 1.0.0
 */

function upper(text: string): string {
    const out = allocCString(`${text}`);
    unsafe {
        const bytes = @ptrCast(u8[*], out.ptr);
        for (const c, i of out) {
            if (c >= 'a' && c <= 'z') bytes[i] = c - 32;
        }
    }
    return out;
}

/**
 * Finds a chip of the table by name.
 *
 * @param name - The name, in any case
 * @returns The chip, or `null` after reporting the names nearest to it
 *
 * @remarks
 * The name matches exactly or by the longest table name that it starts with,
 * so a full part number such as `STM32F411RET6`, with package T and temperature range 6, finds `STM32F411RE`.
 * The error lists up to eight names that share the most leading characters with it, at least six of them.
 *
 * @example
 * ```hx
 * findChip("stm32f411ret6").name; // "STM32F411RE"
 * findChip("nochip");              // null, error: no chip named 'nochip'
 * ```
 *
 * @since 1.0.0
 */

export function findChip(name: string): ?Chip {
    const want = upper(name);
    const chips = chipTable();
    let best: ?Chip = null;
    for (const c of chips.items) {
        if (!startsWith(want, c.name)) continue;
        if (const b = best) {
            if (c.name.len <= b.name.len) continue;
        }
        best = c;
    }
    if (best != null) return best;
    // the nearest: the most leading characters in common
    let common: usize = 0;
    for (const c of chips.items) {
        let n: usize = 0;
        while (n < c.name.len && n < want.len && c.name[n] == want[n]) n++;
        if (n > common) common = n;
    }
    eprintln(`error: no chip named '${name}' (${chips.items.len} are known: \`helix chips\` lists them)`);
    let shown: u32 = 0;
    for (const c of chips.items) {
        if (common < 6 || shown >= 8 || c.name.len < common || !equal(c.name[0..common], want[0..common])) continue;
        eprintln(`  = maybe: ${c.name}`);
        shown++;
    }
    if (chips.items.len > 0) eprintln("  = hint: or describe it: \"chip\": { \"cpu\": ..., \"fpu\": ..., \"flash\": { \"origin\": ..., \"size\": ... }, \"ram\": { ... } }");
    return null;
}

/**
 * Runs `helix chips [filter]`, which lists the chips that `"chip"` and `--chip` know.
 *
 * @param args - The arguments after the command, whose first one is the filter
 * @returns The exit status, 1 when no chip is listed
 *
 * @remarks
 * The filter keeps the chips whose name contains it, in any case.
 *
 * @example
 * ```hx
 * cmdChips(["f411"]); // 0, prints: STM32F411RE  cortex-m4+fpu  flash 0x08000000:512K  ram 0x20000000:128K
 * ```
 *
 * @since 1.0.0
 */

export function cmdChips(args: readonly string[]): u8 {
    const filter = args.len > 0 ? upper(args[0]) : "";
    let shown: u32 = 0;
    for (const c of chipTable().items) {
        if (filter.len > 0 && indexOf(c.name, filter) == null) continue;
        println(`${c.name}  ${c.cpu}${c.fpu ? "+fpu" : ""}  flash ${c.flash}  ram ${c.ram}`);
        shown++;
    }
    if (shown == 0) {
        eprintln(filter.len > 0 ? allocCString(`no chip matches '${args[0]}'`) : "no chip table next to the compiler (lib/chips)");
        return 1;
    }
    return 0;
}

/**
 * Fills in what the command line leaves out from the chip: the target, the CPU, and the memory.
 *
 * @param options - The options to fill
 * @returns `false` after reporting a chip that the table does not know or a core without a Cortex-M target
 *
 * @remarks
 * The chip comes from `--chip`, or else from the `chip` of the package's `helix.jsonc`,
 * which holds a name that the chip table knows or a description of the chip.
 * A target that is not a Cortex-M, such as `native`, is a program for something else,
 * like a code generator, and a test build without a target runs here, so neither takes the chip.
 * Options that the command line sets win over the chip.
 *
 * @example
 * ```hx
 * options.chip = "STM32F411RE";
 * applyChip(&options);
 * options.target; // "thumbv7em-freestanding-eabihf"
 * options.flash;  // "0x08000000:512K"
 * ```
 *
 * @since 1.0.0
 */

export function applyChip(options: *Options): bool {
    // a target that isn't a Cortex-M (`native` for this machine) is a program for something else, like a code
    // generator, and tests run here: the chip isn't theirs
    if (const t = options.target) {
        if (!startsWith(t, "thumb")) return true;
    } else if (options.test) {
        return true;
    }
    let cpu = "";
    let fpu = false;
    let flash = "";
    let ram = "";
    let where = "--chip";
    let name = options.chip ?? "";
    if (name.len == 0) {
        const real = os.realPath(options.file);
        if (real == null) return true;
        const dir = packageDir(real);
        if (dir == null) return true;
        const m = loadManifest(dir, false);
        if (m == null) return true;
        const manifest: Manifest = m;
        where = allocCString(`${dir}/helix.jsonc`);
        name = manifest.chipName;
        cpu = manifest.chipCpu;
        fpu = manifest.chipFpu;
        flash = manifest.chipFlash;
        ram = manifest.chipRam;
    }
    if (name.len > 0) {
        const found = findChip(name);
        if (found == null) return false;
        const chip: Chip = found;
        cpu = chip.cpu;
        fpu = chip.fpu;
        flash = chip.flash;
        ram = chip.ram;
    }
    if (cpu.len == 0) return true;
    if (options.target == null) {
        const derived = cortexMTarget(cpu, fpu);
        if (derived == null) {
            eprintln(`error: ${where}: unknown chip cpu '${cpu}'`);
            eprintln("  = hint: cortex-m0, cortex-m0plus, cortex-m3, cortex-m4, cortex-m7 or cortex-m33");
            return false;
        }
        options.target = derived;
    }
    if (options.cpu == null) options.cpu = cpu;
    if (options.flash == null) options.flash = flash;
    if (options.ram == null) options.ram = ram;
    return true;
}

/**
 * Links a WASI program with wasm-ld into a `.wasm` module.
 *
 * @param options - The options of the build
 * @param target - The target
 * @param object - The object file of the program
 * @param output - The module to write
 * @returns `false` after reporting
 *
 * @remarks
 * The inputs are wasi-libc's start file, which calls `main`, the program, the Helix runtime,
 * what `--link` and `-l` add, then libc and compiler-rt's builtins.
 * The stack is 1 MiB, like a thread's stack elsewhere, instead of wasm-ld's 64 KiB.
 *
 * @since 1.0.0
 */

function linkWasi(options: readonly *Options, target: Target, object: string, output: string): bool {
    const libc = targetLibc(target.triple);
    if (libc == null) return false;
    const runtime = runtimeObject(target, "runtime");
    if (runtime == null) return false;
    if (options.test && runtimeObject(target, "test") == null) return false;   // reports that there's no runner yet
    if (!targetLibrariesExist(options, target, libc)) return false;
    let args = strings();
    add(&args, "wasm-ld");
    add(&args, "--gc-sections");
    add(&args, "-z");
    add(&args, "stack-size=1048576");   // 1 MiB, like a thread's stack elsewhere; wasm-ld's default is 64 KiB
    add(&args, "-o");
    add(&args, output);
    add(&args, allocCString(`${libc}/lib/crt1-command.o`));
    add(&args, object);
    add(&args, runtime);
    add(&args, allocCString(`-L${libc}/lib`));
    for (const link of options.links.items) add(&args, link);
    add(&args, allocCString(`${libc}/lib/libc.a`));
    add(&args, allocCString(`${libc}/lib/libcompiler_rt.a`));
    if (options.strip) add(&args, "--strip-all");
    return runLinker(&args);
}

/**
 * Lets the linker find the LLVM that this compiler uses, for a program that links LLVM, libclang, or lld.
 *
 * @param args - The linker command line to extend
 * @param links - The `--link` files and `-l` libraries of the program
 *
 * @remarks
 * A program that declares `LLVM`, `clang`, or lld's libraries among its system libraries, as the compiler does,
 * links with the LLVM this compiler runs on rather than one that the linker happens to find.
 * The folder goes in as a search path and as a run path, so the program also loads that LLVM when it runs.
 * lld's folder follows it when lld is installed apart from LLVM, as Homebrew does.
 * Nothing is added for a program that links none of them, or when a folder cannot be found.
 *
 * @see lldLibDir
 * @see linkedLlvmLibDir
 *
 * @since 1.0.0
 */

function addLlvmLibraryDir(args: *Strings, links: readonly *Strings): void {
    let wanted = false;
    let lldWanted = false;
    for (const link of links.items) {
        wanted = wanted || isLlvmLink(link);
        lldWanted = lldWanted || startsWith(link, "-llld");
    }
    if (!wanted) return;
    const llvmDir = linkedLlvmLibDir();
    if (const dir = llvmDir) {
        add(args, allocCString(`-L${dir}`));
        add(args, "-rpath");
        add(args, dir);
    }
    if (!lldWanted) return;
    if (const dir = lldLibDir()) {
        if (equal(dir, llvmDir ?? "")) return;   // one LLVM with lld inside
        add(args, allocCString(`-L${dir}`));
        add(args, "-rpath");
        add(args, dir);
    }
}

/**
 * Links a macOS program with ld64.lld against the macOS SDK's stubs of libSystem.
 *
 * @param options - The options of the build
 * @param target - The target
 * @param object - The object file of the program
 * @param output - The executable to write
 * @param debugInfo - Whether the object has debug info to copy out
 * @returns `false` after reporting
 *
 * @remarks
 * The inputs are the program, the Helix runtime, what `--link` and `-l` add, and clang's builtins.
 * arm64e links with Apple's ld, since ld64.lld cannot write signed pointers.
 * The oldest macOS it runs on is this machine's for a host build and 11.0 otherwise.
 * A debug build exports every symbol, so that the panic stack trace can name Helix functions,
 * and `--strip` keeps only the symbols that other code links to.
 * With debug info, LLVM's dsymutil then copies the DWARF out of the object file into `<output>.dSYM`,
 * before the object file is deleted.
 *
 * @since 1.0.0
 */

function linkMacos(options: readonly *Options, target: Target, object: string, output: string, debugInfo: bool): bool {
    const runtime = runtimeObject(target, "runtime");
    if (runtime == null) return false;
    let testRuntime = "";
    if (options.test) {
        const path = runtimeObject(target, "test");
        if (path == null) return false;
        testRuntime = path;
    }
    const sdk = macosSdk();
    if (sdk == null) {
        eprintln("error: can't find the macOS SDK, which has the system libraries' stubs to link against");
        eprintln("  = hint: install the command-line tools (`xcode-select --install`), or set SDKROOT");
        return false;
    }
    const arm64e = startsWith(target.triple, "arm64e");
    let args = strings();
    if (arm64e) {
        if (const apple = appleLinker()) {
            add(&args, apple);
        } else {
            eprintln("error: linking for arm64e needs Apple's ld\n  = hint: install the command-line tools (`xcode-select --install`)");
            return false;
        }
    } else {
        add(&args, "ld64.lld");
    }
    // the oldest macOS it runs on: this machine's for its own programs, else what the target says
    let minimum = "11.0";
    if (target.host) minimum = macosVersion() ?? minimum;

    add(&args, "-arch");
    add(&args, startsWith(target.triple, "x86_64") ? "x86_64" : arm64e ? "arm64e" : "arm64");
    add(&args, "-platform_version");
    add(&args, "macos");
    add(&args, minimum);
    add(&args, sdk.version);
    add(&args, "-syslibroot");
    add(&args, sdk.path);
    add(&args, "-o");
    add(&args, output);
    add(&args, object);
    add(&args, runtime);
    if (options.test) add(&args, testRuntime);
    const llvmLinked = addToolchainLlvm(&args, &options.links, target, false);
    if (llvmLinked) add(&args, "-lc++");
    else addLlvmLibraryDir(&args, &options.links);
    for (const link of options.links.items) {
        if (!(llvmLinked && isLlvmLink(link))) add(&args, link);
    }
    add(&args, "-lSystem");
    if (const resources = clangResourceDir()) {
        const builtins = allocCString(`${resources}/lib/darwin/libclang_rt.osx.a`);
        if (os.readable(builtins)) add(&args, builtins);
    }
    // debug builds export every symbol so the panic stack trace can name Helix functions; --strip keeps only the
    // symbols other code links to
    if (options.mode == ModeDebug && !options.strip) add(&args, "-export_dynamic");
    if (options.strip) add(&args, "-x");
    if (!runLinker(&args)) return false;
    if (debugInfo) {
        const dsym: string[2] = [findTool("dsymutil") ?? "dsymutil", output];
        if (os.run(&dsym) != 0) eprintln("warning: dsymutil failed; stack traces won't have line numbers");
    }
    return true;
}

/**
 * Compiles a program to an object file and links it into an executable.
 *
 * @param requested - The options of the build
 * @param output - The executable, or the object file with `--emit obj`
 * @returns `false` after reporting
 *
 * @remarks
 * The chip first fills in what the options leave out.
 * A program needs `main` unless it is a test build or an object file,
 * and a freestanding program can neither take an `Init` in `main` nor run tests.
 * The object file goes to the temporary folder, and the packages' C objects and libraries join the link list.
 * macOS links with ld64.lld, Linux and Windows with ld.lld, WASI with wasm-ld, and a freestanding target with ld.lld.
 * Other targets, such as Linux with the GNU C library, only build with `--emit obj`.
 *
 * @example
 * ```hx
 * let options = defaultOptions();
 * options.file = "hello.hx";
 * buildExecutable(&options, "hello"); // true, and ./hello runs
 * ```
 *
 * @since 1.0.0
 */

export function buildExecutable(requested: readonly *Options, output: string): bool {
    let chipped = *requested;
    if (!applyChip(&chipped)) return false;
    let options: readonly *Options = &chipped;
    const target = parseTarget(options.target);
    if (target == null) return false;
    let ok = false;
    const c = compileFront(options.file, true, options.test, target, &ok);
    if (ok && c.sema.entry == 0 && !options.test && !options.emitObject) {   // an object can be a library
        eprintln(`error: '${options.file}' has no \`main\` function`);
        eprintln("  = hint: add `export function main(): void { ... }`");
        ok = false;
    }
    if (ok && target.freestanding && c.sema.entryInit != 0) {   // `Init` holds the OS's arguments, allocators and streams
        eprintln(`error: a freestanding program's \`main\` takes no \`Init\`: there's no OS to make one`);
        eprintln("  = hint: `export function main(): void { ... }`; output goes through `helix_console_write` (lib/rt/freestanding.c)");
        ok = false;
    }
    if (ok && target.freestanding && options.test) {
        eprintln("error: `helix test` can't run tests without an OS: test the code for this machine, or in QEMU through `main`");
        ok = false;
    }
    if (!ok) {
        compilationFree(c);
        return false;
    }

    const module = os.fileStem(options.file);
    let cpu: ?readonly u8[*] = null;
    if (const name = options.cpu) cpu = toCString(name);
    const codegen = HxCodegenOptions {
        mode: options.mode, module_name: toCString(module), debugInfo: options.mode == ModeDebug && !options.strip,
        triple: target.host ? null : toCString(target.triple), cpu, freestanding: target.freestanding,
    };

    const object = options.emitObject ? output : allocCString(`${os.tempDir()}/helix-${os.pid()}-${module}.o`);
    let error: ?u8[*] = null;
    ok = hxCodegenObject(&c.sema, &codegen, toCString(object), &error);
    compilationFree(c);
    if (!ok) {
        eprintln(`error: ${fromCString(os.asReadonly(error))}`);
        free(error);
        return false;
    }
    if (options.emitObject) return true;
    let withPackages = *options;
    withPackages.links = strings();
    if (!packageLinks(options, target, &withPackages.links)) {
        os.unlink(object);
        return false;
    }
    for (const link of options.links.items) add(&withPackages.links, link);
    options = &withPackages;
    if (target.musl || target.windows || target.wasi || target.freestanding) {
        const linked = target.freestanding ? linkFreestanding(options, target, object, output)
                     : target.musl ? linkMusl(options, target, object, output)
                     : target.windows ? linkWindows(options, target, object, output)
                     : linkWasi(options, target, object, output);
        os.unlink(object);
        return linked;
    }
    if (!target.apple) {
        eprintln(`error: linking for ${options.target ?? target.triple} isn't supported yet`);
        eprintln("  = hint: `--emit obj` writes the object file; Linux targets link with `-musl` (the default), Windows with `-gnu`");
        os.unlink(object);
        return false;
    }
    const linked = linkMacos(options, target, object, output, codegen.debugInfo);
    os.unlink(object);
    return linked;
}
