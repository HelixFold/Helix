/**
 * The size of the buffer that the functions in this file give C for a path.
 *
 * @remarks
 * {@link cwd} and {@link realPath} allocate this many bytes, so a longer path makes them return `null`.
 *
 * @example
 * ```hx
 * const buf = hxAlloc(PATH_MAX); // room for any path the driver reads back
 * ```
 *
 * @since 1.0.0
 */

export const PATH_MAX: usize = 4096;

/**
 * The mask of the file type bits in a POSIX mode.
 *
 * @remarks
 * {@link isDir}, {@link isFile}, and {@link isLink} compare the masked mode with the code of one type.
 * host.c gives the POSIX bits on Windows too, so the mask works on every system.
 *
 * @example
 * ```hx
 * (0o100644 & S_IFMT) == 0o100000; // true, a regular file
 * ```
 *
 * @since 1.0.0
 */

export const S_IFMT: u32 = 0o170000;
