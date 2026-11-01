/**
 * Imports
 */

import * as fs from "std/fs";
import * as fmt from "std/fmt";
import { Env } from "std/process";
import { ArrayList } from "std/list";
import { equal, endsWith } from "std/text";
import { Build, BuildError, Mode, Step } from "std/build";

/**
 * The platforms that a release is built for, each as the target that `--target` takes.
 *
 * @since 1.0.0
 */

const Platforms: string[6] = [
    "aarch64-macos", "x86_64-macos", "x86_64-linux", "aarch64-linux", "x86_64-windows", "aarch64-windows",
];

/**
 * Finds the toolchain of a platform: its static LLVM, its tools, and clang's headers.
 *
 * @param builder - The build, whose compiler the toolchain sits beside
 * @param platform - The platform, such as `x86_64-linux`
 * @returns The folder with `bin` and `lib`
 *
 * @remarks
 * It looks where the compiler looks when it links LLVM for a target:
 * `lib/llvm/<platform>` beside the compiler, then `$HELIX_HOME/llvm/<platform>`, then `~/.cache/helix/llvm/<platform>`.
 * Without one, it is the last folder that it looked in, so the release fails when it copies from there,
 * and only when the release runs.
 *
 * @since 1.0.0
 */

function toolchainDir(builder: *Build, platform: string): string | Error {
    let compilerDir = ".";
    for (const c, i of builder.helix) {
        if (c == '/') compilerDir = builder.helix[0..i];
    }
    const env = Env {};
    let candidates: string[3] = ["", "", ""];
    candidates[0] = try fmt.alloc(builder.a, `${compilerDir}/lib/llvm/${platform}`);
    if (const home = env.get("HELIX_HOME")) candidates[1] = try fmt.alloc(builder.a, `${home}/llvm/${platform}`);
    if (const home = env.get("HOME")) candidates[2] = try fmt.alloc(builder.a, `${home}/.cache/helix/llvm/${platform}`);
    let last = "";
    for (const dir of candidates) {
        if (dir.len == 0) continue;
        if (fs.exists(try fmt.alloc(builder.a, `${dir}/lib/libLLVMCore.a`))) return dir;
        last = dir;
    }
    return last;
}

/**
 * Finds the macOS SDK that a release takes its trimmed copy from.
 *
 * @param builder - The build
 * @returns The SDK folder
 *
 * @remarks
 * It looks where the compiler does: `$SDKROOT`, then Xcode's SDK, then the command-line tools' SDK.
 * Without one, it is the last of them, so the release fails when it copies from there,
 * and only when the release runs.
 *
 * @since 1.0.0
 */

function macosSdkDir(builder: *Build): string | Error {
    const candidates: string[3] = [
        Env {}.get("SDKROOT") ?? "",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    ];
    for (const dir of candidates) {
        if (dir.len > 0 && fs.exists(try fmt.alloc(builder.a, `${dir}/SDKSettings.json`))) return dir;
    }
    return candidates[2];
}

/**
 * Adds the trimmed macOS SDK of a release to the `release` step.
 *
 * @param builder - The build
 * @param release - The `release` step
 * @param dir - The release folder under `.helix-out`, such as `release/x86_64-linux`
 * @param sdk - The SDK to copy from, from {@link macosSdkDir}
 * @returns Nothing, or the error that stopped the build from recording a step
 *
 * @remarks
 * It goes into `lib/sdk/MacOSX.sdk`, where the compiler looks when there is no other SDK.
 * It holds what building for macOS reads: `SDKSettings.json` for the version, the headers in `usr/include`,
 * and the stubs that programs link against, `libSystem` with the libraries in `usr/lib/system`, and `libc++`.
 * Links in the SDK are copied as the files that they point to.
 *
 * @since 1.0.0
 */

function addMacosSdk(builder: *Build, release: Step, dir: string, sdk: string): void | Error {
    const out = try fmt.alloc(builder.a, `${dir}/lib/sdk/MacOSX.sdk`);
    try release.dependOn(try builder.addInstallFile(try fmt.alloc(builder.a, `${sdk}/SDKSettings.json`), out));
    const folders: string[2] = ["usr/include", "usr/lib/system"];
    for (const folder of folders) {
        const from = try fmt.alloc(builder.a, `${sdk}/${folder}`);
        try release.dependOn(try builder.addInstallFolder(from, try fmt.alloc(builder.a, `${out}/${folder}`)));
    }
    const stubs: string[9] = [
        "libSystem.tbd", "libSystem.B.tbd", "libc.tbd", "libm.tbd", "libpthread.tbd", "libdl.tbd",
        "libc++.tbd", "libc++.1.tbd", "libc++abi.tbd",
    ];
    for (const stub of stubs) {
        const from = try fmt.alloc(builder.a, `${sdk}/usr/lib/${stub}`);
        try release.dependOn(try builder.addInstallFile(from, try fmt.alloc(builder.a, `${out}/usr/lib`)));
    }
}

