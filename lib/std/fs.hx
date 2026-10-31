/**
 * Imports
 */

import { Allocator, alloc, resize, free } from "./heap";

/**
 * The errors that a file system call can throw.
 *
 * @remarks
 * The runtime in `lib/rt/runtime.c` turns each `errno` into one of these,
 * so the same failure reads the same on every platform.
 * Any `errno` that has no member of its own becomes `Unexpected`.
 *
 * @example
 * ```hx
 * fs.readFile(a, "missing.txt"); // throws FsError.NotFound
 * ```
 *
 * @since 1.0.0
 */

export error FsError {
    /**
     * Nothing exists at the path, or a folder in the path is not a folder.
     *
     * @remarks
     * It covers both `ENOENT` and `ENOTDIR`.
     *
     * @example
     * ```hx
     * File.open("missing.txt"); // throws FsError.NotFound
     * ```
     *
     * @since 1.0.0
     */

    NotFound,

    /**
     * The program lacks the permission for the call, or the file system is read-only.
     *
     * @remarks
     * It covers `EACCES`, `EPERM`, and `EROFS`.
     *
     * @example
     * ```hx
     * fs.writeFile("/etc/passwd", "x"); // throws FsError.AccessDenied
     * ```
     *
     * @since 1.0.0
     */

    AccessDenied,

    /**
     * The call needs a file, but the path names a folder.
     *
     * @remarks
     * Opening a folder for reading reports it too, although the system call itself succeeds there.
     *
     * @example
     * ```hx
     * File.open("src"); // throws FsError.IsDirectory
     * ```
     *
     * @since 1.0.0
     */

    IsDirectory,

    /**
     * Something already exists at a path that the call wanted to create.
     *
     * @remarks
     * `File.createNew` and `makeLink` report it.
     *
     * @example
     * ```hx
     * File.createNew("notes.txt"); // throws FsError.AlreadyExists when notes.txt exists
     * ```
     *
     * @since 1.0.0
     */

    AlreadyExists,

    /**
     * The device is full, or the user's disk quota is used up.
     *
     * @remarks
     * It covers `ENOSPC` and `EDQUOT`.
     *
     * @example
     * ```hx
     * fs.writeFile("big.bin", bytes); // throws FsError.NoSpace on a full disk
     * ```
     *
     * @since 1.0.0
     */

    NoSpace,

    /**
     * A path or a name in it is too long, or the path holds a zero byte.
     *
     * @remarks
     * The runtime copies each path into a buffer of `PATH_MAX` bytes and reports it before calling the system,
     * and `Dir.next` reports it for a name longer than its buffer.
     *
     * @example
     * ```hx
     * fs.stat(longPath); // throws FsError.NameTooLong for a path of PATH_MAX bytes or more
     * ```
     *
     * @since 1.0.0
     */

    NameTooLong,

    /**
     * Any other failure.
     *
     * @remarks
     * It stands for every `errno` without a member of its own, and for a code the runtime does not define.
     *
     * @example
     * ```hx
     * fs.rename("a", "/other-volume/a"); // throws FsError.Unexpected for EXDEV
     * ```
     *
     * @since 1.0.0
     */

    Unexpected,
}

