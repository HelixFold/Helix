/**
 * Imports
 */

import * as fmt from "./fmt";
import { equal } from "./text";
import { Env } from "./process";
import { ArenaAllocator, cAllocator, free } from "./heap";
import { deleteFile, makePath, copyFile, stat, linkStat } from "./fs";
import { exists, rename, deleteTree, makeLink, readLink, File, FsError, Kind, Dir, readFile, writeFile } from "./fs";

/**
 * Tests
 */

/**
 * The arena that every path a test builds comes from.
 *
 * @remarks
 * `beforeEach` creates it and `afterEach` frees it, so the paths never count as leaks of `testing.allocator`.
 *
 * @since 1.0.0
 */

let paths: ArenaAllocator = undefined;

/**
 * Returns the folder that the specs work in, under `$TMPDIR`.
 *
 * @returns The path of the folder
 *
 * @remarks
 * It falls back to `/tmp` when `TMPDIR` is not set.
 * The folder is the same for every test, and `afterEach` deletes it.
 *
 * @since 1.0.0
 */

function root(): string {
    const env = Env {};
    const tmp = env.get("TMPDIR") ?? "/tmp";
    return fmt.alloc(paths.allocator(), `${tmp}/helix-fs-spec`) catch unreachable;
}

/**
 * Returns the path of `name` inside the spec folder.
 *
 * @param name - The name, or a relative path, inside the folder
 * @returns The full path
 *
 * @remarks
 * The path comes from the arena, so a test never frees it.
 *
 * @since 1.0.0
 */

function at(name: string): string {
    return fmt.alloc(paths.allocator(), `${root()}/${name}`) catch unreachable;
}

/**
 * Reads the file at `path` as a string for comparison.
 *
 * @param path - The file to read
 * @returns The contents, or an empty string when the file cannot be read
 *
 * @remarks
 * The bytes come from the arena, so a test never frees them.
 *
 * @since 1.0.0
 */

function contents(path: string): string {
    const empty: u8[] = [];
    return readFile(paths.allocator(), path) catch empty;
}

/**
 * Starts a test with an empty spec folder and a fresh arena for paths.
 *
 * @remarks
 * Every top-level `describe` runs it in `beforeEach`.
 * It deletes any folder that an earlier, aborted run left behind before it creates a new one.
 *
 * @since 1.0.0
 */

function begin(): void {
    paths = ArenaAllocator.init(cAllocator());
    deleteTree(root()) catch {};
    makePath(root()) catch {};
}

/**
 * Ends a test by deleting the spec folder and freeing the paths.
 *
 * @remarks
 * Every top-level `describe` runs it in `afterEach`, so no test leaves files behind.
 *
 * @since 1.0.0
 */

function end(): void {
    deleteTree(root()) catch {};
    paths.deinit();
}

describe("FsError") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should report NotFound for a missing file") {
        expect(File.open(at("missing.txt"))).toThrow(FsError.NotFound);
    }

    test("should report AlreadyExists for a path that is taken") {
        try writeFile(at("taken.txt"), "x");

        expect(File.createNew(at("taken.txt"))).toThrow(FsError.AlreadyExists);
    }
}

