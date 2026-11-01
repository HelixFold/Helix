/**
 * Imports
 */

import { Version } from "@constants/version.constant";
import { hxDiagListFree } from "@models/diagnostic.model";
import * as sys from "@modules/driver/bindings/sys.binding";
import * as os from "@modules/driver/components/os.component";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstPrint } from "@components/ast-printer.component";
import { equal, startsWith, endsWith, indexOf } from "std/text";
import { hxDiagRender } from "@components/diagnostic.component";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { ModeDebug } from "@modules/codegen/constants/base.constant";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxTokenName } from "@modules/lexer/components/token.component";
import { TestCounts } from "@modules/driver/structs/driver-module.struct";
import { cmdTranslateSvd } from "@modules/driver/components/svd.component";
import { hxCodegenIr, hxModeParse } from "@modules/codegen/codegen.module";
import { parseTarget } from "@modules/driver/components/compile.component";
import { translateC } from "@modules/driver/components/translate.component";
import { Usage, TestStarts } from "@modules/driver/constants/driver.constant";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { hxSourceLoad, hxSourceLineCol, hxSourceFree } from "@models/source.model";
import { Options } from "@modules/driver/components/structs/compile-component.struct";
import { cmdProjectBuild, movedToHpm } from "@modules/driver/components/project.component";
import { HxCodegenOptions } from "@modules/codegen/components/structs/base-component.struct";
import { TranslateOptions } from "@modules/driver/components/structs/translate-component.struct";
import { allocCString, toCString, fromCString, add, strings } from "@modules/driver/components/os.component";
import { cCompiler, cmdChips, compileFront, compilationFree } from "@modules/driver/components/compile.component";
import { buildExecutable, defaultOptions, parseCompileOption } from "@modules/driver/components/compile.component";

/**
 * The C library functions that the command line uses to release C strings and to clear a diagnostic list.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;
extern "C" function memset(dest: ?u8[*], c: i32, count: usize): ?u8[*];

/**
 * Prints the usage text.
 *
 * @param toStderr - Whether to print to stderr instead of stdout
 *
 * @remarks
 * `helix help` prints it to stdout and exits with 0.
 * A missing or unknown command prints it to stderr, so it does not mix with the output that a script reads.
 *
 * @since 1.0.0
 */

function usage(toStderr: bool): void {
    for (const line of Usage) {
        if (toStderr) eprintln(line);
        else println(line);
    }
}

/**
 * Parses the value of `--mode`.
 *
 * @param text - The value, such as `debug` or `release-fast`
 * @param mode - Where to store the mode
 * @returns `true` when the value names a mode, `false` after reporting an unknown one
 *
 * @remarks
 * The names come from `hxModeParse` of the code generator, so a new mode needs no change here.
 *
 * @since 1.0.0
 */

function parseMode(text: string, mode: *u32): bool {
    if (hxModeParse(toCString(text), mode)) return true;
    eprintln(`error: unknown mode '${text}' (use debug, release-safe, release-fast or release-small)`);
    return false;
}

/**
 * Parses the options of `run`, `build <file>`, `check`, `ir`, `ast`, and `tokens`.
 *
 * @param args - The arguments after the command name
 * @returns The options, or `null` after reporting an error
 *
 * @remarks
 * The options that every compiling command takes go through `parseCompileOption` first.
 * This function then reads `-o`, `--test`, and `--mode`, and takes the first argument
 * that does not start with `-` as the input file.
 * Everything after `--` becomes the arguments of the program that `run` starts.
 * An unknown option, a second input file, or a missing input file is reported and gives `null`.
 *
 * @since 1.0.0
 */

