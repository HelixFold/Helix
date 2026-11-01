/**
 * Imports
 */

import { Allocator, ArenaAllocator, alloc, cAllocator } from "./heap";
import { ArrayList } from "./list";
import { Init, exit } from "./process";
import * as process from "./process";
import * as fmt from "./fmt";
import * as fs from "./fs";
import { equal, startsWith, indexOf, split, lines, parseInt } from "./text";

/**
 * The errors of a build.
 *
 * @remarks
 * The calls of build.hx throw `BadOption`, a failed command throws `StepFailed`,
 * and a packages list that `helix build` did not write throws `BadPackageList`.
 *
 * @example
 * ```hx
 * const app = try b.bin("ghost"); // BuildError.BadOption when helix.jsonc has no program named ghost
 * ```
 *
 * @since 1.0.0
 */

export error BuildError {
    /**
     * A step that the build does not have.
     *
     * @remarks
     * Nothing throws it at the moment, since {@link runBuild} reports an unknown step and returns 2 instead.
     *
     * @example
     * ```hx
     * @errorName(BuildError.UnknownStep); // "UnknownStep"
     * ```
     *
     * @since 1.0.0
     */

    UnknownStep,

    /**
     * A command of a step exited with a status other than 0.
     *
     * @remarks
     * The command already printed its own errors, so {@link runBuild} prints nothing more and returns 1.
     *
     * @example
     * ```hx
     * helix build check; // 1 when a command of check fails
     * ```
     *
     * @since 1.0.0
     */

    StepFailed,

    /**
     * A call of build.hx asked for something that the build cannot do.
     *
     * @remarks
     * It covers a program that helix.jsonc does not name, an executable added twice from two roots,
     * and a step added twice under one name.
     * The call prints the reason on stderr first.
     *
     * @example
     * ```hx
     * try b.step("gen", "Generate");
     * try b.step("gen", "Generate again"); // BuildError.BadOption
     * ```
     *
     * @since 1.0.0
     */

    BadOption,

    /**
     * The packages list holds a line that does not start with `bin`.
     *
     * @example
     * ```hx
     * // packages.txt: lib<tab>-<tab>x<tab>src/x.hx
     * runBuild(init, build); // BuildError.BadPackageList
     * ```
     *
     * @since 1.0.0
     */

    BadPackageList
}

/**
 * The build modes, as `helix build --mode` names them.
 *
 * @remarks
 * The mode decides the optimization of the Helix code and of the C files of an artifact.
 *
 * @example
 * ```hx
 * b.mode == Mode.Debug; // true without --mode
 * ```
 *
 * @since 1.0.0
 */

export enum Mode {
    /**
     * No optimization and full debug info, named `debug`.
     *
     * @remarks
     * It is the mode without `--mode`, and C files get `-O0 -g`.
     *
     * @example
     * ```hx
     * b.mode; // Mode.Debug for helix build
     * ```
     *
     * @since 1.0.0
     */

    Debug,

    /**
     * Optimized code that keeps its safety checks, named `release-safe`.
     *
     * @remarks
     * C files get `-O2`.
     *
     * @example
     * ```hx
     * b.mode; // Mode.ReleaseSafe for helix build --mode release-safe
     * ```
     *
     * @since 1.0.0
     */

    ReleaseSafe,

    /**
     * The fastest code, named `release-fast`.
     *
     * @remarks
     * C files get `-O3`.
     *
     * @example
     * ```hx
     * b.mode; // Mode.ReleaseFast for helix build --mode release-fast
     * ```
     *
     * @since 1.0.0
     */

    ReleaseFast,

    /**
     * The smallest code, named `release-small`.
     *
     * @remarks
     * C files get `-Os`.
     *
     * @example
     * ```hx
     * b.mode; // Mode.ReleaseSmall for helix build --mode release-small
     * ```
     *
     * @since 1.0.0
     */

    ReleaseSmall
}

/**
 * Every mode, in the order of {@link Mode}.
 *
 * @remarks
 * {@link modeNamed} searches it for the name that `--mode` gives.
 *
 * @since 1.0.0
 */

const Modes: Mode[4] = [Mode.Debug, Mode.ReleaseSafe, Mode.ReleaseFast, Mode.ReleaseSmall];

/**
 * Returns the name of a mode, as `--mode` spells it.
 *
 * @param mode - The mode
 * @returns The name, such as `release-fast`
 *
 * @remarks
 * The name also forms a folder of the cache, so artifacts of different modes never share a path.
 *
 * @since 1.0.0
 */

function modeName(mode: Mode): string {
    return switch (mode) {
        case Mode.Debug: "debug";
        case Mode.ReleaseSafe: "release-safe";
        case Mode.ReleaseFast: "release-fast";
        case Mode.ReleaseSmall: "release-small";
    };
}

/**
 * Returns the optimization flag of the C compiler for a mode.
 *
 * @param mode - The mode
 * @returns `-O0`, `-O2`, `-O3`, or `-Os`
 *
 * @remarks
 * {@link compileC} passes it to `helix cc`, and adds `-g` in debug mode.
 *
 * @since 1.0.0
 */

function cOptimization(mode: Mode): string {
    return switch (mode) {
        case Mode.Debug: "-O0";
        case Mode.ReleaseSafe: "-O2";
        case Mode.ReleaseFast: "-O3";
        case Mode.ReleaseSmall: "-Os";
    };
}

/**
 * The settings of an executable that build.hx adds with {@link Build.addExecutable}.
 *
 * @remarks
 * Only the name and the root are required.
 * Every other setting left as null falls back to the build, or to the machine where noted.
 *
 * @example
 * ```hx
 * const tool = try b.addExecutable({ name: "tool", root: "tools/tool.hx", mode: Mode.ReleaseFast });
 * ```
 *
 * @since 1.0.0
 */

export struct ExecutableOptions {
    /**
     * The name of the executable, which also names its file.
     *
     * @example
     * ```hx
     * options.name; // "tool", built as tool, or tool.exe for Windows
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The file with `main`.
     *
     * @example
     * ```hx
     * options.root; // "tools/tool.hx"
     * ```
     *
     * @since 1.0.0
     */

    root: string,

    /**
     * The target as `arch-os[-abi]`, or null for the target of the build.
     *
     * @remarks
     * `native` means this machine.
     *
     * @example
     * ```hx
     * options.target; // "x86_64-linux-gnu"
     * ```
     *
     * @since 1.0.0
     */

    target: ?string = null,

    /**
     * The mode, or null for the mode of the build.
     *
     * @example
     * ```hx
     * options.mode; // Mode.ReleaseSmall
     * ```
     *
     * @since 1.0.0
     */

    mode: ?Mode = null,

    /**
     * Whether to leave out the debug info and the symbols.
     *
     * @example
     * ```hx
     * options.strip; // false
     * ```
     *
     * @since 1.0.0
     */

    strip: bool = false,

    /**
     * The CPU to build for, as `native`, `generic`, or a CPU name such as `apple-m1` or `x86-64-v3`.
     *
     * @remarks
     * Null means native for this machine, and generic for another target.
     *
     * @example
     * ```hx
     * options.cpu; // "apple-m1"
     * ```
     *
     * @since 1.0.0
     */

    cpu: ?string = null,

    /**
     * The linker script of an `<arch>-freestanding` program, which says where the program goes in memory.
     *
     * @remarks
     * Null means the QEMU `virt` machine, or for Cortex-M a script made from the `chip` of helix.jsonc.
     *
     * @example
     * ```hx
     * options.linkerScript; // "boards/link.ld"
     * ```
     *
     * @since 1.0.0
     */

    linkerScript: ?string = null,
}

