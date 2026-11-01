# helix.jsonc

`helix.jsonc` describes a package: its name, its programs, the C it brings, and its dependencies.
It is data only, so a dependency never runs code on your machine while you build.

## An example

```jsonc
{
    "name": "@acme/tls",
    "version": "0.3.1",
    "description": "TLS 1.3 client and server",
    "license": "MIT",
    "helix": ">=1.0.0",                         // the compiler versions it works with

    "exports": { ".": "src/index.hx", "./x509": "src/x509.hx" },
    "bin": { "tls-probe": "src/probe.hx" },     // the programs that helix build builds
    "aliases": { "@x509": "src/x509" },

    "c": {
        "sources": ["c/bearssl/src/*.c"],       // compiled for the consumer's target and mode
        "flags": ["-O2"],
        "includeDirs": ["c/bearssl/inc"],
        "systemLibraries": [],                  // ["z"] links -lz
    },

    "dependencies": {
        "util": "path:../util",
        "json": "^2.1",
    },
}
```

It is JSON with comments (`//` and `/* */`) and trailing commas, as `tsconfig.json` is.
An unknown field is an error with its line and column, so a typo never silently does nothing.

## Fields

| Field                                                                                        | Meaning                                                                                                 |
|----------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| `name`, `version`                                                                            | required, and `name` is what other packages import it by                                                |
| `bin`                                                                                        | program name to root file: what `helix build` builds and installs                                       |
| `exports`                                                                                    | import path to file: what other packages can import, `"."` by default `src/index.hx`                    |
| `c`                                                                                          | the C that the package brings (below)                                                                   |
| `aliases`                                                                                    | `@name` to folder, for imports inside the package (below)                                               |
| `chip`                                                                                       | the microcontroller that a firmware package targets (see [Targets](/projects/targets#microcontrollers)) |
| `dependencies`, `devDependencies`, `peerDependencies`                                        | the packages it uses, installed by `hpm`                                                                |
| `scripts`, `files`, `workspaces`, `registries`                                               | read by `hpm`                                                                                           |
| `description`, `license`, `author`, `repository`, `homepage`, `keywords`, `helix`, `private` | for people and for the registry                                                                         |

## c

```jsonc
"c": {
    "sources": ["c/*.c"],
    "flags": ["-DFAST"],
    "includeDirs": ["c/include"],
    "systemLibraries": ["sqlite3"],
}
```

- `sources` takes `*` in file names, and expands them in sorted order, leaving out hidden files.
- The files are compiled once per target and mode, with the package's own flags and include folders,
  by the clang of the compiler's LLVM.
- They are linked into every program that imports the package, so a package can wrap a C library and still
  cross-compile.
- The older `module` field, with `cSources`, `cFlags`, `includeDirs`, and `systemLibraries`, still reads.

## aliases

```jsonc
"aliases": {
    "@models": "src/models",
    "@components": "src/components",
}
```

`import { User } from "@models/user"` in any file of the package then means `src/models/user.hx`.
The folder must be inside the package, and an alias can't take the scope of a dependency
(`@acme` next to `@acme/tls`).
Each mistake is an error that says why:

| Setting                                        | Error                                           |
|------------------------------------------------|-------------------------------------------------|
| `"lib": "src"`                                 | alias "lib" must be @ and a name                |
| `"@lib": "../other"`                           | must point to a folder inside the package       |
| `"@acme": "src"` with a dependency `@acme/tls` | is also the scope of the dependency "@acme/tls" |

## Dependencies

| Written as                            | Means                                       |
|---------------------------------------|---------------------------------------------|
| `"path:../util"`                      | a local folder, used as it is               |
| `{ "url": "...", "hash": "hx1-..." }` | an archive, pinned by the hash of its files |
| `"^2.1"`                              | the registry                                |
| `"github:owner/repo#ref"`             | a GitHub repository                         |

`hpm`, the package manager, installs them into `helix-modules/`, and the compiler imports from there.
The compiler checks that each import is declared, and never reads the network or the lockfile.

## See also

- [build.hx](/projects/build)
- [Modules](/language/modules)
- [Targets](/projects/targets)
