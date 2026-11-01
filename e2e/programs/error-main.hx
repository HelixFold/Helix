// expect-exit: 1
// expect-stdout: before

extern "C" function printf(format: readonly u8[*], ...): i32;

error FileError { NotFound }

function open(path: string): i32 | FileError {
    if (path.len > 0) throw FileError.NotFound;
    return 3;
}

export function main(): void | Error {
    void printf("before\n");
    const fd = try open("missing.txt");
    void printf("never %d\n", fd);
}
