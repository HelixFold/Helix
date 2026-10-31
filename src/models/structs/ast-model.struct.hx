/**
 * Imports
 */

import { NodeKind } from "@constants/ast.constant";
import { HxSource } from "@models/structs/source-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";

/**
 * One node of the syntax tree, packed into 16 bytes.
 *
 * @remarks
 * Nodes live in one flat array and refer to each other by index, where index 0 is the reserved empty node.
 * What `a` and `b` hold depends on the kind:
 * a child node, a token, a range of children in the extra array, or the index of a record there.
 *
 * @example
 * ```ts
 * // a + b
 * // { kind: Binary, op: BinOp.Add, token: 1, a: <a>, b: <b> }
 * ```
 *
 * @see HxAst
 * @see NodeKind
 *
 * @since 1.0.0
 */

export extern "C" struct HxNode {
    /**
     * The kind of the node.
     *
     * @example
     * ```ts
     * n.kind; // NodeKind.Binary
     * ```
     *
     * @since 1.0.0
     */

    kind: NodeKind,

    /**
     * The `FLAG_` bits of the node, such as {@link FLAG_EXPORT}.
     *
     * @example
     * ```ts
     * n.flags & FLAG_EXPORT; // nonzero for an exported declaration
     * ```
     *
     * @since 1.0.0
     */

    flags: u8,

    /**
     * The operator of a binary operation or an assignment, or the mode of a test, a describe block, or a hook.
     *
     * @example
     * ```ts
     * n.op; // BinOp.Add as u16 for a + b
     * ```
     *
     * @since 1.0.0
     */

    op: u16,

    /**
     * The main token of the node, such as its name or its operator, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, n.token); // 'add' for function add() {}
     * ```
     *
     * @since 1.0.0
     */

    token: u32,

    /**
     * The first slot, whose meaning depends on the kind.
     *
     * @example
     * ```ts
     * n.a; // the left operand of a + b
     * ```
     *
     * @since 1.0.0
     */

    a: u32,

    /**
     * The second slot, whose meaning depends on the kind.
     *
     * @example
     * ```ts
     * n.b; // the right operand of a + b
     * ```
     *
     * @since 1.0.0
     */

    b: u32,
}

/**
 * A range of entries in the extra array.
 *
 * @remarks
 * A list of children, such as the arguments of a call, is stored as the node indexes from `start` up to `end`.
 *
 * @example
 * ```ts
 * const args = record<HxRange>(&ast, call.b);
 * for (const i of args.start..args.end) node(&ast, extraAt(&ast, i)); // each argument
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxRange {
    /**
     * The index of the first entry.
     *
     * @example
     * ```ts
     * range.start; // 4
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The index one past the last entry.
     *
     * @example
     * ```ts
     * range.end; // 6 for a list of two
     * ```
     *
     * @since 1.0.0
     */

    end: u32,
}

/**
 * The record of an `Import` node.
 *
 * @example
 * ```ts
 * // import * as fmt from "std/fmt";
 * // { path_token: <"std/fmt">, alias_token: <fmt>, specs_start: 0, specs_end: 0 }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxImportData {
    /**
     * The string token of the module path.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.path_token); // '"std/fmt"'
     * ```
     *
     * @since 1.0.0
     */

    path_token: u32,

    /**
     * The namespace name of an `import * as` form, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.alias_token); // 'fmt'
     * ```
     *
     * @since 1.0.0
     */

    alias_token: u32,

    /**
     * The start of the range of `ImportSpec` nodes.
     *
     * @example
     * ```ts
     * data.specs_end - data.specs_start; // 2 for import { a, b } from "./x";
     * ```
     *
     * @since 1.0.0
     */

    specs_start: u32,

    /**
     * The end of the range of `ImportSpec` nodes.
     *
     * @example
     * ```ts
     * data.specs_end; // equal to specs_start when there are none
     * ```
     *
     * @since 1.0.0
     */

    specs_end: u32,
}

