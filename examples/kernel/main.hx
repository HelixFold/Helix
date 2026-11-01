/**
 * Imports
 */

import { kernelMain } from "./kernel";
import { target, Arch } from "std/target";

/**
 * The address of the UART on QEMU's riscv64 `virt` board.
 *
 * @remarks
 * The UART is an NS16550A, and writing its first register sends a byte.
 *
 * @since 1.0.0
 */

const RiscvUart: usize = 0x1000_0000;

/**
 * The address of the SiFive test device on QEMU's riscv64 `virt` board.
 *
 * @remarks
 * Writing `0x5555` to it powers the machine off.
 *
 * @since 1.0.0
 */

const RiscvPower: usize = 0x10_0000;

/**
 * The address of the UART on QEMU's aarch64 `virt` board.
 *
 * @remarks
 * The UART is a PL011, and writing its data register sends a byte.
 *
 * @since 1.0.0
 */

const ArmUart: usize = 0x0900_0000;

/**
 * Writes bytes to the board's UART.
 *
 * @param bytes - The bytes to send
 * @param len - How many bytes to send
 *
 * @remarks
 * The runtime of a program without an OS calls it for `println` and for panics.
 * `comptime` keeps only the branch of the target being built, so each board's code is compiled for that board alone.
 * x86_64 needs I/O instructions for its serial port, so it prints nothing.
 *
 * @example
 * ```hx
 * println("hi"); // the runtime calls helix_console_write with the 3 bytes "hi\n"
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function helix_console_write(bytes: readonly u8[*], len: usize): void {
    unsafe {
        if (comptime target.arch == Arch.Riscv64) {
            const uart = @ptrFromInt(*u8, RiscvUart);
            for (const i of 0..len) @volatileStore(uart, bytes[i]);
        } else if (comptime target.arch == Arch.Aarch64) {
            const uart = @ptrFromInt(*u32, ArmUart);
            for (const i of 0..len) @volatileStore(uart, bytes[i] as u32);
        }
    }
}

/**
 * Stops the machine after `main` returns, or after a panic.
 *
 * @remarks
 * QEMU's riscv64 board powers off.
 * On the others the core spins, and Ctrl-A X quits QEMU.
 *
 * @example
 * ```hx
 * @panic("no memory"); // prints the message, then calls helix_halt
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function helix_halt(): noreturn {
    if (comptime target.arch == Arch.Riscv64) {
        unsafe {
            @volatileStore(@ptrFromInt(*u32, RiscvPower), 0x5555);
        }
    }
    while (true) {}
}

/**
 * Starts the kernel with the name of the architecture.
 *
 * @remarks
 * A program without an OS has a `main` that takes no `Init`.
 *
 * @example
 * ```bash
 * helix build examples/kernel/main.hx --target riscv64-freestanding -o kernel
 * qemu-system-riscv64 -machine virt -bios none -nographic -kernel kernel
 *
 * helix build examples/kernel/main.hx --target aarch64-freestanding -o kernel
 * qemu-system-aarch64 -machine virt -cpu cortex-a72 -nographic -kernel kernel
 * ```
 *
 * @since 1.0.0
 */

export function main(): void {
    kernelMain(comptime target.arch == Arch.Riscv64 ? "riscv64" : target.arch == Arch.Aarch64 ? "aarch64" : "x86_64");
}
