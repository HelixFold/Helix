/**
 * Builds the mask of a field from its packed description.
 *
 * @param field - The field, with its lowest bit in bits 0 to 7 and its width in bits 8 to 15
 * @returns The mask, with a 1 in every bit of the field at its place in the register
 *
 * @remarks
 * A width of 32 or more gives a mask of all ones, since shifting a `u32` by 32 would overflow.
 * A width of 0 gives an empty mask.
 *
 * @since 1.0.0
 */

function maskOf(field: u32): u32 {
    const width = (field >> 8) & 0xFF;
    const ones: u32 = width >= 32 ? 0xFFFF_FFFF : ((1 as u32) << width) - 1;
    return ones << (field & 0xFF);
}

/**
 * A 32-bit memory-mapped register of a peripheral.
 *
 * @typeParam F - The enum of the fields of the register, each value packing the position and the width of one field
 *
 * @remarks
 * `helix translate-svd` describes the peripherals of a microcontroller as structs of these registers,
 * so a program reaches a register as `RCC.AHB1ENR` and a field as a member of the enum `F`.
 * Each member of `F` packs the field into one number:
 * bits 0 to 7 hold the lowest bit of the field, and bits 8 to 15 hold its width.
 * So `0x0405` is a field of 4 bits that starts at bit 5, and `0x2000` is the whole register.
 * Every access is a volatile 32-bit load or store at `address`, so the compiler never merges or drops one.
 * The field methods each do one read, one write, or a read followed by a write,
 * so they are not atomic against an interrupt handler that writes the same register.
 *
 * @example
 * ```hx
 * const DR = Register<UartDr> { address: 0x4001_1004 };
 * DR.write(0x41);        // stores 0x41 at 0x4001_1004
 * DR.get(UartDr.DATA);   // 0x41 when the peripheral reads it back
 * ```
 *
 * @since 1.0.0
 */

export struct Register<F> {
    /**
     * The address of the register in the memory map.
     *
     * @remarks
     * `helix translate-svd` fills it in from the base address of the peripheral plus the offset of the register.
     *
     * @example
     * ```hx
     * Register<UartDr> { address: 0x4001_1004 }.address; // 0x4001_1004
     * ```
     *
     * @since 1.0.0
     */

    address: usize,

    /**
     * Reads the whole register.
     *
     * @param this - The register to read
     * @returns The value of the register
     *
     * @remarks
     * It is one volatile `u32` load, so reading a register that clears its flags on a read clears them every time.
     *
     * @example
     * ```hx
     * USART1.SR.read(); // 0xC0 with TXE and TC set
     * ```
     *
     * @since 1.0.0
     */

    read(this: Register<F>): u32 {
        unsafe {
            return @volatileLoad(@ptrFromInt(*u32, this.address));
        }
    }

    /**
     * Writes the whole register.
     *
     * @param this - The register to write
     * @param value - The new value of every bit
     *
     * @remarks
     * It is one volatile `u32` store and reads nothing first, so every field that `value` leaves at 0 becomes 0.
     * Use {@link Register.modify} to change one field and keep the rest.
     *
     * @example
     * ```hx
     * USART1.DR.write(0x41);
     * USART1.DR.read(); // 0x41
     * ```
     *
     * @since 1.0.0
     */

    write(this: Register<F>, value: u32): void {
        unsafe {
            @volatileStore(@ptrFromInt(*u32, this.address), value);
        }
    }

    /**
     * Reads one field of the register.
     *
     * @param this - The register to read
     * @param field - The field to read
     * @returns The value of the field, shifted down to bit 0
     *
     * @remarks
     * It reads the whole register once, masks out the other fields, and shifts the field down to bit 0.
     *
     * @example
     * ```hx
     * while (USART1.SR.get(UsartSr.TXE) == 0) {}   // waits until the transmitter is free
     * GPIOA.MODER.get(GpioaModer.MODER9);          // 2
     * ```
     *
     * @since 1.0.0
     */

    get(this: Register<F>, field: F): u32 {
        const f = field as u32;
        return (this.read() & maskOf(f)) >> (f & 0xFF);
    }

    /**
     * Sets one field of the register to a value and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to set
     * @param value - The new value of the field, counted from bit 0 of the field
     *
     * @remarks
     * It reads the register, replaces the bits of the field, and writes the result back.
     * Bits of `value` that do not fit in the field are dropped, so they never spill into the next field.
     *
     * @example
     * ```hx
     * GPIOA.MODER.modify(GpioaModer.MODER9, 2);   // pin 9 to its alternate function
     * GPIOA.MODER.get(GpioaModer.MODER9);         // 2
     * ```
     *
     * @since 1.0.0
     */

