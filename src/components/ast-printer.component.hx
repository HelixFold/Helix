/**
 * Imports
 */

import { node, extraAt, record, tokenText } from "@models/ast.model";
import { Printer } from "@components/structs/ast-printer-component.struct";
import { FLAG_NAMESPACE, FLAG_VARIADIC, FLAG_COMPTIME } from "@constants/ast.constant";
import { HxFnData, HxContainerData, HxImportData, HxRange } from "@models/structs/ast-model.struct";
import { HxWhileData, HxForData, HxForOfData, HxTestData, HxSliceData } from "@models/structs/ast-model.struct";
import { HxTernaryData, HxCatchData, HxCaseData, HxIfData, HxAst, HxNode } from "@models/structs/ast-model.struct";
import { FLAG_INCLUSIVE, TEST_MODE_LABELS, FLAG_EXPR, FLAG_POINTER, NodeKind, BinOp } from "@constants/ast.constant";
import { NODE_NAMES, BINOP_SPELLINGS, NO_TOKEN, HOOK_NAMES, FLAG_EXPORT, FLAG_EXTERN } from "@constants/ast.constant";

/**
 * The C library function that the printer writes through.
 */

extern "C" function fwrite(bytes: readonly u8[*], size: usize, count: usize, file: ?u8[*]): usize;

/**
 * Writes text to the output stream.
 *
 * @param pr - The printer state
 * @param text - The text to write, where an empty text writes nothing
 */

function put(pr: *Printer, text: string): void {
    if (text.len > 0) void fwrite(text.ptr, 1, text.len, pr.out);
}

/**
 * Writes the text of a token.
 *
 * @param pr - The printer state
 * @param token - The index of the token, where {@link NO_TOKEN} writes `_`
 */

function printToken(pr: *Printer, token: u32): void {
    if (token == NO_TOKEN) put(pr, "_");
    else put(pr, tokenText(pr.ast, token));
}

/**
 * Starts a new indented line in pretty mode, or writes a space in compact mode.
 *
 * @param pr - The printer state
 */

function line(pr: *Printer): void {
    if (!pr.pretty) {
        put(pr, " ");
        return;
    }
    put(pr, "\n");
    for (const _ of 0..pr.indent) put(pr, "  ");
}

/**
 * Returns the printed name of a node kind.
 *
 * @param kind - The kind to name
 * @returns The name from {@link NODE_NAMES}
 */

function name(kind: NodeKind): string {
    return NODE_NAMES[kind as usize];
}

/**
 * Writes an opening parenthesis, a label, and the `:export` and `:extern` markers.
 *
 * @param pr - The printer state
 * @param label - The label of the node
 * @param flags - The `FLAG_` bits of the node
 */

function open(pr: *Printer, label: string, flags: u8): void {
    put(pr, "(");
    put(pr, label);
    if ((flags & FLAG_EXPORT) != 0) put(pr, " :export");
    if ((flags & FLAG_EXTERN) != 0) put(pr, " :extern");
}

/**
 * Writes a closing parenthesis.
 *
 * @param pr - The printer state
 */

function close(pr: *Printer): void {
    put(pr, ")");
}

/**
 * Writes a space and a child node.
 *
 * @param pr - The printer state
 * @param id - The index of the child, where 0 writes `_`
 */

function child(pr: *Printer, id: u32): void {
    put(pr, " ");
    printNode(pr, id);
}

/**
 * Writes a space and the text of a token.
 *
 * @param pr - The printer state
 * @param token - The index of the token
 */

function tokenChild(pr: *Printer, token: u32): void {
    put(pr, " ");
    printToken(pr, token);
}

/**
 * Writes each node of a child list inline.
 *
 * @param pr - The printer state
 * @param start - The index of the first entry in the extra array
 * @param end - The index one past the last entry
 */

function list(pr: *Printer, start: u32, end: u32): void {
    for (const i of start..end) child(pr, extraAt(pr.ast, i));
}

/**
 * Writes each node of a child list on its own indented line.
 *
 * @param pr - The printer state
 * @param start - The index of the first entry in the extra array
 * @param end - The index one past the last entry
 */

function lines(pr: *Printer, start: u32, end: u32): void {
    pr.indent += 1;
    for (const i of start..end) {
        line(pr);
        printNode(pr, extraAt(pr.ast, i));
    }
    pr.indent -= 1;
}

/**
 * Writes a labeled group of a child list, such as `(generics T U)`.
 *
 * @param pr - The printer state
 * @param label - The label of the group
 * @param start - The index of the first entry in the extra array
 * @param end - The index one past the last entry
 *
 * @remarks
 * An empty list writes nothing.
 */

function group(pr: *Printer, label: string, start: u32, end: u32): void {
    if (start == end) return;
    put(pr, " (");
    put(pr, label);
    list(pr, start, end);
    close(pr);
}

