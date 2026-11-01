// expect-stdout: args 0, program set true, PATH set true, missing null
// expect-stdout: read 11 bytes, same true
// expect-stdout: appended 20 bytes, same true
// expect-stdout: createNew: AlreadyExists
// expect-stdout: chunks 3 of 4 bytes
// expect-stdout: deleted: NotFound
// expect-stdout: directory: IsDirectory
// expect-stdout: leaks 0

import { Init, File, Reader, DebugAllocator, cAllocator, free, readFile, writeFile, deleteFile, fprintln, equal } from "std";

const PATH = "helix-files-test.tmp";

function readChunks(r: dyn Reader): usize | Error {
    let buf: u8[4] = undefined;
    let chunks: usize = 0;
    while (try r.read(&buf) > 0) chunks += 1;
    return chunks;
}

function createNew(): void | Error {
    let file = try File.createNew(PATH);
    file.close();
}

function openDirectory(): void | Error {
    let file = try File.open("e2e");
    file.close();
}

export function main(init: Init): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    const a = debug.allocator();
    println(`args ${init.args.len}, program set ${init.program.len > 0}, PATH set ${init.env.get("PATH") != null}, missing ${init.env.get("HELIX_SURELY_UNSET")}`);

    try writeFile(PATH, "first line\n");
    const first = try readFile(a, PATH);
    println(`read ${first.len} bytes, same ${equal(first, "first line\n")}`);
    free(a, first);

    let log = try File.append(PATH);
    try fprintln(&log, `second ${1 + 1}`);
    log.close();
    const both = try readFile(a, PATH);
    println(`appended ${both.len} bytes, same ${equal(both, "first line\nsecond 2\n")}`);
    free(a, both);

    createNew() catch (e) println(`createNew: ${e}`);

    try writeFile(PATH, "0123456789");
    let file = try File.open(PATH);
    println(`chunks ${try readChunks(&file)} of 4 bytes`);
    file.close();

    try deleteFile(PATH);
    deleteFile(PATH) catch (e) println(`deleted: ${e}`);
    openDirectory() catch (e) println(`directory: ${e}`);
    println(`leaks ${debug.deinit()}`);
}
