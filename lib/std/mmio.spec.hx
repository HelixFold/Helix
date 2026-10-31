/**
 * Imports
 */

import { Register, Register16, Register8, SystCsr, SystRvr, SystCvr, SysTick, SYSTICK } from "./mmio";

/**
 * Tests
 */

/**
 * The fields of a made-up register that the specs drive on ordinary memory.
 *
 * @remarks
 * Each value packs a field the way `helix translate-svd` does,
 * with the lowest bit in bits 0 to 7 and the width in bits 8 to 15.
 *
 * @since 1.0.0
 */

enum Field: u32 {
    /**
     * Bits 0 to 3.
     *
     * @since 1.0.0
     */

    Low = 0x0400,

    /**
     * Bit 5 alone.
     *
     * @since 1.0.0
     */

    Flag = 0x0105,

    /**
     * Bits 8 to 11, between two other fields.
     *
     * @since 1.0.0
     */

    Middle = 0x0408,

    /**
     * Bits 24 to 31.
     *
     * @since 1.0.0
     */

    High = 0x0818,

    /**
     * All 32 bits.
     *
     * @since 1.0.0
     */

    Whole = 0x2000,
}

describe("Register") {
    describe("read") {
        test("should read the word at its address") {
            let word: u32 = 0xDEAD_BEEF;
            const reg = Register<Field> { address: @intFromPtr(&word) };

            expect(reg.read()).toBe(0xDEAD_BEEF);
        }

        test("should see a change made behind its back") {
            let word: u32 = 1;
            const reg = Register<Field> { address: @intFromPtr(&word) };
            word = 2;

            expect(reg.read()).toBe(2);
        }
    }

    describe("write") {
        test("should store the whole word at its address") {
            let word: u32 = 0xFFFF_FFFF;
            const reg = Register<Field> { address: @intFromPtr(&word) };
            reg.write(0x1234_5678);

            expect(word).toBe(0x1234_5678);
        }
    }

    describe("get") {
        test("should shift a field down to bit 0") {
            let word: u32 = 0xAB00_0F25;
            const reg = Register<Field> { address: @intFromPtr(&word) };

            expect(reg.get(Field.Low)).toBe(5);
            expect(reg.get(Field.Flag)).toBe(1);
            expect(reg.get(Field.Middle)).toBe(0xF);
            expect(reg.get(Field.High)).toBe(0xAB);
        }

        test("should read the whole word for a field 32 bits wide") {
            let word: u32 = 0xDEAD_BEEF;
            const reg = Register<Field> { address: @intFromPtr(&word) };

            expect(reg.get(Field.Whole)).toBe(0xDEAD_BEEF);
        }
    }

    describe("modify") {
        test("should replace one field and keep the others") {
            let word: u32 = 0xFFFF_FFFF;
            const reg = Register<Field> { address: @intFromPtr(&word) };
            reg.modify(Field.Middle, 0x3);

            expect(word).toBe(0xFFFF_F3FF);
        }

        test("should drop the bits of a value that do not fit in the field") {
            let word: u32 = 0;
            const reg = Register<Field> { address: @intFromPtr(&word) };
            reg.modify(Field.Middle, 0x1F);

            expect(word).toBe(0x0000_0F00);
        }

        test("should write the whole word for a field 32 bits wide") {
            let word: u32 = 0x1111_1111;
            const reg = Register<Field> { address: @intFromPtr(&word) };
            reg.modify(Field.Whole, 0xCAFE_F00D);

            expect(word).toBe(0xCAFE_F00D);
        }
    }

    describe("set") {
        test("should fill one field with ones and keep the others") {
            let word: u32 = 0x0000_0001;
            const reg = Register<Field> { address: @intFromPtr(&word) };
            reg.set(Field.Flag);
            reg.set(Field.High);

            expect(word).toBe(0xFF00_0021);
        }
    }

    describe("clear") {
        test("should fill one field with zeros and keep the others") {
            let word: u32 = 0xFFFF_FFFF;
            const reg = Register<Field> { address: @intFromPtr(&word) };
            reg.clear(Field.Low);
            reg.clear(Field.Flag);

            expect(word).toBe(0xFFFF_FFD0);
        }
    }
}

describe("Register16") {
    describe("read") {
        test("should read 16 bits and widen them") {
            let halves: u16[2] = [0xBEEF, 0xDEAD];
            const reg = Register16<Field> { address: @intFromPtr(&halves[0]) };

            expect(reg.read()).toBe(0xBEEF);
        }
    }

    describe("write") {
        test("should store the low 16 bits and leave the next halfword alone") {
            let halves: u16[2] = [0, 0x5555];
            const reg = Register16<Field> { address: @intFromPtr(&halves[0]) };
            reg.write(0x1_2345);

            expect(halves[0]).toBe(0x2345);
            expect(halves[1]).toBe(0x5555);
        }
    }

    describe("get") {
        test("should shift a field down to bit 0") {
            let halves: u16[2] = [0x0A25, 0];
            const reg = Register16<Field> { address: @intFromPtr(&halves[0]) };

            expect(reg.get(Field.Low)).toBe(5);
            expect(reg.get(Field.Middle)).toBe(0xA);
        }
    }

    describe("modify") {
        test("should replace one field and keep the others") {
            let halves: u16[2] = [0xFFFF, 0x5555];
            const reg = Register16<Field> { address: @intFromPtr(&halves[0]) };
            reg.modify(Field.Middle, 0);

            expect(halves[0]).toBe(0xF0FF);
            expect(halves[1]).toBe(0x5555);
        }
    }

    describe("set") {
        test("should fill one field with ones") {
            let halves: u16[2] = [0, 0];
            const reg = Register16<Field> { address: @intFromPtr(&halves[0]) };
            reg.set(Field.Low);

            expect(halves[0]).toBe(0x000F);
        }

        test("should keep the next halfword when a field reaches past 16 bits") {
            let halves: u16[2] = [0, 0];
            const reg = Register16<Field> { address: @intFromPtr(&halves[0]) };
            reg.set(Field.Whole);

            expect(halves[0]).toBe(0xFFFF);
            expect(halves[1]).toBe(0);
        }
    }

    describe("clear") {
        test("should fill one field with zeros") {
            let halves: u16[2] = [0xFFFF, 0xFFFF];
            const reg = Register16<Field> { address: @intFromPtr(&halves[0]) };
            reg.clear(Field.Flag);

            expect(halves[0]).toBe(0xFFDF);
            expect(halves[1]).toBe(0xFFFF);
        }
    }
}

