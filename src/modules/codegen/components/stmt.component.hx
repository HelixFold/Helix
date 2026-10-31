/**
 * Imports
 */

import { record } from "@models/ast.model";
import { TypeKind } from "@constants/types.constant";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { HxInfoDyn, HxInfoDeref } from "@constants/sema.constant";
import { ModeDebug } from "@modules/codegen/constants/base.constant";
import { elementAddress } from "@modules/codegen/components/expr.component";
import { NodeKind, BinOp, FlagInclusive, NoToken } from "@constants/ast.constant";
import { HxIfData, HxWhileData, HxForData, HxForOfData } from "@models/structs/ast-model.struct";
import { Cg, Value, Block, Loop } from "@modules/codegen/components/structs/base-component.struct";
import { HxInfoReceiverAddr, HxInfoIterator, HxValueUndefined, HxSymAddressed } from "@constants/sema.constant";
import { load, store, branch, condBr, compareIntegers, lower } from "@modules/codegen/components/base.component";
import { emitArith, emitSwitch, emitErrorReturn, emitIndexable } from "@modules/codegen/components/expr.component";
import { optionalPayload, setLocation, entryAlloca, localStorage } from "@modules/codegen/components/base.component";
import { extra, nodeOf, infoOf, typeOf, symbolOf, value, finalType } from "@modules/codegen/components/base.component";
import { slotSignature, slotType, loadSlot, emitValue, emitAddress } from "@modules/codegen/components/expr.component";
import { isSigned, terminated, block, positionAtEnd, int8Type, call } from "@modules/codegen/components/base.component";
import { knownCondition, debuggable, extract, push, vectorAt, fatal } from "@modules/codegen/components/base.component";
import { lowerFunction, constUsize, constErrorCode, optionalPresent } from "@modules/codegen/components/base.component";

/**
 * Emits the pending `defer` and `errdefer` statements above a mark, innermost first, without popping them.
 *
 * @param cg - The code generator
 * @param mark - The length of the defer stack to unwind down to, where 0 unwinds the whole function
 * @param errorCode - The error that the function leaves with, or `null` when it leaves normally
 *
 * @remarks
 * An `errdefer` only runs when the function leaves with an error, so a `null` error code skips it.
 * With an error code, the error goes into the capture of the `errdefer` first, which is how its body sees the error.
 * The stack keeps its entries, since every way out of a scope, such as `return`, `break`, and the normal end,
 * emits its own copy of the same deferred code.
 * Emitting stops as soon as a deferred statement leaves the block, such as one that panics.
 *
 * @example
 * ```hx
 * // { defer close(); return 1; }
 * emitDefers(cg, 0, null); // close() runs before the ret
 * ```
 *
 * @see emitScoped
 * @see emitErrorReturn
 *
 * @since 1.0.0
 */

export function emitDefers(cg: *Cg, mark: u32, errorCode: Value): void {
    let i = cg.defers.len;
    while (i > mark && !terminated(cg)) {
        const d = vectorAt(&cg.defers, i - 1);
        i -= 1;
        if (nodeOf(cg, d).kind == NodeKind.Errdefer) {
            if (errorCode == null) continue;
            if (infoOf(cg, d).symbol != 0) store(cg, errorCode, localStorage(cg, infoOf(cg, d).symbol));
        }
        const saved = cg.defers.len;
        emitStmt(cg, nodeOf(cg, d).a);
        cg.defers.len = saved;
    }
}

/**
 * Emits a statement as its own scope, so that its defers run when it ends normally.
 *
 * @param cg - The code generator
 * @param stmt - The statement node
 *
 * @remarks
 * The `defer` statements that the statement pushes are emitted at its end unless the block has already left,
 * and the defer stack goes back to where it was either way.
 * Branches of an `if`, loop bodies, and `switch` cases are emitted this way.
 *
 * @example
 * ```hx
 * // if (ok) { defer done(); work(); }
 * emitScoped(cg, thenBranch); // work(), then done(), inside the if.then block
 * ```
 *
 * @see emitDefers
 * @since 1.0.0
 */

export function emitScoped(cg: *Cg, stmt: u32): void {
    const mark = cg.defers.len;
    emitStmt(cg, stmt);
    if (!terminated(cg)) emitDefers(cg, mark, null);
    cg.defers.len = mark;
}

