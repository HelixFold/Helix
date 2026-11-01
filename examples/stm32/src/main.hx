/**
 * Imports
 */

import { SYSTICK } from "std/mmio";
import { target, Arch } from "std/target";
import { RCC, GPIOA, USART1, Interrupt, enableInterrupt } from "./stm32f405";

/**
 * The number of SysTick interrupts so far.
 *
 * @remarks
 * An interrupt handler changes it, so every access goes through `@volatileLoad` and `@volatileStore`.
 *
 * @since 1.0.0
 */

let ticks: u32 = 0;

/**
 * The number of USART1 interrupts so far.
 *
 * @since 1.0.0
 */

let uartInterrupts: u32 = 0;

/**
 * Sets up USART1 to send at 115200 baud on PA9.
 *
 * @remarks
 * It turns on the clocks of GPIOA and USART1, gives PA9 to USART1 as alternate function 7,
 * and divides the internal 16 MHz clock down to 115200 baud.
 * Each call names its register field, such as `.GPIOAEN`, and the compiler checks it against that register.
 *
 * @since 1.0.0
 */

function uartInit(): void {
    RCC.AHB1ENR.set(.GPIOAEN);
    RCC.APB2ENR.set(.USART1EN);
    GPIOA.MODER.modify(.MODER9, 2);       // alternate function
    GPIOA.AFRH.modify(.AFRH9, 7);         // AF7: USART1
    USART1.BRR.write(0x8B);               // 16 MHz / 115200
    USART1.CR1.set(.UE);
    USART1.CR1.set(.TE);
}

/**
 * Sends bytes over USART1.
 *
 * @param bytes - The bytes to send
 * @param len - How many bytes to send
 *
 * @remarks
 * The runtime calls it for `println` and for panics.
 * It waits for the transmit register to empty before each byte.
 *
 * @example
 * ```hx
 * println("hi"); // the runtime calls helix_console_write with the 3 bytes "hi\n"
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function helix_console_write(bytes: readonly u8[*], len: usize): void {
    for (const i of 0..len) {
        while (USART1.SR.get(.TXE) == 0) {}
        unsafe {
            USART1.DR.write(bytes[i] as u32);
        }
    }
}

/**
 * Counts a SysTick interrupt.
 *
 * @remarks
 * Its name replaces the default handler of the start code, so defining it is all that a handler takes.
 *
 * @example
 * ```hx
 * SYSTICK.CSR.set(.TICKINT); // from now on, each tick runs SysTick_Handler
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function SysTick_Handler(): void {
    @volatileStore(&ticks, @volatileLoad(&ticks) + 1);
}

/**
 * Counts a USART1 interrupt, then turns that interrupt off.
 *
 * @remarks
 * USART1 is interrupt 37, so its handler is `IRQ37_Handler`.
 * Here it fires when the transmit register is empty.
 *
 * @example
 * ```hx
 * enableInterrupt(Interrupt.USART1);
 * USART1.CR1.set(.TXEIE); // IRQ37_Handler runs once the transmit register is empty
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function IRQ37_Handler(): void {
    @volatileStore(&uartInterrupts, @volatileLoad(&uartInterrupts) + 1);
    USART1.CR1.clear(.TXEIE);
}

/**
 * Prints over USART1, uses the FPU, and waits for SysTick and USART1 interrupts.
 *
 * @remarks
 * `helix.jsonc` names the chip, an STM32F405RG,
 * so `helix build` picks the target, the CPU, and the memory layout from the chip table.
 * The registers come from the chip's SVD file, through `helix translate-svd`.
 *
 * @example
 * ```bash
 * helix translate-svd stm32f405.svd -o src/stm32f405.hx    # after editing the SVD
 * helix build                                              # thumbv7em-freestanding-eabihf, cortex-m4
 * qemu-system-arm -M netduinoplus2 -nographic -kernel helix-out/bin/firmware
 * ```
 *
 * @since 1.0.0
 */

export function main(): void {
    uartInit();
    println(`Hello from Helix on an STM32F405 (${comptime target.arch == Arch.Thumb ? "Cortex-M" : "?"}, ${target.pointerBits}-bit)`);
    const area = 3.14159 * 2.0 * 2.0;
    println(`circle of radius 2: ${area} (the FPU)`);

    SYSTICK.RVR.modify(.RELOAD, 16_000 - 1);   // 1 ms at 16 MHz
    SYSTICK.CVR.write(0);
    SYSTICK.CSR.write(0);
    SYSTICK.CSR.set(.CLKSOURCE);
    SYSTICK.CSR.set(.TICKINT);
    SYSTICK.CSR.set(.ENABLE);
    while (@volatileLoad(&ticks) < 10) {}
    println(`SysTick: ${@volatileLoad(&ticks)} interrupts`);

    enableInterrupt(Interrupt.USART1);
    USART1.CR1.set(.TXEIE);
    while (@volatileLoad(&uartInterrupts) == 0) {}
    println(`USART1: interrupt ${Interrupt.USART1 as u32} handled`);
}
