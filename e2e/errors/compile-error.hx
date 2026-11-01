// `@compileError` fires only in code the program uses, and not in a branch ruled out while compiling, as in Zig.
// `@compileLog` prints while compiling and fails the build.
// expect-error: fires: main calls chain()
// expect-error: compile log: i32 = i32, Big = Big, 2 + 3 = 5, b.a: u64 (known only when the program runs)
// expect-error: small() takes types of at most 8 bytes
// expect-error: `@compileError` needs a message known while compiling

struct Big { a: u64, b: u64 }

function never(): void {
    @compileError("never fires: nothing calls never()");
}

function small<T>(x: T): T {
    if (@sizeOf(T) > 8) @compileError("small() takes types of at most 8 bytes");
    return x;
}

function chain(): void {
    @compileError("fires: main calls chain()");
}

function dynamic(reason: string): void {
    @compileError(reason);
}

export function main(): void {
    void small<i32>(5);
    const b = small(Big { a: 1, b: 2 });
    chain();
    @compileLog(i32, Big, 2 + 3, b.a);
    dynamic("x");
}
