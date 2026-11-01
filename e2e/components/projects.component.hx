/**
 * Imports
 */

import { copyFile } from "std/fs";
import { ArrayList } from "std/list";
import { Run } from "../structs/run.struct";
import { lines, startsWith } from "std/text";
import { snippets, writeText, elfMachine } from "../services/run.service";
import { pass, fail, text, helix, words, contains, ElfX86, copyTree, readText } from "../services/run.service";

/**
 * A build script that breaks a rule of `helix.jsonc`, and the error that it must give.
 *
 * @remarks
 * {@link checkBuildRules} puts `call` into the `build` function of the `bins` project.
 *
 * @since 1.0.0
 */

struct BuildRule {
    /**
     * The call to the builder, such as `b.bin("nope")`.
     *
     * @since 1.0.0
     */

    call: string,

    /**
     * A fragment of the error that `helix build` must print.
     *
     * @since 1.0.0
     */

    error: string,
}

/**
 * Runs the commands of each project in `e2e/projects` in a copy of the project, then the rules of a build script.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * A project's `expect.txt` holds `$ <arguments>` lines, each followed by lines that the stdout of
 * `helix <arguments>` must hold, and `#` lines are comments.
 * The commands run in a copy of the project in the temporary folder, so a build leaves nothing in the repository.
 * A project without an `expect.txt` is a package that another one uses, and has no commands of its own.
 *
 * @example
 * ```hx
 * try checkProjects(&run); // ✗ e2e/projects/bins (build run: missing output: hello from greet), for each failure
 * ```
 *
 * @since 1.0.0
 */

export function checkProjects(run: *Run): void | Error {
    for (const project of try snippets(run, "e2e/projects", true)) {
        const expectFile = try text(run, `${project}/expect.txt`);
        const script = readText(run, expectFile) catch continue;
        const copy = try text(run, `${run.temp}/${project}`);
        try copyTree(run, project, copy);
        try runScript(run, project, copy, script);
    }
    try checkBuildRules(run);
    try checkBuildOnly(run);
}

/**
 * Runs the commands of one `expect.txt` and checks their output.
 *
 * @param run - The run
 * @param project - The project in the repository, which names a failure
 * @param dir - The copy of the project that the commands run in
 * @param script - The text of `expect.txt`
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Each command must exit with 0, and the project passes when every command does what it expects.
 *
 * @since 1.0.0
 */

function runScript(run: *Run, project: string, dir: string, script: string): void | Error {
    let commandLine: ?string = null;
    let wanted = ArrayList<string>.init(run.a);
    let ok = true;
    let rows = lines(script);
    while (const row = rows.next()) {
        if (startsWith(row, "$ ")) {
            if (const line = commandLine) ok = (try runCommand(run, project, dir, line, wanted.items)) && ok;
            commandLine = row[2..];
            wanted = ArrayList<string>.init(run.a);
        } else if (row.len > 0 && !startsWith(row, "#")) {
            try wanted.append(row);
        }
    }
    if (const line = commandLine) ok = (try runCommand(run, project, dir, line, wanted.items)) && ok;
    if (ok) pass(run, project, "");
}

/**
 * Runs one command of an `expect.txt` and checks its output.
 *
 * @param run - The run
 * @param project - The project in the repository, which names a failure
 * @param dir - The copy of the project that the command runs in
 * @param line - The arguments of `helix`, separated by spaces
 * @param wanted - The lines that its stdout must hold
 * @returns `true` when the command exits with 0 and prints every wanted line
 *
 * @remarks
 * The command runs in the copy, so `helix-out` and the caches that it makes stay out of the repository.
 *
 * @since 1.0.0
 */

function runCommand(run: *Run, project: string, dir: string, line: string, wanted: readonly string[]): bool | Error {
    const output = try helix(run, try words(run, line), dir);
    const stdout: string = output.stdout;
    if (output.status != 0) {
        fail(run, project, try text(run, `helix ${line}: exit ${output.status}`), output.stderr);
        return false;
    }
    for (const fragment of wanted) {
        if (!contains(stdout, fragment)) {
            fail(run, project, try text(run, `helix ${line}: missing output: ${fragment}`), stdout);
            return false;
        }
    }
    return true;
}

