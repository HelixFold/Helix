/**
 * Imports
 */

import { BinOp } from "@constants/ast.constant";
import { HxAst } from "@models/structs/ast-model.struct";
import { HxSource } from "@models/structs/source-model.struct";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";

/**
 * The state of one run of the parser over one file.
 *
 * @remarks
 * Lists are built on a shared scratch stack.
 * A parse function notes the top of the stack, pushes the child indexes as it parses them,
 * and then moves exactly its own children into the extra array of the tree.
 * Nested lists finish before their parent does, so they never interleave.
 *
 * Errors use panic mode.
 * The first error in a statement is reported, and further errors are suppressed until the enclosing list
 * resynchronizes, which avoids a cascade of follow-on errors.
 */

export struct Parser {
    /**
     * The source that the tokens point into.
     */

    src: readonly *HxSource,

    /**
     * The tokens being parsed.
     */

    tokens: readonly *HxTokens,

    /**
     * The tree that receives the nodes.
     */

    ast: *HxAst,

    /**
     * The list that receives the syntax errors.
     */

    diags: *HxDiagList,

    /**
     * The index of the current token.
     */

    pos: u32,

    /**
     * The current nesting depth, which {@link MAX_DEPTH} limits.
     */

    depth: u32,

    /**
     * Whether an error was reported and the parser is still looking for a place to resume.
     */

    panicking: bool,

    /**
     * The scratch stack of child indexes for the lists being built.
     */

    scratch: ?u32[*],

    /**
     * The number of entries on the scratch stack.
     */

    scratch_len: u32,

    /**
     * The capacity of the scratch stack.
     */

    scratch_cap: u32,
}

/**
 * How the token at the current position acts as a binary operator.
 */

export struct BinaryInfo {
    /**
     * The precedence, where 0 means that the token is not a binary operator here.
     */

    prec: u8,

    /**
     * The operator that the node records.
     */

    op: BinOp,

    /**
     * Whether the operator groups to the right.
     */

    right: bool,

    /**
     * The number of tokens that the operator takes, which is 2 for a `>>` made of two `>` tokens.
     */

    width: u32,
}