/**
 * Writes the generics, the parameters, and the return type of a function.
 *
 * @param pr - The printer state
 * @param fn - The record of the function
 */

function printSignature(pr: *Printer, fn: HxFnData): void {
    group(pr, "generics", fn.generics_start, fn.generics_end);
    put(pr, " (params");
    list(pr, fn.params_start, fn.params_end);
    close(pr);
    child(pr, fn.return_type);
}

/**
 * Writes a struct, an enum, a union, or an interface with its members.
 *
 * @param pr - The printer state
 * @param n - The node of the declaration
 * @param label - The label to print
 */

function printContainer(pr: *Printer, n: HxNode, label: string): void {
    const data = record<HxContainerData>(pr.ast, n.a);
    open(pr, label, n.flags);
    tokenChild(pr, n.token);
    if (data.backing_type != 0) child(pr, data.backing_type);
    group(pr, "generics", data.generics_start, data.generics_end);
    lines(pr, data.members_start, data.members_end);
    close(pr);
}

/**
 * Writes a body on its own indented line.
 *
 * @param pr - The printer state
 * @param body - The index of the body node
 */

function printBody(pr: *Printer, body: u32): void {
    pr.indent += 1;
    line(pr);
    printNode(pr, body);
    pr.indent -= 1;
}

/**
 * Writes the `:label` marker of a loop.
 *
 * @param pr - The printer state
 * @param label - The index of the label token, where {@link NO_TOKEN} writes nothing
 */

function loopLabel(pr: *Printer, label: u32): void {
    if (label == NO_TOKEN) return;
    put(pr, " :label");
    tokenChild(pr, label);
}

/**
 * Writes the condition of an `if` or a `while`, with its capture.
 *
 * @param pr - The printer state
 * @param capture - The index of the captured name, or {@link NO_TOKEN}
 * @param cond - The index of the condition node
 *
 * @remarks
 * A capture prints as `(const name cond)`.
 */

function condition(pr: *Printer, capture: u32, cond: u32): void {
    if (capture == NO_TOKEN) {
        child(pr, cond);
        return;
    }
    put(pr, " (const");
    tokenChild(pr, capture);
    child(pr, cond);
    close(pr);
}

/**
 * Writes one node and everything under it.
 *
 * @param pr - The printer state
 * @param id - The index of the node, where 0 writes `_`
 *
 * @remarks
 * An atom prints as its token text, and every other node prints as `(label children...)`.
 * A binary operation and a range print with their operator as the label.
 */

