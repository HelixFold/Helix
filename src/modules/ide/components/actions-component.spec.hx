/**
 * Imports
 */

import { buffer } from "@modules/ide/components/json.component";
import { tempDir, makeDirs } from "@modules/driver/components/os.component";
import { defaultOptions } from "@modules/driver/components/compile.component";
import { Action } from "@modules/ide/components/structs/actions-component.struct";
import { debugAction, buildAction, testAction } from "@modules/ide/components/actions.component";
import { cmdActions, debugAdapter, projectDir, runAction } from "@modules/ide/components/actions.component";
import { cmdDebugLaunch, writeAction, writeProjectActions } from "@modules/ide/components/actions.component";
import { writeText, allocCString, toCString, pid, add, strings } from "@modules/driver/components/os.component";

/**
 * Tests
 */

extern "C" function setenv(name: readonly u8[*], value: readonly u8[*], overwrite: i32): i32;

/**
 * The folder that holds this run's projects, created on first use.
 *
 * @returns The temporary folder of this process, with a `project`, a `scripted`, and a `loose` folder inside
 *
 * @remarks
 * The `project` folder holds a `helix.jsonc`, and the `scripted` folder also holds an empty `build.hx`.
 * The `loose` folder holds neither, so it stands for a file outside any project.
 * Every call writes the same files again, which leaves the result unchanged.
 *
 * @since 1.0.0
 */

function root(): string {
    const dir = allocCString(`${tempDir()}/helix-actions-spec-${pid()}`);
    void makeDirs(allocCString(`${dir}/project/src`));
    void makeDirs(allocCString(`${dir}/scripted`));
    void makeDirs(allocCString(`${dir}/loose`));
    void writeText(allocCString(`${dir}/project/helix.jsonc`), "{}");
    void writeText(allocCString(`${dir}/scripted/helix.jsonc`), "{}");
    void writeText(allocCString(`${dir}/scripted/build.hx`), "");

    return dir;
}

/**
 * The text that writing one action gives.
 *
 * @param a - The action to write
 * @returns The JSON text that {@link writeAction} writes for the action
 *
 * @remarks
 * Writes into a fresh buffer, so the text holds that one action and nothing else.
 *
 * @since 1.0.0
 */

function written(a: Action): string {
    let b = buffer();
    writeAction(&b, &a);

    return b.text();
}

describe("projectDir") {
    test("should find the nearest folder up that holds a helix.jsonc") {
        const dir = root();

        expect(projectDir(allocCString(`${dir}/project/src/main.hx`))).toBe(allocCString(`${dir}/project`));
    }

    test("should return a project folder itself") {
        const dir = root();

        expect(projectDir(allocCString(`${dir}/project`))).toBe(allocCString(`${dir}/project`));
    }

    test("should fall back to the file's own folder outside a project") {
        const dir = root();

        expect(projectDir(allocCString(`${dir}/loose/main.hx`))).toBe(allocCString(`${dir}/loose`));
    }

    test("should give the current folder for a bare file name") {
        expect(projectDir("main.hx")).toBe(".");
    }
}

describe("runAction") {
    test("should run the file directly in a project without a build.hx") {
        const dir = root();
        const a = runAction(allocCString(`${dir}/project/src/main.hx`));

        expect(a.kind).toBe("run");
        expect(a.cwd).toBe(allocCString(`${dir}/project`));
        expect(a.argv.items.len).toBe(3);
        expect(a.argv.items[1]).toBe("run");
        expect(a.argv.items[2]).toBe(allocCString(`${dir}/project/src/main.hx`));
    }

    test("should run through build.hx when the project has one") {
        const dir = root();
        const a = runAction(allocCString(`${dir}/scripted/main.hx`));

        expect(a.argv.items.len).toBe(3);
        expect(a.argv.items[1]).toBe("build");
        expect(a.argv.items[2]).toBe("run");
        expect(a.file).toBe(allocCString(`${dir}/scripted/main.hx`));
    }
}

describe("debugAction") {
    test("should run debug-launch on the file from its project") {
        const dir = root();
        const a = debugAction(allocCString(`${dir}/project/src/main.hx`));

        expect(a.kind).toBe("debug");
        expect(a.title).toBe("Debug");
        expect(a.cwd).toBe(allocCString(`${dir}/project`));
        expect(a.argv.items[1]).toBe("debug-launch");
        expect(a.argv.items[2]).toBe(allocCString(`${dir}/project/src/main.hx`));
    }
}

