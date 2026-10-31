/**
 * Imports
 */

import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { Value } from "@modules/codegen/components/structs/base-component.struct";

/**
 * A function used as a value, with what stands in for it while the signed constant is made.
 *
 * @remarks
 * The LLVM C API cannot build a signed pointer constant, so {@link signFunctionPointers} parses one from IR text.
 * In between, a placeholder global takes every use of the function except as a callee,
 * and the signed constant replaces the placeholder once it is linked in.
 *
 * @example
 * ```hx
 * // const callback = onEvent;
 * signed.items[0]; // { fn: @onEvent, placeholder: @hx.ptrauth.placeholder.0, linkage: internal }
 * ```
 *
 * @see signFunctionPointers
 * @since 1.0.0
 */

export struct Signed {
    /**
     * The function that is used as a value.
     *
     * @example
     * ```hx
     * signed.fn; // @onEvent
     * ```
     *
     * @since 1.0.0
     */

    fn: Value,

    /**
     * The global that takes over every use of the function until the signed constant replaces it.
     *
     * @example
     * ```hx
     * signed.placeholder; // @hx.ptrauth.placeholder.0
     * ```
     *
     * @since 1.0.0
     */

    placeholder: Value,

    /**
     * The linkage of the function, put back once the signed constant is linked in.
     *
     * @remarks
     * The function is public while the constant is linked in,
     * since another module cannot name a local function, even one that is being linked in.
     *
     * @example
     * ```hx
     * signed.linkage; // LLVMInternalLinkage
     * ```
     *
     * @since 1.0.0
     */

    linkage: llvm.LLVMLinkage,
}
