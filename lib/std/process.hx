/**
 * Imports
 */

import * as c from "./c";
import { Allocator, alloc, cAllocator, free } from "./heap";

/**
 * The running program as `main(init: Init)` receives it: its arguments and its environment.
 *
 * @remarks
 * The compiler builds it before `main` runs, from the command line that started the program.
 * A `main` without parameters does not get it.
 *
 * @example
 * ```hx
 * export function main(init: Init): void | Error {
 *     for (const arg of init.args) println(arg);
 *     const home = init.env.get("HOME") ?? "/";
 * }
 * ```
 *
 * @since 1.0.0
 */

export struct Init {
    /**
     * How the program was started, which is the first word of the command line.
     *
     * @example
     * ```hx
     * init.program; // "./app" for the command line ./app one two
     * ```
     *
     * @since 1.0.0
     */

    program: string,

    /**
     * The arguments after the first word of the command line.
     *
     * @example
     * ```hx
     * init.args; // ["one", "two"] for the command line ./app one two
     * ```
     *
     * @since 1.0.0
     */

    args: readonly string[],

    /**
     * The environment variables.
     *
     * @example
     * ```hx
     * init.env.get("HOME"); // "/Users/ada"
     * ```
     *
     * @since 1.0.0
     */

    env: Env,
}

/**
 * The environment variables of the process.
 *
 * @remarks
 * It has no fields and reads the live environment on each call, so it sees changes that the process makes.
 *
 * @example
 * ```hx
 * const env = Env {};
 * env.get("HOME"); // "/Users/ada"
 * ```
 *
 * @since 1.0.0
 */

export struct Env {
    /**
     * Returns the value of an environment variable.
     *
     * @param this - The environment
     * @param name - The name of the variable
     * @returns The value, or null when the variable is not set
     *
     * @remarks
     * A name of 256 bytes or more, or one that holds a NUL byte, is never set.
     * The value points into the environment of the process, so a later change to the variable may change it.
     *
     * @example
     * ```hx
     * init.env.get("HOME");        // "/Users/ada"
     * init.env.get("NOT_SET_YET"); // null
     * ```
     *
     * @since 1.0.0
     */

    get(this: Env, name: string): ?string {
        const value = hx_getenv(name.ptr, name.len);
        if (value == null) return null;
        return fromCString(value);
    }
}

/**
 * The errors of starting another program.
 *
 * @remarks
 * {@link run}, {@link capture}, {@link captureAll}, and {@link captureAllWith} throw it,
 * and the runtime prints the reason on stderr first.
 *
 * @example
 * ```hx
 * run(["no-such-program"]) catch (e) { ... }; // ProcessError.CannotStart
 * ```
 *
 * @since 1.0.0
 */

export error ProcessError {
    /**
     * The program could not start, because it does not exist, is not executable, or the command line is empty.
     *
     * @example
     * ```hx
     * expect(run([])).toThrow(ProcessError.CannotStart); // passes
     * ```
     *
     * @since 1.0.0
     */

    CannotStart
}

/**
 * Runs a program and waits for it to finish.
 *
 * @param argv - The command line, whose first word is the program
 * @returns The exit status of the program, or 128 plus the number of the signal that ended it
 * @throws ProcessError.CannotStart when the program cannot start
 *
 * @remarks
 * The first word is looked up in `PATH` the way a shell does.
 * The program inherits the stdin, the stdout, the stderr, and the environment of this program.
 * Output that this program buffered is flushed first, so it comes out before the output of the program.
 *
 * @example
 * ```hx
 * try run(["git", "status"]);       // 0
 * try run(["sh", "-c", "exit 3"]); // 3
 * ```
 *
 * @since 1.0.0
 */

export function run(argv: readonly string[]): u8 | ProcessError {
    const status = hx_process_run(argv.ptr, argv.len);
    if (status < 0) throw ProcessError.CannotStart;
    return status as u8;
}

/**
 * Runs a program and waits for it to finish.
 *
 * @remarks
 * The runtime in `lib/rt/runtime.c` implements it with `posix_spawnp`.
 * It returns the exit status, 128 plus the number of the signal that ended the program,
 * or -1 when the program could not start.
 *
 * @since 1.0.0
 */

extern "C" function hx_process_run(argv: readonly string[*], count: usize): i64;

/**
 * Runs a program with its stdout captured into memory from `malloc`.
 *
 * @remarks
 * The runtime in `lib/rt/runtime.c` implements it.
 * It sets `out` and `len` to the captured bytes, which the caller frees, and returns what `hx_process_run` returns.
 *
 * @since 1.0.0
 */

extern "C" function hx_process_capture(argv: readonly string[*], count: usize, out: *?u8[*], len: *usize): i64;

