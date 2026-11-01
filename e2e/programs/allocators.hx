// expect-stdout: len 100 last 99 live 1
// expect-stdout: sum 499500 chunks 3
// expect-stdout: leaks 1

import { ArrayList, ArenaAllocator, DebugAllocator, cAllocator, alloc, free, create, destroy } from "std";

struct Node { value: i32, next: ?*Node }

function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    const gpa = debug.allocator();

    let list = ArrayList<i32>.init(gpa);
    for (const i of 0..100) try list.append(i as i32);
    println(`len ${list.items.len} last ${list.items[99]} live ${debug.count()}`);
    list.deinit();

    let arena = ArenaAllocator.init(gpa);
    const a = arena.allocator();
    let head: ?*Node = null;
    for (const i of 0..1000) {
        const n = try create<Node>(a);
        *n = Node { value: i as i32, next: head };
        head = n;
    }
    let sum: i64 = 0;
    let cur = head;
    while (const n = cur) {
        sum += n.value;
        cur = n.next;
    }
    println(`sum ${sum} chunks ${arena.chunks.items.len}`);
    arena.deinit();

    const leaked = try alloc<u8>(gpa, 10);
    void leaked;
    const p = try create<i64>(gpa);
    destroy(gpa, p);
    const nums = try alloc<u32>(gpa, 4);
    free(gpa, nums);
    println(`leaks ${debug.deinit()}`);
}
