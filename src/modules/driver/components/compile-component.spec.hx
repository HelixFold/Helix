/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import * as os from "@modules/driver/components/os.component";
import { ModeDebug } from "@modules/codegen/constants/base.constant";
import { allocCString } from "@modules/driver/components/os.component";
import { Options } from "@modules/driver/components/structs/compile-component.struct";
import { addPackageArg, packageDir, cCompiler } from "@modules/driver/components/compile.component";
import { applyChip, buildExecutable, defaultOptions } from "@modules/driver/components/compile.component";
import { compileFront, compilationFree, clearPackageArgs } from "@modules/driver/components/compile.component";
import { parseCompileOption, parseTarget, setOverlay, setQuiet } from "@modules/driver/components/compile.component";

/**
 * Tests
 */

let out: Builder = undefined;
let outReady = false;

let scratchDir: string = "";

/**
 * A temporary folder of this run, which the hooks create and remove.
 *
 * @returns The path of the folder
 *
 * @remarks
 * The first call, which a `beforeAll` makes, fixes the name,
 * so that the test processes forked from it share it.
 *
 * @since 1.0.0
 */

function scratch(): string {
    if (scratchDir.len == 0) scratchDir = allocCString(`${os.tempDir()}/helix-compile-spec-${os.pid()}`);
    return scratchDir;
}

/**
 * Writes a file below the temporary folder, creating its folders, and returns its path.
 *
 * @param relative - The path of the file inside the temporary folder
 * @param text - The contents of the file
 * @returns The full path of the file
 *
 * @remarks
 * Every folder on the way is created, and a failed write is ignored.
 *
 * @since 1.0.0
 */

function put(relative: string, text: string): string {
    const path = allocCString(`${scratch()}/${relative}`);
    void os.makeDirs(path[0..os.lastIndex(path, '/') ?? 0]);
    void os.writeText(path, text);
    return path;
}

/**
 * A NUL-terminated string as a slice.
 *
 * @param text - The C string
 * @returns The bytes before the NUL, without a copy
 *
 * @remarks
 * The diagnostics keep their messages as C strings, and the expectations compare Helix strings.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * Loads and checks a file without printing, and returns every error message, one per line.
 *
 * @param path - The root file of the program
 * @param check - Whether to run the checker after loading
 * @returns The messages of every diagnostic, each followed by a line feed
 *
 * @remarks
 * The diagnostics stay quiet, so the spec output shows only the results.
 * The text lives in a builder that the next call clears, so a case reads it before the next call.
 *
 * @since 1.0.0
 */

function errorsOf(path: string, check: bool): string {
    setQuiet(true);
    let ok = false;
    const c = compileFront(path, check, false, null, &ok);
    defer compilationFree(c);
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    for (const i of 0..c.diags.itemsLen) {
        unsafe {
            out.append(`${cString(c.diags.items![i].message)}\n`) catch unreachable;
        }
    }
    return out.text();
}

/**
 * Reads one option at the start of a command line.
 *
 * @param args - The command line, whose first argument is the option to read
 * @param options - The options that get the value
 * @returns 1 when the argument was an option, 0 when it was not, and -1 after reporting an error
 *
 * @remarks
 * It always reads at index 0, so a case passes only the option and its value.
 *
 * @since 1.0.0
 */

function option(args: readonly string[], options: *Options): i32 {
    let i: usize = 0;
    return parseCompileOption(args, &i, options);
}

describe("defaultOptions") {
    test("should build for this machine in debug mode") {
        const options = defaultOptions();

        expect(options.mode).toBe(ModeDebug);
        expect(options.target).toBeNull();
        expect(options.test).toBeFalse();
    }

    test("should start without a file or anything to link") {
        const options = defaultOptions();

        expect(options.file).toBe("");
        expect(options.links.items).toHaveLength(0);
    }
}