    modify(this: Register<F>, field: F, value: u32): void {
        const f = field as u32;
        this.write((this.read() & ~maskOf(f)) | ((value << (f & 0xFF)) & maskOf(f)));
    }

    /**
     * Sets every bit of one field to 1 and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to fill with ones
     *
     * @remarks
     * For a one-bit field this turns the field on.
     * It reads the register and writes it back, so it suits ordinary fields and not write-1-to-clear flags,
     * which the write back would also clear.
     *
     * @example
     * ```hx
     * RCC.AHB1ENR.set(RccAhb1enr.GPIOAEN);
     * RCC.AHB1ENR.get(RccAhb1enr.GPIOAEN); // 1
     * ```
     *
     * @since 1.0.0
     */

    set(this: Register<F>, field: F): void {
        this.write(this.read() | maskOf(field as u32));
    }

    /**
     * Sets every bit of one field to 0 and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to fill with zeros
     *
     * @remarks
     * For a one-bit field this turns the field off.
     * Like {@link Register.set}, it reads the register and writes it back.
     *
     * @example
     * ```hx
     * RCC.AHB1ENR.clear(RccAhb1enr.GPIOAEN);
     * RCC.AHB1ENR.get(RccAhb1enr.GPIOAEN); // 0
     * ```
     *
     * @since 1.0.0
     */

    clear(this: Register<F>, field: F): void {
        this.write(this.read() & ~maskOf(field as u32));
    }
}

/**
 * A 16-bit memory-mapped register of a peripheral.
 *
 * @typeParam F - The enum of the fields of the register, each value packing the position and the width of one field
 *
 * @remarks
 * Some peripherals accept only accesses of the width of their registers,
 * and a 32-bit access there faults or touches a neighboring register.
 * This struct does every access as 16 bits and otherwise works like {@link Register},
 * with the same packing of fields in `F` and the same `u32` values in the methods.
 * Every access is a volatile 16-bit load or store at `address`, so the compiler never merges or drops one.
 * The field methods each do one read, one write, or a read followed by a write,
 * so they are not atomic against an interrupt handler that writes the same register.
 *
 * @example
 * ```hx
 * const DR = Register16<UartDr> { address: 0x4001_1004 };
 * DR.write(0x41);        // stores 0x41 at 0x4001_1004
 * DR.get(UartDr.DATA);   // 0x41 when the peripheral reads it back
 * ```
 *
 * @since 1.0.0
 */

export struct Register16<F> {
    /**
     * The address of the register in the memory map.
     *
     * @remarks
     * `helix translate-svd` fills it in from the base address of the peripheral plus the offset of the register.
     *
     * @example
     * ```hx
     * Register16<UartDr> { address: 0x4001_1004 }.address; // 0x4001_1004
     * ```
     *
     * @since 1.0.0
     */

    address: usize,

    /**
     * Reads the whole register.
     *
     * @param this - The register to read
     * @returns The value of the register, widened to `u32`
     *
     * @remarks
     * It is one volatile `u16` load, so reading a register that clears its flags on a read clears them every time.
     *
     * @example
     * ```hx
     * USART1.SR.read(); // 0xC0 with TXE and TC set
     * ```
     *
     * @since 1.0.0
     */

    read(this: Register16<F>): u32 {
        unsafe {
            return @volatileLoad(@ptrFromInt(*u16, this.address)) as u32;
        }
    }

    /**
     * Writes the whole register.
     *
     * @param this - The register to write
     * @param value - The new value of every bit, of which only the low 16 bits reach the register
     *
     * @remarks
     * It is one volatile `u16` store and reads nothing first, so every field that `value` leaves at 0 becomes 0.
     * Use {@link Register16.modify} to change one field and keep the rest.
     *
     * @example
     * ```hx
     * USART1.DR.write(0x41);
     * USART1.DR.read(); // 0x41
     * ```
     *
     * @since 1.0.0
     */

    write(this: Register16<F>, value: u32): void {
        unsafe {
            @volatileStore(@ptrFromInt(*u16, this.address), @truncate(u16, value));
        }
    }