/**
 * The settings of the `test` step that build.hx adds with {@link Build.addTestStep}.
 *
 * @remarks
 * Only the root is required.
 * The target and the mode left as null fall back to the build.
 *
 * @example
 * ```hx
 * try b.addTestStep({ root: "specs", linkWith: app });
 * ```
 *
 * @since 1.0.0
 */

export struct TestOptions {
    /**
     * The spec file, or a folder of them.
     *
     * @example
     * ```hx
     * options.root; // "src"
     * ```
     *
     * @since 1.0.0
     */

    root: string,

    /**
     * The target, or null for the target of the build.
     *
     * @example
     * ```hx
     * options.target; // "x86_64-linux-gnu"
     * ```
     *
     * @since 1.0.0
     */

    target: ?string = null,

    /**
     * The mode, or null for the mode of the build.
     *
     * @example
     * ```hx
     * options.mode; // Mode.ReleaseSafe
     * ```
     *
     * @since 1.0.0
     */

    mode: ?Mode = null,

    /**
     * An artifact whose C files, libraries, and options modules the specs also get.
     *
     * @remarks
     * It is for specs that import the code of the artifact.
     *
     * @example
     * ```hx
     * options.linkWith; // the artifact from b.bin("app")
     * ```
     *
     * @since 1.0.0
     */

    linkWith: ?Artifact = null,
}

/**
 * C files to compile into an artifact, with the flags that they share.
 *
 * @remarks
 * {@link Artifact.addCSources} takes it, and each file becomes its own object.
 *
 * @example
 * ```hx
 * try app.addCSources(CSources { files: ["c/zlib.c"], flags: ["-DFAST"] });
 * ```
 *
 * @since 1.0.0
 */

export struct CSources {
    /**
     * The paths of the C files.
     *
     * @example
     * ```hx
     * sources.files; // ["c/a.c", "c/b.c"]
     * ```
     *
     * @since 1.0.0
     */

    files: readonly string[],

    /**
     * The flags that the C compiler gets for each file.
     *
     * @example
     * ```hx
     * sources.flags; // ["-DFAST"]
     * ```
     *
     * @since 1.0.0
     */

    flags: readonly string[] = [],
}

/**
 * One C file of an artifact, with its flags.
 *
 * @remarks
 * {@link Artifact.addCSources} records one for each file of a {@link CSources}.
 *
 * @since 1.0.0
 */

struct CFile {
    /**
     * The path of the C file.
     *
     * @since 1.0.0
     */

    path: string,

    /**
     * The flags that the C compiler gets for the file.
     *
     * @since 1.0.0
     */

    flags: readonly string[],
}

/**
 * Everything that the build records about one executable.
 *
 * @remarks
 * An {@link Artifact} handle points at one by index into the artifacts of the build.
 *
 * @since 1.0.0
 */

struct ArtifactData {
    /**
     * The name of the executable.
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The file with `main`.
     *
     * @since 1.0.0
     */

    root: string,

    /**
     * The target, or null for this machine.
     *
     * @since 1.0.0
     */

    target: ?string,

    /**
     * The mode.
     *
     * @since 1.0.0
     */

    mode: Mode,

    /**
     * Whether to leave out the debug info and the symbols.
     *
     * @since 1.0.0
     */

    strip: bool,

    /**
     * The CPU to build for, or null for the default.
     *
     * @since 1.0.0
     */

    cpu: ?string,

    /**
     * The linker script, or null for the default.
     *
     * @since 1.0.0
     */

    linkerScript: ?string,

    /**
     * The indices of the options modules that the artifact imports.
     *
     * @since 1.0.0
     */

    options: ArrayList<usize>,

    /**
     * The C files to compile and link in.
     *
     * @since 1.0.0
     */

    cFiles: ArrayList<CFile>,

    /**
     * The folders that the C compiler searches for includes.
     *
     * @since 1.0.0
     */

    includeDirs: ArrayList<string>,

    /**
     * The system libraries to link with.
     *
     * @since 1.0.0
     */

    libraries: ArrayList<string>,

    /**
     * The path where the executable is built, in `.helix-cache`.
     *
     * @since 1.0.0
     */

    output: string,

    /**
     * Whether this run already built the executable.
     *
     * @since 1.0.0
     */

    built: bool,
}

/**
 * An executable that build.hx asked for.
 *
 * @remarks
 * It is a handle, an index into the artifacts of the build, so it stays valid as more artifacts are added.
 * {@link Build.bin} returns one for a program of helix.jsonc and {@link Build.addExecutable} for any other.
 *
 * @example
 * ```hx
 * const app = try b.bin("app");
 * try app.linkSystemLibrary("z"); // app now links with -lz
 * ```
 *
 * @since 1.0.0
 */

export struct Artifact {
    /**
     * The build that owns the artifact.
     *
     * @example
     * ```hx
     * app.b; // the build that build(b) received
     * ```
     *
     * @since 1.0.0
     */

    b: *Build,

    /**
     * The position of the artifact in the artifacts of the build.
     *
     * @example
     * ```hx
     * (try b.bin("app")).index; // 0 for the first program of helix.jsonc
     * ```
     *
     * @since 1.0.0
     */

    index: usize,

    /**
     * Adds C files that are compiled with the target and the mode of the artifact and linked into it.
     *
     * @param this - The artifact
     * @param sources - The files and their flags
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * Each file becomes the object `.helix-cache/c/<target>/<mode>/<name>.c/<n>.o`, compiled once per run.
     * The include folders from {@link Artifact.addIncludeDir} come before the flags of the file.
     *
     * @example
     * ```hx
     * try app.addCSources(CSources { files: ["c/a.c"], flags: ["-DFAST"] });
     * // helix cc -c c/a.c -o .helix-cache/c/host/debug/app.c/0.o -O0 -g -DFAST
     * ```
     *
     * @since 1.0.0
     */

    addCSources(this: Artifact, sources: CSources): void | Error {
        for (const file of sources.files) {
            try this.b.artifacts.items[this.index].cFiles.append(CFile { path: file, flags: sources.flags });
        }
    }

    /**
     * Adds a folder that the C compiler searches for the includes of the C files of this artifact.
     *
     * @param this - The artifact
     * @param path - The folder
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * Every C file of the artifact gets it as `-I<path>`, whenever the file was added.
     *
     * @example
     * ```hx
     * try app.addIncludeDir("include"); // the C compiler gets -Iinclude
     * ```
     *
     * @since 1.0.0
     */

    addIncludeDir(this: Artifact, path: string): void | Error {
        try this.b.artifacts.items[this.index].includeDirs.append(path);
    }

    /**
     * Links a library that the system provides.
     *
     * @param this - The artifact
     * @param name - The name of the library, without the `lib` prefix
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * The compiler gets it as `-l<name>` when it builds the artifact.
     *
     * @example
     * ```hx
     * try app.linkSystemLibrary("z"); // -lz
     * ```
     *
     * @since 1.0.0
     */

    linkSystemLibrary(this: Artifact, name: string): void | Error {
        try this.b.artifacts.items[this.index].libraries.append(name);
    }

    /**
     * Lets the code of the artifact import an options module by its name.
     *
     * @param this - The artifact
     * @param options - The module from {@link Build.addOptions}
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * The module is written to `.helix-cache/options/<name>.hx` when the artifact is built,
     * and the compiler gets it as `--pkg <name>=<path>`.
     *
     * @example
     * ```hx
     * try app.addOptions(config); // the program can now import { tracing } from "config"
     * ```
     *
     * @since 1.0.0
     */

    addOptions(this: Artifact, options: Options): void | Error {
        try this.b.artifacts.items[this.index].options.append(options.index);
    }
}

/**
 * The name and the lines of one options module.
 *
 * @remarks
 * An {@link Options} handle points at one by index into the options modules of the build.
 *
 * @since 1.0.0
 */

