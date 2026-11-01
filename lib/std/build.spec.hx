/**
 * Imports
 */

import * as fmt from "./fmt";
import { ArrayList } from "./list";
import { Env, Init } from "./process";
import { Allocator, ArenaAllocator, alloc, cAllocator } from "./heap";
import { exists, makePath, readFile, writeFile, deleteTree } from "./fs";
import { Build, BuildError, CSources, ExecutableOptions, Mode, TestOptions, runBuild } from "./build";

/**
 * Tests
 */

extern "C" function chdir(path: readonly u8[*]): i32;
extern "C" function getcwd(buffer: u8[*], size: usize): ?u8[*];
extern "C" function getpid(): i32;

/**
 * The shell script that stands in for `helix build`, `helix cc`, and `helix test`.
 *
 * @remarks
 * The runner calls `<helix> build ...`, `<helix> cc ...`, and `<helix> test ...`.
 * With `/bin/sh` as the compiler, each of those runs the file named `build`, `cc`, or `test` in the project folder.
 * The script logs its name and arguments to `log.txt`,
 * and writes an executable script at the path after `-o` that logs `ran` and its own arguments when it runs.
 * Beside that script it writes a `.dSYM` folder, as a build for macOS does.
 *
 * @since 1.0.0
 */

const FakeCompiler: string = "echo \"$0 $*\" >> log.txt\nprev=\nfor a in \"$@\"; do\n    if [ \"$prev\" = -o ]; then printf '#!/bin/sh\\necho \"ran $*\" >> log.txt\\n' > \"$a\"; chmod +x \"$a\"; mkdir -p \"$a.dSYM/Contents\"; echo dwarf > \"$a.dSYM/Contents/DWARF\"; fi\n    prev=$a\ndone\n";

/**
 * The packages list of a project with one program, `app`, whose root is `src/main.hx`.
 *
 * @since 1.0.0
 */

const OneBin: string = "bin\t-\tapp\tsrc/main.hx\n";

/**
 * Makes an empty project folder under the temporary folder, with the fake compiler and a packages list.
 *
 * @param a - The allocator for the path
 * @param name - The name of the case, which ends the folder name
 * @param packages - The text of `packages.txt`
 * @returns The path of the folder
 *
 * @remarks
 * Any folder left at the path by an earlier run is removed first, so each case starts empty.
 * Every folder lives under one folder named after the process, which {@link cleanUp} removes.
 *
 * @since 1.0.0
 */

function project(a: dyn Allocator, name: string, packages: string): string | Error {
    const tmp = Env {}.get("TMPDIR") ?? "/tmp";
    const dir = try fmt.alloc(a, `${tmp}/helix-build-spec-${getpid()}/${name}`);
    deleteTree(dir) catch {};
    try makePath(dir);
    try writeFile(try fmt.alloc(a, `${dir}/packages.txt`), packages);
    try writeFile(try fmt.alloc(a, `${dir}/build`), FakeCompiler);
    try writeFile(try fmt.alloc(a, `${dir}/cc`), FakeCompiler);
    try writeFile(try fmt.alloc(a, `${dir}/test`), FakeCompiler);
    return dir;
}

/**
 * Removes every folder that {@link project} made.
 *
 * @remarks
 * A folder that is already gone is not an error.
 *
 * @since 1.0.0
 */

function cleanUp(): void {
    let arena = ArenaAllocator.init(cAllocator());
    defer arena.deinit();
    const tmp = Env {}.get("TMPDIR") ?? "/tmp";
    const root = fmt.alloc(arena.allocator(), `${tmp}/helix-build-spec-${getpid()}`) catch return;
    deleteTree(root) catch {};
}

/**
 * Runs the build runner inside a project folder, with `/bin/sh` as the compiler.
 *
 * @param a - The allocator for the paths and the argument list
 * @param dir - The project folder from {@link project}
 * @param args - The command line after the compiler and the packages list
 * @param build - The `build` function that stands in for the project's build.hx
 * @returns The status that {@link runBuild} returns
 * @throws Any error that {@link runBuild} throws
 *
 * @remarks
 * The runner writes `.helix-cache` and `.helix-out` relative to the current folder,
 * so it changes into `dir` for the run and back to the folder it started in afterwards, even when the run fails.
 *
 * @since 1.0.0
 */

