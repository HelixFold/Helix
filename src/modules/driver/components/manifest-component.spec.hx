/**
 * Imports
 */

import { JsonObject } from "@constants/json.constant";
import { hxJsonFree } from "@components/json.component";
import * as os from "@modules/driver/components/os.component";
import * as manifest from "@modules/driver/components/manifest.component";
import { ManifestReader } from "@modules/driver/components/structs/manifest-component.struct";

/**
 * Tests
 */

/**
 * A new package folder under the temporary folder whose helix.jsonc holds the given text.
 *
 * @param name - The name of the package folder
 * @param jsonc - The text of its helix.jsonc
 * @returns The path of the package folder
 *
 * @remarks
 * Any folder left at the path by an earlier run is removed first, so each case starts clean.
 *
 * @since 1.0.0
 */

function project(name: string, jsonc: string): string {
    const dir = os.allocCString(`${os.tempDir()}/helix-manifest-spec-${os.pid()}/${name}`);
    os.removeTree(dir);
    void os.makeDirs(dir);
    void os.writeText(os.allocCString(`${dir}/helix.jsonc`), jsonc);
    return dir;
}

/**
 * Removes every folder that {@link project} made.
 *
 * @remarks
 * Every package folder lives under one folder named after the process, so removing that folder removes them all.
 *
 * @since 1.0.0
 */

function cleanUp(): void {
    os.removeTree(os.allocCString(`${os.tempDir()}/helix-manifest-spec-${os.pid()}`));
}

describe("itemAt") {
    test("should give the element at an index of an array") {
        let p = manifest.parse("[\"a.c\", \"b.c\"]");
        defer hxJsonFree(&p.json);

        expect(manifest.text(manifest.itemAt(&p.json, 1))).toBe("b.c");
    }

    test("should give the value of a member of an object") {
        let p = manifest.parse("{ \"a\": \"x\", \"b\": \"y\" }");
        defer hxJsonFree(&p.json);

        expect(manifest.text(manifest.itemAt(&p.json, 1))).toBe("y");
    }
}

describe("keyAt") {
    test("should copy the key so that it outlives the tree") {
        let p = manifest.parse("{ \"name\": \"app\", \"bin\": {} }");
        const first = manifest.keyAt(&p.json, 0);
        const second = manifest.keyAt(&p.json, 1);
        hxJsonFree(&p.json);

        expect(first).toBe("name");
        expect(second).toBe("bin");
    }
}

describe("keyStart") {
    test("should give the offset of the key in the source") {
        let p = manifest.parse("{\"name\": 1,\n \"bin\": 2}");
        defer hxJsonFree(&p.json);

        expect(manifest.keyStart(&p.json, 0)).toBe(1);
        expect(manifest.keyStart(&p.json, 1)).toBe(13);
    }
}

describe("text") {
    test("should copy the value of a string") {
        let p = manifest.parse("\"hello\"");
        const value = manifest.text(&p.json);
        hxJsonFree(&p.json);

        expect(value).toBe("hello");
    }
}

describe("member") {
    test("should find a member by its name") {
        let p = manifest.parse("{ \"name\": \"app\" }");
        defer hxJsonFree(&p.json);

        expect(manifest.text(manifest.member(&p.json, "name")!)).toBe("app");
    }

    test("should give null for a missing member, a null object, or a value that is not an object") {
        let p = manifest.parse("{ \"list\": [1] }");
        defer hxJsonFree(&p.json);

        expect(manifest.member(&p.json, "bin") == null).toBeTrue();
        expect(manifest.member(null, "bin") == null).toBeTrue();
        expect(manifest.member(manifest.member(&p.json, "list"), "x") == null).toBeTrue();
    }
}

describe("parse") {
    test("should accept comments and trailing commas") {
        let p = manifest.parse("// helix.jsonc\n{ \"name\": \"app\", /* the name */ \"bin\": {}, }");
        defer hxJsonFree(&p.json);

        expect(p.ok).toBeTrue();
        expect(p.json.kind).toBe(JsonObject);
        expect(p.error).toBe("");
    }

    test("should give the message and the offset of a failure") {
        const p = manifest.parse("{ \"name\": }");

        expect(p.ok).toBeFalse();
        expect(p.error.len > 0).toBeTrue();
        expect(p.at).toBe(10);
    }
}