struct OptionsData {
    /**
     * The name that programs import the module by.
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The lines of the module, each one an `export const` declaration.
     *
     * @since 1.0.0
     */

    lines: ArrayList<string>,
}

/**
 * Values from the build that a program can read as constants, from a module that build.hx generates.
 *
 * @remarks
 * It is a handle, an index into the options modules of the build.
 * Each `add` call adds one `export const` line,
 * and {@link Artifact.addOptions} lets an artifact import the module by its name.
 *
 * @example
 * ```hx
 * const config = try b.addOptions("config");
 * try config.addBool("tracing", true);
 * try app.addOptions(config); // the program reads import { tracing } from "config"
 * ```
 *
 * @since 1.0.0
 */

export struct Options {
    /**
     * The build that owns the module.
     *
     * @example
     * ```hx
     * config.b; // the build that build(b) received
     * ```
     *
     * @since 1.0.0
     */

    b: *Build,

    /**
     * The position of the module in the options modules of the build.
     *
     * @example
     * ```hx
     * (try b.addOptions("config")).index; // 0 for the first module
     * ```
     *
     * @since 1.0.0
     */

    index: usize,

    /**
     * Adds a `bool` constant.
     *
     * @param this - The module
     * @param name - The name of the constant
     * @param value - The value
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * The name goes into the module as it is, so it must be a valid Helix name.
     *
     * @example
     * ```hx
     * try config.addBool("tracing", true); // export const tracing: bool = true;
     * ```
     *
     * @since 1.0.0
     */

    addBool(this: Options, name: string, value: bool): void | Error {
        try this.add(try fmt.alloc(this.b.a, `export const ${name}: bool = ${value};`));
    }

    /**
     * Adds an `i64` constant.
     *
     * @param this - The module
     * @param name - The name of the constant
     * @param value - The value
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * The name goes into the module as it is, so it must be a valid Helix name.
     *
     * @example
     * ```hx
     * try config.addInt("port", 8080); // export const port: i64 = 8080;
     * ```
     *
     * @since 1.0.0
     */

    addInt(this: Options, name: string, value: i64): void | Error {
        try this.add(try fmt.alloc(this.b.a, `export const ${name}: i64 = ${value};`));
    }

    /**
     * Adds a `string` constant.
     *
     * @param this - The module
     * @param name - The name of the constant
     * @param value - The value
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * The value is escaped with {@link escape}, so quotes, backslashes, newlines, tabs, and carriage returns survive.
     *
     * @example
     * ```hx
     * try config.addString("greeting", "hi"); // export const greeting: string = "hi";
     * ```
     *
     * @since 1.0.0
     */

    addString(this: Options, name: string, value: string): void | Error {
        try this.add(try fmt.alloc(this.b.a, `export const ${name}: string = "${try escape(this.b.a, value)}";`));
    }

    /**
     * Adds a line of Helix code to the module as it is.
     *
     * @param this - The module
     * @param line - The line, without a newline
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * It is for a constant of a type that the other methods do not cover.
     * The line is not checked until the program that imports the module compiles.
     *
     * @example
     * ```hx
     * try config.add("export const level: u8 = 3;"); // the line as it is
     * ```
     *
     * @since 1.0.0
     */

    add(this: Options, line: string): void | Error {
        try this.b.optionModules.items[this.index].lines.append(line);
    }
}

/**
 * Escapes text for the inside of a Helix string literal.
 *
 * @param a - The allocator for the result
 * @param text - The text to escape
 * @returns The escaped text, or `AllocError.OutOfMemory`
 *
 * @remarks
 * It escapes the backslash, the double quote, the newline, the tab, and the carriage return.
 * Other control bytes pass through as they are.
 * A first pass counts the size, so the result takes one allocation.
 *
 * @since 1.0.0
 */

function escape(a: dyn Allocator, text: string): string | Error {
    let size: usize = 0;
    for (const c of text) size += c == '\\' || c == '"' || c == '\n' || c == '\t' || c == '\r' ? 2 : 1;
    const out = try alloc<u8>(a, size);
    let n: usize = 0;
    for (const c of text) {
        const pair: ?u8 = c == '\\' ? '\\' : c == '"' ? '"' : c == '\n' ? 'n' : c == '\t' ? 't' : c == '\r' ? 'r' : null;
        if (const p = pair) {
            out[n] = '\\';
            out[n + 1] = p;
            n += 2;
        } else {
            out[n] = c;
            n += 1;
        }
    }
    return out;
}

/**
 * The kinds of step, which decide what a step does when it runs.
 *
 * @since 1.0.0
 */

enum StepKind {
    /**
     * A step that does nothing itself and only runs its dependencies.
     *
     * @since 1.0.0
     */

    Group,

    /**
     * A step that builds an artifact and copies it into a folder of `.helix-out`.
     *
     * @since 1.0.0
     */

    Install,

    /**
     * A step that builds an artifact and runs it with the arguments after `--`.
     *
     * @since 1.0.0
     */

    Run,

    /**
     * A step that runs `helix test`.
     *
     * @since 1.0.0
     */

    Test,

    /**
     * A step that runs a program.
     *
     * @since 1.0.0
     */

    Command
}

/**
 * Everything that the build records about one step.
 *
 * @remarks
 * A {@link Step} handle points at one by index into the steps of the build.
 * Only some fields matter for each kind, and the rest hold placeholders.
 *
 * @since 1.0.0
 */

struct StepData {
    /**
     * The name that `helix build <name>` asks for, or an empty string for a step that only others depend on.
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The description that `--help` and `--steps` show.
     *
     * @since 1.0.0
     */

    description: string,

    /**
     * What the step does.
     *
     * @since 1.0.0
     */

    kind: StepKind,

    /**
     * The index of the artifact of an install step or a run step.
     *
     * @since 1.0.0
     */

    artifact: usize,

    /**
     * The settings of a test step.
     *
     * @since 1.0.0
     */

    test: TestOptions,

    /**
     * The command line of a command step, or the folder in `.helix-out` as the one word of an install step.
     *
     * @since 1.0.0
     */

    argv: readonly string[],

    /**
     * The indices of the steps that run first.
     *
     * @since 1.0.0
     */

    deps: ArrayList<usize>,

    /**
     * Whether this run already performed the step.
     *
     * @since 1.0.0
     */

    done: bool,
}

/**
 * A step of the build.
 *
 * @remarks
 * It is a handle, an index into the steps of the build.
 * A named step can be asked for with `helix build <name>`,
 * and an unnamed one runs only when a named step depends on it.
 *
 * @example
 * ```hx
 * const gen = try b.step("gen", "Generate the code");
 * try gen.dependOn(try b.addSystemCommand(["python3", "gen.py"])); // helix build gen runs gen.py
 * ```
 *
 * @since 1.0.0
 */

export struct Step {
    /**
     * The build that owns the step.
     *
     * @example
     * ```hx
     * gen.b; // the build that build(b) received
     * ```
     *
     * @since 1.0.0
     */

    b: *Build,

    /**
     * The position of the step in the steps of the build.
     *
     * @example
     * ```hx
     * gen.index; // 4 for a project with one program
     * ```
     *
     * @since 1.0.0
     */

    index: usize,

    /**
     * Makes this step run another step first.
     *
     * @param this - The step that waits
     * @param other - The step that runs first
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * Dependencies run in the order that they were added, and each step runs at most once per build.
     * Nothing checks for a cycle, so two steps that depend on each other recurse until the stack overflows.
     *
     * @example
     * ```hx
     * try second.dependOn(first); // first runs before second
     * ```
     *
     * @since 1.0.0
     */

    dependOn(this: Step, other: Step): void | Error {
        try this.b.steps.items[this.index].deps.append(other.index);
    }
}

