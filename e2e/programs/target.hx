// `std/target` says what the program is built for, and a `comptime` condition on it keeps only the branch taken:
// GetTickCount64 exists only on Windows, and every other build links without it.
// expect-stdout: not windows
// expect-stdout: pointers: ok
// expect-stdout: ternary: picked

import { target, Os, Arch } from "std/target";

extern "C" function GetTickCount64(): u64;   // Windows only: never called (or linked) anywhere else

function ticks(): u64 {
    if (comptime target.os == Os.Windows) {
        return GetTickCount64();
    } else {
        return 0;
    }
}

export function main(): void {
    if (ticks() == 0) println("not windows");
    const bits = comptime target.arch == Arch.Wasm32 ? 32 : 64;
    println(`pointers: ${target.pointerBits == bits ? "ok" : "wrong"}`);
    const label = comptime target.os == Os.Freestanding ? "kernel" : "picked";
    println(`ternary: ${label}`);
}
