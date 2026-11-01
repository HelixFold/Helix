# Kernel

A kernel for QEMU's `virt` board, in one source for every architecture.
`std/target` picks the board's UART while compiling, so only the code of the target being built is compiled.

```bash
helix build examples/kernel/main.hx --target riscv64-freestanding -o kernel
qemu-system-riscv64 -machine virt -bios none -nographic -kernel kernel
```

```text
Hello from Helix on riscv64, without an OS
point: 3, 4; fib(50) = 12586269025; pi is about 3.14159
squares: 1 4 9 16
```

The riscv64 board powers off at the end.
`--target aarch64-freestanding` runs the same kernel under `qemu-system-aarch64 -machine virt -cpu cortex-a72`,
where Ctrl-A X quits.

::: code-group
<<< @/../examples/kernel/main.hx [main.hx]
<<< @/../examples/kernel/kernel.hx [kernel.hx]
:::

`main.hx` connects the runtime to the board with `helix_console_write` and `helix_halt`.
`kernel.hx` is plain Helix that doesn't know which board it runs on.

## See also

- [Targets](/projects/targets#without-an-os)
- [Compile Time](/language/comptime#per-target-code)