describe("File") {
    beforeEach { begin(); }
    afterEach { end(); }

    describe("open") {
        test("should open an existing file for reading") {
            try writeFile(at("a.txt"), "abc");
            let file = try File.open(at("a.txt"));
            defer file.close();
            let buf: u8[8] = undefined;

            expect(try file.read(&buf)).toBe(3);
        }

        test("should throw NotFound for a missing file") {
            expect(File.open(at("missing.txt"))).toThrow(FsError.NotFound);
        }

        test("should throw IsDirectory for a folder") {
            expect(File.open(root())).toThrow(FsError.IsDirectory);
        }
    }

    describe("create") {
        test("should create a missing file") {
            let file = try File.create(at("new.txt"));
            file.close();

            expect(exists(at("new.txt"))).toBe(true);
        }

        test("should empty an existing file") {
            try writeFile(at("a.txt"), "old contents");
            let file = try File.create(at("a.txt"));
            file.close();

            expect(contents(at("a.txt"))).toBe("");
        }
    }

    describe("append") {
        test("should write after what the file holds") {
            try writeFile(at("log.txt"), "one\n");
            let file = try File.append(at("log.txt"));
            try file.write("two\n");
            file.close();

            expect(contents(at("log.txt"))).toBe("one\ntwo\n");
        }

        test("should create a missing file") {
            let file = try File.append(at("log.txt"));
            try file.write("x");
            file.close();

            expect(contents(at("log.txt"))).toBe("x");
        }
    }

    describe("createNew") {
        test("should create a file that does not exist yet") {
            let file = try File.createNew(at("lock"));
            try file.write("1");
            file.close();

            expect(contents(at("lock"))).toBe("1");
        }

        test("should throw AlreadyExists when the file exists") {
            try writeFile(at("lock"), "");

            expect(File.createNew(at("lock"))).toThrow(FsError.AlreadyExists);
        }
    }

    describe("stdin") {
        test("should wrap file descriptor 0") {
            expect(File.stdin().fd).toBe(0);
        }
    }

    describe("at") {
        test("should wrap the given file descriptor") {
            expect(File.at(5).fd).toBe(5);
        }
    }

    describe("close") {
        test("should set the file descriptor to -1") {
            try writeFile(at("a.txt"), "");
            let file = try File.open(at("a.txt"));
            file.close();

            expect(file.fd).toBe(-1);
        }
    }

    describe("read") {
        test("should read the bytes and then 0 at the end of the file") {
            try writeFile(at("a.txt"), "hello");
            let file = try File.open(at("a.txt"));
            defer file.close();
            let buf: u8[16] = undefined;
            const n = try file.read(&buf);
            const text: string = buf[0..n];

            expect(text).toBe("hello");
            expect(try file.read(&buf)).toBe(0);
        }

        test("should read no more than the buffer holds") {
            try writeFile(at("a.txt"), "hello");
            let file = try File.open(at("a.txt"));
            defer file.close();
            let buf: u8[2] = undefined;

            expect(try file.read(&buf)).toBe(2);
        }
    }

    describe("write") {
        test("should write all of the bytes") {
            let file = try File.create(at("out.txt"));
            try file.write("abc");
            try file.write("def");
            file.close();

            expect(contents(at("out.txt"))).toBe("abcdef");
        }
    }

    describe("readAll") {
        test("should read the rest of the file") {
            try writeFile(at("a.txt"), "header body");
            let file = try File.open(at("a.txt"));
            defer file.close();
            let buf: u8[7] = undefined;
            void try file.read(&buf);
            const bytes = try file.readAll(testing.allocator);
            defer free(testing.allocator, bytes);
            const text: string = bytes;

            expect(text).toBe("body");
        }

        test("should read a file bigger than the first buffer") {
            let b = fmt.Builder.init(testing.allocator);
            defer b.deinit();
            for (const _ of 0..1000) try b.append("0123456789");
            try writeFile(at("big.txt"), b.text());
            let file = try File.open(at("big.txt"));
            defer file.close();
            const bytes = try file.readAll(testing.allocator);
            defer free(testing.allocator, bytes);

            expect(bytes.len).toBe(10000);
            expect(bytes[9999]).toBe('9');
        }

        test("should return an empty slice for an empty file") {
            try writeFile(at("empty.txt"), "");
            let file = try File.open(at("empty.txt"));
            defer file.close();
            const bytes = try file.readAll(testing.allocator);

            expect(bytes.len).toBe(0);
        }
    }
}

describe("readFile") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should return the whole file") {
        try writeFile(at("notes.txt"), "line 1\nline 2\n");
        const bytes = try readFile(testing.allocator, at("notes.txt"));
        defer free(testing.allocator, bytes);
        const text: string = bytes;

        expect(text).toBe("line 1\nline 2\n");
    }

    test("should throw NotFound for a missing file") {
        expect(readFile(testing.allocator, at("missing.txt"))).toThrow(FsError.NotFound);
    }
}

describe("writeFile") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should create a file with the bytes") {
        try writeFile(at("out.txt"), "done");

        expect(contents(at("out.txt"))).toBe("done");
    }

    test("should replace what the file held") {
        try writeFile(at("out.txt"), "a longer first text");
        try writeFile(at("out.txt"), "short");

        expect(contents(at("out.txt"))).toBe("short");
    }

    test("should throw NotFound when the folder is missing") {
        expect(writeFile(at("no/such/out.txt"), "x")).toThrow(FsError.NotFound);
    }
}

