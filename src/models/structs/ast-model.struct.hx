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
 * ```hx
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
     * ```hx
     * n.kind; // NodeKind.Binary
     * ```
     *
     * @since 1.0.0
     */

    kind: NodeKind,

    /**
     * The `Flag` constant bits of the node, such as {@link FlagExport}.
     *
     * @example
     * ```hx
     * n.flags & FlagExport; // nonzero for an exported declaration
     * ```
     *
     * @since 1.0.0
     */

    flags: u8,

    /**
     * The operator of a binary operation or an assignment, or the mode of a test, a describe block, or a hook.
     *
     * @example
     * ```hx
     * n.op; // BinOp.Add as u16 for a + b
     * ```
     *
     * @since 1.0.0
     */

    op: u16,

    /**
     * The main token of the node, such as its name or its operator, or {@link NoToken}.
     *
     * @example
     * ```hx
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
     * ```hx
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
     * ```hx
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
 * ```hx
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
     * ```hx
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
     * ```hx
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
 * @remarks
 * The parser stores it in the extra array and puts its index in the `a` slot of the node.
 * A bare `import "./x";` names nothing, so its spec range is empty and its alias is {@link NoToken}.
 *
 * @example
 * ```hx
 * // import * as fmt from "std/fmt";
 * // { pathToken: <"std/fmt">, aliasToken: <fmt>, specsStart: 0, specsEnd: 0 }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxImportData {
    /**
     * The string token of the module path.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.pathToken); // '"std/fmt"'
     * ```
     *
     * @since 1.0.0
     */

    pathToken: u32,

    /**
     * The namespace name of an `import * as` form, or {@link NoToken}.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.aliasToken); // 'fmt'
     * ```
     *
     * @since 1.0.0
     */

    aliasToken: u32,

    /**
     * The start of the range of `ImportSpec` nodes.
     *
     * @example
     * ```hx
     * data.specsEnd - data.specsStart; // 2 for import { a, b } from "./x";
     * ```
     *
     * @since 1.0.0
     */

    specsStart: u32,

    /**
     * The end of the range of `ImportSpec` nodes.
     *
     * @example
     * ```hx
     * data.specsEnd; // equal to specsStart when there are none
     * ```
     *
     * @since 1.0.0
     */

    specsEnd: u32,
}

/**
 * The record of a `Function`, `ArrowFunction`, or `TypeFunction` node.
 *
 * @remarks
 * The parser stores it in the extra array and puts its index in the `a` slot of the node.
 * A function declared without a body keeps 0 in `body`, and a function without a return type keeps 0 in `returnType`.
 *
 * @example
 * ```hx
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
     * ```hx
     * fn.genericsEnd - fn.genericsStart; // 1 for max<T>
     * ```
     *
     * @since 1.0.0
     */

    genericsStart: u32,

    /**
     * The end of the range of `GenericParam` nodes.
     *
     * @example
     * ```hx
     * fn.genericsEnd; // equal to genericsStart without generics
     * ```
     *
     * @since 1.0.0
     */

    genericsEnd: u32,

    /**
     * The start of the range of `Param` nodes.
     *
     * @example
     * ```hx
     * fn.paramsEnd - fn.paramsStart; // 2 for (a: T, b: T)
     * ```
     *
     * @since 1.0.0
     */

    paramsStart: u32,

    /**
     * The end of the range of `Param` nodes.
     *
     * @example
     * ```hx
     * fn.paramsEnd; // equal to paramsStart without parameters
     * ```
     *
     * @since 1.0.0
     */

    paramsEnd: u32,

    /**
     * The return type, or 0 for `void`.
     *
     * @example
     * ```hx
     * fn.returnType; // 0 for function main()
     * ```
     *
     * @since 1.0.0
     */

    returnType: u32,

    /**
     * The body, or 0 for an extern function, an interface member, or a function type.
     *
     * @example
     * ```hx
     * fn.body; // 0 for extern "C" function free(ptr: ?u8[*]): void;
     * ```
     *
     * @since 1.0.0
     */

    body: u32,

    /**
     * The string token of an `extern` ABI such as `"C"`, or {@link NoToken}.
     *
     * @example
     * ```hx
     * tokenText(&ast, fn.abiToken); // '"C"'
     * ```
     *
     * @since 1.0.0
     */

    abiToken: u32,

    /**
     * The index of the first node of the declaration.
     *
     * @remarks
     * Every node of the declaration lies from this index up to the function node itself,
     * which lets a later pass walk the whole declaration as one stretch of the node array.
     *
     * @example
     * ```hx
     * fn.firstNode; // the first generic, parameter, or type node
     * ```
     *
     * @since 1.0.0
     */

    firstNode: u32,
}

