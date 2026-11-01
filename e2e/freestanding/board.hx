// QEMU riscv64 `virt` for the freestanding tests: the UART, and power-off when the program stops.

const UART: usize = 0x1000_0000;
const TEST_DEVICE: usize = 0x10_0000;

export extern "C" function helix_console_write(bytes: readonly u8[*], len: usize): void {
    unsafe {
        const uart = @ptrFromInt(*u8, UART);
        for (const i of 0..len) @volatileStore(uart, bytes[i]);
    }
}

export extern "C" function helix_halt(): noreturn {
    unsafe {
        @volatileStore(@ptrFromInt(*u32, TEST_DEVICE), 0x5555);
    }
    while (true) {}
}

/** Used by the tests, so the board's functions are linked in. */
export function boardReady(): bool {
    return true;
}
