/**
 * Imports
 */

import * as fmt from "std/fmt";
import { exists } from "std/fs";
import { Output } from "std/process";
import { equal, trim } from "std/text";
import { Run } from "../structs/run.struct";
import { snippets, ElfX86, ElfRiscv, ElfAarch64, elfMachine, directives } from "../services/run.service";
import { pass, fail, skip, text, helix, onMac, command, contains, findTool, readText } from "../services/run.service";

/**
 * What a program snippet must do when it runs.
 *
 * @remarks
 * It comes from the `expect-stdout`, `expect-exit`, and `expect-panic` lines of the snippet.
 *
 * @since 1.0.0
 */

struct Expected {
    /**
     * Every `expect-stdout` line followed by a newline, which the output must match exactly.
     *
     * @since 1.0.0
     */

    stdout: string,

    /**
     * The exit status, `0` when the snippet does not say.
     *
     * @since 1.0.0
     */

    exit: string,

    /**
     * The message of the panic that ends the program, or an empty text when it must not panic.
     *
     * @since 1.0.0
     */

    panic: string,

    /**
     * Whether the snippet has a `skip-wasi` line, because it needs something that WASI lacks.
     *
     * @since 1.0.0
     */

    skipWasi: bool,
}

/**
 * Builds and runs every program snippet in `e2e/programs`, then the ones that run on other targets.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Each snippet runs with `helix run` in debug, release-safe, and release-fast,
 * or in debug and release-safe when it expects a panic, since release-fast leaves out the checks that panic.
 * Then the same snippets run as arm64e on a Mac, as WASI under Node, and three of them link for each Linux machine.
 *
 * @example
 * ```hx
 * try checkPrograms(&run); // ✗ e2e/programs/hello.hx (debug: stdout differs), for each failure
 * ```
 *
 * @since 1.0.0
 */

export function checkPrograms(run: *Run): void | Error {
    const files = try snippets(run, "e2e/programs", false);
    const modes: string[3] = ["debug", "release-safe", "release-fast"];
    for (const file of files) {
        const expected = try expectationsOf(run, file);
        const count: usize = expected.panic.len > 0 ? 2 : 3;
        for (const mode of modes[0..count]) {
            const args: string[4] = ["run", file, "--mode", mode];
            const output = try helix(run, &args, "");
            if (try matches(run, file, mode, output, expected, 134)) pass(run, file, mode);
        }
    }
    try checkArm64e(run, files);
    try checkWasi(run, files);
    try checkLinux(run);
}

/**
 * Reads what a program snippet expects.
 *
 * @param run - The run
 * @param file - The path of the snippet
 * @returns The output, the exit status, and the panic that the snippet expects
 *
 * @remarks
 * A snippet without an `expect-exit` line must exit with 0.
 *
 * @since 1.0.0
 */

function expectationsOf(run: *Run, file: string): Expected | Error {
    const source = try readText(run, file);
    let stdout = fmt.Builder.init(run.a);
    for (const row of try directives(run, source, "expect-stdout")) try stdout.append(`${row}\n`);
    const exits = try directives(run, source, "expect-exit");
    const panics = try directives(run, source, "expect-panic");
    return Expected {
        stdout: stdout.text(),
        exit: exits.len > 0 ? exits[0] : "0",
        panic: panics.len > 0 ? panics[0] : "",
        skipWasi: (try directives(run, source, "skip-wasi")).len > 0,
    };
}

/**
 * Compares what a program did with what its snippet expects, and reports a difference.
 *
 * @param run - The run
 * @param file - The path of the snippet
 * @param label - The mode or the target, which starts the reason of a failure
 * @param output - What the program did
 * @param expected - What the snippet expects
 * @param panicStatus - The exit status of a panic, or 0 when any status other than 0 counts
 * @returns `true` when the program did what the snippet expects
 *
 * @remarks
 * A panic must end the program with `panicStatus` and print `panic: <message>` on stderr.
 * WebAssembly traps, so its status differs by host and only has to be other than 0.
 *
 * @since 1.0.0
 */

function matches(run: *Run, file: string, label: string, output: Output, expected: Expected, panicStatus: u8): bool | Error {
    const stdout: string = output.stdout;
    const stderr: string = output.stderr;
    if (expected.panic.len > 0) {
        const message = try text(run, `panic: ${expected.panic}`);
        const statusOk = panicStatus == 0 ? output.status != 0 : output.status == panicStatus;
        if (!statusOk || !contains(stderr, message)) {
            fail(run, file, try text(run, `${label}: expected ${message}, exit ${output.status}`), stderr);
            return false;
        }
    } else {
        const status = try text(run, `${output.status}`);
        if (!equal(status, expected.exit)) {
            fail(run, file, try text(run, `${label}: exit ${status}, expected ${expected.exit}`), stderr);
            return false;
        }
    }
    if (!equal(stdout, expected.stdout)) {
        fail(run, file, try text(run, `${label}: stdout differs`), stdout);
        return false;
    }
    return true;
}

