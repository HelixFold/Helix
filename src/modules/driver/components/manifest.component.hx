/**
 * Imports
 */

import { equal, startsWith } from "std/text";
import * as os from "@modules/driver/components/os.component";
import { HxJson } from "@components/structs/json-component.struct";
import { ManifestFields } from "@modules/driver/constants/manifest.constant";
import { hxJsonParse, hxJsonFree, hxJsonGet } from "@components/json.component";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { JsonString, JsonArray, JsonObject, JsonBool } from "@constants/json.constant";
import { allocCString, toCString, fromCString, add, strings } from "@modules/driver/components/os.component";
import { Parsed, ManifestReader, Manifest } from "@modules/driver/components/structs/manifest-component.struct";

/**
 * Returns an element of a JSON array or the value of a member of a JSON object.
 *
 * @param v - The array or object
 * @param i - The index of the element or member, below the count of the value
 * @returns The element, which lives as long as the parsed tree
 *
 * @remarks
 * An object keeps its values in the same array as an array keeps its elements, so one function serves both.
 * It does not check the index, so the caller loops below the count of the value.
 *
 * @example
 * ```hx
 * // ["a.c", "b.c"]
 * text(itemAt(v, 1)); // "b.c"
 * ```
 *
 * @see keyAt
 * @since 1.0.0
 */

export function itemAt(v: readonly *HxJson, i: u32): readonly *HxJson {
    unsafe {
        return &v.items![i];
    }
}

/**
 * Copies the key of a member of a JSON object.
 *
 * @param v - The object
 * @param i - The index of the member
 * @returns The key in new memory, which outlives the parsed tree
 *
 * @remarks
 * The reader frees the JSON tree once it is done, so every string it keeps is a copy.
 *
 * @example
 * ```hx
 * // { "name": "app" }
 * keyAt(v, 0); // "name"
 * ```
 *
 * @see keyStart
 * @since 1.0.0
 */

export function keyAt(v: readonly *HxJson, i: u32): string {
    unsafe {
        return allocCString(`${fromCString(v.keys![i])}`);
    }
}

/**
 * Returns where the key of a member of a JSON object starts in the source.
 *
 * @param v - The object
 * @param i - The index of the member
 * @returns The byte offset of the key, for pointing an error at it
 *
 * @remarks
 * The offset goes to {@link manifestError}, so an error about a key points at the key and not at its value.
 *
 * @example
 * ```hx
 * // {"name": "app"}
 * keyStart(v, 0); // 1
 * ```
 *
 * @see manifestError
 * @since 1.0.0
 */

export function keyStart(v: readonly *HxJson, i: u32): u32 {
    unsafe {
        return v.keyStarts![i];
    }
}

/**
 * Copies the value of a JSON string.
 *
 * @param v - The string value
 * @returns The text in new memory, which outlives the parsed tree
 *
 * @remarks
 * The reader frees the JSON tree once it is done, so the copy is what a manifest keeps.
 *
 * @example
 * ```hx
 * // "app"
 * text(v); // "app"
 * ```
 *
 * @since 1.0.0
 */

export function text(v: readonly *HxJson): string {
    return allocCString(`${fromCString(os.asReadonly(v.string))}`);
}

/**
 * Looks up a member of a JSON object by its name.
 *
 * @param v - The object, or `null`
 * @param name - The name of the member
 * @returns The value of the member, or `null` when `v` is `null`, is not an object, or has no such member
 *
 * @remarks
 * It wraps `hxJsonGet`, which compares each key in order and returns the first match.
 *
 * @example
 * ```hx
 * // { "name": "app" }
 * text(member(v, "name")!); // "app"
 * member(v, "bin");         // null
 * ```
 *
 * @since 1.0.0
 */

export function member(v: ?readonly *HxJson, name: string): ?readonly *HxJson {
    return hxJsonGet(v, toCString(name));
}

