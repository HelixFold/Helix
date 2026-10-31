/**
 * Imports
 */

import { ArrayList } from "std/list";
import { HxAst } from "@models/structs/ast-model.struct";
import { HxSource } from "@models/structs/source-model.struct";
import { HxProgram, HxSema, HxModule } from "@structs/sema.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { Strings } from "@modules/driver/components/structs/os-component.struct";
import { Manifest } from "@modules/driver/components/structs/manifest-component.struct";

/**
 * The options that the compiling commands share, as the command line gives them.
 *
 * @remarks
 * Every compiling command (`build`, `run`, `test`, `check`, `ir`, and the project build) starts from
 * {@link defaultOptions}, reads its own flags, and hands the rest to {@link parseCompileOption}.
 * {@link buildExecutable} then turns the options into an executable or an object file.
 *
 * @example
 * ```hx
 * let options = defaultOptions();
 * options.file = "src/main.hx";
 * options.target = "x86_64-linux";
 * buildExecutable(&options, "main"); // true once it compiles and links
 * ```
 *
 * @see defaultOptions
 * @see buildExecutable
 *
 * @since 1.0.0
 */

export struct Options {
    /**
     * The root file of the program.
     *
     * @example
     * ```hx
     * options.file; // "src/main.hx"
     * ```
     *
     * @since 1.0.0
     */

    file: string,

    /**
     * The output path that `-o` gives, or `null` for the default.
     *
     * @example
     * ```hx
     * options.output; // "build/app" for -o build/app
     * ```
     *
     * @since 1.0.0
     */

    output: ?string,

    /**
     * The optimization mode that `--mode` gives.
     *
     * @remarks
     * It holds one of the codegen modes, from `ModeDebug` (0) to `ModeReleaseSmall` (3).
     *
     * @example
     * ```hx
     * options.mode; // 0, the debug mode
     * ```
     *
     * @since 1.0.0
     */

    mode: u32,

    /**
     * The arguments after `--` that `helix run` passes to the program.
     *
     * @example
     * ```hx
     * options.runArgs; // [ "a", "b" ] for helix run main.hx -- a b
     * ```
     *
     * @since 1.0.0
     */

    runArgs: readonly string[],

    /**
     * Whether to compile the tests of the root module.
     *
     * @remarks
     * `helix test` and `helix check --test` set it.
     * A test build also loads `std/testing` and links the test runtime.
     *
     * @example
     * ```hx
     * options.test; // true under helix test
     * ```
     *
     * @since 1.0.0
     */

    test: bool,

    /**
     * The target that `--target` gives, as `arch-os[-abi]`, or `null` for this machine.
     *
     * @example
     * ```hx
     * options.target; // "aarch64-macos"
     * ```
     *
     * @see parseTarget
     * @since 1.0.0
     */

    target: ?string,

    /**
     * The CPU that `--cpu` gives: `native`, `generic`, or an LLVM CPU name.
     *
     * @example
     * ```hx
     * options.cpu; // "apple-m1"
     * ```
     *
     * @since 1.0.0
     */

    cpu: ?string,

    /**
     * Whether `--strip` leaves out the debug info and the local symbols.
     *
     * @example
     * ```hx
     * options.strip; // true for --strip
     * ```
     *
     * @since 1.0.0
     */

    strip: bool,

    /**
     * Whether `--emit obj` writes the object file instead of linking it.
     *
     * @remarks
     * An object file may be a library, so a program without `main` is allowed then.
     *
     * @example
     * ```hx
     * options.emitObject; // true for --emit obj
     * ```
     *
     * @since 1.0.0
     */

    emitObject: bool,

    /**
     * The files of `--link <file>` and the libraries of `-l<name>`, which go on to the linker as they are.
     *
     * @example
     * ```hx
     * options.links.items; // [ "host.o", "-lz" ]
     * ```
     *
     * @since 1.0.0
     */

    links: Strings,

    /**
     * The linker script that `--linker-script` gives, which places a freestanding program in memory.
     *
     * @example
     * ```hx
     * options.linkerScript; // "board.ld"
     * ```
     *
     * @since 1.0.0
     */

    linkerScript: ?string,