describe("parseCompileOption") {
    test("should read the value of --target and move past it") {
        let options = defaultOptions();
        let i: usize = 0;

        expect(parseCompileOption(["--target", "x86_64-linux"], &i, &options)).toBe(1);
        expect(i).toBe(1);
        expect(options.target ?? "").toBe("x86_64-linux");
    }

    test("should add -l<name> and --link to the link list in order") {
        let options = defaultOptions();
        void option(["-lz"], &options);
        void option(["--link", "host.o"], &options);

        expect(options.links.items).toEqual(["-lz", "host.o"]);
    }

    test("should set --strip without taking a value") {
        let options = defaultOptions();
        let i: usize = 0;

        expect(parseCompileOption(["--strip", "main.hx"], &i, &options)).toBe(1);
        expect(i).toBe(0);
        expect(options.strip).toBeTrue();
    }

    test("should accept --emit obj and reject any other value") {
        let options = defaultOptions();

        expect(option(["--emit", "obj"], &options)).toBe(1);
        expect(options.emitObject).toBeTrue();
        expect(option(["--emit", "asm"], &options)).toBe(-1);
    }

    test("should keep --flash and --ram only as <origin>:<size>") {
        let options = defaultOptions();

        expect(option(["--flash", "0x08000000:512K"], &options)).toBe(1);
        expect(option(["--ram", "0x20000000:128K"], &options)).toBe(1);
        expect(option(["--ram", "128K"], &options)).toBe(-1);
        expect(options.flash ?? "").toBe("0x08000000:512K");
        expect(options.ram ?? "").toBe("0x20000000:128K");
    }

    test("should reject a --pkg without name=path") {
        let options = defaultOptions();

        expect(option(["--pkg", "json"], &options)).toBe(-1);
    }

    test("should leave an option of another command alone") {
        let options = defaultOptions();

        expect(option(["-o", "out"], &options)).toBe(0);
    }

    test("should leave an option without its value to the caller") {
        let options = defaultOptions();

        expect(option(["--target"], &options)).toBe(0);
        expect(options.target).toBeNull();
    }
}

describe("parseTarget") {
    test("should make a Linux target a static musl one unless the ABI says otherwise") {
        const musl = parseTarget("x86_64-linux") ?? unreachable;
        const gnu = parseTarget("x86_64-linux-gnu") ?? unreachable;

        expect(musl.triple).toBe("x86_64-unknown-linux-musl");
        expect(musl.musl).toBeTrue();
        expect(gnu.triple).toBe("x86_64-unknown-linux-gnu");
        expect(gnu.musl).toBeFalse();
    }

    test("should aim a named macOS target at any Mac from macOS 11") {
        const t = parseTarget("aarch64-macos") ?? unreachable;

        expect(t.triple).toBe("arm64-apple-macosx11.0");
        expect(t.apple).toBeTrue();
        expect(t.host).toBeFalse();
    }

    test("should read arm64 as aarch64") {
        const t = parseTarget("arm64-linux") ?? unreachable;

        expect(t.triple).toBe("aarch64-unknown-linux-musl");
    }

    test("should make Windows a MinGW target") {
        const t = parseTarget("x86_64-windows") ?? unreachable;

        expect(t.triple).toBe("x86_64-w64-windows-gnu");
        expect(t.windows).toBeTrue();
    }

    test("should give WASI its own triple and 4-byte pointers") {
        const t = parseTarget("wasm32-wasi") ?? unreachable;

        expect(t.triple).toBe("wasm32-unknown-wasip1");
        expect(t.wasi).toBeTrue();
        expect(t.pointerBytes).toBe(4);
    }

    test("should make a freestanding target an ELF one without an OS") {
        const t = parseTarget("riscv64-freestanding") ?? unreachable;

        expect(t.triple).toBe("riscv64-unknown-none-elf");
        expect(t.freestanding).toBeTrue();
        expect(t.pointerBytes).toBe(8);
    }

    test("should give a Cortex-M target the eabi ABI unless it asks for eabihf") {
        const soft = parseTarget("thumbv7em-freestanding") ?? unreachable;
        const hard = parseTarget("thumbv7em-freestanding-eabihf") ?? unreachable;

        expect(soft.triple).toBe("thumbv7em-none-eabi");
        expect(hard.triple).toBe("thumbv7em-none-eabihf");
        expect(soft.pointerBytes).toBe(4);
    }

    test("should reject eabihf on a Cortex-M core without an FPU") {
        expect(parseTarget("thumbv6m-freestanding-eabihf")).toBeNull();
        expect(parseTarget("thumbv7m-freestanding-eabihf")).toBeNull();
    }

    test("should reject a Cortex-M target with an operating system") {
        expect(parseTarget("thumbv7em-linux")).toBeNull();
    }

    test("should reject an unknown architecture or system") {
        expect(parseTarget("sparc-linux")).toBeNull();
        expect(parseTarget("x86_64-plan9")).toBeNull();
        expect(parseTarget("x86_64")).toBeNull();
    }

    test("should reject a system that the architecture does not run") {
        expect(parseTarget("arm64e-linux")).toBeNull();
        expect(parseTarget("riscv64-macos")).toBeNull();
        expect(parseTarget("wasm32-linux")).toBeNull();
        expect(parseTarget("x86_64-wasi")).toBeNull();
    }

    test("should make this Mac the host target") {
        const t = parseTarget(null) ?? unreachable;
        const native = parseTarget("native") ?? unreachable;

        expect(t.host).toBeTrue();
        expect(t.apple).toBeTrue();
        expect(native.host).toBeTrue();
    }
}