describe("jsonString") {
    test("should read a string member") {
        let p = manifest.parse("{ \"name\": \"app\" }");
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source: "", ok: true };

        expect(manifest.jsonString(&r, &p.json, "name") ?? "<null>").toBe("app");
        expect(r.ok).toBeTrue();
    }

    test("should give null for a missing member without a report") {
        let p = manifest.parse("{}");
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source: "{}", ok: true };

        expect(manifest.jsonString(&r, &p.json, "name") == null).toBeTrue();
        expect(r.ok).toBeTrue();
    }

    test("should report a member of another kind") {
        const source = "{ \"version\": 1 }";
        let p = manifest.parse(source);
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source, ok: true };

        expect(manifest.jsonString(&r, &p.json, "version") == null).toBeTrue();
        expect(r.ok).toBeFalse();
    }
}

describe("jsonStrings") {
    test("should join relative strings to the folder and keep absolute ones") {
        let p = manifest.parse("{ \"sources\": [\"host.c\", \"/opt/x.c\"] }");
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source: "", ok: true };
        let out = os.strings();
        manifest.jsonStrings(&r, &p.json, "sources", "/work/app", &out);

        expect(out.items.len).toBe(2);
        expect(out.items[0]).toBe("/work/app/host.c");
        expect(out.items[1]).toBe("/opt/x.c");
    }

    test("should keep the strings as they are without a folder") {
        let p = manifest.parse("{ \"flags\": [\"-O2\"] }");
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source: "", ok: true };
        let out = os.strings();
        manifest.jsonStrings(&r, &p.json, "flags", null, &out);

        expect(out.items[0]).toBe("-O2");
    }

    test("should report and skip an element that is not a string") {
        const source = "{ \"flags\": [\"-O2\", 3, \"-g\"] }";
        let p = manifest.parse(source);
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source, ok: true };
        let out = os.strings();
        manifest.jsonStrings(&r, &p.json, "flags", null, &out);

        expect(out.items.len).toBe(2);
        expect(r.ok).toBeFalse();
    }

    test("should report a member that is not an array") {
        const source = "{ \"flags\": \"-O2\" }";
        let p = manifest.parse(source);
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source, ok: true };
        let out = os.strings();
        manifest.jsonStrings(&r, &p.json, "flags", null, &out);

        expect(out.items.len).toBe(0);
        expect(r.ok).toBeFalse();
    }
}

describe("jsonStringMap") {
    test("should read the keys and values into parallel lists") {
        let p = manifest.parse("{ \"bin\": { \"app\": \"src/main.hx\", \"tool\": \"src/tool.hx\" } }");
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source: "", ok: true };
        let names = os.strings();
        let values = os.strings();
        manifest.jsonStringMap(&r, &p.json, "bin", &names, &values);

        expect(names.items.len).toBe(2);
        expect(names.items[1]).toBe("tool");
        expect(values.items[1]).toBe("src/tool.hx");
    }

    test("should report and skip a value that is not a string") {
        const source = "{ \"scripts\": { \"a\": 1, \"b\": \"echo\" } }";
        let p = manifest.parse(source);
        defer hxJsonFree(&p.json);
        let r = ManifestReader { path: "helix.jsonc", source, ok: true };
        let names = os.strings();
        let values = os.strings();
        manifest.jsonStringMap(&r, &p.json, "scripts", &names, &values);

        expect(names.items.len).toBe(1);
        expect(names.items[0]).toBe("b");
        expect(r.ok).toBeFalse();
    }
}

describe("emptyManifest") {
    test("should hold only the folder") {
        const m = manifest.emptyManifest("/work/app");

        expect(m.dir).toBe("/work/app");
        expect(m.name == null).toBeTrue();
        expect(m.binNames.items.len).toBe(0);
        expect(m.chipName).toBe("");
        expect(m.chipFpu).toBeFalse();
    }
}