/**
 * Opens the file at `path`.
 *
 * @param path - The path bytes, not NUL-terminated
 * @param len - The length of the path
 * @param mode - 0 to read, 1 to write and truncate, 2 to append, 3 to create a new file
 * @returns The file descriptor, or a negative error code
 *
 * @remarks
 * Every mode but 0 creates a missing file with the permissions `0666`, less the umask.
 * Mode 0 on a folder returns the code for `IsDirectory`.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_open(path: readonly u8[*], len: usize, mode: i32): i64;

/**
 * Reads up to `len` bytes from a file descriptor.
 *
 * @param fd - The file descriptor
 * @param buf - The buffer to read into
 * @param len - The size of the buffer
 * @returns The number of bytes read, 0 at the end of the file, or a negative error code
 *
 * @remarks
 * It retries when a signal interrupts the read.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_read(fd: i32, buf: u8[*], len: usize): i64;

/**
 * Writes all `len` bytes to a file descriptor.
 *
 * @param fd - The file descriptor
 * @param bytes - The bytes to write
 * @param len - The number of bytes
 * @returns 0, or a negative error code
 *
 * @remarks
 * It loops over short writes and interruptions until every byte is out.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_write(fd: i32, bytes: readonly u8[*], len: usize): i64;

/**
 * Closes a file descriptor.
 *
 * @param fd - The file descriptor
 *
 * @remarks
 * It ignores any error from `close`.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_close(fd: i32): void;

/**
 * Returns the size of an open file.
 *
 * @param fd - The file descriptor
 * @returns The size in bytes, or a negative error code
 *
 * @remarks
 * A pipe or a terminal reports 0, so the caller cannot rely on it as the length to read.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_size(fd: i32): i64;

/**
 * Deletes the file at a path.
 *
 * @param path - The path bytes
 * @param len - The length of the path
 * @returns 0, or a negative error code
 *
 * @remarks
 * It calls `unlink`, so it removes a symbolic link itself and fails on a folder.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_delete(path: readonly u8[*], len: usize): i64;

/**
 * Creates a folder and any missing folders above it.
 *
 * @param path - The path bytes
 * @param len - The length of the path
 * @returns 0, or a negative error code
 *
 * @remarks
 * It works like `mkdir -p`, and a folder that already exists is not an error.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_make_path(path: readonly u8[*], len: usize): i64;

/**
 * Copies a file and keeps its permission bits.
 *
 * @param from - The source path bytes
 * @param fromLength - The length of the source path
 * @param to - The destination path bytes
 * @param toLength - The length of the destination path
 * @returns 0, or a negative error code
 *
 * @remarks
 * It deletes the destination first, so a running program that holds the old file keeps its copy intact.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_copy(from: readonly u8[*], fromLength: usize, to: readonly u8[*], toLength: usize): i64;

/**
 * Fills `out` with what the system knows about a path.
 *
 * @param path - The path bytes
 * @param len - The length of the path
 * @param follow - 1 to follow a symbolic link, 0 to report the link itself
 * @param out - The record to fill
 * @returns 0, or a negative error code
 *
 * @remarks
 * It calls `stat` or `lstat`, depending on `follow`.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_stat(path: readonly u8[*], len: usize, follow: i32, out: *RawStat): i64;

/**
 * Opens a folder for listing.
 *
 * @param path - The path bytes
 * @param len - The length of the path
 * @returns A handle for `hx_fs_dir_next`, or a negative error code
 *
 * @remarks
 * The handle is the address of the C library's `DIR` record.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_dir_open(path: readonly u8[*], len: usize): i64;

/**
 * Copies the next name in a folder into `out`.
 *
 * @param handle - The handle from `hx_fs_dir_open`
 * @param out - The buffer for the name
 * @param cap - The size of the buffer
 * @returns The length of the name, 0 when there are no more, or a negative error code
 *
 * @remarks
 * It skips `.` and `..`, and reports a name longer than `cap` as `NameTooLong`.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_dir_next(handle: i64, out: u8[*], cap: usize): i64;

/**
 * Closes a folder handle.
 *
 * @param handle - The handle from `hx_fs_dir_open`
 *
 * @remarks
 * It calls `closedir`, and the handle is invalid afterwards.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_dir_close(handle: i64): void;

/**
 * Renames or moves a file or folder.
 *
 * @param from - The old path bytes
 * @param fromLength - The length of the old path
 * @param to - The new path bytes
 * @param toLength - The length of the new path
 * @returns 0, or a negative error code
 *
 * @remarks
 * It calls `rename`, which replaces a file at `to` and works only within one file system.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_rename(from: readonly u8[*], fromLength: usize, to: readonly u8[*], toLength: usize): i64;

/**
 * Deletes a file or a folder with everything in it.
 *
 * @param path - The path bytes
 * @param len - The length of the path
 * @returns 0, or a negative error code
 *
 * @remarks
 * It works like `rm -rf`, never follows a symbolic link, and treats a missing path as done.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_delete_tree(path: readonly u8[*], len: usize): i64;

/**
 * Creates a symbolic link.
 *
 * @param target - The bytes that the link holds
 * @param targetLength - The length of the target
 * @param path - The path bytes of the new link
 * @param len - The length of the path
 * @returns 0, or a negative error code
 *
 * @remarks
 * It calls `symlink`, which does not check that the target exists.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_symlink(target: readonly u8[*], targetLength: usize, path: readonly u8[*], len: usize): i64;

/**
 * Copies what a symbolic link holds into `out`.
 *
 * @param path - The path bytes of the link
 * @param len - The length of the path
 * @param out - The buffer for the target
 * @param cap - The size of the buffer
 * @returns The number of bytes copied, or a negative error code
 *
 * @remarks
 * It calls `readlink`, which cuts a target longer than `cap` short without reporting it.
 *
 * @since 1.0.0
 */