function printNode(pr: *Printer, id: u32): void {
    if (id == 0) {
        put(pr, "_");
        return;
    }
    const ast = pr.ast;
    const n = node(ast, id);
    switch (n.kind) {
        case NodeKind.None: put(pr, "_");
        case NodeKind.Invalid: put(pr, "<error>");

        // atoms: the token text itself
        case NodeKind.Ident, NodeKind.Int, NodeKind.Float, NodeKind.String, NodeKind.Char, NodeKind.True,
             NodeKind.False, NodeKind.Null, NodeKind.Undefined, NodeKind.Unreachable, NodeKind.TemplateText,
             NodeKind.ErrorMember: printToken(pr, n.token);

        case NodeKind.EnumLiteral: {
            put(pr, ".");
            printToken(pr, n.token);
        }
        case NodeKind.File: {
            put(pr, "(file");
            lines(pr, n.a, n.b);
            close(pr);
        }
        case NodeKind.Import: {
            const data = record<HxImportData>(ast, n.a);
            put(pr, (n.flags & FLAG_EXPORT) != 0 ? "(export-from" : "(import");
            tokenChild(pr, data.path_token);
            if ((n.flags & FLAG_NAMESPACE) != 0) {
                put(pr, " *");
                if (data.alias_token != NO_TOKEN) tokenChild(pr, data.alias_token);
            }
            list(pr, data.specs_start, data.specs_end);
            close(pr);
        }
        case NodeKind.ImportSpec: {
            put(pr, "(");
            printToken(pr, n.token);
            if (n.a != NO_TOKEN) {
                put(pr, " as");
                tokenChild(pr, n.a);
            }
            close(pr);
        }
        case NodeKind.Const, NodeKind.Let: {
            open(pr, name(n.kind), n.flags);
            tokenChild(pr, n.token);
            child(pr, n.a);
            child(pr, n.b);
            close(pr);
        }
        case NodeKind.Function: {
            const fn = record<HxFnData>(ast, n.a);
            open(pr, "function", n.flags);
            if (fn.abi_token != NO_TOKEN) tokenChild(pr, fn.abi_token);
            tokenChild(pr, n.token);
            printSignature(pr, fn);
            if ((n.flags & FLAG_VARIADIC) != 0) put(pr, " ...");
            if (fn.body != 0) printBody(pr, fn.body);
            close(pr);
        }
        case NodeKind.TypeFunction, NodeKind.ArrowFunction: {
            const fn = record<HxFnData>(ast, n.a);
            open(pr, name(n.kind), 0);
            printSignature(pr, fn);
            if (fn.body != 0) child(pr, fn.body);
            close(pr);
        }
        case NodeKind.Param: {
            put(pr, "(");
            if ((n.flags & FLAG_COMPTIME) != 0) put(pr, "comptime ");
            printToken(pr, n.token);
            child(pr, n.a);
            close(pr);
        }
        case NodeKind.GenericParam: {
            put(pr, "(");
            printToken(pr, n.token);
            if (n.a != 0) child(pr, n.a);
            close(pr);
        }
        case NodeKind.Struct: printContainer(pr, n, "struct");
        case NodeKind.Enum: printContainer(pr, n, "enum");
        case NodeKind.Union: printContainer(pr, n, "union");
        case NodeKind.Interface: printContainer(pr, n, "interface");
        case NodeKind.FieldDecl, NodeKind.EnumMember, NodeKind.UnionVariant: {
            open(pr, name(n.kind), n.flags);
            tokenChild(pr, n.token);
            if (n.a != 0) child(pr, n.a);
            if (n.b != 0) child(pr, n.b);
            close(pr);
        }
        case NodeKind.ErrorSet: {
            open(pr, "error", n.flags);
            tokenChild(pr, n.token);
            list(pr, n.a, n.b);
            close(pr);
        }
        case NodeKind.TypeAlias: {
            const data = record<HxContainerData>(ast, n.a);
            open(pr, "type", n.flags);
            tokenChild(pr, n.token);
            group(pr, "generics", data.generics_start, data.generics_end);
            child(pr, n.b);
            close(pr);
        }
        case NodeKind.TypeStruct, NodeKind.Template, NodeKind.ArrayLiteral, NodeKind.PatternStruct: {
            open(pr, name(n.kind), 0);
            list(pr, n.a, n.b);
            close(pr);
        }
        case NodeKind.BuiltinCall: {
            put(pr, "(");
            printToken(pr, n.token);
            list(pr, n.a, n.b);
            close(pr);
        }
        case NodeKind.ImportExpr: {
            put(pr, "(import");
            tokenChild(pr, n.token);
            close(pr);
        }
        case NodeKind.Call, NodeKind.GenericInstance, NodeKind.StructLiteral: {
            const args = record<HxRange>(ast, n.b);
            open(pr, name(n.kind), 0);
            child(pr, n.a);
            list(pr, args.start, args.end);
            close(pr);
        }
        case NodeKind.FieldInit, NodeKind.PatternField: {
            put(pr, "(");
            printToken(pr, n.token);
            if (n.a != 0) child(pr, n.a);
            close(pr);
        }
        case NodeKind.Slice: {
            const data = record<HxSliceData>(ast, n.b);
            open(pr, (n.flags & FLAG_INCLUSIVE) != 0 ? "slice-of=" : "slice-of", 0);
            child(pr, n.a);
            child(pr, data.start);
            child(pr, data.end);
            close(pr);
        }
        case NodeKind.FieldAccess, NodeKind.OptionalField: {
            open(pr, name(n.kind), 0);
            child(pr, n.a);
            tokenChild(pr, n.token);
            close(pr);
        }
        case NodeKind.Binary: {
            open(pr, BINOP_SPELLINGS[n.op as usize], 0);
            child(pr, n.a);
            child(pr, n.b);
            close(pr);
        }
        case NodeKind.Assign: {
            put(pr, "(");
            if (n.op != BinOp.None as u16) put(pr, BINOP_SPELLINGS[n.op as usize]);
            put(pr, "=");
            child(pr, n.a);
            child(pr, n.b);
            close(pr);
        }
        case NodeKind.Range, NodeKind.PatternRange: {
            open(pr, (n.flags & FLAG_INCLUSIVE) != 0 ? "..=" : "..", 0);
            child(pr, n.a);
            child(pr, n.b);
            close(pr);
        }
        case NodeKind.Ternary: {
            const data = record<HxTernaryData>(ast, n.b);
            open(pr, "?", 0);
            child(pr, n.a);
            child(pr, data.then_value);
            child(pr, data.else_value);
            close(pr);
        }
        case NodeKind.Catch: {
            const data = record<HxCatchData>(ast, n.b);
            open(pr, "catch", 0);
            child(pr, n.a);
            tokenChild(pr, data.capture_token);
            child(pr, data.body);
            close(pr);
        }
        case NodeKind.Switch: {
            const cases = record<HxRange>(ast, n.b);
            open(pr, (n.flags & FLAG_EXPR) != 0 ? "switch-expr" : "switch", 0);
            child(pr, n.a);
            lines(pr, cases.start, cases.end);
            close(pr);
        }
        case NodeKind.Case: {
            const data = record<HxCaseData>(ast, n.a);
            put(pr, "(case (");
            for (const i of data.patterns_start..data.patterns_end) {
                if (i != data.patterns_start) put(pr, " ");
                printNode(pr, extraAt(ast, i));
            }
            put(pr, ")");
            if (data.guard != 0) {
                put(pr, " (if");
                child(pr, data.guard);
                close(pr);
            }
            child(pr, data.body);
            close(pr);
        }
        case NodeKind.PatternBind: {
            put(pr, (n.flags & FLAG_POINTER) != 0 ? "(bind *" : "(bind ");
            printToken(pr, n.token);
            close(pr);
        }
        case NodeKind.PatternTag: {
            put(pr, "(tag");
            child(pr, n.a);
            child(pr, n.b);
            close(pr);
        }
        case NodeKind.PatternValue, NodeKind.ExprStmt: printNode(pr, n.a);
        case NodeKind.Block: {
            put(pr, "(block");
            lines(pr, n.a, n.b);
            close(pr);
        }
        case NodeKind.Break, NodeKind.Continue: {
            open(pr, name(n.kind), 0);
            if (n.a != NO_TOKEN) tokenChild(pr, n.a);
            close(pr);
        }
        case NodeKind.If: {
            const data = record<HxIfData>(ast, n.a);
            put(pr, "(if");
            condition(pr, data.capture_token, data.condition);
            printBody(pr, data.then_branch);
            if (data.else_branch != 0) printBody(pr, data.else_branch);
            close(pr);
        }
        case NodeKind.While: {
            const data = record<HxWhileData>(ast, n.a);
            put(pr, "(while");
            loopLabel(pr, data.label_token);
            condition(pr, data.capture_token, data.condition);
            printBody(pr, data.body);
            close(pr);
        }
        case NodeKind.For: {
            const data = record<HxForData>(ast, n.a);
            put(pr, "(for");
            loopLabel(pr, data.label_token);
            child(pr, data.init);
            child(pr, data.condition);
            child(pr, data.step);
            printBody(pr, data.body);
            close(pr);
        }
        case NodeKind.ForOf: {
            const data = record<HxForOfData>(ast, n.a);
            put(pr, "(for-of");
            loopLabel(pr, data.label_token);
            tokenChild(pr, data.item_token);
            if (data.index_token != NO_TOKEN) tokenChild(pr, data.index_token);
            child(pr, data.iterable);
            printBody(pr, data.body);
            close(pr);
        }
        case NodeKind.Errdefer: {
            put(pr, "(errdefer");
            if (n.b != NO_TOKEN) tokenChild(pr, n.b);
            child(pr, n.a);
            close(pr);
        }
        case NodeKind.Hook: {
            put(pr, "(");
            put(pr, HOOK_NAMES[n.op as usize]);
            printBody(pr, n.a);
            close(pr);
        }
        case NodeKind.Describe, NodeKind.Test: {
            put(pr, "(");
            put(pr, name(n.kind));
            put(pr, TEST_MODE_LABELS[n.op as usize]);
            tokenChild(pr, n.token);
            if (n.kind == NodeKind.Describe) {
                lines(pr, n.a, n.b);
            } else {
                const data = record<HxTestData>(ast, n.b);
                if (data.message_token != NO_TOKEN) tokenChild(pr, data.message_token);
                if (data.timeout_token != NO_TOKEN) {
                    put(pr, " :timeout");
                    tokenChild(pr, data.timeout_token);
                }
                if (n.a != 0) printBody(pr, n.a);
            }
            close(pr);
        }
        // everything else: (label a b), omitting absent children
        default: {
            open(pr, name(n.kind), 0);
            if (n.a != 0) child(pr, n.a);
            if (n.b != 0) child(pr, n.b);
            close(pr);
        }
    }
}

/**
 * Writes a node and everything under it as an S-expression.
 *
 * @param ast - The tree that holds the node
 * @param id - The index of the node, usually the root
 * @param out - The C `FILE` to write to
 * @param pretty - Whether to put declarations and statements on their own indented lines
 *
 * @remarks
 * `helix ast` prints a tree this way, and the parser specs compare against it.
 * An operator prints as the label of its node, so `a + b * c` prints as `(+ a (* b c))`.
 * Without `pretty`, the whole node fits on one line.
 * A newline always ends the output.
 *
 * @example
 * ```ts
 * hx_ast_print(&ast, ast.root, stdout, false);
 * // (file (const x _ (+ 1 (* 2 3))))
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_ast_print(ast: readonly *HxAst, id: u32, out: ?u8[*], pretty: bool): void {
    let pr = Printer { ast, out, pretty, indent: 0 };
    printNode(&pr, id);
    put(&pr, "\n");
}
