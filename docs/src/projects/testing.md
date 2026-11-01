# Testing

`describe`, `test`, and `expect` are part of the language, and `helix test` runs them.
Each test runs in its own process, so a panic or a timeout fails only that test.

## A spec

A spec sits next to the file that it tests, named `<name>.spec.hx`:

::: code-group
```hx [port.spec.hx]
import { parsePort, PortError } from "./port";

describe("parsePort") {
    test("should read a plain port") {
        expect(try parsePort("8080")).toBe(8080); // [!code highlight]
    }

    test("should reject an empty string") {
        expect(parsePort("")).toThrow(PortError.Empty); // [!code highlight]
    }

    test("should accept the highest port") {
        expect(parsePort("65535")).toSucceed(); // [!code highlight]
    }
}
```
```hx [port.hx]
import { parseInt } from "std";

export error PortError { Empty, OutOfRange }

export function parsePort(text: string): u16 | Error {
    if (text.len == 0) throw PortError.Empty;
    const value = try parseInt(text);
    if (value < 1 || value > 65535) throw PortError.OutOfRange;
    return value as u16;
}
```
:::

```text
$ helix test
 PASS port.spec.hx (3 tests, 1.9 ms)
Tests:  3 passed, 3 total
Time:   0.21 s
```

- `describe`, `test`, `expect`, the hooks, and `testing` need no import.
- A spec sees only what its source exports.
  To test a private helper, put a `describe` in the source file itself:
  test blocks are left out of every build that isn't a test build.
- A test body may use `try`, and an error that escapes it fails the test.
- `it` is another name for `test`, and `test` and `describe` may also sit at the top level of a file.
- `helix test` runs the tests of the file that it builds, not those of the files it imports, so each test runs once.
- `helix build`, `run`, and `check` don't check test blocks at all, and `helix check --test` does.

## Fixtures and hooks

Variables at the top of a `describe` are its fixture, and **each test gets a fresh copy**, so no test leaks state
into another:

```hx
import { ArrayList } from "std";

describe("ArrayList") {
    let list: ArrayList<i32> = undefined;

    beforeEach { // [!code focus:7]
        list = ArrayList<i32>.init(testing.allocator);
    }

    afterEach {
        list.deinit();
    }

    test("should start empty") {
        expect(list.items).toHaveLength(0);
    }

    test("should keep items in insertion order") {
        try list.append(1);
        try list.append(2);

        try require(list.items).toHaveLength(2);    // stops the test here when it fails // [!code highlight]
        expect(list.items).toEqual([1, 2]);
    }
}
```

| Hook         | Runs                                                       |
|--------------|------------------------------------------------------------|
| `beforeAll`  | once, before the block's first test                        |
| `afterAll`   | once, after its last test                                  |
| `beforeEach` | before every test in the block and in the blocks inside it |
| `afterEach`  | after every test, also when the test fails                 |

::: info 🧪 A fresh copy, literally
Each `describe` runs in its own process, which sets up its fixtures and runs `beforeAll`, then forks once per test.
What `beforeAll` does is in every test's copy, and what a test does is in nobody else's.
:::

`before*` hooks run outermost first, and `after*` hooks innermost first.
A hook body and the first value of a fixture may use `try`, and a hook failing fails every test that it guards.
A fixture follows the usual rules for variables: it needs a value, or `= undefined` when a hook sets it.

On Windows, which has no fork, each test is a process of its own that first sets up the describes around it.
The copy is just as fresh, but `beforeAll` runs once per test, so its side effects, such as printing, show for each
test.

## expect and require

A failed `expect` records the failure and lets the test go on, so one run reports every broken assertion.
`require` stops the test instead, and returns an error, so the early exit is visible as a `try`:

```hx
try require(list.items).toHaveLength(1);    // stop here if this fails
expect(list.items[0]).toBe(7);              // safe: the length is known
```

A failure shows what was expected and what was received:

```text
 FAIL port.spec.hx (8 tests, 1 failed, 72.2 ms)

  ✗ ArrayList › should keep items in insertion order (0.8 ms)
    expect(list.items).toEqual([1, 3])

    Expected: [1, 3]
    Received: [1, 2]

    at port.spec.hx:38:9

Tests:  1 failed, 1 todo, 6 passed, 8 total
```