/**
 * The record of a `Function`, `ArrowFunction`, or `TypeFunction` node.
 *
 * @example
 * ```ts
 * // function max<T>(a: T, b: T): T { ... }
 * // one generic, two params, a return type, and a body
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxFnData {
    /**
     * The start of the range of `GenericParam` nodes.
     *
     * @example
     * ```ts
     * fn.generics_end - fn.generics_start; // 1 for max<T>
     * ```
     *
     * @since 1.0.0
     */

    generics_start: u32,

    /**
     * The end of the range of `GenericParam` nodes.
     *
     * @example
     * ```ts
     * fn.generics_end; // equal to generics_start without generics
     * ```
     *
     * @since 1.0.0
     */

    generics_end: u32,

    /**
     * The start of the range of `Param` nodes.
     *
     * @example
     * ```ts
     * fn.params_end - fn.params_start; // 2 for (a: T, b: T)
     * ```
     *
     * @since 1.0.0
     */

    params_start: u32,

    /**
     * The end of the range of `Param` nodes.
     *
     * @example
     * ```ts
     * fn.params_end; // equal to params_start without parameters
     * ```
     *
     * @since 1.0.0
     */

    params_end: u32,

    /**
     * The return type, or 0 for `void`.
     *
     * @example
     * ```ts
     * fn.return_type; // 0 for function main()
     * ```
     *
     * @since 1.0.0
     */

    return_type: u32,

    /**
     * The body, or 0 for an extern function, an interface member, or a function type.
     *
     * @example
     * ```ts
     * fn.body; // 0 for extern "C" function free(ptr: ?u8[*]): void;
     * ```
     *
     * @since 1.0.0
     */

    body: u32,

    /**
     * The string token of an `extern` ABI such as `"C"`, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, fn.abi_token); // '"C"'
     * ```
     *
     * @since 1.0.0
     */

    abi_token: u32,

    /**
     * The index of the first node of the declaration.
     *
     * @remarks
     * Every node of the declaration lies from this index up to the function node itself,
     * which lets a later pass walk the whole declaration as one stretch of the node array.
     *
     * @example
     * ```ts
     * fn.first_node; // the first generic, parameter, or type node
     * ```
     *
     * @since 1.0.0
     */

    first_node: u32,
}

/**
 * The record of a `Struct`, `Enum`, `Union`, `Interface`, or `TypeAlias` node.
 *
 * @example
 * ```ts
 * // enum Role: u8 { Admin, User }
 * // two members and a backing type
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxContainerData {
    /**
     * The start of the range of `GenericParam` nodes.
     *
     * @example
     * ```ts
     * data.generics_end - data.generics_start; // 1 for struct Box<T>
     * ```
     *
     * @since 1.0.0
     */

    generics_start: u32,

    /**
     * The end of the range of `GenericParam` nodes.
     *
     * @example
     * ```ts
     * data.generics_end; // equal to generics_start without generics
     * ```
     *
     * @since 1.0.0
     */

    generics_end: u32,

    /**
     * The start of the range of member nodes, which a type alias leaves empty.
     *
     * @example
     * ```ts
     * data.members_end - data.members_start; // 2 for enum Role { Admin, User }
     * ```
     *
     * @since 1.0.0
     */

    members_start: u32,

    /**
     * The end of the range of member nodes.
     *
     * @example
     * ```ts
     * data.members_end; // equal to members_start for an empty body
     * ```
     *
     * @since 1.0.0
     */

    members_end: u32,

    /**
     * The backing type of an enum, or 0.
     *
     * @example
     * ```ts
     * data.backing_type; // the u8 of enum Role: u8
     * ```
     *
     * @since 1.0.0
     */

    backing_type: u32,

    /**
     * The index of the first node of the declaration, which a type alias leaves at 0.
     *
     * @example
     * ```ts
     * data.first_node; // the first generic or member node
     * ```
     *
     * @since 1.0.0
     */

    first_node: u32,
}

/**
 * The record of a `Slice` node.
 *
 * @example
 * ```ts
 * // items[2..]
 * // { start: <2>, end: 0 }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxSliceData {
    /**
     * The start bound, or 0 when it is left out.
     *
     * @example
     * ```ts
     * data.start; // 0 for items[..3]
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The end bound, or 0 when it is left out.
     *
     * @example
     * ```ts
     * data.end; // 0 for items[2..]
     * ```
     *
     * @since 1.0.0
     */

    end: u32,
}

/**
 * The record of a `Ternary` node, whose condition sits in the node itself.
 *
 * @example
 * ```ts
 * // ok ? 1 : 0
 * // { then_value: <1>, else_value: <0> }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxTernaryData {
    /**
     * The value when the condition holds.
     *
     * @example
     * ```ts
     * data.then_value; // the 1 of ok ? 1 : 0
     * ```
     *
     * @since 1.0.0
     */

    then_value: u32,

    /**
     * The value when the condition does not hold.
     *
     * @example
     * ```ts
     * data.else_value; // the 0 of ok ? 1 : 0
     * ```
     *
     * @since 1.0.0
     */

    else_value: u32,
}

/**
 * The record of a `Catch` node, whose left side sits in the node itself.
 *
 * @example
 * ```ts
 * // find(id) catch (e) { log(e); }
 * // { capture_token: <e>, body: <block> }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxCatchData {
    /**
     * The name that captures the error, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * data.capture_token; // NO_TOKEN for find(id) catch null
     * ```
     *
     * @since 1.0.0
     */

    capture_token: u32,

    /**
     * The fallback, which is a block or an expression.
     *
     * @example
     * ```ts
     * data.body; // the null of find(id) catch null
     * ```
     *
     * @since 1.0.0
     */

    body: u32,
}