/**
 * Checks that `helix.jsonc` owns the programs of a project and that the old `-D` flags point at the new ones.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * A build script of the `bins` project that declares a program of `bin` again, or asks for one that is not there,
 * must fail with an error that says so.
 * `-Dtarget` must point at `--target` as well.
 *
 * @since 1.0.0
 */

function checkBuildRules(run: *Run): void | Error {
    if (run.filter.len > 0 && !contains("e2e/projects/bins", run.filter)) return;
    const rules: BuildRule[2] = [
        BuildRule { call: "b.addExecutable({ name: \"greet\", root: \"src/main.hx\" })", error: "is a program in helix.jsonc's \"bin\"" },
        BuildRule { call: "b.bin(\"nope\")", error: "\"nope\", which isn't in helix.jsonc" },
    ];
    const dir = try text(run, `${run.temp}/rules`);
    try copyTree(run, "e2e/projects/bins", dir);
    const script = try text(run, `${dir}/build.hx`);
    for (const rule of rules) {
        const source = try text(run, `import { Build } from "std/build";\n\nexport function build(b: *Build): void | Error {\n    void try ${rule.call};\n}\n`);
        try writeText(script, source);
        const args: string[1] = ["build"];
        const output = try helix(run, &args, dir);
        const stderr: string = output.stderr;
        const name = try text(run, `build.hx: ${rule.call}`);
        if (output.status != 0 && contains(stderr, rule.error)) {
            pass(run, name, "");
        } else {
            fail(run, name, try text(run, `should fail with: ${rule.error}`), stderr);
        }
    }

    try copyFile("e2e/projects/bins/build.hx", script);
    const old: string[2] = ["build", "-Dtarget=x86_64-windows"];
    const output = try helix(run, &old, dir);
    const stderr: string = output.stderr;
    if (output.status != 0 && contains(stderr, "-Dtarget is now --target")) {
        pass(run, "helix build -Dtarget", "");
    } else {
        fail(run, "helix build -Dtarget", "should point at --target", stderr);
    }
}

/**
 * Checks a project that has a build script and no `helix.jsonc`.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Its script asks for the same program twice, once for this machine and once for Linux,
 * and those are separate artifacts, each built once.
 * The `run` step must print what the program prints, and `release` must make an x86-64 Linux executable.
 *
 * @since 1.0.0
 */

function checkBuildOnly(run: *Run): void | Error {
    if (run.filter.len > 0 && !contains("only-build", run.filter)) return;
    const dir = try text(run, `${run.temp}/only-build`);
    try writeText(try text(run, `${dir}/src/main.hx`), "export function main(): void { println(\"only build.hx\"); }\n");
    const script = try text(run, `import { Build, Mode } from "std/build";

export function build(b: *Build): void | Error {
    const app = try b.addExecutable({ name: "app", root: "src/main.hx" });
    try b.install(app);
    try b.addRunStep(app);
    const linux = try b.addExecutable({ name: "app", root: "src/main.hx", target: "x86_64-linux", mode: Mode.ReleaseSafe });
    try (try b.step("release", "app for Linux")).dependOn(try b.addInstall(linux, "release"));
}
`);
    try writeText(try text(run, `${dir}/build.hx`), script);
    const runStep: string[2] = ["build", "run"];
    const ran = try helix(run, &runStep, dir);
    const stdout: string = ran.stdout;
    if (ran.status != 0 || !contains(stdout, "only build.hx")) {
        fail(run, "build.hx without helix.jsonc", "build run", ran.stderr);
        return;
    }
    const release: string[6] = ["build", "release", "--target", "x86_64-linux", "--mode", "release-safe"];
    const built = try helix(run, &release, dir);
    const exe = try text(run, `${dir}/helix-out/release/app`);
    if (built.status != 0 || ((try elfMachine(run, exe, 64)) ?? 0) != ElfX86) {
        fail(run, "build.hx without helix.jsonc", "build release: not an x86-64 Linux executable", built.stderr);
        return;
    }
    pass(run, "build.hx without helix.jsonc", "");
}
