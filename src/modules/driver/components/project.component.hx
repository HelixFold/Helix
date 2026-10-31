/**
 * Imports
 */

import * as fmt from "std/fmt";
import { equal } from "std/text";
import { cAllocator } from "std/heap";
import * as os from "@modules/driver/components/os.component";
import { hxFatalMessage } from "@components/memory.component";
import { Moved } from "@modules/driver/constants/project.constant";
import { loadManifest } from "@modules/driver/components/manifest.component";
import { clearPackageArgs } from "@modules/driver/components/compile.component";
import { allocCString, add, strings } from "@modules/driver/components/os.component";
import { addPackageArg, defaultOptions, buildExecutable } from "@modules/driver/components/compile.component";

/**
 * Ends the process with a fatal out-of-memory message.
 *
 * @remarks
 * A failed append to the text of `.helix-cache/packages.txt` ends here, since the build cannot go on without memory.
 *
 * @since 1.0.0
 */

function outOfMemory(): noreturn {
    hxFatalMessage("out of memory");
}

/**
 * Tells the user where a package command that hpm took over went.
 *
 * @param command - The command that `helix` was given, such as `add`
 * @param args - The arguments after the command
 * @returns 1 after reporting a moved command, or `null` when the command is not one of them
 *
 * @remarks
 * The report goes to the standard error, with a hint that shows the same arguments for the hpm command.
 *
 * @example
 * ```hx
 * movedToHpm("add", [ "tls" ]);
 * // error: `helix add` moved to hpm, the package manager
 * //   = hint: hpm add tls
 * movedToHpm("build", []); // null
 * ```
 *
 * @see Moved
 * @since 1.0.0
 */

export function movedToHpm(command: string, args: readonly string[]): ?u8 {
    let i: usize = 0;
    while (i < Moved.len) {
        if (equal(Moved[i], command)) {
            let line = allocCString(`hpm ${Moved[i + 1]}`);
            for (const arg of args) line = allocCString(`${line} ${arg}`);
            eprintln(`error: \`helix ${command}\` moved to hpm, the package manager`);
            eprintln(`  = hint: ${line}`);
            return 1;
        }
        i += 2;
    }
    return null;
}

/**
 * Runs `helix build` for a project.
 *
 * @param args - The arguments after `build`, which go to the build runner unchanged
 * @returns The exit code of the build runner, or 1 when the build cannot start
 *
 * @remarks
 * It finds the nearest folder at or above the current one with a build.hx or a helix.jsonc and changes to it.
 * The programs in helix.jsonc's `bin` go to .helix-cache/packages.txt as `bin<tab>-<tab>name<tab>root` lines,
 * which the runner always builds.
 * It then compiles std's build runner (lib/std/build-runner.hx, next to the compiler) to .helix-cache/build
 * with the project's build.hx as the `@build` package, or lib/std/default-build.hx when there is none,
 * and runs it with the compiler's path, the packages file, and `args`.
 * The runner builds the `bin` programs, then what build.hx adds.
 * Dependencies come from helix-modules, which hpm lays out (docs/design/hpm.md).
 *
 * @example
 * ```hx
 * cmdProjectBuild([ "--mode", "release-fast" ]); // 0 once every step has built
 * ```
 *
 * @since 1.0.0
 */

export function cmdProjectBuild(args: readonly string[]): u8 {
    const here = os.cwd();
    if (here == null) return 1;
    let root: string = here;
    let hasBuild = false;
    while (true) {   // the nearest folder up from here with a build.hx or a helix.jsonc
        hasBuild = os.readable(allocCString(`${root}/build.hx`));
        if (hasBuild || os.readable(allocCString(`${root}/helix.jsonc`))) break;
        const slash = os.lastIndex(root, '/') ?? 0;
        if (slash == 0) {
            eprintln("error: no build.hx or helix.jsonc here or in any folder above");
            eprintln("  = hint: `hpm init` creates a project; `helix build file.hx` compiles a single file");
            return 1;
        }
        root = root[0..slash];
    }
    root = allocCString(`${root}`);
    if (!os.chdir(root)) return 1;

    let f = fmt.Builder.init(cAllocator());
    if (os.readable("helix.jsonc")) {
        const m = loadManifest(root, true);
        if (m == null) return 1;
        // `bin <tab> - <tab> name <tab> root`: the project's programs, which the runner always builds
        for (const name, i of m.binNames.items) f.append(`bin\t-\t${name}\t${m.binRoots.items[i]}\n`) catch outOfMemory();
    }
    if (!os.makeDirs(".helix-cache")) return 1;
    if (!os.writeText(".helix-cache/packages.txt", f.text())) {
        eprintln(`error: cannot write .helix-cache/packages.txt: ${os.strerror(os.errno())}`);
        return 1;
    }

    const runnerSource = os.besideCompiler("lib/std/build-runner.hx");
    const helix = os.compilerPath();
    if (runnerSource == null || helix == null) {
        eprintln("error: the build runner (lib/std/build-runner.hx) is missing next to the compiler");
        return 1;
    }
    let buildFile = allocCString(`${root}/build.hx`);
    if (!hasBuild) {
        const fallback = os.besideCompiler("lib/std/default-build.hx");
        if (fallback == null) {
            eprintln("error: the default build (lib/std/default-build.hx) is missing next to the compiler");
            return 1;
        }
        buildFile = fallback;
    }
    clearPackageArgs();
    void addPackageArg(null, allocCString(`@build=${buildFile}`));
    let options = defaultOptions();
    options.file = runnerSource;
    if (!buildExecutable(&options, ".helix-cache/build")) {
        eprintln("error: build.hx doesn't compile");
        return 1;
    }

    let runner = strings();
    add(&runner, ".helix-cache/build");
    add(&runner, helix);
    add(&runner, ".helix-cache/packages.txt");
    for (const arg of args) add(&runner, arg);
    const status = os.run(runner.items);
    return status < 0 ? 1 : status as u8;
}