function parseOptions(args: readonly string[]): ?Options {
    let options = defaultOptions();
    let file: ?string = null;
    let i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (equal(arg, "--")) {
            options.runArgs = args[i + 1..];
            break;
        }
        const handled = parseCompileOption(args, &i, &options);
        if (handled < 0) return null;
        if (handled == 0) {
            if (equal(arg, "-o") && i + 1 < args.len) {
                i++;
                options.output = args[i];
            } else if (equal(arg, "--test")) {
                options.test = true;
            } else if (equal(arg, "--mode") && i + 1 < args.len) {
                i++;
                if (!parseMode(args[i], &options.mode)) return null;
            } else if (arg.len > 0 && arg[0] == '-') {
                eprintln(`error: unknown option '${arg}'`);
                return null;
            } else if (file == null) {
                file = arg;
            } else {
                eprintln(`error: unexpected argument '${arg}'`);
                return null;
            }
        }
        i++;
    }
    if (const path = file) {
        options.file = path;
        return options;
    }
    eprintln("error: missing input file");
    return null;
}

/**
 * Runs `helix version`, which prints the Helix version and the LLVM version that the compiler links.
 *
 * @returns The exit status, always 0
 *
 * @remarks
 * The LLVM version comes from `LLVMGetVersion`,
 * so it names the library that the compiler runs with, not the one it was built against.
 *
 * @since 1.0.0
 */

function cmdVersion(): u8 {
    let major: u32 = 0;
    let minor: u32 = 0;
    let patch: u32 = 0;
    llvm.LLVMGetVersion(&major, &minor, &patch);
    println(`helix ${Version} (LLVM ${major}.${minor}.${patch})`);
    return 0;
}

/**
 * Runs `helix check`, which reports the errors in a file without building it.
 *
 * @param options - The parsed options, where `--test` also checks the tests
 * @returns The exit status, 0 when the file checks and 1 otherwise
 *
 * @remarks
 * It loads and checks the program for the target of `--target` without generating code,
 * so it is the fastest way to see every error.
 * The diagnostics print while the program loads, and the compilation is released before it returns.
 *
 * @since 1.0.0
 */

function cmdCheck(options: *Options): u8 {
    const target = parseTarget(options.target);
    if (target == null) return 1;
    let ok = false;
    const c = compileFront(options.file, true, options.test, target, &ok);
    compilationFree(c);
    return ok ? 0 : 1;
}

/**
 * Runs `helix build <file.hx>`, which builds an executable from one file.
 *
 * @param options - The parsed options
 * @returns The exit status, 0 when the build succeeds and 1 otherwise
 *
 * @remarks
 * Without `-o`, the output is the file name without `.hx`.
 * For a Windows target it gets `.exe` and for a WASI target `.wasm`, unless `--emit obj` asks for an object file.
 *
 * @since 1.0.0
 */

function cmdBuild(options: *Options): u8 {
    let output = os.fileStem(options.file);
    if (const target = options.target) {
        if (options.output == null && !options.emitObject) {
            if (indexOf(target, "windows") != null) output = allocCString(`${output}.exe`);
            if (indexOf(target, "wasi") != null) output = allocCString(`${output}.wasm`);
        }
    }
    return buildExecutable(options, options.output ?? output) ? 0 : 1;
}

/**
 * Runs `helix run`, which builds a program into the temporary folder, runs it, and removes it.
 *
 * @param options - The parsed options, whose run arguments go to the program
 * @returns The exit status of the program, or 1 when it does not build or start
 *
 * @remarks
 * The executable is named after the process id and the file stem,
 * so two runs at the same time do not overwrite each other.
 * The `.dSYM` folder that macOS writes beside it is removed too.
 *
 * @since 1.0.0
 */

function cmdRun(options: *Options): u8 {
    const exe = allocCString(`${os.tempDir()}/helix-run-${os.pid()}-${os.fileStem(options.file)}`);
    if (!buildExecutable(options, exe)) return 1;
    let args = strings();
    add(&args, exe);
    for (const arg of options.runArgs) add(&args, arg);
    const status = os.run(args.items);
    os.unlink(exe);
    os.removeTree(allocCString(`${exe}.dSYM`));
    return status < 0 ? 1 : status as u8;
}

