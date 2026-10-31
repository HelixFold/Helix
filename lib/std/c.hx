/**
 * Gives memory from `malloc` or `realloc` back to the C heap.
 *
 * @param ptr - The memory to give back, or null
 *
 * @remarks
 * It is one of the few C library functions that the standard library builds on.
 * The module is private to std, so a program reaches the C heap through `cAllocator` instead.
 * A null pointer does nothing.
 *
 * @example
 * ```hx
 * const raw = malloc(16);
 * free(raw); // raw is no longer valid
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function free(ptr: ?u8[*]): void;

/**
 * Ends the process with an exit status.
 *
 * @param code - The exit status
 *
 * @remarks
 * The C library flushes its buffered streams on the way out, so buffered output still appears.
 * The defers of the program do not run.
 *
 * @example
 * ```hx
 * exit(1); // the process ends with status 1
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function exit(code: i32): noreturn;

/**
 * Allocates bytes from the C heap.
 *
 * @param size - The number of bytes
 * @returns A pointer to the uninitialized bytes, or null when the heap has no memory left
 *
 * @remarks
 * The memory is aligned for any C type, which is 16 bytes on the 64-bit targets.
 * Give it back with {@link free}.
 *
 * @example
 * ```hx
 * const raw = malloc(4); // a pointer to 4 fresh bytes
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function malloc(size: usize): ?u8[*];

/**
 * Counts the bytes of a NUL-terminated C string.
 *
 * @param text - The start of the string
 * @returns The number of bytes before the first NUL
 *
 * @remarks
 * It reads until it finds a NUL, so the bytes must contain one.
 *
 * @example
 * ```hx
 * const text = "abc\0";
 * strlen(text.ptr); // 3
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function strlen(text: readonly u8[*]): usize;

/**
 * Grows or shrinks memory from the C heap and keeps its contents.
 *
 * @param ptr - The memory from `malloc` or `realloc`, or null to allocate fresh memory
 * @param size - The new size in bytes
 * @returns A pointer to the resized memory, or null when the heap has no memory left
 *
 * @remarks
 * The memory may move, so the caller must use the returned pointer and drop the old one.
 * A null result leaves the old memory untouched and still owned by the caller.
 *
 * @example
 * ```hx
 * const grown = realloc(raw, 64); // the old bytes at the front, now 64 long
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function realloc(ptr: ?u8[*], size: usize): ?u8[*];

/**
 * Copies bytes from one place in memory to another.
 *
 * @param dest - Where the bytes go
 * @param source - Where the bytes come from
 * @param count - The number of bytes to copy
 * @returns The destination pointer
 *
 * @remarks
 * The two ranges must not overlap.
 *
 * @example
 * ```hx
 * memcpy(dest.ptr, source.ptr, 3); // dest.ptr, with the first 3 bytes of source copied in
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function memcpy(dest: u8[*], source: readonly u8[*], count: usize): u8[*];