    /**
     * Reads one field of the register.
     *
     * @param this - The register to read
     * @param field - The field to read
     * @returns The value of the field, shifted down to bit 0
     *
     * @remarks
     * It reads the whole register once, masks out the other fields, and shifts the field down to bit 0.
     *
     * @example
     * ```hx
     * while (USART1.SR.get(UsartSr.TXE) == 0) {}   // waits until the transmitter is free
     * GPIOA.MODER.get(GpioaModer.MODER9);          // 2
     * ```
     *
     * @since 1.0.0
     */

    get(this: Register16<F>, field: F): u32 {
        const f = field as u32;
        return (this.read() & maskOf(f)) >> (f & 0xFF);
    }

    /**
     * Sets one field of the register to a value and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to set
     * @param value - The new value of the field, counted from bit 0 of the field
     *
     * @remarks
     * It reads the register, replaces the bits of the field, and writes the result back.
     * Bits of `value` that do not fit in the field are dropped, so they never spill into the next field.
     *
     * @example
     * ```hx
     * GPIOA.MODER.modify(GpioaModer.MODER9, 2);   // pin 9 to its alternate function
     * GPIOA.MODER.get(GpioaModer.MODER9);         // 2
     * ```
     *
     * @since 1.0.0
     */

    modify(this: Register16<F>, field: F, value: u32): void {
        const f = field as u32;
        this.write((this.read() & ~maskOf(f)) | ((value << (f & 0xFF)) & maskOf(f)));
    }

    /**
     * Sets every bit of one field to 1 and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to fill with ones
     *
     * @remarks
     * For a one-bit field this turns the field on.
     * It reads the register and writes it back, so it suits ordinary fields and not write-1-to-clear flags,
     * which the write back would also clear.
     *
     * @example
     * ```hx
     * RCC.AHB1ENR.set(RccAhb1enr.GPIOAEN);
     * RCC.AHB1ENR.get(RccAhb1enr.GPIOAEN); // 1
     * ```
     *
     * @since 1.0.0
     */

    set(this: Register16<F>, field: F): void {
        this.write(this.read() | maskOf(field as u32));
    }

    /**
     * Sets every bit of one field to 0 and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to fill with zeros
     *
     * @remarks
     * For a one-bit field this turns the field off.
     * Like {@link Register16.set}, it reads the register and writes it back.
     *
     * @example
     * ```hx
     * RCC.AHB1ENR.clear(RccAhb1enr.GPIOAEN);
     * RCC.AHB1ENR.get(RccAhb1enr.GPIOAEN); // 0
     * ```
     *
     * @since 1.0.0
     */

    clear(this: Register16<F>, field: F): void {
        this.write(this.read() & ~maskOf(field as u32));
    }
}

/**
 * An 8-bit memory-mapped register of a peripheral.
 *
 * @typeParam F - The enum of the fields of the register, each value packing the position and the width of one field
 *
 * @remarks
 * Some peripherals accept only accesses of the width of their registers,
 * and a 32-bit access there faults or touches a neighboring register.
 * This struct does every access as 8 bits and otherwise works like {@link Register},
 * with the same packing of fields in `F` and the same `u32` values in the methods.
 * Every access is a volatile 8-bit load or store at `address`, so the compiler never merges or drops one.
 * The field methods each do one read, one write, or a read followed by a write,
 * so they are not atomic against an interrupt handler that writes the same register.
 *
 * @example
 * ```hx
 * const DR = Register8<UartDr> { address: 0x4001_1004 };
 * DR.write(0x41);        // stores 0x41 at 0x4001_1004
 * DR.get(UartDr.DATA);   // 0x41 when the peripheral reads it back
 * ```
 *
 * @since 1.0.0
 */

export struct Register8<F> {
    /**
     * The address of the register in the memory map.
     *
     * @remarks
     * `helix translate-svd` fills it in from the base address of the peripheral plus the offset of the register.
     *
     * @example
     * ```hx
     * Register8<UartDr> { address: 0x4001_1004 }.address; // 0x4001_1004
     * ```
     *
     * @since 1.0.0
     */

    address: usize,

    /**
     * Reads the whole register.
     *
     * @param this - The register to read
     * @returns The value of the register, widened to `u32`
     *
     * @remarks
     * It is one volatile `u8` load, so reading a register that clears its flags on a read clears them every time.
     *
     * @example
     * ```hx
     * USART1.SR.read(); // 0xC0 with TXE and TC set
     * ```
     *
     * @since 1.0.0
     */

