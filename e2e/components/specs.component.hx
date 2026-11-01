/**
 * Imports
 */

import { Run } from "../structs/run.struct";
import { isWindowsExe } from "../services/run.service";
import { pass, fail, text, helix, contains, readText, snippets, directives } from "../services/run.service";

/**
 * Runs every spec snippet in `e2e/specs` with `helix test`, then builds each one for the targets without a runner here.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Each spec runs in debug and release-safe, and stdout must hold `Tests:  <expect-tests>` and every `expect-output`.
 * A spec may fail on purpose, so the exit status does not count.
 * Then each spec must build as a Windows executable for x86_64 and arm64, and a spec built for WASI must be refused,
 * since its runner starts a process for each test.
 *
 * @example
 * ```hx
 * try checkSpecs(&run); // ✗ e2e/specs/basics.spec.hx (debug: expected 'Tests:  ...'), for each failure
 * ```
 *
 * @since 1.0.0
 */

export function checkSpecs(run: *Run): void | Error {
    const files = try snippets(run, "e2e/specs", false);
    const modes: string[2] = ["debug", "release-safe"];
    for (const file of files) {
        const source = try readText(run, file);
        const totals = try directives(run, source, "expect-tests");
        const fragments = try directives(run, source, "expect-output");
        const summary = try text(run, `Tests:  ${totals.len > 0 ? totals[0] : ""}`);
        for (const mode of modes) {
            const args: string[4] = ["test", file, "--mode", mode];
            const output = try helix(run, &args, "");
            const stdout: string = output.stdout;
            if (!contains(stdout, summary)) {
                fail(run, file, try text(run, `${mode}: expected '${summary}'`), stdout);
                continue;
            }
            let missing: ?string = null;
            for (const fragment of fragments) {
                if (!contains(stdout, fragment)) {
                    missing = fragment;
                    break;
                }
            }
            if (const fragment = missing) {
                fail(run, file, try text(run, `${mode}: missing output: ${fragment}`), stdout);
                continue;
            }
            pass(run, file, mode);
        }
    }

    const targets: string[2] = ["x86_64-windows", "aarch64-windows"];
    for (const target of targets) {
        for (const file of files) {
            const exe = try text(run, `${run.temp}/spec.exe`);
            const args: string[7] = ["build", file, "--test", "--target", target, "-o", exe];
            const output = try helix(run, &args, "");
            if (output.status == 0 && (try isWindowsExe(run, exe))) {
                pass(run, file, try text(run, `--test --target ${target}`));
            } else {
                fail(run, file, try text(run, `--test --target ${target}: not a Windows executable`), output.stderr);
            }
        }
    }

    if (run.filter.len > 0 && !contains("wasm32-wasi", run.filter)) return;
    const wasm = try text(run, `${run.temp}/spec-wasi`);
    const wasi: string[7] = ["build", "e2e/projects/bins/src/main.spec.hx", "--test", "--target", "wasm32-wasi", "-o", wasm];
    const output = try helix(run, &wasi, "");
    const stderr: string = output.stderr;
    if (output.status != 0 && contains(stderr, "can't build for WASI")) {
        pass(run, "helix build --test --target wasm32-wasi", "");
    } else {
        fail(run, "helix build --test --target wasm32-wasi", "should say that there is no test runner for WASI", stderr);
    }
}