function runIn(a: dyn Allocator, dir: string, args: readonly string[], build: (b: *Build) => void | Error): u8 | Error {
    const home = try alloc<u8>(a, 4096);
    void getcwd(home.ptr, home.len);
    void chdir((try fmt.alloc(a, `${dir}\0`)).ptr);
    defer void chdir(home.ptr);
    let words = ArrayList<string>.init(a);
    try words.append("/bin/sh");
    try words.append("packages.txt");
    for (const arg of args) try words.append(arg);
    return try runBuild(Init { program: "build-runner", args: words.items, env: Env {} }, build);
}

/**
 * Reads a file inside a project folder.
 *
 * @param a - The allocator for the contents
 * @param dir - The project folder
 * @param name - The path of the file, relative to the folder
 * @returns The contents of the file, or an empty string when it does not exist
 *
 * @remarks
 * The log of the fake compiler only exists once a command ran, so a missing file reads as nothing ran.
 *
 * @since 1.0.0
 */

function readIn(a: dyn Allocator, dir: string, name: string): string {
    const path = fmt.alloc(a, `${dir}/${name}`) catch return "";
    const bytes = readFile(a, path) catch return "";
    return bytes;
}

/**
 * Whether a file exists inside a project folder.
 *
 * @param a - The allocator for the path
 * @param dir - The project folder
 * @param name - The path of the file, relative to the folder
 * @returns `true` when anything is at the path
 *
 * @remarks
 * It joins the two paths and asks `exists` from std/fs.
 *
 * @since 1.0.0
 */

function existsIn(a: dyn Allocator, dir: string, name: string): bool {
    const path = fmt.alloc(a, `${dir}/${name}`) catch return false;
    return exists(path);
}

/**
 * The mode that the last build saw.
 *
 * @since 1.0.0
 */

let seenMode: Mode = Mode.Debug;

/**
 * The target that the last build saw.
 *
 * @since 1.0.0
 */

let seenTarget: ?string = null;

/**
 * The value that the last build read for a bool option.
 *
 * @since 1.0.0
 */

let seenBool: ?bool = null;

/**
 * The value that the last build read for a string option.
 *
 * @since 1.0.0
 */

let seenString: ?string = null;

/**
 * The value that the last build read for an int option.
 *
 * @since 1.0.0
 */

let seenInt: ?i64 = null;

/**
 * The first index that the last build observed.
 *
 * @since 1.0.0
 */

let seenFirst: usize = 0;

/**
 * The second index that the last build observed.
 *
 * @since 1.0.0
 */

let seenSecond: usize = 0;

/**
 * Whether the call that the last build expected to fail failed with `BuildError.BadOption`.
 *
 * @since 1.0.0
 */

let seenBadOption: bool = false;

/**
 * A build that adds nothing.
 *
 * @param _b - The build, unused
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * The project still gets the runner's own steps from its packages list.
 *
 * @since 1.0.0
 */

function emptyBuild(_b: *Build): void | Error {}

/**
 * A build that records the mode and the target.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It writes them to {@link seenMode} and {@link seenTarget}.
 *
 * @since 1.0.0
 */

function recordMode(b: *Build): void | Error {
    seenMode = b.mode;
    seenTarget = b.target;
}

/**
 * A build that compiles two C files into `app`, with an include folder and a flag.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * Both files share the `-DFAST` flag, and `include` is the include folder.
 *
 * @since 1.0.0
 */

function withCSources(b: *Build): void | Error {
    const app = try b.bin("app");
    try app.addCSources(CSources { files: ["c/a.c", "c/b.c"], flags: ["-DFAST"] });
    try app.addIncludeDir("include");
}

/**
 * A build that links `app` with the system library `z`.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It calls `linkSystemLibrary` once.
 *
 * @since 1.0.0
 */