extern "C" function hx_fs_read_link(path: readonly u8[*], len: usize, out: u8[*], cap: usize): i64;

/**
 * The record that `hx_fs_stat` fills, laid out like `HxStat` in `lib/rt/runtime.c`.
 *
 * @remarks
 * The field order and types must match the C struct, since the runtime writes into it through a pointer.
 * {@link statOf} turns it into a {@link Stat}.
 *
 * @since 1.0.0
 */

extern "C" struct RawStat {
    /**
     * The size in bytes.
     *
     * @since 1.0.0
     */

    size: i64,

    /**
     * The last modification, in seconds since 1970.
     *
     * @since 1.0.0
     */

    mtime: i64,

    /**
     * The kind of the path: 0 file, 1 folder, 2 symbolic link, 3 anything else.
     *
     * @since 1.0.0
     */

    kind: i32,

    /**
     * The permission bits, with the setuid, setgid, and sticky bits.
     *
     * @since 1.0.0
     */

    mode: u32,
}

/**
 * Turns a runtime result into its value or its error.
 *
 * @param result - A result from one of the `hx_fs_` functions
 * @returns The result as an unsigned value when it is not negative, or the matching `FsError`
 *
 * @remarks
 * A negative result is minus the error code, from 1 for `NotFound` to 7 for `Unexpected`,
 * in the order of the `FsError` members.
 * A code past 7 becomes `Unexpected` as well.
 *
 * @since 1.0.0
 */

function check(result: i64): u64 | FsError {
    if (result >= 0) return result as u64;
    const errors: FsError[7] = [
        FsError.NotFound, FsError.AccessDenied, FsError.IsDirectory, FsError.AlreadyExists,
        FsError.NoSpace, FsError.NameTooLong, FsError.Unexpected,
    ];
    const code = (-result) as usize;
    throw code <= errors.len ? errors[code - 1] : FsError.Unexpected;
}

/**
 * An open file.
 *
 * @remarks
 * Open one with `open`, `create`, `append`, or `createNew`, and close it when done with `defer file.close()`.
 * A `*File` is both a `dyn Writer` and a `dyn Reader`, so `fprint` and `fprintln` write into it.
 * Every `write` is a system call, so build a big output first and write it at once.
 * For a whole file in one step, {@link readFile} and {@link writeFile} are shorter.
 *
 * @example
 * ```hx
 * let file = try File.create("log.txt");
 * defer file.close();
 * try fprintln(&file, `started at ${t}`);
 * ```
 *
 * @see readFile
 * @see writeFile
 *
 * @since 1.0.0
 */

export struct File {
    /**
     * The operating system's file descriptor.
     *
     * @remarks
     * `close` sets it to -1.
     *
     * @example
     * ```hx
     * File.stdin().fd; // 0
     * ```
     *
     * @since 1.0.0
     */

    fd: i32,

