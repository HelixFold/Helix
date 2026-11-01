# Contributing to Helix

Thanks for your interest in contributing.
Bug reports, fixes, features, and documentation improvements are all welcome.
This guide explains how to set up the project and get a change merged.

## Code of conduct

By participating you agree to follow the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
Be respectful and constructive in issues, pull requests, and reviews.

## Ways to contribute

- **Report a bug**: open a [bug report](https://github.com/HelixFold/Helix/issues/new?template=bug_report.md) with a minimal reproduction.
- **Request a feature**: open a [feature request](https://github.com/HelixFold/Helix/issues/new?template=feature_request.md) describing the use case.
- **Send a pull request**: fix a bug, add a feature, or improve the docs.

Search [existing issues](https://github.com/HelixFold/Helix/issues) first to avoid duplicates.

The package manager, the language server, and the editor support live in repositories of their own.

## Development setup

The compiler is written in Helix, so building it takes a Helix toolchain.
The repository ships one for x86_64 Linux, which is what CI uses:

```bash
git clone https://github.com/HelixFold/Helix.git
cd Helix
tar -xJf .github/bootstrap/helix-1.0.0-alpha.0-x86_64-linux.tar.xz -C "$HOME/.local"
export PATH="$HOME/.local/helix-1.0.0-alpha.0-x86_64-linux:$PATH"
export HELIX_HOME="$HOME/.local/helix-1.0.0-alpha.0-x86_64-linux/lib"
```

### Build steps

| Command               | Description                                                                                                     |
|-----------------------|-----------------------------------------------------------------------------------------------------------------|
| `helix build`         | Build the compiler into `.helix-out/bin/helix`.                                                                 |
| `helix build test`    | Build the compiler, then run the specs in `src` and `lib` with it.                                              |
| `helix build e2e`     | Build the compiler, then check it against the snippets in `e2e`.                                                |
| `helix build release` | Build a release for every platform into `.helix-out/release/<platform>`, or one with `--platform=x86_64-linux`. |
| `pnpm docs:dev`       | Serve the VitePress docs locally.                                                                               |
| `pnpm docs:build`     | Build the docs, which fails on a broken link or a missing example.                                              |

Run `helix build test` and `helix build e2e` before opening a pull request.
CI runs both on Linux, with the macOS SDK so that the e2e projects also build for macOS.

### Release builds

`helix build release` makes `.helix-out/release/<platform>` for each platform, a folder that runs as it is:
`helix` with LLVM, libclang, and lld linked in, `lib/std`, `lib/rt`, and `lib/chips`,
clang, llvm-ar, and llvm-dlltool (and dsymutil for macOS) in `lib/llvm/bin`, clang's headers in `lib/llvm/lib/clang`,
the unpacked sources of musl, compiler-rt, and wasi-libc in `lib/src`,
and a trimmed macOS SDK in `lib/sdk/MacOSX.sdk`, so every release builds for macOS.

Each platform needs its toolchain in `$HELIX_HOME/llvm/<platform>`:

- `lib` holds the static LLVM, libclang, and lld, the C++ runtime for that platform, and clang's headers in `lib/clang`.
- `bin` holds clang, llvm-ar, and llvm-dlltool, built for that platform.
- `sysroot` holds mingw-w64's headers and C runtime, for Windows only.

The C library sources come from `$HELIX_HOME/src`, where a build for each target unpacks them the first time.
The trimmed macOS SDK in each release's `lib/sdk/MacOSX.sdk` comes from `$SDKROOT`, Xcode, or the command-line tools.

## Workflow

1. Fork the repository and create a branch from `master`.

   ```bash
   git checkout -b feature/short-description
   ```

2. Make your change, with specs and documentation.
3. Verify everything passes:

   ```bash
   helix build test
   helix build e2e
   ```

4. Push your branch and open a pull request against `master`. Fill in the pull request template.

Keep pull requests small and focused, since they are easier to review and merge.

## Commit messages

Follow the existing history: an area prefix, a colon, then a capitalized imperative summary.

```text
compile.component: Name the cached runtime after a hash of its source
process: Add captureAll and captureAllWith for both streams of a program
e2e: Pass the options of build.hx as --name=value
docs: Add a page for each example
```

- The prefix is a place, not a category.
  Use the file, module, or folder the change lives in, not a Conventional Commits type such as `feat:` or `fix:`.
- Use the imperative mood ("Add", not "Added" or "Adds").
- Keep the first line at or under 72 characters.
- Reference related issues in the body (for example, `Closes #123`).

## Coding standards

- Lay code out as the rest of `src` is: constants, structs, components, services, models, and modules.
- Name things by what they do: camelCase functions and fields, PascalCase types and constants,
  and kebab-case file names. Names of C functions keep their C spelling.
- Write imports one per line, ordered by length, then from a to z.
- Document every exported symbol and every member with **TSDoc**, including an `@since` tag.
  Keep the tag order consistent with the rest of the codebase:
  description, `@typeParam`, `@param`, `@returns`, `@throws`, `@remarks`, `@example`, `@see`, `@since`.
- Fence examples in doc comments as ` ```hx `.

## Specs

Specs use Helix's own `describe`, `test`, and `expect`.
Place a spec next to the file it covers, with the dot of the name turned into a dash:
`compile.component.hx` is tested by `compile-component.spec.hx`.

```hx
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

Name each test for the behavior it checks, starting with `should`.
A change to what the compiler accepts or prints also gets a snippet in `e2e`, which checks the compiler from outside.

## Documentation

- Update the TSDoc of any API you change.
- Update the VitePress docs under `docs/src` when the language, the tools, or the standard library change,
  and add a bullet to `docs/src/release.md`.
- Check each code example in the docs with the compiler.
  The pages under `docs/src/examples` show the programs in `examples`, so keep those building and running.
- Run `pnpm docs:build` to check for broken links.

## Versioning

Helix follows [Semantic Versioning](https://semver.org/).
Until 1.0.0, a minor version may still change the language.