/**
 * Emits a `const` or `let` declaration: the storage of the local and the store of its initial value.
 *
 * @param cg - The code generator
 * @param node - The declaration node
 *
 * @remarks
 * A constant whose value the checker knows gets no storage, since every use reads the value directly.
 * It still gets one when its address is taken, or when debug info can show it in a debugger.
 * An initial value of `undefined` stores nothing.
 * In debug builds it fills the memory with the byte 0xAA instead,
 * so that a read before the first write is easy to spot.
 *
 * @example
 * ```hx
 * // let x: i32 = 1;
 * emitLocal(cg, node); // %x = alloca i32, then store i32 1, ptr %x
 * ```
 *
 * @see emitStmt
 * @since 1.0.0
 */

export function emitLocal(cg: *Cg, node: u32): void {
    const sym = infoOf(cg, node).symbol;
    if (sym == 0 || symbolOf(cg, sym).type == 0) return;
    // Constants need no storage, except to show them in a debugger.
    if (symbolOf(cg, sym).value != 0 && (symbolOf(cg, sym).flags & (HxSymAddressed as u16)) == 0 && !debuggable(cg, symbolOf(cg, sym).type)) return;
    const slot = localStorage(cg, sym);
    const init = nodeOf(cg, node).b;
    if (init == 0) return;

    if (infoOf(cg, init).value != 0 && value(cg, infoOf(cg, init).value).kind == HxValueUndefined as u8) {
        // Debug builds fill undefined memory with 0xAA so reading it before writing is easy to spot.
        if (cg.options.mode == ModeDebug) {
            const size = llvm.LLVMABISizeOfType(cg.layout, lower(cg, symbolOf(cg, sym).type));
            void llvm.LLVMBuildMemSet(cg.b, slot, llvm.LLVMConstInt(int8Type(cg), 0xAA, 0), constUsize(cg, size), 1);
        }
        return;
    }
    const v = emitValue(cg, init);
    if (v != null && !terminated(cg)) store(cg, v, slot);
}

/**
 * Emits an assignment, plain or compound.
 *
 * @param cg - The code generator
 * @param node - The assignment node
 *
 * @remarks
 * A plain `x = v` stores the value, and `x = undefined` stores nothing.
 * A compound `x += v` loads the old value, applies the operator through {@link emitArith}, and stores the result,
 * so it gets the same overflow checks as `x = x + v`.
 *
 * @since 1.0.0
 */

function emitAssign(cg: *Cg, node: u32): void {
    const n = nodeOf(cg, node);
    const op = @enumFromInt(BinOp, n.op);
    const address = emitAddress(cg, n.a);
    const type = infoOf(cg, n.a).type;

    if (op == BinOp.None) {
        if (infoOf(cg, n.b).value != 0 && value(cg, infoOf(cg, n.b).value).kind == HxValueUndefined as u8) return;
        const v = emitValue(cg, n.b);
        if (v != null) store(cg, v, address);
        return;
    }
    const old = load(cg, lower(cg, type), address, "");
    const rhs = emitValue(cg, n.b);
    store(cg, emitArith(cg, op, old, rhs, type, node), address);
}

/**
 * Makes a loop the innermost target of `break` and `continue`.
 *
 * @param cg - The code generator
 * @param node - The loop node, which the checker records as the target of each jump
 * @param breakBlock - The block that `break` jumps to
 * @param continueBlock - The block that `continue` jumps to
 *
 * @remarks
 * The loop also remembers the depth of the defer stack, so a jump out of it runs only the defers inside the loop.
 *
 * @since 1.0.0
 */

function pushLoop(cg: *Cg, node: u32, breakBlock: Block, continueBlock: Block): void {
    cg.loops[cg.loopCount] = Loop { node, breakBlock: breakBlock, continueBlock: continueBlock, deferMark: cg.defers.len };
    cg.loopCount += 1;
}

/**
 * Emits a `break` or `continue`, running the defers inside the loop that it leaves.
 *
 * @param cg - The code generator
 * @param node - The jump node, whose symbol is the loop node that it targets
 * @param isBreak - Whether the jump is a `break` rather than a `continue`
 *
 * @remarks
 * The target can be an outer loop of a labeled jump, so the loops are searched from the innermost outward.
 * A target missing from the stack is an internal error.
 *
 * @since 1.0.0
 */

