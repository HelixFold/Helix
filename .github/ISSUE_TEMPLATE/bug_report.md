---
name: 🐞 Bug Report
title: 🐞 Bug Report
about: Something is broken
labels: [ "bug", "needs triage" ]
---

**Describe the bug**

A clear and concise description of what is wrong.

**Reproduction**

The smallest program that shows it, and the command that you ran.

```hx
export function main(): void {
    println("...");
}
```

```bash
helix run bug.hx
```

**Expected behavior**

What you expected to happen.

**Actual behavior**

What actually happened. Include the whole output: the compiler's errors, or the panic with its stack trace.

```text
error: ...
 --> bug.hx:2:5
```

**Environment**

|                                    | |
|------------------------------------|-|
| `helix version`                    | |
| `--target` and `--mode`, when used | |
| OS and architecture                | |

**Checklist**

- [ ] I have searched for existing issues, and this is not a duplicate.
- [ ] I am using the latest release, or a compiler built from `master`.
- [ ] I have included a minimal reproduction above.