/**
 * A name and a value, used for the `--name=value` options of build.hx and for the programs of helix.jsonc.
 *
 * @remarks
 * For a program the name is the name of the program and the value is its root.
 *
 * @since 1.0.0
 */

struct Define {
    /**
     * The name of the option, or of the program.
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The value of the option, or the root of the program.
     *
     * @since 1.0.0
     */

    value: string,
}

/**
 * An option that build.hx declared, for `--help` and to catch a misspelled option.
 *
 * @remarks
 * {@link Build.declare} records one the first time that build.hx asks for a name.
 *
 * @since 1.0.0
 */

struct Declared {
    /**
     * The name of the option.
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The kind of value, which is `bool`, `string`, or `int`.
     *
     * @since 1.0.0
     */

    kind: string,

    /**
     * The description that `--help` shows.
     *
     * @since 1.0.0
     */

    description: string,
}

/**
 * What build.hx describes, filled in by its `build(b)` and then performed by the runner.
 *
 * @remarks
 * helix.jsonc declares the programs.
 * With or without a build.hx, the runner builds and installs each `bin`,
 * gives the first one a `run` step, and tests `src/` in a `test` step.
 * build.hx adds to that: options, C sources, code generators, programs that are not shipped, and steps of its own.
 * A `run` or `test` step of its own replaces the default one.
 *
 * `--target` and `--mode` belong to the runner, and build.hx reads them as `b.target` and `b.mode`.
 * Any other `--name=value` is an option that build.hx declares.
 *
 * `helix build` compiles build.hx with the runner of this module and runs it.
 * The `build` function only records options, artifacts, and steps.
 * The runner then performs the steps named on the command line, or `install` when none are,
 * each one after its dependencies, by calling `helix` and `helix cc`.
 * `helix build --help` lists the steps and the options.
 *
 * @example
 * ```hx
 * // helix.jsonc: "bin": { "app": "src/main.hx" }
 *
 * // build.hx
 * import { Build } from "std/build";
 *
 * export function build(b: *Build): void | Error {
 *     const tracing = b.optionBool("tracing", "Log every request") ?? false;
 *
 *     const config = try b.addOptions("config");  // import { tracing } from "config" in the program
 *     try config.addBool("tracing", tracing);
 *
 *     const app = try b.bin("app");               // the program of helix.jsonc, to add to
 *     try app.addOptions(config);
 * }
 * ```
 *
 * @since 1.0.0
 */

export struct Build {
    /**
     * The allocator for everything that the build records.
     *
     * @remarks
     * It is an arena that {@link runBuild} frees at the end, so nothing that the build allocates needs a free.
     *
     * @example
     * ```hx
     * const path = try fmt.alloc(b.a, `gen/${name}.hx`); // freed with the build
     * ```
     *
     * @since 1.0.0
     */

    a: dyn Allocator,

    /**
     * The path of the `helix` compiler that runs the commands.
     *
     * @example
     * ```hx
     * b.helix; // "/usr/local/bin/helix"
     * ```
     *
     * @since 1.0.0
     */

    helix: string,

    /**
     * Whether `-v` asked to print each command before it runs.
     *
     * @example
     * ```hx
     * b.verbose; // true for helix build -v
     * ```
     *
     * @since 1.0.0
     */

    verbose: bool,

    /**
     * The target that `--target arch-os[-abi]` names.
     *
     * @remarks
     * Null means this machine, or the `chip` of helix.jsonc.
     *
     * @example
     * ```hx
     * b.target; // "x86_64-linux-gnu" for helix build --target x86_64-linux-gnu
     * ```
     *
     * @since 1.0.0
     */

    target: ?string,

    /**
     * The mode that `--mode` names, which is debug without it.
     *
     * @example
     * ```hx
     * b.mode; // Mode.ReleaseFast for helix build --mode release-fast
     * ```
     *
     * @since 1.0.0
     */

    mode: Mode,

    /**
     * The options of the command line that build.hx declares, in order.
     *
     * @remarks
     * A `--name` without a value holds `true`.
     *
     * @example
     * ```hx
     * b.defines.items.len; // 2 for helix build --fast --level=3
     * ```
     *
     * @since 1.0.0
     */

    defines: ArrayList<Define>,

    /**
     * The options that build.hx declared, in the order that it first asked for them.
     *
     * @example
     * ```hx
     * b.declared.items.len; // 1 after b.optionBool("fast", "Build for speed")
     * ```
     *
     * @since 1.0.0
     */

    declared: ArrayList<Declared>,

    /**
     * The programs of the `bin` of helix.jsonc, each with its name and its root.
     *
     * @example
     * ```hx
     * b.bins.items.len; // 1 for "bin": { "app": "src/main.hx" }
     * ```
     *
     * @since 1.0.0
     */

    bins: ArrayList<Define>,

    /**
     * The options modules from {@link Build.addOptions}.
     *
     * @example
     * ```hx
     * b.optionModules.items.len; // 1 after b.addOptions("config")
     * ```
     *
     * @since 1.0.0
     */

    optionModules: ArrayList<OptionsData>,

    /**
     * The arguments after `--`, which the `run` step passes to the program.
     *
     * @example
     * ```hx
     * b.runArgs; // ["one", "two"] for helix build run -- one two
     * ```
     *
     * @since 1.0.0
     */

    runArgs: readonly string[],

    /**
     * The executables, starting with the programs of helix.jsonc in their order.
     *
     * @example
     * ```hx
     * b.artifacts.items.len; // 1 for a project with one program and no build.hx
     * ```
     *
     * @since 1.0.0
     */

    artifacts: ArrayList<ArtifactData>,

    /**
     * The steps, starting with `install`.
     *
     * @example
     * ```hx
     * b.steps.items.len; // 4 for one program: install, its install step, run, and test
     * ```
     *
     * @since 1.0.0
     */

    steps: ArrayList<StepData>,

    /**
     * The C objects that this run already compiled.
     *
     * @remarks
     * {@link compileC} checks it, so an object that two steps need is compiled once.
     *
     * @example
     * ```hx
     * b.compiled.items; // [".helix-cache/c/host/debug/app.c/0.o"]
     * ```
     *
     * @since 1.0.0
     */

    compiled: ArrayList<string>,

    /**
     * The indices of the `run` and `test` steps of the runner, which build.hx's own steps replace.
     *
     * @example
     * ```hx
     * b.defaults.items.len; // 2 before build.hx adds a run or test step
     * ```
     *
     * @since 1.0.0
     */

    defaults: ArrayList<usize>,

    /**
     * Declares an option and returns its value on the command line.
     *
     * @param this - The build
     * @param name - The name of the option
     * @param kind - The kind of value that `--help` shows
     * @param description - The description that `--help` shows
     * @returns The text after `--name=`, `true` for a bare `--name`, or null when the command line leaves it out
     *
     * @remarks
     * The first call for a name records the option, so `--help` lists it and the runner accepts its `--name`.
     * Later calls for the same name keep the first kind and description.
     * When the command line repeats an option, the first one wins.
     * The typed methods {@link Build.optionBool}, {@link Build.optionString}, and {@link Build.optionInt} call it.
     * It ends the process with status 2 when there is no memory to record the option.
     *
     * @example
     * ```hx
     * b.declare("level", "string", "How loud to be"); // "high" for helix build --level=high
     * ```
     *
     * @since 1.0.0
     */

    declare(this: *Build, name: string, kind: string, description: string): ?string {
        let known = false;
        for (const d of this.declared.items) known = known || equal(d.name, name);
        if (!known) {
            this.declared.append(Declared { name, kind, description }) catch {
                eprintln("error: out of memory");
                exit(2);
            };
        }
        for (const d of this.defines.items) {
            if (equal(d.name, name)) return d.value;
        }
        return null;
    }