/**
 * The record of a `Struct`, `Enum`, `Union`, `Interface`, or `TypeAlias` node.
 *
 * @remarks
 * The parser stores it in the extra array and puts its index in the `a` slot of the node.
 * A type alias fills only the generic range and keeps its aliased type in the `b` slot of the node.
 *
 * @example
 * ```hx
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
     * ```hx
     * data.genericsEnd - data.genericsStart; // 1 for struct Box<T>
     * ```
     *
     * @since 1.0.0
     */

    genericsStart: u32,

    /**
     * The end of the range of `GenericParam` nodes.
     *
     * @example
     * ```hx
     * data.genericsEnd; // equal to genericsStart without generics
     * ```
     *
     * @since 1.0.0
     */

    genericsEnd: u32,

    /**
     * The start of the range of member nodes, which a type alias leaves empty.
     *
     * @example
     * ```hx
     * data.membersEnd - data.membersStart; // 2 for enum Role { Admin, User }
     * ```
     *
     * @since 1.0.0
     */

    membersStart: u32,

    /**
     * The end of the range of member nodes.
     *
     * @example
     * ```hx
     * data.membersEnd; // equal to membersStart for an empty body
     * ```
     *
     * @since 1.0.0
     */

    membersEnd: u32,

    /**
     * The backing type of an enum, or 0.
     *
     * @example
     * ```hx
     * data.backingType; // the u8 of enum Role: u8
     * ```
     *
     * @since 1.0.0
     */

    backingType: u32,

    /**
     * The index of the first node of the declaration, which a type alias leaves at 0.
     *
     * @example
     * ```hx
     * data.firstNode; // the first generic or member node
     * ```
     *
     * @since 1.0.0
     */

    firstNode: u32,
}

/**
 * The record of a `Slice` node.
 *
 * @remarks
 * The parser stores it in the extra array and puts its index in the `b` slot of the node,
 * while the `a` slot holds the value being sliced.
 *
 * @example
 * ```hx
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
     * ```hx
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
     * ```hx
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
 * @remarks
 * The parser stores it in the extra array and puts its index in the `b` slot of the node,
 * since the `a` slot already holds the condition.
 *
 * @example
 * ```hx
 * // ok ? 1 : 0
 * // { thenValue: <1>, elseValue: <0> }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxTernaryData {
    /**
     * The value when the condition holds.
     *
     * @example
     * ```hx
     * data.thenValue; // the 1 of ok ? 1 : 0
     * ```
     *
     * @since 1.0.0
     */

    thenValue: u32,

    /**
     * The value when the condition does not hold.
     *
     * @example
     * ```hx
     * data.elseValue; // the 0 of ok ? 1 : 0
     * ```
     *
     * @since 1.0.0
     */

    elseValue: u32,
}

