// expect-panic: use after free: this memory (8 bytes) was freed
// skip-wasi: WebAssembly has no page protections, so DebugAllocator can't guard memory there

import { DebugAllocator, cAllocator, create, destroy } from "std";

struct Point { x: i32, y: i32 }

function read(p: *Point): i32 {
    return p.x;
}

function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    const gpa = debug.allocator();
    const p = try create<Point>(gpa);
    destroy(gpa, p);
    println(`${read(p)}`);
}