function withLibrary(b: *Build): void | Error {
    try (try b.bin("app")).linkSystemLibrary("z");
}

/**
 * A build that gives `app` an options module named `config` with one value of each kind.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * The string value holds a quote, a backslash, and a newline, to show the escaping.
 *
 * @since 1.0.0
 */

function withOptions(b: *Build): void | Error {
    const config = try b.addOptions("config");
    try config.addBool("tracing", true);
    try config.addInt("port", -8080);
    try config.addString("greeting", "say \"hi\"\\\n");
    try config.add("export const raw: u8 = 7;");
    try (try b.bin("app")).addOptions(config);
}

/**
 * A build with a `gen` step that runs two commands, the second depending on the first.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * Each command appends a word to `log.txt`, so the log shows the order in which they ran.
 *
 * @since 1.0.0
 */

function withSteps(b: *Build): void | Error {
    const first = try b.addSystemCommand(["sh", "-c", "echo first >> log.txt"]);
    const second = try b.addSystemCommand(["sh", "-c", "echo second >> log.txt"]);
    try second.dependOn(first);
    const gen = try b.step("gen", "Generate the code");
    try gen.dependOn(second);
}

/**
 * A build with a `docs` step that depends on nothing.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * The step is a group without dependencies, so running it runs nothing.
 *
 * @since 1.0.0
 */

function withEmptyStep(b: *Build): void | Error {
    void try b.step("docs", "Write the docs");
}

/**
 * A build with a `check` step that runs a command that fails.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * The command exits with status 3.
 *
 * @since 1.0.0
 */

function withFailingStep(b: *Build): void | Error {
    const check = try b.step("check", "Fail on purpose");
    try check.dependOn(try b.addSystemCommand(["sh", "-c", "exit 3"]));
}

/**
 * A build that declares the option `level` and records the value that `declare` returns.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It also declares `level` a second time, which must not list it twice.
 *
 * @since 1.0.0
 */

function withDeclare(b: *Build): void | Error {
    seenString = b.declare("level", "string", "How loud to be");
    void b.declare("level", "string", "How loud to be");
}

/**
 * A build that reads the bool option `fast`.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It writes the value to {@link seenBool}.
 *
 * @since 1.0.0
 */

function withBool(b: *Build): void | Error {
    seenBool = b.optionBool("fast", "Build for speed");
}

/**
 * A build that reads the string option `name`.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It writes the value to {@link seenString}.
 *
 * @since 1.0.0
 */

function withString(b: *Build): void | Error {
    seenString = b.optionString("name", "The name to greet");
}

/**
 * A build that reads the int option `jobs`.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It writes the value to {@link seenInt}.
 *
 * @since 1.0.0
 */

function withInt(b: *Build): void | Error {
    seenInt = b.optionInt("jobs", "How many jobs");
}

/**
 * A build that adds two options modules and records their indices.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It writes the indices to {@link seenFirst} and {@link seenSecond}.
 *
 * @since 1.0.0
 */

function withTwoOptions(b: *Build): void | Error {
    seenFirst = (try b.addOptions("one")).index;
    seenSecond = (try b.addOptions("two")).index;
}

/**
 * A build that looks up `app` and a program that helix.jsonc does not name.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It records the index of `app` in {@link seenFirst} and whether the second lookup failed in {@link seenBadOption}.
 *
 * @since 1.0.0
 */

function withBin(b: *Build): void | Error {
    seenFirst = (try b.bin("app")).index;
    seenBadOption = false;
    void b.bin("ghost") catch (e) {
        seenBadOption = e == BuildError.BadOption;
        return;
    };
}

/**
 * A build that adds the executable `tool` without installing it.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * Nothing asks for the artifact, so nothing builds it.
 *
 * @since 1.0.0
 */

function withUnusedExecutable(b: *Build): void | Error {
    void try b.addExecutable({ name: "tool", root: "tools/tool.hx" });
}

/**
 * A build that adds `tool` twice with the same settings and once more in another mode.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It records the index of the second call in {@link seenFirst} and the index of the third in {@link seenSecond}.
 *
 * @since 1.0.0
 */