/**
 * The record of a `Catch` node, whose left side sits in the node itself.
 *
 * @remarks
 * The parser stores it in the extra array and puts its index in the `b` slot of the node,
 * since the `a` slot already holds the expression that may fail.
 *
 * @example
 * ```hx
 * // find(id) catch (e) { log(e); }
 * // { captureToken: <e>, body: <block> }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxCatchData {
    /**
     * The name that captures the error, or {@link NoToken}.
     *
     * @example
     * ```hx
     * data.captureToken; // NoToken for find(id) catch null
     * ```
     *
     * @since 1.0.0
     */

    captureToken: u32,

    /**
     * The fallback, which is a block or an expression.
     *
     * @example
     * ```hx
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
 * @remarks
 * The parser stores it in the extra array and puts its index in the `b` slot of the node.
 * The token of the node holds the test name, and the `a` slot holds the body.
 *
 * @example
 * ```hx
 * // test.panics("stops", "index out of bounds", { timeout: 100 }) {}
 * // { messageToken: <"index out of bounds">, timeoutToken: <100> }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxTestData {
    /**
     * The expected panic message of a `test.panics`, or {@link NoToken}.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.messageToken); // '"index out of bounds"'
     * ```
     *
     * @since 1.0.0
     */

    messageToken: u32,

    /**
     * The integer token of the timeout option in milliseconds, or {@link NoToken}.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.timeoutToken); // '100'
     * ```
     *
     * @since 1.0.0
     */

    timeoutToken: u32,
}

/**
 * The record of a `Case` node.
 *
 * @remarks
 * The parser stores it in the extra array and puts its index in the `a` slot of the node.
 * The same record serves a statement switch and an expression switch, and only the meaning of `body` differs.
 *
 * @example
 * ```hx
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
     * ```hx
     * data.patternsEnd - data.patternsStart; // 2 for case .Admin, .Owner:
     * ```
     *
     * @since 1.0.0
     */

    patternsStart: u32,

    /**
     * The end of the range of pattern nodes.
     *
     * @example
     * ```hx
     * data.patternsEnd; // patternsStart + 1 for case 0:
     * ```
     *
     * @since 1.0.0
     */

    patternsEnd: u32,

    /**
     * The guard expression, or 0.
     *
     * @example
     * ```hx
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
     * ```hx
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
 * @remarks
 * The parser stores it in the extra array and puts its index in the `a` slot of the node.
 * A missing `else` leaves 0 in `elseBranch`, and an `else if` chain nests another `If` node there.
 *
 * @example
 * ```hx
 * // if (const user = find(id)) greet(user); else signUp();
 * // { condition: <find(id)>, captureToken: <user>, thenBranch, elseBranch }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxIfData {
    /**
     * The condition.
     *
     * @example
     * ```hx
     * data.condition; // the find(id) of the example above
     * ```
     *
     * @since 1.0.0
     */

    condition: u32,

    /**
     * The name that captures the value of an optional condition, or {@link NoToken}.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.captureToken); // 'user'
     * ```
     *
     * @since 1.0.0
     */

    captureToken: u32,

    /**
     * The statement that runs when the condition holds.
     *
     * @example
     * ```hx
     * data.thenBranch; // the greet(user) statement
     * ```
     *
     * @since 1.0.0
     */

    thenBranch: u32,

    /**
     * The statement that runs otherwise, or 0 without an `else`.
     *
     * @example
     * ```hx
     * data.elseBranch; // 0 for if (ready) start();
     * ```
     *
     * @since 1.0.0
     */

    elseBranch: u32,
}

/**
 * The record of a `While` node.
 *
 * @remarks
 * The parser stores it in the extra array and puts its index in the `a` slot of the node.
 * The label and the capture are optional, and each one is {@link NoToken} when absent.
 *
 * @example
 * ```hx
 * // outer: while (const line = next()) print(line);
 * // { condition: <next()>, captureToken: <line>, body, labelToken: <outer> }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxWhileData {
    /**
     * The condition.
     *
     * @example
     * ```hx
     * data.condition; // the next() of the example above
     * ```
     *
     * @since 1.0.0
     */

    condition: u32,

    /**
     * The name that captures the value of an optional condition, or {@link NoToken}.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.captureToken); // 'line'
     * ```
     *
     * @since 1.0.0
     */

    captureToken: u32,

    /**
     * The statement that repeats.
     *
     * @example
     * ```hx
     * data.body; // the print(line) statement
     * ```
     *
     * @since 1.0.0
     */

    body: u32,

    /**
     * The label of the loop, or {@link NoToken}.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.labelToken); // 'outer'
     * ```
     *
     * @since 1.0.0
     */

    labelToken: u32,
}

