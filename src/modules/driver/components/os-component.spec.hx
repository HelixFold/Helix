/**
 * Imports
 */

import { equal } from "std/text";
import * as sys from "@modules/driver/bindings/sys.binding";
import * as os from "@modules/driver/components/os.component";

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
 * Any folder left at the path by an earlier run is removed first, so each case starts empty.
 *
 * @since 1.0.0
 */

function scratch(name: string): string {
    const dir = os.allocCString(`${os.tempDir()}/helix-os-spec-${os.pid()}/${name}`);
    os.removeTree(dir);
    void os.makeDirs(dir);
    return dir;
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
    os.removeTree(os.allocCString(`${os.tempDir()}/helix-os-spec-${os.pid()}`));
}

/**
 * Sets an environment variable for this process.
 *
 * @param name - The name of the variable
 * @param value - The new value, which replaces any value set already
 *
 * @remarks
 * It calls `setenv` of C directly, so the functions under test see the change.
 *
 * @since 1.0.0
 */

function setVariable(name: string, value: string): void {
    void sys.setenv(os.toCString(name), os.toCString(value), 1);
}

/**
 * Removes an environment variable from this process.
 *
 * @param name - The name of the variable
 *
 * @remarks
 * It calls `unsetenv` of C directly, and removing a variable that is not set is not an error.
 *
 * @since 1.0.0
 */

function unsetVariable(name: string): void {
    void sys.unsetenv(os.toCString(name));
}

describe("allocCString") {
    test("should format the template and end it with a NUL") {
        const text = os.allocCString(`a${1 + 1}b`);

        expect(text).toBe("a2b");
        unsafe {
            expect(text.ptr[3]).toBe(0);
        }
    }
}

describe("toCString") {
    test("should copy only the slice and end the copy with a NUL") {
        const full = "abcdef";
        const copy = os.toCString(full[0..3]);

        expect(os.fromCString(copy)).toBe("abc");
    }
}

describe("asReadonly") {
    test("should keep the pointer it is given") {
        const message = os.asReadonly(sys.strerror(2));

        expect(os.fromCString(message)).toBe(os.strerror(2));
    }
}

describe("fromCString") {
    test("should read up to the NUL") {
        expect(os.fromCString(os.toCString("helix"))).toBe("helix");
    }

    test("should give an empty string for null") {
        expect(os.fromCString(null)).toBe("");
    }
}

describe("strings") {
    test("should start empty") {
        expect(os.strings().items.len).toBe(0);
    }
}

describe("add") {
    test("should append in order") {
        let list = os.strings();
        os.add(&list, "a");
        os.add(&list, "b");

        expect(list.items.len).toBe(2);
        expect(list.items[1]).toBe("b");
    }
}

describe("compare") {
    test("should order by the first differing byte") {
        expect(os.compare("abc", "abd")).toBe(-1);
        expect(os.compare("b", "abc")).toBe(1);
    }

    test("should put a prefix before the longer string") {
        expect(os.compare("ab", "abc")).toBe(-1);
        expect(os.compare("abc", "ab")).toBe(1);
    }

    test("should give 0 for equal strings") {
        expect(os.compare("same", "same")).toBe(0);
    }

    test("should put upper case before lower case") {
        expect(os.compare("Z", "a")).toBe(-1);
    }
}

describe("sort") {
    test("should sort in compare order") {
        let list = os.strings();
        os.add(&list, "b.hx");
        os.add(&list, "a.hx");
        os.add(&list, "B.hx");
        os.add(&list, "a");
        os.sort(list.items);

        expect(list.items[0]).toBe("B.hx");
        expect(list.items[1]).toBe("a");
        expect(list.items[2]).toBe("a.hx");
        expect(list.items[3]).toBe("b.hx");
    }

    test("should leave an empty list alone") {
        const list = os.strings();
        os.sort(list.items);

        expect(list.items.len).toBe(0);
    }
}

