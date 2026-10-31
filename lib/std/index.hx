/**
 * The Helix standard library (alpha), which re-exports its modules under the one name `std`.
 *
 * @remarks
 * `import { ... } from "std"` brings in everything from text, heap, list, io, process, and fs.
 * A program can also import one module on its own, by its path under `std/`.
 * The build, testing, target, and C modules stay out of this list and are imported by their own paths.
 *
 * @example
 * ```hx
 * import { ArrayList, cAllocator } from "std";
 * import * as text from "std/text";
 * ```
 *
 * @since 1.0.0
 */

export * from "./io";
export * from "./fs";
export * from "./text";
export * from "./heap";
export * from "./list";
export * from "./process";