    /**
     * Opens an existing file for reading.
     *
     * @param path - The path of the file
     * @returns The open file, or `NotFound`, `IsDirectory`, or another `FsError`
     *
     * @remarks
     * A folder fails with `IsDirectory` here rather than on the first read.
     *
     * @example
     * ```hx
     * let file = try File.open("notes.txt");
     * defer file.close();
     * ```
     *
     * @since 1.0.0
     */

    open(path: string): File | FsError {
        return File.at(try check(hx_fs_open(path.ptr, path.len, 0)));
    }

    /**
     * Opens a file for writing, creating it or emptying it.
     *
     * @param path - The path of the file
     * @returns The open file, or an `FsError`
     *
     * @remarks
     * A new file gets the permissions `0666`, less the umask.
     * An existing file loses its contents.
     *
     * @example
     * ```hx
     * let file = try File.create("out.txt");
     * try file.write("hi"); // out.txt now holds "hi"
     * ```
     *
     * @since 1.0.0
     */

    create(path: string): File | FsError {
        return File.at(try check(hx_fs_open(path.ptr, path.len, 1)));
    }

    /**
     * Opens a file for writing at its end, creating it when it is missing.
     *
     * @param path - The path of the file
     * @returns The open file, or an `FsError`
     *
     * @remarks
     * Every write goes to the end of the file, even when another program writes to it at the same time.
     *
     * @example
     * ```hx
     * let file = try File.append("log.txt");
     * try file.write("more\n"); // added after what log.txt held
     * ```
     *
     * @since 1.0.0
     */

    append(path: string): File | FsError {
        return File.at(try check(hx_fs_open(path.ptr, path.len, 2)));
    }

    /**
     * Creates a new file for writing.
     *
     * @param path - The path of the file
     * @returns The open file, or `AlreadyExists` when something is at `path`
     *
     * @remarks
     * The check and the creation are one step, so two programs racing for the same path cannot both win.
     *
     * @example
     * ```hx
     * File.createNew("lock"); // throws FsError.AlreadyExists the second time
     * ```
     *
     * @since 1.0.0
     */

    createNew(path: string): File | FsError {
        return File.at(try check(hx_fs_open(path.ptr, path.len, 3)));
    }

    /**
     * Returns the program's standard input.
     *
     * @returns The file for descriptor 0
     *
     * @remarks
     * The program does not own it, so closing it is rarely what the caller wants.
     *
     * @example
     * ```hx
     * let input = File.stdin();
     * const text = try input.readAll(a); // everything piped in
     * ```
     *
     * @since 1.0.0
     */

    stdin(): File {
        return File { fd: 0 };
    }

    /**
     * Wraps a file descriptor from the runtime in a `File`.
     *
     * @param fd - The descriptor that `check` returned
     * @returns The file for that descriptor
     *
     * @remarks
     * The opening functions use it to turn the unsigned result of `check` into the signed descriptor.
     *
     * @example
     * ```hx
     * File.at(1).fd; // 1
     * ```
     *
     * @since 1.0.0
     */

    at(fd: u64): File {
        return File { fd: fd as i32 };
    }

    /**
     * Closes the file.
     *
     * @param this - The file
     *
     * @remarks
     * It sets `fd` to -1, so a use after closing fails instead of touching a reused descriptor.
     *
     * @example
     * ```hx
     * file.close();
     * file.fd; // -1
     * ```
     *
     * @since 1.0.0
     */

    close(this: *File): void {
        hx_fs_close(this.fd);
        this.fd = -1;
    }

    /**
     * Reads into `buf`.
     *
     * @param this - The file
     * @param buf - The buffer to read into
     * @returns The number of bytes read, where 0 means the end of the file, or an `FsError`
     *
     * @remarks
     * It may read fewer bytes than `buf` holds even before the end, so loop until it returns 0.
     *
     * @example
     * ```hx
     * let buf: u8[64] = undefined;
     * const n = try file.read(&buf); // 5, for a file that holds "hello"
     * ```
     *
     * @since 1.0.0
     */

    read(this: *File, buf: u8[]): usize | Error {
        return (try check(hx_fs_read(this.fd, buf.ptr, buf.len))) as usize;
    }