    /**
     * Declares a bool option and returns its value.
     *
     * @param this - The build
     * @param name - The name of the option
     * @param description - The description that `--help` shows
     * @returns `true` for `--name` or `--name=true`, `false` for `--name=false`, or null when the option is left out
     *
     * @remarks
     * Any other value prints an error and ends the process with status 2.
     *
     * @example
     * ```hx
     * const tracing = b.optionBool("tracing", "Log every request") ?? false; // true for --tracing
     * ```
     *
     * @since 1.0.0
     */

    optionBool(this: *Build, name: string, description: string): ?bool {
        if (const value = this.declare(name, "bool", description)) {
            if (equal(value, "true")) return true;
            if (equal(value, "false")) return false;
            eprintln(`error: --${name} takes true or false, not '${value}'`);
            exit(2);
        }
        return null;
    }

    /**
     * Declares a string option and returns its value.
     *
     * @param this - The build
     * @param name - The name of the option
     * @param description - The description that `--help` shows
     * @returns The text after `--name=`, or null when the option is left out
     *
     * @remarks
     * The text runs to the end of the argument, so it may hold more `=` signs.
     * A bare `--name` gives `true`.
     *
     * @example
     * ```hx
     * b.optionString("name", "The name to greet"); // "ada" for --name=ada
     * ```
     *
     * @since 1.0.0
     */

    optionString(this: *Build, name: string, description: string): ?string {
        return this.declare(name, "string", description);
    }

    /**
     * Declares an int option and returns its value.
     *
     * @param this - The build
     * @param name - The name of the option
     * @param description - The description that `--help` shows
     * @returns The whole number after `--name=`, or null when the option is left out
     *
     * @remarks
     * A value that is not a whole number prints an error and ends the process with status 2.
     *
     * @example
     * ```hx
     * b.optionInt("jobs", "How many jobs"); // 8 for --jobs=8
     * ```
     *
     * @since 1.0.0
     */

    optionInt(this: *Build, name: string, description: string): ?i64 {
        if (const value = this.declare(name, "int", description)) {
            return parseInt(value) catch {
                eprintln(`error: --${name} takes a whole number, not '${value}'`);
                exit(2);
            };
        }
        return null;
    }

    /**
     * Adds a module of constants that artifacts can import by its name.
     *
     * @param this - The build
     * @param name - The name that programs import the module by
     * @returns The module, or `AllocError.OutOfMemory`
     *
     * @remarks
     * The module stays empty until its `add` methods fill it,
     * and an artifact sees it only after {@link Artifact.addOptions}.
     *
     * @example
     * ```hx
     * const config = try b.addOptions("config"); // config.index is 0 for the first module
     * ```
     *
     * @since 1.0.0
     */

    addOptions(this: *Build, name: string): Options | Error {
        try this.optionModules.append(OptionsData { name, lines: ArrayList<string>.init(this.a) });
        return Options { b: this, index: this.optionModules.items.len - 1 };
    }

    /**
     * Returns the program of the `bin` of helix.jsonc with the given name.
     *
     * @param this - The build
     * @param name - The name of the program
     * @returns The artifact that the runner already builds and installs
     * @throws BuildError.BadOption when helix.jsonc has no program by that name
     *
     * @remarks
     * Use it to add to a program of helix.jsonc, and {@link Build.addExecutable} for any other executable.
     *
     * @example
     * ```hx
     * const app = try b.bin("app"); // app.index is 0 for the first program
     * ```
     *
     * @since 1.0.0
     */

    bin(this: *Build, name: string): Artifact | Error {
        for (const art, i of this.artifacts.items) {
            if (i < this.bins.items.len && equal(art.name, name)) return Artifact { b: this, index: i };
        }
        eprintln(`error: build.hx asks for the program "${name}", which isn't in helix.jsonc's "bin"`);
        throw BuildError.BadOption;
    }

    /**
     * Adds an executable built from a file with `main`.
     *
     * @param this - The build
     * @param options - The settings of the executable
     * @returns The artifact
     * @throws BuildError.BadOption when the name belongs to a program of helix.jsonc
     * @throws BuildError.BadOption when the same name, target, and mode come from two different roots
     *
     * @remarks
     * Nothing is built until a step needs the artifact.
     * The same name for another target or mode is a new artifact.
     * Asking again with the same name, target, mode, root, and strip setting returns the artifact from before,
     * so a release target that `--target` also names is built once.
     * The executable is built at `.helix-cache/bin/<target>/<mode>/<name>`,
     * with `.exe` for Windows and `.wasm` for WASI.
     *
     * @example
     * ```hx
     * const tool = try b.addExecutable({ name: "tool", root: "tools/tool.hx" }); // built only when a step needs it
     * ```
     *
     * @since 1.0.0
     */

    addExecutable(this: *Build, options: ExecutableOptions): Artifact | Error {
        const target = options.target ?? this.target;
        const mode = options.mode ?? this.mode;
        for (const art, i of this.artifacts.items) {   // the same program for another target or mode is a new one
            if (!equal(art.name, options.name) || !sameTarget(art.target, target) || art.mode != mode) continue;
            if (i < this.bins.items.len) {
                eprintln(`error: "${options.name}" is a program in helix.jsonc's "bin"; build.hx adds to it with b.bin("${options.name}")`);
                throw BuildError.BadOption;
            }
            // asked for again (a release's target that `--target` also names): one artifact, built once
            if (equal(art.root, options.root) && art.strip == options.strip) return Artifact { b: this, index: i };
            eprintln(`error: build.hx adds the executable "${options.name}" twice, from ${art.root} and ${options.root}`);
            throw BuildError.BadOption;
        }
        const output = try fmt.alloc(this.a, `${try cacheDir(this, target, mode)}/${options.name}${executableSuffix(target)}`);
        try this.artifacts.append(ArtifactData {
            name: options.name,
            root: options.root,
            target,
            mode,
            strip: options.strip,
            cpu: options.cpu,
            linkerScript: options.linkerScript,
            options: ArrayList<usize>.init(this.a),
            cFiles: ArrayList<CFile>.init(this.a),
            includeDirs: ArrayList<string>.init(this.a),
            libraries: ArrayList<string>.init(this.a),
            output,
            built: false,
        });
        return Artifact { b: this, index: this.artifacts.items.len - 1 };
    }

    /**
     * Makes the default `install` step copy an artifact into `.helix-out/bin/`.
     *
     * @param this - The build
     * @param artifact - The artifact to install
     * @returns Nothing, or `AllocError.OutOfMemory`
     *
     * @remarks
     * It adds an install step with {@link Build.addInstall} and makes `install` depend on it.
     *
     * @example
     * ```hx
     * try b.install(tool); // helix build puts tool in .helix-out/bin/
     * ```
     *
     * @since 1.0.0
     */

    install(this: *Build, artifact: Artifact): void | Error {
        const step = try this.addInstall(artifact, "bin");
        try this.steps.items[0].deps.append(step.index);
    }

    /**
     * Adds a step that builds an artifact and copies it into a folder under `.helix-out/`.
     *
     * @param this - The build
     * @param artifact - The artifact to install
     * @param dir - The folder under `.helix-out/`
     * @returns The unnamed step, for a step of its own to depend on
     *
     * @remarks
     * The copy keeps the permissions, so an executable stays one.
     * The step runs only when a named step depends on it.
     *
     * @example
     * ```hx
     * const release = try b.step("release", "Build the release");
     * try release.dependOn(try b.addInstall(app, "release/x86_64-linux")); // .helix-out/release/x86_64-linux/app
     * ```
     *
     * @since 1.0.0
     */

    addInstall(this: *Build, artifact: Artifact, dir: string): Step | Error {
        const argv = try alloc<string>(this.a, 1);
        argv[0] = dir;
        const index = try this.addStep(StepData {
            name: "", description: "", kind: StepKind.Install, artifact: artifact.index, test: TestOptions { root: "" },
            argv, deps: ArrayList<usize>.init(this.a), done: false,
        });
        return Step { b: this, index };
    }

