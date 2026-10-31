/*
 * The start of a Cortex-M program (`--target thumbv6m/thumbv7m/thumbv7em/thumbv8m.main-freestanding`): the vector
 * table the core reads at reset, and Reset_Handler. The core loads the stack pointer from the table's first word,
 * so all of it is C: copy .data from flash to RAM, zero .bss, switch the FPU on when the build uses it, run main.
 *
 * Every exception and interrupt has a handler a program can replace by defining it:
 *
 *   export extern "C" function SysTick_Handler(): void { ... }
 *   export extern "C" function IRQ28_Handler(): void { ... }      // interrupt 28 (TIM2 on an STM32F4)
 *
 * Those it doesn't define report themselves and halt: a fault prints its status registers and the address of the
 * instruction that caused it. The linker script (generated from the chip's memory, see build.md) defines
 * __stack_top, __data_load, __data_start, __data_end, __bss_start and __bss_end.
 */

#include <stdint.h>

extern uint32_t __stack_top, __data_load, __data_start, __data_end, __bss_start, __bss_end;
extern int main(int argc, char **argv);
extern void helix_halt(void) __attribute__((noreturn));
extern int dprintf(int fd, const char *fmt, ...);

#define REG(address) (*(volatile uint32_t *)(address))
#define SCB_CPACR REG(0xE000ED88)       // coprocessor access: the FPU
#define SCB_ICSR REG(0xE000ED04)        // the active exception's number
#define SCB_CFSR REG(0xE000ED28)        // what a fault was (ARMv7-M and later)
#define SCB_HFSR REG(0xE000ED2C)
#define SCB_BFAR REG(0xE000ED38)        // the address a bus fault was about

__attribute__((noreturn)) void Reset_Handler(void) {
    uint32_t *from = &__data_load;
    for (uint32_t *to = &__data_start; to < &__data_end;) *to++ = *from++;
    for (uint32_t *p = &__bss_start; p < &__bss_end;) *p++ = 0;
#if defined(__ARM_FP)
    SCB_CPACR |= 0xFu << 20;   // CP10, CP11: full access, so float instructions don't fault
    __asm__ volatile("dsb\n\tisb");
#endif
    main(0, 0);
    helix_halt();
}

/** An exception or interrupt nothing handles: which one it was, then halt. */
__attribute__((noreturn)) void Default_Handler(void) {
    uint32_t number = SCB_ICSR & 0x1FF;
    if (number >= 16) dprintf(2, "\nunhandled interrupt: IRQ%lu (define IRQ%lu_Handler)\n", (unsigned long)(number - 16), (unsigned long)(number - 16));
    else dprintf(2, "\nunhandled exception %lu\n", (unsigned long)number);
    helix_halt();
}

/** A fault: the frame the core pushed (r0-r3, r12, lr, pc, xpsr) tells where it happened. */
__attribute__((noreturn, used)) void hx_cortex_m_fault(uint32_t *frame) {
#if __ARM_ARCH >= 7
    dprintf(2, "\nhard fault at pc 0x%08lx (CFSR 0x%08lx, HFSR 0x%08lx, BFAR 0x%08lx)\n", (unsigned long)frame[6],
            (unsigned long)SCB_CFSR, (unsigned long)SCB_HFSR, (unsigned long)SCB_BFAR);
#else
    dprintf(2, "\nhard fault at pc 0x%08lx\n", (unsigned long)frame[6]);
#endif
    helix_halt();
}

/** Finds the stacked frame (main or process stack, from EXC_RETURN in lr) in instructions every Cortex-M has. */
__attribute__((naked)) void HardFault_Handler(void) {
    __asm__ volatile(
        "movs r1, #4\n\t"
        "mov r2, lr\n\t"
        "tst r2, r1\n\t"
        "beq 1f\n\t"
        "mrs r0, psp\n\t"
        "b 2f\n"
        "1:\n\t"
        "mrs r0, msp\n"
        "2:\n\t"
        "ldr r1, =hx_cortex_m_fault\n\t"
        "bx r1\n\t"
        ".ltorg");
}

#define WEAK(name) void name(void) __attribute__((weak, alias("Default_Handler")));
WEAK(NMI_Handler)
WEAK(MemManage_Handler)
WEAK(BusFault_Handler)
WEAK(UsageFault_Handler)
WEAK(SecureFault_Handler)
WEAK(SVC_Handler)
WEAK(DebugMon_Handler)
WEAK(PendSV_Handler)
WEAK(SysTick_Handler)

/* IRQ0_Handler ... IRQ239_Handler: 240 interrupts, the most a Cortex-M has */
#define IRQ(n) WEAK(IRQ##n##_Handler)
#define IRQ10(t) IRQ(t##0) IRQ(t##1) IRQ(t##2) IRQ(t##3) IRQ(t##4) IRQ(t##5) IRQ(t##6) IRQ(t##7) IRQ(t##8) IRQ(t##9)
#define IRQS                                                                                                   \
    IRQ10() IRQ10(1) IRQ10(2) IRQ10(3) IRQ10(4) IRQ10(5) IRQ10(6) IRQ10(7) IRQ10(8) IRQ10(9) IRQ10(10) IRQ10(11)     \
    IRQ10(12) IRQ10(13) IRQ10(14) IRQ10(15) IRQ10(16) IRQ10(17) IRQ10(18) IRQ10(19) IRQ10(20) IRQ10(21) IRQ10(22) \
    IRQ10(23)
IRQS
#undef IRQ
#define IRQ(n) IRQ##n##_Handler,

typedef void (*Vector)(void);

__attribute__((section(".vectors"), used)) const Vector hx_vectors[16 + 240] = {
    (Vector)&__stack_top,
    Reset_Handler,
    NMI_Handler,
    HardFault_Handler,
    MemManage_Handler,
    BusFault_Handler,
    UsageFault_Handler,
    SecureFault_Handler,
    0,
    0,
    0,
    SVC_Handler,
    DebugMon_Handler,
    0,
    PendSV_Handler,
    SysTick_Handler,
    IRQS
};