    /**
     * Writes all of `bytes`.
     *
     * @param this - The file
     * @param bytes - The bytes to write
     * @returns Nothing, or an `FsError`
     *
     * @remarks
     * The runtime loops until every byte is out.
     * Every call is a system call, so build a big output first and write it at once.
     *
     * @example
     * ```hx
     * try file.write("hello"); // the file grows by 5 bytes
     * ```
     *
     * @since 1.0.0
     */

    write(this: *File, bytes: readonly u8[]): void | Error {
        void try check(hx_fs_write(this.fd, bytes.ptr, bytes.len));
    }

    /**
     * Reads the rest of the file into new memory from `a`.
     *
     * @param this - The file
     * @param a - The allocator that the bytes come from
     * @returns The bytes, owned by the caller, or the error that reading or allocation threw
     *
     * @remarks
     * It starts with a buffer one byte bigger than the file, so a regular file takes one read and one final check.
     * A pipe or stdin reports size 0, so it starts at 4096 bytes and doubles as needed.
     * The result is resized to the bytes it read, and a failure frees the buffer.
     *
     * @example
     * ```hx
     * let file = try File.open("notes.txt");
     * const text = try file.readAll(a); // the whole file
     * ```
     *
     * @since 1.0.0
     */

    readAll(this: *File, a: dyn Allocator): u8[] | Error {
        const size = (check(hx_fs_size(this.fd)) catch 0) as usize;
        let buf = try alloc<u8>(a, size > 0 ? size + 1 : 4096);
        errdefer free(a, buf);
        let len: usize = 0;
        while (true) {
            if (len == buf.len) buf = try resize(a, buf, buf.len * 2);
            const n = try this.read(buf[len..buf.len]);
            if (n == 0) break;
            len += n;
        }
        return try resize(a, buf, len);
    }
}

/**
 * Reads the whole file at `path` into new memory from `a`.
 *
 * @param a - The allocator that the bytes come from
 * @param path - The path of the file
 * @returns The bytes, owned by the caller, or the error that opening, reading, or allocation threw
 *
 * @remarks
 * It opens the file, reads it with `File.readAll`, and closes it again.
 * The caller gives the bytes back with `free(a, bytes)`.
 * An empty file gives an empty slice.
 *
 * @example
 * ```hx
 * const text = try fs.readFile(a, "notes.txt");
 * defer free(a, text);
 * ```
 *
 * @since 1.0.0
 */

export function readFile(a: dyn Allocator, path: string): u8[] | Error {
    let file = try File.open(path);
    defer file.close();
    return try file.readAll(a);
}

/**
 * Replaces the file at `path` with `bytes`, creating it when it is missing.
 *
 * @param path - The path of the file
 * @param bytes - The new contents
 * @returns Nothing, or an `FsError`
 *
 * @remarks
 * It opens the file with `File.create`, so the old contents are gone even when the write fails.
 *
 * @example
 * ```hx
 * try fs.writeFile("out.txt", "done"); // out.txt holds "done"
 * ```
 *
 * @since 1.0.0
 */

export function writeFile(path: string, bytes: readonly u8[]): void | Error {
    let file = try File.create(path);
    defer file.close();
    try file.write(bytes);
}

/**
 * Deletes the file at `path`.
 *
 * @param path - The path of the file
 * @returns Nothing, or an `FsError`
 *
 * @remarks
 * A symbolic link goes itself, never the file it points at.
 * It fails on a folder, so use {@link deleteTree} for one.
 *
 * @example
 * ```hx
 * try fs.deleteFile("out.txt");
 * fs.exists("out.txt"); // false
 * ```
 *
 * @since 1.0.0
 */

export function deleteFile(path: string): void | Error {
    void try check(hx_fs_delete(path.ptr, path.len));
}

/**
 * Creates the folder at `path` and any missing folders above it.
 *
 * @param path - The path of the folder
 * @returns Nothing, or an `FsError`
 *
 * @remarks
 * It works like `mkdir -p`, so a folder that already exists is fine.
 *
 * @example
 * ```hx
 * try fs.makePath("build/out/bin");
 * fs.stat("build/out").kind; // Kind.Directory
 * ```
 *
 * @since 1.0.0
 */