/**
 * Runs a program with its stdout and its stderr captured into memory from `malloc`.
 *
 * @remarks
 * The runtime in `lib/rt/runtime.c` implements it, reading both pipes as they fill.
 * It starts the program in `dir` when `dirLen` is not 0,
 * and kills it once `timeout` milliseconds pass when that is above 0.
 * It sets `out` and `err` to the captured bytes, which the caller frees, and returns what `hx_process_run` returns.
 *
 * @since 1.0.0
 */

extern "C" function hx_process_capture_all(argv: readonly string[*], count: usize, dir: readonly u8[*], dirLen: usize, timeout: i64, out: *?u8[*], outLen: *usize, err: *?u8[*], errLen: *usize): i64;

/**
 * What {@link capture} or {@link captureAll} got from a program.
 *
 * @remarks
 * The caller owns the bytes and gives them back to the allocator that it passed.
 *
 * @example
 * ```hx
 * const out = try capture(a, ["git", "rev-parse", "HEAD"]);
 * out.status; // 0
 * free(a, out.stdout);
 * ```
 *
 * @since 1.0.0
 */

export struct Output {
    /**
     * The exit status of the program, or 128 plus the number of the signal that ended it.
     *
     * @example
     * ```hx
     * out.status; // 0
     * ```
     *
     * @since 1.0.0
     */

    status: u8,

    /**
     * Everything that the program wrote to stdout, in memory from the allocator passed to the capture.
     *
     * @example
     * ```hx
     * out.stdout; // the bytes of "a1b2c3\n"
     * ```
     *
     * @since 1.0.0
     */

    stdout: u8[],

    /**
     * Everything that the program wrote to stderr, in memory from the allocator passed to {@link captureAll}.
     *
     * @remarks
     * It is empty after {@link capture}, which leaves the stderr of the program on the stderr of this program.
     *
     * @example
     * ```hx
     * out.stderr; // the bytes of "error: no such file\n"
     * ```
     *
     * @since 1.0.0
     */

    stderr: u8[],
}

/**
 * Runs a program like {@link run} and captures its stdout into memory.
 *
 * @param a - The allocator for the captured bytes
 * @param argv - The command line, whose first word is the program
 * @returns The exit status and the captured bytes, or the error that stopped it
 * @throws ProcessError.CannotStart when the program cannot start
 *
 * @remarks
 * The stderr of the program still goes to the stderr of this program.
 * The bytes are copied from the buffer of the runtime into memory from `a`, so the caller frees them with `a`.
 * A program that writes nothing gets an empty slice, which needs no free.
 *
 * @example
 * ```hx
 * const out = try capture(a, ["git", "rev-parse", "HEAD"]);
 * defer free(a, out.stdout);
 * out.status; // 0
 * ```
 *
 * @since 1.0.0
 */

export function capture(a: dyn Allocator, argv: readonly string[]): Output | Error {
    let raw: ?u8[*] = null;
    let len: usize = 0;
    const status = hx_process_capture(argv.ptr, argv.len, &raw, &len);
    defer c.free(raw);
    if (status < 0) throw ProcessError.CannotStart;
    return Output { status: status as u8, stdout: try copyBytes(a, raw, len), stderr: [] };
}

/**
 * How {@link captureAllWith} starts a program and how long it lets it run.
 *
 * @remarks
 * Both fields have defaults, so `CaptureOptions {}` runs the program as {@link captureAll} does.
 *
 * @example
 * ```hx
 * const options = CaptureOptions { dir: "build", timeout: 3000 };
 * options.timeout; // 3000
 * ```
 *
 * @since 1.0.0
 */

export struct CaptureOptions {
    /**
     * The folder that the program starts in, or an empty text for the folder of this program.
     *
     * @remarks
     * A relative path in the command line, the program's included, is found from this folder.
     *
     * @example
     * ```hx
     * CaptureOptions { dir: "/tmp" }; // the program runs in /tmp
     * ```
     *
     * @since 1.0.0
     */

    dir: string = "",

    /**
     * The milliseconds that the program may run before it is killed, or 0 for no limit.
     *
     * @remarks
     * A killed program ends with status 137, which is 128 plus the number of the signal that kills it,
     * and the output keeps what it wrote before then.
     * Reach for it with a program that may never end on its own, such as an emulator that boots a board.
     *
     * @example
     * ```hx
     * CaptureOptions { timeout: 3000 }; // the program is killed after 3 seconds
     * ```
     *
     * @since 1.0.0
     */

    timeout: u32 = 0,
}

/**
 * Runs a program like {@link run} and captures both its stdout and its stderr into memory.
 *
 * @param a - The allocator for the captured bytes
 * @param argv - The command line, whose first word is the program
 * @returns The exit status and the bytes of both streams, or the error that stopped it
 * @throws ProcessError.CannotStart when the program cannot start
 *
 * @remarks
 * Reach for it over {@link capture} when the program reports on stderr, as a compiler does with its errors.
 * The two streams stay apart, so the order between a line on stdout and one on stderr is lost.
 * The caller frees both slices with `a`.
 *
 * @example
 * ```hx
 * const out = try captureAll(a, ["sh", "-c", "echo out; echo err >&2; exit 1"]);
 * out.status; // 1
 * out.stdout; // the bytes of "out\n"
 * out.stderr; // the bytes of "err\n"
 * ```
 *
 * @see captureAllWith
 * @since 1.0.0
 */