/**
 * Parses a text as JSON with comments.
 *
 * @param source - The text, such as the contents of helix.jsonc
 * @returns The tree on success, or the message and the offset of the failure
 *
 * @remarks
 * Line and block comments are skipped, and a comma may follow the last element of an array or object.
 *
 * @example
 * ```hx
 * const p = parse("{ \"name\": \"app\", } // a comment");
 * p.ok; // true
 * ```
 *
 * @see Parsed
 * @since 1.0.0
 */

export function parse(source: string): Parsed {
    let p = Parsed { json: undefined, ok: false, error: "", at: 0 };
    let error: u8[128] = undefined;
    p.ok = hxJsonParse(toCString(source), source.len, &p.json, &error, 128, &p.at);
    unsafe {
        if (!p.ok) p.error = allocCString(`${fromCString(@ptrCast(readonly u8[*], &error))}`);
    }
    return p;
}

/**
 * Reports an error in a JSON file at a byte offset.
 *
 * @param path - The path of the file, as the message shows it
 * @param source - The text of the file
 * @param offset - The byte offset that the error points at
 * @param message - What is wrong
 *
 * @remarks
 * The message goes to the standard error as `path:line:col: error: message`,
 * with the line and column counted from 1.
 *
 * @example
 * ```hx
 * manifestError("helix.jsonc", "{\n  \"x\": 1 }", 4, "unknown field `x`");
 * // helix.jsonc:2:3: error: unknown field `x`
 * ```
 *
 * @since 1.0.0
 */

export function manifestError(path: string, source: string, offset: u32, message: string): void {
    let line: u32 = 1;
    let col: u32 = 1;
    for (const c, i of source) {
        if (i >= offset) break;
        if (c == '\n') {
            line++;
            col = 1;
        } else {
            col++;
        }
    }
    eprintln(`${path}:${line}:${col}: error: ${message}`);
}

/**
 * Reads a string member of a JSON object.
 *
 * @param r - The reader, which records a failure
 * @param object - The object
 * @param name - The name of the member
 * @returns A copy of the string, or `null` when the member is missing or is not a string
 *
 * @remarks
 * A member of another kind is reported and clears the reader's `ok` flag.
 *
 * @example
 * ```hx
 * // { "name": "app", "version": 1 }
 * jsonString(&r, json, "name");    // "app"
 * jsonString(&r, json, "version"); // null, reported as "`version` must be a string"
 * ```
 *
 * @since 1.0.0
 */

export function jsonString(r: *ManifestReader, object: readonly *HxJson, name: string): ?string {
    const v = member(object, name);
    if (v == null) return null;
    if (v.kind == JsonString) return text(v);
    manifestError(r.path, r.source, v.start, allocCString(`\`${name}\` must be a string`));
    r.ok = false;
    return null;
}

/**
 * Appends each string of an array member of a JSON object to a list.
 *
 * @param r - The reader, which records a failure
 * @param object - The object
 * @param name - The name of the member
 * @param dir - The folder to join each relative path to, or `null` to keep the strings as they are
 * @param out - The list that receives the strings
 *
 * @remarks
 * A missing member adds nothing.
 * A member that is not an array, and each element that is not a string, is reported and skipped.
 * With `dir`, a string that starts with `/` stays as it is.
 *
 * @example
 * ```hx
 * // { "sources": ["host.c", "/opt/x.c"] }
 * jsonStrings(&r, c, "sources", "/work/app", &out); // [ "/work/app/host.c", "/opt/x.c" ]
 * ```
 *
 * @since 1.0.0
 */

