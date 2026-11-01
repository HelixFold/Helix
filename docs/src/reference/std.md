# Standard Library

`std` ships with the compiler and is written in Helix.
::: tip 📚 What "std" gives
`import { ... } from "std"` takes from `std/io`, `std/fs`, `std/text`, `std/heap`, `std/list`, and `std/process`.
The other modules are imported by their own path, such as `"std/fmt"`.
:::

| Module        | Contents                                                                                                                    |
|---------------|-----------------------------------------------------------------------------------------------------------------------------|
| `std/heap`    | `Allocator`, `cAllocator`, `ArenaAllocator`, `DebugAllocator`, `alloc`, `resize`, `free`, `create`, `destroy`               |
| `std/list`    | `ArrayList<T>`: `init`, `append`, `pop`, `clear`, `deinit`                                                                  |
| `std/text`    | `equal`, `startsWith`, `endsWith`, `indexOf`, `trim`, `parseInt`, and the iterators `split` and `lines`                     |
| `std/fmt`     | `alloc`, `bufPrint`, `count`, and `Builder`, a growable string                                                              |
| `std/io`      | `Writer`, `Reader`, `stdout`, `stderr`, `fprint`, `fprintln`                                                                |
| `std/fs`      | `File`, `Dir`, `readFile`, `writeFile`, `deleteFile`, `makePath`, `copyFile`, `stat`, `exists`, `rename`, `deleteTree`, ... |
| `std/process` | `Init`, `Env`, `run`, `capture`, `captureAll`, `captureAllWith`, `exit`                                                     |
| `std/json`    | `parseJson` into a `JsonValue` with source spans, `lineCol`, `writeJsonString`                                              |
| `std/sha256`  | `sha256`, the streaming `Sha256`, and `toHex`                                                                               |
| `std/target`  | `target`, the machine that a build is for (see [Compile Time](/language/comptime#per-target-code))                          |
| `std/mmio`    | memory-mapped registers for firmware, and the Cortex-M `SYSTICK` and NVIC                                                   |
| `std/testing` | `allocator` and `TestError`, visible in specs as `testing`                                                                  |
| `std/build`   | `Build` and the runner behind `helix build` (see [build.hx](/projects/build))                                               |

## std/heap

Code that allocates takes a `dyn Allocator`, so every allocation is visible.
See [Memory](/language/memory#allocators) for each allocator and function.

```hx
import { ArrayList, DebugAllocator, cAllocator } from "std";

let debug = DebugAllocator.init(cAllocator());
defer void debug.deinit();

let list = ArrayList<i32>.init(debug.allocator());
defer list.deinit();
try list.append(1);
```

## std/text

Text functions take and return slices, so none of them allocates:

```hx
import { equal, startsWith, indexOf, parseInt, split, trim } from "std";

equal("a", "a");                // true
startsWith("helix", "he");      // true
indexOf("helix", "li");         // 2, or null when it isn't there
try parseInt("-42");            // -42, or ParseIntError
trim("  hi \n");                // "hi"

for (const part of split("a,b,,c", ",")) print(`[${part}]`);     // [a][b][][c]
for (const line of lines(text)) println(line);
```

## std/fmt

`std/fmt` formats template strings without hidden allocation:

```hx
import * as fmt from "std/fmt";
import { stdout, fprintln, cAllocator, free } from "std";

const a = cAllocator();
const label = try fmt.alloc(a, `user-${id}`);       // u8[] from `a` // [!code highlight]
defer free(a, label);

let buf: u8[32] = undefined;
const pair = try fmt.bufPrint(&buf, `${3},${4}`);   // into your buffer, or FormatError.NoSpaceLeft

let b = fmt.Builder.init(a);                        // a growable string
defer b.deinit();
for (const i of 0..3) try b.append(`[${i}]`);

try fprintln(stdout(), `${label} ${pair} ${b.text()}`);     // user-7 3,4 [0][1][2]
```

A parameter of type `Format` takes a template string.
The template's values are evaluated at the call and formatted into the writer, so a `Format` can't be stored or
returned.

## std/fs

```hx
import { readFile, writeFile, deleteFile, exists, cAllocator, free } from "std";

const a = cAllocator();
try writeFile("notes.txt", "first line\n");
const text = try readFile(a, "notes.txt");
defer free(a, text);
println(exists("notes.txt"));       // true
try deleteFile("notes.txt");
```

`File` opens, creates, appends to, reads, and writes one file, and `Dir` lists a folder:

```hx
let dir = try Dir.open("src");
defer dir.close();
while (const name = try dir.next()) println(name);
```

Failures are `FsError`: `NotFound`, `AccessDenied`, `IsDirectory`, `AlreadyExists`, `NoSpace`, `NameTooLong`,
`Unexpected`.

## std/process

```hx
import { run, capture, captureAllWith, CaptureOptions, cAllocator, free } from "std";

const status = try run(["git", "status"]);              // its exit status
const out = try capture(a, ["echo", "hi"]);             // its stdout, in memory
const slow = try captureAllWith(a, ["make"], CaptureOptions { dir: "build", timeout: 3000 });
```

| Function                           | Does                                             |
|------------------------------------|--------------------------------------------------|
| `run(argv)`                        | runs a program and waits for it                  |
| `capture(a, argv)`                 | the same, with its stdout in memory              |
| `captureAll(a, argv)`              | the same, with stdout and stderr apart           |
| `captureAllWith(a, argv, options)` | the same, in a folder and with a time limit      |
| `exit(code)`                       | ends the program at once, without running defers |

`Init` and `Env` carry the command line and the environment (see [Functions](/language/functions#main)).

## std/json

```hx
import { parseJson, JsonOptions, JsonProblem } from "std/json";

let problem: JsonProblem = undefined;
const value = try parseJson(arena.allocator(), "{ \"port\": 8080 }", JsonOptions { comments: false }, &problem);
println(value.kind);                // Object
```

Each `JsonValue` keeps its place in the source, and `lineCol` turns that into a line and a column for a message.
`comments: true` reads `//` and `/* */` comments, as in `helix.jsonc`.

## std/sha256

```hx
import { sha256, toHex } from "std/sha256";

const digest = sha256("abc");       // u8[32]
const hex = toHex(digest);          // u8[64]: "ba7816bf8f01cfea..."
```

`Sha256` hashes data that arrives in pieces, with `init`, `update`, and `finish`.

## std/io

`Writer` and `Reader` are the interfaces that output and input go through,
and `stdout()` and `stderr()` share their buffer with `print` and `eprint`.
`fprint` and `fprintln` format a template into any `dyn Writer`.

## See also

- [Memory](/language/memory)
- [Testing](/projects/testing)
- [build.hx](/projects/build)