/**
 * Runs `helix ir`, which prints the optimized LLVM IR of a file to stdout.
 *
 * @param options - The parsed options, whose mode and target shape the IR
 * @returns The exit status, 0 when the IR is printed and 1 otherwise
 *
 * @remarks
 * Debug mode includes debug info in the IR.
 * A host target leaves the triple to LLVM, and a cross target passes its triple.
 *
 * @since 1.0.0
 */

function cmdIr(options: *Options): u8 {
    const target = parseTarget(options.target);
    if (target == null) return 1;
    let ok = false;
    const c = compileFront(options.file, true, options.test, target, &ok);
    if (ok) {
        const codegen = HxCodegenOptions {
            mode: options.mode, module_name: toCString(os.fileStem(options.file)), debugInfo: options.mode == ModeDebug,
            triple: target.host ? null : toCString(target.triple), cpu: null, freestanding: target.freestanding,
        };
        let error: ?u8[*] = null;
        if (const ir = hxCodegenIr(&c.sema, &codegen, &error)) {
            const text = fromCString(os.asReadonly(ir));
            void sys.fwrite(text.ptr, 1, text.len, os.cStdout());
            free(ir);
        } else {
            eprintln(`error: ${fromCString(os.asReadonly(error))}`);
            free(error);
            ok = false;
        }
    }
    compilationFree(c);
    return ok ? 0 : 1;
}

/**
 * Runs `helix ast`, which prints the syntax tree of a file to stdout.
 *
 * @param options - The parsed options
 * @returns The exit status, 0 when the file parses and 1 otherwise
 *
 * @remarks
 * The tree prints whenever the file parses, even when parsing reported errors.
 *
 * @since 1.0.0
 */

function cmdAst(options: *Options): u8 {
    let ok = false;
    const c = compileFront(options.file, false, false, null, &ok);
    if (c.parsed) hxAstPrint(&c.ast, c.ast.root, os.stdoutFile(), true);
    compilationFree(c);
    return ok ? 0 : 1;
}

/**
 * Runs `helix tokens`, which prints the token stream of a file to stdout.
 *
 * @param options - The parsed options
 * @returns The exit status, 0 when the file lexes and 1 otherwise
 *
 * @remarks
 * Each line holds the line and column, the token kind, and the token text.
 * A doc comment prints as a `DOC_COMMENT` line with its length in bytes, before the token that it belongs to.
 * The lexer's diagnostics go to stderr.
 *
 * @since 1.0.0
 */

function cmdTokens(options: *Options): u8 {
    let src: HxSource = undefined;
    let error: readonly u8[*] = "";
    if (!hxSourceLoad(&src, toCString(options.file), &error)) {
        eprintln(`error: cannot read '${options.file}': ${fromCString(error)}`);
        return 1;
    }
    let diags: HxDiagList = undefined;
    let tokens: HxTokens = undefined;
    unsafe {
        void memset(@ptrCast(?u8[*], &diags), 0, @sizeOf(HxDiagList));
    }
    const ok = hxLex(&src, &tokens, &diags);

    let doc: u32 = 0;
    for (const i of 0..tokens.len) {
        unsafe {
            while (doc < tokens.docsLen && tokens.docs![doc].token == i) {
                const at = hxSourceLineCol(&src, tokens.docs![doc].start);
                void sys.printf("%5u:%-4u %-22s (%u bytes)\n", at.line, at.col, "DOC_COMMENT", tokens.docs![doc].len);
                doc++;
            }
            const at = hxSourceLineCol(&src, tokens.starts![i]);
            void sys.printf("%5u:%-4u %-22s %.*s\n", at.line, at.col, hxTokenName(tokens.kinds![i] as u32),
                          tokens.lens![i] as i32, &src.text![tokens.starts![i]]);
        }
    }

    hxDiagRender(&diags, os.stderrFile(), os.useColor(2));
    hxTokensFree(&tokens);
    hxDiagListFree(&diags);
    hxSourceFree(&src);
    return ok ? 0 : 1;
}

