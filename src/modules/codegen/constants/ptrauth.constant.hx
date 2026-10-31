/**
 * The function attributes that ask LLVM to sign and check pointers on arm64e.
 *
 * @remarks
 * Every function of the module gets all four, as clang gives them.
 * All but `ptrauth-calls` also go into `llvm.module.flags`.
 *
 * @example
 * ```hx
 * Attributes[1]; // "ptrauth-returns"
 * ```
 *
 * @see signFunctionPointers
 * @since 1.0.0
 */

export const Attributes: string[4] = ["ptrauth-calls", "ptrauth-returns", "ptrauth-auth-traps", "ptrauth-indirect-gotos"];