/**
 * Runs every program snippet as arm64e, with pointer authentication, on a Mac.
 *
 * @param run - The run
 * @param files - The program snippets
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Signed function pointers reach C, such as the comparator of `qsort`, and come back.
 * It needs the linker of Apple from the command-line tools, so it skips itself on another machine.
 *
 * @since 1.0.0
 */

function checkArm64e(run: *Run, files: readonly string[]): void | Error {
    if (!onMac() || !exists("/Library/Developer/CommandLineTools/usr/bin/ld")) {
        try skip(run, "arm64e programs: they need a Mac with the command-line tools");
        return;
    }
    for (const file of files) {
        const expected = try expectationsOf(run, file);
        const args: string[4] = ["run", file, "--target", "arm64e-macos"];
        const output = try helix(run, &args, "");
        if (try matches(run, file, "arm64e", output, expected, 134)) pass(run, file, "arm64e");
    }
}

/**
 * Builds every program snippet for WASI and runs it with the WASI of Node, through `e2e/wasi-run.mjs`.
 *
 * @param run - The run
 * @param files - The program snippets
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * A snippet with a `skip-wasi` line is left out.
 * It skips itself without Node, or when the compiler cannot download the WASI C library.
 *
 * @since 1.0.0
 */

function checkWasi(run: *Run, files: readonly string[]): void | Error {
    const node = try findTool(run, "node");
    if (node == null) {
        try skip(run, "WASI programs: they need node");
        return;
    }
    for (const file of files) {
        const expected = try expectationsOf(run, file);
        if (expected.skipWasi) continue;
        const wasm = try text(run, `${run.temp}/program.wasm`);
        const build: string[6] = ["build", file, "-o", wasm, "--target", "wasm32-wasi"];
        const built = try helix(run, &build, "");
        const errors: string = built.stderr;
        if (contains(errors, "couldn't download")) {
            try skip(run, "WASI programs: the WASI C library couldn't be downloaded");
            return;
        }
        if (built.status != 0) {
            fail(run, file, "wasm32-wasi: doesn't build", errors);
            continue;
        }
        const argv: string[4] = [node, "--no-warnings", "e2e/wasi-run.mjs", wasm];
        const output = try command(run, &argv, "", 0);
        if (try matches(run, file, "wasm32-wasi", output, expected, 0)) pass(run, file, "wasm32-wasi");
    }
}

/**
 * Links three program snippets for each Linux machine and checks the executables.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Each one must be an ELF executable for its machine, static against the musl that Helix builds.
 * On a Linux machine of the same kind, it also runs and must print what its snippet expects.
 * It skips itself when the compiler cannot download musl.
 *
 * @since 1.0.0
 */

function checkLinux(run: *Run): void | Error {
    const targets: string[3] = ["x86_64-linux", "aarch64-linux", "riscv64-linux"];
    const machines: u16[3] = [ElfX86, ElfAarch64, ElfRiscv];
    const names: string[3] = ["c-interop", "structs", "iterators"];
    const host = try hostMachine(run);
    for (const target, i of targets) {
        for (const name of names) {
            const file = try text(run, `e2e/programs/${name}.hx`);
            if (run.filter.len > 0 && !contains(file, run.filter)) continue;
            const exe = try text(run, `${run.temp}/${name}-${target}`);
            const build: string[6] = ["build", file, "-o", exe, "--target", target];
            const built = try helix(run, &build, "");
            const errors: string = built.stderr;
            if (contains(errors, "couldn't download")) {
                try skip(run, "Linux programs: musl couldn't be downloaded");
                return;
            }
            const label = try text(run, `${target}`);
            if (built.status != 0) {
                fail(run, file, try text(run, `${label}: doesn't build`), errors);
                continue;
            }
            if (((try elfMachine(run, exe, 64)) ?? 0) != machines[i]) {
                fail(run, file, try text(run, `${label}: not a 64-bit ELF executable for its machine`), "");
                continue;
            }
            if (equal(host, target)) {
                const argv: string[1] = [exe];
                const output = try command(run, &argv, "", 0);
                if (!(try matches(run, file, label, output, try expectationsOf(run, file), 134))) continue;
            }
            pass(run, file, label);
        }
    }
}

/**
 * Names this machine the way a Linux target names it.
 *
 * @param run - The run
 * @returns `x86_64-linux` or `aarch64-linux` on such a Linux machine, or an empty text on any other
 *
 * @remarks
 * It asks `uname`, and {@link checkLinux} runs the executables only for the target that it gives.
 *
 * @since 1.0.0
 */

function hostMachine(run: *Run): string | Error {
    if (onMac()) return "";
    const argv: string[2] = ["uname", "-m"];
    const output = try command(run, &argv, "", 0);
    const machine = trim(output.stdout);
    if (equal(machine, "x86_64")) return "x86_64-linux";
    if (equal(machine, "aarch64")) return "aarch64-linux";
    return "";
}
