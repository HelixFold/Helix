/*
 * `_start` for programs without an operating system (`--target <arch>-freestanding`): the first code that runs.
 * One core goes on (the others wait), with a stack at __stack_top and .bss zeroed (both from the linker script),
 * the FPU on, and a trap handler that reports a crash (hx_freestanding_trap, in freestanding.c) instead of
 * hanging; then main() runs. If it returns, the core halts (helix_halt).
 *
 *   riscv64   QEMU `virt` with -bios none starts every hart here, in machine mode
 *   aarch64   QEMU `virt` with -kernel starts here at EL1; the FPU and SIMD are switched on (the compiler uses them)
 *   x86_64    a bootloader (Limine, ...) that has already entered 64-bit mode jumps here
 */

    .section .text.start, "ax"
    .global _start

#if defined(__riscv) && __riscv_xlen == 64

_start:
    csrr    t0, mhartid
    bnez    t0, park
.option push
.option norelax
    la      gp, __global_pointer$
.option pop
    la      sp, __stack_top
    li      t0, (1 << 13)           // mstatus.FS = Initial: the FPU is off after reset, and the compiler uses it
    csrs    mstatus, t0
    la      t0, trap
    csrw    mtvec, t0
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:  li      a0, 0
    li      a1, 0
    call    main
    call    helix_halt
park:
    wfi
    j       park

    .balign 4
trap:                               // anything unexpected: report it (and stop)
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    la      sp, __stack_top
    call    hx_freestanding_trap

#elif defined(__aarch64__)

_start:
    mrs     x0, mpidr_el1
    and     x0, x0, #0xff
    cbnz    x0, park
    mov     x0, #(3 << 20)          // CPACR_EL1.FPEN: no traps for FP and SIMD
    msr     cpacr_el1, x0
    ldr     x0, =vectors
    msr     vbar_el1, x0
    isb
    ldr     x0, =__stack_top
    mov     sp, x0
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:  mov     x0, #0
    mov     x1, #0
    bl      main
    bl      helix_halt
park:
    wfe
    b       park

    // exception vectors: 16 entries of 128 bytes; every one reports the exception (and stops)
    .balign 2048
vectors:
    .rept 16
    .balign 128
    mrs     x0, esr_el1
    mrs     x1, elr_el1
    mrs     x2, far_el1
    ldr     x3, =__stack_top
    mov     sp, x3
    bl      hx_freestanding_trap
    .endr

#elif defined(__x86_64__)

_start:
    lea     __stack_top(%rip), %rsp
    lea     __bss_start(%rip), %rdi
    lea     __bss_end(%rip), %rcx
    sub     %rdi, %rcx
    xor     %eax, %eax
    cld
    rep stosb
    xor     %edi, %edi
    xor     %esi, %esi
    call    main
    call    helix_halt

#else
#error "no start code for this architecture yet"
#endif
