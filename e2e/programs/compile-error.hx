// `@compileError` in code nothing uses, or in a branch a compile-time condition rules out, doesn't stop the build.
// expect-stdout: 3 7.5 60 0.1

function never(): void {
    @compileError("never fires: nothing calls never()");
}

/** Types of at most 8 bytes; a bigger one is a compile error in its own instance only. */
function small<T>(x: T): T {
    if (@sizeOf(T) > 8) @compileError("small() takes types of at most 8 bytes");
    return x;
}

export function main(): void {
    const f: f32 = 60.0;
    const g: f32 = 0.1;
    println(`${small<u8>(3)} ${small(7.5)} ${f} ${g}`);
}
