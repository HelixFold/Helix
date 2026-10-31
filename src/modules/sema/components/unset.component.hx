/**
 * Imports
 */

import { NodeKind } from "@constants/ast.constant";
import { Ctx, HxU32Vec } from "@structs/sema.struct";
import { hxAlloc } from "@components/memory.component";
import { pushU32, u32At } from "@modules/sema/components/scope.component";
import { HxInfoField, HxInfoDeref, HxSymLocal } from "@constants/sema.constant";
import { Unset } from "@modules/sema/components/structs/unset-component.struct";
import { nodeOf, infoOf, symbolOf, tokenText, errorNode, hint } from "@modules/sema/components/base.component";

/**
 * Finds a value in a vector.
 *
 * @param vec - The vector to search
 * @param v - The value to find
 * @returns The index of the first match, or `null` when the value is not there
 *
 * @remarks
 * The search is linear, which suits the short lists of locals that a function leaves without a value.
 *
 * @since 1.0.0
 */

function has(vec: readonly *HxU32Vec, v: u32): ?u32 {
    for (const i of 0..vec.len) {
        if (u32At(vec, i) == v) return i;
    }
    return null;
}

/**
 * Removes an entry from a vector by moving the last entry into its place.
 *
 * @param vec - The vector to shrink
 * @param i - The index of the entry to remove
 *
 * @remarks
 * The order of the remaining entries is not kept, which the sets in this file do not need.
 *
 * @since 1.0.0
 */

function drop(vec: *HxU32Vec, i: u32): void {
    unsafe {
        vec.items![i] = vec.items![vec.len - 1];
    }
    vec.len -= 1;
}

/**
 * Records that a local starts without a value, as `let x: T = undefined;` declares it.
 *
 * @param c - The checker context
 * @param sym - The symbol of the local, where 0 does nothing
 *
 * @remarks
 * Reading the local before every path assigns it is then an error.
 * Only whole values are followed, such as numbers, pointers, slices, optionals, and enums.
 * Arrays, structs, and unions are filled piece by piece, which this tracking cannot tell from a full write.
 *
 * @example
 * ```hx
 * // let x: i32 = undefined;
 * declareUnset(c, sym); // x has no value yet
 * ```
 *
 * @see flushReads
 * @since 1.0.0
 */

export function declareUnset(c: *Ctx, sym: u32): void {
    if (sym != 0) pushU32(&c.unset, sym);
}

/**
 * Records a read of a local that may not have a value yet.
 *
 * @param c - The checker context
 * @param node - The identifier node that reads the local
 * @param sym - The symbol of the local
 *
 * @remarks
 * The read is only recorded here and reported when the statement ends,
 * since the target of `x = ...` is checked like a read before the checker knows that it is a target.
 * {@link noteWrite} then cancels it.
 *
 * @example
 * ```hx
 * // y = x + 1;   x was declared = undefined
 * noteRead(c, node, sym); // reported by flushReads at the end of the statement
 * ```
 *
 * @see flushReads
 * @since 1.0.0
 */

export function noteRead(c: *Ctx, node: u32, sym: u32): void {
    if (c.unset.len == 0 || has(&c.unset, sym) == null) return;
    pushU32(&c.unsetReads, node);
}

/**
 * Finds the local that a place is part of.
 *
 * @param c - The checker context
 * @param node - The place, such as `x`, `x.f`, `x[i]` of an array, or `x.f[i].g`
 * @returns The identifier node of the local, or 0 when the place does not belong to one
 *
 * @remarks
 * A field reached through a pointer belongs to the pointee, not to the local, so it gives 0.
 *
 * @since 1.0.0
 */

function rootIdent(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    switch (n.kind) {
        case NodeKind.Ident: return node;
        case NodeKind.Index: return rootIdent(c, n.a);
        case NodeKind.FieldAccess: {
            const flags = infoOf(c, node).flags;
            if ((flags & HxInfoField) != 0 && (flags & HxInfoDeref) == 0) return rootIdent(c, n.a);
            return 0;
        }
        default: return 0;
    }
}

/**
 * Records that a place is written or has its address taken.
 *
 * @param c - The checker context
 * @param place - The place being written
 *
 * @remarks
 * This use of the place is not a read, and its local has a value once the statement is done.
 * The value only counts from the end of the statement, so `x = x + 1` still reads an `x` without one.
 * Assigning a field or an element, taking `&x`, and calling a method that takes `*this` all count as writes.
 *
 * @example
 * ```hx
 * // x = 1;   x was declared = undefined
 * noteWrite(c, target); // x has a value after this statement
 * ```
 *
 * @see noteRead
 * @since 1.0.0
 */

export function noteWrite(c: *Ctx, place: u32): void {
    if (c.unset.len == 0) return;
    const root = rootIdent(c, place);
    if (root == 0) return;
    if (const i = has(&c.unsetReads, root)) drop(&c.unsetReads, i);
    pushU32(&c.unsetWrites, infoOf(c, root).symbol);
}

