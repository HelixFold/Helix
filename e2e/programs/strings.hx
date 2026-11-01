// expect-stdout: made user-42 (7 bytes)
// expect-stdout: buffer 3,4
// expect-stdout: too long: 0
// expect-stdout: [0][1][2] done
// expect-stdout: origin at { x: 0, y: 0 }
// expect-stdout: plain
// expect-stdout: [0][1][2] donebuilder at { x: 1, y: 2 }
// expect-stdout: count 4

import * as fmt from "std/fmt";
import { DebugAllocator, cAllocator, free } from "std/heap";
import { Writer, stdout, stderr, fprint, fprintln } from "std/io";

struct Point { x: i32, y: i32 }

function report(w: dyn Writer, name: string, p: Point): void | Error {
    try fprintln(w, `${name} at ${p}`);
}

export function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    defer void debug.deinit();
    const a = debug.allocator();

    const id: u32 = 42;
    const s = try fmt.alloc(a, `user-${id}`);
    defer free(a, s);
    println(`made ${s} (${s.len} bytes)`);

    let buf: u8[8] = undefined;
    const t = try fmt.bufPrint(&buf, `${3},${4}`);
    println(`buffer ${t}`);
    const long = fmt.bufPrint(&buf, `${1234567890}`) catch buf[0..0];
    println(`too long: ${long.len}`);

    let b = fmt.Builder.init(a);
    defer b.deinit();
    for (const i of 0..3) try b.append(`[${i}]`);
    try b.append(" done");
    println(b.text());

    try report(stdout(), "origin", Point { x: 0, y: 0 });
    try fprint(stdout(), "plain\n");
    try fprintln(stderr(), `to stderr ${1.5}`);
    try report(&b, "builder", Point { x: 1, y: 2 });
    print(b.text());
    println(`count ${try fmt.count(`${id}${id}`)}`);
}