describe("lastIndex") {
    test("should find the last match") {
        expect(os.lastIndex("a/b/c", '/') ?? 99).toBe(3);
    }

    test("should give null when the byte is missing") {
        expect(os.lastIndex("abc", '/') == null).toBeTrue();
    }
}

describe("firstIndex") {
    test("should find the first match") {
        expect(os.firstIndex("a/b/c", '/') ?? 99).toBe(1);
    }

    test("should give null when the byte is missing") {
        expect(os.firstIndex("", '/') == null).toBeTrue();
    }
}

describe("baseName") {
    test("should keep what follows the last slash") {
        expect(os.baseName("src/modules/main.hx")).toBe("main.hx");
    }

    test("should keep a path without a slash whole") {
        expect(os.baseName("main.hx")).toBe("main.hx");
    }

    test("should give an empty string for a path that ends in a slash") {
        expect(os.baseName("src/")).toBe("");
    }
}

describe("fileStem") {
    test("should drop the folder and the last extension") {
        expect(os.fileStem("src/hello.hx")).toBe("hello");
        expect(os.fileStem("lib/a.tar.gz")).toBe("a.tar");
    }

    test("should keep a name that starts with its only dot") {
        expect(os.fileStem("dir/.env")).toBe(".env");
    }

    test("should keep a name without an extension") {
        expect(os.fileStem("bin/helix")).toBe("helix");
    }
}

describe("getenv") {
    test("should read a variable that is set, even to an empty value") {
        setVariable("HELIX_OS_SPEC", "");

        expect(os.getenv("HELIX_OS_SPEC") ?? "<null>").toBe("");
    }

    test("should give null for a variable that is not set") {
        unsetVariable("HELIX_OS_SPEC");

        expect(os.getenv("HELIX_OS_SPEC") == null).toBeTrue();
    }
}

describe("getenvSet") {
    test("should give null for an empty variable") {
        setVariable("HELIX_OS_SPEC", "");

        expect(os.getenvSet("HELIX_OS_SPEC") == null).toBeTrue();
    }

    test("should read a variable with a value") {
        setVariable("HELIX_OS_SPEC", "on");

        expect(os.getenvSet("HELIX_OS_SPEC") ?? "<null>").toBe("on");
        unsetVariable("HELIX_OS_SPEC");
    }
}

describe("errno") {
    test("should report why the last call failed") {
        const dir = scratch("errno");
        defer cleanUp();
        const ok = os.chdir(os.allocCString(`${dir}/missing`));

        expect(ok).toBeFalse();
        expect(os.strerror(os.errno())).toBe(os.strerror(2));
    }
}

describe("strerror") {
    test("should describe an error code") {
        expect(os.strerror(2)).toBe("No such file or directory");
    }
}

describe("pid") {
    test("should give a positive id") {
        expect(os.pid() > 0).toBeTrue();
    }
}

describe("stdoutFile") {
    test("should give the standard output") {
        expect(os.stdoutFile() != null).toBeTrue();
    }
}

describe("stderrFile") {
    test("should give the standard error") {
        expect(os.stderrFile() != null).toBeTrue();
    }
}

describe("cStdout") {
    test("should give the standard output as a typed file") {
        expect(os.cStdout() != null).toBeTrue();
    }
}

describe("flushStdout") {
    test("should flush without failing") {
        os.flushStdout();

        expect(true).toBeTrue();
    }
}

describe("useColor") {
    test("should turn color off when NO_COLOR has a value") {
        setVariable("NO_COLOR", "1");
        const color = os.useColor(1);
        unsetVariable("NO_COLOR");

        expect(color).toBeFalse();
    }
}

describe("tempDir") {
    test("should prefer TMPDIR") {
        const saved = os.allocCString(`${os.getenv("TMPDIR") ?? ""}`);
        setVariable("TMPDIR", "/var/spec-tmp");
        const dir = os.allocCString(`${os.tempDir()}`);
        setVariable("TMPDIR", saved);

        expect(dir).toBe("/var/spec-tmp");
    }
}