    /**
     * The flash memory of a microcontroller, as `<origin>:<size>`.
     *
     * @remarks
     * It comes from `--flash`, or from the chip of the package's `helix.jsonc`.
     * A Cortex-M build makes its linker script from it and {@link Options.ram}.
     *
     * @example
     * ```hx
     * options.flash; // "0x08000000:512K"
     * ```
     *
     * @since 1.0.0
     */

    flash: ?string,

    /**
     * The RAM of a microcontroller, as `<origin>:<size>`.
     *
     * @remarks
     * It comes from `--ram`, or from the chip of the package's `helix.jsonc`.
     *
     * @example
     * ```hx
     * options.ram; // "0x20000000:128K"
     * ```
     *
     * @since 1.0.0
     */

    ram: ?string,

    /**
     * The chip that `--chip` names, whose core, FPU, and memory come from the chip table in `lib/chips`.
     *
     * @example
     * ```hx
     * options.chip; // "STM32F411RE"
     * ```
     *
     * @see applyChip
     * @since 1.0.0
     */

    chip: ?string,
}

/**
 * A compilation target: its LLVM triple and what it means for the runtime and the linker.
 *
 * @remarks
 * {@link parseTarget} makes it from the `--target` text.
 * At most one of the system flags is set, and none of them for macOS.
 *
 * @example
 * ```hx
 * const target = parseTarget("x86_64-linux");
 * target.triple; // "x86_64-unknown-linux-musl"
 * target.musl;   // true
 * ```
 *
 * @see parseTarget
 * @since 1.0.0
 */

export struct Target {
    /**
     * The LLVM triple.
     *
     * @example
     * ```hx
     * target.triple; // "arm64-apple-macosx11.0"
     * ```
     *
     * @since 1.0.0
     */

    triple: string,

    /**
     * Whether the target is the machine that the compiler runs on.
     *
     * @remarks
     * Only a Mac sets it, for no target or `native`.
     * The code generator then tunes for this CPU, and the build links the runtime that ships with the compiler.
     *
     * @example
     * ```hx
     * parseTarget(null).host; // true on a Mac
     * ```
     *
     * @since 1.0.0
     */

    host: bool,

    /**
     * Whether the target is macOS.
     *
     * @example
     * ```hx
     * parseTarget("aarch64-macos").apple; // true
     * ```
     *
     * @since 1.0.0
     */

    apple: bool,

    /**
     * Whether the target is Linux with musl.
     *
     * @remarks
     * Helix then builds the C library itself and links a static program with ld.lld.
     *
     * @example
     * ```hx
     * parseTarget("x86_64-linux").musl;     // true
     * parseTarget("x86_64-linux-gnu").musl; // false
     * ```
     *
     * @since 1.0.0
     */

    musl: bool,

    /**
     * Whether the target is Windows with the MinGW ABI.
     *
     * @remarks
     * The program then imports msvcrt.dll and kernel32.dll, and ld.lld links it.
     *
     * @example
     * ```hx
     * parseTarget("x86_64-windows").windows; // true
     * ```
     *
     * @since 1.0.0
     */

    windows: bool,

    /**
     * Whether the target is WebAssembly with WASI.
     *
     * @remarks
     * Helix then builds wasi-libc, and wasm-ld links the program.
     *
     * @example
     * ```hx
     * parseTarget("wasm32-wasi").wasi; // true
     * ```
     *
     * @since 1.0.0
     */

    wasi: bool,

    /**
     * Whether the target has no operating system, as for kernels, boot code, and microcontrollers.
     *
     * @remarks
     * The program then links with ld.lld against the freestanding runtime, placed in memory by a linker script.
     *
     * @example
     * ```hx
     * parseTarget("riscv64-freestanding").freestanding; // true
     * ```
     *
     * @since 1.0.0
     */

    freestanding: bool,

    /**
     * The size of a pointer in bytes.
     *
     * @example
     * ```hx
     * parseTarget("wasm32-wasi").pointerBytes;          // 4
     * parseTarget("thumbv7em-freestanding").pointerBytes; // 4
     * parseTarget("x86_64-linux").pointerBytes;         // 8
     * ```
     *
     * @since 1.0.0
     */

    pointerBytes: u32,
}

