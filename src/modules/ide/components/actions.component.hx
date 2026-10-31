/**
 * Imports
 */

import { Builder } from "std/fmt";
import * as os from "@modules/driver/components/os.component";
import { llvmTool } from "@modules/driver/components/libc.component";
import { buildExecutable } from "@modules/driver/components/compile.component";
import { Action } from "@modules/ide/components/structs/actions-component.struct";
import { allocCString, add, strings } from "@modules/driver/components/os.component";
import { Options } from "@modules/driver/components/structs/compile-component.struct";
import { buffer, raw, quoted, quotedList, writeKey } from "@modules/ide/components/json.component";

/**
 * Finds the project that a file belongs to.
 *
 * @param file - The path of a file, or of a folder
 * @returns The nearest folder up that holds a `helix.jsonc`, or the file's own folder when none does
 *
 * @remarks
 * A folder that holds a `helix.jsonc` itself is its own project.
 * The walk stops below the root, so `/helix.jsonc` is never found.
 * A bare file name without a slash belongs to `.`.
 *
 * @example
 * ```hx
 * // /p/helix.jsonc exists
 * projectDir("/p/src/main.hx"); // '/p'
 * projectDir("/tmp/main.hx");   // '/tmp'
 * projectDir("main.hx");        // '.'
 * ```
 *
 * @since 1.0.0
 */

export function projectDir(file: string): string {
    if (os.isDirectory(file) && os.readable(allocCString(`${file}/helix.jsonc`))) return file;
    const slash = os.lastIndex(file, '/') ?? 0;
    const own = slash > 0 ? file[0..slash] : ".";
    let dir = own;
    while (true) {
        if (os.readable(allocCString(`${dir}/helix.jsonc`))) return dir;
        const up = os.lastIndex(dir, '/') ?? 0;
        if (up == 0) return own;
        dir = dir[0..up];
    }
}

/**
 * Creates an action whose command line starts with this compiler.
 *
 * @param kind - The kind of the action
 * @param title - The label that the editor shows
 * @param cwd - The folder that the command runs in
 * @param file - The file or folder that the action is about, or an empty string
 * @returns The action, with only the compiler on its command line and no names
 *
 * @remarks
 * The compiler is the helix that answered the editor, found through its own executable path,
 * so the editor and the command line always agree.
 * It falls back to `helix` when that path is unknown.
 *
 * @since 1.0.0
 */

function action(kind: string, title: string, cwd: string, file: string): Action {
    let argv = strings();
    add(&argv, os.compilerPath() ?? "helix");
    return Action { kind, title, cwd, argv, file, name: strings() };
}

/**
 * Creates the action that runs the program that a file holds.
 *
 * @param file - The file that holds the program
 * @returns The `run` action, titled `▶ Run`
 *
 * @remarks
 * When the project has a `build.hx`, the action runs `helix build run`,
 * since the script may add C sources, options, or libraries.
 * Otherwise it runs `helix run <file>`.
 *
 * @example
 * ```hx
 * runAction("/p/main.hx").argv;        // [ '/usr/local/bin/helix', 'run', '/p/main.hx' ]
 * runAction("/scripted/main.hx").argv; // [ '/usr/local/bin/helix', 'build', 'run' ]
 * ```
 *
 * @since 1.0.0
 */

export function runAction(file: string): Action {
    const dir = projectDir(file);
    let a = action("run", "▶ Run", dir, file);
    if (os.readable(allocCString(`${dir}/build.hx`))) {
        add(&a.argv, "build");
        add(&a.argv, "run");
    } else {
        add(&a.argv, "run");
        add(&a.argv, file);
    }
    return a;
}

/**
 * Creates the action that debugs the program that a file holds.
 *
 * @param file - The file that holds the program
 * @returns The `debug` action, which runs `helix debug-launch <file>` in the project folder
 *
 * @remarks
 * The action passes the file itself, not the project, so a debug session always starts from the file it names.
 * Unlike {@link runAction}, it never switches to `build run` when the project has a `build.hx`.
 *
 * @example
 * ```hx
 * debugAction("/p/main.hx").argv; // [ '/usr/local/bin/helix', 'debug-launch', '/p/main.hx' ]
 * ```
 *
 * @see cmdDebugLaunch
 * @since 1.0.0
 */