describe("clearPackageArgs") {
    beforeAll {
        void put("clear/lib.hx", "export const answer: i32 = 42;\n");
        void put("clear/main.hx", "import { answer } from \"lib\";\nconst x: i32 = answer;\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should forget a meaning that --pkg gave") {
        void addPackageArg(null, allocCString(`lib=${scratch()}/clear/lib.hx`));
        clearPackageArgs();

        expect(errorsOf(allocCString(`${scratch()}/clear/main.hx`), true)).toInclude("unknown package \"lib\"");
    }
}

describe("addPackageArg") {
    beforeAll {
        void put("pkg/lib.hx", "export const answer: i32 = 42;\n");
        void put("pkg/folder/index.hx", "export const other: i32 = 7;\n");
        void put("pkg/main.hx", "import { answer } from \"lib\";\nconst x: i32 = answer;\n");
        void put("pkg/dir.hx", "import { other } from \"folder\";\nconst x: i32 = other;\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should make a bare import name the given file") {
        expect(addPackageArg(null, allocCString(`lib=${scratch()}/pkg/lib.hx`))).toBeTrue();

        expect(errorsOf(allocCString(`${scratch()}/pkg/main.hx`), true)).toBe("");
    }

    test("should find the index.hx of a folder") {
        void addPackageArg(null, allocCString(`folder=${scratch()}/pkg/folder`));

        expect(errorsOf(allocCString(`${scratch()}/pkg/dir.hx`), true)).toBe("");
    }

    test("should reject text without a name or a path") {
        expect(addPackageArg(null, "lib")).toBeFalse();
        expect(addPackageArg(null, "lib=")).toBeFalse();
        expect(addPackageArg(null, "=lib.hx")).toBeFalse();
    }
}

describe("packageDir") {
    beforeAll {
        void put("app/helix.jsonc", "{ \"name\": \"app\", \"version\": \"1.0.0\" }\n");
        void put("app/src/deep/main.hx", "\n");
        void put("loose/main.hx", "\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should find the nearest folder above the file with a helix.jsonc") {
        const real = os.realPath(scratch()) ?? unreachable;

        expect(packageDir(allocCString(`${scratch()}/app/src/deep/main.hx`)) ?? "").toBe(allocCString(`${real}/app`));
    }

    test("should give null for a file outside any package") {
        expect(packageDir(allocCString(`${scratch()}/loose/main.hx`))).toBeNull();
    }

    test("should give null for a file that does not exist") {
        expect(packageDir(allocCString(`${scratch()}/missing.hx`))).toBeNull();
    }
}

describe("cCompiler") {
    test("should aim clang at a freestanding target without system headers") {
        const target = parseTarget("riscv64-freestanding") ?? unreachable;
        const cc = cCompiler(target) ?? unreachable;

        expect(cc.items).toHaveLength(3);
        expect(cc.items[1]).toBe("-target");
        expect(cc.items[2]).toBe("riscv64-unknown-none-elf");
    }

    test("should refuse Windows, whose headers Helix does not set up") {
        const target = parseTarget("x86_64-windows") ?? unreachable;

        expect(cCompiler(target)).toBeNull();
    }
}

describe("setOverlay") {
    beforeAll {
        void put("overlay/main.hx", "const x: i32 = \"not a number\";\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should read the given text instead of the file") {
        const path = os.realPath(allocCString(`${scratch()}/overlay/main.hx`)) ?? unreachable;
        setOverlay(path, "const x: i32 = 1;\n");

        expect(errorsOf(path, true)).toBe("");
    }

    test("should read the last text set for a path") {
        const path = os.realPath(allocCString(`${scratch()}/overlay/main.hx`)) ?? unreachable;
        setOverlay(path, "const x: i32 = 1;\n");
        setOverlay(path, "const x: i32 = true;\n");

        expect(errorsOf(path, true)).not.toBe("");
    }
}

describe("setQuiet") {
    beforeAll {
        void put("quiet/main.hx", "const x: i32 = true;\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should keep the diagnostics in the compilation") {
        setQuiet(true);
        let ok = true;
        const c = compileFront(allocCString(`${scratch()}/quiet/main.hx`), true, false, null, &ok);
        defer compilationFree(c);

        expect(ok).toBeFalse();
        expect(c.diags.errorCount).toBe(1);
    }
}

describe("compileFront") {
    beforeAll {
        void put("front/main.hx", "import { y } from \"./b\";\nconst x: i32 = y;\n");
        void put("front/b.hx", "export const y: i32 = 2;\n");
        void put("front/missing.hx", "import { y } from \"./nothing\";\n");
        void put("front/bare.hx", "import { y } from \"nowhere\";\n");
        void put("front/typed.hx", "const x: i32 = true;\n");
        const aliases = "\"aliases\": { \"@lib\": \"src/lib\" }";
        void put("alias/helix.jsonc", allocCString(`{ "name": "alias", "version": "1.0.0", ${aliases} }\n`));
        void put("alias/src/lib/math.hx", "export const two: i32 = 2;\n");
        void put("alias/src/main.hx", "import { two } from \"@lib/math\";\nconst x: i32 = two;\n");
        void put("alias/src/wrong.hx", "import { two } from \"@lib/nothing\";\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should load a relative import as a second module") {
        setQuiet(true);
        let ok = false;
        const c = compileFront(allocCString(`${scratch()}/front/main.hx`), true, false, null, &ok);
        defer compilationFree(c);

        expect(ok).toBeTrue();
        expect(c.modules.items).toHaveLength(2);
        expect(c.program.count).toBe(2);
    }

    test("should report a relative import that names no file") {
        const errors = errorsOf(allocCString(`${scratch()}/front/missing.hx`), true);

        expect(errors).toInclude("cannot find module \"./nothing\"");
    }

    test("should report a bare import outside any package") {
        expect(errorsOf(allocCString(`${scratch()}/front/bare.hx`), true)).toInclude("unknown package \"nowhere\"");
    }

    test("should resolve an import through an alias of the package") {
        expect(errorsOf(allocCString(`${scratch()}/alias/src/main.hx`), true)).toBe("");
    }

    test("should report an alias that leads to no file") {
        expect(errorsOf(allocCString(`${scratch()}/alias/src/wrong.hx`), true))
            .toInclude("cannot find module \"@lib/nothing\"");
    }

    test("should report type errors only when it checks") {
        expect(errorsOf(allocCString(`${scratch()}/front/typed.hx`), false)).toBe("");
        expect(errorsOf(allocCString(`${scratch()}/front/typed.hx`), true)).not.toBe("");
    }

    test("should fail without loading a root file that does not exist") {
        setQuiet(true);
        let ok = true;
        const c = compileFront(allocCString(`${scratch()}/front/none.hx`), true, false, null, &ok);
        defer compilationFree(c);

        expect(ok).toBeFalse();
        expect(c.loaded).toBeFalse();
    }
}

describe("compilationFree") {
    beforeAll {
        void put("free/main.hx", "const x: i32 = 1;\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should release a checked compilation and one that never loaded") {
        setQuiet(true);
        let ok = false;
        compilationFree(compileFront(allocCString(`${scratch()}/free/main.hx`), true, false, null, &ok));
        compilationFree(compileFront(allocCString(`${scratch()}/free/none.hx`), true, false, null, &ok));

        expect(ok).toBeFalse();
    }
}

describe("applyChip") {
    beforeAll {
        const chip = "\"chip\": { \"cpu\": \"cortex-m4\", \"fpu\": true, ";
        const flash = "\"flash\": { \"origin\": \"0x08000000\", \"size\": \"512K\" }, ";
        const ram = "\"ram\": { \"origin\": \"0x20000000\", \"size\": \"128K\" } }";
        void put("fw/helix.jsonc", allocCString(`{ "name": "fw", "version": "1.0.0", ${chip}${flash}${ram} }\n`));
        void put("fw/main.hx", "\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should take the target, CPU, and memory from the package's chip") {
        let options = defaultOptions();
        options.file = allocCString(`${scratch()}/fw/main.hx`);

        expect(applyChip(&options)).toBeTrue();
        expect(options.target ?? "").toBe("thumbv7em-freestanding-eabihf");
        expect(options.cpu ?? "").toBe("cortex-m4");
        expect(options.flash ?? "").toBe("0x08000000:512K");
        expect(options.ram ?? "").toBe("0x20000000:128K");
    }

    test("should keep what the command line sets over the chip") {
        let options = defaultOptions();
        options.file = allocCString(`${scratch()}/fw/main.hx`);
        options.cpu = "cortex-m7";

        expect(applyChip(&options)).toBeTrue();
        expect(options.cpu ?? "").toBe("cortex-m7");
    }

    test("should leave a build for a target other than a Cortex-M alone") {
        let options = defaultOptions();
        options.file = allocCString(`${scratch()}/fw/main.hx`);
        options.target = "x86_64-linux";

        expect(applyChip(&options)).toBeTrue();
        expect(options.target ?? "").toBe("x86_64-linux");
        expect(options.flash).toBeNull();
    }

    test("should leave a test build without a target alone") {
        let options = defaultOptions();
        options.file = allocCString(`${scratch()}/fw/main.hx`);
        options.test = true;

        expect(applyChip(&options)).toBeTrue();
        expect(options.target).toBeNull();
    }
}

describe("buildExecutable") {
    beforeAll {
        void put("build/lib.hx", "export const x: i32 = 1;\n");
    }

    afterAll {
        os.removeTree(scratch());
    }

    test("should refuse a target that Helix cannot compile for") {
        let options = defaultOptions();
        options.file = allocCString(`${scratch()}/build/lib.hx`);
        options.target = "sparc-linux";

        expect(buildExecutable(&options, allocCString(`${scratch()}/build/out`))).toBeFalse();
    }

    test("should refuse a program without main") {
        let options = defaultOptions();
        options.file = allocCString(`${scratch()}/build/lib.hx`);

        expect(buildExecutable(&options, allocCString(`${scratch()}/build/out`))).toBeFalse();
        expect(os.exists(allocCString(`${scratch()}/build/out`))).toBeFalse();
    }
}
