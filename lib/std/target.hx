/**
 * The operating systems that a program can be built for.
 *
 * @remarks
 * The compiler sets {@link target} to the system of each build,
 * so a `comptime` check against a member compiles only the branch that it takes.
 *
 * @example
 * ```hx
 * if (comptime target.os == Os.Windows) { ... } else { ... } // only one branch is compiled
 * ```
 *
 * @since 1.0.0
 */

export enum Os {
    /**
     * The macOS system.
     *
     * @example
     * ```hx
     * target.os == Os.Macos; // true for a build on or for a Mac
     * ```
     *
     * @since 1.0.0
     */

    Macos,

    /**
     * The Linux system.
     *
     * @example
     * ```hx
     * target.os == Os.Linux; // true for --target x86_64-linux-gnu
     * ```
     *
     * @since 1.0.0
     */

    Linux,

    /**
     * The Windows system.
     *
     * @example
     * ```hx
     * target.os == Os.Windows; // true for --target x86_64-windows
     * ```
     *
     * @since 1.0.0
     */

    Windows,

    /**
     * The WebAssembly System Interface.
     *
     * @example
     * ```hx
     * target.os == Os.Wasi; // true for --target wasm32-wasi
     * ```
     *
     * @since 1.0.0
     */

    Wasi,

    /**
     * No operating system, as for a kernel or firmware.
     *
     * @example
     * ```hx
     * target.os == Os.Freestanding; // true for --target thumbv7em-freestanding
     * ```
     *
     * @since 1.0.0
     */

    Freestanding
}

/**
 * The processors that a program can be built for.
 *
 * @remarks
 * The compiler sets {@link target} to the processor of each build,
 * so a `comptime` check against a member compiles only the branch that it takes.
 *
 * @example
 * ```hx
 * if (comptime target.arch == Arch.Thumb) { ... } // compiled only for a Cortex-M build
 * ```
 *
 * @since 1.0.0
 */

export enum Arch {
    /**
     * The 64-bit x86 processor.
     *
     * @example
     * ```hx
     * target.arch == Arch.X86_64; // true for --target x86_64-linux-gnu
     * ```
     *
     * @since 1.0.0
     */

    X86_64,

    /**
     * The 64-bit ARM processor.
     *
     * @example
     * ```hx
     * target.arch == Arch.Aarch64; // true for --target aarch64-macos
     * ```
     *
     * @since 1.0.0
     */

    Aarch64,

    /**
     * The 64-bit ARM processor with the pointer authentication of Apple.
     *
     * @example
     * ```hx
     * target.arch == Arch.Arm64e; // true for --target arm64e-macos
     * ```
     *
     * @since 1.0.0
     */

    Arm64e,

    /**
     * The 64-bit RISC-V processor.
     *
     * @example
     * ```hx
     * target.arch == Arch.Riscv64; // true for --target riscv64-linux
     * ```
     *
     * @since 1.0.0
     */

    Riscv64,

    /**
     * The 32-bit WebAssembly machine.
     *
     * @example
     * ```hx
     * target.arch == Arch.Wasm32; // true for --target wasm32-wasi
     * ```
     *
     * @since 1.0.0
     */

    Wasm32,

    /**
     * The Thumb instruction set of a Cortex-M microcontroller.
     *
     * @example
     * ```hx
     * target.arch == Arch.Thumb; // true for --target thumbv7em-freestanding
     * ```
     *
     * @since 1.0.0
     */

    Thumb
}

/**
 * The system, the processor, and the pointer size of a build.
 *
 * @remarks
 * {@link target} holds the one for the current build.
 *
 * @example
 * ```hx
 * const t = Target { os: Os.Linux, arch: Arch.Riscv64, pointerBits: 64 };
 * t.pointerBits; // 64
 * ```
 *
 * @since 1.0.0
 */

export struct Target {
    /**
     * The operating system.
     *
     * @example
     * ```hx
     * target.os; // Os.Linux for --target x86_64-linux-gnu
     * ```
     *
     * @since 1.0.0
     */

    os: Os,

    /**
     * The processor.
     *
     * @example
     * ```hx
     * target.arch; // Arch.X86_64 for --target x86_64-linux-gnu
     * ```
     *
     * @since 1.0.0
     */

    arch: Arch,

    /**
     * The size of a pointer in bits.
     *
     * @remarks
     * It is 64, except on wasm32 and Cortex-M, where it is 32.
     *
     * @example
     * ```hx
     * target.pointerBits; // 32 for --target wasm32-wasi
     * ```
     *
     * @since 1.0.0
     */

    pointerBits: u32,
}

/**
 * The target that the program is built for, from `--target` or this machine.
 *
 * @remarks
 * The compiler rewrites this module for every build, replacing everything from this declaration to the end of the file,
 * so code can choose per platform while compiling and only the branch it takes is compiled.
 * The value in the file only shows the shape, and each build gets its own values.
 * This declaration must stay the last one in the file.
 *
 * @example
 * ```hx
 * import { target, Os } from "std/target";
 *
 * if (comptime target.os == Os.Windows) { ... } else { ... } // only one branch is compiled
 * ```
 *
 * @since 1.0.0
 */

export const target: Target = Target { os: Os.Macos, arch: Arch.Aarch64, pointerBits: 64 };