describe("Register8") {
    describe("read") {
        test("should read 8 bits and widen them") {
            let bytes: u8[2] = [0xEF, 0xBE];
            const reg = Register8<Field> { address: @intFromPtr(&bytes[0]) };

            expect(reg.read()).toBe(0xEF);
        }
    }

    describe("write") {
        test("should store the low 8 bits and leave the next byte alone") {
            let bytes: u8[2] = [0, 0x55];
            const reg = Register8<Field> { address: @intFromPtr(&bytes[0]) };
            reg.write(0x1234);

            expect(bytes[0]).toBe(0x34);
            expect(bytes[1]).toBe(0x55);
        }
    }

    describe("get") {
        test("should shift a field down to bit 0") {
            let bytes: u8[2] = [0x27, 0];
            const reg = Register8<Field> { address: @intFromPtr(&bytes[0]) };

            expect(reg.get(Field.Low)).toBe(7);
            expect(reg.get(Field.Flag)).toBe(1);
        }
    }

    describe("modify") {
        test("should replace one field and keep the others") {
            let bytes: u8[2] = [0xFF, 0x55];
            const reg = Register8<Field> { address: @intFromPtr(&bytes[0]) };
            reg.modify(Field.Low, 0x9);

            expect(bytes[0]).toBe(0xF9);
            expect(bytes[1]).toBe(0x55);
        }
    }

    describe("set") {
        test("should fill one field with ones") {
            let bytes: u8[2] = [0, 0];
            const reg = Register8<Field> { address: @intFromPtr(&bytes[0]) };
            reg.set(Field.Flag);

            expect(bytes[0]).toBe(0x20);
        }
    }

    describe("clear") {
        test("should fill one field with zeros") {
            let bytes: u8[2] = [0xFF, 0xFF];
            const reg = Register8<Field> { address: @intFromPtr(&bytes[0]) };
            reg.clear(Field.Low);

            expect(bytes[0]).toBe(0xF0);
            expect(bytes[1]).toBe(0xFF);
        }
    }
}

describe("SystCsr") {
    test("should place each field at its bit of the control register") {
        let word: u32 = 0;
        const csr = Register<SystCsr> { address: @intFromPtr(&word) };
        csr.set(SystCsr.ENABLE);
        csr.set(SystCsr.TICKINT);
        csr.set(SystCsr.CLKSOURCE);

        expect(word).toBe(0b111);
    }

    test("should read COUNTFLAG from bit 16") {
        let word: u32 = 0x0001_0000;
        const csr = Register<SystCsr> { address: @intFromPtr(&word) };

        expect(csr.get(SystCsr.COUNTFLAG)).toBe(1);
        expect(csr.get(SystCsr.ENABLE)).toBe(0);
    }
}

describe("SystRvr") {
    test("should cover the low 24 bits with RELOAD") {
        let word: u32 = 0xFF00_0000;
        const rvr = Register<SystRvr> { address: @intFromPtr(&word) };
        rvr.modify(SystRvr.RELOAD, 0xFFFF_FFFF);

        expect(word).toBe(0xFFFF_FFFF);
        expect(rvr.get(SystRvr.RELOAD)).toBe(0x00FF_FFFF);
    }
}

describe("SystCvr") {
    test("should cover the low 24 bits with CURRENT") {
        let word: u32 = 0xAB12_3456;
        const cvr = Register<SystCvr> { address: @intFromPtr(&word) };

        expect(cvr.get(SystCvr.CURRENT)).toBe(0x12_3456);
    }
}

describe("SysTick") {
    test("should drive its three registers on ordinary memory") {
        let words: u32[3] = [0, 0, 0];
        const timer = SysTick {
            CSR: Register<SystCsr> { address: @intFromPtr(&words[0]) },
            RVR: Register<SystRvr> { address: @intFromPtr(&words[1]) },
            CVR: Register<SystCvr> { address: @intFromPtr(&words[2]) },
        };
        timer.RVR.modify(SystRvr.RELOAD, 15_999);
        timer.CSR.set(SystCsr.ENABLE);

        expect(words[0]).toBe(1);
        expect(words[1]).toBe(15_999);
        expect(words[2]).toBe(0);
    }
}

describe("SYSTICK") {
    test("should point at the fixed SysTick addresses of the Cortex-M core") {
        expect(SYSTICK.CSR.address).toBe(0xE000_E010);
        expect(SYSTICK.RVR.address).toBe(0xE000_E014);
        expect(SYSTICK.CVR.address).toBe(0xE000_E018);
    }
}
