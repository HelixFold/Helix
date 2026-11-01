# Targets

One `helix` builds for every target that it knows, from any machine.
`--target` works on `helix build`, `run`, `test`, and `ir`.

```bash
helix build app.hx --target x86_64-macos
helix build app.hx --target aarch64-linux        # a static program for any arm64 Linux
helix build app.hx --target x86_64-windows       # app.exe
helix build app.hx --target wasm32-wasi          # a .wasm module
helix build --target x86_64-linux                # a whole project, its packages' C included
```

## Target names

Targets are written `arch-os[-abi]`, and `native` is this machine.

| OS       | Targets                                                               | Links with                        |
|----------|-----------------------------------------------------------------------|-----------------------------------|
| macOS    | `aarch64-macos`, `x86_64-macos`, `arm64e-macos`                       | `ld64.lld` and the macOS SDK      |
| Linux    | `x86_64-linux`, `aarch64-linux`, `riscv64-linux`                      | `ld.lld`, statically against musl |
| Windows  | `x86_64-windows`, `aarch64-windows`                                   | `ld.lld` in MinGW mode            |
| WASI     | `wasm32-wasi`                                                         | `wasm-ld` and wasi-libc           |
| No OS    | `riscv64-freestanding`, `aarch64-freestanding`, `x86_64-freestanding` | `ld.lld`                          |
| Cortex-M | `thumbv6m-`, `thumbv7m-`, `thumbv7em-`, `thumbv8m.main-freestanding`  | `ld.lld`                          |

`usize` and pointers are as wide as the target's: 32 bits on `wasm32`.

- Linux targets default to `-musl`, and Windows targets to `-gnu`.
- `riscv64` is `rv64gc` with doubles in float registers (`lp64d`), as clang and Linux distributions assume.
- `-linux-gnu` (glibc) compiles to an object file with `--emit obj`, but doesn't link yet.

## The toolchain

`helix` doesn't run the system's `cc`, `ld`, `xcrun`, or `dsymutil`.
C compiles with the clang of its own LLVM, programs link with lld, and debug info goes into a `.dSYM` with LLVM's
dsymutil.

- **macOS** programs link against the macOS SDK, found in `$SDKROOT`, Xcode, or the command-line tools.
- **Linux** programs are static, so they run on any Linux.
  The C library is musl, built from source the first time a build needs it, with compiler-rt's builtins.
  The result stays in `$HELIX_HOME/libc/<target>`.
- **Windows** programs import only `msvcrt.dll` and `kernel32.dll`, which every Windows has.
  Helix makes their import libraries itself, so there is nothing else to install.
- **WASI** programs link against wasi-libc, built from source like musl.
  `wasmtime app.wasm` runs one, and so does Node's WASI.
  A WASI program can't start other programs or read its own call stack,
  so a panic prints its message and traps, and the host prints the stack.
- **System libraries** of the machine that builds, such as `-lz`, can't go into a program for another machine.
  Build the library from source as a package's C instead.
  musl's own `-lm`, `-lpthread`, and `-ldl` work, since they are part of its `libc.a`.
::: warning 🍎 The macOS SDK
Apple's SDK can't be shipped with Helix, so building for macOS from Linux needs `SDKROOT` to point at a copy.
CI does this with the `macos-sdk` option of `.github/actions/setup-helix`.
:::

- **arm64e** is arm64 with pointer authentication: function pointers and return addresses are signed, so a corrupted
  one traps instead of being followed.
  It links with Apple's `ld` from the command-line tools.

::: tip 📦 Offline builds
A toolchain can ship the C library sources in `$HELIX_HOME/src`, so the first build for a target needs no
download.
The CI toolchain in `.github/bootstrap` does.
:::

## Without an OS

`--target riscv64-freestanding`, `aarch64-freestanding`, or `x86_64-freestanding` builds an ELF file that a bootloader or
`qemu -kernel` loads.
The program connects the runtime to its hardware with two `export extern "C"` functions:
`helix_console_write`, where `println` and panics go, and `helix_halt`, what a panic or the end of `main` does.