    /**
     * Adds the `run` step, which builds an artifact and runs it with the arguments after `--`.
     *
     * @param this - The build
     * @param artifact - The artifact to run
     * @returns Nothing, or the error that {@link Build.addStep} threw
     *
     * @remarks
     * It replaces the default `run` step of the runner.
     * A program that exits with a status other than 0 ends the build with that status, as `helix run` does.
     *
     * @example
     * ```hx
     * try b.addRunStep(tool); // helix build run -- one two runs tool one two
     * ```
     *
     * @since 1.0.0
     */

    addRunStep(this: *Build, artifact: Artifact): void | Error {
        void try this.addStep(StepData {
            name: "run", description: "Build and run the program; arguments after `--` go to it", kind: StepKind.Run,
            artifact: artifact.index, test: TestOptions { root: "" }, argv: [], deps: ArrayList<usize>.init(this.a),
            done: false,
        });
    }

    /**
     * Adds the `test` step, which runs `helix test` on a spec file or a folder.
     *
     * @param this - The build
     * @param options - The settings of the tests
     * @returns Nothing, or the error that {@link Build.addStep} threw
     *
     * @remarks
     * It replaces the default `test` step of the runner, which tests `src/`.
     * The specs get the C files, the libraries, and the options modules of the artifact in `linkWith`.
     *
     * @example
     * ```hx
     * try b.addTestStep({ root: "specs" }); // helix build test runs helix test specs
     * ```
     *
     * @since 1.0.0
     */

    addTestStep(this: *Build, options: TestOptions): void | Error {
        void try this.addStep(StepData {
            name: "test", description: "Run the tests", kind: StepKind.Test, artifact: 0, test: options, argv: [],
            deps: ArrayList<usize>.init(this.a), done: false,
        });
    }

    /**
     * Adds a named step that does nothing itself.
     *
     * @param this - The build
     * @param name - The name that `helix build <name>` asks for
     * @param description - The description that `--help` and `--steps` show
     * @returns The step, to give work with `dependOn`
     * @throws BuildError.BadOption when build.hx already added a step by that name
     *
     * @remarks
     * A step named `run` or `test` replaces the default one of the runner.
     *
     * @example
     * ```hx
     * const gen = try b.step("gen", "Generate the code"); // helix build gen runs what gen depends on
     * ```
     *
     * @since 1.0.0
     */

    step(this: *Build, name: string, description: string): Step | Error {
        const index = try this.addStep(StepData {
            name, description, kind: StepKind.Group, artifact: 0, test: TestOptions { root: "" }, argv: [],
            deps: ArrayList<usize>.init(this.a), done: false,
        });
        return Step { b: this, index };
    }

    /**
     * Adds a step that runs a program, such as a code generator.
     *
     * @param this - The build
     * @param argv - The command line, whose first word is the program
     * @returns The unnamed step, for a named step to depend on
     *
     * @remarks
     * The step fails the build when the program exits with a status other than 0.
     * It runs only when a named step depends on it.
     *
     * @example
     * ```hx
     * const gen = try b.addSystemCommand(["python3", "gen.py"]);
     * try (try b.step("gen", "Generate the code")).dependOn(gen); // helix build gen runs gen.py
     * ```
     *
     * @since 1.0.0
     */

    addSystemCommand(this: *Build, argv: readonly string[]): Step | Error {
        const index = try this.addStep(StepData {
            name: "", description: "", kind: StepKind.Command, artifact: 0, test: TestOptions { root: "" }, argv,
            deps: ArrayList<usize>.init(this.a), done: false,
        });
        return Step { b: this, index };
    }

    /**
     * Adds a step and returns its index.
     *
     * @param this - The build
     * @param data - The step
     * @returns The index of the step
     * @throws BuildError.BadOption when a step by the same name exists and is not a default of the runner
     *
     * @remarks
     * A named step that matches a default `run` or `test` step of the runner takes its place and its index,
     * and that default stops counting as one, so a second step by the same name fails.
     * Unnamed steps never clash.
     *
     * @example
     * ```hx
     * b.addStep(data); // 4 for the fifth step
     * ```
     *
     * @since 1.0.0
     */

    addStep(this: *Build, data: StepData): usize | Error {
        if (data.name.len > 0) {
            for (const s, i of this.steps.items) {
                if (!equal(s.name, data.name)) continue;
                for (const d, j of this.defaults.items) {   // build.hx's own `run` or `test` replaces the runner's
                    if (d != i) continue;
                    this.steps.items[i] = data;
                    this.defaults.items[j] = this.defaults.items[this.defaults.items.len - 1];
                    void this.defaults.pop();
                    return i;
                }
                eprintln(`error: build.hx adds the step "${data.name}" twice`);
                throw BuildError.BadOption;
            }
        }
        try this.steps.append(data);
        return this.steps.items.len - 1;
    }
}

/**
 * Runs a command of a step.
 *
 * @param b - The build
 * @param argv - The command line
 * @returns Nothing, or the error that stopped the command
 * @throws BuildError.StepFailed when the command exits with a status other than 0
 * @throws ProcessError.CannotStart when the command cannot start
 *
 * @remarks
 * With `-v` it first prints the command on stderr, its words separated by spaces.
 *
 * @since 1.0.0
 */

function command(b: *Build, argv: readonly string[]): void | Error {
    if (b.verbose) {
        for (const word, i of argv) {
            if (i > 0) eprint(" ");
            eprint(word);
        }
        eprintln("");
    }
    const status = try process.run(argv);
    if (status != 0) throw BuildError.StepFailed;
}

/**
 * Compiles one C file for a target and a mode into `.helix-cache`.
 *
 * @param b - The build
 * @param package - The folder of the objects, such as `app.c`
 * @param index - The position of the file in its artifact, which names the object
 * @param file - The path of the C file
 * @param target - The target, or null for this machine
 * @param mode - The mode
 * @param flags - The flags of the file
 * @param includes - The include folders of the artifact
 * @returns The path of the object, or the error that stopped the compile
 *
 * @remarks
 * The object goes to `.helix-cache/c/<target>/<mode>/<package>/<index>.o`.
 * An object that this run already compiled is not compiled again.
 * The command is `helix cc [--target t] -c <file> -o <object>`, then the optimization of the mode,
 * `-g` in debug mode, an `-I` for each include folder, and the flags of the file.
 *
 * @since 1.0.0
 */

function compileC(b: *Build, package: string, index: usize, file: string, target: ?string, mode: Mode,
                  flags: readonly string[], includes: readonly string[]): string | Error {
    const object = try fmt.alloc(b.a, `.helix-cache/c/${target ?? "host"}/${modeName(mode)}/${package}/${index}.o`);
    for (const done of b.compiled.items) {
        if (equal(done, object)) return object;
    }
    const dir = try fmt.alloc(b.a, `.helix-cache/c/${target ?? "host"}/${modeName(mode)}/${package}`);
    try fs.makePath(dir);

    let argv = ArrayList<string>.init(b.a);
    try argv.append(b.helix);
    try argv.append("cc");
    if (const t = target) {
        try argv.append("--target");
        try argv.append(t);
    }
    try argv.append("-c");
    try argv.append(file);
    try argv.append("-o");
    try argv.append(object);
    try argv.append(cOptimization(mode));
    if (mode == Mode.Debug) try argv.append("-g");
    for (const dirPath of includes) try argv.append(try fmt.alloc(b.a, `-I${dirPath}`));
    for (const flag of flags) try argv.append(flag);
    try command(b, argv.items);
    try b.compiled.append(object);
    return object;
}