/**
 * Runs `helix cc [--target t] args`, which is the system C compiler aimed at a Helix target.
 *
 * @param args - The arguments after `cc`, where a leading `--target t` picks the target
 * @returns The exit status of the C compiler, or 1 when it cannot start
 *
 * @remarks
 * The build runner uses it to compile C sources for the target that it builds.
 *
 * @since 1.0.0
 */

function cmdCc(args: readonly string[]): u8 {
    let targetName: ?string = null;
    let first: usize = 0;
    if (args.len > 1 && equal(args[0], "--target")) {
        targetName = args[1];
        first = 2;
    }
    const target = parseTarget(targetName);
    if (target == null) return 1;
    const compiler = cCompiler(target);
    if (compiler == null) return 1;
    let cc: Strings = compiler;
    for (const arg of args[first..]) add(&cc, arg);
    const status = os.run(cc.items);
    return status < 0 ? 1 : status as u8;
}

/**
 * Checks whether a file has a top-level test, so that `helix test` runs it.
 *
 * @param path - The file to read
 * @returns `true` when a line starts with one of {@link TestStarts}, `false` otherwise or when the file cannot be read
 *
 * @remarks
 * Only the start of a line counts,
 * so an indented `test(` inside a function or a comment does not make a file a test file.
 *
 * @since 1.0.0
 */

function hasTests(path: string): bool {
    const source = os.readText(path);
    if (source == null) return false;
    let start: usize = 0;
    while (start < source.len) {
        let end = start;
        while (end < source.len && source[end] != '\n') end++;
        const line = source[start..end];
        for (const prefix of TestStarts) {
            if (startsWith(line, prefix)) return true;
        }
        start = end + 1;
    }
    return false;
}

/**
 * Collects the test files under a folder.
 *
 * @param dir - The folder to search, where `.` keeps the paths relative
 * @param out - The list to add the paths to
 *
 * @remarks
 * Every `*.spec.hx` file counts, and so does any other `.hx` file that has a top-level test.
 * The search goes into subfolders but skips hidden names, `build`, and `node_modules`.
 *
 * @since 1.0.0
 */

function findSpecs(dir: string, out: *Strings): void {
    const names = os.listDir(dir);
    if (names == null) return;
    for (const name of names.items) {
        if (name[0] == '.' || equal(name, "build") || equal(name, "node_modules")) continue;
        const path = equal(dir, ".") ? name : allocCString(`${dir}/${name}`);
        const st = os.stat(path, false);
        if (st == null) continue;
        if (os.isDir(st.mode)) findSpecs(path, out);
        else if (endsWith(name, ".spec.hx") || (endsWith(name, ".hx") && hasTests(path))) add(out, path);
    }
}

/**
 * The number of the next test binary, which keeps the binaries of one `helix test` run apart.
 *
 * @since 1.0.0
 */

let nextSpec: u32 = 0;

/**
 * Whether `--reporter json` asked for one JSON event per line, for editors.
 *
 * @remarks
 * The design of the events is in docs/design/ide.md.
 *
 * @since 1.0.0
 */

let jsonReport = false;

/**
 * Whether `--reporter teamcity` asked for the TeamCity messages that JetBrains editors show as a test tree.
 *
 * @since 1.0.0
 */

let teamcityReport = false;

/**
 * Escapes a text as a TeamCity message value.
 *
 * @param text - The text to escape
 * @returns The text with `|`, `'`, `[`, and `]` prefixed by `|`, and each newline written as `|n`
 *
 * @remarks
 * TeamCity reads `'` as the end of a value, so a value that is not escaped would cut the message short.
 * A carriage return is left as it is.
 *
 * @since 1.0.0
 */

function teamcityValue(text: string): string {
    let out = "";
    for (const c, i of text) {
        if (c == '|' || c == '\'' || c == '[' || c == ']') out = allocCString(`${out}|${text[i..i + 1]}`);
        else if (c == '\n') out = allocCString(`${out}|n`);
        else out = allocCString(`${out}${text[i..i + 1]}`);
    }
    return out;
}