export function jsonStrings(r: *ManifestReader, object: readonly *HxJson, name: string, dir: ?string, out: *Strings): void {
    const v = member(object, name);
    if (v == null) return;
    if (v.kind != JsonArray) {
        manifestError(r.path, r.source, v.start, allocCString(`\`${name}\` must be an array of strings`));
        r.ok = false;
        return;
    }
    for (const i of 0..v.count) {
        const element = itemAt(v, i);
        if (element.kind != JsonString) {
            manifestError(r.path, r.source, element.start, allocCString(`\`${name}\` must hold only strings`));
            r.ok = false;
            continue;
        }
        const value = text(element);
        if (const base = dir) {
            if (value.len == 0 || value[0] != '/') {
                add(out, allocCString(`${base}/${value}`));
                continue;
            }
        }
        add(out, allocCString(`${value}`));
    }
}

/**
 * Reads an object member whose values are all strings into two parallel lists.
 *
 * @param r - The reader, which records a failure
 * @param object - The object that holds the member
 * @param name - The name of the member, such as `bin`, `scripts`, or `exports`
 * @param names - The list that receives the keys
 * @param values - The list that receives the values, at the same index as their keys
 *
 * @remarks
 * A missing member adds nothing.
 * A member that is not an object, and each value that is not a string, is reported and skipped.
 *
 * @example
 * ```hx
 * // { "bin": { "app": "src/main.hx" } }
 * jsonStringMap(&r, json, "bin", &names, &values); // names [ "app" ], values [ "src/main.hx" ]
 * ```
 *
 * @since 1.0.0
 */

export function jsonStringMap(r: *ManifestReader, object: readonly *HxJson, name: string, names: *Strings, values: *Strings): void {
    const v = member(object, name);
    if (v == null) return;
    if (v.kind != JsonObject) {
        manifestError(r.path, r.source, v.start, allocCString(`\`${name}\` must be an object of strings`));
        r.ok = false;
        return;
    }
    for (const i of 0..v.count) {
        const value = itemAt(v, i);
        if (value.kind != JsonString) {
            manifestError(r.path, r.source, value.start, allocCString(`\`${name}.${keyAt(v, i)}\` must be a string`));
            r.ok = false;
            continue;
        }
        add(names, allocCString(`${keyAt(v, i)}`));
        add(values, allocCString(`${text(value)}`));
    }
}

/**
 * Appends the keys of an object member to a list.
 *
 * @param r - The reader, which records a failure
 * @param object - The object that holds the member
 * @param name - The name of the member, such as `dependencies`
 * @param out - The list that receives the keys
 *
 * @remarks
 * The compiler only needs the names of the dependencies, so the values, which belong to hpm, stay unread.
 * A member that is not an object is reported.
 *
 * @since 1.0.0
 */

function jsonKeys(r: *ManifestReader, object: readonly *HxJson, name: string, out: *Strings): void {
    const v = member(object, name);
    if (v == null) return;
    if (v.kind != JsonObject) {
        manifestError(r.path, r.source, v.start, allocCString(`\`${name}\` must be an object: { "name": "spec" }`));
        r.ok = false;
        return;
    }
    for (const i of 0..v.count) add(out, keyAt(v, i));
}

/**
 * Creates a manifest that says nothing about a package.
 *
 * @param dir - The folder of the package
 * @returns A manifest with empty lists, no name or version, and no chip
 *
 * @remarks
 * Use it for a package without a helix.jsonc, or as the start of a read.
 *
 * @example
 * ```hx
 * emptyManifest("/work/app").binNames.items.len; // 0
 * ```
 *
 * @see loadManifest
 * @since 1.0.0
 */

export function emptyManifest(dir: string): Manifest {
    return Manifest {
        dir, name: null, version: null, exportPaths: strings(), exportFiles: strings(), cSources: strings(),
        cFlags: strings(), includeDirs: strings(), systemLibraries: strings(), binNames: strings(), binRoots: strings(),
        scriptNames: strings(), scriptCommands: strings(), deps: strings(), devDeps: strings(), peerDeps: strings(),
        aliasNames: strings(), aliasPaths: strings(), chipName: "", chipCpu: "", chipFpu: false, chipFlash: "", chipRam: "",
    };
}

