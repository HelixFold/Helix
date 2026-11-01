// expect-panic: memory freed twice, or not from this allocator

import { DebugAllocator, cAllocator, alloc, free } from "std";

function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    const gpa = debug.allocator();
    const items = try alloc<u8>(gpa, 8);
    free(gpa, items);
    free(gpa, items);
}