export function captureAll(a: dyn Allocator, argv: readonly string[]): Output | Error {
    return try captureAllWith(a, argv, CaptureOptions {});
}

/**
 * Runs a program like {@link captureAll}, in a given folder and with a time limit.
 *
 * @param a - The allocator for the captured bytes
 * @param argv - The command line, whose first word is the program
 * @param options - The folder that the program starts in and the milliseconds that it may run
 * @returns The exit status and the bytes of both streams, or the error that stopped it
 * @throws ProcessError.CannotStart when the program cannot start
 *
 * @remarks
 * This program stays in its own folder, so its relative paths keep their meaning while the other program runs.
 * The caller frees both slices with `a`.
 *
 * @example
 * ```hx
 * const out = try captureAllWith(a, ["pwd"], CaptureOptions { dir: "/tmp" });
 * out.stdout; // the bytes of "/tmp\n"
 * const slow = try captureAllWith(a, ["sleep", "10"], CaptureOptions { timeout: 100 });
 * slow.status; // 137
 * ```
 *
 * @see CaptureOptions
 * @since 1.0.0
 */

export function captureAllWith(a: dyn Allocator, argv: readonly string[], options: CaptureOptions): Output | Error {
    let rawOut: ?u8[*] = null;
    let rawErr: ?u8[*] = null;
    let outLen: usize = 0;
    let errLen: usize = 0;
    const dir = options.dir;
    const status = hx_process_capture_all(argv.ptr, argv.len, dir.ptr, dir.len, options.timeout as i64, &rawOut, &outLen, &rawErr, &errLen);
    defer c.free(rawOut);
    defer c.free(rawErr);
    if (status < 0) throw ProcessError.CannotStart;
    const stdout = try copyBytes(a, rawOut, outLen);
    errdefer free(a, stdout);
    const stderr = try copyBytes(a, rawErr, errLen);
    return Output { status: status as u8, stdout, stderr };
}

/**
 * Copies bytes that the runtime captured into memory from an allocator.
 *
 * @param a - The allocator for the copy
 * @param raw - The bytes from `malloc`, or null when there are none
 * @param len - The number of bytes
 * @returns The copy, or the error of the allocator
 *
 * @remarks
 * The caller still frees `raw` with `free` from C, since the copy does not take it over.
 *
 * @since 1.0.0
 */

function copyBytes(a: dyn Allocator, raw: ?u8[*], len: usize): u8[] | Error {
    const bytes = try alloc<u8>(a, len);
    if (const r = raw) {
        unsafe {
            for (const i of 0..len) bytes[i] = r[i];
        }
    }
    return bytes;
}

/**
 * Ends the program with an exit status.
 *
 * @param code - The exit status
 *
 * @remarks
 * The defers of the program do not run, but output that it buffered is flushed.
 *
 * @example
 * ```hx
 * exit(2); // the program ends with status 2
 * ```
 *
 * @since 1.0.0
 */

export function exit(code: u8): noreturn {
    c.exit(code as i32);
}

/**
 * Looks up an environment variable.
 *
 * @remarks
 * The runtime in `lib/rt/runtime.c` implements it.
 * It returns null for a name of 256 bytes or more and for a name that holds a NUL byte.
 *
 * @since 1.0.0
 */

extern "C" function hx_getenv(name: readonly u8[*], len: usize): ?readonly u8[*];

/**
 * Turns a NUL-terminated C string into a string.
 *
 * @param text - The start of the C string
 * @returns The bytes before the NUL, without a copy
 *
 * @remarks
 * The result points into the C string, so it lives as long as that string does.
 *
 * @since 1.0.0
 */

function fromCString(text: readonly u8[*]): string {
    unsafe {
        return text[0..c.strlen(text)];
    }
}

/**
 * Builds the {@link Init} of the program from the `argc` and `argv` of C.
 *
 * @param argc - The number of words on the command line
 * @param argv - The words, as C strings
 * @returns The program, its arguments, and its environment
 *
 * @remarks
 * The compiler calls it before `main(init: Init)` and finds it by its name, so the name stays as it is.
 * The list of words comes from the C heap and lives as long as the program.
 * It panics when the C heap has no memory for the list.
 *
 * @since 1.0.0
 */

function _startup(argc: i32, argv: readonly u8[*][*]): Init {
    const count = argc as usize;
    const words = alloc<string>(cAllocator(), count) catch @panic("out of memory reading the command line");
    for (const _, i of words) {
        unsafe {
            words[i] = fromCString(argv[i]);
        }
    }
    if (count == 0) return Init { program: "", args: words, env: Env {} };
    return Init { program: words[0], args: words[1..count], env: Env {} };
}