/**
 * Quotes a text as a JSON string.
 *
 * @param text - The text to quote
 * @returns The text in double quotes, with `"` and `\` escaped and each newline written as `\n`
 *
 * @remarks
 * Any other control character becomes a space.
 *
 * @since 1.0.0
 */

function jsonQuote(text: string): string {
    let out = "\"";
    for (const c, i of text) {
        if (c == '"' || c == '\\') out = allocCString(`${out}\\${text[i..i + 1]}`);
        else if (c == '\n') out = allocCString(`${out}\\n`);
        else if (c < 0x20) out = allocCString(`${out} `);
        else out = allocCString(`${out}${text[i..i + 1]}`);
    }
    return allocCString(`${out}"`);
}

/**
 * Reads the summary file that a test binary writes.
 *
 * @param path - The summary file
 * @param counts - Where to store the counts
 * @returns `true` when the file holds five numbers, `false` when it is missing or short
 *
 * @remarks
 * The file holds the numbers of passed, failed, panicked, skipped, and todo tests in that order,
 * separated by spaces, tabs, or newlines.
 *
 * @since 1.0.0
 */

function readSummary(path: string, counts: *TestCounts): bool {
    const source = os.readText(path);
    if (source == null) return false;
    let values: i64[5] = [0, 0, 0, 0, 0];
    let n: usize = 0;
    let i: usize = 0;
    while (n < 5) {
        while (i < source.len && (source[i] == ' ' || source[i] == '\n' || source[i] == '\t')) i++;
        const negative = i < source.len && source[i] == '-';
        if (negative) i++;
        const start = i;
        let value: i64 = 0;
        while (i < source.len && source[i] >= '0' && source[i] <= '9') {
            value = value * 10 + (source[i] - '0') as i64;
            i++;
        }
        if (i == start) return false;
        values[n] = negative ? -value : value;
        n++;
    }
    *counts = TestCounts { passed: values[0], failed: values[1], panicked: values[2], skipped: values[3], todo: values[4] };
    return true;
}

/**
 * Builds one spec into a test binary and runs it.
 *
 * @param path - The spec file
 * @param base - The options to build with, which this function copies
 * @param runnerArgs - The options for the test binary, such as `-f` and `-v`
 * @param counts - The totals to add the counts of this spec to
 * @param compiled - Where to store whether the spec compiled
 * @returns `true` when the spec compiled and every test passed
 *
 * @remarks
 * A spec that does not compile is reported in the format of the selected reporter.
 * The binary writes its counts to a summary file beside it, and a binary that stops without one counts as failed.
 * The binary, its summary, and its `.dSYM` folder are removed afterwards.
 *
 * @since 1.0.0
 */

