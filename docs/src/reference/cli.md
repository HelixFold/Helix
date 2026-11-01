# Command Line

Everything goes through one program, `helix`.

## Commands

| Command                              | Does                                                                                                       |
|--------------------------------------|------------------------------------------------------------------------------------------------------------|
| `helix run <file.hx> [-- args]`      | builds and runs a program, passing on the arguments after `--`                                             |
| `helix build <file.hx>`              | builds an executable from one file, named after it, or `-o <path>`                                         |
| `helix build [steps] [--name=value]` | builds the project: `helix.jsonc`'s programs, then `build.hx` (see [build.hx](/projects/build))            |
| `helix check <file.hx>`              | reports errors without building, and `--test` checks the tests too                                         |
| `helix test [files or folders]`      | runs the specs (see [Testing](/projects/testing))                                                          |
| `helix translate-c <header.h>`       | Helix declarations for a C header (see [C Interop](/language/c-interop#translate-c))                       |
| `helix translate-svd <chip.svd>`     | a microcontroller's registers and interrupts (see [Targets](/projects/targets#registers-from-an-svd-file)) |
| `helix chips [filter]`               | the chips that `--chip` and `helix.jsonc`'s `chip` know                                                    |
| `helix cc [--target t] args`         | the clang of the compiler's LLVM, aimed at a Helix target                                                  |
| `helix ir <file.hx>`                 | prints the optimized LLVM IR                                                                               |
| `helix ast <file.hx>`                | prints the syntax tree                                                                                     |
| `helix tokens <file.hx>`             | prints the token stream                                                                                    |
| `helix version`                      | prints the Helix and LLVM versions                                                                         |

`helix build` with a `.hx` file before any `--` builds that file, and otherwise it builds the project.

## Options

These work on `run`, `build <file>`, `check`, `ir`, and `test`:

| Option                                         | Does                                                                  |
|------------------------------------------------|-----------------------------------------------------------------------|
| `-o <path>`                                    | the output of `build`                                                 |
| `--mode <mode>`                                | `debug` (default), `release-safe`, `release-fast`, or `release-small` |
| `--target <arch-os[-abi]>`                     | builds for another machine (see [Targets](/projects/targets))         |
| `--cpu <name>`                                 | `native`, `generic`, or an LLVM CPU name such as `apple-m1`           |
| `--chip <name>`                                | a microcontroller from the chip table: its core, FPU, and memory      |
| `--flash <origin:size>`, `--ram <origin:size>` | the memory of a Cortex-M chip, such as `0x08000000:512K`              |
| `--linker-script <file>`                       | places a program without an OS in memory                              |
| `--emit obj`                                   | writes the object file instead of linking                             |
| `--strip`                                      | leaves out debug info and local symbols                               |
| `--link <file>`, `-l<name>`                    | links an object, an archive, or a system library too                  |
| `--pkg <name=path>`                            | what `import ... from "name"` means, instead of `helix-modules`       |
| `--pkg-in <root> <name=path>`                  | the same, for the code of the package whose root module is `<root>`   |

## Test options

| Option                | Does                                                           |
|-----------------------|----------------------------------------------------------------|
| `-s <glob>`           | only spec files whose path matches, where `*` also crosses `/` |
| `-f <regex>`          | only tests whose `describe` and `test` names match             |
| `-b`                  | stops after the first failing spec                             |
| `-v`                  | lists every test, not only failures                            |
| `-t <ms>`             | the timeout of each test, 5000 by default                      |
| `--reporter json`     | one JSON event per line, for editors and tools                 |
| `--reporter teamcity` | the messages that JetBrains IDEs show as a test tree           |

## Environment

| Variable     | Does                                                                                                            |
|--------------|-----------------------------------------------------------------------------------------------------------------|
| `HELIX_HOME` | where the toolchain's LLVM, the C libraries that Helix builds, and the caches live, by default `~/.cache/helix` |
| `SDKROOT`    | the macOS SDK, for building for macOS from another machine                                                      |

## Packages

Packages are installed by `hpm`, the package manager, which is a program of its own.
`helix add`, `helix init`, and the other package commands say where they went:

```text
error: `helix add` moved to hpm, the package manager
  = hint: hpm add tls
```

## See also

- [Getting Started](/guide)
- [build.hx](/projects/build)
- [Testing](/projects/testing)
