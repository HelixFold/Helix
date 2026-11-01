# Debugging

A debug build carries DWARF debug info, so any debugger that reads DWARF can step through Helix code:
lldb on macOS and Linux, gdb on Linux, and an editor that drives one of them.
Breakpoints go by `.hx` file and line, and functions, locals, and types keep their Helix names.

## What a program needs

| Build                                                  | Debug info                                |
|--------------------------------------------------------|-------------------------------------------|
| `helix build app.hx -o app`, the default `debug` mode  | yes                                       |
| `helix build` in a project, the default `debug` mode   | yes, for each program in `.helix-out/bin` |
| `--mode release-safe`, `release-fast`, `release-small` | none                                      |
| `--strip`                                              | none                                      |

- On macOS the debug info sits beside the program in a `.dSYM` folder: `app.dSYM` for `app`.
  Keep the two together, since the debugger looks for the folder next to the program.
  `helix build` copies it into `.helix-out/bin` along with each program.
- On Linux the debug info is inside the executable itself.
- `helix run` builds into a cache and starts the program at once, so build with `helix build` for a debugger.

::: tip 🐞 Install a debugger
macOS has lldb with Xcode's command-line tools: `xcode-select --install`.
On Linux, install `gdb` or `lldb` from the distribution, such as `apt install gdb`.
:::

## Finding a bug

This program should print the average of four numbers, 25, but prints 30:

```hx
struct Stats {
    count: usize,
    total: i64,
}

function collect(values: readonly i64[]): Stats {
    let stats = Stats { count: 0, total: 0 };
    for (const i of 1..values.len) { // [!code warning]
        stats.total += values[i];
        stats.count += 1;
    }
    return stats;
}

export function main(): void {
    const values: i64[4] = [10, 20, 30, 40];
    const stats = collect(&values);
    println(`average: ${stats.total / (stats.count as i64)}`);
}
```

Build it with debug info, start it under lldb, and stop on line 9, inside the loop:

```text
$ helix build average.hx -o average
$ lldb ./average
(lldb) breakpoint set --file average.hx --line 9
(lldb) run
-> 9           stats.total += values[i];
(lldb) frame variable
(readonly i64[]) values = {
  ptr = 0x000000016fdfd5e8
  len = 4
}
(Stats) stats = (count = 0, total = 0)
(u64) i = 1
```

The first pass of the loop already has `i = 1`, so `values[0]` is never added: the range should start at 0.
`continue` runs to the next pass, which confirms it:

```text
(lldb) continue
(lldb) frame variable i stats
(u64) i = 2
(Stats) stats = (count = 1, total = 20)
```

`finish` runs to the end of `collect`, and `next` runs the line that stores its result in `main`:

```text
(lldb) breakpoint delete 1
(lldb) finish
-> 17      const stats = collect(&values);
(lldb) next
(lldb) frame variable stats
(Stats) stats = (count = 3, total = 90)
```

The fix is `for (const i of 0..values.len)`, which prints `average: 25`.

### The same in gdb

```text
$ gdb ./average
(gdb) break average.hx:9
(gdb) run
(gdb) info locals
(gdb) info args
(gdb) continue
(gdb) finish
```

## Commands

| To                                    | lldb                                                          | gdb                                    |
|---------------------------------------|---------------------------------------------------------------|----------------------------------------|
| start the program, with arguments     | `lldb ./app -- one two`, then `run`                           | `gdb --args ./app one two`, then `run` |
| stop at a line                        | `breakpoint set --file app.hx --line 12`                      | `break app.hx:12`                      |
| stop at a line when a condition holds | `breakpoint set --file app.hx --line 12 --condition 'i == 3'` | `break app.hx:12 if i == 3`            |
| stop in a function                    | `breakpoint set --name app.collect`                           | `break app.collect`                    |
| run the next line                     | `next`                                                        | `next`                                 |
| step into a call                      | `step`                                                        | `step`                                 |
| run to the end of the function        | `finish`                                                      | `finish`                               |
| run to the next breakpoint            | `continue`                                                    | `continue`                             |
| show the locals and the arguments     | `frame variable`                                              | `info locals`, `info args`             |
| show one value                        | `frame variable stats.total`                                  | `print stats.total`                    |
| show the calls that led here          | `bt`                                                          | `bt`                                   |
| move to the caller's frame            | `frame select 1`, or `up`                                     | `frame 1`, or `up`                     |

A function's name in the debugger is its module, a dot, and its name: `collect` in `average.hx` is `average.collect`.

::: warning ⏸️ Stopping in a function by its name
A breakpoint on a function's name stops on the line with its signature, before the parameters hold their values.
Run `next` once before reading them, or set the breakpoint on the function's first line instead.
:::

## How values look

The debugger shows each value as the structure that the compiler lowers it to:

| Helix type           | Shown as                                                                            |
|----------------------|-------------------------------------------------------------------------------------|
| `i32`, `bool`, `f64` | the value                                                                           |
| `usize`, `isize`     | `u64` and `i64` on a 64-bit target                                                  |
| a struct             | its fields: `(count = 3, total = 90)`                                               |
| an enum              | the member: `Guest`                                                                 |
| an array, `i32[3]`   | its items: `([0] = 1, [1] = 2, [2] = 3)`                                            |
| `string`             | `(ptr = "helix", len = 5)`                                                          |
| a slice, `i64[]`     | `ptr` and `len`: read an item with `frame variable values.ptr[0]`                   |
| `?i32`               | `(value = 7, present = true)`, or `present = false` for `null`                      |
| `i32 \| Bad`         | `(value = ..., error = Negative)`, where `value` counts only when there is no error |
| a pointer, `*Point`  | the address: `frame variable *p` shows the struct                                   |

## Stopping at a panic

A panic prints its message and a stack trace, then ends the program.
To look at the program at that moment, stop where the runtime reports it.
Every panic goes through a function whose name starts with `helix.panic`:

```hx
function pick(items: readonly i32[], index: usize): i32 {
    return items[index];                    // index 3 of 3 // [!code error]
}

export function main(): void {
    const items: i32[3] = [10, 20, 30];
    let index: usize = 2;
    index += 1;
    println(pick(&items, index));
}
```

```text
$ lldb ./crash
(lldb) breakpoint set --func-regex '^helix\.panic'
(lldb) run
(lldb) bt
   * frame #0: crash`helix.panic_bounds
     frame #1: crash`crash.pick(items=readonly i32[] @ 0x000000016fdfd5c8, index=3) at crash.hx:2:5
     frame #2: crash`crash.main at crash.hx:9:5
(lldb) frame select 1
(lldb) frame variable
(readonly i32[]) items = {
  ptr = 0x000000016fdfd604
  len = 3
}
(u64) index = 3
```

In gdb, `rbreak ^helix\.panic` sets the same breakpoints.

## Attaching to a running program

A program that is already running, such as a server, can be debugged without restarting it.
Attach by its process ID:

```hx
extern "C" function sleep(seconds: u32): u32;

function handle(request: u32): u32 {
    return request * 2; // [!code focus]
}

export function main(): void {
    let served: u32 = 0;
    while (served < 30) {
        served += handle(served);
        served += 1;
        void sleep(1);
    }
    println(`served ${served}`);
}
```

```text
$ ./server &
[1] 26491
$ lldb -p 26491
(lldb) breakpoint set --file server.hx --line 4
(lldb) continue
-> 4       return request * 2;
(lldb) frame variable
(u32) request = 4
(lldb) detach
```

| To                                     | lldb                                     | gdb                      |
|----------------------------------------|------------------------------------------|--------------------------|
| attach to a process ID                 | `lldb -p 26491`                          | `gdb -p 26491`           |
| attach by name                         | `lldb -n server`                         | `gdb -p $(pidof server)` |
| wait for the next program of that name | `process attach --name server --waitfor` |                          |
| leave the program running, and quit    | `detach`                                 | `detach`                 |

Attaching stops the program until `continue`.
`--waitfor` suits a program that ends too soon to attach to by hand: start the debugger first, then the program.

::: info 🔒 Permission to attach
On Linux, attaching to a process that the debugger didn't start can need permission:
`/proc/sys/kernel/yama/ptrace_scope` set to `1` allows it only for a parent process, so run the debugger with `sudo`,
or start the program from the debugger instead.
On macOS, the first attach may ask for permission to use the developer tools.
:::

## In an editor

An editor debugs Helix through lldb.
In VS Code, install the CodeLLDB extension, and add a launch configuration that builds the program first:

::: code-group
```jsonc [.vscode/launch.json]
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug app",
            "type": "lldb",
            "request": "launch",
            "program": "${workspaceFolder}/.helix-out/bin/app",
            "args": [],
            "cwd": "${workspaceFolder}",
            "preLaunchTask": "helix build",
        },
        {
            "name": "Attach to app",
            "type": "lldb",
            "request": "attach",
            "program": "${workspaceFolder}/.helix-out/bin/app",
        },
    ],
}
```
```jsonc [.vscode/tasks.json]
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "helix build",
            "type": "shell",
            "command": "helix build",
            "group": "build",
        },
    ],
}
```
```jsonc [.vscode/settings.json]
{
    // lets breakpoints be set in .hx files, which no extension registers for a debugger
    "debug.allowBreakpointsEverywhere": true,
}
```
:::

## See also

- [Safety](/language/safety) for panics and the checks behind them
- [Command Line](/reference/cli) for `--mode` and `--strip`
- [Testing](/projects/testing)