function withRepeatedExecutable(b: *Build): void | Error {
    const first = try b.addExecutable({ name: "tool", root: "tools/tool.hx" });
    seenFirst = (try b.addExecutable({ name: "tool", root: "tools/tool.hx" })).index - first.index;
    seenSecond = (try b.addExecutable({ name: "tool", root: "tools/tool.hx", mode: Mode.ReleaseFast })).index;
}

/**
 * A build that adds `tool` from two different roots.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It records whether the second call failed in {@link seenBadOption}.
 *
 * @since 1.0.0
 */

function withConflictingExecutable(b: *Build): void | Error {
    void try b.addExecutable({ name: "tool", root: "tools/tool.hx" });
    seenBadOption = false;
    void b.addExecutable({ name: "tool", root: "tools/other.hx" }) catch (e) {
        seenBadOption = e == BuildError.BadOption;
        return;
    };
}

/**
 * A build that adds an executable with the name of a program from helix.jsonc.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It records whether the call failed in {@link seenBadOption}.
 *
 * @since 1.0.0
 */

function withBinAsExecutable(b: *Build): void | Error {
    seenBadOption = false;
    void b.addExecutable({ name: "app", root: "src/main.hx" }) catch (e) {
        seenBadOption = e == BuildError.BadOption;
        return;
    };
}

/**
 * A build that installs `tool`, stripped, in release-fast mode.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * The install step copies it into `.helix-out/bin`.
 *
 * @since 1.0.0
 */

function withInstall(b: *Build): void | Error {
    try b.install(try b.addExecutable({ name: "tool", root: "tools/tool.hx", mode: Mode.ReleaseFast, strip: true }));
}

/**
 * A build with a `release` step that installs `tool` into `.helix-out/release/x`.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * The step is the only thing that asks for the artifact.
 *
 * @since 1.0.0
 */

function withAddInstall(b: *Build): void | Error {
    const tool = try b.addExecutable({ name: "tool", root: "tools/tool.hx" });
    const release = try b.step("release", "Install the release build");
    try release.dependOn(try b.addInstall(tool, "release/x"));
}

/**
 * A build with a `release` step that copies `notes/readme.txt` and the `notes` folder into `.helix-out/release`.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * The file goes into `release/docs`, and what the folder holds into `release/notes`.
 *
 * @since 1.0.0
 */

function withInstallCopies(b: *Build): void | Error {
    const release = try b.step("release", "Copy the notes");
    try release.dependOn(try b.addInstallFile("notes/readme.txt", "release/docs"));
    try release.dependOn(try b.addInstallFolder("notes", "release/notes"));
}

/**
 * A build whose own `run` step runs `tool` instead of `app`.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It replaces the default `run` step of the runner.
 *
 * @since 1.0.0
 */

function withRunStep(b: *Build): void | Error {
    try b.addRunStep(try b.addExecutable({ name: "tool", root: "tools/tool.hx" }));
}

/**
 * A build whose own `test` step tests `specs` in release-safe mode.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It replaces the default `test` step of the runner.
 *
 * @since 1.0.0
 */

function withTestStep(b: *Build): void | Error {
    try b.addTestStep({ root: "specs", mode: Mode.ReleaseSafe });
}

/**
 * A build that adds two steps named `gen`.
 *
 * @param b - The build
 * @returns Nothing, or the error that a call on the build threw
 *
 * @remarks
 * It records whether the second call failed in {@link seenBadOption}.
 *
 * @since 1.0.0
 */

function withDuplicateStep(b: *Build): void | Error {
    void try b.step("gen", "Generate the code");
    seenBadOption = false;
    void b.step("gen", "Generate the code again") catch (e) {
        seenBadOption = e == BuildError.BadOption;
        return;
    };
}

describe("BuildError") {
    test("should fail with BadPackageList for a packages line that is not a bin") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "bad-packages", "lib\t-\tx\tsrc/x.hx\n");

        expect(runIn(a, dir, [], emptyBuild)).toThrow(BuildError.BadPackageList);
        cleanUp();
    }
}