describe("deleteFile") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should delete the file") {
        try writeFile(at("a.txt"), "x");
        try deleteFile(at("a.txt"));

        expect(exists(at("a.txt"))).toBe(false);
    }

    test("should throw NotFound for a missing file") {
        expect(deleteFile(at("missing.txt"))).toThrow(FsError.NotFound);
    }

    test("should delete a link and leave its target") {
        try writeFile(at("target.txt"), "x");
        try makeLink("target.txt", at("link"));
        try deleteFile(at("link"));

        expect(exists(at("link"))).toBe(false);
        expect(exists(at("target.txt"))).toBe(true);
    }
}

describe("makePath") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should create every missing folder in the path") {
        try makePath(at("a/b/c"));

        expect((try stat(at("a/b/c"))).kind).toBe(Kind.Directory);
    }

    test("should accept a folder that already exists") {
        try makePath(at("a"));
        try makePath(at("a"));

        expect(exists(at("a"))).toBe(true);
    }

    test("should throw NotFound when a file sits where a folder belongs") {
        try writeFile(at("a"), "");

        expect(makePath(at("a/b"))).toThrow(FsError.NotFound);
    }
}

describe("copyFile") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should copy the contents") {
        try writeFile(at("from.txt"), "copy me");
        try copyFile(at("from.txt"), at("to.txt"));

        expect(contents(at("to.txt"))).toBe("copy me");
    }

    test("should replace a file at the destination") {
        try writeFile(at("from.txt"), "new");
        try writeFile(at("to.txt"), "old and longer");
        try copyFile(at("from.txt"), at("to.txt"));

        expect(contents(at("to.txt"))).toBe("new");
    }

    test("should keep the permission bits") {
        try writeFile(at("from.txt"), "x");
        try copyFile(at("from.txt"), at("to.txt"));

        expect((try stat(at("to.txt"))).mode).toBe((try stat(at("from.txt"))).mode);
    }

    test("should throw NotFound for a missing source") {
        expect(copyFile(at("missing.txt"), at("to.txt"))).toThrow(FsError.NotFound);
    }
}

describe("Kind") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should tell a file, a folder, a link, and a device apart") {
        try writeFile(at("a.txt"), "");
        try makeLink("a.txt", at("link"));

        expect((try stat(at("a.txt"))).kind).toBe(Kind.File);
        expect((try stat(root())).kind).toBe(Kind.Directory);
        expect((try linkStat(at("link"))).kind).toBe(Kind.Link);
        expect((try stat("/dev/null")).kind).toBe(Kind.Other);
    }
}

describe("Stat") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should hold the size, the modification time, and the permission bits") {
        try writeFile(at("a.txt"), "12345");
        const info = try stat(at("a.txt"));

        expect(info.size).toBe(5);
        expect(info.mtime > 0).toBe(true);
        expect(info.mode & 0o600).toBe(0o600);
        expect(info.mode & 0o170000).toBe(0);
    }
}

describe("stat") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should follow a link to what it points at") {
        try writeFile(at("a.txt"), "abc");
        try makeLink("a.txt", at("link"));
        const info = try stat(at("link"));

        expect(info.kind).toBe(Kind.File);
        expect(info.size).toBe(3);
    }

    test("should throw NotFound for a broken link") {
        try makeLink("missing.txt", at("link"));

        expect(stat(at("link"))).toThrow(FsError.NotFound);
    }
}

describe("linkStat") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should report a link itself with the length of its target") {
        try writeFile(at("a.txt"), "abc");
        try makeLink("a.txt", at("link"));
        const info = try linkStat(at("link"));

        expect(info.kind).toBe(Kind.Link);
        expect(info.size).toBe(5);
    }

    test("should report a file the same as stat") {
        try writeFile(at("a.txt"), "abc");

        expect((try linkStat(at("a.txt"))).kind).toBe(Kind.File);
    }
}

describe("exists") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should return true for a file and a folder") {
        try writeFile(at("a.txt"), "");

        expect(exists(at("a.txt"))).toBe(true);
        expect(exists(root())).toBe(true);
    }

    test("should return false for a missing path") {
        expect(exists(at("missing.txt"))).toBe(false);
    }

    test("should return true for a broken link") {
        try makeLink("missing.txt", at("link"));

        expect(exists(at("link"))).toBe(true);
    }
}