/**
 * Reads an object member of a JSON object.
 *
 * @param r - The reader, which records a failure
 * @param object - The object that holds the member
 * @param name - The name of the member
 * @param example - A sample of the expected shape, which the error message shows
 * @returns The member, or `null` when it is missing or is not an object
 *
 * @remarks
 * A member of another kind is reported.
 *
 * @since 1.0.0
 */

function jsonObject(r: *ManifestReader, object: readonly *HxJson, name: string, example: string): ?readonly *HxJson {
    const v = member(object, name);
    if (v == null) return null;
    if (v.kind == JsonObject) return v;
    manifestError(r.path, r.source, v.start, allocCString(`\`${name}\` must be an object: ${example}`));
    r.ok = false;
    return null;
}

/**
 * Reads the C that a package brings.
 *
 * @param r - The reader, which records a failure
 * @param json - The top-level object of helix.jsonc
 * @param m - The manifest to fill
 *
 * @remarks
 * It reads `c` with `sources`, `flags`, `includeDirs`, and `systemLibraries`,
 * then the older `module` with `cSources`, `cFlags`, `includeDirs`, and `systemLibraries`.
 * The source and include paths become absolute, and the patterns in the source names are expanded last.
 *
 * @since 1.0.0
 */

function readC(r: *ManifestReader, json: readonly *HxJson, m: *Manifest): void {
    if (const c = jsonObject(r, json, "c", "{ \"sources\": [\"c/*.c\"] }")) {
        jsonStrings(r, c, "sources", m.dir, &m.cSources);
        jsonStrings(r, c, "flags", null, &m.cFlags);
        jsonStrings(r, c, "includeDirs", m.dir, &m.includeDirs);
        jsonStrings(r, c, "systemLibraries", null, &m.systemLibraries);
    }
    if (const mod = jsonObject(r, json, "module", "{ \"root\": \"src/index.hx\" }")) {
        jsonStrings(r, mod, "cSources", m.dir, &m.cSources);
        jsonStrings(r, mod, "cFlags", null, &m.cFlags);
        jsonStrings(r, mod, "includeDirs", m.dir, &m.includeDirs);
        jsonStrings(r, mod, "systemLibraries", null, &m.systemLibraries);
    }
    m.cSources = expandSources(&m.cSources);
}

/**
 * Reads what a package exports.
 *
 * @param r - The reader, which records a failure
 * @param json - The top-level object of helix.jsonc
 * @param m - The manifest to fill
 *
 * @remarks
 * `exports` is either a file, which means the path `.`, or a map from import paths to files.
 * Each import path must be `.` or start with `./`.
 * Without `exports`, `.` means `module.root`, else src/index.hx.
 * The files become absolute.
 *
 * @since 1.0.0
 */

function readExports(r: *ManifestReader, json: readonly *HxJson, m: *Manifest): void {
    let paths = strings();
    let files = strings();
    const v = member(json, "exports");
    if (v != null && v.kind == JsonString) {
        add(&paths, ".");
        add(&files, text(v));
    } else {
        jsonStringMap(r, json, "exports", &paths, &files);
    }
    for (const path of paths.items) {
        if (equal(path, ".") || startsWith(path, "./")) continue;
        let at: u32 = 0;
        if (const e = v) at = e.start;
        manifestError(r.path, r.source, at, allocCString(`export "${path}" must be "." or start with "./"`));
        r.ok = false;
    }
    if (paths.items.len == 0) {
        let root = "src/index.hx";
        if (const mod = member(json, "module")) {
            if (mod.kind == JsonObject) {
                if (const value = jsonString(r, mod, "root")) root = value;
            }
        }
        add(&paths, ".");
        add(&files, root);
    }
    for (const path, i of paths.items) {
        add(&m.exportPaths, path);
        add(&m.exportFiles, allocCString(`${m.dir}/${files.items[i]}`));
    }
}