function runSpec(path: string, base: readonly *Options, runnerArgs: readonly string[], counts: *TestCounts, compiled: *bool): bool {
    const exe = allocCString(`${os.tempDir()}/helix-test-${os.pid()}-${nextSpec}`);
    nextSpec++;
    const summary = allocCString(`${exe}.summary`);
    let options = *base;
    options.file = path;
    options.test = true;
    *compiled = buildExecutable(&options, exe);
    if (!*compiled && teamcityReport) {
        println(`##teamcity[testSuiteStarted name='${teamcityValue(path)}']\n##teamcity[testStarted name='(compiling)']\n##teamcity[testFailed name='(compiling)' message='doesn|'t compile; the errors are on stderr']\n##teamcity[testFinished name='(compiling)']\n##teamcity[testSuiteFinished name='${teamcityValue(path)}']`);
        os.flushStdout();
        return false;
    }
    if (!*compiled && jsonReport) {
        println(`{"event":"file","file":${jsonQuote(path)},"status":"error","message":"doesn't compile; the errors are on stderr"}`);
        os.flushStdout();
        return false;
    }
    if (!*compiled) {
        const color = os.useColor(1);
        println(` ${color ? "\x1b[1;31m" : ""}FAIL${color ? "\x1b[0m" : ""} ${path} (doesn't compile; errors above)\n`);
        os.flushStdout();
        return false;
    }

    let args = strings();
    add(&args, exe);
    add(&args, "--name");
    add(&args, path);
    add(&args, "--summary");
    add(&args, summary);
    if (teamcityReport) add(&args, "--teamcity");
    else if (jsonReport) add(&args, "--json");
    else if (os.useColor(1)) add(&args, "--color");
    for (const arg of runnerArgs) add(&args, arg);
    os.flushStdout();
    const status = os.run(args.items);

    let ok = status == 0;
    let got = TestCounts { passed: 0, failed: 0, panicked: 0, skipped: 0, todo: 0 };
    if (readSummary(summary, &got)) {
        counts.passed += got.passed;
        counts.failed += got.failed;
        counts.panicked += got.panicked;
        counts.skipped += got.skipped;
        counts.todo += got.todo;
    } else {
        eprintln(`error: the test binary for '${path}' stopped without a result (exit status ${status})`);
        ok = false;
    }
    os.unlink(summary);
    os.unlink(exe);
    os.removeTree(allocCString(`${exe}.dSYM`));
    return ok;
}

/**
 * Runs `helix test [files or dirs] [-s glob] [-f regex] [-b] [-v] [-t ms] [--mode m] [--reporter r]`.
 *
 * @param args - The arguments after `test`
 * @returns The exit status, 0 when every spec compiles and passes and 1 otherwise
 *
 * @remarks
 * Without a file or folder it searches the current folder.
 * The specs run in sorted order, and `-s` keeps those whose path matches a shell pattern.
 * A `*` in that pattern also matches `/`, so one star selects everything under a folder just as two stars do.
 * `-f`, `-t`, `-v`, and `-b` go on to each test binary, and `-b` also stops after the first failing spec.
 * The text reporter ends with the totals and the time,
 * and the JSON reporter ends with one `done` event that holds the totals.
 *
 * @since 1.0.0
 */