    read(this: Register8<F>): u32 {
        unsafe {
            return @volatileLoad(@ptrFromInt(*u8, this.address)) as u32;
        }
    }

    /**
     * Writes the whole register.
     *
     * @param this - The register to write
     * @param value - The new value of every bit, of which only the low 8 bits reach the register
     *
     * @remarks
     * It is one volatile `u8` store and reads nothing first, so every field that `value` leaves at 0 becomes 0.
     * Use {@link Register8.modify} to change one field and keep the rest.
     *
     * @example
     * ```hx
     * USART1.DR.write(0x41);
     * USART1.DR.read(); // 0x41
     * ```
     *
     * @since 1.0.0
     */

    write(this: Register8<F>, value: u32): void {
        unsafe {
            @volatileStore(@ptrFromInt(*u8, this.address), @truncate(u8, value));
        }
    }

    /**
     * Reads one field of the register.
     *
     * @param this - The register to read
     * @param field - The field to read
     * @returns The value of the field, shifted down to bit 0
     *
     * @remarks
     * It reads the whole register once, masks out the other fields, and shifts the field down to bit 0.
     *
     * @example
     * ```hx
     * while (USART1.SR.get(UsartSr.TXE) == 0) {}   // waits until the transmitter is free
     * GPIOA.MODER.get(GpioaModer.MODER9);          // 2
     * ```
     *
     * @since 1.0.0
     */

    get(this: Register8<F>, field: F): u32 {
        const f = field as u32;
        return (this.read() & maskOf(f)) >> (f & 0xFF);
    }

    /**
     * Sets one field of the register to a value and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to set
     * @param value - The new value of the field, counted from bit 0 of the field
     *
     * @remarks
     * It reads the register, replaces the bits of the field, and writes the result back.
     * Bits of `value` that do not fit in the field are dropped, so they never spill into the next field.
     *
     * @example
     * ```hx
     * GPIOA.MODER.modify(GpioaModer.MODER9, 2);   // pin 9 to its alternate function
     * GPIOA.MODER.get(GpioaModer.MODER9);         // 2
     * ```
     *
     * @since 1.0.0
     */

    modify(this: Register8<F>, field: F, value: u32): void {
        const f = field as u32;
        this.write((this.read() & ~maskOf(f)) | ((value << (f & 0xFF)) & maskOf(f)));
    }

    /**
     * Sets every bit of one field to 1 and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to fill with ones
     *
     * @remarks
     * For a one-bit field this turns the field on.
     * It reads the register and writes it back, so it suits ordinary fields and not write-1-to-clear flags,
     * which the write back would also clear.
     *
     * @example
     * ```hx
     * RCC.AHB1ENR.set(RccAhb1enr.GPIOAEN);
     * RCC.AHB1ENR.get(RccAhb1enr.GPIOAEN); // 1
     * ```
     *
     * @since 1.0.0
     */

    set(this: Register8<F>, field: F): void {
        this.write(this.read() | maskOf(field as u32));
    }

    /**
     * Sets every bit of one field to 0 and keeps every other field.
     *
     * @param this - The register to change
     * @param field - The field to fill with zeros
     *
     * @remarks
     * For a one-bit field this turns the field off.
     * Like {@link Register8.set}, it reads the register and writes it back.
     *
     * @example
     * ```hx
     * RCC.AHB1ENR.clear(RccAhb1enr.GPIOAEN);
     * RCC.AHB1ENR.get(RccAhb1enr.GPIOAEN); // 0
     * ```
     *
     * @since 1.0.0
     */

    clear(this: Register8<F>, field: F): void {
        this.write(this.read() & ~maskOf(field as u32));
    }
}

/**
 * The address of the first NVIC set-enable register.
 *
 * @remarks
 * Writing a 1 to a bit enables the matching interrupt, and writing a 0 has no effect.
 *
 * @since 1.0.0
 */

const NvicSetEnable: usize = 0xE000_E100;

/**
 * The address of the first NVIC clear-enable register.
 *
 * @remarks
 * Writing a 1 to a bit disables the matching interrupt, and writing a 0 has no effect.
 *
 * @since 1.0.0
 */

const NvicClearEnable: usize = 0xE000_E180;

/**
 * The address of the first NVIC set-pending register.
 *
 * @remarks
 * Writing a 1 to a bit marks the matching interrupt as pending, and writing a 0 has no effect.
 *
 * @since 1.0.0
 */