describe("slashes") {
    test("should turn every backslash into a slash") {
        expect(os.slashes("C:\\Users\\ada\\x.hx")).toBe("C:/Users/ada/x.hx");
    }

    test("should copy rather than change the original") {
        const original = "a\\b";
        const copy = os.slashes(original);

        expect(copy).toBe("a/b");
        expect(original).toBe("a\\b");
    }
}

describe("helixHome") {
    test("should use HELIX_HOME when it is set") {
        setVariable("HELIX_HOME", "/opt/hx");
        const home = os.helixHome("sdk");
        unsetVariable("HELIX_HOME");

        expect(home).toBe("/opt/hx/sdk");
    }

    test("should fall back to the cache in HOME") {
        unsetVariable("HELIX_HOME");
        const saved = os.allocCString(`${os.getenv("HOME") ?? ""}`);
        setVariable("HOME", "/home/ada");
        const home = os.helixHome("sdk");
        setVariable("HOME", saved);

        expect(home).toBe("/home/ada/.cache/helix/sdk");
    }
}

describe("cwd") {
    test("should give an absolute path") {
        const here = os.cwd() ?? "";

        expect(here.len > 0 && here[0] == '/').toBeTrue();
    }
}

describe("chdir") {
    test("should change the folder that cwd reports") {
        const dir = os.realPath(scratch("chdir")) ?? "";
        defer cleanUp();
        const before = os.allocCString(`${os.cwd() ?? "."}`);
        const changed = os.chdir(dir);
        const after = os.cwd() ?? "";
        void os.chdir(before);

        expect(changed).toBeTrue();
        expect(after).toBe(dir);
    }
}

describe("realPath") {
    test("should resolve dot parts to an absolute path") {
        const dir = scratch("realPath");
        defer cleanUp();
        const resolved = os.realPath(os.allocCString(`${dir}/./`)) ?? "";

        expect(equal(resolved, os.realPath(dir) ?? "x")).toBeTrue();
        expect(resolved[0]).toBe('/');
    }

    test("should give null for a path that does not exist") {
        const dir = scratch("realPathMissing");
        defer cleanUp();

        expect(os.realPath(os.allocCString(`${dir}/missing`)) == null).toBeTrue();
    }
}

describe("exists") {
    test("should find a folder and miss a missing file") {
        const dir = scratch("exists");
        defer cleanUp();

        expect(os.exists(dir)).toBeTrue();
        expect(os.exists(os.allocCString(`${dir}/missing`))).toBeFalse();
    }
}

describe("readable") {
    test("should accept a file that was just written") {
        const dir = scratch("readable");
        defer cleanUp();
        const file = os.allocCString(`${dir}/a.txt`);
        void os.writeText(file, "x");

        expect(os.readable(file)).toBeTrue();
        expect(os.readable(os.allocCString(`${dir}/b.txt`))).toBeFalse();
    }
}

describe("executable") {
    test("should tell a program from a plain file") {
        const dir = scratch("executable");
        defer cleanUp();
        const file = os.allocCString(`${dir}/a.txt`);
        void os.writeText(file, "x");

        expect(os.executable("/bin/sh")).toBeTrue();
        expect(os.executable(file)).toBeFalse();
    }
}

describe("stat") {
    test("should describe a file and a folder") {
        const dir = scratch("stat");
        defer cleanUp();
        const file = os.allocCString(`${dir}/a.txt`);
        void os.writeText(file, "x");

        expect(os.isFile(os.stat(file, false)!.mode)).toBeTrue();
        expect(os.isDir(os.stat(dir, false)!.mode)).toBeTrue();
        expect(os.stat(file, false)!.mtime > 0).toBeTrue();
    }

    test("should describe a link itself only when asked") {
        const dir = scratch("statLink");
        defer cleanUp();
        const link = os.allocCString(`${dir}/link`);
        void sys.symlink(os.toCString(dir), os.toCString(link));

        expect(os.isLink(os.stat(link, true)!.mode)).toBeTrue();
        expect(os.isDir(os.stat(link, false)!.mode)).toBeTrue();
    }

    test("should give null for a path that does not exist") {
        expect(os.stat("/no/such/helix/path", false) == null).toBeTrue();
    }
}