describe("buildAction") {
    test("should build the whole project inside one") {
        const dir = root();
        const a = buildAction(allocCString(`${dir}/project/src/main.hx`));

        expect(a.kind).toBe("build");
        expect(a.file).toBe("");
        expect(a.argv.items.len).toBe(2);
        expect(a.argv.items[1]).toBe("build");
    }

    test("should build the file alone outside a project") {
        const dir = root();
        const a = buildAction(allocCString(`${dir}/loose/main.hx`));

        expect(a.argv.items.len).toBe(3);
        expect(a.argv.items[2]).toBe(allocCString(`${dir}/loose/main.hx`));
    }
}

describe("testAction") {
    test("should run every test of the file and end with --reporter") {
        const names: string[0] = [];
        const a = testAction("/p/a.spec.hx", &names, true);

        expect(a.title).toBe("▶ Run tests");
        expect(a.argv.items.len).toBe(4);
        expect(a.argv.items[1]).toBe("test");
        expect(a.argv.items[2]).toBe("/p/a.spec.hx");
        expect(a.argv.items[3]).toBe("--reporter");
        expect(a.name.items.len).toBe(0);
    }

    test("should match one test by its joined names, anchored at both ends") {
        const names: string[2] = ["parser", "should read"];
        const a = testAction("/p/a.spec.hx", &names, false);

        expect(a.title).toBe("▶ Run test");
        expect(a.argv.items[3]).toBe("-f");
        expect(a.argv.items[4]).toBe("^parser should read$");
        expect(a.name.items.len).toBe(2);
        expect(a.name.items[1]).toBe("should read");
    }

    test("should match a describe by its names followed by a space") {
        const names: string[1] = ["parser"];
        const a = testAction("/p/a.spec.hx", &names, true);

        expect(a.title).toBe("▶ Run tests");
        expect(a.argv.items[4]).toBe("^parser ");
    }

    test("should escape the regex characters in a name") {
        const names: string[1] = ["a.b(c)*"];
        const a = testAction("/p/a.spec.hx", &names, false);

        expect(a.argv.items[4]).toBe("^a\\.b\\(c\\)\\*$");
    }
}

describe("writeAction") {
    test("should write the action as a JSON object") {
        let argv = strings();
        add(&argv, "helix");
        add(&argv, "build");
        const a = Action { kind: "build", title: "Build", cwd: "/p", argv, file: "", name: strings() };

        expect(written(a)).toBe("{\"kind\":\"build\",\"title\":\"Build\",\"cwd\":\"/p\",\"argv\":[\"helix\",\"build\"]}");
    }

    test("should add the file and the names when the action has them") {
        let names = strings();
        add(&names, "parser");
        const a = Action { kind: "test", title: "T", cwd: "/p", argv: strings(), file: "/p/a.spec.hx", name: names };

        expect(written(a)).toBe("{\"kind\":\"test\",\"title\":\"T\",\"cwd\":\"/p\",\"argv\":[],\"file\":\"/p/a.spec.hx\",\"name\":[\"parser\"]}");
    }
}

describe("writeProjectActions") {
    test("should list build, run, and test for a project") {
        const dir = root();
        let b = buffer();
        writeProjectActions(&b, allocCString(`${dir}/project/src/main.hx`));
        const text = b.text();

        expect(text).toStartWith("[{\"kind\":\"build\"");
        expect(text).toInclude("{\"kind\":\"run\",\"title\":\"Run\"");
        expect(text).toInclude("\"build\",\"run\"]");
        expect(text).toInclude("{\"kind\":\"test\",\"title\":\"Test\"");
        expect(text).toEndWith(allocCString(`"--reporter"],"file":"${dir}/project"}]`));
    }

    test("should leave out run outside a project") {
        const dir = root();
        let b = buffer();
        writeProjectActions(&b, allocCString(`${dir}/loose/main.hx`));

        expect(b.text()).not.toInclude("\"kind\":\"run\"");
        expect(b.text()).toInclude("\"kind\":\"test\"");
    }
}

describe("cmdActions") {
    test("should fail without exactly one argument") {
        const args: string[0] = [];

        expect(cmdActions(&args)).toBe(1);
    }

    test("should fail for a path that cannot be read") {
        const args: string[1] = ["/nonexistent/helix-actions-spec/main.hx"];

        expect(cmdActions(&args)).toBe(1);
    }
}

describe("debugAdapter") {
    test("should prefer the adapter that HELIX_LLDB_DAP names") {
        void setenv(toCString("HELIX_LLDB_DAP"), toCString("/opt/custom/lldb-dap"), 1);

        expect(debugAdapter()).toBe("/opt/custom/lldb-dap");
    }
}

describe("cmdDebugLaunch") {
    test("should fail when the output folder cannot be created") {
        let options = defaultOptions();
        options.file = "/nonexistent/helix-actions-spec/main.hx";

        expect(cmdDebugLaunch(&options)).toBe(1);
    }
}