describe("Mode") {
    test("should read the mode that --mode names") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "mode", "");
        const status = try runIn(a, dir, ["--mode", "release-small", "--steps"], recordMode);

        expect(status).toBe(0);
        expect(seenMode == Mode.ReleaseSmall).toBeTrue();
        cleanUp();
    }

    test("should default to debug without --mode") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "mode-default", "");
        seenMode = Mode.ReleaseFast;
        void try runIn(a, dir, ["--steps"], recordMode);

        expect(seenMode == Mode.Debug).toBeTrue();
        expect(seenTarget).toBeNull();
        cleanUp();
    }
}

describe("ExecutableOptions") {
    test("should leave every setting but the name and the root to the build") {
        const options = ExecutableOptions { name: "tool", root: "tools/tool.hx" };

        expect(options.target).toBeNull();
        expect(options.mode == null).toBeTrue();
        expect(options.strip).toBeFalse();
        expect(options.cpu).toBeNull();
        expect(options.linkerScript).toBeNull();
    }
}

describe("TestOptions") {
    test("should leave the target, the mode, and the linked artifact to the build") {
        const options = TestOptions { root: "src" };

        expect(options.target).toBeNull();
        expect(options.mode == null).toBeTrue();
        expect(options.linkWith == null).toBeTrue();
    }
}

describe("CSources") {
    test("should start without flags") {
        const sources = CSources { files: ["a.c"] };

        expect(sources.flags.len).toBe(0);
    }
}

describe("Artifact") {
    describe("addCSources") {
        test("should compile each file once and link the objects into the artifact") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "c-sources", OneBin);
            const status = try runIn(a, dir, [], withCSources);
            const log = readIn(a, dir, "log.txt");

            expect(status).toBe(0);
            expect(log).toInclude("cc -c c/a.c -o .helix-cache/c/host/debug/app.c/0.o -O0 -g -Iinclude -DFAST\n");
            expect(log).toInclude("cc -c c/b.c -o .helix-cache/c/host/debug/app.c/1.o -O0 -g -Iinclude -DFAST\n");
            expect(log).toInclude("--link .helix-cache/c/host/debug/app.c/0.o --link .helix-cache/c/host/debug/app.c/1.o");
            cleanUp();
        }

        test("should compile with the optimization flag of the mode") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "c-sources-mode", OneBin);
            void try runIn(a, dir, ["--mode", "release-fast"], withCSources);

            expect(readIn(a, dir, "log.txt")).toInclude("-o .helix-cache/c/host/release-fast/app.c/0.o -O3 -Iinclude");
            cleanUp();
        }
    }

    describe("addIncludeDir") {
        test("should pass the folder to the C compiler with -I") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "include-dir", OneBin);
            void try runIn(a, dir, [], withCSources);

            expect(readIn(a, dir, "log.txt")).toInclude(" -Iinclude ");
            cleanUp();
        }
    }

    describe("linkSystemLibrary") {
        test("should link the library with -l") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "system-library", OneBin);
            void try runIn(a, dir, [], withLibrary);

            expect(readIn(a, dir, "log.txt")).toInclude("build src/main.hx -o .helix-cache/bin/host/debug/app --mode debug -lz\n");
            cleanUp();
        }
    }

    describe("addOptions") {
        test("should hand the options module to the compiler as a package") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "artifact-options", OneBin);
            void try runIn(a, dir, [], withOptions);

            expect(readIn(a, dir, "log.txt")).toInclude("--pkg config=.helix-cache/options/config.hx\n");
            expect(existsIn(a, dir, ".helix-cache/options/config.hx")).toBeTrue();
            cleanUp();
        }
    }
}