describe("isDir") {
    test("should accept only the folder type") {
        expect(os.isDir(0o040755)).toBeTrue();
        expect(os.isDir(0o100644)).toBeFalse();
    }
}

describe("isFile") {
    test("should accept only the regular file type") {
        expect(os.isFile(0o100644)).toBeTrue();
        expect(os.isFile(0o120777)).toBeFalse();
    }
}

describe("isLink") {
    test("should accept only the link type") {
        expect(os.isLink(0o120777)).toBeTrue();
        expect(os.isLink(0o040755)).toBeFalse();
    }
}

describe("isDirectory") {
    test("should accept a folder and reject a file or a missing path") {
        const dir = scratch("isDirectory");
        defer cleanUp();
        const file = os.allocCString(`${dir}/a.txt`);
        void os.writeText(file, "x");

        expect(os.isDirectory(dir)).toBeTrue();
        expect(os.isDirectory(file)).toBeFalse();
        expect(os.isDirectory(os.allocCString(`${dir}/missing`))).toBeFalse();
    }
}

describe("listDir") {
    test("should list the names without dot and dot-dot") {
        const dir = scratch("listDir");
        defer cleanUp();
        void os.writeText(os.allocCString(`${dir}/b.hx`), "");
        void os.writeText(os.allocCString(`${dir}/a.hx`), "");
        void os.makeDir(os.allocCString(`${dir}/sub`));
        const names = os.listDir(dir) ?? os.strings();
        os.sort(names.items);

        expect(names.items.len).toBe(3);
        expect(names.items[0]).toBe("a.hx");
        expect(names.items[1]).toBe("b.hx");
        expect(names.items[2]).toBe("sub");
    }

    test("should give null for a folder that cannot be read") {
        expect(os.listDir("/no/such/helix/path") == null).toBeTrue();
    }
}

describe("makeDirs") {
    test("should create every missing folder on the way") {
        const dir = scratch("makeDirs");
        defer cleanUp();
        const deep = os.allocCString(`${dir}/a/b/c`);

        expect(os.makeDirs(deep)).toBeTrue();
        expect(os.isDirectory(deep)).toBeTrue();
    }

    test("should succeed for a folder that already exists") {
        const dir = scratch("makeDirsAgain");
        defer cleanUp();

        expect(os.makeDirs(dir)).toBeTrue();
    }
}

describe("makeDir") {
    test("should create a folder once and fail the second time") {
        const dir = scratch("makeDir");
        defer cleanUp();
        const sub = os.allocCString(`${dir}/out`);

        expect(os.makeDir(sub)).toBeTrue();
        expect(os.makeDir(sub)).toBeFalse();
    }

    test("should fail when the parent is missing") {
        const dir = scratch("makeDirParent");
        defer cleanUp();

        expect(os.makeDir(os.allocCString(`${dir}/a/b`))).toBeFalse();
    }
}

describe("removeTree") {
    test("should remove a folder with everything in it") {
        const dir = scratch("removeTree");
        defer cleanUp();
        const tree = os.allocCString(`${dir}/tree`);
        void os.makeDirs(os.allocCString(`${tree}/a/b`));
        void os.writeText(os.allocCString(`${tree}/a/b/c.txt`), "x");
        os.removeTree(tree);

        expect(os.exists(tree)).toBeFalse();
    }

    test("should remove a link and keep what it points at") {
        const dir = scratch("removeTreeLink");
        defer cleanUp();
        const target = os.allocCString(`${dir}/target`);
        const link = os.allocCString(`${dir}/link`);
        void os.makeDir(target);
        void os.writeText(os.allocCString(`${target}/keep.txt`), "x");
        void sys.symlink(os.toCString(target), os.toCString(link));
        os.removeTree(link);

        expect(os.stat(link, true) == null).toBeTrue();
        expect(os.readable(os.allocCString(`${target}/keep.txt`))).toBeTrue();
    }
}

