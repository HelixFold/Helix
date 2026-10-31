/**
 * Imports
 */

import { ArrayList } from "std/list";

/**
 * A growable list of strings on the C heap.
 *
 * @remarks
 * The driver is a short-lived process, so neither the list nor its strings are ever freed.
 *
 * @example
 * ```hx
 * let names = strings();
 * add(&names, "main.hx");
 * names.items.len; // 1
 * ```
 *
 * @see add
 * @see strings
 *
 * @since 1.0.0
 */

export type Strings = ArrayList<string>;

/**
 * The facts about a file that the driver reads from `stat`.
 *
 * @remarks
 * host.c fills it from `stat` or `lstat` on macOS and Linux and from the file attributes on Windows,
 * where it makes up POSIX bits from the kind and the read-only flag.
 *
 * @example
 * ```hx
 * const st = stat("src", false);
 * isDir(st!.mode); // true
 * ```
 *
 * @see stat
 * @since 1.0.0
 */

export struct Stat {
    /**
     * The type and permission bits, with the POSIX meaning on every system.
     *
     * @example
     * ```hx
     * st.mode & 0o777; // 0o644
     * ```
     *
     * @since 1.0.0
     */

    mode: u32,

    /**
     * The time of the last change to the contents, in seconds since 1970.
     *
     * @example
     * ```hx
     * st.mtime; // 1761900000
     * ```
     *
     * @since 1.0.0
     */

    mtime: i64,
}