/**
 * A meaning for a bare `import ... from "name"`, as `--pkg` and `--pkg-in` give it.
 *
 * @remarks
 * `--pkg name=path` is for the program's own code.
 * `--pkg-in <root> name=path` is for the code of the package whose root module is `<root>`.
 * A module belongs to the package whose folder holds it,
 * where that folder is the nearest one up from the package's root with a `helix.jsonc`.
 *
 * @example
 * ```hx
 * addPackageArg(null, "json=lib/json.hx"); // import ... from "json" now means lib/json.hx
 * ```
 *
 * @see addPackageArg
 * @since 1.0.0
 */

export struct PackageArg {
    /**
     * The real path of the root module of the importing package, or `null` for the program itself.
     *
     * @example
     * ```hx
     * arg.scope; // null for --pkg
     * ```
     *
     * @since 1.0.0
     */

    scope: ?string,

    /**
     * The name that the import uses.
     *
     * @example
     * ```hx
     * arg.name; // "json" for --pkg json=lib/json.hx
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The root module of the package, or a folder that holds an `index.hx`.
     *
     * @example
     * ```hx
     * arg.path; // "lib/json.hx" for --pkg json=lib/json.hx
     * ```
     *
     * @since 1.0.0
     */

    path: string,
}

/**
 * A package folder with its `helix.jsonc`, which a compilation reads once.
 *
 * @remarks
 * {@link knownPackage} keeps up to 1024 of them in a fixed table for the whole run,
 * so each `helix.jsonc` is read only once however many imports reach it.
 *
 * @example
 * ```hx
 * const p = knownPackage(dir);
 * p.manifest.deps.items; // [ "json" ]
 * ```
 *
 * @since 1.0.0
 */

export struct KnownPackage {
    /**
     * The real path of the package folder.
     *
     * @example
     * ```hx
     * p.dir; // "/work/app/helix-modules/json"
     * ```
     *
     * @since 1.0.0
     */

    dir: string,

    /**
     * The package's `helix.jsonc`, as it was read.
     *
     * @example
     * ```hx
     * p.manifest.name; // "json"
     * ```
     *
     * @since 1.0.0
     */

    manifest: Manifest,

    /**
     * Whether an import reached the package.
     *
     * @remarks
     * Its C sources are then compiled and linked into the program, with its system libraries.
     *
     * @example
     * ```hx
     * p.imported; // true once the program imports "json"
     * ```
     *
     * @since 1.0.0
     */

    imported: bool,

    /**
     * Whether the package's `helix-modules` layout and its staleness were checked.
     *
     * @example
     * ```hx
     * p.checked; // true after the first import through it
     * ```
     *
     * @since 1.0.0
     */

    checked: bool,
}
/**
 * A program that is loaded, parsed, and maybe checked, with everything the stages share.
 *
 * @remarks
 * {@link compileFront} makes it on the heap, since the syntax tree points into it,
 * and {@link compilationFree} releases it.
 *
 * @example
 * ```hx
 * let ok = false;
 * const c = compileFront("main.hx", true, false, null, &ok);
 * c.diags.errorCount; // 0 when ok is true
 * compilationFree(c);
 * ```
 *
 * @see compileFront
 * @see compilationFree
 *
 * @since 1.0.0
 */

export struct Compilation {
    /**
     * The text of every loaded file.
     *
     * @example
     * ```hx
     * c.src.fileCount; // 2 for main.hx and one import
     * ```
     *
     * @since 1.0.0
     */

    src: HxSource,

    /**
     * The tokens of every loaded file, one file after another.
     *
     * @example
     * ```hx
     * c.tokens.len; // the tokens of all modules
     * ```
     *
     * @since 1.0.0
     */

    tokens: HxTokens,

    /**
     * The syntax tree of every module, with its root set to the root module's file node.
     *
     * @example
     * ```hx
     * c.ast.root; // the file node of main.hx
     * ```
     *
     * @since 1.0.0
     */

    ast: HxAst,

    /**
     * The checker state, which is set once the program is checked.
     *
     * @example
     * ```hx
     * c.sema.entry; // the symbol of main, or 0 without one
     * ```
     *
     * @since 1.0.0
     */

    sema: HxSema,

