# Modules

Each file is a module.
Its declarations are private unless they are exported, and importing a module never runs code.

## Exports and imports

```hx
// geometry/point.hx
export struct Point { x: i32, y: i32 }

export function origin(): Point {
    return Point { x: 0, y: 0 };
}

function secret(): i32 {                // private to this file
    return 42;
}
```

```hx
// geometry/index.hx
export { Point, origin } from "./point";    // re-exports
export * from "./area";
```

```hx
// main.hx
import * as geo from "./geometry";                  // a namespace
import { area as areaOf } from "./geometry/area";   // a rename
import { Point } from "./geometry";

export function main(): void {
    const p = Point { x: 3, y: 4 };
    println(`${areaOf(p)} ${geo.origin()}`);        // 12 { x: 0, y: 0 }
}
```

| Form                            | Meaning                                |
|---------------------------------|----------------------------------------|
| `import { a, b } from "./x";`   | names from a module                    |
| `import { a as b } from "./x";` | a name under another name              |
| `import * as x from "./x";`     | the whole module as a namespace, `x.a` |
| `export { a } from "./x";`      | passes a name on                       |
| `export * from "./x";`          | passes every name on                   |

## Resolution

| Spec                | Looks for                                                                                    |
|---------------------|----------------------------------------------------------------------------------------------|
| `"./parser"`        | `./parser.hx`, then `./parser/index.hx`                                                      |
| `"std"`, `"std/fs"` | the standard library that comes with the compiler                                            |
| `"http"`            | a dependency listed in `helix.jsonc`, installed in `helix-modules/`                          |
| `"@lib/shapes"`     | with `"aliases": { "@lib": "src/lib" }`: `src/lib/shapes.hx`, then `src/lib/shapes/index.hx` |

Aliases let deep files skip the `../../`.
An alias must point inside its package, and can't take the name of a dependency's scope.
See [helix.jsonc](/projects/manifest#aliases).

## Rules

- Modules hold only declarations: there are no top-level statements and no module set-up code.
- Analysis is lazy: only the declarations that a program uses are checked and compiled.
- Circular imports are allowed, since declarations resolve on demand.
- An unused import is an error, and so is importing a private name:

```text
error: "./geometry/point" has no export named `secret`
  = hint: it exists but is private; add `export` to its declaration
error: unused import `lines`
  = hint: remove it
```

## Packages

A bare name, such as `"http"`, is a dependency of the package that the importing file belongs to.
Packages are installed by `hpm`, the package manager, which lays them out in `helix-modules/`.
The compiler reads that folder, never the network or a lockfile.
Your code can't import your dependencies' dependencies: add them to your own `helix.jsonc` when you need them.

## See also

- [helix.jsonc](/projects/manifest)
- [Standard Library](/reference/std)
- [C Interop](/language/c-interop)