/**
 * Checks whether a name can be an alias.
 *
 * @param name - The name to check
 * @returns `true` for `@` followed by one or more letters, digits, `_`, `-`, or `.`
 *
 * @remarks
 * {@link readAliases} rejects any other name, so an alias always reads like a scope such as `@utils`.
 *
 * @since 1.0.0
 */

function aliasName(name: string): bool {
    if (name.len < 2 || name[0] != '@') return false;
    for (const c of name[1..]) {
        const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
        if (!ok) return false;
    }
    return true;
}

/**
 * Checks whether a path has a `..` part.
 *
 * @param path - The path, with `/` between its parts
 * @returns `true` when any part is exactly `..`
 *
 * @remarks
 * A name that only starts with `..`, such as `..data`, is not a parent part.
 * {@link readAliases} uses it to keep an alias inside its package.
 *
 * @since 1.0.0
 */

function hasParentPart(path: string): bool {
    let start: usize = 0;
    for (const c, i of path) {
        if (c != '/' && i + 1 < path.len) continue;
        const end = c == '/' ? i : i + 1;
        if (equal(path[start..end], "..")) return true;
        start = i + 1;
    }
    return false;
}

/**
 * Finds a dependency of a package that lies in a scope.
 *
 * @param m - The manifest with the dependencies read
 * @param name - The scope, such as `@acme`
 * @returns The first dependency named `<scope>/...` in any of the three lists, or `null` when there is none
 *
 * @remarks
 * An alias with the name of a scope would hide every package in that scope,
 * so {@link readAliases} rejects it and names the dependency.
 *
 * @since 1.0.0
 */

function scopeUsed(m: readonly *Manifest, name: string): ?string {
    const lists: (readonly *Strings)[3] = [&m.deps, &m.devDeps, &m.peerDeps];
    for (const list of lists) {
        for (const dep of list.items) {
            if (dep.len > name.len && startsWith(dep, name) && dep[name.len] == '/') return dep;
        }
    }
    return null;
}

/**
 * Reads the aliases of a package.
 *
 * @param r - The reader, which records a failure
 * @param json - The top-level object of helix.jsonc
 * @param m - The manifest to fill, with the dependencies already read
 *
 * @remarks
 * `{ "@diag": "src/diag" }` makes `import ... from "@diag/x"` in this package's files mean src/diag/x.
 * A path must stay inside the package, with no `..` part and no leading `/`,
 * so that the aliases of a published package still work.
 * A name cannot be the scope of a dependency, or `@acme/tls` would mean two things.
 * Leading `./` and trailing `/` are dropped, and the path becomes absolute.
 *
 * @since 1.0.0
 */

function readAliases(r: *ManifestReader, json: readonly *HxJson, m: *Manifest): void {
    let names = strings();
    let paths = strings();
    jsonStringMap(r, json, "aliases", &names, &paths);
    const v = member(json, "aliases");
    for (const name, i of names.items) {
        const path = paths.items[i];
        let at: u32 = 0;
        if (const object = v) at = keyStart(object, @truncate(u32, i));
        if (!aliasName(name)) {
            manifestError(r.path, r.source, at, allocCString(`alias "${name}" must be @ and a name, like "@utils"`));
            r.ok = false;
            continue;
        }
        if (const dep = scopeUsed(m, name)) {
            manifestError(r.path, r.source, at, allocCString(`alias "${name}" is also the scope of the dependency "${dep}"`));
            eprintln(`  = hint: pick another name, so "${dep}" still means the package`);
            r.ok = false;
            continue;
        }
        if (path.len == 0 || path[0] == '/' || hasParentPart(path)) {
            manifestError(r.path, r.source, at, allocCString(`alias "${name}" must point to a folder inside the package, like "src/utils", not '${path}'`));
            r.ok = false;
            continue;
        }
        let clean = path;
        while (startsWith(clean, "./")) clean = clean[2..];
        while (clean.len > 0 && clean[clean.len - 1] == '/') clean = clean[0..clean.len - 1];
        add(&m.aliasNames, name);
        add(&m.aliasPaths, clean.len == 0 || equal(clean, ".") ? m.dir : allocCString(`${m.dir}/${clean}`));
    }
}