/**
 * Cancels a recorded read of a node that turned out not to read the value.
 *
 * @param c - The checker context
 * @param node - The identifier node whose read to cancel
 *
 * @remarks
 * The length of an array is known while compiling, so `x.len` does not read `x`.
 *
 * @example
 * ```hx
 * // const n = buffer.len;   buffer was declared = undefined
 * noteNotRead(c, node); // no error for buffer
 * ```
 *
 * @since 1.0.0
 */

export function noteNotRead(c: *Ctx, node: u32): void {
    if (c.unsetReads.len == 0) return;
    if (const i = has(&c.unsetReads, node)) drop(&c.unsetReads, i);
}

/**
 * Reports the reads of locals without a value at the end of a statement, then applies its writes.
 *
 * @param c - The checker context
 *
 * @remarks
 * Each local is reported once, at its first read without a value, and is then treated as set
 * so that one mistake does not produce an error at every later read.
 *
 * @example
 * ```hx
 * // let x: i32 = undefined;
 * // print(x);
 * flushReads(c); // error: `x` is read before it's given a value
 * ```
 *
 * @see noteRead
 * @see noteWrite
 *
 * @since 1.0.0
 */

export function flushReads(c: *Ctx): void {
    let i: u32 = 0;
    while (i < c.unsetReads.len) {
        const node = u32At(&c.unsetReads, i);
        i += 1;
        const sym = infoOf(c, node).symbol;
        const at = has(&c.unset, sym);
        if (at == null) continue;   // reported already in this statement
        const name = tokenText(c, nodeOf(c, node).token);
        const diag = errorNode(c, node, `\`${name}\` is read before it's given a value`);
        hint(c, diag, "it was declared `= undefined`; assign it on every path before reading it");
        drop(&c.unset, at);   // once is enough
    }
    c.unsetReads.len = 0;
    for (const j of 0..c.unsetWrites.len) {
        if (const at = has(&c.unset, u32At(&c.unsetWrites, j))) drop(&c.unset, at);
    }
    c.unsetWrites.len = 0;
}

/**
 * Takes a snapshot of the locals that have no value yet.
 *
 * @param c - The checker context
 * @returns The snapshot, which later changes to the context leave alone
 *
 * @remarks
 * The snapshot is a heap copy with one spare slot, so an empty set still gets a valid allocation.
 * Take one before each branch, and merge the snapshots after the branches with `mergeUnset`.
 *
 * @example
 * ```hx
 * const before = saveUnset(c); // before a branch
 * ```
 *
 * @see restoreUnset
 * @since 1.0.0
 */

export function saveUnset(c: *Ctx): Unset {
    unsafe {
        const items = @ptrCast(u32[*], hxAlloc((c.unset.len as usize + 1) * 4));
        for (const i of 0..c.unset.len) items[i] = u32At(&c.unset, i);
        return Unset { items, len: c.unset.len };
    }
}

/**
 * Goes back to a snapshot of the locals without a value.
 *
 * @param c - The checker context
 * @param s - The snapshot to go back to
 *
 * @remarks
 * The else branch of an `if` starts from the same state as its then branch, so the checker restores it in between.
 *
 * @example
 * ```hx
 * restoreUnset(c, before); // the else branch starts where the then branch did
 * ```
 *
 * @see saveUnset
 * @since 1.0.0
 */

export function restoreUnset(c: *Ctx, s: Unset): void {
    c.unset.len = 0;
    unsafe {
        for (const i of 0..s.len) pushU32(&c.unset, s.items[i]);
    }
}

/**
 * Merges the snapshots of two branches that started from the same point.
 *
 * @param c - The checker context
 * @param before - The snapshot from before the branches
 * @param a - The snapshot at the end of the first branch
 * @param b - The snapshot at the end of the second branch
 *
 * @remarks
 * A local is still without a value when either branch left it so.
 * The caller leaves out a branch that never goes on, such as one that returns, throws, or breaks,
 * so that `if (!ok) return; x = 1;` style code does not count against the local.
 *
 * @example
 * ```hx
 * // if (ok) x = 1;   the missing else branch leaves x without a value
 * mergeUnset(c, before, afterThen, before); // x stays without a value
 * ```
 *
 * @since 1.0.0
 */

export function mergeUnset(c: *Ctx, before: Unset, a: Unset, b: Unset): void {
    c.unset.len = 0;
    unsafe {
        for (const i of 0..before.len) {
            const sym = before.items[i];
            let left = false;
            for (const j of 0..a.len) left = left || a.items[j] == sym;
            for (const j of 0..b.len) left = left || b.items[j] == sym;
            if (left) pushU32(&c.unset, sym);
        }
    }
}

/**
 * Checks whether a local still has no value.
 *
 * @param c - The checker context
 * @param sym - The symbol to check
 * @returns `true` for a local that no path has given a value yet
 *
 * @remarks
 * Only locals count, so a global is never reported as unset, even when the set holds its symbol.
 *
 * @example
 * ```hx
 * // let x: i32 = undefined;
 * isUnset(c, sym); // true until x is assigned
 * ```
 *
 * @since 1.0.0
 */

export function isUnset(c: *Ctx, sym: u32): bool {
    return has(&c.unset, sym) != null && symbolOf(c, sym).kind == HxSymLocal as u8;
}