const NvicSetPending: usize = 0xE000_E200;

/**
 * The address of the first NVIC clear-pending register.
 *
 * @remarks
 * Writing a 1 to a bit removes the pending state of the matching interrupt, and writing a 0 has no effect.
 *
 * @since 1.0.0
 */

const NvicClearPending: usize = 0xE000_E280;

/**
 * Writes the bit of one interrupt into a bank of NVIC registers.
 *
 * @param bank - The address of the first register of the bank
 * @param n - The number of the interrupt
 *
 * @remarks
 * Each 32-bit register of the Cortex-M interrupt controller covers 32 interrupts,
 * so interrupt `n` is bit `n % 32` of the register at `bank + (n / 32) * 4`.
 * It stores only that bit, which works because these registers ignore the zeros in a write.
 *
 * @since 1.0.0
 */

function nvicBit(bank: usize, n: u32): void {
    unsafe {
        @volatileStore(@ptrFromInt(*u32, bank + ((n / 32) as usize) * 4), (1 as u32) << (n % 32));
    }
}

/**
 * Enables an interrupt in the Cortex-M interrupt controller.
 *
 * @param n - The number of the interrupt
 *
 * @remarks
 * Once enabled, the interrupt runs its handler, `IRQ<n>_Handler`, when it fires.
 * Modules that `helix translate-svd` generates wrap this with the names of the interrupts of the chip.
 *
 * @example
 * ```hx
 * nvicEnable(37);   // USART1 on an STM32F411, which now runs IRQ37_Handler
 * ```
 *
 * @see nvicDisable
 * @since 1.0.0
 */

export function nvicEnable(n: u32): void {
    nvicBit(NvicSetEnable, n);
}

/**
 * Disables an interrupt in the Cortex-M interrupt controller.
 *
 * @param n - The number of the interrupt
 *
 * @remarks
 * The interrupt can still become pending while disabled, and its handler runs once {@link nvicEnable} enables it again.
 *
 * @example
 * ```hx
 * nvicDisable(37);   // USART1 on an STM32F411 stops running IRQ37_Handler
 * ```
 *
 * @see nvicEnable
 * @since 1.0.0
 */

export function nvicDisable(n: u32): void {
    nvicBit(NvicClearEnable, n);
}

/**
 * Raises an interrupt from software.
 *
 * @param n - The number of the interrupt
 *
 * @remarks
 * The interrupt becomes pending as if its peripheral had fired, and its handler runs as soon as it is enabled.
 *
 * @example
 * ```hx
 * nvicSetPending(37);   // IRQ37_Handler runs next, if interrupt 37 is enabled
 * ```
 *
 * @see nvicClearPending
 * @since 1.0.0
 */

export function nvicSetPending(n: u32): void {
    nvicBit(NvicSetPending, n);
}

/**
 * Removes the pending state of an interrupt.
 *
 * @param n - The number of the interrupt
 *
 * @remarks
 * An interrupt that fired while disabled stays pending, and clearing it keeps the handler from running once enabled.
 *
 * @example
 * ```hx
 * nvicClearPending(37);   // a pending USART1 interrupt no longer runs IRQ37_Handler
 * ```
 *
 * @see nvicSetPending
 * @since 1.0.0
 */

export function nvicClearPending(n: u32): void {
    nvicBit(NvicClearPending, n);
}

/**
 * The fields of the SysTick control and status register.
 *
 * @remarks
 * Each value packs a field like the enums of {@link Register},
 * with the lowest bit in bits 0 to 7 and the width in bits 8 to 15.
 *
 * @example
 * ```hx
 * SYSTICK.CSR.set(SystCsr.ENABLE);
 * SYSTICK.CSR.get(SystCsr.ENABLE); // 1
 * ```
 *
 * @since 1.0.0
 */

export enum SystCsr: u32 {
    /**
     * Bit 0, which starts and stops the counter.
     *
     * @example
     * ```hx
     * SYSTICK.CSR.set(SystCsr.ENABLE);   // the counter starts counting down
     * ```
     *
     * @since 1.0.0
     */

    ENABLE = 0x0100,

    /**
     * Bit 1, which raises an interrupt each time the counter wraps.
     *
     * @remarks
     * The interrupt runs `SysTick_Handler`.
     *
     * @example
     * ```hx
     * SYSTICK.CSR.set(SystCsr.TICKINT);   // SysTick_Handler runs at each wrap
     * ```
     *
     * @since 1.0.0
     */