/**
 * Reads a memory region of a described chip.
 *
 * @param r - The reader, which records a failure
 * @param chip - The `chip` object
 * @param name - The name of the region, `flash` or `ram`
 * @returns The region as `origin:size`, such as `0x08000000:512K`, or an empty string after a report
 *
 * @remarks
 * The region is `{ "origin": "0x08000000", "size": "512K" }`, and a missing region or field is reported.
 *
 * @since 1.0.0
 */

function memoryRegion(r: *ManifestReader, chip: readonly *HxJson, name: string): string {
    const v = member(chip, name);
    if (v == null) {
        manifestError(r.path, r.source, chip.start, allocCString(`\`chip\` needs \`${name}\`: { "origin": "0x...", "size": "...K" }`));
        r.ok = false;
        return "";
    }
    const region = v;
    const origin = jsonString(r, region, "origin");
    const size = jsonString(r, region, "size");
    if (origin == null || size == null) {
        manifestError(r.path, r.source, region.start, allocCString(`\`chip.${name}\` is { "origin": "0x...", "size": "...K" }`));
        r.ok = false;
        return "";
    }
    return allocCString(`${origin}:${size}`);
}

/**
 * Reads the microcontroller that a firmware package runs on.
 *
 * @param r - The reader, which records a failure
 * @param json - The top-level object of helix.jsonc
 * @param m - The manifest to fill
 *
 * @remarks
 * `chip` is either a name that the chip table knows, such as `"STM32F411RE"`, or a description.
 * A description gives the core in `cpu` (cortex-m0, cortex-m0plus, cortex-m3, cortex-m4, cortex-m7, or cortex-m33),
 * whether the chip has and uses an FPU in `fpu`, and its `flash` and `ram`.
 * Builds of the package then default to that target, CPU, and memory layout (docs/design/build.md).
 *
 * @since 1.0.0
 */

function readChip(r: *ManifestReader, json: readonly *HxJson, m: *Manifest): void {
    const chip = member(json, "chip");
    if (chip == null) return;
    const c = chip;
    if (c.kind == JsonString) {   // a name: the chip table has the rest
        m.chipName = text(c);
        return;
    }
    if (c.kind != JsonObject) {
        manifestError(r.path, r.source, c.start, "`chip` must be an object: { \"cpu\", \"fpu\", \"flash\", \"ram\" }");
        r.ok = false;
        return;
    }
    m.chipCpu = jsonString(r, c, "cpu") ?? "";
    if (m.chipCpu.len == 0) {
        manifestError(r.path, r.source, c.start, "`chip` needs `cpu`: cortex-m0, cortex-m0plus, cortex-m3, cortex-m4, cortex-m7 or cortex-m33");
        r.ok = false;
    }
    if (const fpu = member(c, "fpu")) m.chipFpu = fpu.kind == JsonBool && fpu.boolean;
    m.chipFlash = memoryRegion(r, c, "flash");
    m.chipRam = memoryRegion(r, c, "ram");
}

/**
 * Reads the helix.jsonc of a package.
 *
 * @param dir - The folder of the package
 * @param required - Whether a missing helix.jsonc is an error to report
 * @returns The manifest, or `null` when the file is missing or has a mistake
 *
 * @remarks
 * The file is JSON with comments and trailing commas.
 * An unknown top-level field stops the read with an error and a hint,
 * while other mistakes are all reported before the read gives up.
 * Every message goes to the standard error as `path:line:col: error: ...`.
 *
 * @example
 * ```hx
 * // /work/app/helix.jsonc: { "name": "app", "bin": { "app": "src/main.hx" } }
 * loadManifest("/work/app", true)!.binNames.items; // [ "app" ]
 * loadManifest("/tmp", false);                     // null, and nothing is reported
 * ```
 *
 * @see Manifest
 * @since 1.0.0
 */