function emitJump(cg: *Cg, node: u32, isBreak: bool): void {
    const target = infoOf(cg, node).symbol;
    let i = cg.loopCount;
    while (i > 0) {
        i -= 1;
        const loop = cg.loops[i];
        if (loop.node != target) continue;
        emitDefers(cg, loop.deferMark, null);
        branch(cg, isBreak ? loop.breakBlock : loop.continueBlock);
        return;
    }
    fatal(cg, "codegen: jump target loop not found");
}

/**
 * Emits the body of a loop as its own scope, then a jump to the next step unless the body left.
 *
 * @param cg - The code generator
 * @param node - The loop node
 * @param body - The body statement
 * @param end - The block after the loop, which `break` jumps to
 * @param next - The block that `continue` and the end of the body jump to
 *
 * @remarks
 * It pushes the loop for the length of the body only, so `break` and `continue` inside it find their targets,
 * and the loop is gone from the stack again once the body ends.
 * Every loop form shares it, so the condition and the step stay with the caller.
 *
 * @since 1.0.0
 */

function loopBody(cg: *Cg, node: u32, body: u32, end: Block, next: Block): void {
    pushLoop(cg, node, end, next);
    emitScoped(cg, body);
    if (!terminated(cg)) branch(cg, next);
    cg.loopCount -= 1;
}

/**
 * Emits a `while` loop as a condition block, a body block, and an end block.
 *
 * @param cg - The code generator
 * @param node - The `while` node
 *
 * @remarks
 * The capturing form `while (const item = it.next())` tests whether the optional holds a value,
 * and stores the payload in the capture at the start of each pass through the body.
 *
 * @since 1.0.0
 */

function emitWhile(cg: *Cg, node: u32): void {
    const data = record<HxWhileData>(cg.ast, nodeOf(cg, node).a);
    const cond = block(cg, "while.cond");
    const body = block(cg, "while.body");
    const end = block(cg, "while.end");

    branch(cg, cond);
    positionAtEnd(cg, cond);
    let test = emitValue(cg, data.condition);
    let payload: Value = null;
    if (data.captureToken != NoToken) {   // `while (const item = it.next())`
        const type = finalType(cg, data.condition);
        payload = optionalPayload(cg, test, type);
        test = optionalPresent(cg, test, type);
    }
    condBr(cg, test, body, end);

    positionAtEnd(cg, body);
    if (payload != null && infoOf(cg, node).symbol != 0) store(cg, payload, localStorage(cg, infoOf(cg, node).symbol));
    loopBody(cg, node, data.body, end, cond);
    positionAtEnd(cg, end);
}

/**
 * Emits a C-style `for (init; condition; step)` loop.
 *
 * @param cg - The code generator
 * @param node - The `for` node
 *
 * @remarks
 * A missing condition loops until a jump leaves.
 * A `continue` jumps to the step block, which runs the step and goes back to the condition.
 *
 * @since 1.0.0
 */

function emitFor(cg: *Cg, node: u32): void {
    const data = record<HxForData>(cg.ast, nodeOf(cg, node).a);
    emitStmt(cg, data.init);

    const cond = block(cg, "for.cond");
    const body = block(cg, "for.body");
    const step = block(cg, "for.step");
    const end = block(cg, "for.end");

    branch(cg, cond);
    positionAtEnd(cg, cond);
    if (data.condition != 0) condBr(cg, emitValue(cg, data.condition), body, end);
    else branch(cg, body);

    positionAtEnd(cg, body);
    loopBody(cg, node, data.body, end, step);

    positionAtEnd(cg, step);
    emitStmt(cg, data.step);
    branch(cg, cond);
    positionAtEnd(cg, end);
}

/**
 * Emits `for (const x of a..b)`, counting in the item's own type.
 *
 * @param cg - The code generator
 * @param node - The `for` node
 * @param data - The parts of the loop, where the iterable is the range
 *
 * @remarks
 * The exclusive form tests `x < b` before each pass.
 * The inclusive form `a..=b` tests for an empty range once,
 * then checks for the last value before it adds one, so `0..=255` over a `u8` never overflows.
 * The optional index counts from 0 in a `usize` beside the item.
 *
 * @since 1.0.0
 */

