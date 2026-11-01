# build.hx

`helix build` builds a project.
Without a `build.hx` it builds and installs each program of `helix.jsonc`'s `bin`, gives the first one a `run` step,
and tests `src/` in a `test` step, which is the whole build of most projects.
A `build.hx` adds what a project needs beyond that: options, C sources, extra programs, and steps of its own.

## Commands

```bash
helix build                     # the default step, install: each program into helix-out/bin
helix build run -- ada          # builds and runs the program, passing on the arguments after --
helix build test                # runs the specs in src/
helix build --help              # the steps, and the options that build.hx declares
helix build --target x86_64-linux --mode release-fast
```

## An example

::: code-group
```hx [build.hx]
import { Build, Mode } from "std/build";

export function build(b: *Build): void | Error {
    const greeting = b.optionString("greeting", "What greet says first") ?? "hello"; // [!code highlight]
    const loud = b.optionBool("loud", "Shout the greeting") ?? false; // [!code highlight]

    const config = try b.addOptions("config");          // a module that the program imports
    try config.addString("greeting", greeting);
    try config.addBool("loud", loud);

    const greet = try b.bin("greet");                   // helix.jsonc's program
    try greet.addOptions(config);

    const release = try b.step("release", "greet for Linux, in helix-out/linux");
    const linux = try b.addExecutable({ name: "greet", root: "src/main.hx", target: "x86_64-linux", mode: Mode.ReleaseSafe });
    try linux.addOptions(config);
    try release.dependOn(try b.addInstall(linux, "linux"));
}
```
```jsonc [helix.jsonc]
{
    "name": "greet",
    "version": "0.1.0",
    "bin": { "greet": "src/main.hx" },
}
```
```hx [src/main.hx]
import { Init } from "std";
import { greeting, loud } from "config";                // the module that build.hx made // [!code highlight]

export function main(init: Init): void {
    const name = init.args.len > 0 ? init.args[0] : "world";
    println(`${greeting}${loud ? "!" : ""} ${name}`);
}
```
:::

```bash
helix build run -- ada                      # hello ada
helix build run --greeting=hi --loud -- ada # hi! ada
helix build release                         # helix-out/linux/greet
```

```text
$ helix build --help
Usage: helix build [steps] [--target t] [--mode m] [--name=value] [-v] [-- program args]

Steps:
  install  Build everything `install`ed into helix-out/ (the default)
  run  Build and run the program; arguments after `--` go to it
  test  Run the tests
  release  greet for Linux, in helix-out/linux

Options (from build.hx):
  --greeting=[string]  What greet says first
  --loud=[bool]  Shout the greeting

General:
  --target t  what to build for: aarch64-macos, x86_64-linux-gnu, x86_64-windows, ... (default: this machine)
  --mode m  debug (default), release-safe, release-fast or release-small
  -v  print each command
  --steps  list the steps
  --help  this list
```

## Options

A build script declares its options, and the command line sets them as `--name=value`, or `--name` for `true`:

| Call                                | Gives                                                            |
|-------------------------------------|------------------------------------------------------------------|
| `b.optionBool(name, description)`   | `true` for `--name` or `--name=true`, `false` for `--name=false` |
| `b.optionString(name, description)` | the text after `--name=`                                         |
| `b.optionInt(name, description)`    | the whole number after `--name=`                                 |

Each gives `null` when the command line leaves the option out.
An option that the script never declares is an error, so a misspelled one never silently does nothing:

```text
error: build.hx has no option --nope; `helix build --help` lists them
```

::: warning 🔁 No more `-D`
Options used to be written `-Dname=value`.
They are now `--name=value`, and `-D` is an unknown option:

```bash
helix build run -Dgreeting=hi    # error: unknown option '-Dgreeting=hi' # [!code --]
helix build run --greeting=hi    # [!code ++]
```
:::

`--target`, `--mode`, `--steps`, `--help`, and `-v` belong to `helix build` itself,
and the script reads the first two as `b.target` and `b.mode`.

## The Build API

| Member                                                                       | Does                                                                         |
|------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| `target`, `mode`                                                             | `--target`, null for this machine, and `--mode`, debug when not given        |
| `bin(name)`                                                                  | the program that `helix.jsonc` names, already built and installed, to add to |
| `addOptions(name)`                                                           | a module of constants, filled with `addBool`, `addInt`, and `addString`      |
| `addExecutable({ name, root, target?, mode?, strip?, cpu?, linkerScript? })` | a program that isn't in `bin`, such as a code generator                      |
| `addTestStep({ root, mode?, target?, linkWith? })`                           | replaces the `test` step with `helix test` on a file or folder               |
| `addRunStep(artifact)`                                                       | replaces the `run` step                                                      |
| `install(artifact)`                                                          | copies it into `helix-out/bin` as part of `install`                          |
| `addInstall(artifact, dir)`                                                  | a step that copies it into `helix-out/<dir>`                                 |
| `step(name, description)`                                                    | a step of its own, and `dependOn(other)` orders steps                        |
| `addSystemCommand(argv)`                                                     | a step that runs a program                                                   |

| Artifact member | Does |
|-----------------|------|
| `addCSources({ files, flags })` | C files compiled for the artifact's target and mode |
| `addIncludeDir(path)` | an include folder for its C |
| `linkSystemLibrary(name)` | links `-l<name>` |
| `addOptions(options)` | lets it import an options module |

`target: "native"` builds for this machine whatever `--target` says, which suits a code generator that runs during
the build.

## Rules

`helix.jsonc` owns the programs, and `build.hx` adds to them:

- `b.addExecutable` with a name from `bin`, for the build's own target and mode, is an error:
  `"greet" is a program in helix.jsonc's "bin"`.
  The same program for another target or mode is a new artifact, as the `release` step above shows.
- `b.bin(name)` of a name that isn't in `bin` is an error.
- A dependency's `build.hx` never runs: a package is built from its `helix.jsonc` alone.

## How it runs

`helix build` compiles `build.hx` together with the runner from `std/build` into `.helix-cache/build`, then runs it.
The `build` function only records artifacts and steps.
The runner then performs the steps that the command line names, each one's dependencies first,
by starting `helix` and `helix cc`.

## See also

- [helix.jsonc](/projects/manifest)
- [Targets](/projects/targets)
- [Testing](/projects/testing)
