// Constants without a type (`const n = 64;`) are values only the compiler holds: debug builds, which describe
// locals to the debugger, must not try to store them.
// expect-stdout: true 2.5 b

export function main(): void {
    const bits = 64;
    const half = 2.5;
    const label = comptime 1 == 2 ? "a" : "b";
    println(`${bits == 64} ${half} ${label}`);
}