function emitForRange(cg: *Cg, node: u32, data: readonly *HxForOfData): void {
    const range = nodeOf(cg, data.iterable);
    const inclusive = (range.flags & FlagInclusive) != 0;
    const itemSym = infoOf(cg, node).symbol;
    const type = infoOf(cg, data.iterable).type;
    const sign = isSigned(cg, type);

    const start = emitValue(cg, range.a);
    const stop = emitValue(cg, range.b);
    const item = localStorage(cg, itemSym);
    const index = data.indexToken != NoToken ? localStorage(cg, itemSym + 1) : null;
    store(cg, start, item);
    if (index != null) store(cg, constUsize(cg, 0), index);

    const cond = block(cg, "range.cond");
    const body = block(cg, "range.body");
    const step = block(cg, "range.step");
    const end = block(cg, "range.end");

    if (inclusive) {
        const empty = compareIntegers(cg, sign ? llvm.LLVMIntSGT : llvm.LLVMIntUGT, start, stop);
        condBr(cg, empty, end, body);
        llvm.LLVMDeleteBasicBlock(cond);
    } else {
        branch(cg, cond);
        positionAtEnd(cg, cond);
        const current = load(cg, lower(cg, type), item, "");
        condBr(cg, compareIntegers(cg, sign ? llvm.LLVMIntSLT : llvm.LLVMIntULT, current, stop), body, end);
    }

    positionAtEnd(cg, body);
    loopBody(cg, node, data.body, end, step);

    positionAtEnd(cg, step);
    const current = load(cg, lower(cg, type), item, "");
    const next = block(cg, "range.next");
    if (inclusive) condBr(cg, compareIntegers(cg, llvm.LLVMIntEQ, current, stop), end, next);
    else branch(cg, next);
    positionAtEnd(cg, next);
    const one = llvm.LLVMConstInt(lower(cg, type), 1, 0);
    store(cg, sign ? llvm.LLVMBuildNSWAdd(cg.b, current, one, "") : llvm.LLVMBuildNUWAdd(cg.b, current, one, ""), item);
    if (index != null) {
        const i = load(cg, lower(cg, cg.types.usize), index, "");
        store(cg, llvm.LLVMBuildNUWAdd(cg.b, i, constUsize(cg, 1), ""), index);
    }
    branch(cg, inclusive ? body : cond);
    positionAtEnd(cg, end);
}

/**
 * Emits `for (const x, i of items)` over a slice, an array, a pointer to an array, or a string literal.
 *
 * @param cg - The code generator
 * @param node - The `for` node
 * @param data - The parts of the loop
 *
 * @remarks
 * A hidden `usize` counter runs from 0 to the length, and each pass copies the element at the counter into the item.
 * The counter never goes past the length, so the loop needs no bounds check.
 *
 * @since 1.0.0
 */

function emitForItems(cg: *Cg, node: u32, data: readonly *HxForOfData): void {
    const itemSym = infoOf(cg, node).symbol;
    const base = emitIndexable(cg, data.iterable);
    const usize = lower(cg, cg.types.usize);

    const counter = entryAlloca(cg, usize, "i");
    store(cg, constUsize(cg, 0), counter);
    const item = localStorage(cg, itemSym);
    const index = data.indexToken != NoToken ? localStorage(cg, itemSym + 1) : null;

    const cond = block(cg, "items.cond");
    const body = block(cg, "items.body");
    const step = block(cg, "items.step");
    const end = block(cg, "items.end");

    branch(cg, cond);
    positionAtEnd(cg, cond);
    const i = load(cg, usize, counter, "");
    condBr(cg, compareIntegers(cg, llvm.LLVMIntULT, i, base.len), body, end);

    positionAtEnd(cg, body);
    const element = load(cg, lower(cg, base.elem), elementAddress(cg, &base, i), "");
    store(cg, element, item);
    if (index != null) store(cg, i, index);
    loopBody(cg, node, data.body, end, step);

    positionAtEnd(cg, step);
    const current = load(cg, usize, counter, "");
    store(cg, llvm.LLVMBuildNUWAdd(cg.b, current, constUsize(cg, 1), ""), counter);
    branch(cg, cond);
    positionAtEnd(cg, end);
}

/**
 * Emits `for (const x, i of it)` over an iterator, calling its `next()` until it returns `null`.
 *
 * @param cg - The code generator
 * @param node - The `for` node
 * @param data - The parts of the loop
 *
 * @remarks
 * The receiver is the `dyn` value itself, the iterator's address, or a copy in a hidden local,
 * depending on how the checker resolved the `next` method.
 * Through a `dyn`, the method comes from the vtable slot, and the data pointer is its receiver.
 * The optional index counts the passes in a hidden `usize` counter.
 *
 * @since 1.0.0
 */

