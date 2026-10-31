/**
 * Imports
 */

import { HxAst } from "@models/structs/ast-model.struct";

/**
 * The state of one run of the AST printer.
 *
 * @remarks
 * `hxAstPrint` makes one on the stack for each call and throws it away afterwards,
 * so nothing carries over between two printed trees.
 *
 * @example
 * ```hx
 * let pr = Printer { ast, out, pretty: true, indent: 0 };
 * pr.indent; // 0 at the root of the tree
 * ```
 *
 * @see hxAstPrint
 * @since 1.0.0
 */

export struct Printer {
    /**
     * The tree being printed.
     *
     * @example
     * ```hx
     * pr.ast; // the tree that hxParse built
     * ```
     *
     * @since 1.0.0
     */

    ast: readonly *HxAst,

    /**
     * The C `FILE` that receives the output.
     *
     * @example
     * ```hx
     * pr.out; // stdout, or a stream from open_memstream
     * ```
     *
     * @since 1.0.0
     */

    out: ?u8[*],

    /**
     * Whether declarations and statements go on their own indented lines.
     *
     * @example
     * ```hx
     * pr.pretty; // false writes the whole tree on one line
     * ```
     *
     * @since 1.0.0
     */

    pretty: bool,

    /**
     * The current indentation level in pretty mode, in steps of two spaces.
     *
     * @example
     * ```hx
     * pr.indent; // 2 inside the body of a function
     * ```
     *
     * @since 1.0.0
     */

    indent: u32,
}
