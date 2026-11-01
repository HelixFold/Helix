---
layout: home
title: 'Helix'
titleTemplate: 'A systems language with TypeScript syntax'
hero:
    name: 'Helix'
    text: 'TypeScript syntax, native code'
    tagline: A systems language with no hidden control flow, no hidden allocation, and checks that run while it compiles.
    actions:
        - theme: brand
          text: Get Started
          link: ./guide
        - theme: alt
          text: Language Tour
          link: ./language/basics
        - theme: alt
          text: View on GitHub
          link: https://github.com/HelixFold/Helix
    image:
        src: /logo.png
        alt: 'Helix logo'
features:
    - icon: 🧩
      title: Reads like TypeScript
      details: Functions, structs, unions, generics, and template strings in the syntax you already know, compiled by LLVM into native executables.
    - icon: 🔍
      title: Nothing hidden
      details: Every call that can fail is marked with try or catch, every allocation takes an allocator, and errors are values instead of exceptions.
    - icon: 🛡️
      title: Safe by default
      details: Overflow, bounds, null, and cast checks panic with the source line in debug builds, and unused results, unhandled errors, and unchecked nulls never compile.
    - icon: ⚙️
      title: Compile-time code
      details: comptime runs ordinary Helix while compiling, so tables, sizes, and checks cost nothing at run time.
    - icon: 🧪
      title: Tests built in
      details: describe, test, and expect are part of the language, and helix test runs every spec in its own process.
    - icon: 🌍
      title: Cross-compiles
      details: One helix builds for macOS, static Linux, Windows, WASI, and boards without an OS, Cortex-M microcontrollers included.
---