    /**
     * The diagnostics of every stage.
     *
     * @remarks
     * They are printed at the end of {@link compileFront} unless {@link setQuiet} keeps them here.
     *
     * @example
     * ```hx
     * c.diags.errorCount; // 1 for one missing import
     * ```
     *
     * @since 1.0.0
     */

    diags: HxDiagList,

    /**
     * The modules and the import targets as the checker reads them.
     *
     * @example
     * ```hx
     * c.program.count; // the number of modules
     * ```
     *
     * @since 1.0.0
     */

    program: HxProgram,

    /**
     * The modules, the root first, each with its root node and its readable name.
     *
     * @example
     * ```hx
     * c.modules.items[0]; // the root module, named "main"
     * ```
     *
     * @since 1.0.0
     */

    modules: ArrayList<HxModule>,

    /**
     * The real path of each module, so that every file loads once.
     *
     * @example
     * ```hx
     * c.realPaths.items[0]; // "/work/app/src/main.hx"
     * ```
     *
     * @since 1.0.0
     */

    realPaths: Strings,

    /**
     * Whether the files were loaded.
     *
     * @example
     * ```hx
     * c.loaded; // false when the root file does not read
     * ```
     *
     * @since 1.0.0
     */

    loaded: bool,

    /**
     * Whether the syntax tree exists, so that {@link compilationFree} releases it.
     *
     * @example
     * ```hx
     * c.parsed; // true once the files were loaded
     * ```
     *
     * @since 1.0.0
     */

    parsed: bool,

    /**
     * Whether the checker ran, so that {@link compilationFree} releases its state.
     *
     * @example
     * ```hx
     * c.checked; // true after compileFront with check set and no load error
     * ```
     *
     * @since 1.0.0
     */

    checked: bool,
}

/**
 * An import declaration and the module that it loads.
 *
 * @remarks
 * {@link loadProgram} collects one for each import that resolves,
 * then writes `module + 1` at the `node` index of the import table of the program, so 0 there means no module.
 *
 * @example
 * ```hx
 * const t = ImportTarget { node: decl, module: 1 };
 * ```
 *
 * @since 1.0.0
 */

export struct ImportTarget {
    /**
     * The import declaration node.
     *
     * @example
     * ```hx
     * t.node; // the node of import { x } from "./b"
     * ```
     *
     * @since 1.0.0
     */

    node: u32,

    /**
     * The index of the module that the import loads.
     *
     * @example
     * ```hx
     * t.module; // 1, the first imported file
     * ```
     *
     * @since 1.0.0
     */

    module: u32,
}

/**
 * A chip from the chip table, with its core, FPU, and main memory.
 *
 * @remarks
 * {@link chipTable} reads each one from a row of a JSON file in `lib/chips` beside the compiler,
 * in the order name, core, FPU, flash, and RAM.
 * A row with fewer than five entries is skipped.
 *
 * @example
 * ```hx
 * const chip = findChip("STM32F411RE");
 * chip.cpu;   // "cortex-m4"
 * chip.flash; // "0x08000000:512K"
 * ```
 *
 * @see chipTable
 * @since 1.0.0
 */

export struct Chip {
    /**
     * The name of the chip, in capitals.
     *
     * @example
     * ```hx
     * chip.name; // "STM32F411RE"
     * ```
     *
     * @since 1.0.0
     */

    name: string,

    /**
     * The core, as LLVM names it.
     *
     * @example
     * ```hx
     * chip.cpu; // "cortex-m4"
     * ```
     *
     * @since 1.0.0
     */

    cpu: string,

    /**
     * Whether the chip has an FPU.
     *
     * @example
     * ```hx
     * chip.fpu; // true
     * ```
     *
     * @since 1.0.0
     */

    fpu: bool,

    /**
     * The main flash memory, as `<origin>:<size>`.
     *
     * @example
     * ```hx
     * chip.flash; // "0x08000000:512K"
     * ```
     *
     * @since 1.0.0
     */

    flash: string,

    /**
     * The main RAM, as `<origin>:<size>`.
     *
     * @example
     * ```hx
     * chip.ram; // "0x20000000:128K"
     * ```
     *
     * @since 1.0.0
     */

    ram: string,
}