describe("loadManifest") {
    test("should read the name, the version, and the programs") {
        const dir = project("basic", os.allocCString(`// the package\n{ "name": "app", "version": "1.2.3",
            "bin": { "app": "src/main.hx" }, }`));
        defer cleanUp();
        const m = manifest.loadManifest(dir, true)!;

        expect(m.name ?? "").toBe("app");
        expect(m.version ?? "").toBe("1.2.3");
        expect(m.binNames.items[0]).toBe("app");
        expect(m.binRoots.items[0]).toBe("src/main.hx");
    }

    test("should export src/index.hx as the package without exports") {
        const dir = project("defaultExport", "{ \"name\": \"lib\" }");
        defer cleanUp();
        const m = manifest.loadManifest(dir, true)!;

        expect(m.exportPaths.items[0]).toBe(".");
        expect(m.exportFiles.items[0]).toBe(os.allocCString(`${dir}/src/index.hx`));
    }

    test("should export module.root when exports is missing") {
        const dir = project("moduleRoot", "{ \"module\": { \"root\": \"lib/main.hx\" } }");
        defer cleanUp();
        const m = manifest.loadManifest(dir, true)!;

        expect(m.exportFiles.items[0]).toBe(os.allocCString(`${dir}/lib/main.hx`));
    }

    test("should read exports given as one file or as a map") {
        const one = project("exportFile", "{ \"exports\": \"src/lib.hx\" }");
        const map = project("exportMap", "{ \"exports\": { \".\": \"src/a.hx\", \"./x509\": \"src/x509.hx\" } }");
        defer cleanUp();
        const a = manifest.loadManifest(one, true)!;
        const b = manifest.loadManifest(map, true)!;

        expect(a.exportPaths.items[0]).toBe(".");
        expect(a.exportFiles.items[0]).toBe(os.allocCString(`${one}/src/lib.hx`));
        expect(b.exportPaths.items[1]).toBe("./x509");
        expect(b.exportFiles.items[1]).toBe(os.allocCString(`${map}/src/x509.hx`));
    }

    test("should reject an export path that does not start with ./") {
        const dir = project("badExport", "{ \"exports\": { \"x509\": \"src/x509.hx\" } }");
        defer cleanUp();

        expect(manifest.loadManifest(dir, true) == null).toBeTrue();
    }

    test("should read the C of both c and module, with absolute paths") {
        const json = os.allocCString(`{ "c": { "sources": ["c/a.c"], "flags": ["-O2"],
            "includeDirs": ["c"], "systemLibraries": ["z"] },
            "module": { "cSources": ["c/b.c"], "cFlags": ["-g"] } }`);
        const dir = project("cSources", json);
        defer cleanUp();
        const m = manifest.loadManifest(dir, true)!;

        expect(m.cSources.items.len).toBe(2);
        expect(m.cSources.items[1]).toBe(os.allocCString(`${dir}/c/b.c`));
        expect(m.cFlags.items[1]).toBe("-g");
        expect(m.includeDirs.items[0]).toBe(os.allocCString(`${dir}/c`));
        expect(m.systemLibraries.items[0]).toBe("z");
    }

    test("should expand a pattern in a C source name in sorted order, skipping hidden files") {
        const dir = project("cPattern", "{ \"c\": { \"sources\": [\"c/x*.c\"] } }");
        defer cleanUp();
        void os.makeDirs(os.allocCString(`${dir}/c`));
        void os.writeText(os.allocCString(`${dir}/c/xb.c`), "");
        void os.writeText(os.allocCString(`${dir}/c/xa.c`), "");
        void os.writeText(os.allocCString(`${dir}/c/y.c`), "");
        const m = manifest.loadManifest(dir, true)!;

        expect(m.cSources.items.len).toBe(2);
        expect(m.cSources.items[0]).toBe(os.allocCString(`${dir}/c/xa.c`));
        expect(m.cSources.items[1]).toBe(os.allocCString(`${dir}/c/xb.c`));
    }

    test("should read the names of the three kinds of dependency") {
        const json = os.allocCString(`{ "dependencies": { "@acme/tls": "^1" }, "devDependencies": { "bench": "*" },
            "peerDependencies": { "std": "*" } }`);
        const dir = project("deps", json);
        defer cleanUp();
        const m = manifest.loadManifest(dir, true)!;

        expect(m.deps.items[0]).toBe("@acme/tls");
        expect(m.devDeps.items[0]).toBe("bench");
        expect(m.peerDeps.items[0]).toBe("std");
    }

    test("should make alias paths absolute and drop ./ and trailing slashes") {
        const dir = project("aliases", "{ \"aliases\": { \"@diag\": \"./src/diag/\", \"@root\": \".\" } }");
        defer cleanUp();
        const m = manifest.loadManifest(dir, true)!;

        expect(m.aliasNames.items[0]).toBe("@diag");
        expect(m.aliasPaths.items[0]).toBe(os.allocCString(`${dir}/src/diag`));
        expect(m.aliasPaths.items[1]).toBe(dir);
    }

    test("should reject an alias without @, one that leaves the package, or one that is a dependency scope") {
        const noAt = project("aliasName", "{ \"aliases\": { \"diag\": \"src/diag\" } }");
        const parent = project("aliasParent", "{ \"aliases\": { \"@up\": \"src/../..\" } }");
        const absolute = project("aliasAbsolute", "{ \"aliases\": { \"@abs\": \"/usr\" } }");
        const scope = project("aliasScope", os.allocCString(`{ "dependencies": { "@acme/tls": "1" },
            "aliases": { "@acme": "src" } }`));
        defer cleanUp();

        expect(manifest.loadManifest(noAt, true) == null).toBeTrue();
        expect(manifest.loadManifest(parent, true) == null).toBeTrue();
        expect(manifest.loadManifest(absolute, true) == null).toBeTrue();
        expect(manifest.loadManifest(scope, true) == null).toBeTrue();
    }

    test("should keep a chip given by name") {
        const dir = project("chipName", "{ \"chip\": \"STM32F411RE\" }");
        defer cleanUp();
        const m = manifest.loadManifest(dir, true)!;

        expect(m.chipName).toBe("STM32F411RE");
        expect(m.chipCpu).toBe("");
    }

    test("should read a described chip") {
        const json = os.allocCString(`{ "chip": { "cpu": "cortex-m4", "fpu": true,
            "flash": { "origin": "0x08000000", "size": "512K" },
            "ram": { "origin": "0x20000000", "size": "128K" } } }`);
        const dir = project("chipDescribed", json);
        defer cleanUp();
        const m = manifest.loadManifest(dir, true)!;

        expect(m.chipCpu).toBe("cortex-m4");
        expect(m.chipFpu).toBeTrue();
        expect(m.chipFlash).toBe("0x08000000:512K");
        expect(m.chipRam).toBe("0x20000000:128K");
    }

    test("should reject a described chip without a cpu or a memory region") {
        const noCpu = project("chipNoCpu", os.allocCString(`{ "chip": { "flash": { "origin": "0", "size": "1K" },
            "ram": { "origin": "0", "size": "1K" } } }`));
        const noRam = project("chipNoRam", os.allocCString(`{ "chip": { "cpu": "cortex-m0",
            "flash": { "origin": "0", "size": "1K" } } }`));
        defer cleanUp();

        expect(manifest.loadManifest(noCpu, true) == null).toBeTrue();
        expect(manifest.loadManifest(noRam, true) == null).toBeTrue();
    }

    test("should reject an unknown field") {
        const dir = project("unknown", "{ \"name\": \"app\", \"nmae\": \"typo\" }");
        defer cleanUp();

        expect(manifest.loadManifest(dir, true) == null).toBeTrue();
    }

    test("should accept every field that hpm uses too") {
        const dir = project("hpmFields", os.allocCString(`{ "$schema": "x", "license": "MIT", "keywords": [],
            "workspaces": [] }`));
        defer cleanUp();

        expect(manifest.loadManifest(dir, true) != null).toBeTrue();
    }

    test("should reject a file that does not parse or does not hold an object") {
        const broken = project("broken", "{ \"name\": ");
        const array = project("array", "[]");
        defer cleanUp();

        expect(manifest.loadManifest(broken, true) == null).toBeTrue();
        expect(manifest.loadManifest(array, true) == null).toBeTrue();
    }

    test("should give null for a folder without helix.jsonc") {
        const dir = project("missing", "");
        defer cleanUp();
        os.unlink(os.allocCString(`${dir}/helix.jsonc`));

        expect(manifest.loadManifest(dir, false) == null).toBeTrue();
        expect(manifest.loadManifest(dir, true) == null).toBeTrue();
    }
}

describe("contains") {
    test("should find an entry that is equal to the name") {
        let list = os.strings();
        os.add(&list, "@acme/tls");

        expect(manifest.contains(&list, "@acme/tls")).toBeTrue();
        expect(manifest.contains(&list, "@acme")).toBeFalse();
    }
}