export function debugAction(file: string): Action {
    let a = action("debug", "Debug", projectDir(file), file);
    add(&a.argv, "debug-launch");
    add(&a.argv, file);
    return a;
}

/**
 * Creates the action that builds the project around a file.
 *
 * @param file - A file of the project
 * @returns The `build` action, which builds the whole project, or the file alone outside a project
 *
 * @remarks
 * The action passes the file only when the folder from {@link projectDir} holds no `helix.jsonc`.
 * Inside a project, `helix build` reads the configuration and builds every entry, so the action carries no file.
 * The action has no file of its own, so it applies to the project rather than to the file that offered it.
 *
 * @example
 * ```hx
 * buildAction("/p/src/main.hx").argv; // [ '/usr/local/bin/helix', 'build' ]
 * buildAction("/tmp/main.hx").argv;   // [ '/usr/local/bin/helix', 'build', '/tmp/main.hx' ]
 * ```
 *
 * @since 1.0.0
 */

export function buildAction(file: string): Action {
    const dir = projectDir(file);
    let a = action("build", "Build", dir, "");
    add(&a.argv, "build");
    if (!os.readable(allocCString(`${dir}/helix.jsonc`))) add(&a.argv, file);
    return a;
}

/**
 * Quotes a text for a POSIX extended regex, as the `-f` option of the test runner takes it.
 *
 * @param text - The text to match literally
 * @returns The text with a backslash before each of `.[](){}*+?^$|` and the backslash itself
 *
 * @remarks
 * Test names are free text, so a name such as `a (b)` would otherwise read as a group in the `-f` pattern.
 * The function escapes bytes one at a time and leaves every other byte, including UTF-8 bytes, as it is.
 *
 * @since 1.0.0
 */

function regexQuote(text: string): string {
    let b = buffer();
    for (const ch, i of text) {
        const special = ch == '.' || ch == '[' || ch == ']' || ch == '(' || ch == ')' || ch == '{' || ch == '}' || ch == '*' ||
                        ch == '+' || ch == '?' || ch == '^' || ch == '$' || ch == '|' || ch == '\\';
        if (special) raw(&b, "\\");
        raw(&b, text[i..i + 1]);
    }
    return allocCString(`${b.text()}`);
}

/**
 * Creates the action that runs the tests of a spec, or of a folder of specs.
 *
 * @param file - The spec file, or a folder of them
 * @param names - The names of one describe or test, outermost first, or none for every test
 * @param describe - Whether the names point at a describe rather than at a single test
 * @returns The `test` action, whose command line ends with `--reporter`
 *
 * @remarks
 * The test runner matches `-f` against the names of a test joined with spaces.
 * The action joins the quoted names the same way and anchors them with `^`.
 * A test ends with `$`, and a describe ends with a space, so it matches every test inside it.
 * The client appends the reporter it wants after the closing `--reporter`.
 *
 * @example
 * ```hx
 * const names: string[2] = ["parser", "should read"];
 * testAction("/p/a.spec.hx", &names, false).argv;
 * // [ '/usr/local/bin/helix', 'test', '/p/a.spec.hx', '-f', '^parser should read$', '--reporter' ]
 * ```
 *
 * @since 1.0.0
 */

export function testAction(file: string, names: readonly string[], describe: bool): Action {
    const title = names.len == 0 || describe ? "▶ Run tests" : "▶ Run test";
    let a = action("test", title, projectDir(file), file);
    add(&a.argv, "test");
    add(&a.argv, file);
    if (names.len > 0) {
        let joined = "";
        for (const n, i of names) {
            joined = allocCString(`${joined}${i > 0 ? " " : ""}${regexQuote(n)}`);
            add(&a.name, n);
        }
        add(&a.argv, "-f");
        add(&a.argv, describe ? allocCString(`^${joined} `) : allocCString(`^${joined}$`));
    }
    add(&a.argv, "--reporter");
    return a;
}