describe("Options") {
    describe("addBool") {
        test("should write a bool constant") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "options-bool", OneBin);
            void try runIn(a, dir, [], withOptions);

            expect(readIn(a, dir, ".helix-cache/options/config.hx")).toInclude("export const tracing: bool = true;\n");
            cleanUp();
        }
    }

    describe("addInt") {
        test("should write an i64 constant") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "options-int", OneBin);
            void try runIn(a, dir, [], withOptions);

            expect(readIn(a, dir, ".helix-cache/options/config.hx")).toInclude("export const port: i64 = -8080;\n");
            cleanUp();
        }
    }

    describe("addString") {
        test("should write a string constant with quotes, backslashes, and newlines escaped") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "options-string", OneBin);
            void try runIn(a, dir, [], withOptions);

            expect(readIn(a, dir, ".helix-cache/options/config.hx"))
                .toInclude("export const greeting: string = \"say \\\"hi\\\"\\\\\\n\";\n");
            cleanUp();
        }
    }

    describe("add") {
        test("should write the line as it is, after a generated header") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "options-add", OneBin);
            void try runIn(a, dir, [], withOptions);
            const text = readIn(a, dir, ".helix-cache/options/config.hx");

            expect(text).toStartWith("// Generated by build.hx's addOptions(\"config\")");
            expect(text).toEndWith("export const raw: u8 = 7;\n");
            cleanUp();
        }
    }
}

describe("Step") {
    describe("dependOn") {
        test("should run what a step depends on first") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "depend-on", "");
            const status = try runIn(a, dir, ["gen"], withSteps);

            expect(status).toBe(0);
            expect(readIn(a, dir, "log.txt")).toBe("first\nsecond\n");
            cleanUp();
        }
    }
}

