/**
 * Imports
 */

import * as fmt from "std/fmt";
import { cAllocator } from "std";
import { endsWith, indexOf, startsWith } from "std/text";
import { clangResourceDir } from "@modules/driver/components/libc.component";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { macosSdk, macosVersion } from "@modules/driver/components/libc.component";
import { strings, exists, getenv, allocCString } from "@modules/driver/components/os.component";
import { lldLibDir, hostPlatform, bareMetalFlags } from "@modules/driver/components/libc.component";
import { appleLinker, bareMetal, libcEnsure, llvmTool, findTool } from "@modules/driver/components/libc.component";

/**
 * Tests
 */

/**
 * The items of a list of strings, joined with one space.
 *
 * @param list - The list to join
 * @returns The items with a space between each pair, or an empty string for an empty list
 *
 * @remarks
 * It lets a case compare a whole flag list with one expectation.
 *
 * @since 1.0.0
 */

function joined(list: readonly *Strings): string {
    let b = fmt.Builder.init(cAllocator());
    for (const item, i of list.items) b.append(`${i > 0 ? " " : ""}${item}`) catch unreachable;
    return b.text();
}

/**
 * The flags that {@link bareMetalFlags} adds for a triple to an empty list.
 *
 * @param triple - The LLVM triple of the target
 * @returns The flags, joined with one space
 *
 * @remarks
 * A triple that needs no flags of its own gives an empty string.
 *
 * @since 1.0.0
 */

function flagsFor(triple: string): string {
    let flags = strings();
    bareMetalFlags(&flags, triple);
    return joined(&flags);
}

describe("llvmTool") {
    test("should find clang next to the libclang that the compiler links") {
        const clang = llvmTool("clang") ?? "";

        expect(endsWith(clang, "/bin/clang")).toBeTrue();
    }

    test("should give null for a tool that the LLVM folder lacks") {
        expect(llvmTool("helix-no-such-tool")).toBeNull();
    }
}

describe("findTool") {
    test("should prefer the tool next to the LLVM that the compiler links") {
        expect(findTool("clang") ?? "").toBe(llvmTool("clang") ?? "?");
    }

    test("should give null for a tool that is nowhere") {
        expect(findTool("helix-no-such-tool")).toBeNull();
    }
}

describe("hostPlatform") {
    test("should name the platform as a toolchain folder is named") {
        const platform = hostPlatform();

        expect(endsWith(platform, "-macos") || endsWith(platform, "-linux") || endsWith(platform, "-windows")).toBeTrue();
        expect(startsWith(platform, "x86_64-") || startsWith(platform, "aarch64-")).toBeTrue();
    }
}

describe("lldLibDir") {
    test("should give a folder that holds lld's libraries, when it finds one") {
        if (const dir = lldLibDir()) {
            const archive = exists(allocCString(`${dir}/liblldCommon.a`));
            const shared = exists(allocCString(`${dir}/liblldCommon.dylib`));

            expect(archive || shared).toBeTrue();
        }
    }
}

/**
 * Whether this machine runs macOS.
 *
 * @returns `true` when the system version file of macOS exists
 *
 * @remarks
 * Only a Mac has a macOS version, and only a Mac or a machine with `SDKROOT` set has an SDK,
 * so the cases for them expect a value there and `null` on any other machine.
 *
 * @since 1.0.0
 */

function onMac(): bool {
    return exists("/System/Library/CoreServices/SystemVersion.plist");
}

describe("appleLinker") {
    test("should find the ld of the command-line tools or of Xcode") {
        expect(endsWith(appleLinker() ?? "/usr/bin/ld", "/usr/bin/ld")).toBeTrue();
    }
}

describe("macosSdk") {
    test("should find an SDK with the version from its settings file on a Mac or through SDKROOT") {
        const sdk = macosSdk();

        expect(sdk != null).toBe(onMac() || getenv("SDKROOT") != null);
        if (const found = sdk) {
            expect(endsWith(found.path, ".sdk")).toBeTrue();
            expect(indexOf(found.version, ".") != null).toBeTrue();
        }
    }
}

describe("macosVersion") {
    test("should give a dotted version number on a Mac and null elsewhere") {
        const version = macosVersion();

        expect(version != null).toBe(onMac());
        if (const found = version) {
            expect(found.len > 0 && found[0] >= '1' && found[0] <= '9').toBeTrue();
            expect(indexOf(found, ".") != null).toBeTrue();
        }
    }
}

describe("clangResourceDir") {
    test("should give the numbered folder under the clang folder of the LLVM libraries") {
        const dir = clangResourceDir() ?? "";
        const at = indexOf(dir, "/clang/") ?? 0;

        expect(at > 0).toBeTrue();
        expect(dir[at + 7] >= '0' && dir[at + 7] <= '9').toBeTrue();
    }
}

describe("bareMetal") {
    test("should treat the -unknown-none-elf and -none-eabi triples as having no OS") {
        expect(bareMetal("riscv64-unknown-none-elf")).toBeTrue();
        expect(bareMetal("thumbv7em-none-eabihf")).toBeTrue();
        expect(bareMetal("thumbv6m-none-eabi")).toBeTrue();
    }

    test("should treat a triple with an OS as not bare metal") {
        expect(bareMetal("x86_64-unknown-linux-musl")).toBeFalse();
        expect(bareMetal("wasm32-unknown-wasip1")).toBeFalse();
    }
}

describe("bareMetalFlags") {
    test("should add the RISC-V architecture, ABI, and code model") {
        expect(flagsFor("riscv64-unknown-none-elf")).toBe("-march=rv64gc -mabi=lp64d -mcmodel=medany");
    }

    test("should turn off the red zone on x86_64") {
        expect(flagsFor("x86_64-unknown-none-elf")).toBe("-mno-red-zone");
    }

    test("should turn off outline atomics on aarch64") {
        expect(flagsFor("aarch64-unknown-none-elf")).toBe("-mno-outline-atomics");
    }

    test("should use the soft float ABI for a Cortex-M without hf") {
        expect(flagsFor("thumbv6m-none-eabi")).toBe("-mthumb -march=armv6-m -mfloat-abi=soft");
    }

    test("should pass floats in FPU registers for an -eabihf Cortex-M") {
        expect(flagsFor("thumbv7em-none-eabihf")).toBe("-mthumb -march=armv7e-m -mfloat-abi=hard -mfpu=fpv4-sp-d16");
        expect(flagsFor("thumbv8m.main-none-eabihf")).toBe("-mthumb -march=armv8-m.main -mfloat-abi=hard -mfpu=fpv5-sp-d16");
    }

    test("should add nothing for another architecture") {
        expect(flagsFor("wasm32-unknown-none-elf")).toBe("");
    }
}

describe("libcEnsure") {
    test("should refuse a glibc target without building anything") {
        expect(libcEnsure("x86_64-unknown-linux-gnu", "/nonexistent")).toBeNull();
    }

    test("should refuse a musl target on an architecture it does not know") {
        expect(libcEnsure("mips-unknown-linux-musl", "/nonexistent")).toBeNull();
    }
}
