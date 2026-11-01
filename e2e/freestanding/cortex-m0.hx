// A Cortex-M0 (QEMU's micro:bit, an nRF51): Thumb-1 only, no divide instruction, so 64-bit division and printing
// go through compiler-rt's helpers.
// target: thumbv6m-freestanding --cpu cortex-m0 --flash 0x00000000:256K --ram 0x20000000:16K
// qemu: qemu-system-arm -M microbit
// expect-qemu: cortex-m0: 12586269025 / 7 = 1798038432

const UART: usize = 0x4000_2000;

function reg(offset: usize): *u32 {
    unsafe {
        return @ptrFromInt(*u32, UART + offset);
    }
}

export extern "C" function helix_console_write(bytes: readonly u8[*], len: usize): void {
    for (const i of 0..len) {
        @volatileStore(reg(0x11C), 0);   // EVENTS_TXDRDY
        unsafe {
            @volatileStore(reg(0x51C), bytes[i] as u32);   // TXD
        }
        while (@volatileLoad(reg(0x11C)) == 0) {}
    }
}

export function main(): void {
    @volatileStore(reg(0x500), 4);       // ENABLE
    @volatileStore(reg(0x008), 1);       // TASKS_STARTTX
    let stored: u64 = 12_586_269_025;
    const big = @volatileLoad(&stored);   // read at run time, so the division happens there, through compiler-rt
    println(`cortex-m0: ${big} / 7 = ${big / 7}`);
    while (true) {}
}