export function loadManifest(dir: string, required: bool): ?Manifest {
    let m = emptyManifest(dir);
    const path = allocCString(`${dir}/helix.jsonc`);
    const loaded = os.readText(path);
    if (loaded == null) {
        if (!required) return null;
        eprintln(`error: '${dir}' has no helix.jsonc, so it isn't a Helix package`);
        return null;
    }
    const source: string = loaded;
    let parsed = parse(source);
    if (!parsed.ok) {
        manifestError(path, source, parsed.at, parsed.error);
        return null;
    }
    defer hxJsonFree(&parsed.json);
    const json = &parsed.json;
    let r = ManifestReader { path, source, ok: true };
    if (json.kind != JsonObject) {
        manifestError(path, source, json.start, "helix.jsonc must hold an object: { \"name\": ..., \"version\": ... }");
        return null;
    }
    for (const i of 0..json.count) {
        let known = false;
        for (const field of ManifestFields) {
            if (equal(keyAt(json, i), field)) known = true;
        }
        if (!known) {
            manifestError(path, source, keyStart(json, i), allocCString(`unknown field \`${keyAt(json, i)}\``));
            eprintln("  = hint: the fields are listed in docs/design/build.md and hpm.md");
            return null;
        }
    }
    m.name = jsonString(&r, json, "name");
    m.version = jsonString(&r, json, "version");
    readExports(&r, json, &m);
    readC(&r, json, &m);
    jsonStringMap(&r, json, "bin", &m.binNames, &m.binRoots);
    jsonStringMap(&r, json, "scripts", &m.scriptNames, &m.scriptCommands);
    jsonKeys(&r, json, "dependencies", &m.deps);
    jsonKeys(&r, json, "devDependencies", &m.devDeps);
    jsonKeys(&r, json, "peerDependencies", &m.peerDeps);
    readAliases(&r, json, &m);
    readChip(&r, json, &m);
    if (!r.ok) return null;
    return m;
}

/**
 * Expands the patterns in C source paths, such as `c/src/x*.c`.
 *
 * @param paths - The paths, some of which may hold `*`, `?`, or `[`
 * @returns The paths without patterns as they are, and each pattern replaced by its matches in sorted order
 *
 * @remarks
 * Only the file name may hold a pattern, since the folder is listed as written.
 * Hidden files never match, and a pattern without matches adds nothing.
 *
 * @since 1.0.0
 */

function expandSources(paths: readonly *Strings): Strings {
    let expanded = strings();
    for (const path of paths.items) {
        let pattern = false;
        for (const c of path) {
            if (c == '*' || c == '?' || c == '[') pattern = true;
        }
        if (!pattern) {
            add(&expanded, path);
            continue;
        }
        let dir = ".";
        let name = path;
        if (const slash = os.lastIndex(path, '/')) {
            dir = path[0..slash];
            name = path[slash + 1..];
        }
        const first = expanded.items.len;
        if (const names = os.listDir(dir)) {
            for (const entry of names.items) {
                if (entry[0] != '.' && os.matches(name, entry)) add(&expanded, allocCString(`${dir}/${entry}`));
            }
        }
        os.sort(expanded.items[first..]);
    }
    return expanded;
}

/**
 * Checks whether a list holds a string.
 *
 * @param list - The list to search
 * @param name - The string to find
 * @returns `true` when an entry is equal to `name`
 *
 * @remarks
 * It compares whole strings, so a scope such as `@acme` does not match `@acme/tls`.
 *
 * @example
 * ```hx
 * contains(&m.deps, "@acme/tls"); // true when the package depends on it
 * ```
 *
 * @since 1.0.0
 */

export function contains(list: readonly *Strings, name: string): bool {
    for (const entry of list.items) {
        if (equal(entry, name)) return true;
    }
    return false;
}