/**
 * The record of a C-style `For` node.
 *
 * @remarks
 * The parser stores it in the extra array and puts its index in the `a` slot of the node.
 * Any of the three clauses may be left out, which leaves 0 in its field.
 *
 * @example
 * ```hx
 * // for (let i = 0; i < n; i++) step(i);
 * // { init: <let i = 0>, condition: <i < n>, step: <i++>, body, labelToken: NoToken }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxForData {
    /**
     * The statement that runs once before the loop, or 0.
     *
     * @example
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
     * data.body; // the step(i) statement
     * ```
     *
     * @since 1.0.0
     */

    body: u32,

    /**
     * The label of the loop, or {@link NoToken}.
     *
     * @example
     * ```hx
     * data.labelToken; // NoToken without a label
     * ```
     *
     * @since 1.0.0
     */

    labelToken: u32,
}

/**
 * The record of a `ForOf` node.
 *
 * @remarks
 * The parser stores it in the extra array and puts its index in the `a` slot of the node.
 * The index name and the label are optional, and each one is {@link NoToken} when absent.
 *
 * @example
 * ```hx
 * // for (const item, i of items) use(item);
 * // { itemToken: <item>, indexToken: <i>, iterable: <items>, body, labelToken: NoToken }
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxForOfData {
    /**
     * The name of each item.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.itemToken); // 'item'
     * ```
     *
     * @since 1.0.0
     */

    itemToken: u32,

    /**
     * The name of the index of each item, or {@link NoToken}.
     *
     * @example
     * ```hx
     * tokenText(&ast, data.indexToken); // 'i'
     * ```
     *
     * @since 1.0.0
     */

    indexToken: u32,

    /**
     * The collection or `Range` node that the loop walks.
     *
     * @example
     * ```hx
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
     * ```hx
     * data.body; // the use(item) statement
     * ```
     *
     * @since 1.0.0
     */

    body: u32,

    /**
     * The label of the loop, or {@link NoToken}.
     *
     * @example
     * ```hx
     * data.labelToken; // NoToken without a label
     * ```
     *
     * @since 1.0.0
     */

    labelToken: u32,
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
 * ```hx
 * let ast: HxAst = undefined;
 * hxAstInit(&ast, &src, &tokens);
 * // the parser fills it, then ast.root is the File node
 * hxAstFree(&ast);
 * ```
 *
 * @see HxNode
 * @see hxAstInit
 *
 * @since 1.0.0
 */

export extern "C" struct HxAst {
    /**
     * The source that the tokens point into.
     *
     * @example
     * ```hx
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
     * ```hx
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
     * ```hx
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
     * ```hx
     * ast.nodesLen; // 1 for a new tree
     * ```
     *
     * @since 1.0.0
     */

    nodesLen: u32,

    /**
     * The capacity of the node array.
     *
     * @example
     * ```hx
     * ast.nodesCap; // about half the token count
     * ```
     *
     * @since 1.0.0
     */

    nodesCap: u32,

    /**
     * The child lists and records that do not fit in a node.
     *
     * @example
     * ```hx
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
     * ```hx
     * ast.extraLen; // 0 for a new tree
     * ```
     *
     * @since 1.0.0
     */

    extraLen: u32,

    /**
     * The capacity of the extra array in words.
     *
     * @example
     * ```hx
     * ast.extraCap; // about a quarter of the token count
     * ```
     *
     * @since 1.0.0
     */

    extraCap: u32,

    /**
     * The index of the `File` node of the entry file, or 0 before parsing.
     *
     * @remarks
     * A program of several files has one `File` node per file, and this one belongs to the file it started from.
     *
     * @example
     * ```hx
     * node(&ast, ast.root).kind; // NodeKind.File
     * ```
     *
     * @since 1.0.0
     */

    root: u32,
}
