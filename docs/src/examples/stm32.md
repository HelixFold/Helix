# STM32 Firmware

Firmware for an STM32F405, a Cortex-M4 with an FPU.
It prints over USART1, uses the FPU, and handles SysTick and USART1 interrupts in Helix.

```bash
cd examples/stm32
helix build
qemu-system-arm -M netduinoplus2 -nographic -kernel helix-out/bin/firmware
```

```text
Hello from Helix on an STM32F405 (Cortex-M, 32-bit)
circle of radius 2: 12.56636 (the FPU)
SysTick: 10 interrupts
USART1: interrupt 37 handled
```

On a board, flash the same ELF file with probe-rs, OpenOCD, or STM32CubeProgrammer.

::: info 🔌 The chip decides the build
`helix.jsonc` names the chip, so `helix build` takes the target, the CPU, and the memory layout from the chip table,
with no options on the command line.
:::

::: code-group
<<< @/../examples/stm32/src/main.hx [src/main.hx]
<<< @/../examples/stm32/helix.jsonc [helix.jsonc]
:::

The registers come from the chip's SVD file:

```bash
helix translate-svd stm32f405.svd -o src/stm32f405.hx
```

## See also

- [Targets](/projects/targets#microcontrollers)
- [helix.jsonc](/projects/manifest)