/**
 * The record of a `Test` node.
 *
 * @example
 * ```ts
 * // test.panics("stops", "index out of bounds", { timeout: 100 }) {}
 * // { message_token: <"index out of bounds">, timeout_token: <100> }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxTestData {
    /**
     * The expected panic message of a `test.panics`, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.message_token); // '"index out of bounds"'
     * ```
     *
     * @since 1.0.0
     */

    message_token: u32,

    /**
     * The integer token of the timeout option in milliseconds, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.timeout_token); // '100'
     * ```
     *
     * @since 1.0.0
     */

    timeout_token: u32,
}

/**
 * The record of a `Case` node.
 *
 * @example
 * ```ts
 * // case .Admin, .Owner if (active): grant();
 * // two patterns, a guard, and a body
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxCaseData {
    /**
     * The start of the range of pattern nodes.
     *
     * @example
     * ```ts
     * data.patterns_end - data.patterns_start; // 2 for case .Admin, .Owner:
     * ```
     *
     * @since 1.0.0
     */

    patterns_start: u32,

    /**
     * The end of the range of pattern nodes.
     *
     * @example
     * ```ts
     * data.patterns_end; // patterns_start + 1 for case 0:
     * ```
     *
     * @since 1.0.0
     */

    patterns_end: u32,

    /**
     * The guard expression, or 0.
     *
     * @example
     * ```ts
     * data.guard; // the active of case .Admin if (active):
     * ```
     *
     * @since 1.0.0
     */

    guard: u32,

    /**
     * The body, which is a block of statements or the value of an expression switch.
     *
     * @example
     * ```ts
     * data.body; // the grant() of case .Admin: grant();
     * ```
     *
     * @since 1.0.0
     */

    body: u32,
}

/**
 * The record of an `If` node.
 *
 * @example
 * ```ts
 * // if (const user = find(id)) greet(user); else signUp();
 * // { condition: <find(id)>, capture_token: <user>, then_branch, else_branch }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxIfData {
    /**
     * The condition.
     *
     * @example
     * ```ts
     * data.condition; // the find(id) of the example above
     * ```
     *
     * @since 1.0.0
     */

    condition: u32,

    /**
     * The name that captures the value of an optional condition, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.capture_token); // 'user'
     * ```
     *
     * @since 1.0.0
     */

    capture_token: u32,

    /**
     * The statement that runs when the condition holds.
     *
     * @example
     * ```ts
     * data.then_branch; // the greet(user) statement
     * ```
     *
     * @since 1.0.0
     */

    then_branch: u32,

    /**
     * The statement that runs otherwise, or 0 without an `else`.
     *
     * @example
     * ```ts
     * data.else_branch; // 0 for if (ready) start();
     * ```
     *
     * @since 1.0.0
     */

    else_branch: u32,
}

/**
 * The record of a `While` node.
 *
 * @example
 * ```ts
 * // outer: while (const line = next()) print(line);
 * // { condition: <next()>, capture_token: <line>, body, label_token: <outer> }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxWhileData {
    /**
     * The condition.
     *
     * @example
     * ```ts
     * data.condition; // the next() of the example above
     * ```
     *
     * @since 1.0.0
     */

    condition: u32,

    /**
     * The name that captures the value of an optional condition, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.capture_token); // 'line'
     * ```
     *
     * @since 1.0.0
     */

    capture_token: u32,

    /**
     * The statement that repeats.
     *
     * @example
     * ```ts
     * data.body; // the print(line) statement
     * ```
     *
     * @since 1.0.0
     */

    body: u32,

    /**
     * The label of the loop, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.label_token); // 'outer'
     * ```
     *
     * @since 1.0.0
     */

    label_token: u32,
}

/**
 * The record of a C-style `For` node.
 *
 * @example
 * ```ts
 * // for (let i = 0; i < n; i++) step(i);
 * // { init: <let i = 0>, condition: <i < n>, step: <i++>, body, label_token: NO_TOKEN }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxForData {
    /**
     * The statement that runs once before the loop, or 0.
     *
     * @example
     * ```ts
     * data.init; // the let i = 0
     * ```
     *
     * @since 1.0.0
     */

    init: u32,

    /**
     * The condition checked before each pass, or 0 for a loop that runs until a `break`.
     *
     * @example
     * ```ts
     * data.condition; // 0 for for (;;) {}
     * ```
     *
     * @since 1.0.0
     */

    condition: u32,

    /**
     * The statement that runs after each pass, or 0.
     *
     * @example
     * ```ts
     * data.step; // the i++
     * ```
     *
     * @since 1.0.0
     */

    step: u32,

    /**
     * The statement that repeats.
     *
     * @example
     * ```ts
     * data.body; // the step(i) statement
     * ```
     *
     * @since 1.0.0
     */

    body: u32,

    /**
     * The label of the loop, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * data.label_token; // NO_TOKEN without a label
     * ```
     *
     * @since 1.0.0
     */

    label_token: u32,
}