/**
 * Returns the file suffix of an executable for a target.
 *
 * @param target - The target, or null for this machine
 * @returns `.exe` for Windows, `.wasm` for WASI, and an empty string otherwise
 *
 * @remarks
 * It looks for `windows` or `wasi` anywhere in the target.
 * Null gives an empty string, even when this machine runs Windows.
 *
 * @since 1.0.0
 */

function executableSuffix(target: ?string): string {
    if (const t = target) {
        if (indexOf(t, "windows") != null) return ".exe";
        if (indexOf(t, "wasi") != null) return ".wasm";
    }
    return "";
}

/**
 * Whether two artifacts have the same target.
 *
 * @param x - The first target, or null for this machine
 * @param y - The second target, or null for this machine
 * @returns `true` when both are null or both spell the same target
 *
 * @remarks
 * It compares the spelling only, so `native` and null count as different.
 *
 * @since 1.0.0
 */

function sameTarget(x: ?string, y: ?string): bool {
    if (const a = x) {
        if (const b = y) return equal(a, b);
        return false;
    }
    return y == null;
}

/**
 * Returns the folder where artifacts for a target and a mode are built.
 *
 * @param b - The build
 * @param target - The target, or null for this machine
 * @param mode - The mode
 * @returns `.helix-cache/bin/<target>/<mode>`, with `host` for this machine, or `AllocError.OutOfMemory`
 *
 * @remarks
 * The path is relative to the project folder.
 *
 * @since 1.0.0
 */

function cacheDir(b: *Build, target: ?string, mode: Mode): string | Error {
    return try fmt.alloc(b.a, `.helix-cache/bin/${target ?? "host"}/${modeName(mode)}`);
}

/**
 * Builds an artifact, unless this run already did.
 *
 * @param b - The build
 * @param index - The index of the artifact
 * @returns Nothing, or the error that stopped the build
 *
 * @remarks
 * The command is `helix build <root> -o <output> --mode <mode>`,
 * then `--target`, `--cpu`, `--strip`, and `--linker-script` when the artifact sets them,
 * then what {@link artifactOptions} adds.
 *
 * @since 1.0.0
 */

function buildArtifact(b: *Build, index: usize): void | Error {
    const art = b.artifacts.items[index];
    if (art.built) return;
    try fs.makePath(try cacheDir(b, art.target, art.mode));

    let argv = ArrayList<string>.init(b.a);
    try argv.append(b.helix);
    try argv.append("build");
    try argv.append(art.root);
    try argv.append("-o");
    try argv.append(art.output);
    try argv.append("--mode");
    try argv.append(modeName(art.mode));
    if (const t = art.target) {
        try argv.append("--target");
        try argv.append(t);
    }
    if (const cpu = art.cpu) {
        try argv.append("--cpu");
        try argv.append(cpu);
    }
    if (art.strip) try argv.append("--strip");
    if (const script = art.linkerScript) {
        try argv.append("--linker-script");
        try argv.append(script);
    }
    try artifactOptions(b, index, art.target, art.mode, &argv);
    try command(b, argv.items);
    b.artifacts.items[index].built = true;
}

/**
 * Adds the options modules, the C objects, and the libraries of an artifact to a command line.
 *
 * @param b - The build
 * @param index - The index of the artifact
 * @param target - The target to compile the C files for, or null for this machine
 * @param mode - The mode to compile the C files in
 * @param argv - The command line to add to
 * @returns Nothing, or the error that stopped a C compile or a file write
 *
 * @remarks
 * Each options module is written to `.helix-cache/options/<name>.hx` under a generated header
 * and added as `--pkg <name>=<path>`.
 * Each C file is compiled with {@link compileC} and added as `--link <object>`.
 * Each library is added as `-l<name>`.
 * A build and a test step share it, so specs that link with an artifact get the same code.
 *
 * @since 1.0.0
 */

function artifactOptions(b: *Build, index: usize, target: ?string, mode: Mode, argv: *ArrayList<string>): void | Error {
    const art = b.artifacts.items[index];
    for (const o of art.options.items) {
        const module = b.optionModules.items[o];
        let text = fmt.Builder.init(b.a);
        try text.append(`// Generated by build.hx's addOptions("${module.name}"); rebuilt on every \`helix build\`.\n`);
        for (const line of module.lines.items) try text.append(`${line}\n`);
        try fs.makePath(".helix-cache/options");
        const path = try fmt.alloc(b.a, `.helix-cache/options/${module.name}.hx`);
        try fs.writeFile(path, text.text());
        try argv.append("--pkg");
        try argv.append(try fmt.alloc(b.a, `${module.name}=${path}`));
    }
    const own = try fmt.alloc(b.a, `${art.name}.c`);   // the artifact's own C files, in their own folder
    for (const file, i of art.cFiles.items) {
        try argv.append("--link");
        try argv.append(try compileC(b, own, i, file.path, target, mode, file.flags, art.includeDirs.items));
    }
    for (const lib of art.libraries.items) try argv.append(try fmt.alloc(b.a, `-l${lib}`));
}

/**
 * Performs a step, after the steps that it depends on.
 *
 * @param b - The build
 * @param index - The index of the step
 * @returns Nothing, or the error that stopped the step
 *
 * @remarks
 * A step that this run already performed does nothing.
 * - **Group** - nothing beyond its dependencies
 * - **Install** - builds the artifact and copies it to `.helix-out/<dir>/`
 * - **Run** - builds the artifact and runs it with the arguments after `--`,
 *   ending the process with the status of the program when that status is not 0
 * - **Test** - runs `helix test <root> --mode <mode>`, with `--target` and the code of `linkWith` when set
 * - **Command** - runs the command line
 *
 * @since 1.0.0
 */

function make(b: *Build, index: usize): void | Error {
    if (b.steps.items[index].done) return;
    for (const dep of b.steps.items[index].deps.items) try make(b, dep);
    const step = b.steps.items[index];
    switch (step.kind) {
        case StepKind.Group: {}
        case StepKind.Install: {
            try buildArtifact(b, step.artifact);
            const art = b.artifacts.items[step.artifact];
            const dir = try fmt.alloc(b.a, `.helix-out/${step.argv[0]}`);
            try fs.makePath(dir);
            const installed = try fmt.alloc(b.a, `${dir}/${art.name}${executableSuffix(art.target)}`);
            try fs.copyFile(art.output, installed);
            if (b.verbose) eprintln(`installed ${installed}`);
        }
        case StepKind.Run: {
            try buildArtifact(b, step.artifact);
            let argv = ArrayList<string>.init(b.a);
            try argv.append(b.artifacts.items[step.artifact].output);
            for (const arg of b.runArgs) try argv.append(arg);
            const status = try process.run(argv.items);
            if (status != 0) exit(status);   // the program's own status, as `helix run` gives it
        }
        case StepKind.Test: {
            const target = step.test.target ?? b.target;
            const mode = step.test.mode ?? b.mode;
            let argv = ArrayList<string>.init(b.a);
            try argv.append(b.helix);
            try argv.append("test");
            try argv.append(step.test.root);
            try argv.append("--mode");
            try argv.append(modeName(mode));
            if (const t = target) {
                try argv.append("--target");
                try argv.append(t);
            }
            if (const art = step.test.linkWith) try artifactOptions(b, art.index, target, mode, &argv);
            try command(b, argv.items);
        }
        case StepKind.Command: try command(b, step.argv);
    }
    b.steps.items[index].done = true;
}

/**
 * Reads the packages list that `helix build` wrote about the project.
 *
 * @param b - The build
 * @param path - The path of the list
 * @returns Nothing, or the error that stopped the read
 * @throws BuildError.BadPackageList when a line does not start with `bin`
 *
 * @remarks
 * Each line is `bin<tab>-<tab><name><tab><root>`, and the second field is skipped.
 * Each line adds a program to the `bins` of the build, in order.
 *
 * @since 1.0.0
 */