function cmdTest(args: readonly string[]): u8 {
    let base = defaultOptions();
    let glob: ?string = null;
    let bail = false;
    let roots = strings();
    let runnerArgs = strings();
    let i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        const hasValue = i + 1 < args.len;
        const handled = parseCompileOption(args, &i, &base);
        if (handled < 0) return 1;
        if (handled == 0) {
            if (equal(arg, "--mode") && hasValue) {
                i++;
                if (!parseMode(args[i], &base.mode)) return 1;
            } else if (equal(arg, "-s") && hasValue) {
                i++;
                glob = args[i];
            } else if ((equal(arg, "-f") || equal(arg, "-t")) && hasValue) {
                add(&runnerArgs, arg);
                i++;
                add(&runnerArgs, args[i]);
            } else if (equal(arg, "-v") || equal(arg, "-b")) {
                if (equal(arg, "-b")) bail = true;
                add(&runnerArgs, arg);
            } else if (equal(arg, "--reporter") && hasValue) {
                i++;
                if (!equal(args[i], "json") && !equal(args[i], "teamcity") && !equal(args[i], "text")) {
                    eprintln(`error: unknown reporter '${args[i]}' (use text, json or teamcity)`);
                    return 1;
                }
                jsonReport = equal(args[i], "json");
                teamcityReport = equal(args[i], "teamcity");
            } else if (arg.len > 0 && arg[0] == '-') {
                eprintln(`error: unknown option '${arg}'`);
                return 1;
            } else {
                add(&roots, arg);
            }
        }
        if (runnerArgs.items.len > 12) {
            eprintln("error: too many options");
            return 1;
        }
        i++;
    }

    let specs = strings();
    if (roots.items.len == 0) add(&roots, ".");
    for (const root of roots.items) {
        const st = os.stat(root, false);
        if (st == null) {
            eprintln(`error: cannot read '${root}': ${os.strerror(os.errno())}`);
            return 1;
        }
        if (os.isDir(st.mode)) findSpecs(root, &specs);
        else add(&specs, root);
    }
    os.sort(specs.items);
    if (const pattern = glob) {   // `*` matches across folders too, so `src/**` and `src/*` both mean "anything under src"
        let kept: usize = 0;
        for (const spec, j of specs.items) {
            if (os.matches(pattern, spec)) {
                specs.items[kept] = specs.items[j];
                kept++;
            }
        }
        specs.items = specs.items[0..kept];
    }
    if (specs.items.len == 0) {
        if (const pattern = glob) eprintln(`error: no tests found matching ${pattern}`);
        else eprintln("error: no tests found");
        eprintln("  = hint: tests go in `<name>.spec.hx` files next to the code, in `describe(\"...\") { test(\"...\") { ... } }`");
        return 1;
    }

    const start = os.secondsNow();
    let counts = TestCounts { passed: 0, failed: 0, panicked: 0, skipped: 0, todo: 0 };
    let broken: u32 = 0;
    let ok = true;
    for (const spec of specs.items) {
        let compiled = false;
        const passed = runSpec(spec, &base, runnerArgs.items, &counts, &compiled);
        if (!compiled) broken++;
        if (!passed) ok = false;
        if (!passed && bail) break;
    }
    const elapsed = os.secondsNow() - start;
    if (teamcityReport) return ok ? 0 : 1;
    if (jsonReport) {
        println(`{"event":"done","passed":${counts.passed},"failed":${counts.failed},"panicked":${counts.panicked},"skipped":${counts.skipped},"todo":${counts.todo},"broken":${broken},"specs":${specs.items.len}}`);
        os.flushStdout();
        return ok ? 0 : 1;
    }

    const color = os.useColor(1);
    const red = color ? "\x1b[1;31m" : "";
    const green = color ? "\x1b[1;32m" : "";
    const yellow = color ? "\x1b[1;33m" : "";
    const reset = color ? "\x1b[0m" : "";
    const total = counts.passed + counts.failed + counts.panicked + counts.skipped + counts.todo;
    print("Tests:  ");
    if (counts.failed > 0) print(`${red}${counts.failed} failed${reset}, `);
    if (counts.panicked > 0) print(`${red}${counts.panicked} panicked${reset}, `);
    if (counts.skipped > 0) print(`${yellow}${counts.skipped} skipped${reset}, `);
    if (counts.todo > 0) print(`${yellow}${counts.todo} todo${reset}, `);
    println(`${counts.passed > 0 ? green : ""}${counts.passed} passed${counts.passed > 0 ? reset : ""}, ${total} total`);
    if (broken > 0) println(`Specs:  ${red}${broken} didn't compile${reset}, ${specs.items.len} total`);
    os.flushStdout();
    void sys.printf("Time:   %.2f s\n", elapsed);
    return ok ? 0 : 1;
}

/**
 * Runs `helix translate-c <header.h> [-o out.hx] [--target t] [--all] [--dir] [-I dir] [-D name[=value]]`.
 *
 * @param args - The arguments after `translate-c`
 * @returns The exit status, 0 when the translation succeeds and 1 otherwise
 *
 * @remarks
 * Any other option starting with `-` goes to clang, and `-I`, `-D`, `-isystem`, and `-include` take their value along.
 * The command line without `-o` is recorded so that the output can say how to make it again.
 * It takes exactly one header.
 *
 * @since 1.0.0
 */