describe("Dir") {
    beforeEach { begin(); }
    afterEach { end(); }

    describe("open") {
        test("should open a folder") {
            let dir = try Dir.open(root());
            defer dir.close();

            expect(dir.handle != 0).toBe(true);
        }

        test("should throw NotFound for a missing folder") {
            expect(Dir.open(at("missing"))).toThrow(FsError.NotFound);
        }

        test("should throw NotFound for a file") {
            try writeFile(at("a.txt"), "");

            expect(Dir.open(at("a.txt"))).toThrow(FsError.NotFound);
        }
    }

    describe("close") {
        test("should set the handle to 0 and do nothing the second time") {
            let dir = try Dir.open(root());
            dir.close();
            dir.close();

            expect(dir.handle).toBe(0);
        }
    }

    describe("next") {
        test("should list every name without the dot entries") {
            try writeFile(at("a.txt"), "");
            try makePath(at("sub"));
            let dir = try Dir.open(root());
            defer dir.close();
            let found: usize = 0;
            let others: usize = 0;
            while (const name = try dir.next()) {
                if (equal(name, "a.txt") || equal(name, "sub")) found += 1;
                else others += 1;
            }

            expect(found).toBe(2);
            expect(others).toBe(0);
        }

        test("should return null for an empty folder") {
            let dir = try Dir.open(root());
            defer dir.close();

            expect(try dir.next()).toBeNull();
        }
    }
}

describe("rename") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should move a file to the new path") {
        try writeFile(at("a.txt"), "x");
        try rename(at("a.txt"), at("b.txt"));

        expect(exists(at("a.txt"))).toBe(false);
        expect(contents(at("b.txt"))).toBe("x");
    }

    test("should replace a file at the new path") {
        try writeFile(at("a.txt"), "new");
        try writeFile(at("b.txt"), "old");
        try rename(at("a.txt"), at("b.txt"));

        expect(contents(at("b.txt"))).toBe("new");
    }

    test("should move a folder with what it holds") {
        try makePath(at("from/inner"));
        try rename(at("from"), at("to"));

        expect(exists(at("to/inner"))).toBe(true);
    }

    test("should throw NotFound for a missing source") {
        expect(rename(at("missing.txt"), at("b.txt"))).toThrow(FsError.NotFound);
    }
}

describe("deleteTree") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should delete a folder and everything in it") {
        try makePath(at("tree/a/b"));
        try writeFile(at("tree/a/b/file.txt"), "x");
        try deleteTree(at("tree"));

        expect(exists(at("tree"))).toBe(false);
    }

    test("should delete a single file") {
        try writeFile(at("a.txt"), "x");
        try deleteTree(at("a.txt"));

        expect(exists(at("a.txt"))).toBe(false);
    }

    test("should accept a missing path") {
        try deleteTree(at("missing"));

        expect(exists(at("missing"))).toBe(false);
    }

    test("should delete a link to a folder and leave the folder") {
        try makePath(at("kept"));
        try writeFile(at("kept/file.txt"), "x");
        try makeLink("kept", at("link"));
        try deleteTree(at("link"));

        expect(exists(at("link"))).toBe(false);
        expect(exists(at("kept/file.txt"))).toBe(true);
    }
}

describe("makeLink") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should create a link that holds the target") {
        try makeLink("v2", at("latest"));

        expect((try linkStat(at("latest"))).kind).toBe(Kind.Link);
    }

    test("should throw AlreadyExists when the path is taken") {
        try writeFile(at("latest"), "");

        expect(makeLink("v2", at("latest"))).toThrow(FsError.AlreadyExists);
    }
}

describe("readLink") {
    beforeEach { begin(); }
    afterEach { end(); }

    test("should return the target that the link holds") {
        try makeLink("some/target", at("link"));
        const bytes = try readLink(testing.allocator, at("link"));
        defer free(testing.allocator, bytes);
        const text: string = bytes;

        expect(text).toBe("some/target");
    }

    test("should throw NotFound for a missing link") {
        expect(readLink(testing.allocator, at("missing"))).toThrow(FsError.NotFound);
    }
}
