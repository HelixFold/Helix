/**
 * Imports
 */

import * as os from "@modules/driver/components/os.component";
import { movedToHpm, cmdProjectBuild } from "@modules/driver/components/project.component";

/**
 * Tests
 */

/**
 * A new empty folder under the temporary folder, unique to this process and the given name.
 *
 * @param name - The name of the case, which ends the folder name
 * @returns The path of the folder
 *
 * @remarks
 * The temporary folder goes through {@link realPath} first,
 * so the path has no links in it even where the temporary folder is a link.
 *
 * @since 1.0.0
 */

function scratch(name: string): string {
    const dir = os.realPath(os.tempDir()) ?? os.tempDir();
    const path = os.allocCString(`${dir}/helix-project-spec-${os.pid()}/${name}`);
    os.removeTree(path);
    void os.makeDirs(path);
    return path;
}

/**
 * Removes every folder that {@link scratch} made.
 *
 * @remarks
 * Every folder from {@link scratch} lives under one folder named after the process, so removing it removes them all.
 *
 * @since 1.0.0
 */

function cleanUp(): void {
    const dir = os.realPath(os.tempDir()) ?? os.tempDir();
    os.removeTree(os.allocCString(`${dir}/helix-project-spec-${os.pid()}`));
}

/**
 * Runs `helix build` with no arguments from a folder, then goes back to the folder it started from.
 *
 * @param dir - The folder to build from
 * @returns The exit status of `helix build`
 *
 * @remarks
 * The build looks for `build.hx` or `helix.jsonc` from the current folder upward, so the case must change the folder.
 * Going back keeps the change from leaking into the next case.
 *
 * @since 1.0.0
 */

function buildFrom(dir: string): u8 {
    const before = os.allocCString(`${os.cwd() ?? "."}`);
    void os.chdir(dir);
    const status = cmdProjectBuild([]);
    void os.chdir(before);
    return status;
}

describe("movedToHpm") {
    test("should report a command that moved to hpm") {
        expect(movedToHpm("add", [ "tls" ]) ?? 0).toBe(1);
        expect(movedToHpm("package", []) ?? 0).toBe(1);
    }

    test("should give null for a command that is still the compiler's") {
        expect(movedToHpm("build", []) == null).toBeTrue();
        expect(movedToHpm("pack", []) == null).toBeTrue();
    }
}

describe("cmdProjectBuild") {
    test("should fail when no folder above has a build.hx or a helix.jsonc") {
        const dir = scratch("empty");
        defer cleanUp();

        expect(buildFrom(dir)).toBe(1);
    }

    test("should find the project in a folder above and list its programs for the runner") {
        const root = scratch("app");
        defer cleanUp();
        void os.writeText(os.allocCString(`${root}/helix.jsonc`), "{ \"bin\": { \"app\": \"src/main.hx\" } }");
        const nested = os.allocCString(`${root}/src/deep`);
        void os.makeDirs(nested);
        const status = buildFrom(nested);

        expect(status).toBe(1);
        expect(os.readText(os.allocCString(`${root}/.helix-cache/packages.txt`)) ?? "").toBe("bin\t-\tapp\tsrc/main.hx\n");
    }
}