/**
 * Adds what a release for one platform holds to the `release` step.
 *
 * @param builder - The build
 * @param release - The `release` step
 * @param platform - The platform, such as `x86_64-linux`
 * @param toolchain - The platform's toolchain, from {@link toolchainDir}
 * @param sources - The source folders of the C libraries, from {@link sourceTrees}, which every platform ships
 * @param sdk - The macOS SDK to take the trimmed copy from
 * @returns Nothing, or the error that stopped the build from recording a step
 *
 * @remarks
 * The release goes into `.helix-out/release/<platform>`, laid out as the compiler expects next to itself:
 * - `helix`, in release-safe and stripped, with LLVM, libclang, and lld linked in
 * - `lib/std`, `lib/rt`, and `lib/chips` from this repository
 * - `lib/llvm/bin` with the tools that the compiler runs: clang, llvm-ar, llvm-dlltool, and dsymutil on macOS
 * - `lib/llvm/lib/clang` with clang's own headers
 * - `lib/sdk/MacOSX.sdk`, a trimmed macOS SDK, so that every platform builds for macOS (see {@link addMacosSdk})
 * - `lib/src` with the sources of musl, compiler-rt, and wasi-libc, unpacked,
 *   so building for a target needs no download and no `tar`
 * - `LICENSE`
 *
 * @since 1.0.0
 */

function addRelease(
    builder: *Build, release: Step, platform: string, toolchain: string, sources: readonly string[], sdk: string,
): void | Error {
    const dir = try fmt.alloc(builder.a, `release/${platform}`);
    const exe = endsWith(platform, "-windows") ? ".exe" : "";
    // the toolchain's files first, so a missing toolchain stops the release before the compiler builds
    const headers = try fmt.alloc(builder.a, `${toolchain}/lib/clang`);
    try release.dependOn(try builder.addInstallFolder(headers, try fmt.alloc(builder.a, `${dir}/lib/llvm/lib/clang`)));
    const bin = try fmt.alloc(builder.a, `${dir}/lib/llvm/bin`);
    const tools: string[4] = ["clang", "llvm-ar", "llvm-dlltool", "dsymutil"];
    for (const tool of tools) {
        const path = try fmt.alloc(builder.a, `${toolchain}/bin/${tool}${exe}`);
        if (equal(tool, "dsymutil") && !endsWith(platform, "-macos")) continue;   // only macOS keeps debug info apart
        try release.dependOn(try builder.addInstallFile(path, bin));
    }
    const compiler = try builder.addExecutable({
        name: "helix", root: "src/main.hx", mode: Mode.ReleaseSafe, target: platform, strip: true,
    });
    try release.dependOn(try builder.addInstall(compiler, dir));
    try release.dependOn(try builder.addInstallFile("LICENSE", dir));
    const folders: string[3] = ["lib/std", "lib/rt", "lib/chips"];
    for (const folder of folders) {
        try release.dependOn(try builder.addInstallFolder(folder, try fmt.alloc(builder.a, `${dir}/${folder}`)));
    }
    try addMacosSdk(builder, release, dir, sdk);
    for (const tree of sources) {
        let name = tree;
        for (const c, i of tree) {
            if (c == '/') name = tree[i + 1..];
        }
        try release.dependOn(try builder.addInstallFolder(tree, try fmt.alloc(builder.a, `${dir}/lib/src/${name}`)));
    }
}

/**
 * Lists the unpacked sources of the C libraries, which the compiler keeps in `$HELIX_HOME/src`.
 *
 * @param builder - The build
 * @returns The paths of the source folders, or none when the folder is missing
 *
 * @remarks
 * A release ships them in `lib/src`, where the compiler looks first,
 * so building for a target needs no download, `curl`, or `tar`.
 * Only a folder that the compiler finished unpacking counts, which a `.unpacked` file in it marks.
 * A build for each target fills the folder the first time that it needs a C library.
 *
 * @since 1.0.0
 */

