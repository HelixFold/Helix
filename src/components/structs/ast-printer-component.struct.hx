/**
 * Imports
 */

import { HxAst } from "@models/structs/ast-model.struct";

/**
 * The state of one run of the AST printer.
 */

export struct Printer {
    /**
     * The tree being printed.
     */

    ast: readonly *HxAst,

    /**
     * The C `FILE` that receives the output.
     */

    out: ?u8[*],

    /**
     * Whether declarations and statements go on their own indented lines.
     */

    pretty: bool,

    /**
     * The current indentation level in pretty mode, in steps of two spaces.
     */

    indent: u32,
}
