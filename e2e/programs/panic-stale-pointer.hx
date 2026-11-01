// expect-panic: use after free: this memory (32 bytes) was freed, or moved when it grew
// skip-wasi: WebAssembly has no page protections, so DebugAllocator can't guard memory there
// A pointer into an ArrayList, kept while the list grows (and so moves its items).

import { DebugAllocator, cAllocator, ArrayList } from "std";

function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    let list = ArrayList<i32>.init(debug.allocator());
    try list.append(1);
    const first = &list.items[0];
    for (const i of 0..100) try list.append(i as i32);
    println(`stale: ${*first}`);
}