export function makePath(path: string): void | Error {
    void try check(hx_fs_make_path(path.ptr, path.len));
}

/**
 * Copies the file at `from` to `to`.
 *
 * @param from - The path of the file to copy
 * @param to - The path of the copy
 * @returns Nothing, or an `FsError`
 *
 * @remarks
 * It replaces a file at `to` and keeps the permission bits, so an executable stays one.
 * The old `to` is deleted first, so a running program that holds it keeps its own copy intact.
 *
 * @example
 * ```hx
 * try fs.copyFile("helix", "bin/helix"); // bin/helix is executable as well
 * ```
 *
 * @since 1.0.0
 */

export function copyFile(from: string, to: string): void | Error {
    void try check(hx_fs_copy(from.ptr, from.len, to.ptr, to.len));
}

/* ---- folders, metadata, links ---- */

/**
 * The kind of thing at a path.
 *
 * @remarks
 * {@link stat} follows symbolic links, so it never reports `Link`, while {@link linkStat} does.
 *
 * @example
 * ```hx
 * fs.stat("src").kind; // Kind.Directory
 * ```
 *
 * @since 1.0.0
 */

export enum Kind {
    /**
     * A regular file.
     *
     * @example
     * ```hx
     * fs.stat("notes.txt").kind; // Kind.File
     * ```
     *
     * @since 1.0.0
     */

    File,

    /**
     * A folder.
     *
     * @example
     * ```hx
     * fs.stat("src").kind; // Kind.Directory
     * ```
     *
     * @since 1.0.0
     */

    Directory,

    /**
     * A symbolic link, which only {@link linkStat} reports.
     *
     * @example
     * ```hx
     * fs.linkStat("latest").kind; // Kind.Link
     * ```
     *
     * @since 1.0.0
     */

    Link,

    /**
     * Anything else, such as a device, a pipe, or a socket.
     *
     * @example
     * ```hx
     * fs.stat("/dev/null").kind; // Kind.Other
     * ```
     *
     * @since 1.0.0
     */

    Other,
}

/**
 * What {@link stat} and {@link linkStat} report about a path.
 *
 * @remarks
 * It holds the size, the modification time, the kind, and the permission bits.
 *
 * @example
 * ```hx
 * const info = try fs.stat("notes.txt");
 * info.size; // 12
 * ```
 *
 * @since 1.0.0
 */

export struct Stat {
    /**
     * The size in bytes.
     *
     * @remarks
     * For a symbolic link from `linkStat` it is the length of the target the link holds.
     *
     * @example
     * ```hx
     * (try fs.stat("notes.txt")).size; // 12
     * ```
     *
     * @since 1.0.0
     */

    size: u64,

    /**
     * The last modification, in seconds since 1970.
     *
     * @remarks
     * Compare two of them to tell which file changed last.
     *
     * @example
     * ```hx
     * (try fs.stat("notes.txt")).mtime; // 1761955200
     * ```
     *
     * @since 1.0.0
     */

    mtime: i64,

    /**
     * The kind of thing at the path.
     *
     * @remarks
     * Only `linkStat` ever reports `Kind.Link`.
     *
     * @example
     * ```hx
     * (try fs.stat("src")).kind; // Kind.Directory
     * ```
     *
     * @since 1.0.0
     */

    kind: Kind,

    /**
     * The permission bits, like `0o755`.
     *
     * @remarks
     * It also holds the setuid, setgid, and sticky bits, and never the bits for the kind.
     *
     * @example
     * ```hx
     * (try fs.stat("helix")).mode; // 0o755
     * ```
     *
     * @since 1.0.0
     */

    mode: u32,
}