/**
 * Appends an action to a buffer as a JSON object.
 *
 * @param b - The buffer to append to
 * @param a - The action to write
 *
 * @remarks
 * The `file` member is left out while the file is an empty string, and the `name` member while there are no names.
 *
 * @example
 * ```hx
 * writeAction(&b, &action);
 * b.text(); // '{"kind":"build","title":"Build","cwd":"/p","argv":["helix","build"]}'
 * ```
 *
 * @see Action
 * @since 1.0.0
 */

export function writeAction(b: *Builder, a: readonly *Action): void {
    raw(b, "{");
    writeKey(b, "kind", true);
    quoted(b, a.kind);
    writeKey(b, "title", false);
    quoted(b, a.title);
    writeKey(b, "cwd", false);
    quoted(b, a.cwd);
    writeKey(b, "argv", false);
    quotedList(b, a.argv.items);
    if (a.file.len > 0) {
        writeKey(b, "file", false);
        quoted(b, a.file);
    }
    if (a.name.items.len > 0) {
        writeKey(b, "name", false);
        quotedList(b, a.name.items);
    }
    raw(b, "}");
}

/**
 * Appends the actions of a whole project to a buffer, for the command palette of an editor.
 *
 * @param b - The buffer to append to
 * @param file - A file of the project
 *
 * @remarks
 * The array holds the build action, then `Run`, which runs `helix build run`, when the project has a `helix.jsonc`,
 * then `Test`, which runs every spec of the project folder.
 * The language server answers its `helix/projectActions` request with it.
 *
 * @example
 * ```hx
 * writeProjectActions(&b, "/p/src/main.hx");
 * b.text(); // '[{"kind":"build",...},{"kind":"run","title":"Run",...},{"kind":"test","title":"Test",...}]'
 * ```
 *
 * @since 1.0.0
 */

export function writeProjectActions(b: *Builder, file: string): void {
    const dir = projectDir(file);
    raw(b, "[");
    const build = buildAction(file);
    writeAction(b, &build);
    if (os.readable(allocCString(`${dir}/helix.jsonc`))) {
        let run = action("run", "Run", dir, "");
        add(&run.argv, "build");
        add(&run.argv, "run");
        raw(b, ",");
        writeAction(b, &run);
    }
    let tests = testAction(dir, strings().items, true);
    tests.title = "Test";
    raw(b, ",");
    writeAction(b, &tests);
    raw(b, "]");
}

/**
 * Runs `helix actions <file or folder>`, which prints the actions for it as a JSON array.
 *
 * @param args - The arguments after `actions`, which must be exactly one path
 * @returns 0 after printing the actions, or 1 for a wrong argument count or a path that cannot be read
 *
 * @remarks
 * The array holds the build action, then run and debug for a file, then the tests of the file or folder.
 * Editors use it for the run configurations that a person makes, so those run exactly what the lenses run.
 *
 * @example
 * ```hx
 * const args: string[1] = ["src/main.hx"];
 * cmdActions(&args); // 0, after printing [{"kind":"build",...},{"kind":"run",...},...]
 * ```
 *
 * @since 1.0.0
 */

export function cmdActions(args: readonly string[]): u8 {
    if (args.len != 1) {
        eprintln("usage: helix actions <file.hx or folder>");
        return 1;
    }
    const target = os.realPath(args[0]);
    if (target == null) {
        eprintln(`error: cannot read '${args[0]}': ${os.strerror(os.errno())}`);
        return 1;
    }
    const path: string = target;
    let b = buffer();
    raw(&b, "[");
    const build = buildAction(path);
    writeAction(&b, &build);
    if (!os.isDirectory(path)) {
        const run = runAction(path);
        const debug = debugAction(path);
        raw(&b, ",");
        writeAction(&b, &run);
        raw(&b, ",");
        writeAction(&b, &debug);
    }
    const tests = testAction(path, strings().items, true);
    raw(&b, ",");
    writeAction(&b, &tests);
    raw(&b, "]");
    println(b.text());
    return 0;
}

