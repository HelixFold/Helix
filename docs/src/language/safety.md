# Safety

Helix checks what it can while compiling, and checks the rest while the program runs in `debug` and `release-safe`.
A failed check at run time is a panic: the message, the source line, and a stack trace.

## A panic

```hx
function grow(level: i32): i32 {
    return level * 2;                       // 3_000_000_002 doesn't fit in i32 // [!code error]
}

export function main(): void {
    let level: i32 = 1_500_000_000;
    level += 1;
    println(grow(level));
}
```

```text
panic: integer overflow
 --> overflow.hx:2:12
  |
2 |     return level * 2;
  |            ^~~~~~~~~
stack trace:
  at overflow.grow (overflow.hx:2)
  at overflow.main (overflow.hx:8)
```

A panic aborts the program with exit status 134.
Defers don't run, and output printed before it still appears.

## Checks at run time

| Check       | Triggers on                                                  | Message                                                  |
|-------------|--------------------------------------------------------------|----------------------------------------------------------|
| Overflow    | `+ - *`, unary `-`, `++`, `--`, and `/` of the minimum by -1 | integer overflow                                         |
| Bounds      | `items[i]` on an array or a slice                            | index out of bounds: index 4, len 4                      |
| Slices      | `items[a..b]`                                                | slice end is out of bounds                               |
| Division    | `x / 0`, `x % 0`                                             | division by zero                                         |
| Shifts      | `x << n` with `n` at least the width                         | shift amount is too large: it must be less than 32       |
| Casts       | `300 as u8`, `-1 as u64`                                     | integer cast out of range: the value doesn't fit in `u8` |
| Float casts | `1e20 as i32`                                                | float cast out of range: the value doesn't fit in `i32`  |
| Unreachable | reaching `unreachable`                                       | reached unreachable code                                 |
| Null        | `x!` on a null                                               | unwrapped a null value                                   |
| `@panic`    | `@panic("configuration is missing")`                         | configuration is missing                                 |

With [`DebugAllocator`](/language/memory#allocators), memory mistakes stop at the access that makes them:

| Mistake                                                    | Message                                                                 |
|------------------------------------------------------------|-------------------------------------------------------------------------|
| A double free, or a free from another allocator            | memory freed twice, or not from this allocator                          |
| Use after free, or a pointer into an `ArrayList` that grew | use after free: this memory (32 bytes) was freed, or moved when it grew |
| A raw pointer past the end of a block                      | invalid memory access at 0x...                                          |

`+% -% *%` wrap and `+| -| *|` saturate, so they never panic, and `<<` drops the bits shifted out, as in C.

## Modes

| Mode            | Checks  | Use it for                            |
|-----------------|---------|---------------------------------------|
| `debug`         | yes     | development                           |
| `release-safe`  | yes     | production code that keeps its checks |
| `release-fast`  | removed | measured hot paths                    |
| `release-small` | removed | firmware and small binaries           |

::: danger 💥 No checks in release-fast
In `release-fast` and `release-small` the checks are gone, and overflow is undefined behavior.
The program above prints `-1294967294` there instead of panicking.
:::

## Checks while compiling

Some mistakes never reach a run:

- unused locals, parameters, imports, and results, and a `let` that never changes
- `if (count)` on a number, implicit narrowing, and `===`
- an error that nobody handles, and a `try` in a function that can't fail
- an optional used without a check for `null`
- a `switch` that misses an enum member or a union variant
- a pointer to a local that outlives the function, and reading `undefined` before writing it
- a constant expression that overflows, and a constant index out of bounds
- raw pointer indexing outside `unsafe`

Each one is shown on the page for its feature, with the compiler's hint.

## Debugging

Debug builds carry DWARF debug info, so `lldb ./app` sets breakpoints by Helix file and line,
and `frame variable` shows locals with their Helix names and types.
A breakpoint on `helix.panic` stops the program at a panic, with the line that caused it one frame up.
See [Debugging](/projects/debugging).

## See also

- [Basics](/language/basics#rules-the-compiler-enforces)
- [Memory](/language/memory)
- [Testing](/projects/testing) for `test.panics`