function sourceTrees(builder: *Build): string[] | Error {
    const env = Env {};
    let home = "";
    if (const set = env.get("HELIX_HOME")) {
        home = set;
    } else if (const user = env.get("HOME")) {
        home = try fmt.alloc(builder.a, `${user}/.cache/helix`);
    }
    let found = ArrayList<string>.init(builder.a);
    const dir = try fmt.alloc(builder.a, `${home}/src`);
    if (!fs.exists(dir)) return found.items;
    let folder = try fs.Dir.open(dir);
    defer folder.close();
    while (const name = try folder.next()) {
        const tree = try fmt.alloc(builder.a, `${dir}/${name}`);
        if (fs.exists(try fmt.alloc(builder.a, `${tree}/.unpacked`))) try found.append(tree);
    }
    return found.items;
}

/**
 * The build script that `helix build` runs for the compiler.
 *
 * @param builder - The builder that records the artifacts and steps of this build
 * @returns Nothing, or the error that stopped the script from recording a step
 *
 * @remarks
 * The compiler is `src/main.hx`.
 * Its C and native libraries are declared in helix.jsonc:
 * `host.c` (what differs between macOS, Linux, and Windows) and LLVM with libclang,
 * which the compiler that runs the build takes from the toolchain's static LLVM for the target,
 * in `lib/llvm/<platform>` beside it or in `$HELIX_HOME/llvm/<platform>`,
 * and otherwise from the folder of the LLVM it is linked to itself.
 * The built compiler finds the standard library in the `lib` folder of this repository, two folders above
 * `.helix-out/bin`, and builds its runtime from `lib/rt` the first time it needs it.
 *
 * - **install** - the default step, which builds `.helix-out/bin/helix`
 * - **run** - builds the compiler and runs it, passing on the arguments after `--`
 * - **test** - installs the compiler, then runs the specs in `src` and `lib` with it,
 *   so the specs exercise the compiler this build just made
 * - **e2e** - installs the compiler, then checks that it builds, rejects, and tests each snippet in
 *   `e2e` as the snippet says (`e2e/main.hx`)
 * - **release** - builds a release for every platform into `.helix-out/release/<platform>`: the compiler with
 *   LLVM and lld inside, and everything that it needs beside it, so it builds for every target with nothing installed.
 *   `--platform=<platform>` builds one platform only.
 *   Each platform needs its toolchain in `$HELIX_HOME/llvm/<platform>`, as {@link toolchainDir} says
 *
 * @example
 * ```bash
 * helix build                   # .helix-out/bin/helix
 * helix build run -- version    # helix 1.0.0-alpha.0 (LLVM 23.1.4)
 * helix build test              # Tests:  1980 passed, 1980 total
 * helix build e2e               # E2E:  ... passed
 * helix build release           # .helix-out/release/<platform>, for all six
 * helix build release --platform=x86_64-linux
 * ```
 *
 * @see Build
 * @since 1.0.0
 */

export function build(builder: *Build): void | Error {
    const executable = try builder.addExecutable({ name: "helix", root: "src/main.hx" });
    try builder.install(executable);
    try builder.addRunStep(executable);

    const installed = Step { b: builder, index: 0 };   // step 0 is `install`
    const specs = try builder.addSystemCommand([".helix-out/bin/helix", "test", "src", "lib"]);
    try specs.dependOn(installed);
    const snippets = try builder.addSystemCommand([".helix-out/bin/helix", "run", "e2e/main.hx", "--", ".helix-out/bin/helix"]);
    try snippets.dependOn(installed);

    const e2e = try builder.step("e2e", "Build the compiler, then check it against the snippets in e2e");
    try e2e.dependOn(snippets);
    const test = try builder.step("test", "Build the compiler, then run the specs in src and lib with it");
    try test.dependOn(specs);

    const only = builder.optionString("platform", "Build the release for this platform only, such as x86_64-linux");
    const release = try builder.step("release", "Build the compiler and what it needs for each platform");
    const sources = try sourceTrees(builder);
    const sdk = try macosSdkDir(builder);
    let known = false;
    for (const platform of Platforms) {
        if (const chosen = only) {
            if (!equal(chosen, platform)) continue;
        }
        known = true;
        try addRelease(builder, release, platform, try toolchainDir(builder, platform), sources, sdk);
    }
    if (!known) {
        eprintln(`error: --platform takes one of ${Platforms}`);
        throw BuildError.BadOption;
    }
}