::: code-group
```hx [kernel.hx]
// QEMU's riscv64 `virt` board: a UART at 0x1000_0000, and a test device that powers it off.
const Uart: usize = 0x1000_0000;
const TestDevice: usize = 0x10_0000;

export extern "C" function helix_console_write(bytes: readonly u8[*], len: usize): void { // [!code highlight]
    unsafe {
        const uart = @ptrFromInt(*u8, Uart);
        for (const i of 0..len) @volatileStore(uart, bytes[i]);
    }
}

export extern "C" function helix_halt(): noreturn { // [!code highlight]
    unsafe {
        @volatileStore(@ptrFromInt(*u32, TestDevice), 0x5555);
    }
    while (true) {}
}

function fib(n: u64): u64 {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

export function main(): void {
    println(`Hello from Helix without an OS: fib(20) = ${fib(20)}`);
}
```

```bash [run in QEMU]
helix build kernel.hx --target riscv64-freestanding -o kernel
qemu-system-riscv64 -machine virt -bios none -nographic -kernel kernel
# Hello from Helix without an OS: fib(20) = 6765
```
:::

- `_start` sets up the stack, zeroes `.bss`, and calls `main`, which takes no `Init`.
- The default memory layout is QEMU's `virt` board: riscv64 at `0x80000000`, aarch64 at `0x40080000`,
  and x86_64 at 1 MiB for a bootloader such as Limine.
  `--linker-script board.ld` gives another, which must define `__stack_top`, `__bss_start`, and `__bss_end`.
- The code is static, and riscv64 uses the `medany` model, so code linked anywhere is reachable.
- `@volatileLoad` and `@volatileStore` read and write hardware registers exactly as written.
- There is no heap unless the program brings one, and `helix test` needs an OS.

## Microcontrollers

Helix knows the Cortex-M cores, and a chip is described by its core and its memory:

| Core           | `--target`                                           | `--cpu`                      |
|----------------|------------------------------------------------------|------------------------------|
| Cortex-M0, M0+ | `thumbv6m-freestanding`                              | `cortex-m0`, `cortex-m0plus` |
| Cortex-M3      | `thumbv7m-freestanding`                              | `cortex-m3`                  |
| Cortex-M4, M7  | `thumbv7em-freestanding`, `-eabihf` with the FPU     | `cortex-m4`, `cortex-m7`     |
| Cortex-M33     | `thumbv8m.main-freestanding`, `-eabihf` with the FPU | `cortex-m33`                 |

```bash
helix build fw.hx --target thumbv7em-freestanding-eabihf --cpu cortex-m4 --flash 0x08000000:1024K --ram 0x20000000:128K
helix build fw.hx --chip STM32F411RE         # the same settings, from the chip table
helix chips F411                             # the chips whose name holds F411
```

A firmware package names its chip once in `helix.jsonc`, and every build follows it:

```jsonc
"chip": "STM32F411RE"
```

```jsonc
"chip": {
    "cpu": "cortex-m4",
    "fpu": true,
    "flash": { "origin": "0x08000000", "size": "1024K" },
    "ram": { "origin": "0x20000000", "size": "128K" },
}
```

- The chip is a default, not a rule: a program built for this machine (`target: "native"` in `build.hx`) and
  `helix test` leave it out.
- The linker script comes from the flash and RAM: the vector table first, then the code, `.data`, `.bss`, and the
  stack at the top of RAM.
- An interrupt handler is an `export extern "C"` function, `SysTick_Handler` or `IRQ28_Handler`, and one left
  undefined reports itself: `unhandled interrupt: IRQ5 (define IRQ5_Handler)`.
- Floats and 64-bit numbers on cores without hardware support go through compiler-rt.
- A fault prints its status registers and the address of the instruction.

### Registers from an SVD file

Vendors describe every register of a chip in a CMSIS-SVD file.
`helix translate-svd` turns one into a module that `std/mmio` drives:

```bash
helix translate-svd STM32F405.svd -o src/stm32f405.hx
```

```hx
import { GPIOA, TIMER, UART0, Interrupt, enableInterrupt } from "./chip";

export extern "C" function IRQ28_Handler(): void {   // runs on interrupt 28 // [!code focus:3]
    TIMER.CHA_CTRL.clear(.EN);
}

export function main(): void {
    GPIOA.MODER.modify(.MODER3, 1);         // one field, by name
    UART0.DATA.write(65);                   // the whole register
    enableInterrupt(Interrupt.TIMER);
}
```

Each register's fields are an enum that the compiler checks against that register.
Peripherals with the same registers share a type, and 8-bit and 16-bit registers are accessed at their width.
An access folds to one volatile load or store with a constant mask, and only what a program uses is compiled.

## See also

- [build.hx](/projects/build)
- [C Interop](/language/c-interop)
- [Command Line](/reference/cli)
