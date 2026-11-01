// A panic without an OS: its message goes to the console, then the board halts.
// expect-qemu: panic: index out of bounds: index 7, len 3
// expect-qemu: panic.hx:12

import { boardReady } from "./board";

export function main(): void {
    println(`ready: ${boardReady()}`);
    const items: u32[3] = [1, 2, 3];
    let i: usize = 7;
    if (boardReady()) i = 7;
    println(`${items[i]}`);
}
