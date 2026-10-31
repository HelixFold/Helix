/**
 * Imports
 */

import { HxJson } from "@components/structs/json-component.struct";
import { Strings } from "@modules/driver/components/structs/os-component.struct";

/**
 * The result of parsing a JSON text with {@link parse}.
 *
 * @remarks
 * A failure leaves `ok` false and sets `at` and `error`, which {@link manifestError} turns into a message.
 *
 * @example
 * ```hx
 * const p = parse("{ \"a\": 1 }");
 * p.ok; // true
 * ```
 *
 * @see parse
 * @since 1.0.0
 */

export struct Parsed {
    /**
     * The parsed tree, which the caller frees with `hxJsonFree` after a successful parse.
     *
     * @example
     * ```hx
     * p.json.kind; // JsonObject for "{}"
     * ```
     *
     * @since 1.0.0
     */

    json: HxJson,

    /**
     * Whether the whole text is one valid value.
     *
     * @example
     * ```hx
     * parse("{").ok; // false
     * ```
     *
     * @since 1.0.0
     */

    ok: bool,

    /**
     * The message of a failure, or an empty string on success.
     *
     * @example
     * ```hx
     * p.error; // "expected a value"
     * ```
     *
     * @since 1.0.0
     */

    error: string,

    /**
     * The byte offset in the text that a failure points at.
     *
     * @example
     * ```hx
     * manifestError(path, source, p.at, p.error); // helix.jsonc:3:5: error: ...
     * ```
     *
     * @since 1.0.0
     */

    at: u32,
}

/**
 * The state of one read of a JSON file, which the `json` readers share.
 *
 * @remarks
 * A reader reports a member of the wrong kind and goes on, so that one read shows every mistake in the file.
 *
 * @example
 * ```hx
 * let r = ManifestReader { path, source, ok: true };
 * jsonString(&r, json, "name"); // reports a `name` that is not a string
 * r.ok;                         // false after any report
 * ```
 *
 * @since 1.0.0
 */

export struct ManifestReader {
    /**
     * The path of the file, for the messages.
     *
     * @example
     * ```hx
     * r.path; // "/work/app/helix.jsonc"
     * ```
     *
     * @since 1.0.0
     */

    path: string,

    /**
     * The text of the file, for turning offsets into lines and columns.
     *
     * @example
     * ```hx
     * r.source; // "{ \"name\": \"app\" }"
     * ```
     *
     * @since 1.0.0
     */

    source: string,

    /**
     * Whether the read has reported nothing so far.
     *
     * @example
     * ```hx
     * r.ok; // true until the first error
     * ```
     *
     * @since 1.0.0
     */

    ok: bool,
}

/**
 * The contents of a package's helix.jsonc as the compiler needs them, with paths made absolute.
 *
 * @remarks
 * It holds the name of the package, what it exports, the C it brings, its programs, and the names of its dependencies.
 * Versions, sources, and the lockfile belong to hpm (docs/design/hpm.md),
 * since the compiler only needs to know which names a package may import.
 *
 * @example
 * ```hx
 * const m = loadManifest("/work/app", true)!;
 * m.name;             // "app"
 * m.exportFiles.items; // [ "/work/app/src/index.hx" ]
 * ```
 *
 * @see loadManifest
 * @see emptyManifest
 *
 * @since 1.0.0
 */

export struct Manifest {
    /**
     * The folder that holds helix.jsonc, which the relative paths in it start from.
     *
     * @example
     * ```hx
     * m.dir; // "/work/app"
     * ```
     *
     * @since 1.0.0
     */

    dir: string,

    /**
     * The `name` of the package, or `null` when helix.jsonc has none.
     *
     * @example
     * ```hx
     * m.name; // "app"
     * ```
     *
     * @since 1.0.0
     */

    name: ?string,

    /**
     * The `version` of the package, or `null` when helix.jsonc has none.
     *
     * @example
     * ```hx
     * m.version; // "1.0.0"
     * ```
     *
     * @since 1.0.0
     */

    version: ?string,

    /**
     * The paths that other packages import, such as `.` and `./x509`.
     *
     * @example
     * ```hx
     * m.exportPaths.items; // [ ".", "./x509" ]
     * ```
     *
     * @see Manifest.exportFiles
     * @since 1.0.0
     */

    exportPaths: Strings,

    /**
     * The absolute file that each export path means, at the same index.
     *
     * @example
     * ```hx
     * m.exportFiles.items; // [ "/work/app/src/index.hx", "/work/app/src/x509.hx" ]
     * ```
     *
     * @since 1.0.0
     */

    exportFiles: Strings,

    /**
     * The absolute paths of the C files that the package brings, with patterns in their names expanded.
     *
     * @example
     * ```hx
     * m.cSources.items; // [ "/work/app/c/host.c" ]
     * ```
     *
     * @since 1.0.0
     */

