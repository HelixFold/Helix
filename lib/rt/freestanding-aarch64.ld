/*
 * The default memory layout of `--target aarch64-freestanding` programs: QEMU virt: RAM starts at 0x40000000, where QEMU puts the device tree; the program goes after it.
 * Another board takes its own script: `--linker-script board.ld`, or `linkerScript` in build.hx. A script must
 * define __stack_top, __bss_start and __bss_end for the start code (lib/rt/freestanding_start.S).
 */
ENTRY(_start)

SECTIONS
{
    . = 0x40080000;
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    }
    .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) }
    .data : ALIGN(16) {
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    }
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }
    . = ALIGN(16);
    . += 64K;
    __stack_top = .;
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame*) }
}
