/**
 * Imports
 */

import { Allocator, AllocError, resize, free } from "./heap";

/**
 * A growable array of `T` values.
 *
 * @typeParam T - The type of the values that the list holds
 *
 * @remarks
 * The values live in one block of memory from the allocator passed to `init`, and `deinit` gives that block back.
 * `items` is the part in use and `capacity` is how many values fit before the list has to grow.
 * Growing moves the block, so a pointer into `items` taken before an `append` may dangle after it.
 *
 * @example
 * ```hx
 * let list = ArrayList<i32>.init(cAllocator());
 * defer list.deinit();
 * try list.append(1);
 * try list.append(2);
 * list.items;  // [1, 2]
 * list.pop();  // 2
 * ```
 *
 * @since 1.0.0
 */

export struct ArrayList<T> {
    /**
     * The values in the list, in the order they were appended.
     *
     * @remarks
     * The slice points into storage that holds `capacity` values, of which the first `items.len` are in use.
     * Code may read and write the values in place, but only the methods change its length.
     *
     * @example
     * ```hx
     * try list.append(7);
     * list.items[0]; // 7
     * ```
     *
     * @since 1.0.0
     */

    items: T[],

    /**
     * The number of values that fit in the storage before it has to grow.
     *
     * @remarks
     * It starts at 0, becomes 8 on the first `append`, and doubles every time the storage fills up.
     *
     * @example
     * ```hx
     * try list.append(1);
     * list.capacity; // 8
     * ```
     *
     * @since 1.0.0
     */

    capacity: usize,

    /**
     * The allocator that the storage comes from.
     *
     * @remarks
     * Every grow step and the final `deinit` go through it, so it must outlive the list.
     *
     * @example
     * ```hx
     * const list = ArrayList<u8>.init(cAllocator());
     * list.allocator; // the C heap
     * ```
     *
     * @since 1.0.0
     */

    allocator: dyn Allocator,

    /**
     * Creates an empty list that takes its memory from `allocator`.
     *
     * @param allocator - The allocator that the storage comes from
     * @returns An empty list with no storage yet
     *
     * @remarks
     * Nothing allocates here, the first `append` does.
     * A list that never grows needs no `deinit`, but calling it is always safe.
     *
     * @example
     * ```hx
     * const list = ArrayList<i32>.init(cAllocator());
     * list.items.len; // 0
     * list.capacity;  // 0
     * ```
     *
     * @since 1.0.0
     */

    init(allocator: dyn Allocator): ArrayList<T> {
        return ArrayList<T> { items: [], capacity: 0, allocator };
    }

    /**
     * Gives the storage back to the allocator and leaves the list empty.
     *
     * @param this - The list to release
     *
     * @remarks
     * It frees the whole storage, `capacity` values long, not only the part in use.
     * Afterwards `items` is empty and `capacity` is 0, so the list can grow again, and a second `deinit` does no harm.
     *
     * @example
     * ```hx
     * try list.append(1);
     * list.deinit();
     * list.capacity; // 0
     * ```
     *
     * @since 1.0.0
     */

    deinit(this: *ArrayList<T>): void {
        unsafe {
            free(this.allocator, this.items.ptr[0..this.capacity]);
        }
        this.items = [];
        this.capacity = 0;
    }

    /**
     * Adds `item` at the end of the list.
     *
     * @param this - The list to add to
     * @param item - The value to add
     * @returns Nothing, or `AllocError.OutOfMemory` when the storage could not grow
     *
     * @remarks
     * When the storage is full it grows to 8 values the first time and to twice its capacity after that,
     * through `resize`, so the values may move.
     * A failed grow throws before anything changes, and the list keeps its old values.
     *
     * @example
     * ```hx
     * try list.append(3);
     * list.items; // [3]
     * ```
     *
     * @since 1.0.0
     */

    append(this: *ArrayList<T>, item: T): void | AllocError {
        if (this.items.len == this.capacity) {
            const grown = this.capacity == 0 ? 8 : this.capacity * 2;
            unsafe {
                const storage = try resize(this.allocator, this.items.ptr[0..this.capacity], grown);
                this.items = storage[0..this.items.len];
            }
            this.capacity = grown;
        }
        unsafe {
            const len = this.items.len;
            this.items = this.items.ptr[0..len + 1];
            this.items[len] = item;
        }
    }

    /**
     * Removes the last value and returns it.
     *
     * @param this - The list to take from
     * @returns The last value, or null when the list is empty
     *
     * @remarks
     * Only the length shrinks, and the storage stays the same size.
     *
     * @example
     * ```hx
     * try list.append(4);
     * list.pop(); // 4
     * list.pop(); // null
     * ```
     *
     * @since 1.0.0
     */

    pop(this: *ArrayList<T>): ?T {
        if (this.items.len == 0) return null;
        const last = this.items[this.items.len - 1];
        this.items = this.items[0..this.items.len - 1];
        return last;
    }

    /**
     * Removes every value and keeps the storage for reuse.
     *
     * @param this - The list to empty
     *
     * @remarks
     * The capacity stays as it was, so appending up to it again allocates nothing.
     * Use `deinit` to give the memory back instead.
     *
     * @example
     * ```hx
     * try list.append(5);
     * list.clear();
     * list.items.len; // 0
     * list.capacity;  // 8
     * ```
     *
     * @since 1.0.0
     */

    clear(this: *ArrayList<T>): void {
        this.items = this.items[0..0];
    }
}
