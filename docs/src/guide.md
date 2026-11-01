# Getting Started

This page builds the compiler, runs a first program, and sets up a project with specs.

## Build the compiler

Helix has no published release yet, so the compiler is built from this repository with a Helix toolchain.
The repository ships one for x86_64 Linux in `.github/bootstrap`, which is what CI uses:

```bash
git clone https://github.com/HelixFold/Helix && cd Helix
tar -xJf .github/bootstrap/helix-1.0.0-alpha.0-x86_64-linux.tar.xz -C "$HOME/.local"
export PATH="$HOME/.local/helix-1.0.0-alpha.0-x86_64-linux:$PATH"
export HELIX_HOME="$HOME/.local/helix-1.0.0-alpha.0-x86_64-linux/lib"

helix build          # the compiler, in .helix-out/bin/helix # [!code highlight]
helix build test     # its specs, run by the compiler the build just made
helix build e2e      # the end-to-end checks in e2e/
```

::: warning 🐧 Linux x86_64 only, for now
The bootstrap toolchain is built for x86_64 Linux, and there is no prebuilt toolchain for other machines yet.
:::

The toolchain's `lib` folder holds the static LLVM, clang, lld, and the C library sources that the compiler needs,
laid out as a `HELIX_HOME`.
The new compiler reads the standard library from the `lib` folder of the repository, two folders above `.helix-out/bin`.

::: info 🧰 What the toolchain brings
`helix` never runs the system `cc`, `ld`, or `xcrun`.
It compiles C with the clang of its own LLVM and links with the lld built into it,
so the same compiler builds for every target.
See [Targets](/projects/targets).
:::

## Your first program

Save this as `hello.hx`, then run it:

::: code-group
```hx [hello.hx]
function add(a: i32, b: i32): i32 {
    return a + b;
}

export function main(): void { // [!code focus:3]
    println(`hello from helix: ${add(40, 2)}`);
}
```
```bash [run]
helix run hello.hx                  # hello from helix: 42
helix build hello.hx -o hello       # an executable named hello
helix check hello.hx                # the errors only, without building
```
:::

`main` is the entry point.
`println` takes a template string, and the compiler writes the formatting for each `${...}` from its type, so there is
no format string to get wrong.

## Build modes

Every command takes `--mode`:

| Mode              | Runtime checks | Optimized | Use it for                            |
|-------------------|----------------|-----------|---------------------------------------|
| `debug` (default) | yes            | no        | development, with debug info          |
| `release-safe`    | yes            | yes       | production code that keeps its checks |
| `release-fast`    | no             | yes       | measured hot paths                    |
| `release-small`   | no             | for size  | firmware and small binaries           |

```bash
helix run hello.hx --mode release-fast
```

In `debug` and `release-safe`, overflow, bounds, null, and cast checks panic with the source line.
See [Safety](/language/safety).

## A project

A folder with a `helix.jsonc` is a project:

```jsonc
{
    "name": "greet",
    "version": "0.1.0",
    "bin": { "greet": "src/main.hx" },
}
```

```bash
helix build                # builds each program of "bin" into .helix-out/bin
helix build run -- ada     # builds and runs it, passing on the arguments after --
helix build test           # runs the specs in src/
```

A `build.hx` next to it adds options, C sources, and steps of its own.
See [helix.jsonc](/projects/manifest) and [build.hx](/projects/build).

## Specs

A spec sits next to the file that it tests, as `<name>.spec.hx`.
`describe`, `test`, and `expect` are part of the language, so a spec imports only the code under test:

```hx
// src/port.spec.hx
import { parsePort, PortError } from "./port";

describe("parsePort") {
    test("should read a plain port") {
        expect(try parsePort("8080")).toBe(8080);
    }

    test("should reject an empty string") {
        expect(parsePort("")).toThrow(PortError.Empty);
    }
}
```

```bash
helix test                  # every spec under the current folder
helix test src/port.spec.hx
```

See [Testing](/projects/testing).

## See also

- [Basics](/language/basics)
- [Errors](/language/errors)
- [Command Line](/reference/cli)
- [Examples](/examples/hello), whole programs from a hello world to firmware
