/**
 * Imports
 */

import { ArrayList } from "std/list";
import { Dir, exists } from "std/fs";
import { equal, endsWith } from "std/text";
import { Run } from "../structs/run.struct";
import { pass, fail, text, helix, contains, readText, sortTexts } from "../services/run.service";

/**
 * Checks that `helix translate-c` and `helix translate-svd` turn the samples in `e2e/translate` into what they expect.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Each header `<name>.h` with a `<name>.expected.hx` must translate into exactly that file, which must compile.
 * A header without one, such as `demo-types.h`, is one that another header includes.
 * `svd/demo.svd` must translate into `svd/demo.expected.hx`, and `svd/use.hx`, firmware that uses it,
 * must build for a Cortex-M4.
 * When the translation changes on purpose, write the new output into the expected file.
 *
 * @example
 * ```hx
 * try checkTranslate(&run); // ✗ e2e/translate/demo.h (output differs from e2e/translate/demo.expected.hx)
 * ```
 *
 * @since 1.0.0
 */

export function checkTranslate(run: *Run): void | Error {
    for (const file of try headers(run)) {
        const expectedFile = try text(run, `${file[0..file.len - 2]}.expected.hx`);
        if (!exists(expectedFile)) continue;
        const args: string[2] = ["translate-c", file];
        const output = try helix(run, &args, "");
        const stdout: string = output.stdout;
        if (output.status != 0) {
            fail(run, file, "translate-c failed", output.stderr);
            continue;
        }
        if (!equal(stdout, try readText(run, expectedFile))) {
            fail(run, file, try text(run, `output differs from ${expectedFile}`), stdout);
            continue;
        }
        const check: string[2] = ["check", expectedFile];
        const checked = try helix(run, &check, "");
        if (checked.status != 0) {
            fail(run, expectedFile, "the translation doesn't compile", checked.stderr);
            continue;
        }
        pass(run, file, "");
    }
    try checkSvd(run);
}

/**
 * Lists the C headers in `e2e/translate`.
 *
 * @param run - The run
 * @returns The paths of the `.h` files, sorted
 *
 * @remarks
 * The snippet listing only takes `.hx` files, so the headers have a listing of their own.
 *
 * @since 1.0.0
 */

function headers(run: *Run): string[] | Error {
    let found = ArrayList<string>.init(run.a);
    let folder = try Dir.open("e2e/translate");
    defer folder.close();
    while (const name = try folder.next()) {
        const path = try text(run, `e2e/translate/${name}`);
        if (endsWith(name, ".h") && (run.filter.len == 0 || contains(path, run.filter))) try found.append(path);
    }
    sortTexts(found.items);
    return found.items;
}

/**
 * Checks that the SVD sample translates into what it expects, and that firmware using it builds.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the check
 *
 * @remarks
 * The firmware builds for a Cortex-M4 with 64K of flash and 16K of RAM.
 *
 * @since 1.0.0
 */

function checkSvd(run: *Run): void | Error {
    const svd = "e2e/translate/svd/demo.svd";
    if (run.filter.len > 0 && !contains(svd, run.filter)) return;
    const out = try text(run, `${run.temp}/demo.hx`);
    const args: string[4] = ["translate-svd", svd, "-o", out];
    const output = try helix(run, &args, "");
    if (output.status != 0 || !equal(try readText(run, out), try readText(run, "e2e/translate/svd/demo.expected.hx"))) {
        fail(run, svd, "translate-svd's output differs from demo.expected.hx", output.stderr);
        return;
    }
    const exe = try text(run, `${run.temp}/use`);
    const use: string[12] = [
        "build", "e2e/translate/svd/use.hx", "--target", "thumbv7em-freestanding", "--cpu", "cortex-m4",
        "--flash", "0x08000000:64K", "--ram", "0x20000000:16K", "-o", exe,
    ];
    const built = try helix(run, &use, "");
    if (built.status != 0) {
        fail(run, "e2e/translate/svd/use.hx", "doesn't build", built.stderr);
        return;
    }
    pass(run, svd, "");
}