/**
 * The record of a `ForOf` node.
 *
 * @example
 * ```ts
 * // for (const item, i of items) use(item);
 * // { item_token: <item>, index_token: <i>, iterable: <items>, body, label_token: NO_TOKEN }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxForOfData {
    /**
     * The name of each item.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.item_token); // 'item'
     * ```
     *
     * @since 1.0.0
     */

    item_token: u32,

    /**
     * The name of the index of each item, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * tokenText(&ast, data.index_token); // 'i'
     * ```
     *
     * @since 1.0.0
     */

    index_token: u32,

    /**
     * The collection or `Range` node that the loop walks.
     *
     * @example
     * ```ts
     * node(&ast, data.iterable).kind; // NodeKind.Range for 0..n
     * ```
     *
     * @since 1.0.0
     */

    iterable: u32,

    /**
     * The statement that repeats.
     *
     * @example
     * ```ts
     * data.body; // the use(item) statement
     * ```
     *
     * @since 1.0.0
     */

    body: u32,

    /**
     * The label of the loop, or {@link NO_TOKEN}.
     *
     * @example
     * ```ts
     * data.label_token; // NO_TOKEN without a label
     * ```
     *
     * @since 1.0.0
     */

    label_token: u32,
}

/**
 * The syntax tree of a program, as a flat node array and an extra array of 32-bit words.
 *
 * @remarks
 * Node 0 is a reserved empty node, so 0 in any child slot means that the child is absent.
 * Children that do not fit in the two slots of a node live in the extra array,
 * either as a range of node indexes or as one of the `Data` records.
 * Nodes point back into the tokens and the source, so both must outlive the tree.
 *
 * @example
 * ```ts
 * let ast: HxAst = undefined;
 * hx_ast_init(&ast, &src, &tokens);
 * // the parser fills it, then ast.root is the File node
 * hx_ast_free(&ast);
 * ```
 *
 * @see HxNode
 * @see hx_ast_init
 *
 * @since 1.0.0
 */

export extern "C" struct HxAst {
    /**
     * The source that the tokens point into.
     *
     * @example
     * ```ts
     * ast.src.len; // the length of the program text
     * ```
     *
     * @since 1.0.0
     */

    src: readonly *HxSource,

    /**
     * The tokens that the nodes point at.
     *
     * @example
     * ```ts
     * ast.tokens.len; // the number of tokens
     * ```
     *
     * @since 1.0.0
     */

    tokens: readonly *HxTokens,

    /**
     * The nodes, where node 0 is the reserved empty node.
     *
     * @example
     * ```ts
     * node(&ast, ast.root).kind; // NodeKind.File
     * ```
     *
     * @since 1.0.0
     */

    nodes: ?HxNode[*],

    /**
     * The number of nodes, the reserved one included.
     *
     * @example
     * ```ts
     * ast.nodes_len; // 1 for a new tree
     * ```
     *
     * @since 1.0.0
     */

    nodes_len: u32,

    /**
     * The capacity of the node array.
     *
     * @example
     * ```ts
     * ast.nodes_cap; // about half the token count
     * ```
     *
     * @since 1.0.0
     */

    nodes_cap: u32,

    /**
     * The child lists and records that do not fit in a node.
     *
     * @example
     * ```ts
     * extraAt(&ast, 4); // a node index or a record word
     * ```
     *
     * @since 1.0.0
     */

    extra: ?u32[*],

    /**
     * The number of words in the extra array.
     *
     * @example
     * ```ts
     * ast.extra_len; // 0 for a new tree
     * ```
     *
     * @since 1.0.0
     */

    extra_len: u32,

    /**
     * The capacity of the extra array in words.
     *
     * @example
     * ```ts
     * ast.extra_cap; // about a quarter of the token count
     * ```
     *
     * @since 1.0.0
     */

    extra_cap: u32,

    /**
     * The index of the `File` node of the entry file, or 0 before parsing.
     *
     * @remarks
     * A program of several files has one `File` node per file, and this one belongs to the file it started from.
     *
     * @example
     * ```ts
     * node(&ast, ast.root).kind; // NodeKind.File
     * ```
     *
     * @since 1.0.0
     */

    root: u32,
}
