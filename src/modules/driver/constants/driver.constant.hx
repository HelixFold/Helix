/**
 * The lines that `helix help` prints, one entry per line.
 *
 * @remarks
 * The list covers the commands, the options that compiling commands take, and the options of `helix test`.
 * `helix help`, `helix --help`, and `helix -h` print it to stdout.
 * Running `helix` without a command, or with an unknown one, prints it to stderr.
 *
 * @example
 * ```hx
 * Usage[0]; // 'Usage: helix <command> [options]'
 * ```
 *
 * @see run
 * @since 1.0.0
 */

export const Usage: readonly string[] = [
    "Usage: helix <command> [options]",
    "",
    "Commands:",
    "  build [steps] [-Dk=v]     Build the project: helix.jsonc's bin, then build.hx (--target, --mode; --help)",
    "  run <file.hx> [-- args]   Build and run a program",
    "  build <file.hx>           Build an executable from one file",
    "  cc [--target t] args      The system C compiler, aimed at a Helix target",
    "  translate-c <header.h>    Helix declarations for a C header (-o out.hx, -I, -D, --dir, --all)",
    "  translate-svd <chip.svd>  A microcontroller's registers and interrupts, from its SVD file (-o out.hx)",
    "  chips [filter]            The microcontrollers --chip and helix.jsonc's \"chip\" know, by name",
    "  test [files or dirs]      Run tests (default: every spec under the current directory; --reporter json|teamcity)",
    "  check <file.hx>           Report errors without building (--test also checks its tests)",
    "  ir <file.hx>              Print the optimized LLVM IR",
    "  ast <file.hx>             Print the syntax tree",
    "  tokens <file.hx>          Print the token stream",
    "  lsp                       The language server editors start (docs/design/ide.md)",
    "  debug-launch <file.hx>    Build for debugging; print how to start lldb-dap on it (JSON)",
    "  actions <file or folder>  What an editor runs for it: build, run, debug, test (JSON)",
    "  version                   Print the Helix and LLVM versions",
    "",
    "Packages are hpm's: `hpm init`, `hpm add <name>`, `hpm install` (see `hpm help`).",
    "",
    "Options:",
    "  -o <path>                 Output path for `build` (default: the file name without .hx)",
    "  --mode <mode>             debug (default), release-safe, release-fast, release-small",
    "  --target <arch-os[-abi]>  cross-compile: aarch64-macos, arm64e-macos, x86_64-linux-gnu, ...",
    "  --emit obj                write the object file instead of linking",
    "  --cpu <name>              native, generic, or an LLVM CPU name (apple-m1, x86-64-v3, ...)",
    "  --strip                   no debug info or local symbols",
    "  --pkg <name=path>         what `import ... from \"name\"` means, instead of helix-modules",
    "  --pkg-in <root> <name=path>  the same, for the code of the package whose root module is <root>",
    "  --link <file>, -l<name>   link an object, archive or system library too",
    "",
    "Test options:",
    "  -s <glob>                 only spec files whose path matches",
    "  -f <regex>                only tests whose describe/test names match",
    "  -b                        stop after the first failure",
    "  -v                        list every test, not only failures",
    "  -t <ms>                   per-test timeout (default 5000)",
];

/**
 * The line starts that mark a top-level test in a source file.
 *
 * @remarks
 * A `.hx` file that is not named `*.spec.hx` still runs under `helix test`
 * when one of its lines begins with `describe`, `test`, or `it`, followed by `(` or `.`.
 * Only a line that starts at column 0 counts, so an indented call inside a function does not.
 *
 * @example
 * ```hx
 * TestStarts[0]; // 'describe('
 * ```
 *
 * @since 1.0.0
 */

export const TestStarts: string[6] = ["describe(", "describe.", "test(", "test.", "it(", "it."];