function emitForIterator(cg: *Cg, node: u32, data: readonly *HxForOfData): void {
    const info = infoOf(cg, node);
    const itemSym = info.symbol;
    const type = finalType(cg, data.iterable);
    const usize = lower(cg, cg.types.usize);
    const isDyn = (info.flags & HxInfoDyn) != 0;

    let receiver: Value = null;   // the iterator's address, or the `dyn` itself
    if ((info.flags & (HxInfoDyn | HxInfoDeref)) != 0) {
        receiver = emitValue(cg, data.iterable);
    } else if ((info.flags & HxInfoReceiverAddr) != 0) {
        receiver = emitAddress(cg, data.iterable);
    } else {
        receiver = entryAlloca(cg, lower(cg, type), "iterator");
        store(cg, emitValue(cg, data.iterable), receiver);
    }
    let signature: u32 = 0;
    let target: Value = null;
    let self: Value = null;
    if (isDyn) {
        signature = slotSignature(cg, typeOf(cg, type).child, info.aux);
        self = extract(cg, receiver, 0, "data");
        target = loadSlot(cg, receiver, info.aux);
    } else {
        signature = symbolOf(cg, info.aux).type;
        self = receiver;
        target = cg.storage[info.aux];
    }
    const optional = typeOf(cg, signature).child;
    const fnT = isDyn ? slotType(cg, signature) : lowerFunction(cg, signature);

    let counter: Value = null;
    if (data.indexToken != NoToken) {
        counter = entryAlloca(cg, usize, "i");
        store(cg, constUsize(cg, 0), counter);
    }
    const item = localStorage(cg, itemSym);
    const index = counter != null ? localStorage(cg, itemSym + 1) : null;

    const cond = block(cg, "iter.next");
    const body = block(cg, "iter.body");
    const step = block(cg, "iter.step");
    const end = block(cg, "iter.end");

    branch(cg, cond);
    positionAtEnd(cg, cond);
    const args: Value[1] = [self];
    const next = call(cg, fnT, target, &args, "next");
    const have = block(cg, "iter.item");
    condBr(cg, optionalPresent(cg, next, optional), have, end);
    positionAtEnd(cg, have);
    store(cg, optionalPayload(cg, next, optional), item);
    if (index != null) store(cg, load(cg, usize, counter, ""), index);
    branch(cg, body);

    positionAtEnd(cg, body);
    loopBody(cg, node, data.body, end, step);

    positionAtEnd(cg, step);
    if (counter != null) {
        const current = load(cg, usize, counter, "");
        store(cg, llvm.LLVMBuildNUWAdd(cg.b, current, constUsize(cg, 1), ""), counter);
    }
    branch(cg, cond);
    positionAtEnd(cg, end);
}

/**
 * Emits an `if` statement, with or without an `else` branch.
 *
 * @param cg - The code generator
 * @param node - The `if` node
 *
 * @remarks
 * A condition that the checker decided while compiling emits only the branch it takes, without a test.
 * The capturing form `if (const v = optional)` tests whether the optional holds a value,
 * and stores the payload in the capture at the start of the then branch.
 *
 * @since 1.0.0
 */

function emitIf(cg: *Cg, node: u32): void {
    const data = record<HxIfData>(cg.ast, nodeOf(cg, node).a);
    const known = data.captureToken == NoToken ? knownCondition(cg, data.condition) : -1;
    if (known >= 0) {   // decided while compiling: only the branch taken exists
        emitScoped(cg, known == 1 ? data.thenBranch : data.elseBranch);
        return;
    }
    let cond = emitValue(cg, data.condition);
    let payload: Value = null;
    if (data.captureToken != NoToken) {   // `if (const v = optional)`
        const type = finalType(cg, data.condition);
        payload = optionalPayload(cg, cond, type);
        cond = optionalPresent(cg, cond, type);
    }
    const thenBlock = block(cg, "if.then");
    const elseBlock = data.elseBranch != 0 ? block(cg, "if.else") : null;
    const end = block(cg, "if.end");
    condBr(cg, cond, thenBlock, elseBlock != null ? elseBlock : end);

    positionAtEnd(cg, thenBlock);
    if (payload != null && infoOf(cg, node).symbol != 0) store(cg, payload, localStorage(cg, infoOf(cg, node).symbol));
    emitScoped(cg, data.thenBranch);
    if (!terminated(cg)) branch(cg, end);

    if (elseBlock != null) {
        positionAtEnd(cg, elseBlock);
        emitScoped(cg, data.elseBranch);
        if (!terminated(cg)) branch(cg, end);
    }
    positionAtEnd(cg, end);
}

