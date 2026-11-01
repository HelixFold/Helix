// A hardware fault without an OS: the start code's trap handler reports it instead of hanging.
// expect-qemu: trap: mcause 0x5

import { boardReady } from "./board";

export function main(): void {
    println(`ready: ${boardReady()}`);
    unsafe {
        const nowhere = @ptrFromInt(*u32, 0x10);   // no memory there on `virt`: a load access fault
        println(`${@volatileLoad(nowhere)}`);
    }
}