/**
 * Asks the runtime about `path` and turns its record into a {@link Stat}.
 *
 * @param path - The path to look at
 * @param follow - Whether to follow a symbolic link
 * @returns What the system knows about the path, or an `FsError`
 *
 * @remarks
 * {@link stat} and {@link linkStat} share it and differ only in `follow`.
 *
 * @since 1.0.0
 */

function statOf(path: string, follow: bool): Stat | FsError {
    let raw = RawStat { size: 0, mtime: 0, kind: 0, mode: 0 };
    void try check(hx_fs_stat(path.ptr, path.len, follow ? 1 : 0, &raw));
    const kinds: Kind[4] = [Kind.File, Kind.Directory, Kind.Link, Kind.Other];
    return Stat { size: raw.size as u64, mtime: raw.mtime, kind: kinds[raw.kind as usize], mode: raw.mode };
}

/**
 * Reports what `path` is, following symbolic links.
 *
 * @param path - The path to look at
 * @returns The size, modification time, kind, and permission bits, or an `FsError`
 *
 * @remarks
 * A link reports what it points at, and a broken link fails with `NotFound`.
 * Use {@link linkStat} to look at the link itself.
 *
 * @example
 * ```hx
 * const info = try fs.stat("notes.txt");
 * info.kind; // Kind.File
 * ```
 *
 * @see linkStat
 * @since 1.0.0
 */

export function stat(path: string): Stat | FsError {
    return try statOf(path, true);
}

/**
 * Reports what `path` is, without following a symbolic link.
 *
 * @param path - The path to look at
 * @returns The size, modification time, kind, and permission bits, or an `FsError`
 *
 * @remarks
 * A link reports itself with the kind `Kind.Link`, even when it is broken.
 * Anything else reports the same as with {@link stat}.
 *
 * @example
 * ```hx
 * fs.linkStat("latest").kind; // Kind.Link
 * ```
 *
 * @see stat
 * @since 1.0.0
 */

export function linkStat(path: string): Stat | FsError {
    return try statOf(path, false);
}

/**
 * Reports whether anything is at `path`.
 *
 * @param path - The path to look at
 * @returns True when something is there, including a symbolic link
 *
 * @remarks
 * It does not follow a link, so a broken link counts.
 * Every failure reads as false, including a denied permission and a path that is too long.
 *
 * @example
 * ```hx
 * fs.exists("notes.txt"); // true
 * ```
 *
 * @since 1.0.0
 */

export function exists(path: string): bool {
    let raw = RawStat { size: 0, mtime: 0, kind: 0, mode: 0 };
    return hx_fs_stat(path.ptr, path.len, 0, &raw) == 0;
}

/**
 * The names in a folder, one at a time.
 *
 * @remarks
 * `next` skips `.` and `..` and lists the names in the order that the operating system gives them.
 * Each name lives in the `Dir` itself and is valid until the next call, so copy it to keep it.
 * Close it when done with `defer dir.close()`.
 *
 * @example
 * ```hx
 * let dir = try Dir.open("src");
 * defer dir.close();
 * while (const name = try dir.next()) println(name);
 * ```
 *
 * @since 1.0.0
 */

export struct Dir {
    /**
     * The runtime's handle for the open folder.
     *
     * @remarks
     * `close` sets it to 0, which marks the folder as closed.
     *
     * @example
     * ```hx
     * dir.close();
     * dir.handle; // 0
     * ```
     *
     * @since 1.0.0
     */

    handle: i64,

    /**
     * The buffer that holds the name that `next` returned last.
     *
     * @remarks
     * It is 256 bytes, which fits any name on the common file systems.
     *
     * @example
     * ```hx
     * dir.name.len; // 256
     * ```
     *
     * @since 1.0.0
     */

    name: u8[256],

    /**
     * Opens the folder at `path` for listing.
     *
     * @param path - The path of the folder
     * @returns The open folder, or an `FsError`
     *
     * @remarks
     * A path that names a file fails with `NotFound`, since the system reports `ENOTDIR`.
     *
     * @example
     * ```hx
     * let dir = try Dir.open("src");
     * defer dir.close();
     * ```
     *
     * @since 1.0.0
     */

