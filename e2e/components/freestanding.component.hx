/**
 * Imports
 */

import { copyFile } from "std/fs";
import { ArrayList } from "std/list";
import { equal, trim } from "std/text";
import { Run } from "../structs/run.struct";
import { snippets, ElfArm, writeText, elfMachine, directives } from "../services/run.service";
import { pass, fail, skip, text, helix, words, command, contains, findTool, readText } from "../services/run.service";

/**
 * The milliseconds that a program in QEMU may run before the check stops it.
 *
 * @remarks
 * A program that ends powers the board off, and one that halts after a panic or a fault keeps QEMU running.
 *
 * @example
 * ```hx
 * CaptureOptions { timeout: QemuMilliseconds };
 * ```
 *
 * @since 1.0.0
 */

export const QemuMilliseconds: u32 = 3000;

/**
 * Builds the programs without an OS in `e2e/freestanding`, boots them in QEMU, and checks the chip settings.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * A snippet with `expect-qemu` lines builds with its `// target:` or `// build:` options,
 * or for `riscv64-freestanding` without them, and boots with its `// qemu:` command,
 * or with the riscv64 `virt` board without one.
 * Every `expect-qemu` line must appear in what QEMU prints, and the boot skips itself without that QEMU.
 * The chip checks build without QEMU, so they run on every machine.
 *
 * @example
 * ```hx
 * try checkFreestanding(&run); // ✗ e2e/freestanding/panic.hx (QEMU didn't print: ...), for each failure
 * ```
 *
 * @since 1.0.0
 */

export function checkFreestanding(run: *Run): void | Error {
    for (const file of try snippets(run, "e2e/freestanding", false)) {
        const source = try readText(run, file);
        const wanted = try directives(run, source, "expect-qemu");
        if (wanted.len == 0) continue;   // board.hx, which the others import
        try bootInQemu(run, file, source, wanted);
    }
    if (run.filter.len > 0 && !contains("e2e/freestanding/cortex-m3.hx", run.filter)) return;
    try checkDescribedChip(run);
    try checkUnknownChip(run);
    try checkCortexCores(run);
}

/**
 * Builds one snippet for its board and checks what it prints in QEMU.
 *
 * @param run - The run
 * @param file - The path of the snippet
 * @param source - The text of the snippet
 * @param wanted - The lines that QEMU must print
 * @returns Nothing, or the error that stopped the check
 *
 * @remarks
 * QEMU runs for at most {@link QemuMilliseconds}, and its stdout and stderr together must hold every wanted line.
 *
 * @since 1.0.0
 */

function bootInQemu(run: *Run, file: string, source: string, wanted: readonly string[]): void | Error {
    const targets = try directives(run, source, "target");
    const builds = try directives(run, source, "build");
    const qemus = try directives(run, source, "qemu");
    const options = targets.len > 0 ? try text(run, `--target ${targets[0]}`)
                  : builds.len > 0 ? builds[0] : "--target riscv64-freestanding";
    const qemu = try words(run, qemus.len > 0 ? qemus[0] : "qemu-system-riscv64 -machine virt -bios none");
    const tool = try findTool(run, qemu[0]);
    if (tool == null) {
        try skip(run, try text(run, `${file} in QEMU: no ${qemu[0]}`));
        return;
    }

    const exe = try text(run, `${run.temp}/qemu-test`);
    let build = ArrayList<string>.init(run.a);
    try build.append("build");
    try build.append(file);
    for (const option of try words(run, options)) try build.append(option);
    try build.append("-o");
    try build.append(exe);
    const built = try helix(run, build.items, "");
    if (built.status != 0) {
        fail(run, file, "doesn't build", built.stderr);
        return;
    }

    let argv = ArrayList<string>.init(run.a);
    for (const word of qemu) try argv.append(word);
    try argv.append("-nographic");
    try argv.append("-kernel");
    try argv.append(exe);
    const output = try command(run, argv.items, "", QemuMilliseconds);
    const printed = try text(run, `${output.stdout}${output.stderr}`);
    for (const line of wanted) {
        if (!contains(printed, line)) {
            fail(run, file, try text(run, `QEMU didn't print: ${line}`), printed);
            return;
        }
    }
    pass(run, file, "QEMU");
}

/**
 * Checks that a chip described in `helix.jsonc` builds as a named one does, also next to a build script.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * The package gives the CPU and the memory of a Cortex-M3, and a file of it must build into a 32-bit ARM executable.
 * The chip is the default of the package, not a rule: a program that the build script asks for on `native`
 * runs on this machine, and the specs run here too.
 *
 * @since 1.0.0
 */

