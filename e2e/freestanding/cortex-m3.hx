// A Cortex-M3 without an FPU (QEMU's STM32F100 board): software floats and 64-bit numbers through compiler-rt.
// build: --chip STM32F100RB
// qemu: qemu-system-arm -M stm32vldiscovery
// expect-qemu: cortex-m3: 12586269025 2.5
// expect-qemu: unhandled interrupt: IRQ5

const USART1_DR: usize = 0x4001_3804;
const USART1_CR1: usize = 0x4001_380C;
const NVIC_ISER0: usize = 0xE000_E100;
const NVIC_ISPR0: usize = 0xE000_E200;

function reg(address: usize): *u32 {
    unsafe {
        return @ptrFromInt(*u32, address);
    }
}

export extern "C" function helix_console_write(bytes: readonly u8[*], len: usize): void {
    for (const i of 0..len) {
        unsafe {
            @volatileStore(reg(USART1_DR), bytes[i] as u32);
        }
    }
}

function fib(n: u64): u64 {
    let a: u64 = 0;
    let b: u64 = 1;
    for (const _ of 0..n) {
        const next = a + b;
        a = b;
        b = next;
    }
    return a;
}

export function main(): void {
    @volatileStore(reg(USART1_CR1), (1 << 13) | (1 << 3));   // UE, TE
    const half: f64 = 5.0 / 2.0;
    println(`cortex-m3: ${fib(50)} ${half}`);
    // an interrupt nobody handles reports itself
    @volatileStore(reg(NVIC_ISER0), 1 << 5);
    @volatileStore(reg(NVIC_ISPR0), 1 << 5);
    while (true) {}
}