    open(path: string): Dir | FsError {
        return Dir { handle: try check(hx_fs_dir_open(path.ptr, path.len)) as i64, name: undefined };
    }

    /**
     * Closes the folder.
     *
     * @param this - The folder
     *
     * @remarks
     * Closing twice is safe, since the second call sees the handle at 0 and does nothing.
     *
     * @example
     * ```hx
     * dir.close();
     * dir.close(); // does nothing
     * ```
     *
     * @since 1.0.0
     */

    close(this: *Dir): void {
        if (this.handle != 0) hx_fs_dir_close(this.handle);
        this.handle = 0;
    }

    /**
     * Returns the next name in the folder.
     *
     * @param this - The folder
     * @returns The next name, null when there are no more, or an `FsError`
     *
     * @remarks
     * The name points into `name`, so the next call overwrites it.
     *
     * @example
     * ```hx
     * dir.next(); // "main.hx"
     * dir.next(); // null, once every name is out
     * ```
     *
     * @since 1.0.0
     */

    next(this: *Dir): ?string | FsError {
        const n = try check(hx_fs_dir_next(this.handle, &this.name, this.name.len));
        if (n == 0) return null;
        const name: *u8[256] = &this.name;
        return name[0..n as usize];
    }
}

/**
 * Renames or moves a file or folder.
 *
 * @param from - The current path
 * @param to - The new path
 * @returns Nothing, or an `FsError`
 *
 * @remarks
 * It replaces a file at `to`, and it works only within one file system.
 * A move to another one fails, so copy and delete instead.
 *
 * @example
 * ```hx
 * try fs.rename("a.txt", "b.txt");
 * fs.exists("a.txt"); // false
 * ```
 *
 * @since 1.0.0
 */

export function rename(from: string, to: string): void | Error {
    void try check(hx_fs_rename(from.ptr, from.len, to.ptr, to.len));
}

/**
 * Deletes a file or a folder and everything in it.
 *
 * @param path - The path to delete
 * @returns Nothing, or an `FsError`
 *
 * @remarks
 * It works like `rm -rf`, and a missing path is fine.
 * A symbolic link goes itself, never what it points at, even when it points at a folder.
 *
 * @example
 * ```hx
 * try fs.deleteTree("build");
 * fs.exists("build"); // false
 * ```
 *
 * @since 1.0.0
 */

export function deleteTree(path: string): void | Error {
    void try check(hx_fs_delete_tree(path.ptr, path.len));
}

/**
 * Makes `path` a symbolic link that holds `target`.
 *
 * @param target - What the link points at, relative to the link's folder or absolute
 * @param path - Where the link goes
 * @returns Nothing, or `AlreadyExists` when something is at `path`, or another `FsError`
 *
 * @remarks
 * The target need not exist, and the link stays broken until it does.
 *
 * @example
 * ```hx
 * try fs.makeLink("v2", "latest");
 * fs.linkStat("latest").kind; // Kind.Link
 * ```
 *
 * @since 1.0.0
 */

export function makeLink(target: string, path: string): void | Error {
    void try check(hx_fs_symlink(target.ptr, target.len, path.ptr, path.len));
}

/**
 * Reads what the symbolic link at `path` holds into new memory from `a`.
 *
 * @param a - The allocator that the bytes come from
 * @param path - The path of the link
 * @returns The target the link holds, owned by the caller, or an `FsError`
 *
 * @remarks
 * It reads into a 1024-byte buffer on the stack and copies the result.
 * A target longer than that comes back cut to 1024 bytes without an error.
 *
 * @example
 * ```hx
 * const target = try fs.readLink(a, "latest");
 * target; // "v2"
 * ```
 *
 * @since 1.0.0
 */

export function readLink(a: dyn Allocator, path: string): u8[] | Error {
    let buf: u8[1024] = undefined;
    const n = try check(hx_fs_read_link(path.ptr, path.len, &buf, buf.len)) as usize;
    const out = try alloc<u8>(a, n);
    for (const i of 0..n) out[i] = buf[i];
    return out;
}
