/**
 * Imports
 */

import { Arch, Os, Target, target } from "./target";

/**
 * Tests
 */

describe("Os") {
    test("should number the systems in declaration order") {
        expect(@enumFromInt(Os, 0) == Os.Macos).toBeTrue();
        expect(@enumFromInt(Os, 3) == Os.Wasi).toBeTrue();
        expect(@enumFromInt(Os, 4) == Os.Freestanding).toBeTrue();
    }
}

describe("Arch") {
    test("should number the processors in declaration order") {
        expect(@enumFromInt(Arch, 0) == Arch.X86_64).toBeTrue();
        expect(@enumFromInt(Arch, 5) == Arch.Thumb).toBeTrue();
    }
}

describe("Target") {
    test("should hold a system, a processor, and a pointer size") {
        const other = Target { os: Os.Linux, arch: Arch.Riscv64, pointerBits: 64 };

        expect(other.os == Os.Linux).toBeTrue();
        expect(other.arch == Arch.Riscv64).toBeTrue();
        expect(other.pointerBits).toBe(64);
    }
}

describe("target") {
    test("should give the pointer size of the build") {
        expect(target.pointerBits).toBe(@sizeOf(usize) * 8);
    }

    test("should compile only the branch that a comptime check takes") {
        let branch: i32 = 0;
        if (comptime target.os == Os.Windows) {
            branch = 1;
        } else {
            branch = 2;
        }

        expect(branch).toBe(2);
    }
}
