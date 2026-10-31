/**
 * Imports
 */

import { ArrayList } from "./list";

/**
 * Tests
 */

describe("ArrayList") {
    describe("init") {
        test("should start empty without taking any memory") {
            const list = ArrayList<i32>.init(testing.allocator);

            expect(list.items.len).toBe(0);
            expect(list.capacity).toBe(0);
        }
    }

    describe("deinit") {
        test("should give the storage back and leave the list empty") {
            let list = ArrayList<i32>.init(testing.allocator);
            try list.append(1);
            list.deinit();

            expect(list.items.len).toBe(0);
            expect(list.capacity).toBe(0);
        }

        test("should do no harm on a list that never grew") {
            let list = ArrayList<i32>.init(testing.allocator);
            list.deinit();

            expect(list.capacity).toBe(0);
        }

        test("should do no harm when it runs twice") {
            let list = ArrayList<i32>.init(testing.allocator);
            try list.append(1);
            list.deinit();
            list.deinit();

            expect(list.capacity).toBe(0);
        }
    }

    describe("append") {
        test("should keep the values in the order they arrive") {
            let list = ArrayList<i32>.init(testing.allocator);
            defer list.deinit();
            try list.append(3);
            try list.append(1);
            try list.append(2);

            expect(list.items).toEqual([3, 1, 2]);
        }

        test("should grow the storage to 8 values on the first append") {
            let list = ArrayList<i32>.init(testing.allocator);
            defer list.deinit();
            try list.append(1);

            expect(list.capacity).toBe(8);
        }

        test("should double the capacity when the storage fills up") {
            let list = ArrayList<i32>.init(testing.allocator);
            defer list.deinit();
            for (const i of 0..9) try list.append(i as i32);

            expect(list.capacity).toBe(16);
            expect(list.items.len).toBe(9);
        }

        test("should keep every value across several grow steps") {
            let list = ArrayList<usize>.init(testing.allocator);
            defer list.deinit();
            for (const i of 0..100) try list.append(i);

            expect(list.items.len).toBe(100);
            expect(list.items[0]).toBe(0);
            expect(list.items[63]).toBe(63);
            expect(list.items[99]).toBe(99);
            expect(list.capacity).toBe(128);
        }
    }

    describe("pop") {
        test("should remove and return the last value") {
            let list = ArrayList<i32>.init(testing.allocator);
            defer list.deinit();
            try list.append(1);
            try list.append(2);

            expect(list.pop()).toBe(2);
            expect(list.items).toEqual([1]);
        }

        test("should return null for an empty list") {
            let list = ArrayList<i32>.init(testing.allocator);

            expect(list.pop()).toBeNull();
        }

        test("should keep the storage at its size") {
            let list = ArrayList<i32>.init(testing.allocator);
            defer list.deinit();
            try list.append(1);
            void list.pop();

            expect(list.capacity).toBe(8);
        }
    }

    describe("clear") {
        test("should remove every value and keep the capacity") {
            let list = ArrayList<i32>.init(testing.allocator);
            defer list.deinit();
            for (const i of 0..10) try list.append(i as i32);
            list.clear();

            expect(list.items.len).toBe(0);
            expect(list.capacity).toBe(16);
        }

        test("should let the list fill up again from the start") {
            let list = ArrayList<i32>.init(testing.allocator);
            defer list.deinit();
            try list.append(1);
            list.clear();
            try list.append(5);

            expect(list.items).toEqual([5]);
            expect(list.capacity).toBe(8);
        }
    }
}