    cSources: Strings,

    /**
     * The flags for compiling the C files of the package.
     *
     * @example
     * ```hx
     * m.cFlags.items; // [ "-DNDEBUG" ]
     * ```
     *
     * @since 1.0.0
     */

    cFlags: Strings,

    /**
     * The absolute folders that the C files of the package include headers from.
     *
     * @example
     * ```hx
     * m.includeDirs.items; // [ "/work/app/c/include" ]
     * ```
     *
     * @since 1.0.0
     */

    includeDirs: Strings,

    /**
     * The system libraries that a program using the package links against.
     *
     * @example
     * ```hx
     * m.systemLibraries.items; // [ "z" ]
     * ```
     *
     * @since 1.0.0
     */

    systemLibraries: Strings,

    /**
     * The names of the programs in `bin`.
     *
     * @example
     * ```hx
     * m.binNames.items; // [ "app" ]
     * ```
     *
     * @see Manifest.binRoots
     * @since 1.0.0
     */

    binNames: Strings,

    /**
     * The root file of each program, at the same index as its name, as helix.jsonc writes it.
     *
     * @example
     * ```hx
     * m.binRoots.items; // [ "src/main.hx" ]
     * ```
     *
     * @since 1.0.0
     */

    binRoots: Strings,

    /**
     * The names of the commands in `scripts`.
     *
     * @example
     * ```hx
     * m.scriptNames.items; // [ "lint" ]
     * ```
     *
     * @see Manifest.scriptCommands
     * @since 1.0.0
     */

    scriptNames: Strings,

    /**
     * The command line of each script, at the same index as its name.
     *
     * @example
     * ```hx
     * m.scriptCommands.items; // [ "helix check src/main.hx" ]
     * ```
     *
     * @since 1.0.0
     */

    scriptCommands: Strings,

    /**
     * The names in `dependencies`.
     *
     * @example
     * ```hx
     * m.deps.items; // [ "@acme/tls" ]
     * ```
     *
     * @since 1.0.0
     */

    deps: Strings,

    /**
     * The names in `devDependencies`.
     *
     * @example
     * ```hx
     * m.devDeps.items; // [ "bench" ]
     * ```
     *
     * @since 1.0.0
     */

    devDeps: Strings,

    /**
     * The names in `peerDependencies`.
     *
     * @example
     * ```hx
     * m.peerDeps.items; // [ "std" ]
     * ```
     *
     * @since 1.0.0
     */

    peerDeps: Strings,

    /**
     * The names in `aliases`, such as `@diag`.
     *
     * @remarks
     * An import in the package's own files that starts with one of these names means the folder at the same index
     * in the alias paths instead.
     *
     * @example
     * ```hx
     * m.aliasNames.items; // [ "@diag" ]
     * ```
     *
     * @since 1.0.0
     */

    aliasNames: Strings,

    /**
     * The absolute folder that each alias means, at the same index as its name.
     *
     * @example
     * ```hx
     * m.aliasPaths.items; // [ "/work/app/src/diag" ]
     * ```
     *
     * @since 1.0.0
     */

    aliasPaths: Strings,

    /**
     * The name of the microcontroller when `chip` is a string, such as `"STM32F411RE"`.
     *
     * @remarks
     * compile.hx looks the name up in lib/chips.
     * It is empty when `chip` is a description or is missing.
     *
     * @example
     * ```hx
     * m.chipName; // "STM32F411RE"
     * ```
     *
     * @since 1.0.0
     */

    chipName: string,

    /**
     * The core of the microcontroller that a firmware package is for, when `chip` describes it.
     *
     * @remarks
     * It is one of cortex-m0, cortex-m0plus, cortex-m3, cortex-m4, cortex-m7, and cortex-m33,
     * or empty when the package has no described chip.
     *
     * @example
     * ```hx
     * m.chipCpu; // "cortex-m4"
     * ```
     *
     * @since 1.0.0
     */

    chipCpu: string,

    /**
     * Whether the described chip has a floating-point unit that builds use.
     *
     * @example
     * ```hx
     * m.chipFpu; // true for "fpu": true
     * ```
     *
     * @since 1.0.0
     */

    chipFpu: bool,

    /**
     * The flash of the described chip as `origin:size`, the form that `--flash` takes.
     *
     * @example
     * ```hx
     * m.chipFlash; // "0x08000000:512K"
     * ```
     *
     * @since 1.0.0
     */

    chipFlash: string,

    /**
     * The RAM of the described chip as `origin:size`, in the same form as the flash.
     *
     * @example
     * ```hx
     * m.chipRam; // "0x20000000:128K"
     * ```
     *
     * @since 1.0.0
     */

    chipRam: string,
}
