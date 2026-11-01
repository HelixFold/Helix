/**
 * Imports
 */

import { Init } from "std/process";
import { ArrayList } from "std/list";
import { Run } from "./structs/run.struct";
import { ArenaAllocator, cAllocator } from "std/heap";
import { checkSpecs } from "./components/specs.component";
import { checkErrors } from "./components/errors.component";
import { checkPrograms } from "./components/programs.component";
import { checkProjects } from "./components/projects.component";
import { checkTranslate } from "./components/translate.component";
import { checkFreestanding } from "./components/freestanding.component";
import { absolute, makeTemp, deleteFolder } from "./services/run.service";

/**
 * Checks that the compiler builds, runs, rejects, tests, and translates the snippets in `e2e` as each snippet says.
 *
 * @param init - The command line, with the compiler and an optional path filter as its arguments
 * @returns 0 when every check passes, 1 otherwise, or the error that stopped the run
 *
 * @remarks
 * It runs from the root of the repository, and each folder of `e2e` has a component that checks it:
 *
 * - **programs** - `helix run` in each mode must print the `expect-stdout` lines and exit or panic as expected,
 *   also as arm64e on a Mac, as WASI under Node, and as an executable for each Linux machine
 * - **errors** - `helix check` must fail with exactly the `expect-error` errors, and wrong aliases must be errors
 * - **specs** - `helix test` must print the `expect-tests` totals and each `expect-output` fragment,
 *   and each spec must build for Windows
 * - **projects** - the commands of each `expect.txt` must print what it lists, in a copy of the project
 * - **freestanding** - programs without an OS must print their `expect-qemu` lines in QEMU, and chips must build
 * - **translate** - `translate-c` and `translate-svd` must give the expected files
 *
 * A group that needs a tool this machine lacks, such as QEMU or Node, is skipped, and the end of the report says which.
 * The compiler defaults to `helix-out/bin/helix`, which `helix build` installs.
 *
 * @example
 * ```bash
 * helix run e2e/main.hx -- helix-out/bin/helix          # E2E:  512 passed, 512 total
 * helix run e2e/main.hx -- helix-out/bin/helix panic-   # only the snippets whose path holds panic-
 * ```
 *
 * @since 1.0.0
 */

export function main(init: Init): u8 | Error {
    let arena = ArenaAllocator.init(cAllocator());
    defer arena.deinit();
    let run = Run {
        a: arena.allocator(),
        compiler: "",
        filter: init.args.len > 1 ? init.args[1] : "",
        temp: "",
        passed: 0,
        failed: 0,
        skipped: ArrayList<string>.init(arena.allocator()),
    };
    run.compiler = try absolute(&run, init.args.len > 0 ? init.args[0] : "helix-out/bin/helix");
    run.temp = try makeTemp(&run);
    defer deleteFolder(run.temp) catch {};

    try checkPrograms(&run);
    try checkErrors(&run);
    try checkSpecs(&run);
    try checkProjects(&run);
    try checkFreestanding(&run);
    try checkTranslate(&run);

    for (const note of run.skipped.items) println(`  - skipped ${note}`);
    const total = run.passed + run.failed;
    if (run.failed > 0) {
        println(`E2E:  ${run.failed} failed, ${run.passed} passed, ${total} total`);
        return 1;
    }
    println(`E2E:  ${run.passed} passed, ${total} total`);
    return 0;
}