function cmdTranslateC(args: readonly string[]): u8 {
    let header: ?string = null;
    let output: ?string = null;
    let targetName: ?string = null;
    let all = false;
    let wholeDir = false;
    let clangArgs = strings();
    let command = "helix translate-c";
    let i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        const hasValue = i + 1 < args.len;
        const isOutput = equal(arg, "-o") && hasValue;
        if (!isOutput) command = allocCString(`${command} ${arg}`);
        if (isOutput) {
            i++;
            output = args[i];
        } else if (equal(arg, "--target") && hasValue) {
            i++;
            targetName = args[i];
            command = allocCString(`${command} ${args[i]}`);
        } else if (equal(arg, "--all")) {
            all = true;
        } else if (equal(arg, "--dir")) {
            wholeDir = true;
        } else if (arg.len > 0 && arg[0] == '-') {
            add(&clangArgs, arg);   // -I, -D and anything else clang takes
            const separate = (equal(arg, "-I") || equal(arg, "-D") || equal(arg, "-isystem") || equal(arg, "-include")) && hasValue;
            if (separate) {
                i++;
                add(&clangArgs, args[i]);
                command = allocCString(`${command} ${args[i]}`);
            }
        } else if (header == null) {
            header = arg;
        } else {
            eprintln(`error: unexpected argument '${arg}' (one header at a time)`);
            return 1;
        }
        i++;
    }
    if (header == null) {
        eprintln("error: `helix translate-c` takes a C header: `helix translate-c zlib.h -o src/c.hx`");
        return 1;
    }
    const target = parseTarget(targetName);
    if (target == null) return 1;
    return translateC(TranslateOptions {
        header: header ?? "", output, triple: target.host ? null : target.triple, clangArgs: clangArgs.items, all,
        wholeDir, command,
    });
}

/**
 * Runs the `helix` command line and returns the exit status.
 *
 * @param args - The arguments without the program name, starting with the command
 * @returns The exit status of the command, or 1 for a missing or unknown command
 *
 * @remarks
 * This file holds the commands that do not belong to projects, and it hands the rest to their own modules.
 * `helix build` with a `.hx` file before any `--` builds that one file.
 * Otherwise it builds the project through its build.hx.
 * The commands that moved to hpm, such as `add` and `init`, report where they went.
 *
 * @example
 * ```hx
 * run([ 'version' ]);       // 0, after printing the Helix and LLVM versions
 * run([ 'frobnicate' ]);    // 1, after printing the usage to stderr
 * ```
 *
 * @since 1.0.0
 */

export function run(args: readonly string[]): u8 {
    if (args.len == 0) {
        usage(true);
        return 1;
    }
    const command = args[0];
    const rest = args[1..];
    if (equal(command, "version") || equal(command, "--version")) return cmdVersion();
    if (equal(command, "help") || equal(command, "--help") || equal(command, "-h")) {
        usage(false);
        return 0;
    }

    if (equal(command, "test")) return cmdTest(rest);
    if (equal(command, "cc")) return cmdCc(rest);
    if (const status = movedToHpm(command, rest)) return status;
    if (equal(command, "translate-c")) return cmdTranslateC(rest);
    if (equal(command, "translate-svd")) return cmdTranslateSvd(rest);
    if (equal(command, "chips")) return cmdChips(rest);
    if (equal(command, "build")) {   // `helix build file.hx` compiles one file; otherwise it runs build.hx
        let file = false;
        for (const arg of rest) {
            if (equal(arg, "--")) break;
            if (endsWith(arg, ".hx")) file = true;
        }
        if (!file) return cmdProjectBuild(rest);
    }

    const commands: string[6] = ["run", "build", "check", "ir", "ast", "tokens"];
    for (const name, i of commands) {
        if (!equal(command, name)) continue;
        const parsed = parseOptions(rest);
        if (parsed == null) return 1;
        let options: Options = parsed;
        if (i == 0) return cmdRun(&options);
        if (i == 1) return cmdBuild(&options);
        if (i == 2) return cmdCheck(&options);
        if (i == 3) return cmdIr(&options);
        if (i == 4) return cmdAst(&options);
        return cmdTokens(&options);
    }

    eprintln(`error: unknown command '${command}'\n`);
    usage(true);
    return 1;
}