function checkDescribedChip(run: *Run): void | Error {
    const dir = try text(run, `${run.temp}/described`);
    try writeText(try text(run, `${dir}/helix.jsonc`), try text(run, `{ "name": "d", "version": "0.1.0", "chip": { "cpu": "cortex-m3", "flash": { "origin": "0x08000000", "size": "128K" }, "ram": { "origin": "0x20000000", "size": "8K" } } }\n`));
    const main = try text(run, `${dir}/src/main.hx`);
    try writeText(main, "");
    try copyFile("e2e/freestanding/cortex-m3.hx", main);
    const firmware = try text(run, `${dir}/fw`);
    const args: string[4] = ["build", main, "-o", firmware];
    const built = try helix(run, &args, "");
    if (built.status != 0 || ((try elfMachine(run, firmware, 32)) ?? 0) != ElfArm) {
        fail(run, "chip (described)", "doesn't build a 32-bit ARM executable", built.stderr);
    } else {
        pass(run, "chip (described)", "");
    }

    try writeText(try text(run, `${dir}/src/tool.hx`), "export function main(): void { println(\"from the host\"); }\n");
    try writeText(try text(run, `${dir}/src/host.spec.hx`), "test(\"runs here\") {\n    expect(1 + 1).toBe(2);\n}\n");
    const script = try text(run, `import { Build } from "std/build";

export function build(b: *Build): void | Error {
    try b.install(try b.addExecutable({ name: "tool", root: "src/tool.hx", target: "native" }));
    try b.install(try b.addExecutable({ name: "firmware", root: "src/main.hx" }));
}
`);
    try writeText(try text(run, `${dir}/build.hx`), script);
    const build: string[1] = ["build"];
    const project = try helix(run, &build, dir);
    if (project.status != 0) {
        fail(run, "chip (with build.hx)", "helix build failed", project.stderr);
        return;
    }
    const tool: string[1] = [try text(run, `${dir}/.helix-out/bin/tool`)];
    const ran = try command(run, &tool, "", 0);
    if (!equal(trim(ran.stdout), "from the host")) {
        fail(run, "chip (with build.hx)", "the native tool got the chip", ran.stderr);
        return;
    }
    if (((try elfMachine(run, try text(run, `${dir}/.helix-out/bin/firmware`), 32)) ?? 0) != ElfArm) {
        fail(run, "chip (with build.hx)", "the firmware isn't a 32-bit ARM executable", "");
        return;
    }
    const test: string[2] = ["test", "src"];
    const tested = try helix(run, &test, dir);
    if (tested.status != 0) {
        fail(run, "chip (with build.hx)", "the specs got the chip", tested.stdout);
        return;
    }
    pass(run, "chip (with build.hx)", "");
}

/**
 * Checks that an unknown chip name is an error that offers the names near it.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the check
 *
 * @remarks
 * `STM32F41RE` is not a chip, and `STM32F410` is the nearest one.
 *
 * @since 1.0.0
 */

function checkUnknownChip(run: *Run): void | Error {
    const exe = try text(run, `${run.temp}/nochip`);
    const args: string[6] = ["build", "e2e/freestanding/cortex-m3.hx", "--chip", "STM32F41RE", "-o", exe];
    const output = try helix(run, &args, "");
    const stderr: string = output.stderr;
    if (output.status != 0 && contains(stderr, "no chip named 'STM32F41RE'") && contains(stderr, "maybe: STM32F410")) {
        pass(run, "--chip", "an unknown chip");
    } else {
        fail(run, "--chip", "an unknown chip should be an error with nearby names", stderr);
    }
}

/**
 * Checks that the other Cortex-M cores link: the M33 with its FPU and the M4 without one.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Both build `cortex-m3.hx` with the flash and the RAM given on the command line.
 *
 * @since 1.0.0
 */

function checkCortexCores(run: *Run): void | Error {
    const cores: string[2] = ["thumbv8m.main-freestanding-eabihf --cpu cortex-m33", "thumbv7em-freestanding --cpu cortex-m4"];
    const exe = try text(run, `${run.temp}/cortex`);
    for (const core of cores) {
        let args = ArrayList<string>.init(run.a);
        try args.append("build");
        try args.append("e2e/freestanding/cortex-m3.hx");
        try args.append("--target");
        for (const word of try words(run, core)) try args.append(word);
        const rest: string[6] = ["--flash", "0x10000000:512K", "--ram", "0x38000000:256K", "-o", exe];
        for (const word of rest) try args.append(word);
        const output = try helix(run, args.items, "");
        if (output.status == 0 && ((try elfMachine(run, exe, 32)) ?? 0) == ElfArm) {
            pass(run, "e2e/freestanding/cortex-m3.hx", core);
        } else {
            fail(run, "e2e/freestanding/cortex-m3.hx", try text(run, `${core}: doesn't build`), output.stderr);
        }
    }
}