| Group    | Matchers                                                                                                     |
|----------|--------------------------------------------------------------------------------------------------------------|
| Equality | `toBe`, which compares strings by their text, and `toEqual`, deep and structural                             |
| Optional | `toBeNull`, `toBeDefined`                                                                                    |
| Bool     | `toBeTrue`, `toBeFalse`                                                                                      |
| Numbers  | `toBeGreaterThan`, `toBeGreaterThanOrEqual`, `toBeLessThan`, `toBeLessThanOrEqual`, `toBeCloseTo(v, digits)` |
| Slices   | `toHaveLength`, `toContain`, `toContainEqual`                                                                |
| Strings  | `toStartWith`, `toEndWith`, `toInclude`, `toMatch(glob)`, `toHaveLength`                                     |
| Errors   | `toThrow()`, `toThrow(MyError.Case)`, `toSucceed()`                                                          |
| Modifier | `.not`, as in `expect(name).not.toBe("zig")`                                                                 |

Errors are values, so `toThrow` takes the fallible call itself, with no closure.
Matchers are type-checked: `expect(count).toBe("3")` is a compile error, not a failing test.
So is `toBe` on a struct, which has no `==`:

```text
error: `toBe` compares with `==`, which `P` doesn't have
  = hint: use `toEqual`, which compares field by field
```

`expect` and `require` work in tests and hooks only, so a `comptime` block can't use them.
`toEqual` and `toContain` take an array literal where the subject is a slice: `expect(list.items).toEqual([1, 2])`.

## Modifiers

```hx
test.skip("should handle IPv6") { ... }
test.only("should read a plain port") { ... }              // remove before committing // [!code warning]
test.todo("should support named ports");                    // without a body
test.failing("should parse nested arrays") { ... }          // passes only while it fails: a known bug
test.panics("should stop on a read past the end", "index out of bounds") { // [!code highlight]
    void list.items[5];                                     // passes only if it panics with this message
}

describe.skip("legacy") { ... }
describe.only("parser") { ... }

test("should finish a large parse", { timeout: 10_000 }) { ... }   // the options of one test // [!code highlight]
```

A test that runs past its timeout fails with `timed out after 10000 ms`.

## testing.allocator

`testing.allocator` is a [`DebugAllocator`](/language/memory#allocators) that is fresh for each test.
It panics on a bad free, and a leak fails the test with the leaked sizes.

## Running specs

```bash
helix test                          # every spec under the current folder
helix test src lib                  # the specs under these folders
helix test src/port.spec.hx         # one file
helix test -s 'src/net/**'          # spec files whose path matches a pattern
helix test -f 'parsePort'           # tests whose describe and test names match a regex
helix test -v                       # lists every test, not only failures
helix test -b                       # stops after the first failing spec
helix test -t 10000                 # the timeout of each test in ms, 5000 by default
helix test --mode release-safe
helix test --reporter json          # one JSON event per line, for editors and tools
```

Without a path, `helix test` searches the current folder, skipping hidden folders, `build`, and `node_modules`,
for `*.spec.hx` files and other `.hx` files with a top-level `describe` or `test`.
`--reporter teamcity` prints the messages that JetBrains IDEs show as a test tree.

Output that a test writes is captured, and printed only when the test fails.

A panic fails only its test, and shows where it happened:

```text
 FAIL use.spec.hx (2 tests, 1 panicked, 61.1 ms)

  ✗ should stop (59 ms)
    panic: index out of bounds: index 2, len 2
     --> use.spec.hx:3:9
    stack trace:
      at test "should stop" (use.spec.hx:3)

Tests:  1 panicked, 1 passed, 2 total
```

## How the runner works

1. Each spec file is built on its own into a test binary.
   Test bodies, each `describe`'s set-up, and its hooks become functions, and a table that the compiler generates
   lists them in source order, so nothing is discovered at run time.
   A spec that doesn't compile is reported, and the others still run.
2. The binary walks the table.
   Every `describe` runs in a forked process, and every test in a process forked from that one,
   so a panic, a crash, or a timeout ends only that process, and its parent records the result.

## See also

- [Errors](/language/errors)
- [build.hx](/projects/build) for the `test` step
- [Command Line](/reference/cli)