/**
 * Emits one statement, dispatching on its node kind.
 *
 * @param cg - The code generator
 * @param node - The statement node, where 0 does nothing
 *
 * @remarks
 * Nothing is emitted once the current block has left, such as after a `return`.
 * A block runs the defers that it pushed when it ends normally.
 * A `return` runs every pending defer before the `ret`,
 * and a bare `return` from a function that returns an error union returns the success code 0.
 * A `defer` or `errdefer` only goes on the defer stack here, and a `comptime` block already ran while compiling.
 * Any other node is an expression whose value goes unused.
 *
 * @example
 * ```hx
 * // while (i < n) i++;
 * emitStmt(cg, node); // while.cond, while.body, and while.end blocks
 * ```
 *
 * @see emitValue
 * @see emitScoped
 *
 * @since 1.0.0
 */

export function emitStmt(cg: *Cg, node: u32): void {
    if (node == 0 || terminated(cg)) return;
    const n = nodeOf(cg, node);
    if (n.kind != NodeKind.Block) setLocation(cg, node);

    switch (n.kind) {
        case NodeKind.Block: {
            const mark = cg.defers.len;
            for (const i of n.a..n.b) {
                if (terminated(cg)) break;
                emitStmt(cg, extra(cg, i));
            }
            if (!terminated(cg)) emitDefers(cg, mark, null);
            cg.defers.len = mark;
        }
        case NodeKind.UnsafeBlock: emitStmt(cg, n.a);
        case NodeKind.Const, NodeKind.Let: emitLocal(cg, node);
        case NodeKind.ExprStmt: {
            if (nodeOf(cg, n.a).kind == NodeKind.Switch) void emitSwitch(cg, n.a, false);
            else void emitValue(cg, n.a);
        }
        case NodeKind.Assign: emitAssign(cg, node);
        case NodeKind.Increment, NodeKind.Decrement: {
            const address = emitAddress(cg, n.a);
            const type = infoOf(cg, n.a).type;
            const old = load(cg, lower(cg, type), address, "");
            const one = llvm.LLVMConstInt(lower(cg, type), 1, 0);
            const op = n.kind == NodeKind.Increment ? BinOp.Add : BinOp.Sub;
            store(cg, emitArith(cg, op, old, one, type, node), address);
        }
        case NodeKind.Return: {
            const v = n.a != 0 ? emitValue(cg, n.a) : null;
            if (terminated(cg)) return;
            emitDefers(cg, 0, null);
            if (terminated(cg)) return;
            if (v != null) void llvm.LLVMBuildRet(cg.b, v);
            else if (typeOf(cg, cg.returnType).kind == TypeKind.ErrorUnion) void llvm.LLVMBuildRet(cg.b, constErrorCode(cg, 0));
            else void llvm.LLVMBuildRetVoid(cg.b);
        }
        case NodeKind.Break: emitJump(cg, node, true);
        case NodeKind.Continue: emitJump(cg, node, false);
        case NodeKind.If: emitIf(cg, node);
        case NodeKind.While: emitWhile(cg, node);
        case NodeKind.For: emitFor(cg, node);
        case NodeKind.ForOf: {
            const data = record<HxForOfData>(cg.ast, n.a);
            if (nodeOf(cg, data.iterable).kind == NodeKind.Range) emitForRange(cg, node, &data);
            else if ((infoOf(cg, node).flags & HxInfoIterator) != 0) emitForIterator(cg, node, &data);
            else emitForItems(cg, node, &data);
        }
        case NodeKind.Defer, NodeKind.Errdefer: push(&cg.defers, node);
        case NodeKind.ComptimeBlock: {}   // already ran, while compiling
        case NodeKind.Switch: void emitSwitch(cg, node, false);
        case NodeKind.Throw: emitErrorReturn(cg, emitValue(cg, n.a));
        default: void emitValue(cg, node);
    }
}