describe("unlink") {
    test("should remove a file") {
        const dir = scratch("unlink");
        defer cleanUp();
        const file = os.allocCString(`${dir}/a.o`);
        void os.writeText(file, "x");
        os.unlink(file);

        expect(os.exists(file)).toBeFalse();
    }
}

describe("rename") {
    test("should move a file over an existing one") {
        const dir = scratch("rename");
        defer cleanUp();
        const from = os.allocCString(`${dir}/out.tmp`);
        const to = os.allocCString(`${dir}/out`);
        void os.writeText(from, "new");
        void os.writeText(to, "old");

        expect(os.rename(from, to)).toBeTrue();
        expect(os.exists(from)).toBeFalse();
        expect(os.readText(to) ?? "").toBe("new");
    }

    test("should fail for a missing file") {
        const dir = scratch("renameMissing");
        defer cleanUp();

        expect(os.rename(os.allocCString(`${dir}/a`), os.allocCString(`${dir}/b`))).toBeFalse();
    }
}

describe("readText") {
    test("should read the whole file and end it with a NUL") {
        const dir = scratch("readText");
        defer cleanUp();
        const file = os.allocCString(`${dir}/a.txt`);
        void os.writeText(file, "line 1\nline 2\n");
        const text = os.readText(file) ?? "<null>";

        expect(text).toBe("line 1\nline 2\n");
        unsafe {
            expect(text.ptr[text.len]).toBe(0);
        }
    }

    test("should read an empty file as an empty string") {
        const dir = scratch("readTextEmpty");
        defer cleanUp();
        const file = os.allocCString(`${dir}/empty`);
        void os.writeText(file, "");

        expect(os.readText(file) ?? "<null>").toBe("");
    }

    test("should give null for a missing file") {
        expect(os.readText("/no/such/helix/file") == null).toBeTrue();
    }
}

describe("writeText") {
    test("should replace what the file held") {
        const dir = scratch("writeText");
        defer cleanUp();
        const file = os.allocCString(`${dir}/a.txt`);
        void os.writeText(file, "a longer first text");

        expect(os.writeText(file, "short")).toBeTrue();
        expect(os.readText(file) ?? "").toBe("short");
    }

    test("should fail when the folder is missing") {
        const dir = scratch("writeTextMissing");
        defer cleanUp();

        expect(os.writeText(os.allocCString(`${dir}/no/a.txt`), "x")).toBeFalse();
    }
}

describe("copyFile") {
    test("should copy the bytes") {
        const dir = scratch("copyFile");
        defer cleanUp();
        const from = os.allocCString(`${dir}/a`);
        const to = os.allocCString(`${dir}/b`);
        void os.writeText(from, "payload");

        expect(os.copyFile(from, to, false)).toBeTrue();
        expect(os.readText(to) ?? "").toBe("payload");
    }

    test("should copy the permissions only when asked") {
        const dir = scratch("copyFileMode");
        defer cleanUp();
        const from = os.allocCString(`${dir}/tool`);
        const kept = os.allocCString(`${dir}/kept`);
        const plain = os.allocCString(`${dir}/plain`);
        void os.writeText(from, "#!/bin/sh\n");
        void sys.chmod(os.toCString(from), 0o755);
        void os.copyFile(from, kept, true);
        void os.copyFile(from, plain, false);

        expect(os.executable(kept)).toBeTrue();
        expect(os.executable(plain)).toBeFalse();
    }

    test("should fail for a missing file") {
        const dir = scratch("copyFileMissing");
        defer cleanUp();

        expect(os.copyFile(os.allocCString(`${dir}/a`), os.allocCString(`${dir}/b`), false)).toBeFalse();
    }
}