/**
 * Finds the `lldb-dap` debug adapter.
 *
 * @returns The path of the adapter, or `null` when there is none
 *
 * @remarks
 * The search goes through these places in order and stops at the first one that gives an adapter:
 *
 * - the path in `HELIX_LLDB_DAP`, which is used as it is
 * - the `bin` folder of the LLVM that Helix uses
 * - Xcode, then the command-line tools, then Homebrew's LLVM
 * - every folder in `PATH`
 *
 * @example
 * ```hx
 * debugAdapter(); // '/Library/Developer/CommandLineTools/usr/bin/lldb-dap'
 * ```
 *
 * @since 1.0.0
 */

export function debugAdapter(): ?string {
    if (const configured = os.getenvSet("HELIX_LLDB_DAP")) return configured;
    if (const llvm = llvmTool("lldb-dap")) return llvm;
    const candidates: string[3] = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap",
        "/Library/Developer/CommandLineTools/usr/bin/lldb-dap",
        "/opt/homebrew/opt/llvm/bin/lldb-dap",
    ];
    for (const path of candidates) {
        if (os.executable(path)) return path;
    }
    if (const path = os.getenv("PATH")) {
        let start: usize = 0;
        for (const c, i of path) {
            if (c != ':' && i + 1 < path.len) continue;
            const dir = path[start..c == ':' ? i : i + 1];
            start = i + 1;
            const candidate = allocCString(`${dir}/lldb-dap`);
            if (dir.len > 0 && os.executable(candidate)) return candidate;
        }
    }
    return null;
}

/**
 * Runs `helix debug-launch <file.hx> [build options] [-- program args]`.
 *
 * @param options - The build options, whose file is the program to debug
 * @returns 0 after printing the launch settings, or 1 when the output folder, the build, or the adapter fails
 *
 * @remarks
 * It builds the program in debug mode into `<project>/helix-out/debug/`,
 * then prints how a debug adapter client starts it, as `{ "adapter", "program", "args", "cwd", "initCommands" }`.
 * The adapter is the `lldb-dap` that {@link debugAdapter} finds.
 * The init commands load the lldb formatters of Helix from `lib/lldb/helix.py` beside the compiler,
 * and stay empty when that file is missing.
 * Build errors go to stderr.
 *
 * @example
 * ```hx
 * cmdDebugLaunch(&options);
 * // 0, after printing {"adapter":"/usr/bin/lldb-dap","program":"/p/helix-out/debug/main",...}
 * ```
 *
 * @see debugAction
 * @since 1.0.0
 */

export function cmdDebugLaunch(options: *Options): u8 {
    const file = os.realPath(options.file) ?? options.file;
    const dir = projectDir(file);
    const outDir = allocCString(`${dir}/helix-out/debug`);
    if (!os.makeDirs(outDir)) {
        eprintln(`error: cannot create ${outDir}: ${os.strerror(os.errno())}`);
        return 1;
    }
    const exe = allocCString(`${outDir}/${os.fileStem(file)}`);
    if (!buildExecutable(options, exe)) return 1;
    const adapter = debugAdapter();
    if (adapter == null) {
        eprintln("error: no lldb-dap to debug with");
        eprintln("  = hint: it comes with Xcode's command-line tools (`xcode-select --install`), or set HELIX_LLDB_DAP");
        return 1;
    }
    let b = buffer();
    raw(&b, "{");
    writeKey(&b, "adapter", true);
    quoted(&b, adapter);
    writeKey(&b, "program", false);
    quoted(&b, exe);
    writeKey(&b, "args", false);
    quotedList(&b, options.runArgs);
    writeKey(&b, "cwd", false);
    quoted(&b, dir);
    writeKey(&b, "initCommands", false);
    raw(&b, "[");
    if (const formatters = os.besideCompiler("lib/lldb/helix.py")) {
        if (os.readable(formatters)) quoted(&b, allocCString(`command script import "${formatters}"`));
    }
    raw(&b, "]}");
    println(b.text());
    return 0;
}
