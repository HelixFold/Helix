// expect-stdout: size 5 file true link true gone true
// expect-stdout: link -> sub
// expect-stdout: entries 3
// expect-stdout: link gone, target kept: true
// expect-stdout: deleted true
// expect-stdout: status 0 out captured
// skip-wasi: uses /tmp and starts a program

import { DebugAllocator, cAllocator, free, makePath, writeFile, Dir, stat, linkStat, exists, rename, deleteTree, makeLink, readLink, Kind, capture } from "std";

function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    defer void debug.deinit();
    const a = debug.allocator();
    const root = "/tmp/helix-std-fs-test";
    try deleteTree(root);
    try makePath("/tmp/helix-std-fs-test/sub");
    try writeFile("/tmp/helix-std-fs-test/a.txt", "hello");
    try writeFile("/tmp/helix-std-fs-test/sub/b.txt", "x");
    try makeLink("sub", "/tmp/helix-std-fs-test/link");
    try rename("/tmp/helix-std-fs-test/a.txt", "/tmp/helix-std-fs-test/c.txt");
    const info = try stat("/tmp/helix-std-fs-test/c.txt");
    println(`size ${info.size} file ${info.kind == Kind.File} link ${(try linkStat("/tmp/helix-std-fs-test/link")).kind == Kind.Link} gone ${!exists("/tmp/helix-std-fs-test/a.txt")}`);
    const target = try readLink(a, "/tmp/helix-std-fs-test/link");
    defer free(a, target);
    println(`link -> ${target}`);
    let dir = try Dir.open(root);
    defer dir.close();
    let count: u32 = 0;
    while (const _name = try dir.next()) count += 1;
    println(`entries ${count}`);
    try deleteTree("/tmp/helix-std-fs-test/link");
    println(`link gone, target kept: ${exists("/tmp/helix-std-fs-test/sub/b.txt")}`);
    try deleteTree(root);
    println(`deleted ${!exists(root)}`);
    const out = try capture(a, ["printf", "captured"]);
    defer free(a, out.stdout);
    println(`status ${out.status} out ${out.stdout}`);
}