    TICKINT = 0x0101,

    /**
     * Bit 2, which picks the clock of the processor over the slower reference clock.
     *
     * @example
     * ```hx
     * SYSTICK.CSR.set(SystCsr.CLKSOURCE);   // counts at the processor clock
     * ```
     *
     * @since 1.0.0
     */

    CLKSOURCE = 0x0102,

    /**
     * Bit 16, which reads 1 when the counter wrapped since the last read of the register.
     *
     * @remarks
     * Reading the register clears it.
     *
     * @example
     * ```hx
     * while (SYSTICK.CSR.get(SystCsr.COUNTFLAG) == 0) {}   // waits for the next wrap
     * ```
     *
     * @since 1.0.0
     */

    COUNTFLAG = 0x0110,
}

/**
 * The field of the SysTick reload value register.
 *
 * @example
 * ```hx
 * SYSTICK.RVR.modify(SystRvr.RELOAD, 15_999);
 * SYSTICK.RVR.get(SystRvr.RELOAD); // 15999
 * ```
 *
 * @since 1.0.0
 */

export enum SystRvr: u32 {
    /**
     * Bits 0 to 23, the value that the counter starts from after each wrap.
     *
     * @remarks
     * The counter counts down from this value to 0, so a wrap comes every `RELOAD + 1` ticks.
     *
     * @example
     * ```hx
     * SYSTICK.RVR.modify(SystRvr.RELOAD, 15_999);   // a wrap every millisecond at 16 MHz
     * ```
     *
     * @since 1.0.0
     */

    RELOAD = 0x1800,
}

/**
 * The field of the SysTick current value register.
 *
 * @example
 * ```hx
 * SYSTICK.CVR.get(SystCvr.CURRENT); // 9000 while counting down from 15999
 * ```
 *
 * @since 1.0.0
 */

export enum SystCvr: u32 {
    /**
     * Bits 0 to 23, the value of the counter right now.
     *
     * @remarks
     * Any write sets the counter to 0 and clears `COUNTFLAG`.
     *
     * @example
     * ```hx
     * SYSTICK.CVR.write(0);   // restarts the count from RELOAD on the next tick
     * ```
     *
     * @since 1.0.0
     */

    CURRENT = 0x1800,
}

/**
 * The SysTick timer that every Cortex-M core has.
 *
 * @remarks
 * The timer belongs to the core and not to the chip, so the SVD files of chips leave it out,
 * and this module describes it instead.
 * It counts down from its reload value to 0 and can raise an interrupt at each wrap.
 *
 * @example
 * ```hx
 * SYSTICK.RVR.modify(SystRvr.RELOAD, 15_999);
 * SYSTICK.CVR.write(0);
 * SYSTICK.CSR.write(0b111);   // ENABLE, TICKINT, and CLKSOURCE
 * ```
 *
 * @see SYSTICK
 * @since 1.0.0
 */

export struct SysTick {
    /**
     * The control and status register.
     *
     * @example
     * ```hx
     * SYSTICK.CSR.address; // 0xE000_E010
     * ```
     *
     * @since 1.0.0
     */

    CSR: Register<SystCsr>,

    /**
     * The reload value register.
     *
     * @example
     * ```hx
     * SYSTICK.RVR.address; // 0xE000_E014
     * ```
     *
     * @since 1.0.0
     */

    RVR: Register<SystRvr>,

    /**
     * The current value register.
     *
     * @example
     * ```hx
     * SYSTICK.CVR.address; // 0xE000_E018
     * ```
     *
     * @since 1.0.0
     */

    CVR: Register<SystCvr>,
}

/**
 * The SysTick timer of the core, at its fixed addresses.
 *
 * @remarks
 * Every Cortex-M core puts the timer at `0xE000_E010`, so these addresses hold on every chip.
 *
 * @example
 * ```hx
 * SYSTICK.CSR.set(SystCsr.ENABLE);
 * SYSTICK.CSR.address; // 0xE000_E010
 * ```
 *
 * @see SysTick
 * @since 1.0.0
 */

export const SYSTICK: SysTick = SysTick {
    CSR: Register<SystCsr> { address: 0xE000_E010 },
    RVR: Register<SystRvr> { address: 0xE000_E014 },
    CVR: Register<SystCvr> { address: 0xE000_E018 },
};