describe("Build") {
    describe("declare") {
        test("should return the value of the option and accept it") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "declare", "");
            const status = try runIn(a, dir, ["--level=high", "--steps"], withDeclare);

            expect(status).toBe(0);
            expect(seenString).toBe("high");
            cleanUp();
        }

        test("should return null for an option that the command line leaves out") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "declare-absent", "");
            void try runIn(a, dir, ["--steps"], withDeclare);

            expect(seenString).toBeNull();
            cleanUp();
        }
    }

    describe("optionBool") {
        test("should read a bare option as true") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "bool-bare", "");
            void try runIn(a, dir, ["--fast", "--steps"], withBool);

            expect(seenBool).toBe(true);
            cleanUp();
        }

        test("should read false") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "bool-false", "");
            void try runIn(a, dir, ["--fast=false", "--steps"], withBool);

            expect(seenBool).toBe(false);
            cleanUp();
        }

        test("should return null for an option that the command line leaves out") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "bool-absent", "");
            void try runIn(a, dir, ["--steps"], withBool);

            expect(seenBool).toBeNull();
            cleanUp();
        }
    }

    describe("optionString") {
        test("should read the text after the equals sign") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "string", "");
            void try runIn(a, dir, ["--name=a=b", "--steps"], withString);

            expect(seenString).toBe("a=b");
            cleanUp();
        }
    }

    describe("optionInt") {
        test("should parse the value as a whole number") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "int", "");
            void try runIn(a, dir, ["--jobs=-12", "--steps"], withInt);

            expect(seenInt).toBe(-12);
            cleanUp();
        }
    }

    describe("addOptions") {
        test("should hand out one module per call, in order") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "add-options", "");
            void try runIn(a, dir, ["--steps"], withTwoOptions);

            expect(seenFirst).toBe(0);
            expect(seenSecond).toBe(1);
            cleanUp();
        }
    }

    describe("bin") {
        test("should find the program of helix.jsonc and reject a name it does not list") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "bin", OneBin);
            void try runIn(a, dir, ["--steps"], withBin);

            expect(seenFirst).toBe(0);
            expect(seenBadOption).toBeTrue();
            cleanUp();
        }
    }

    describe("addExecutable") {
        test("should build nothing until a step needs the artifact") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "executable-unused", "");
            const status = try runIn(a, dir, [], withUnusedExecutable);

            expect(status).toBe(0);
            expect(readIn(a, dir, "log.txt")).toBe("");
            cleanUp();
        }

        test("should give the same artifact for the same settings and a new one for another mode") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "executable-repeat", "");
            void try runIn(a, dir, ["--steps"], withRepeatedExecutable);

            expect(seenFirst).toBe(0);
            expect(seenSecond).toBe(1);
            cleanUp();
        }

        test("should reject the same program from two roots") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "executable-conflict", "");
            void try runIn(a, dir, ["--steps"], withConflictingExecutable);

            expect(seenBadOption).toBeTrue();
            cleanUp();
        }

        test("should reject a program that helix.jsonc already builds") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "executable-bin", OneBin);
            void try runIn(a, dir, ["--steps"], withBinAsExecutable);

            expect(seenBadOption).toBeTrue();
            cleanUp();
        }
    }

    describe("install") {
        test("should build the artifact and copy it into .helix-out/bin") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "install", "");
            const status = try runIn(a, dir, [], withInstall);

            expect(status).toBe(0);
            expect(readIn(a, dir, "log.txt"))
                .toBe("build tools/tool.hx -o .helix-cache/bin/host/release-fast/tool --mode release-fast --strip\n");
            expect(existsIn(a, dir, ".helix-out/bin/tool")).toBeTrue();
            cleanUp();
        }

        test("should copy the debug info folder of the program beside it") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "install-symbols", "");
            void try runIn(a, dir, [], withInstall);

            expect(readIn(a, dir, ".helix-out/bin/tool.dSYM/Contents/DWARF")).toBe("dwarf\n");
            cleanUp();
        }

        test("should add the suffix of the target to the file name") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "install-windows", "");
            void try runIn(a, dir, ["--target", "x86_64-windows"], withInstall);

            expect(existsIn(a, dir, ".helix-out/bin/tool.exe")).toBeTrue();
            cleanUp();
        }
    }

    describe("addInstall") {
        test("should copy the artifact into the folder under .helix-out when its step runs") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "add-install", "");
            void try runIn(a, dir, [], withAddInstall);
            const before = existsIn(a, dir, ".helix-out/release/x/tool");
            void try runIn(a, dir, ["release"], withAddInstall);

            expect(before).toBeFalse();
            expect(existsIn(a, dir, ".helix-out/release/x/tool")).toBeTrue();
            cleanUp();
        }
    }

    describe("addInstallFile") {
        test("should copy the file into the folder under .helix-out, keeping its name") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "install-file", "");
            try makePath(try fmt.alloc(a, `${dir}/notes/more`));
            try writeFile(try fmt.alloc(a, `${dir}/notes/readme.txt`), "read me\n");
            try writeFile(try fmt.alloc(a, `${dir}/notes/more/later.txt`), "later\n");
            void try runIn(a, dir, ["release"], withInstallCopies);

            expect(readIn(a, dir, ".helix-out/release/docs/readme.txt")).toBe("read me\n");
            cleanUp();
        }
    }

    describe("addInstallFolder") {
        test("should copy everything in the folder, the folders inside it too") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "install-folder", "");
            try makePath(try fmt.alloc(a, `${dir}/notes/more`));
            try writeFile(try fmt.alloc(a, `${dir}/notes/readme.txt`), "read me\n");
            try writeFile(try fmt.alloc(a, `${dir}/notes/more/later.txt`), "later\n");
            void try runIn(a, dir, ["release"], withInstallCopies);

            expect(readIn(a, dir, ".helix-out/release/notes/readme.txt")).toBe("read me\n");
            expect(readIn(a, dir, ".helix-out/release/notes/more/later.txt")).toBe("later\n");
            cleanUp();
        }

        test("should leave nothing that an earlier build put in the folder") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "install-folder-stale", "");
            try makePath(try fmt.alloc(a, `${dir}/notes`));
            try writeFile(try fmt.alloc(a, `${dir}/notes/readme.txt`), "read me\n");
            try makePath(try fmt.alloc(a, `${dir}/.helix-out/release/notes`));
            try writeFile(try fmt.alloc(a, `${dir}/.helix-out/release/notes/old.txt`), "old\n");
            void try runIn(a, dir, ["release"], withInstallCopies);

            expect(existsIn(a, dir, ".helix-out/release/notes/old.txt")).toBeFalse();
            cleanUp();
        }
    }

    describe("addRunStep") {
        test("should replace the default run step and pass the arguments after --") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "run-step", OneBin);
            const status = try runIn(a, dir, ["run", "--", "one", "two"], withRunStep);

            expect(status).toBe(0);
            expect(readIn(a, dir, "log.txt"))
                .toBe("build tools/tool.hx -o .helix-cache/bin/host/debug/tool --mode debug\nran one two\n");
            cleanUp();
        }
    }

    describe("addTestStep") {
        test("should replace the default test step") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "test-step", OneBin);
            void try runIn(a, dir, ["test"], withTestStep);

            expect(readIn(a, dir, "log.txt")).toBe("test specs --mode release-safe\n");
            cleanUp();
        }

        test("should test src by default") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "test-default", "");
            void try runIn(a, dir, ["test", "--target", "x86_64-linux-gnu"], emptyBuild);

            expect(readIn(a, dir, "log.txt")).toBe("test src --mode debug --target x86_64-linux-gnu\n");
            cleanUp();
        }
    }

    describe("step") {
        test("should add a named step that does no work of its own") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "step", "");
            const status = try runIn(a, dir, ["docs"], withEmptyStep);

            expect(status).toBe(0);
            expect(readIn(a, dir, "log.txt")).toBe("");
            cleanUp();
        }
    }

    describe("addSystemCommand") {
        test("should fail the build when the command exits with a status other than 0") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "command-fails", "");

            expect(try runIn(a, dir, ["check"], withFailingStep)).toBe(1);
            cleanUp();
        }
    }

    describe("addStep") {
        test("should reject a second step with the same name") {
            let arena = ArenaAllocator.init(cAllocator());
            defer arena.deinit();
            const a = arena.allocator();
            const dir = try project(a, "duplicate-step", "");
            void try runIn(a, dir, ["--steps"], withDuplicateStep);

            expect(seenBadOption).toBeTrue();
            cleanUp();
        }
    }
}