describe("cArgs") {
    test("should copy each argument and end the array with null") {
        const argv = os.cArgs([ "cc", "-c" ]);

        unsafe {
            expect(os.fromCString(os.asReadonly(argv[0]))).toBe("cc");
            expect(os.fromCString(os.asReadonly(argv[1]))).toBe("-c");
            expect(argv[2] == null).toBeTrue();
        }
    }
}

describe("spawn") {
    test("should start a program found in PATH") {
        const child = os.spawn([ "true" ], false, null);

        expect(child != null).toBeTrue();
        expect(os.waitFor(child ?? -1)).toBe(0);
    }

    test("should send the standard output to a file") {
        const dir = scratch("spawn");
        defer cleanUp();
        const out = os.allocCString(`${dir}/out.txt`);
        const child = os.spawn([ "echo", "hello" ], false, out);
        void os.waitFor(child ?? -1);

        expect(os.readText(out) ?? "").toBe("hello\n");
    }
}

describe("waitFor") {
    test("should give the exit code of the program") {
        const child = os.spawn([ "sh", "-c", "exit 3" ], false, null);

        expect(os.waitFor(child ?? -1)).toBe(3);
    }

    test("should give 128 plus the signal that killed the program") {
        const child = os.spawn([ "sh", "-c", "kill -9 $$" ], false, null);

        expect(os.waitFor(child ?? -1)).toBe(137);
    }
}

describe("waitAny") {
    test("should give the child that ended with its exit code") {
        const child = os.spawn([ "sh", "-c", "exit 4" ], false, null) ?? -1;
        let code: i64 = 0;
        const ended = os.waitAny(&code);

        expect(ended ?? -2).toBe(child);
        expect(code).toBe(4);
    }

    test("should give null when no child is running") {
        let code: i64 = 0;

        expect(os.waitAny(&code) == null).toBeTrue();
    }
}

describe("run") {
    test("should give the exit code of the program") {
        expect(os.run([ "true" ])).toBe(0);
        expect(os.run([ "false" ])).toBe(1);
    }

    test("should give -1 for a program that cannot start") {
        expect(os.run([ "helix-os-spec-no-such-program" ])).toBe(-1);
    }
}

describe("cpuCount") {
    test("should count at least one processor") {
        expect(os.cpuCount() >= 1).toBeTrue();
    }
}

describe("secondsNow") {
    test("should never go backward") {
        const first = os.secondsNow();
        const second = os.secondsNow();

        expect(second >= first).toBeTrue();
    }
}

describe("matches") {
    test("should match the shell wildcards") {
        expect(os.matches("*.spec.hx", "os-component.spec.hx")).toBeTrue();
        expect(os.matches("a?c", "abc")).toBeTrue();
        expect(os.matches("[ab].hx", "b.hx")).toBeTrue();
    }

    test("should require the whole name to match") {
        expect(os.matches("*.hx", "main.hx.bak")).toBeFalse();
        expect(os.matches("[ab].hx", "c.hx")).toBeFalse();
    }
}

describe("compilerPath") {
    test("should give the absolute path of the running executable") {
        const path = os.compilerPath() ?? "";

        expect(path.len > 0 && path[0] == '/').toBeTrue();
        expect(os.executable(path)).toBeTrue();
    }
}

describe("besideCompiler") {
    test("should find the executable itself by its name") {
        const path = os.compilerPath() ?? "";
        const found = os.besideCompiler(os.baseName(path)) ?? "<null>";

        expect(found).toBe(path);
    }

    test("should give null for a file that is not there") {
        expect(os.besideCompiler("helix-os-spec-missing") == null).toBeTrue();
    }
}
