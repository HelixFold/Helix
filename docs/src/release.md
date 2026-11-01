# Release Notes

What changed in each release of Helix.
The current line is `v1.0.x`.

## v1.0.0-alpha.0

The first alpha: a compiler written in Helix that builds itself, its standard library, and programs for every
target from one `helix`.

```hx
import { ArrayList, DebugAllocator, cAllocator } from "std";

export function main(): void | Error {
    let debug = DebugAllocator.init(cAllocator());
    defer void debug.deinit();

    let list = ArrayList<i32>.init(debug.allocator());
    defer list.deinit();

    for (const i of 0..5) try list.append((i * i) as i32);
    println(`squares ${list.items}`);       // squares [0, 1, 4, 9, 16]
}
```

- **Added**: [the language](language/basics) - integers of any width, floats, slices, arrays, strings, and
  [structs with methods, enums, and tagged unions](language/types).
- **Added**: [errors as values](language/errors) with `throw`, `try`, `catch`, `defer`, and `errdefer`,
  and [optionals](language/optionals) with null narrowing.
- **Added**: [`switch` with patterns](language/control-flow#switch), ranges, guards, and struct patterns,
  and [iterators](language/control-flow#iterators) for `for-of`.
- **Added**: [generics and interfaces](language/generics), with static and `dyn` dispatch.
- **Added**: [`comptime`](language/comptime) expressions, blocks, and parameters, `@compileError`, and per-target code
  through `std/target`.
- **Added**: [C interop](language/c-interop) - `extern "C"` in both directions, the C ABI for structs by value,
  callbacks, and `helix translate-c`.
- **Added**: [runtime safety](language/safety) - overflow, bounds, null, and cast checks that panic with the source
  line, and `DebugAllocator` for memory mistakes.
- **Added**: [tests](projects/testing) - `describe`, `test`, `expect`, hooks, fixtures, and `helix test`, which runs
  each test in its own process.
- **Added**: [projects](projects/manifest) with `helix.jsonc` and [`build.hx`](projects/build),
  whose options are `--name=value`.
- **Added**: [debugging](projects/debugging) with lldb or gdb, by Helix file and line,
  and `helix build` installs the `.dSYM` debug info of each program beside it on macOS.
- **Added**: [cross-compiling](projects/targets) for macOS, static Linux, Windows, WASI, boards without an OS, and
  Cortex-M microcontrollers, with `helix translate-svd`.
- **Added**: [the standard library](reference/std): allocators, `ArrayList`, text, formatting, files, processes, JSON,
  and SHA-256.

## See also

- [Getting Started](guide)
- [Command Line](reference/cli)