describe("runBuild") {
    test("should install every program of helix.jsonc when no step is named") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "default-install", OneBin);
        const status = try runIn(a, dir, [], emptyBuild);

        expect(status).toBe(0);
        expect(existsIn(a, dir, ".helix-out/bin/app")).toBeTrue();
        cleanUp();
    }

    test("should refuse to start without the compiler and the packages list") {
        expect(try runBuild(Init { program: "build-runner", args: ["/bin/sh"], env: Env {} }, emptyBuild)).toBe(2);
    }

    test("should return 2 for a step that the build does not have") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "unknown-step", "");

        expect(try runIn(a, dir, ["deploy"], emptyBuild)).toBe(2);
        cleanUp();
    }

    test("should return 2 for an option it does not know") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "unknown-option", "");

        expect(try runIn(a, dir, ["-x"], emptyBuild)).toBe(2);
        expect(try runIn(a, dir, ["-Dfast"], emptyBuild)).toBe(2);
        cleanUp();
    }

    test("should return 2 for an option that the build never declares") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "undeclared", "");

        expect(try runIn(a, dir, ["--fast"], emptyBuild)).toBe(2);
        expect(try runIn(a, dir, ["--level=high"], emptyBuild)).toBe(2);
        cleanUp();
    }

    test("should return 2 for a mode it does not know") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "unknown-mode", "");

        expect(try runIn(a, dir, ["--mode", "fastest"], emptyBuild)).toBe(2);
        cleanUp();
    }

    test("should return 2 for --target without a value") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "target-without-value", "");

        expect(try runIn(a, dir, ["--target"], emptyBuild)).toBe(2);
        cleanUp();
    }

    test("should print the help and run nothing for --help") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "help", OneBin);
        const status = try runIn(a, dir, ["--help"], emptyBuild);

        expect(status).toBe(0);
        expect(readIn(a, dir, "log.txt")).toBe("");
        cleanUp();
    }

    test("should read the target that --target names") {
        let arena = ArenaAllocator.init(cAllocator());
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try project(a, "target", "");
        void try runIn(a, dir, ["--target", "riscv64-linux", "--steps"], recordMode);

        expect(seenTarget).toBe("riscv64-linux");
        cleanUp();
    }
}
