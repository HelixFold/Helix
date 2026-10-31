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
 *
 * @example
 * ```hx
 * let p = Parser {
 *     src: ast.src, tokens: ast.tokens, ast, diags, pos: 0, depth: 0, panicking: false,
 *     scratch: null, scratchLen: 0, scratchCap: 0,
 * };
 * parseDeclaration(&p); // the index of the node of the first declaration
 * p.pos;                // the token after that declaration
 * ```
 *
 * @since 1.0.0
 */

export struct Parser {
    /**
     * The source that the tokens point into.
     *
     * @example
     * ```hx
     * p.src; // the source of the file being parsed
     * ```
     *
     * @since 1.0.0
     */

    src: readonly *HxSource,

    /**
     * The tokens being parsed.
     *
     * @example
     * ```hx
     * p.tokens; // the tokens that the lexer produced for that source
     * ```
     *
     * @since 1.0.0
     */

    tokens: readonly *HxTokens,

    /**
     * The tree that receives the nodes.
     *
     * @example
     * ```hx
     * p.ast; // the tree that hxParseModule fills
     * ```
     *
     * @since 1.0.0
     */

    ast: *HxAst,

    /**
     * The list that receives the syntax errors.
     *
     * @example
     * ```hx
     * p.diags; // the list that collects every syntax error
     * ```
     *
     * @since 1.0.0
     */

    diags: *HxDiagList,

    /**
     * The index of the current token.
     *
     * @example
     * ```hx
     * p.pos; // 0 before the first token of a single-file program
     * ```
     *
     * @since 1.0.0
     */

    pos: u32,

    /**
     * The current nesting depth, which {@link MaxDepth} limits.
     *
     * @example
     * ```hx
     * p.depth; // 0 at the top level of a file
     * ```
     *
     * @since 1.0.0
     */

    depth: u32,

    /**
     * Whether an error was reported and the parser is still looking for a place to resume.
     *
     * @example
     * ```hx
     * p.panicking; // false until the first error of a statement
     * ```
     *
     * @since 1.0.0
     */

    panicking: bool,

    /**
     * The scratch stack of child indexes for the lists being built.
     *
     * @example
     * ```hx
     * p.scratch; // null until the first list pushes a child
     * ```
     *
     * @since 1.0.0
     */

    scratch: ?u32[*],

    /**
     * The number of entries on the scratch stack.
     *
     * @example
     * ```hx
     * p.scratchLen; // 0 outside any list
     * ```
     *
     * @since 1.0.0
     */

    scratchLen: u32,

    /**
     * The capacity of the scratch stack.
     *
     * @example
     * ```hx
     * p.scratchCap; // 0 until the stack first grows
     * ```
     *
     * @since 1.0.0
     */

    scratchCap: u32,
}

/**
 * How the token at the current position acts as a binary operator.
 *
 * @remarks
 * The precedence climber in {@link parseBinary} reads it once per operator,
 * so one table lookup decides the binding power, the node operator, the grouping, and how many tokens to consume.
 * The lexer never emits a `>>` token, so a shift appears here as two adjacent `>` tokens with a width of 2.
 *
 * @example
 * ```hx
 * currentBinaryOperator(p); // { prec: PrecAdd, op: BinOp.Add, right: false, width: 1 } at the + of a + b
 * currentBinaryOperator(p); // { prec: 0, op: BinOp.None, right: false, width: 1 } at the ; of a;
 * ```
 *
 * @since 1.0.0
 */

export struct BinaryInfo {
    /**
     * The precedence, where 0 means that the token is not a binary operator here.
     *
     * @example
     * ```hx
     * currentBinaryOperator(p).prec; // PrecAdd at the + of a + b
     * ```
     *
     * @since 1.0.0
     */

    prec: u8,

    /**
     * The operator that the node records.
     *
     * @example
     * ```hx
     * currentBinaryOperator(p).op; // BinOp.Add at the + of a + b
     * ```
     *
     * @since 1.0.0
     */

    op: BinOp,

    /**
     * Whether the operator groups to the right.
     *
     * @example
     * ```hx
     * currentBinaryOperator(p).right; // true at the ?? of a ?? b
     * ```
     *
     * @since 1.0.0
     */

    right: bool,

    /**
     * The number of tokens that the operator takes, which is 2 for a `>>` made of two `>` tokens.
     *
     * @example
     * ```hx
     * currentBinaryOperator(p).width; // 2 at the >> of a >> 2
     * ```
     *
     * @since 1.0.0
     */

    width: u32,
}