function readPackages(b: *Build, path: string): void | Error {
    const contents = try fs.readFile(b.a, path);
    for (const line of lines(contents)) {
        let fields = split(line, "\t");
        const kind = fields.next() ?? "";
        void fields.next();
        const name = fields.next() ?? "";
        if (!equal(kind, "bin")) throw BuildError.BadPackageList;
        try b.bins.append(Define { name, value: fields.next() ?? "" });
    }
}

/**
 * Adds what every project gets before its build.hx runs.
 *
 * @param b - The build
 * @returns Nothing, or `AllocError.OutOfMemory`
 *
 * @remarks
 * Each `bin` of helix.jsonc is built and installed, the first one gets a `run` step,
 * and a `test` step tests `src/` with the code of the first program.
 * The `run` and `test` steps are defaults, which build.hx's own replace.
 *
 * @since 1.0.0
 */

function addManifest(b: *Build): void | Error {
    let first: ?Artifact = null;
    for (const bin of b.bins.items) {
        const app = try b.addExecutable({ name: bin.name, root: bin.value });
        try b.install(app);
        if (first == null) {
            try b.addRunStep(app);
            try b.defaults.append(b.steps.items.len - 1);
            first = app;
        }
    }
    try b.addTestStep({ root: "src", linkWith: first });
    try b.defaults.append(b.steps.items.len - 1);
}

/**
 * Returns the mode that `--mode` names.
 *
 * @param name - The name, such as `release-fast`
 * @returns The mode, or null when no mode has that name
 *
 * @remarks
 * It compares against {@link modeName} of each mode in {@link Modes}.
 *
 * @since 1.0.0
 */

function modeNamed(name: string): ?Mode {
    for (const m of Modes) {
        if (equal(modeName(m), name)) return m;
    }
    return null;
}

/**
 * Runs a build, as the `main` of the build runner.
 *
 * @param init - The command line, `<helix> <packages.txt> [steps] [options] [-- args]`
 * @param build - The `build` function of build.hx
 * @returns 0 when the build succeeds, 1 when a step fails, and 2 for a bad command line
 * @throws BuildError.BadPackageList when the packages list holds a line that is not a program
 *
 * @remarks
 * `helix build` starts the runner with the path of the compiler and of the packages list.
 * The options are `--target t`, `--mode m`, `--help` or `-h`, `--steps`, `-v`, and `--name=value` for build.hx,
 * and everything after `--` goes to the program of the `run` step.
 * The runner adds the steps that helix.jsonc implies, calls `build`, and then:
 * - with `--help`, prints the steps, the options of build.hx, and the general options, and returns 0
 * - with `--steps`, prints the named steps and returns 0
 * - returns 2 for a `--name` that build.hx never declared, and for an unknown step
 * - performs each step named, or `install` when none is, and returns 1 when one fails
 *
 * Everything that the build allocates comes from one arena, which is freed before it returns.
 *
 * @example
 * ```hx
 * runBuild(init, build); // 0 for helix build test when the tests pass
 * ```
 *
 * @since 1.0.0
 */

export function runBuild(init: Init, build: (b: *Build) => void | Error): u8 | Error {
    let arena = ArenaAllocator.init(cAllocator());
    defer arena.deinit();
    const a = arena.allocator();
    if (init.args.len < 2) {
        eprintln("error: the build runner is started by `helix build`");
        return 2;
    }

    let b = Build {
        a, helix: init.args[0], verbose: false, target: null, mode: Mode.Debug, defines: ArrayList<Define>.init(a), declared: ArrayList<Declared>.init(a),
        bins: ArrayList<Define>.init(a), optionModules: ArrayList<OptionsData>.init(a), runArgs: [],
        artifacts: ArrayList<ArtifactData>.init(a),
        steps: ArrayList<StepData>.init(a), compiled: ArrayList<string>.init(a), defaults: ArrayList<usize>.init(a),
    };
    void try b.addStep(StepData {
        name: "install", description: "Build everything `install`ed into .helix-out/ (the default)", kind: StepKind.Group,
        artifact: 0, test: TestOptions { root: "" }, argv: [], deps: ArrayList<usize>.init(a), done: false,
    });
    try readPackages(&b, init.args[1]);

    let wanted = ArrayList<string>.init(a);
    let list = false;
    let help = false;
    const args = init.args[2..];
    let at: usize = 0;
    while (at < args.len) {
        const arg = args[at];
        at += 1;
        if (equal(arg, "--")) {
            b.runArgs = args[at..];
            break;
        }
        if ((equal(arg, "--target") || equal(arg, "--mode")) && at == args.len) {
            eprintln(`error: ${arg} needs a value`);
            return 2;
        }
        if (equal(arg, "--target")) {
            b.target = args[at];
            at += 1;
        } else if (equal(arg, "--mode")) {
            if (const m = modeNamed(args[at])) {
                b.mode = m;
            } else {
                eprintln(`error: unknown mode '${args[at]}' (use debug, release-safe, release-fast or release-small)`);
                return 2;
            }
            at += 1;
        } else if (equal(arg, "-v")) {
            b.verbose = true;
        } else if (equal(arg, "--steps")) {
            list = true;
        } else if (equal(arg, "--help") || equal(arg, "-h")) {
            help = true;
        } else if (startsWith(arg, "--") && arg.len > 2) {   // an option of build.hx: --name=value, or --name for true
            const eq = indexOf(arg, "=") ?? arg.len;
            try b.defines.append(Define { name: arg[2..eq], value: eq < arg.len ? arg[eq + 1..] : "true" });
        } else if (startsWith(arg, "-")) {
            eprintln(`error: unknown option '${arg}'`);
            return 2;
        } else {
            try wanted.append(arg);
        }
    }

    try addManifest(&b);
    try build(&b);

    if (help) {
        println("Usage: helix build [steps] [--target t] [--mode m] [--name=value] [-v] [-- program args]\n\nSteps:");
        for (const s of b.steps.items) {
            if (s.name.len > 0) println(`  ${s.name}  ${s.description}`);
        }
        println("\nOptions (from build.hx):");
        if (b.declared.items.len == 0) println("  (none)");
        for (const d of b.declared.items) println(`  --${d.name}=[${d.kind}]  ${d.description}`);
        println("\nGeneral:");
        println("  --target t  what to build for: aarch64-macos, x86_64-linux-gnu, x86_64-windows, ... (default: this machine)");
        println("  --mode m  debug (default), release-safe, release-fast or release-small");
        println("  -v  print each command\n  --steps  list the steps\n  --help  this list");
        return 0;
    }
    if (list) {
        for (const s of b.steps.items) {
            if (s.name.len > 0) println(`  ${s.name}  ${s.description}`);
        }
        return 0;
    }
    for (const d of b.defines.items) {   // an option that build.hx never asked about is a typo, not a no-op
        let known = false;
        for (const k of b.declared.items) known = known || equal(k.name, d.name);
        if (!known) {
            eprintln(`error: build.hx has no option --${d.name}; \`helix build --help\` lists them`);
            return 2;
        }
    }
    if (wanted.items.len == 0) try wanted.append("install");
    for (const name of wanted.items) {
        let found: ?usize = null;
        for (const s, i of b.steps.items) {
            if (equal(s.name, name)) found = i;
        }
        if (const index = found) {
            make(&b, index) catch (e) {
                if (e != BuildError.StepFailed) eprintln(`error: step "${name}" failed: ${@errorName(e)}`);
                return 1;
            };
        } else {
            eprintln(`error: build.hx has no step "${name}"; \`helix build --help\` lists them`);
            return 2;
        }
    }
    return 0;
}
