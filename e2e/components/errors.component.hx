/**
 * Imports
 */

import { Run } from "../structs/run.struct";
import { lines, startsWith, endsWith } from "std/text";
import { pass, fail, text, helix, contains, readText, snippets, writeText, directives } from "../services/run.service";

/**
 * A wrong `aliases` setting of `helix.jsonc`, and the error that it must give.
 *
 * @remarks
 * {@link checkAliases} writes `settings` into the manifest of a small package and checks a file that imports `@lib/x`.
 *
 * @since 1.0.0
 */

struct AliasCase {
    /**
     * The `aliases` and `dependencies` members of the manifest, as JSON.
     *
     * @since 1.0.0
     */

    settings: string,

    /**
     * A fragment of the error that the compiler must print.
     *
     * @since 1.0.0
     */

    error: string,
}

/**
 * Checks that the compiler rejects every error snippet in `e2e/errors` with exactly the errors that it expects,
 * then that it rejects each wrong `aliases` setting.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * Each `expect-error` fragment must appear on a line of stderr after `error: `,
 * and stderr must hold as many `error: ` lines as the snippet has fragments.
 * A `.spec.hx` snippet is checked with `--test`, so that its tests are checked too.
 *
 * @example
 * ```hx
 * try checkErrors(&run); // ✗ e2e/errors/types.hx (missing error: ...), for each failure
 * ```
 *
 * @since 1.0.0
 */

export function checkErrors(run: *Run): void | Error {
    for (const file of try snippets(run, "e2e/errors", false)) {
        const source = try readText(run, file);
        const wanted = try directives(run, source, "expect-error");
        const withTests: string[3] = ["check", "--test", file];
        const alone: string[2] = ["check", file];
        const output = try helix(run, endsWith(file, ".spec.hx") ? &withTests : &alone, "");
        const stderr: string = output.stderr;
        if (output.status == 0) {
            fail(run, file, "compiled, but errors were expected", stderr);
            continue;
        }
        let missing: ?string = null;
        for (const fragment of wanted) {
            if (!contains(stderr, try text(run, `error: ${fragment}`))) {
                missing = fragment;
                break;
            }
        }
        if (const fragment = missing) {
            fail(run, file, try text(run, `missing error: ${fragment}`), stderr);
            continue;
        }
        let reported: usize = 0;
        let rows = lines(stderr);
        while (const row = rows.next()) {
            if (startsWith(row, "error: ")) reported++;
        }
        if (reported != wanted.len) {
            fail(run, file, try text(run, `${reported} errors, expected ${wanted.len}`), stderr);
            continue;
        }
        pass(run, file, "");
    }
    try checkAliases(run);
}

/**
 * Checks that each wrong `aliases` setting in `helix.jsonc` is an error that says why.
 *
 * @param run - The run
 * @returns Nothing, or the error that stopped the checks
 *
 * @remarks
 * The package lives in the temporary folder of the run, and its `src/main.hx` imports `@lib/x`.
 * The checks run only when the filter of the run is empty or matches `aliases`.
 *
 * @since 1.0.0
 */

function checkAliases(run: *Run): void | Error {
    if (run.filter.len > 0 && !contains("aliases", run.filter)) return;
    const cases: AliasCase[7] = [
        AliasCase { settings: "\"aliases\": { \"lib\": \"src\" }", error: "alias \"lib\" must be @ and a name" },
        AliasCase { settings: "\"aliases\": { \"@lib\": \"../other\" }", error: "must point to a folder inside the package" },
        AliasCase { settings: "\"aliases\": { \"@lib\": \"src/a/../../x\" }", error: "must point to a folder inside the package" },
        AliasCase { settings: "\"aliases\": { \"@lib\": \"/etc\" }", error: "must point to a folder inside the package" },
        AliasCase {
            settings: "\"aliases\": { \"@acme\": \"src\" }, \"dependencies\": { \"@acme/tls\": \"^1\" }",
            error: "is also the scope of the dependency \"@acme/tls\"",
        },
        AliasCase { settings: "\"aliases\": { \"@lib\": \"src/nope\" }", error: "the alias makes it src/nope/x" },
        AliasCase { settings: "\"aliases\": { \"@other\": \"src\" }", error: "\"@lib/x\" is neither an alias nor a package" },
    ];
    const dir = try text(run, `${run.temp}/alias-errors`);
    const main = try text(run, `${dir}/src/main.hx`);
    try writeText(main, "import { x } from \"@lib/x\";\nexport function main(): void {}\n");
    for (const alias of cases) {
        try writeText(try text(run, `${dir}/helix.jsonc`), try text(run, `{ "name": "a", "version": "1.0.0", ${alias.settings} }\n`));
        const args: string[2] = ["check", main];
        const output = try helix(run, &args, "");
        const stderr: string = output.stderr;
        const name = try text(run, `aliases ${alias.settings}`);
        if (output.status == 0) {
            fail(run, name, "compiled, but an error was expected", "");
        } else if (!contains(stderr, alias.error)) {
            fail(run, name, try text(run, `missing: ${alias.error}`), stderr);
        } else {
            pass(run, name, "");
        }
    }
}
