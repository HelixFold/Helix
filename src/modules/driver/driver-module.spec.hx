/**
 * Imports
 */

import { run } from "@modules/driver/driver.module";
import { allocCString, makeDirs, removeTree, writeText, tempDir, pid } from "@modules/driver/components/os.component";

/**
 * Tests
 */

/**
 * A new, empty folder under the temporary folder, named after the process and a case name.
 *
 * @param name - The name of the case, which ends the folder name
 * @returns The path of the folder
 *
 * @remarks
 * Any folder left at the path by an earlier run is removed first, so each case starts empty.
 *
 * @since 1.0.0
 */

function scratch(name: string): string {
    const dir = allocCString(`${tempDir()}/helix-driver-spec-${pid()}-${name}`);
    removeTree(dir);
    void makeDirs(dir);
    return dir;
}

/**
 * Writes a file into a folder and returns its path.
 *
 * @param dir - The folder to write into
 * @param name - The file name inside the folder
 * @param text - The contents of the file
 * @returns The path of the file
 *
 * @remarks
 * The folder must exist already, and a failed write is ignored.
 *
 * @since 1.0.0
 */

function put(dir: string, name: string, text: string): string {
    const path = allocCString(`${dir}/${name}`);
    void writeText(path, text);
    return path;
}

describe("run") {
    describe("the commands it answers itself") {
        test("should fail without a command") {
            expect(run([])).toBe(1);
        }

        test("should succeed for help in each of its spellings") {
            expect(run(["help"])).toBe(0);
            expect(run(["--help"])).toBe(0);
            expect(run(["-h"])).toBe(0);
        }

        test("should succeed for version in each of its spellings") {
            expect(run(["version"])).toBe(0);
            expect(run(["--version"])).toBe(0);
        }

        test("should fail for an unknown command") {
            expect(run(["frobnicate"])).toBe(1);
        }

        test("should fail for a command that moved to hpm") {
            expect(run(["add", "json"])).toBe(1);
            expect(run(["init"])).toBe(1);
        }
    }

    describe("the options of a compiling command") {
        test("should fail without an input file") {
            expect(run(["check"])).toBe(1);
        }

        test("should fail for an unknown option") {
            expect(run(["check", "--bogus", "a.hx"])).toBe(1);
        }

        test("should fail for a second input file") {
            expect(run(["check", "a.hx", "b.hx"])).toBe(1);
        }

        test("should fail for an unknown mode") {
            expect(run(["check", "--mode", "fastest", "a.hx"])).toBe(1);
        }

        test("should fail for an emit kind other than obj") {
            expect(run(["check", "--emit", "exe", "a.hx"])).toBe(1);
        }
    }

    describe("tokens") {
        test("should succeed for a file that lexes") {
            const dir = scratch("tokens");
            const file = put(dir, "a.hx", "/** Doc. */\nconst x = 1;\n");
            const args: string[2] = ["tokens", file];

            expect(run(&args)).toBe(0);
            removeTree(dir);
        }

        test("should fail for a file that cannot be read") {
            const dir = scratch("tokens-missing");
            const args: string[2] = ["tokens", allocCString(`${dir}/missing.hx`)];

            expect(run(&args)).toBe(1);
            removeTree(dir);
        }
    }

    describe("ast") {
        test("should succeed for a file that parses") {
            const dir = scratch("ast");
            const file = put(dir, "a.hx", "function f(): i32 { return 1; }\n");
            const args: string[2] = ["ast", file];

            expect(run(&args)).toBe(0);
            removeTree(dir);
        }

        test("should fail for a file with a syntax error") {
            const dir = scratch("ast-error");
            const file = put(dir, "a.hx", "function f(: i32 {\n");
            const args: string[2] = ["ast", file];

            expect(run(&args)).toBe(1);
            removeTree(dir);
        }
    }

    describe("test") {
        test("should fail for a path that does not exist") {
            const dir = scratch("test-missing");
            const args: string[2] = ["test", allocCString(`${dir}/nothing`)];

            expect(run(&args)).toBe(1);
            removeTree(dir);
        }

        test("should fail for a folder without tests") {
            const dir = scratch("test-empty");
            void put(dir, "plain.hx", "function f(): void {}\n");
            void put(dir, "notes.txt", "describe(\"x\") {}\n");
            const args: string[2] = ["test", dir];

            expect(run(&args)).toBe(1);
            removeTree(dir);
        }

        test("should fail when the -s pattern keeps none of the specs it found") {
            const dir = scratch("test-glob");
            void put(dir, "a.spec.hx", "describe(\"a\") {}\n");
            void put(dir, "b.hx", "test(\"b\") {}\n");
            const args: string[4] = ["test", dir, "-s", "*nothing*"];

            expect(run(&args)).toBe(1);
            removeTree(dir);
        }

        test("should fail for an unknown reporter") {
            expect(run(["test", "--reporter", "xml"])).toBe(1);
        }

        test("should fail for an unknown option") {
            expect(run(["test", "--bogus"])).toBe(1);
        }

        test("should fail for an unknown mode") {
            expect(run(["test", "--mode", "fastest"])).toBe(1);
        }

        test("should fail when more than twelve options go to the test binary") {
            expect(run(["test", "-f", "a", "-f", "b", "-f", "c", "-t", "1", "-t", "2", "-v", "-v", "-b"])).toBe(1);
        }
    }

    describe("translate-c") {
        test("should fail without a header") {
            expect(run(["translate-c", "-o", "out.hx"])).toBe(1);
        }

        test("should fail for a second header") {
            expect(run(["translate-c", "a.h", "b.h"])).toBe(1);
        }
    }
}
