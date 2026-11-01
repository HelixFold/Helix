// expect-stdout: aligned true
// expect-stdout: same 42
// expect-stdout: step 8

// @intFromPtr and @ptrFromInt: a pointer's address, and back (only inside `unsafe`).
export function main(): void {
    let values: u64[4] = [1, 42, 3, 4];
    const first: u64[*] = &values;
    const at = @intFromPtr(first);
    println(`aligned ${at % @alignOf(u64) == 0}`);
    unsafe {
        const second = @ptrFromInt(*u64, at + 8);
        println(`same ${*second}`);
    }
    const p: *u64 = &values[2];
    println(`step ${@intFromPtr(p) - @intFromPtr(&values[1])}`);
}
