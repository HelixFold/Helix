/**
 * Imports
 */

import * as fmt from "./fmt";
import { free } from "./heap";
import { Env } from "./process";
import { readFile, deleteFile } from "./fs";
import { Reader, Writer, fprint, fprintln, stderr, stdout } from "./io";

/**
 * Tests
 */

extern "C" function dup(fd: i32): i32;
extern "C" function close(fd: i32): i32;
extern "C" function getpid(): i32;
extern "C" function fflush(stream: ?u8[*]): i32;
extern "C" function dup2(fd: i32, target: i32): i32;
extern "C" function creat(path: readonly u8[*], mode: u32): i32;

/**
 * The error that {@link Failing} returns from every write.
 *
 * @since 1.0.0
 */

error SpecError { Full }

/**
 * Writes bytes to a file descriptor through a writer and returns what reached the descriptor.
 *
 * @param fd - The descriptor to capture, 1 for stdout or 2 for stderr
 * @param w - The writer under test
 * @param before - Text that `print` writes first, or an empty string
 * @param bytes - The bytes to write through the writer
 * @returns The bytes that reached the descriptor, in memory from `testing.allocator`
 * @throws Any error from the writer or from reading the capture file
 *
 * @remarks
 * It points the descriptor at a file under the temporary folder,
 * writes, flushes every C stream, and points the descriptor back.
 * The file is deleted afterwards, so only the returned bytes remain.
 *
 * @since 1.0.0
 */

function captureFd(fd: i32, w: dyn Writer, before: string, bytes: string): u8[] | Error {
    const dir = Env {}.get("TMPDIR") ?? "/tmp";
    const path = try fmt.alloc(testing.allocator, `${dir}/helix-io-spec-${getpid()}\0`);
    defer free(testing.allocator, path);
    void fflush(null);
    const saved = dup(fd);
    const file = creat(path.ptr, 0o600);
    void dup2(file, fd);
    void close(file);
    if (before.len > 0) print(before);
    w.write(bytes) catch {};
    void fflush(null);
    void dup2(saved, fd);
    void close(saved);
    const name = path[0..path.len - 1];
    const contents = try readFile(testing.allocator, name);
    try deleteFile(name);
    return contents;
}

/**
 * A writer that keeps what it gets in a buffer that the test owns.
 *
 * @remarks
 * It counts its calls, so a test can tell how many writes a function made.
 * A write past the end of the buffer fails the bounds check, so tests keep their output short.
 *
 * @since 1.0.0
 */

struct Collector {
    /**
     * The buffer that receives the bytes.
     *
     * @since 1.0.0
     */

    out: u8[],

    /**
     * The count of bytes written so far.
     *
     * @since 1.0.0
     */

    len: usize,

    /**
     * The count of calls to `write` so far.
     *
     * @since 1.0.0
     */

    calls: usize,

    /**
     * Appends bytes to the buffer.
     *
     * @param this - The collector
     * @param bytes - The bytes to keep
     * @returns Nothing, since it never fails
     *
     * @remarks
     * It counts the call even when the bytes are empty.
     *
     * @since 1.0.0
     */

    write(this: *Collector, bytes: readonly u8[]): void | Error {
        for (const byte of bytes) {
            this.out[this.len] = byte;
            this.len += 1;
        }
        this.calls += 1;
    }

    /**
     * Returns the bytes written so far.
     *
     * @param this - The collector
     * @returns The written part of the buffer
     *
     * @remarks
     * The result points into the buffer, so a later write changes what it holds.
     *
     * @since 1.0.0
     */

    text(this: readonly *Collector): string {
        return this.out[0..this.len];
    }
}

/**
 * A writer that fails every write.
 *
 * @remarks
 * It shows that the print functions pass the error of the writer on.
 *
 * @since 1.0.0
 */

struct Failing {
    /**
     * Fails with `SpecError.Full`.
     *
     * @param this - The writer
     * @param _bytes - The bytes, ignored
     * @returns `SpecError.Full`, always
     *
     * @remarks
     * It keeps nothing.
     *
     * @since 1.0.0
     */

    write(this: *Failing, _bytes: readonly u8[]): void | Error {
        throw SpecError.Full;
    }
}

/**
 * A reader that gives a fixed count of `x` bytes and then nothing.
 *
 * @remarks
 * Each read fills as much of the buffer as it has left.
 *
 * @since 1.0.0
 */

struct Countdown {
    /**
     * The count of bytes still to give.
     *
     * @since 1.0.0
     */

    left: usize,

    /**
     * Fills the buffer with `x` bytes, up to the count left.
     *
     * @param this - The reader
     * @param buf - The buffer to fill
     * @returns The count of bytes it wrote, or 0 once it has none left
     *
     * @remarks
     * It never fails, so the error half of its result only matches the interface.
     *
     * @since 1.0.0
     */

    read(this: *Countdown, buf: u8[]): usize | Error {
        const n = this.left < buf.len ? this.left : buf.len;
        for (const i of 0..n) buf[i] = 'x';
        this.left -= n;
        return n;
    }
}

describe("Writer") {
    test("should accept a pointer to a struct with a write method") {
        let buffer: u8[64] = undefined;
        let collector = Collector { out: buffer[0..64], len: 0, calls: 0 };
        const w: dyn Writer = &collector;
        try w.write("ab");

        expect(collector.text()).toBe("ab");
    }
}

describe("Reader") {
    test("should accept a pointer to a struct with a read method and report 0 at the end") {
        let countdown = Countdown { left: 5 };
        const r: dyn Reader = &countdown;
        let buffer: u8[4] = undefined;

        expect(try r.read(buffer[0..4])).toBe(4);
        expect(try r.read(buffer[0..4])).toBe(1);
        expect(try r.read(buffer[0..4])).toBe(0);
    }
}

describe("fprint") {
    test("should write a template and a plain string without a newline") {
        let buffer: u8[64] = undefined;
        let collector = Collector { out: buffer[0..64], len: 0, calls: 0 };
        const n = 42;
        try fprint(&collector, `n=${n}!`);
        try fprint(&collector, "plain");

        expect(collector.text()).toBe("n=42!plain");
    }

    test("should pass on the error of the writer") {
        let failing = Failing {};

        expect(fprint(&failing, "text")).toThrow(SpecError.Full);
    }
}

describe("fprintln") {
    test("should write the text and then a newline in a separate write") {
        let buffer: u8[64] = undefined;
        let collector = Collector { out: buffer[0..64], len: 0, calls: 0 };
        try fprintln(&collector, "line");

        expect(collector.text()).toBe("line\n");
        expect(collector.calls).toBe(2);
    }

    test("should pass on the error of the writer") {
        let failing = Failing {};

        expect(fprintln(&failing, "text")).toThrow(SpecError.Full);
    }
}

describe("stdout") {
    test("should write to file descriptor 1") {
        const bytes = try captureFd(1, stdout(), "", "to stdout");
        const text: string = bytes;

        expect(text).toBe("to stdout");
        free(testing.allocator, bytes);
    }

    test("should keep its output in order with print") {
        const bytes = try captureFd(1, stdout(), "first ", "second");
        const text: string = bytes;

        expect(text).toBe("first second");
        free(testing.allocator, bytes);
    }
}

describe("stderr") {
    test("should write to file descriptor 2") {
        const bytes = try captureFd(2, stderr(), "", "to stderr");
        const text: string = bytes;

        expect(text).toBe("to stderr");
        free(testing.allocator, bytes);
    }
}
