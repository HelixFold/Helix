/**
 * Imports
 */

import { hxTypeName } from "@models/types.model";
import { HxInfoField } from "@constants/sema.constant";
import { record, hxNodeKindName } from "@models/ast.model";
import { HxType } from "@models/structs/types-model.struct";
import { hxVecGrowImpl } from "@components/memory.component";
import { HxArena } from "@services/structs/arena-service.struct";
import { emitf, hint as diagHint } from "@models/diagnostic.model";
import { DiagError, DiagNote } from "@constants/diagnostic.constant";
import { TypeKind, Signed, Readonly } from "@constants/types.constant";
import { hxArenaAlloc, hxArenaStrndup, hxArenaFree } from "@services/arena.service";
import { emptyValue, infoAt, hxNodeSpan } from "@modules/sema/components/base.component";
import { NodeKind, BinOp, FlagInclusive, FlagPointer, NoToken } from "@constants/ast.constant";
import { addOverflows, subOverflows, mulOverflows } from "@modules/sema/components/scope.component";
import { HxValue, HxAggregate, HxEvalHost, HxNodeInfo, HxSymbol, HxMember } from "@structs/sema.struct";
import { HxInfoIterator, HxValueFunction, HxInfoFormatWrite, HxValueFloat } from "@constants/sema.constant";
import { HxFnData, HxRange, HxSliceData, HxTernaryData, HxCatchData } from "@models/structs/ast-model.struct";
import { HxSymGlobal, HxMemberField, HxInfoPrint, HxValueError, HxValueNull } from "@constants/sema.constant";
import { ComptimeValue, Local, Evaluation, Sequence } from "@modules/sema/services/structs/eval-service.struct";
import { HxValueUndefined, HxInfoReceiverAddr, HxValueAggregate, HxValueString } from "@constants/sema.constant";
import { HxCaseData, HxIfData, HxWhileData, HxForData, HxForOfData, HxNode } from "@models/structs/ast-model.struct";
import { HxInfoMethod, HxSymMutable, HxInfoUnionInit, HxInfoModuleRef, HxInfoDeref } from "@constants/sema.constant";
import { HxSymArrow, HxValueInt, HxValueBool, HxInfoIndirect, HxInfoDyn, HxSymExtern } from "@constants/sema.constant";
import { I128Max, MaxSteps, MaxDepth, EvalVoid, ComptimeValueKind, Flow } from "@modules/sema/constants/eval.constant";

/**
 * The C library functions that the interpreter uses to release its lists and to compute a float remainder.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;
extern "C" function fmod(x: f64, y: f64): f64;

/**
 * Reads a node of the tree.
 *
 * @param ev - The evaluation
 * @param id - The node index
 * @returns A copy of the node
 *
 * @remarks
 * The copy is cheap to take, and later changes to the tree never reach it.
 * The index is not checked against the node count.
 *
 * @since 1.0.0
 */

function nodeOf(ev: *Evaluation, id: u32): HxNode {
    unsafe {
        return ev.sema.ast!.nodes![id];
    }
}

/**
 * Reads the checker's information about a node in the current generic instance.
 *
 * @param ev - The evaluation
 * @param id - The node index
 * @returns A copy of the node's information, with its types, symbol, flags, and constant value
 *
 * @remarks
 * It reads through `infoAt`, so a node inside the declaration of the current instance reads that instance's own types.
 * Every other node reads the shared table.
 *
 * @since 1.0.0
 */

function infoOf(ev: *Evaluation, id: u32): HxNodeInfo {
    return *infoAt(ev.sema, ev.instance, id);
}

/**
 * Reads a type.
 *
 * @param ev - The evaluation
 * @param id - The type index
 * @returns A copy of the type
 *
 * @remarks
 * The index is not checked, so 0, the invalid type, reads the first entry of the table.
 *
 * @since 1.0.0
 */

function typeOf(ev: *Evaluation, id: u32): HxType {
    unsafe {
        return ev.sema.types.items![id];
    }
}

/**
 * Reads a symbol.
 *
 * @param ev - The evaluation
 * @param id - The symbol index
 * @returns A copy of the symbol
 *
 * @remarks
 * The index is not checked, so the caller passes a symbol that the checker created.
 *
 * @since 1.0.0
 */

function symbolOf(ev: *Evaluation, id: u32): HxSymbol {
    unsafe {
        return @ptrCast(HxSymbol[*], ev.sema.symbols.items)[id];
    }
}

/**
 * Reads an entry of the tree's extra list, which holds child lists and records.
 *
 * @param ev - The evaluation
 * @param index - The index into the extra list
 * @returns The entry
 *
 * @remarks
 * The index is not checked, so the caller passes one that a node or a record gave it.
 *
 * @since 1.0.0
 */

function extraOf(ev: *Evaluation, index: u32): u32 {
    unsafe {
        return ev.sema.ast!.extra![index];
    }
}

/**
 * Reads a constant value that the checker stored.
 *
 * @param ev - The evaluation
 * @param index - The value index
 * @returns A copy of the value
 *
 * @remarks
 * The copy shares the bytes and the element range of the stored value, so it is cheap,
 * and {@link fromValue} turns it into an interpreter value.
 *
 * @since 1.0.0
 */

function valueAt(ev: *Evaluation, index: u32): HxValue {
    unsafe {
        return @ptrCast(HxValue[*], ev.sema.values.items)[index];
    }
}

/**
 * Reads an entry of the list that holds the elements of aggregate values.
 *
 * @param ev - The evaluation
 * @param index - The index into the element list
 * @returns The value index of the element
 *
 * @remarks
 * An aggregate value keeps its elements as a range of this list, starting at its `elems` field.
 *
 * @since 1.0.0
 */

function valueElementAt(ev: *Evaluation, index: u32): u32 {
    unsafe {
        return ev.sema.valueElems.items![index];
    }
}

/**
 * Reads the aggregate record of a struct or union type.
 *
 * @param ev - The evaluation
 * @param type - The struct or union type
 * @returns A copy of the aggregate, with the range of its members
 *
 * @remarks
 * The `len` field of a struct or union type holds the aggregate index plus 1,
 * so the type must be one of those kinds, since nothing checks it.
 *
 * @since 1.0.0
 */

function aggregateOf(ev: *Evaluation, type: u32): HxAggregate {
    unsafe {
        return @ptrCast(HxAggregate[*], ev.sema.aggregates.items)[(typeOf(ev, type).len as usize) - 1];
    }
}

/**
 * Reads one member of an aggregate.
 *
 * @param ev - The evaluation
 * @param agg - The aggregate
 * @param i - The position of the member within the aggregate
 * @returns A copy of the member
 *
 * @remarks
 * The position is relative to the aggregate, and the function adds the start of its member range.
 *
 * @since 1.0.0
 */

function memberAt(ev: *Evaluation, agg: HxAggregate, i: u32): HxMember {
    unsafe {
        return @ptrCast(HxMember[*], ev.sema.members.items)[agg.membersStart + i];
    }
}

/**
 * Reads the source text of a token.
 *
 * @param ev - The evaluation
 * @param token - The token index
 * @returns The text, pointing into the source
 *
 * @remarks
 * The slice points into the source text without a copy, so it lives as long as the source does.
 *
 * @since 1.0.0
 */

function tokenText(ev: *Evaluation, token: u32): string {
    const a = ev.sema.ast!;
    unsafe {
        const start = a.tokens.starts![token];
        return a.src.text![start..start + a.tokens.lens![token]];
    }
}

/**
 * Finds the type that a node has after the checker converted it.
 *
 * @param ev - The evaluation
 * @param node - The node
 * @returns The type it converts to, or its own type when it is not converted
 *
 * @remarks
 * Use it where the value must have the type the program sees, such as when a literal flows into a wider integer.
 *
 * @since 1.0.0
 */

function finalType(ev: *Evaluation, node: u32): u32 {
    const info = infoOf(ev, node);
    return info.coerce != 0 ? info.coerce : info.type;
}

/**
 * Writes the name of a type for an error message.
 *
 * @param ev - The evaluation
 * @param type - The type to name
 * @returns The name, at most 127 bytes, in the checker's arena
 *
 * @remarks
 * Each call takes a fresh 128 bytes from the checker's arena,
 * so a message can hold several names, and the checker frees them with its arena.
 *
 * @since 1.0.0
 */

function typeName(ev: *Evaluation, type: u32): string {
    const buf = hxArenaAlloc(&ev.sema.arena, 128, 1);
    hxTypeName(&ev.sema.types, type, buf, 128);
    unsafe {
        let n: usize = 0;
        while (buf[n] != 0) n += 1;
        return buf[0..n];
    }
}

/**
 * Makes an empty value of a kind.
 *
 * @param kind - The kind of value
 * @returns The value, with every other field zero or null
 *
 * @remarks
 * Every other constructor starts from it, so a field that a kind does not use is always zero.
 *
 * @since 1.0.0
 */

function newValue(kind: ComptimeValueKind): ComptimeValue {
    return ComptimeValue { kind, b: false, i: 0, f: 0, bytes: null, len: 0, start: 0, count: 0, elems: null, target: null };
}

/**
 * Makes an integer value.
 *
 * @param i - The integer
 * @returns A value of kind `Int`
 *
 * @remarks
 * The value holds an `i128`, wide enough for any integer type, and the caller checks the range against the type.
 *
 * @since 1.0.0
 */

function cvInt(i: i128): ComptimeValue {
    let v = newValue(ComptimeValueKind.Int);
    v.i = i;
    return v;
}

/**
 * Makes a boolean value.
 *
 * @param b - The boolean
 * @returns A value of kind `Bool`
 *
 * @remarks
 * The boolean goes in the `b` field, and every other field stays zero.
 *
 * @since 1.0.0
 */

function cvBool(b: bool): ComptimeValue {
    let v = newValue(ComptimeValueKind.Bool);
    v.b = b;
    return v;
}

/**
 * Makes a floating-point value.
 *
 * @param f - The number
 * @returns A value of kind `Float`
 *
 * @remarks
 * The interpreter holds every float as `f64`, whatever its type in the program.
 *
 * @since 1.0.0
 */

function cvFloat(f: f64): ComptimeValue {
    let v = newValue(ComptimeValueKind.Float);
    v.f = f;
    return v;
}

/**
 * Allocates the elements of an aggregate in the evaluation's arena.
 *
 * @param ev - The evaluation
 * @param count - The number of elements
 * @returns Room for the elements, plus one so that an empty aggregate still gets a pointer
 *
 * @remarks
 * The arena owns the room, so it lives until the evaluation is disposed, and nothing frees it on its own.
 * The elements are not set, so the caller fills each one.
 *
 * @since 1.0.0
 */

function elemsOf(ev: *Evaluation, count: u32): ComptimeValue[*] {
    unsafe {
        return @ptrCast(ComptimeValue[*], hxArenaAlloc(&ev.arena, ((count as usize) + 1) * @sizeOf(ComptimeValue), @alignOf(ComptimeValue)));
    }
}

/**
 * Allocates storage for one value in the evaluation's arena.
 *
 * @param ev - The evaluation
 * @returns The storage, not yet set
 *
 * @remarks
 * Locals, temporaries, and the targets of pointers live in these slots,
 * so a pointer stays valid until the evaluation ends.
 *
 * @since 1.0.0
 */

function slotOf(ev: *Evaluation): *ComptimeValue {
    unsafe {
        return @ptrCast(*ComptimeValue, hxArenaAlloc(&ev.arena, @sizeOf(ComptimeValue), @alignOf(ComptimeValue)));
    }
}

/**
 * Reads one element of an aggregate.
 *
 * @param v - The aggregate
 * @param i - The element index
 * @returns A shallow copy of the element
 *
 * @remarks
 * A nested aggregate shares its elements with the original,
 * so the caller makes a deep copy before it stores the element anywhere.
 *
 * @since 1.0.0
 */

function elementOf(v: ComptimeValue, i: u32): ComptimeValue {
    unsafe {
        return v.elems![i];
    }
}

/**
 * Finds the storage of one element of an aggregate, so that it can be assigned.
 *
 * @param v - The aggregate
 * @param i - The element index
 * @returns The element's storage
 *
 * @remarks
 * The aggregate is passed by value, but its elements are shared,
 * so writing through the result changes every copy that shares those elements.
 *
 * @since 1.0.0
 */

function elemSlot(v: ComptimeValue, i: u32): *ComptimeValue {
    unsafe {
        return &v.elems![i];
    }
}

/**
 * Reports an error at a node and stops the evaluation.
 *
 * @param ev - The evaluation
 * @param node - The node that caused the error
 * @param message - The error message
 *
 * @remarks
 * When the node is not the `comptime` that started the evaluation,
 * a note at that `comptime` says `while evaluating this at compile time`.
 * The flow becomes `Abort`, and a later failure in the same evaluation reports nothing.
 *
 * @since 1.0.0
 */

function fail(ev: *Evaluation, node: u32, message: Format): void {
    if (ev.flow == Flow.Abort) return;
    let start: u32 = 0;
    let len: u32 = 0;
    hxNodeSpan(ev.sema.ast!, node, &start, &len);
    void emitf(ev.sema.diags!, DiagError, ev.sema.src, start, len, message);
    if (node != ev.root) {
        hxNodeSpan(ev.sema.ast!, ev.root, &start, &len);
        void emitf(ev.sema.diags!, DiagNote, ev.sema.src, start, len, "while evaluating this at compile time");
    }
    ev.flow = Flow.Abort;
}

/**
 * Reports code that the interpreter can't run yet.
 *
 * @param ev - The evaluation
 * @param node - The node it can't run
 * @param what - The name of the feature, which opens the message
 *
 * @remarks
 * Use it for code that the language allows but the interpreter does not run yet,
 * so the error reads as a missing feature rather than a mistake in the program.
 *
 * @since 1.0.0
 */

function unsupported(ev: *Evaluation, node: u32, what: string): void {
    fail(ev, node, `${what} can't run at compile time yet`);
}

/**
 * Counts one step of the evaluation against {@link MaxSteps}.
 *
 * @param ev - The evaluation
 * @param node - The call or loop that takes the step
 * @returns `true` while the evaluation is within the limit
 *
 * @remarks
 * Past the limit it reports an error with a hint that asks whether a loop is endless.
 *
 * @since 1.0.0
 */

function step(ev: *Evaluation, node: u32): bool {
    ev.steps += 1;
    if (ev.steps <= MaxSteps) return true;
    fail(ev, node, `compile-time evaluation took more than ${MaxSteps} steps (loop iterations and calls)`);
    const diags = ev.sema.diags!;
    if (diags.itemsLen >= 2) {   // the error, then its note
        diagHint(diags, diags.itemsLen - (ev.root != node ? 2 : 1), "is a loop endless? Compile-time work this big is better done at runtime");
    }
    return false;
}

/**
 * Makes a deep copy of a value.
 *
 * @param ev - The evaluation
 * @param v - The value to copy
 * @returns The copy, which shares no aggregate storage with the original
 *
 * @remarks
 * Reading a value is a shallow copy, and storing one in a declaration, an assignment,
 * or a parameter is a deep copy.
 * That keeps Helix's value semantics without reference counting.
 *
 * @since 1.0.0
 */

function copy(ev: *Evaluation, v: ComptimeValue): ComptimeValue {
    if (v.kind != ComptimeValueKind.Agg || v.count == 0) return v;
    const elems = elemsOf(ev, v.count);
    unsafe {
        for (const i of 0..v.count) elems[i] = copy(ev, elementOf(v, i));
    }
    let out = v;
    out.elems = elems;
    return out;
}

/**
 * Makes an undefined value shaped like a type.
 *
 * @param ev - The evaluation
 * @param type - The type of the value
 * @returns An aggregate of undefined elements for an array or struct, and an `Undef` value otherwise
 *
 * @remarks
 * The elements of an array or struct can then be set one by one.
 *
 * @since 1.0.0
 */

function undefinedOf(ev: *Evaluation, type: u32): ComptimeValue {
    const t = typeOf(ev, type);
    if (t.kind == TypeKind.Array) {
        let v = newValue(ComptimeValueKind.Agg);
        v.count = @truncate(u32, t.len);
        const elems = elemsOf(ev, v.count);
        unsafe {
            for (const i of 0..v.count) elems[i] = undefinedOf(ev, t.child);
        }
        v.elems = elems;
        return v;
    }
    if (t.kind == TypeKind.Struct) {
        const agg = aggregateOf(ev, type);
        let v = newValue(ComptimeValueKind.Agg);
        v.count = agg.fieldCount;
        const elems = elemsOf(ev, v.count);
        for (const i of 0..agg.membersCount) {
            const m = memberAt(ev, agg, i);
            unsafe {
                if (m.kind == HxMemberField as u8) elems[m.index] = undefinedOf(ev, m.type);
            }
        }
        v.elems = elems;
        return v;
    }
    return newValue(ComptimeValueKind.Undef);
}

/**
 * Finds the smallest value of an integer type.
 *
 * @param ev - The evaluation
 * @param type - The integer type
 * @returns 0 for an unsigned type, and the most negative value for a signed one
 *
 * @remarks
 * A type of 128 bits or more gives the smallest `i128`, the widest value the interpreter holds.
 *
 * @since 1.0.0
 */

function intMin(ev: *Evaluation, type: u32): i128 {
    const t = typeOf(ev, type);
    if ((t.flags & Signed) == 0) return 0;
    return t.bits >= 128 ? -I128Max - 1 : -((1 as i128) << (t.bits - 1));
}

/**
 * Finds the largest value of an integer type.
 *
 * @param ev - The evaluation
 * @param type - The integer type
 * @returns The largest value, capped at {@link I128Max}
 *
 * @remarks
 * An unsigned type of 128 bits also gives {@link I128Max}, since the interpreter holds integers as `i128`.
 *
 * @since 1.0.0
 */

function intMax(ev: *Evaluation, type: u32): i128 {
    const t = typeOf(ev, type);
    const bits: u16 = (t.flags & Signed) != 0 ? t.bits - 1 : t.bits;
    return bits >= 127 ? I128Max : ((1 as i128) << bits) - 1;
}

/**
 * Checks whether an integer fits in a type.
 *
 * @param ev - The evaluation
 * @param type - The type
 * @param v - The integer
 * @returns `true` when it fits, and always `true` for a type that is not a concrete integer
 *
 * @remarks
 * Only a concrete integer type has a range, so a literal type accepts any value that an `i128` holds.
 *
 * @since 1.0.0
 */

function intFits(ev: *Evaluation, type: u32, v: i128): bool {
    if (typeOf(ev, type).kind != TypeKind.Int) return true;
    return v >= intMin(ev, type) && v <= intMax(ev, type);
}

/**
 * Wraps an integer around to the width of its type.
 *
 * @param ev - The evaluation
 * @param type - The type
 * @param v - The integer
 * @returns The low bits of the integer, sign-extended for a signed type
 *
 * @remarks
 * A type that is not a concrete integer, or one 128 bits wide, leaves the integer as it is.
 *
 * @since 1.0.0
 */

function wrapToType(ev: *Evaluation, type: u32, v: i128): i128 {
    const t = typeOf(ev, type);
    if (t.kind != TypeKind.Int || t.bits >= 128) return v;
    const mask: u128 = ((1 as u128) << t.bits) -% 1;
    const u = @truncate(u128, v) & mask;
    if ((t.flags & Signed) != 0 && ((u >> (t.bits - 1)) & 1) != 0) return @truncate(i128, u | ~mask);
    return @truncate(i128, u);
}

/**
 * Writes an integer in decimal for an error message.
 *
 * @param v - The integer
 * @param buf - The buffer to write into
 * @returns The digits, with a leading `-` for a negative integer, pointing into the buffer
 *
 * @remarks
 * It turns a negative number into its magnitude through `-(v + 1) + 1`, so the smallest `i128` does not overflow.
 * The digits never exceed the buffer, since an `i128` has at most 39 of them.
 *
 * @since 1.0.0
 */

function intText(v: i128, buf: *u8[48]): string {
    let digits: u8[48] = undefined;
    let n: usize = 0;
    let u: u128 = v < 0 ? ((-(v + 1)) as u128) + 1 : v as u128;
    while (true) {
        digits[n] = '0' + @truncate(u8, u % 10);
        n += 1;
        u /= 10;
        if (u == 0 || n >= 48) break;
    }
    let used: usize = 0;
    if (v < 0) {
        buf[used] = '-';
        used += 1;
    }
    while (n > 0 && used + 1 < 48) {
        n -= 1;
        buf[used] = digits[n];
        used += 1;
    }
    return buf[0..used];
}

/**
 * Checks that a value has the kind that an operation needs.
 *
 * @param ev - The evaluation
 * @param v - The value
 * @param kind - The kind the operation needs
 * @param node - The node to report at
 * @returns `true` when the value has the kind
 *
 * @remarks
 * An undefined value reports `this reads an undefined value at compile time`,
 * and any other kind reports `this value can't be used at compile time here`.
 *
 * @since 1.0.0
 */

function expectKind(ev: *Evaluation, v: ComptimeValue, kind: ComptimeValueKind, node: u32): bool {
    if (v.kind == kind) return true;
    if (v.kind == ComptimeValueKind.Undef) fail(ev, node, "this reads an undefined value at compile time");
    else fail(ev, node, "this value can't be used at compile time here");
    return false;
}

/**
 * Applies a binary operator to two integers of a type, with the checks that safe builds make at runtime.
 *
 * @param ev - The evaluation
 * @param node - The node to report at
 * @param op - The operator
 * @param a - The left operand
 * @param b - The right operand
 * @param type - The type of the operands
 * @returns The result, or an `Undef` value after reporting an error
 *
 * @remarks
 * - **Wrapping operators** `+%`, `-%`, and `*%` wrap to the type.
 * - **Saturating operators** clamp to the bounds of a concrete integer type.
 * - **Other arithmetic** reports an overflow when the result doesn't fit, and a division by zero.
 * - **Shifts** report an amount below zero or at least the width of the type, and `<<` drops the bits shifted out.
 *
 * @since 1.0.0
 */

function intOp(ev: *Evaluation, node: u32, op: BinOp, a: i128, b: i128, type: u32): ComptimeValue {
    const concrete = typeOf(ev, type).kind == TypeKind.Int;
    let r: i128 = 0;
    let overflow = false;
    switch (op) {
        case BinOp.AddWrap: return cvInt(wrapToType(ev, type, a +% b));
        case BinOp.SubWrap: return cvInt(wrapToType(ev, type, a -% b));
        case BinOp.MulWrap: return cvInt(wrapToType(ev, type, a *% b));
        case BinOp.Add, BinOp.AddSat: overflow = addOverflows(a, b, &r);
        case BinOp.Sub, BinOp.SubSat: overflow = subOverflows(a, b, &r);
        case BinOp.Mul, BinOp.MulSat: overflow = mulOverflows(a, b, &r);
        case BinOp.Div, BinOp.Mod: {
            if (b == 0) {
                fail(ev, node, "division by zero at compile time");
                return newValue(ComptimeValueKind.Undef);
            }
            if (b == -1 && concrete && a == intMin(ev, type)) overflow = true;
            else if (b == -1 && a == -I128Max - 1) overflow = true;   // i128's minimum has no positive opposite
            else r = op == BinOp.Div ? a / b : a % b;
        }
        case BinOp.BitAnd: return cvInt(a & b);
        case BinOp.BitOr: return cvInt(a | b);
        case BinOp.BitXor: return cvInt(wrapToType(ev, type, a ^ b));
        case BinOp.Shl, BinOp.Shr: {
            const limit: i128 = concrete ? typeOf(ev, type).bits as i128 : 127;
            if (b < 0 || b >= limit) {
                let buf: u8[48] = undefined;
                fail(ev, node, `shift amount ${intText(b, &buf)} is too large for \`${typeName(ev, type)}\``);
                return newValue(ComptimeValueKind.Undef);
            }
            const amount = @truncate(u8, b);
            if (op == BinOp.Shr) return cvInt(a >> amount);
            return cvInt(wrapToType(ev, type, @truncate(i128, @truncate(u128, a) << amount)));   // `<<` drops the bits shifted out
        }
        default: {
            unsupported(ev, node, "this operator");
            return newValue(ComptimeValueKind.Undef);
        }
    }
    if (concrete && (op == BinOp.AddSat || op == BinOp.SubSat || op == BinOp.MulSat)) {
        if (overflow) {
            const negative = op == BinOp.MulSat ? (a < 0) != (b < 0) : op == BinOp.SubSat ? b > 0 : b < 0;
            return cvInt(negative ? intMin(ev, type) : intMax(ev, type));
        }
        return cvInt(r < intMin(ev, type) ? intMin(ev, type) : r > intMax(ev, type) ? intMax(ev, type) : r);
    }
    if (overflow || !intFits(ev, type, r)) {
        fail(ev, node, `integer overflow at compile time: the result doesn't fit in \`${typeName(ev, type)}\``);
        return newValue(ComptimeValueKind.Undef);
    }
    return cvInt(r);
}

/**
 * Turns a constant value that the checker stored into an interpreter value.
 *
 * @param ev - The evaluation
 * @param index - The value index
 * @returns The interpreter value, with aggregates converted element by element
 *
 * @remarks
 * A kind that the interpreter does not know becomes an undefined value instead of an error.
 * Strings keep pointing at the stored bytes, and each aggregate gets its elements from the evaluation's arena.
 *
 * @since 1.0.0
 */

function fromValue(ev: *Evaluation, index: u32): ComptimeValue {
    const v = valueAt(ev, index);
    switch (v.kind as u32) {
        case 1: return cvInt(v.integer);
        case 2: return cvFloat(v.floating);
        case 3: return cvBool(v.boolean);
        case 6: return newValue(ComptimeValueKind.Null);
        case 5: return newValue(ComptimeValueKind.Undef);
        case 4: {
            let s = newValue(ComptimeValueKind.Bytes);
            s.bytes = v.bytes;
            s.len = v.len;
            return s;
        }
        case 7: {
            let e = newValue(ComptimeValueKind.Error);
            e.i = v.integer;
            return e;
        }
        case 8: {
            let f = newValue(ComptimeValueKind.Func);
            f.i = v.integer;
            return f;
        }
        case 9: {
            let a = newValue(ComptimeValueKind.Agg);
            a.count = v.count;
            const elems = elemsOf(ev, v.count);
            unsafe {
                for (const i of 0..v.count) elems[i] = fromValue(ev, valueElementAt(ev, v.elems + i));
            }
            a.elems = elems;
            return a;
        }
        default: return newValue(ComptimeValueKind.Undef);
    }
}

/**
 * Stores a constant value for the program.
 *
 * @param ev - The evaluation
 * @param v - The value
 * @returns The new value's index
 *
 * @remarks
 * The value goes into the checker's table, so it outlives the evaluation.
 * The table grows as needed, and indexes from before the growth stay valid.
 *
 * @since 1.0.0
 */

function addValue(ev: *Evaluation, v: HxValue): u32 {
    const list = &ev.sema.values;
    unsafe {
        if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, @sizeOf(HxValue));
        @ptrCast(HxValue[*], list.items)[list.len] = v;
    }
    list.len += 1;
    return list.len - 1;
}

/**
 * Makes a constant value of a kind that holds an integer.
 *
 * @param kind - The value kind, such as an integer, an error, or a function
 * @param integer - The integer it holds
 * @returns The value
 *
 * @remarks
 * It starts from `emptyValue`, so every field other than the integer is zero.
 *
 * @since 1.0.0
 */

function valueOf(kind: u32, integer: i128): HxValue {
    let v = emptyValue(@truncate(u8, kind));
    v.integer = integer;
    return v;
}

/**
 * Appends the element indexes of an aggregate value to the checker's element list.
 *
 * @param ev - The evaluation
 * @param elems - The value indexes of the elements
 * @param count - The number of elements to append
 * @returns The position of the first appended element
 *
 * @remarks
 * The appended indexes form one contiguous range, so the aggregate value needs only the returned start.
 *
 * @since 1.0.0
 */

function pushValueElems(ev: *Evaluation, elems: readonly u32[], count: u32): u32 {
    const list = &ev.sema.valueElems;
    const first = list.len;
    for (const e of elems[0..count]) {
        unsafe {
            if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, 4);
            list.items![list.len] = e;
        }
        list.len += 1;
    }
    return first;
}

/**
 * Copies the bytes of a `u8` array or slice when every one of them is known.
 *
 * @param elems - The elements of the array
 * @param from - The first element to copy
 * @param count - The number of elements to copy
 * @param out - The buffer to copy into
 * @returns `true` when every element was an integer, and `false` at the first one that was not
 *
 * @remarks
 * It stops at the first element that is not an integer, such as an undefined byte,
 * and leaves the bytes that it has already copied in the buffer.
 *
 * @since 1.0.0
 */

function knownBytes(elems: ComptimeValue[*], from: u32, count: u32, out: u8[*]): bool {
    unsafe {
        for (const i of 0..count) {
            if (elems[from + i].kind != ComptimeValueKind.Int) return false;
            out[i] = @truncate(u8, elems[from + i].i);
        }
    }
    return true;
}

/**
 * Turns an evaluated value of a type into a value that the program can hold, or reports why it can't.
 *
 * @param ev - The evaluation
 * @param v - The evaluated value
 * @param type - The type the value has in the program
 * @param node - The node to report at
 * @returns The value index, {@link EvalVoid} for `void`, or 0 after reporting an error
 *
 * @remarks
 * Numbers, strings, arrays, structs, and optionals can be kept.
 * A read-only `u8` slice becomes a string, and another read-only slice becomes a constant array that codegen emits.
 * Arrays and slices of more than 4096 elements, and pointers, report
 * that a value made at compile time can't be kept for the program.
 *
 * @since 1.0.0
 */

function toValue(ev: *Evaluation, v: ComptimeValue, type: u32, node: u32): u32 {
    const t = typeOf(ev, type);
    if (v.kind == ComptimeValueKind.Undef) return addValue(ev, emptyValue(HxValueUndefined as u8));
    switch (t.kind) {
        case TypeKind.Void, TypeKind.Noreturn: return EvalVoid;
        case TypeKind.Optional: {
            if (v.kind == ComptimeValueKind.Null) return addValue(ev, emptyValue(HxValueNull as u8));
            return toValue(ev, v, t.child, node);
        }
        case TypeKind.ErrorUnion: {
            if (v.kind == ComptimeValueKind.Error) return addValue(ev, valueOf(HxValueError, v.i));
            if (t.child == ev.sema.types.voidType) return addValue(ev, valueOf(HxValueError, 0));
            return toValue(ev, v, t.child, node);
        }
        case TypeKind.Int, TypeKind.Enum, TypeKind.ComptimeInt: if (v.kind == ComptimeValueKind.Int) return addValue(ev, valueOf(HxValueInt, v.i));
        case TypeKind.Float, TypeKind.ComptimeFloat: {
            if (v.kind == ComptimeValueKind.Float) {
                let x = emptyValue(HxValueFloat as u8);
                x.floating = v.f;
                return addValue(ev, x);
            }
        }
        case TypeKind.Bool: {
            if (v.kind == ComptimeValueKind.Bool) {
                let x = emptyValue(HxValueBool as u8);
                x.boolean = v.b;
                return addValue(ev, x);
            }
        }
        case TypeKind.ErrorSet: if (v.kind == ComptimeValueKind.Error) return addValue(ev, valueOf(HxValueError, v.i));
        case TypeKind.Function: if (v.kind == ComptimeValueKind.Func) return addValue(ev, valueOf(HxValueFunction, v.i));
        case TypeKind.StringLiteral, TypeKind.Slice, TypeKind.ManyPointer: {
            const text = t.kind == TypeKind.StringLiteral || t.child == ev.sema.types.u8;
            if (text && (t.kind != TypeKind.Slice || (t.flags & Readonly) != 0)) {
                let bytes: ?readonly u8[*] = null;
                let len: u32 = 0;
                let ok = true;
                if (v.kind == ComptimeValueKind.Bytes) {
                    bytes = v.bytes;
                    len = v.len;
                } else if (v.kind == ComptimeValueKind.Slice && (v.len == 0 || v.target != null)) {
                    const buf = hxArenaAlloc(&ev.arena, (v.len as usize) + 1, 1);
                    unsafe {
                        if (v.len != 0 && !knownBytes(v.target!.elems!, v.start, v.len, buf)) ok = false;
                    }
                    bytes = buf;
                    len = v.len;
                } else {
                    ok = false;
                }
                if (ok) {
                    let s = emptyValue(HxValueString as u8);
                    s.bytes = hxArenaStrndup(&ev.sema.arena, bytes ?? "", len as usize);
                    s.len = len;
                    return addValue(ev, s);
                }
            } else if (t.kind == TypeKind.Slice && (t.flags & Readonly) != 0 && v.kind == ComptimeValueKind.Slice && (v.len == 0 || v.target != null)) {
                // a constant slice: kept as its elements, which codegen puts in a constant array
                let elems: u32[4096] = undefined;
                if (v.len <= 4096) {
                    let ok = true;
                    for (const i of 0..v.len) {
                        if (!ok) break;
                        unsafe {
                            elems[i] = toValue(ev, v.target!.elems![v.start + i], t.child, node);
                        }
                        ok = elems[i] != 0 && elems[i] != EvalVoid;
                    }
                    if (!ok) return 0;
                    let agg = emptyValue(HxValueAggregate as u8);
                    agg.elems = pushValueElems(ev, &elems, v.len);
                    agg.count = v.len;
                    return addValue(ev, agg);
                }
            }
        }
        case TypeKind.Array, TypeKind.Struct: {
            if (v.kind == ComptimeValueKind.Agg && v.count <= 4096) {
                let elems: u32[4096] = undefined;
                let ok = true;
                for (const i of 0..v.count) {
                    if (!ok) break;
                    let elemType = t.child;
                    if (t.kind == TypeKind.Struct) {
                        const agg = aggregateOf(ev, type);
                        for (const m of 0..agg.membersCount) {
                            const mem = memberAt(ev, agg, m);
                            if (mem.kind == HxMemberField as u8 && mem.index == i) elemType = mem.type;
                        }
                    }
                    elems[i] = toValue(ev, elementOf(v, i), elemType, node);
                    ok = elems[i] != 0 && elems[i] != EvalVoid;
                }
                if (!ok) return 0;
                let agg = emptyValue(HxValueAggregate as u8);
                agg.elems = pushValueElems(ev, &elems, v.count);
                agg.count = v.count;
                return addValue(ev, agg);
            }
        }
        default: {}
    }
    if (ev.flow != Flow.Abort) {
        let start: u32 = 0;
        let len: u32 = 0;
        hxNodeSpan(ev.sema.ast!, node, &start, &len);
        const diag = emitf(ev.sema.diags!, DiagError, ev.sema.src, start, len, `a \`${typeName(ev, type)}\` made at compile time can't be kept for the program`);
        diagHint(ev.sema.diags!, diag, "numbers, strings, arrays, structs and optionals can; pointers only exist while the compiler evaluates");
        ev.flow = Flow.Abort;
    }
    return 0;
}

/**
 * Converts a value from one type to another, as the checker decided.
 *
 * @param ev - The evaluation
 * @param v - The value
 * @param from - The type it has
 * @param to - The type it converts to
 * @param node - The node to report at
 * @param checked - Whether an integer that doesn't fit is an error, as it is for an explicit cast
 * @returns The converted value, or an `Undef` value after reporting an error
 *
 * @remarks
 * A float that is out of range for an integer reports an error,
 * and a pointer to an array becomes a slice of the whole array.
 * A `dyn` value can't be made at compile time yet.
 *
 * @since 1.0.0
 */

function convert(ev: *Evaluation, v: ComptimeValue, from: u32, to: u32, node: u32, checked: bool): ComptimeValue {
    if (from == to || to == 0 || from == 0 || ev.flow == Flow.Abort) return v;
    const t = typeOf(ev, to);
    const f = typeOf(ev, from);
    if (v.kind == ComptimeValueKind.Undef) return undefinedOf(ev, to);
    switch (t.kind) {
        case TypeKind.Optional: {
            if (v.kind == ComptimeValueKind.Null || f.kind == TypeKind.Optional) return v;
            return convert(ev, v, from, t.child, node, checked);
        }
        case TypeKind.ErrorUnion: {
            if (f.kind == TypeKind.ErrorSet || f.kind == TypeKind.ErrorUnion) return v;
            return convert(ev, v, from, t.child, node, checked);
        }
        case TypeKind.Int, TypeKind.Enum: {
            let i: i128 = 0;
            if (v.kind == ComptimeValueKind.Int) {
                i = v.i;
            } else if (v.kind == ComptimeValueKind.Bool) {
                i = v.b ? 1 : 0;
            } else if (v.kind == ComptimeValueKind.Float) {
                if (v.f != v.f || v.f >= 1.7e38 || v.f <= -1.7e38) {
                    fail(ev, node, "float cast out of range at compile time");
                    return newValue(ComptimeValueKind.Undef);
                }
                i = v.f as i128;
            } else {
                return v;
            }
            const target = t.kind == TypeKind.Enum ? t.child : to;
            if (checked && !intFits(ev, target, i)) {
                let buf: u8[48] = undefined;
                fail(ev, node, `${intText(i, &buf)} doesn't fit in \`${typeName(ev, target)}\` (cast at compile time)`);
                return newValue(ComptimeValueKind.Undef);
            }
            return cvInt(i);
        }
        case TypeKind.Float: {
            if (v.kind != ComptimeValueKind.Int && v.kind != ComptimeValueKind.Float) return v;
            const d = v.kind == ComptimeValueKind.Int ? v.i as f64 : v.f;
            return cvFloat(t.bits == 32 ? (d as f32) as f64 : d);
        }
        case TypeKind.Slice: {
            if (f.kind == TypeKind.Pointer && v.kind == ComptimeValueKind.Ptr && v.target != null && v.target!.kind == ComptimeValueKind.Agg) {
                let s = newValue(ComptimeValueKind.Slice);   // `&array` as a slice of the whole array
                s.target = v.target;
                s.len = v.target!.count;
                return s;
            }
            return v;
        }
        case TypeKind.Dyn: {
            unsupported(ev, node, "`dyn` values");
            return newValue(ComptimeValueKind.Undef);
        }
        default: return v;
    }
}

/**
 * Declares a local with a deep copy of a value.
 *
 * @param ev - The evaluation
 * @param sym - The symbol of the local
 * @param v - The value it starts with
 * @returns The local's storage
 *
 * @remarks
 * The copy keeps value semantics, so changing the local never changes the value that it came from.
 * {@link findLocal} takes the newest local with a symbol,
 * so a recursive call gets its own storage for the same symbols.
 *
 * @since 1.0.0
 */

function declare(ev: *Evaluation, sym: u32, v: ComptimeValue): *ComptimeValue {
    const slot = slotOf(ev);
    *slot = copy(ev, v);
    unsafe {
        if (ev.localsLen == ev.localsCap) hxVecGrowImpl(@ptrCast(*?u8[*], &ev.locals), &ev.localsCap, ev.localsLen + 1, @sizeOf(Local));
        ev.locals![ev.localsLen] = Local { sym, slot };
    }
    ev.localsLen += 1;
    return slot;
}

/**
 * Finds the storage of a local in the current call.
 *
 * @param ev - The evaluation
 * @param sym - The symbol of the local
 * @returns The storage of the newest local with that symbol, or `null` when the current call has none
 *
 * @remarks
 * Locals below the frame base belong to callers, so the search stops there.
 *
 * @since 1.0.0
 */

function findLocal(ev: *Evaluation, sym: u32): ?*ComptimeValue {
    let i = ev.localsLen;
    while (i > ev.frameBase) {
        i -= 1;
        unsafe {
            if (ev.locals![i].sym == sym) return ev.locals![i].slot;
        }
    }
    return null;
}

/**
 * Turns a constant value into an interpreter value, like {@link fromValue}, knowing its type.
 *
 * @param ev - The evaluation
 * @param index - The value index
 * @param type - The type of the value
 * @returns The interpreter value
 *
 * @remarks
 * A constant slice is stored as its elements and comes back as a slice of them.
 *
 * @since 1.0.0
 */

function fromTypedValue(ev: *Evaluation, index: u32, type: u32): ComptimeValue {
    const v = valueAt(ev, index);
    const t = typeOf(ev, type);
    if (v.kind != HxValueAggregate as u8) return fromValue(ev, index);
    if (t.kind == TypeKind.Optional) return fromTypedValue(ev, index, t.child);
    let a = newValue(ComptimeValueKind.Agg);
    a.count = v.count;
    const elems = elemsOf(ev, v.count);
    for (const i of 0..v.count) {
        let e = t.child;
        if (t.kind == TypeKind.Struct) {
            const agg = aggregateOf(ev, type);
            for (const m of 0..agg.membersCount) {
                const mem = memberAt(ev, agg, m);
                if (mem.kind == HxMemberField as u8 && mem.index == i) e = mem.type;
            }
        }
        const elementValue = valueElementAt(ev, v.elems + i);
        unsafe {
            elems[i] = e != 0 ? fromTypedValue(ev, elementValue, e) : fromValue(ev, elementValue);
        }
    }
    a.elems = elems;
    if (t.kind != TypeKind.Slice) return a;
    let s = newValue(ComptimeValueKind.Slice);
    const target = slotOf(ev);
    *target = a;
    s.target = target;
    s.len = a.count;
    return s;
}

/**
 * Finds the value of a symbol outside the current call.
 *
 * @param ev - The evaluation
 * @param sym - The symbol
 * @param node - The node to report at
 * @returns The value, or an `Undef` value after reporting an error
 *
 * @remarks
 * The symbol can be a constant, or a global constant array or struct
 * such as `const T = comptime f();` whose value the program keeps.
 * Anything else reports that the symbol is only known when the program runs.
 *
 * @since 1.0.0
 */

function symbolValue(ev: *Evaluation, sym: u32, node: u32): ComptimeValue {
    const s = symbolOf(ev, sym);
    if (s.value != 0) return fromValue(ev, s.value);
    if (s.kind == HxSymGlobal as u8 && nodeOf(ev, s.decl).kind == NodeKind.Const && nodeOf(ev, s.decl).b != 0) {
        let v: u32 = 0;
        unsafe {
            v = @ptrCast(HxNodeInfo[*], ev.sema.info)[nodeOf(ev, s.decl).b].value;   // `const T = comptime f();`: kept in the binary
        }
        if (v != 0) return fromTypedValue(ev, v, s.type);
    }
    fail(ev, node, `\`${tokenText(ev, s.token)}\` is only known when the program runs`);
    return newValue(ComptimeValueKind.Undef);
}

/**
 * Finds the array or string that a node indexes into.
 *
 * @param ev - The evaluation
 * @param base - The node that is indexed
 * @param out - The sequence to fill
 * @returns `true` when the node gave a sequence, and `false` after reporting an error
 *
 * @remarks
 * An array is reached through its storage, so that an element can be assigned.
 * An undefined array becomes one of undefined elements first.
 *
 * @since 1.0.0
 */

function sequence(ev: *Evaluation, base: u32, out: *Sequence): bool {
    const type = finalType(ev, base);
    *out = Sequence { array: null, bytes: null, start: 0, len: 0 };
    if (typeOf(ev, type).kind == TypeKind.Array) {
        const slot = place(ev, base);
        if (slot == null || ev.flow != Flow.None) return false;
        if (slot.kind == ComptimeValueKind.Undef) *slot = undefinedOf(ev, type);
        out.array = slot;
        out.len = slot.count;
        return true;
    }
    const v = eval(ev, base);
    if (ev.flow != Flow.None) return false;
    if (v.kind == ComptimeValueKind.Ptr && v.target != null && v.target!.kind == ComptimeValueKind.Agg) {
        out.array = v.target;
        out.len = v.target!.count;
        return true;
    }
    if (v.kind == ComptimeValueKind.Slice) {
        out.array = v.target;
        out.start = v.start;
        out.len = v.len;
        return true;
    }
    if (v.kind == ComptimeValueKind.Bytes) {
        out.bytes = v.bytes;
        out.len = v.len;
        return true;
    }
    if (v.kind == ComptimeValueKind.Undef) fail(ev, base, "this reads an undefined value at compile time");
    else unsupported(ev, base, "indexing this");
    return false;
}

/**
 * Evaluates the index of an index expression and checks it against a length.
 *
 * @param ev - The evaluation
 * @param node - The index expression
 * @param len - The length of the sequence
 * @param out - The index, when it is in bounds
 * @returns `true` when the index is in bounds, and `false` after reporting an error
 *
 * @remarks
 * An index that is not an integer fails the kind check,
 * and a negative or too large index reports its value and the length.
 *
 * @since 1.0.0
 */

function indexOf(ev: *Evaluation, node: u32, len: u32, out: *u64): bool {
    const i = eval(ev, nodeOf(ev, node).b);
    if (ev.flow != Flow.None || !expectKind(ev, i, ComptimeValueKind.Int, nodeOf(ev, node).b)) return false;
    if (i.i < 0 || @truncate(u64, i.i) >= (len as u64)) {
        let buf: u8[48] = undefined;
        fail(ev, node, `index out of bounds at compile time: index ${intText(i.i, &buf)}, len ${len}`);
        return false;
    }
    *out = @truncate(u64, i.i);
    return true;
}

/**
 * Reads one element of a sequence.
 *
 * @param seq - The sequence
 * @param i - The index within the sequence
 * @returns The element, or the byte as an integer for a string
 *
 * @remarks
 * The index is not checked, so the caller checks it with {@link indexOf} first.
 * A string element reads as an integer, since a byte of a string is a `u8`.
 *
 * @since 1.0.0
 */

function element(seq: *Sequence, i: u64): ComptimeValue {
    unsafe {
        if (const array = seq.array) return array.elems![(seq.start as usize) + (i as usize)];
        return cvInt(seq.bytes![i as usize] as i128);
    }
}

/**
 * Finds the storage that a place expression names, so that it can be assigned or have its address taken.
 *
 * @param ev - The evaluation
 * @param node - The place expression
 * @returns The storage, or `null` after reporting an error
 *
 * @remarks
 * A local, an element, a field, and a dereference name existing storage.
 * Changing a global variable can't run at compile time yet, and string literals can't be changed.
 * Any other expression, a constant included, gets temporary storage that holds a copy of its value.
 *
 * @since 1.0.0
 */

function place(ev: *Evaluation, node: u32): ?*ComptimeValue {
    if (ev.flow != Flow.None) return null;
    const n = nodeOf(ev, node);
    const info = infoOf(ev, node);
    switch (n.kind) {
        case NodeKind.Ident: {
            if (const slot = findLocal(ev, info.symbol)) return slot;
            if (symbolOf(ev, info.symbol).kind == HxSymGlobal as u8 && (symbolOf(ev, info.symbol).flags & (HxSymMutable as u16)) != 0) {
                unsupported(ev, node, "changing a global variable");
                return null;
            }
            // a constant: give it temporary storage, below
        }
        case NodeKind.Index: {
            let seq: Sequence = undefined;
            let i: u64 = 0;
            if (!sequence(ev, n.a, &seq) || !indexOf(ev, node, seq.len, &i)) return null;
            if (seq.array == null) {
                fail(ev, node, "string literals can't be changed");
                return null;
            }
            return elemSlot(*seq.array!, seq.start + @truncate(u32, i));
        }
        case NodeKind.FieldAccess: {
            if ((info.flags & HxInfoField) != 0) {
                let base: ?*ComptimeValue = null;
                if ((info.flags & HxInfoDeref) != 0) {
                    const p = eval(ev, n.a);
                    if (ev.flow != Flow.None || !expectKind(ev, p, ComptimeValueKind.Ptr, n.a)) return null;
                    base = p.target;
                } else {
                    base = place(ev, n.a);
                }
                if (base == null) return null;
                if (base!.kind == ComptimeValueKind.Undef) {
                    const t = finalType(ev, n.a);
                    *base! = undefinedOf(ev, typeOf(ev, t).kind == TypeKind.Pointer ? typeOf(ev, t).child : t);
                }
                if (base!.kind != ComptimeValueKind.Agg) {
                    fail(ev, node, "this value can't be used at compile time here");
                    return null;
                }
                return elemSlot(*base!, info.aux);
            }
        }
        case NodeKind.Deref: {
            const p = eval(ev, n.a);
            if (ev.flow != Flow.None || !expectKind(ev, p, ComptimeValueKind.Ptr, n.a)) return null;
            return p.target;
        }
        default: {}
    }
    const v = eval(ev, node);
    if (ev.flow != Flow.None) return null;
    const temp = slotOf(ev);
    *temp = copy(ev, v);
    return temp;
}

/**
 * Compares the bytes of two strings.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns `true` when they have the same length and bytes
 *
 * @remarks
 * Strings compare by content, so two strings at different addresses with the same bytes are equal.
 *
 * @since 1.0.0
 */

function bytesEqual(a: ComptimeValue, b: ComptimeValue): bool {
    if (a.len != b.len) return false;
    unsafe {
        for (const i of 0..a.len) {
            if (a.bytes![i] != b.bytes![i]) return false;
        }
    }
    return true;
}

/**
 * Compares two values for `==`.
 *
 * @param ev - The evaluation
 * @param a - The left value
 * @param b - The right value
 * @param node - The node to report at
 * @returns `true` when the values are equal
 *
 * @remarks
 * Integers and floats compare by number, pointers by the storage they point to, and strings by their bytes.
 * `null` equals only `null`.
 * An undefined value, and a pair of kinds without a comparison, report an error.
 *
 * @since 1.0.0
 */

function equal(ev: *Evaluation, a: ComptimeValue, b: ComptimeValue, node: u32): bool {
    if (a.kind == ComptimeValueKind.Undef || b.kind == ComptimeValueKind.Undef) {
        fail(ev, node, "this reads an undefined value at compile time");
        return false;
    }
    if (a.kind == ComptimeValueKind.Null || b.kind == ComptimeValueKind.Null) return a.kind == b.kind;
    switch (a.kind) {
        case ComptimeValueKind.Int, ComptimeValueKind.Error, ComptimeValueKind.Func: return b.kind == ComptimeValueKind.Float ? (a.i as f64) == b.f : a.i == b.i;
        case ComptimeValueKind.Float: return b.kind == ComptimeValueKind.Int ? a.f == (b.i as f64) : a.f == b.f;
        case ComptimeValueKind.Bool: return a.b == b.b;
        case ComptimeValueKind.Ptr: return samePlace(a.target, b.target);
        case ComptimeValueKind.Bytes: if (b.kind == ComptimeValueKind.Bytes) return bytesEqual(a, b);
        default: {}
    }
    unsupported(ev, node, "comparing these values");
    return false;
}

/**
 * Checks whether two pointers point to the same storage.
 *
 * @param a - The first target
 * @param b - The second target
 * @returns `true` when both are the same storage or both are `null`
 *
 * @remarks
 * Pointers compare by identity, so two slots that hold equal values still differ.
 *
 * @since 1.0.0
 */

function samePlace(a: ?*ComptimeValue, b: ?*ComptimeValue): bool {
    if (a == null || b == null) return a == null && b == null;
    return a == b;
}

/**
 * Reads an integer or float value as a float.
 *
 * @param v - The value
 * @returns The float, or the integer converted to one
 *
 * @remarks
 * The caller checks that the value is a number first, since any other kind reads as its integer field.
 *
 * @since 1.0.0
 */

function asFloat(v: ComptimeValue): f64 {
    return v.kind == ComptimeValueKind.Float ? v.f : v.i as f64;
}

/**
 * Evaluates a binary expression.
 *
 * @param ev - The evaluation
 * @param node - The binary expression
 * @returns The result
 *
 * @remarks
 * `&&`, `||`, and `??` evaluate their right side only when the left side does not decide the result.
 * Comparisons with a NaN are false.
 * Float arithmetic rounds to `f32` when the operands are `f32`, and integer arithmetic goes through {@link intOp}.
 *
 * @since 1.0.0
 */

function binary(ev: *Evaluation, node: u32): ComptimeValue {
    const n = nodeOf(ev, node);
    const op = @enumFromInt(BinOp, n.op);
    if (op == BinOp.And || op == BinOp.Or) {
        const a = eval(ev, n.a);
        if (ev.flow != Flow.None || !expectKind(ev, a, ComptimeValueKind.Bool, n.a)) return a;
        if (a.b == (op == BinOp.Or)) return a;
        const b = eval(ev, n.b);
        if (ev.flow == Flow.None) void expectKind(ev, b, ComptimeValueKind.Bool, n.b);
        return b;
    }
    if (op == BinOp.Coalesce) {
        const a = eval(ev, n.a);
        if (ev.flow != Flow.None || a.kind != ComptimeValueKind.Null) return a;
        return eval(ev, n.b);
    }
    const a = eval(ev, n.a);
    const b = eval(ev, n.b);
    if (ev.flow != Flow.None) return a;
    const type = finalType(ev, n.a);
    if (op == BinOp.Eq || op == BinOp.Ne) {
        const same = equal(ev, a, b, node);
        return cvBool(op == BinOp.Eq ? same : !same);
    }
    if (a.kind == ComptimeValueKind.Undef || b.kind == ComptimeValueKind.Undef) {
        fail(ev, node, "this reads an undefined value at compile time");
        return a;
    }
    if ((op as u32) >= (BinOp.Lt as u32) && (op as u32) <= (BinOp.Ge as u32)) {
        let cmp: i32 = 0;
        if (a.kind == ComptimeValueKind.Float || b.kind == ComptimeValueKind.Float) {
            const x = asFloat(a);
            const y = asFloat(b);
            if (x != x || y != y) return cvBool(false);
            cmp = x < y ? -1 : x > y ? 1 : 0;
        } else {
            cmp = a.i < b.i ? -1 : a.i > b.i ? 1 : 0;
        }
        return cvBool(switch (op) {
            case BinOp.Lt: cmp < 0;
            case BinOp.Le: cmp <= 0;
            case BinOp.Gt: cmp > 0;
            default: cmp >= 0;
        });
    }
    if (a.kind == ComptimeValueKind.Float || b.kind == ComptimeValueKind.Float) {
        const x = asFloat(a);
        const y = asFloat(b);
        let r: f64 = 0;
        switch (op) {
            case BinOp.Add: r = x + y;
            case BinOp.Sub: r = x - y;
            case BinOp.Mul: r = x * y;
            case BinOp.Div: r = x / y;
            case BinOp.Mod: r = fmod(x, y);
            default: {
                unsupported(ev, node, "this operator on floats");
                return a;
            }
        }
        return cvFloat(typeOf(ev, type).kind == TypeKind.Float && typeOf(ev, type).bits == 32 ? (r as f32) as f64 : r);
    }
    if (!expectKind(ev, a, ComptimeValueKind.Int, n.a) || !expectKind(ev, b, ComptimeValueKind.Int, n.b)) return a;
    return intOp(ev, node, op, a.i, b.i, type);
}

/**
 * Runs a function with its arguments.
 *
 * @param ev - The evaluation
 * @param sym - The function's symbol
 * @param args - The arguments, already converted to the parameter types
 * @param site - The call to report at
 * @returns The returned value, an `Error` value for a thrown error, or `Void`
 *
 * @remarks
 * The host checks the function's body first, since the checker may not have reached it yet.
 * A C function can't run at compile time, and a call that nests past {@link MaxDepth} reports an error.
 * The call runs in its own frame with the function's generic instance,
 * and returning puts back the caller's locals, defers, and instance.
 *
 * @since 1.0.0
 */

function call(ev: *Evaluation, sym: u32, args: readonly ComptimeValue[], site: u32): ComptimeValue {
    const s = symbolOf(ev, sym);
    const name = (s.flags & (HxSymArrow as u16)) != 0 ? "the arrow function" : tokenText(ev, s.token);
    if ((s.flags & (HxSymExtern as u16)) != 0) {
        fail(ev, site, `\`${name}\` is a C function, so it can't run at compile time`);
        return newValue(ComptimeValueKind.Undef);
    }
    if (!ev.host.ensureBody!(ev.host.user, sym)) {
        ev.flow = Flow.Abort;   // its errors are already reported
        return newValue(ComptimeValueKind.Undef);
    }
    if (ev.depth >= MaxDepth) {
        fail(ev, site, `compile-time calls nest more than ${MaxDepth} deep`);
        return newValue(ComptimeValueKind.Undef);
    }
    if (!step(ev, site)) return newValue(ComptimeValueKind.Undef);

    const fn = record<HxFnData>(ev.sema.ast!, nodeOf(ev, s.decl).a);
    const savedInstance = ev.instance;
    const savedBase = ev.frameBase;
    const savedLocals = ev.localsLen;
    const savedDefers = ev.defersLen;
    ev.instance = s.instance;
    ev.frameBase = ev.localsLen;
    ev.depth += 1;
    for (const arg, i of args) {
        if (fn.paramsStart + @truncate(u32, i) >= fn.paramsEnd) break;
        void declare(ev, infoOf(ev, extraOf(ev, fn.paramsStart + @truncate(u32, i))).symbol, arg);
    }
    let result = newValue(ComptimeValueKind.Void);
    if (nodeOf(ev, fn.body).kind == NodeKind.Block) {
        exec(ev, fn.body);
        if (ev.flow == Flow.Return) result = ev.ret;
    } else {
        result = eval(ev, fn.body);   // an arrow function's expression body
        if (ev.flow == Flow.Return) result = ev.ret;   // `throw` inside it
    }
    if (ev.flow != Flow.Abort) ev.flow = Flow.None;
    ev.depth -= 1;
    ev.instance = savedInstance;
    ev.frameBase = savedBase;
    ev.localsLen = savedLocals;
    ev.defersLen = savedDefers;
    return result;
}

/**
 * Evaluates a call expression.
 *
 * @param ev - The evaluation
 * @param node - The call
 * @returns The returned value, or an `Undef` value after reporting an error
 *
 * @remarks
 * A method call passes its receiver as the first argument, by address when the method takes `*this`.
 * A call through a function value runs the function that the value holds.
 * Printing, union values, calls through `dyn`, and formatting can't run at compile time.
 * At most 256 arguments are passed.
 *
 * @since 1.0.0
 */

function evalCall(ev: *Evaluation, node: u32): ComptimeValue {
    const n = nodeOf(ev, node);
    const info = infoOf(ev, node);
    const range = record<HxRange>(ev.sema.ast!, n.b);
    if ((info.flags & HxInfoPrint) != 0) {
        fail(ev, node, "printing can't happen at compile time");
        return newValue(ComptimeValueKind.Undef);
    }
    if ((info.flags & HxInfoUnionInit) != 0) {
        unsupported(ev, node, "union values");
        return newValue(ComptimeValueKind.Undef);
    }
    if ((info.flags & (HxInfoDyn | HxInfoFormatWrite)) != 0) {
        unsupported(ev, node, (info.flags & HxInfoDyn) != 0 ? "calls through `dyn`" : "formatting");
        return newValue(ComptimeValueKind.Undef);
    }
    let args: ComptimeValue[257] = undefined;
    let count: u32 = 0;
    let sym = info.symbol;
    if ((info.flags & HxInfoMethod) != 0) {   // the receiver is the first argument
        const callee = nodeOf(ev, n.a).kind == NodeKind.GenericInstance ? nodeOf(ev, n.a).a : n.a;   // `x.map<i32>(f)`
        const receiver = nodeOf(ev, callee).a;
        const throughPointer = (info.flags & HxInfoDeref) != 0;
        if ((info.flags & HxInfoReceiverAddr) != 0) {
            if (throughPointer) {
                args[count] = eval(ev, receiver);
            } else {
                let p = newValue(ComptimeValueKind.Ptr);
                p.target = place(ev, receiver);
                args[count] = p;
            }
        } else if (throughPointer) {
            const p = eval(ev, receiver);
            if (ev.flow != Flow.None || !expectKind(ev, p, ComptimeValueKind.Ptr, receiver)) return newValue(ComptimeValueKind.Undef);
            args[count] = *p.target!;
        } else {
            args[count] = eval(ev, receiver);
        }
        count += 1;
    } else if ((info.flags & HxInfoIndirect) != 0) {
        const f = eval(ev, n.a);
        if (ev.flow != Flow.None || !expectKind(ev, f, ComptimeValueKind.Func, n.a)) return newValue(ComptimeValueKind.Undef);
        sym = @truncate(u32, f.i);
    }
    for (const i of range.start..range.end) {
        if (count >= 256) break;
        args[count] = eval(ev, extraOf(ev, i));
        count += 1;
    }
    if (ev.flow != Flow.None) return newValue(ComptimeValueKind.Undef);
    const all: *ComptimeValue[257] = &args;
    return call(ev, sym, all[0..count], node);
}

/**
 * Evaluates a struct literal.
 *
 * @param ev - The evaluation
 * @param node - The struct literal
 * @returns The struct, as an aggregate of its fields
 *
 * @remarks
 * A field that the literal leaves out gets its default value,
 * which runs in the struct's own generic instance since its types belong there.
 * The shorthand `{ name }` reads a constant, a local, or a global constant.
 *
 * @since 1.0.0
 */

function structLiteral(ev: *Evaluation, node: u32): ComptimeValue {
    const type = infoOf(ev, node).type;
    const agg = aggregateOf(ev, type);
    let v = newValue(ComptimeValueKind.Agg);
    v.count = agg.fieldCount;
    v.elems = elemsOf(ev, v.count);
    const set = hxArenaAlloc(&ev.arena, (v.count as usize) + 1, 1);
    unsafe {
        for (const i of 0..v.count + 1) set[i] = 0;
    }
    const inits = record<HxRange>(ev.sema.ast!, nodeOf(ev, node).b);
    for (const i of inits.start..inits.end) {
        if (ev.flow != Flow.None) break;
        const init = extraOf(ev, i);
        const info = infoOf(ev, init);
        let field = newValue(ComptimeValueKind.Undef);
        if (nodeOf(ev, init).a != 0) {
            field = eval(ev, nodeOf(ev, init).a);
        } else if (info.value != 0) {   // `{ name }` of a constant
            field = convert(ev, fromValue(ev, info.value), info.type, info.coerce, init, false);
        } else {                        // `{ name }` of a variable
            if (const slot = findLocal(ev, info.symbol)) field = *slot;
            else field = symbolValue(ev, info.symbol, init);
            field = convert(ev, field, info.type, info.coerce, init, false);
        }
        *elemSlot(v, info.aux) = copy(ev, field);
        unsafe {
            set[info.aux] = 1;
        }
    }
    for (const i of 0..agg.membersCount) {
        if (ev.flow != Flow.None) break;
        const m = memberAt(ev, agg, i);
        unsafe {
            if (m.kind != HxMemberField as u8 || set[m.index] != 0 || m.defaultValue == 0) continue;
        }
        const saved = ev.instance;
        ev.instance = agg.instance;   // the default's types belong to the struct's own instance
        *elemSlot(v, m.index) = copy(ev, eval(ev, m.defaultValue));
        ev.instance = saved;
    }
    return v;
}

/**
 * Evaluates a field access.
 *
 * @param ev - The evaluation
 * @param node - The field access
 * @returns The field's value, or an `Undef` value after reporting an error
 *
 * @remarks
 * A field reached through a pointer reads the pointee.
 * A name from another module reads that module's symbol.
 * `.len` of a slice or string is its length, while `.ptr` has no compile-time form.
 *
 * @since 1.0.0
 */

function fieldAccess(ev: *Evaluation, node: u32): ComptimeValue {
    const n = nodeOf(ev, node);
    const info = infoOf(ev, node);
    if ((info.flags & HxInfoModuleRef) != 0) return symbolValue(ev, info.symbol, node);
    if ((info.flags & HxInfoUnionInit) != 0) {
        unsupported(ev, node, "union values");
        return newValue(ComptimeValueKind.Undef);
    }
    let base = eval(ev, n.a);
    if (ev.flow != Flow.None) return base;
    if ((info.flags & HxInfoField) != 0) {
        if ((info.flags & HxInfoDeref) != 0) {
            if (!expectKind(ev, base, ComptimeValueKind.Ptr, n.a)) return base;
            base = *base.target!;
        }
        if (!expectKind(ev, base, ComptimeValueKind.Agg, n.a)) return base;
        return elementOf(base, info.aux);
    }
    // `.len` of a slice or string; `.ptr` has no compile-time form
    if (tokenText(ev, n.token)[0] != 'l') {
        unsupported(ev, node, "`.ptr`");
        return newValue(ComptimeValueKind.Undef);
    }
    if (base.kind == ComptimeValueKind.Slice || base.kind == ComptimeValueKind.Bytes) return cvInt(base.len as i128);
    fail(ev, node, "this reads an undefined value at compile time");
    return newValue(ComptimeValueKind.Undef);
}

/**
 * Evaluates a slice expression such as `a[1..3]`.
 *
 * @param ev - The evaluation
 * @param node - The slice expression
 * @returns A slice of the array, the bytes of a string, or an `Undef` value after reporting an error
 *
 * @remarks
 * A start after the end, and an end past the length, report an error.
 *
 * @since 1.0.0
 */

function sliceOf(ev: *Evaluation, node: u32): ComptimeValue {
    const n = nodeOf(ev, node);
    const data = record<HxSliceData>(ev.sema.ast!, n.b);
    let seq: Sequence = undefined;
    if (!sequence(ev, n.a, &seq)) return newValue(ComptimeValueKind.Undef);
    let start: i128 = 0;
    let end: i128 = seq.len as i128;
    if (data.start != 0) {
        const s = eval(ev, data.start);
        if (ev.flow != Flow.None || !expectKind(ev, s, ComptimeValueKind.Int, data.start)) return s;
        start = s.i;
    }
    if (data.end != 0) {
        const e = eval(ev, data.end);
        if (ev.flow != Flow.None || !expectKind(ev, e, ComptimeValueKind.Int, data.end)) return e;
        end = e.i + ((n.flags & FlagInclusive) != 0 ? 1 : 0);
    }
    if (start > end || end > (seq.len as i128) || start < 0) {
        fail(ev, node, `${start > end ? "slice start is after its end (at compile time)" : "slice end is out of bounds (at compile time)"}`);
        return newValue(ComptimeValueKind.Undef);
    }
    if (seq.array == null) {
        let b = newValue(ComptimeValueKind.Bytes);
        unsafe {
            b.bytes = @ptrFromInt(u8[*], @intFromPtr(seq.bytes!) + @truncate(usize, start));
        }
        b.len = @truncate(u32, end - start);
        return b;
    }
    let s = newValue(ComptimeValueKind.Slice);
    s.target = seq.array;
    s.start = seq.start + @truncate(u32, start);
    s.len = @truncate(u32, end - start);
    return s;
}

/**
 * Evaluates a builtin call.
 *
 * @param ev - The evaluation
 * @param node - The builtin call
 * @returns The result, or an `Undef` value after reporting an error
 *
 * @remarks
 * `@panic` reports `panic at compile time:` with its message,
 * and `@compileError` reports its message as the error.
 * `@truncate` wraps its value to the result type.
 * Any other builtin can't run at compile time yet.
 *
 * @since 1.0.0
 */

function builtin(ev: *Evaluation, node: u32): ComptimeValue {
    const n = nodeOf(ev, node);
    const name = tokenText(ev, n.token);
    const isPanic = name.len == 6 && name[1] == 'p';
    const isCompileError = name.len == 13 && name[1] == 'c' && name[8] == 'E';
    if (isPanic || isCompileError) {
        const message = eval(ev, extraOf(ev, n.a));
        if (ev.flow != Flow.None) return message;
        let text: string = "";
        if (message.kind == ComptimeValueKind.Bytes) {
            unsafe {
                text = message.bytes![0..message.len];
            }
        } else if (message.kind == ComptimeValueKind.Slice && message.target != null) {
            const buf = hxArenaAlloc(&ev.arena, (message.len as usize) + 1, 1);
            unsafe {
                if (knownBytes(message.target!.elems!, message.start, message.len, buf)) text = buf[0..message.len];
            }
        }
        if (isPanic) fail(ev, node, `panic at compile time: ${text}`);
        else fail(ev, node, `${text}`);
        return newValue(ComptimeValueKind.Undef);
    }
    if (name.len == 9 && name[1] == 't') {   // @truncate
        const v = eval(ev, extraOf(ev, n.a + 1));
        if (ev.flow != Flow.None || !expectKind(ev, v, ComptimeValueKind.Int, node)) return v;
        return cvInt(wrapToType(ev, infoOf(ev, node).type, v.i));
    }
    unsupported(ev, node, "this builtin");
    return newValue(ComptimeValueKind.Undef);
}

/**
 * Names a node kind for an error message.
 *
 * @param kind - The node kind
 * @returns The name
 *
 * @remarks
 * The name comes from `hxNodeKindName` as static text, so the slice never needs to be released.
 *
 * @since 1.0.0
 */

function nodeKindName(kind: NodeKind): string {
    const text = hxNodeKindName(kind as u32);
    unsafe {
        let n: usize = 0;
        while (text[n] != 0) n += 1;
        return text[0..n];
    }
}

/**
 * Evaluates an expression whose value the checker did not already know.
 *
 * @param ev - The evaluation
 * @param node - The expression
 * @returns The value, before the conversion that the checker decided for the node
 *
 * @remarks
 * Every kind of expression has its own case, and a kind without one reports that it can't run at compile time yet.
 * `try` and `throw` return the error from the call, and `x ?? return 0` runs the `return` as a statement.
 * Unwrapping `null` and reaching `unreachable` report an error.
 *
 * @since 1.0.0
 */

function evalRaw(ev: *Evaluation, node: u32): ComptimeValue {
    const n = nodeOf(ev, node);
    const info = infoOf(ev, node);
    switch (n.kind) {
        case NodeKind.Ident: {
            if (const slot = findLocal(ev, info.symbol)) return *slot;
            return symbolValue(ev, info.symbol, node);
        }
        case NodeKind.Binary: return binary(ev, node);
        case NodeKind.Negate: {
            const v = eval(ev, n.a);
            if (ev.flow != Flow.None) return v;
            if (v.kind == ComptimeValueKind.Float) return cvFloat(-v.f);
            if (!expectKind(ev, v, ComptimeValueKind.Int, n.a)) return v;
            return intOp(ev, node, BinOp.Sub, 0, v.i, finalType(ev, n.a));
        }
        case NodeKind.Not: {
            const v = eval(ev, n.a);
            if (ev.flow != Flow.None || !expectKind(ev, v, ComptimeValueKind.Bool, n.a)) return v;
            return cvBool(!v.b);
        }
        case NodeKind.BitNot: {
            const v = eval(ev, n.a);
            if (ev.flow != Flow.None || !expectKind(ev, v, ComptimeValueKind.Int, n.a)) return v;
            return cvInt(wrapToType(ev, finalType(ev, n.a), ~v.i));
        }
        case NodeKind.AddressOf: {
            let p = newValue(ComptimeValueKind.Ptr);
            p.target = place(ev, n.a);
            return p;
        }
        case NodeKind.Deref: {
            const p = eval(ev, n.a);
            if (ev.flow != Flow.None || !expectKind(ev, p, ComptimeValueKind.Ptr, n.a)) return p;
            return *p.target!;
        }
        case NodeKind.Discard: {
            void eval(ev, n.a);
            return newValue(ComptimeValueKind.Void);
        }
        case NodeKind.Call: return evalCall(ev, node);
        case NodeKind.Cast: return convert(ev, eval(ev, n.a), finalType(ev, n.a), info.type, node, true);
        case NodeKind.Ternary: {
            const data = record<HxTernaryData>(ev.sema.ast!, n.b);
            const c = eval(ev, n.a);
            if (ev.flow != Flow.None || !expectKind(ev, c, ComptimeValueKind.Bool, n.a)) return c;
            return eval(ev, c.b ? data.thenValue : data.elseValue);
        }
        case NodeKind.Index: {
            let seq: Sequence = undefined;
            let i: u64 = 0;
            if (!sequence(ev, n.a, &seq) || !indexOf(ev, node, seq.len, &i)) return newValue(ComptimeValueKind.Undef);
            return element(&seq, i);
        }
        case NodeKind.Slice: return sliceOf(ev, node);
        case NodeKind.FieldAccess: return fieldAccess(ev, node);
        case NodeKind.BuiltinCall: return builtin(ev, node);
        case NodeKind.StructLiteral: return structLiteral(ev, node);
        case NodeKind.ArrayLiteral: {
            const isSlice = typeOf(ev, info.type).kind == TypeKind.Slice;
            if (isSlice && n.a == n.b) return newValue(ComptimeValueKind.Slice);   // `[]`
            let v = newValue(ComptimeValueKind.Agg);
            v.count = n.b - n.a;
            v.elems = elemsOf(ev, v.count);
            for (const i of 0..v.count) {
                if (ev.flow != Flow.None) break;
                *elemSlot(v, i) = copy(ev, eval(ev, extraOf(ev, n.a + i)));
            }
            if (!isSlice) return v;
            let s = newValue(ComptimeValueKind.Slice);   // a constant `readonly T[]`: a slice of the array the literal makes
            const target = slotOf(ev);
            *target = v;
            s.target = target;
            s.len = v.count;
            return s;
        }
        case NodeKind.Unwrap: {
            const v = eval(ev, n.a);
            if (ev.flow == Flow.None && v.kind == ComptimeValueKind.Null) fail(ev, node, "unwrapped a null value at compile time");
            return v;
        }
        case NodeKind.OptionalField: {
            let base = eval(ev, n.a);
            if (ev.flow != Flow.None || base.kind == ComptimeValueKind.Null) return base;
            if ((info.flags & HxInfoField) != 0) {
                if ((info.flags & HxInfoDeref) != 0) {
                    if (!expectKind(ev, base, ComptimeValueKind.Ptr, n.a)) return base;
                    base = *base.target!;
                }
                if (!expectKind(ev, base, ComptimeValueKind.Agg, n.a)) return base;
                return elementOf(base, info.aux);
            }
            return cvInt(base.len as i128);   // `?.len`
        }
        case NodeKind.Try: {
            const v = eval(ev, n.a);
            if (ev.flow == Flow.None && v.kind == ComptimeValueKind.Error) {
                ev.ret = v;
                ev.flow = Flow.Return;
            }
            return v;
        }
        case NodeKind.Catch: {
            const data = record<HxCatchData>(ev.sema.ast!, n.b);
            const v = eval(ev, n.a);
            if (ev.flow != Flow.None || v.kind != ComptimeValueKind.Error) return v;
            const mark = ev.localsLen;
            if (info.symbol != 0) void declare(ev, info.symbol, v);
            let fallback = newValue(ComptimeValueKind.Void);
            if (nodeOf(ev, data.body).kind == NodeKind.Block) exec(ev, data.body);
            else fallback = eval(ev, data.body);
            ev.localsLen = mark;
            return fallback;
        }
        case NodeKind.Switch: return switchOf(ev, node, true);
        case NodeKind.Throw: {
            let e = eval(ev, n.a);
            if (ev.flow != Flow.None) return e;
            e.kind = ComptimeValueKind.Error;
            ev.ret = e;
            ev.flow = Flow.Return;
            return e;
        }
        case NodeKind.Return, NodeKind.Break, NodeKind.Continue: {   // `x ?? return 0`
            exec(ev, node);
            return newValue(ComptimeValueKind.Void);
        }
        case NodeKind.Unreachable: {
            fail(ev, node, "reached unreachable code at compile time");
            return newValue(ComptimeValueKind.Undef);
        }
        case NodeKind.ComptimeExpr: return eval(ev, n.a);
        case NodeKind.EnumLiteral: {
            unsupported(ev, node, "union values");
            return newValue(ComptimeValueKind.Undef);
        }
        case NodeKind.Template: {
            unsupported(ev, node, "template strings");
            return newValue(ComptimeValueKind.Undef);
        }
        default: {
            fail(ev, node, `\`${nodeKindName(n.kind)}\` can't run at compile time yet`);
            return newValue(ComptimeValueKind.Undef);
        }
    }
}

/**
 * Evaluates an expression and applies the conversion that the checker decided for it.
 *
 * @param ev - The evaluation
 * @param node - The expression
 * @returns The value, or an `Undef` value when the flow is not `None`
 *
 * @remarks
 * A node that the checker already folded to a constant reads that constant instead of running.
 *
 * @since 1.0.0
 */

function eval(ev: *Evaluation, node: u32): ComptimeValue {
    if (ev.flow != Flow.None) return newValue(ComptimeValueKind.Undef);
    const info = infoOf(ev, node);
    let v = info.value != 0 ? fromValue(ev, info.value) : evalRaw(ev, node);
    if (ev.flow != Flow.None) return v;
    if (info.coerce != 0) v = convert(ev, v, info.type, info.coerce, node, false);
    return v;
}

/**
 * Runs the defers registered since a mark, newest first.
 *
 * @param ev - The evaluation
 * @param mark - The number of defers to keep
 *
 * @remarks
 * An `errdefer` runs only when the scope returns an error, and it can bind that error.
 * The flow, return value, and loop target that left the scope are put back once the defers have run,
 * unless a defer reports an error.
 * After an abort the defers are dropped without running.
 *
 * @since 1.0.0
 */

function runDefers(ev: *Evaluation, mark: u32): void {
    const flow = ev.flow;
    if (flow == Flow.Abort) {
        ev.defersLen = mark;
        return;
    }
    const ret = ev.ret;
    const target = ev.target;
    const failing = flow == Flow.Return && ret.kind == ComptimeValueKind.Error;
    while (ev.defersLen > mark) {
        ev.defersLen -= 1;
        let d: u32 = 0;
        unsafe {
            d = ev.defers![ev.defersLen];
        }
        if (nodeOf(ev, d).kind == NodeKind.Errdefer && !failing) continue;
        ev.flow = Flow.None;
        const locals = ev.localsLen;
        if (nodeOf(ev, d).kind == NodeKind.Errdefer && infoOf(ev, d).symbol != 0) void declare(ev, infoOf(ev, d).symbol, ret);
        exec(ev, nodeOf(ev, d).a);
        ev.localsLen = locals;
        if (ev.flow == Flow.Abort) return;
    }
    ev.flow = flow;
    ev.ret = ret;
    ev.target = target;
}

/**
 * Runs one pass of a loop body.
 *
 * @param ev - The evaluation
 * @param loop - The loop, which `break` and `continue` name as their target
 * @param body - The body
 * @returns `false` when the loop should stop
 *
 * @remarks
 * Each pass counts as a step.
 * A `break` or `continue` that targets another loop leaves the flag set, so the outer loop sees it.
 *
 * @since 1.0.0
 */

function loopBody(ev: *Evaluation, loop: u32, body: u32): bool {
    if (!step(ev, loop)) return false;
    exec(ev, body);
    if (ev.flow == Flow.Break && ev.target == loop) {
        ev.flow = Flow.None;
        return false;
    }
    if (ev.flow == Flow.Continue && ev.target == loop) ev.flow = Flow.None;
    return ev.flow == Flow.None;
}

/**
 * Checks whether a switch pattern matches a value.
 *
 * @param ev - The evaluation
 * @param pat - The pattern
 * @param subject - The value
 * @returns `true` when it matches
 *
 * @remarks
 * A value pattern compares with `==`, a range checks the bounds, and a binding declares the value.
 * Union patterns and bindings by pointer can't run at compile time yet.
 *
 * @since 1.0.0
 */

function matches(ev: *Evaluation, pat: u32, subject: ComptimeValue): bool {
    const p = nodeOf(ev, pat);
    switch (p.kind) {
        case NodeKind.PatternValue: {
            if ((infoOf(ev, pat).flags & HxInfoUnionInit) == 0) return equal(ev, subject, eval(ev, p.a), pat);
        }
        case NodeKind.PatternRange: {
            const lo = eval(ev, p.a);
            const hi = eval(ev, p.b);
            if (ev.flow != Flow.None || !expectKind(ev, subject, ComptimeValueKind.Int, pat)) return false;
            return subject.i >= lo.i && ((p.flags & FlagInclusive) != 0 ? subject.i <= hi.i : subject.i < hi.i);
        }
        case NodeKind.PatternBind: {
            if ((p.flags & FlagPointer) == 0) {
                if (infoOf(ev, pat).symbol != 0) void declare(ev, infoOf(ev, pat).symbol, subject);
                return true;
            }
        }
        default: {}
    }
    unsupported(ev, pat, "this pattern");
    return false;
}

/**
 * Runs a switch.
 *
 * @param ev - The evaluation
 * @param node - The switch
 * @param wantValue - Whether the switch is an expression, so that a case body gives its value
 * @returns The value of the chosen case for a switch expression, and `Void` otherwise
 *
 * @remarks
 * The first case with a matching pattern and a true guard runs, and the default case runs when none does.
 * When no case runs it reports that no case matches the value.
 * In a switch statement an empty case runs the next one, as in `case 1: case 2: ...`.
 *
 * @since 1.0.0
 */

function switchOf(ev: *Evaluation, node: u32, wantValue: bool): ComptimeValue {
    const n = nodeOf(ev, node);
    const cases = record<HxRange>(ev.sema.ast!, n.b);
    const subject = eval(ev, n.a);
    if (ev.flow != Flow.None) return subject;
    const count = cases.end - cases.start;
    let chosen: i32 = -1;
    let fallback: i32 = -1;
    const mark = ev.localsLen;
    for (const i of 0..count) {
        if (chosen >= 0 || ev.flow != Flow.None) break;
        const cn = nodeOf(ev, extraOf(ev, cases.start + i));
        if (cn.kind == NodeKind.DefaultCase) {
            fallback = i as i32;
            continue;
        }
        const data = record<HxCaseData>(ev.sema.ast!, cn.a);
        for (const j of data.patternsStart..data.patternsEnd) {
            if (chosen >= 0 || ev.flow != Flow.None) break;
            ev.localsLen = mark;
            if (!matches(ev, extraOf(ev, j), subject)) continue;
            if (data.guard != 0) {
                const ok = eval(ev, data.guard);
                if (ev.flow != Flow.None || !expectKind(ev, ok, ComptimeValueKind.Bool, data.guard) || !ok.b) continue;
            }
            chosen = i as i32;
        }
    }
    if (ev.flow != Flow.None) return subject;
    if (chosen < 0) chosen = fallback;
    if (chosen < 0) {
        ev.localsLen = mark;
        fail(ev, node, "no case matches this value at compile time");
        return subject;
    }
    let result = newValue(ComptimeValueKind.Void);
    for (const i of (chosen as u32)..count) {
        const cn = nodeOf(ev, extraOf(ev, cases.start + i));
        const body = cn.kind == NodeKind.DefaultCase ? cn.a : record<HxCaseData>(ev.sema.ast!, cn.a).body;
        const stacked = !wantValue && nodeOf(ev, body).kind == NodeKind.Block && nodeOf(ev, body).a == nodeOf(ev, body).b && i + 1 < count;
        if (stacked) continue;   // `case 1: case 2: ...` - an empty case runs the next one
        if (wantValue && nodeOf(ev, body).kind != NodeKind.Block) result = eval(ev, body);
        else exec(ev, body);
        break;
    }
    ev.localsLen = mark;
    return result;
}

/**
 * Registers a `defer` or `errdefer` to run when its scope ends.
 *
 * @param ev - The evaluation
 * @param node - The `defer` or `errdefer` statement
 *
 * @remarks
 * The defers run in reverse order when their scope ends,
 * and each scope remembers the length of the list so that it runs only its own.
 *
 * @since 1.0.0
 */

function pushDefer(ev: *Evaluation, node: u32): void {
    unsafe {
        if (ev.defersLen == ev.defersCap) hxVecGrowImpl(@ptrCast(*?u8[*], &ev.defers), &ev.defersCap, ev.defersLen + 1, 4);
        ev.defers![ev.defersLen] = node;
    }
    ev.defersLen += 1;
}

/**
 * Runs a statement.
 *
 * @param ev - The evaluation
 * @param node - The statement, where 0 does nothing
 *
 * @remarks
 * A block drops its locals and runs its defers at its end.
 * Declarations and assignments store deep copies,
 * and a compound assignment or an increment goes through the same checks as the operator.
 * `return`, `break`, and `continue` set the flow, and loops count each pass as a step.
 *
 * @since 1.0.0
 */

function exec(ev: *Evaluation, node: u32): void {
    if (node == 0 || ev.flow != Flow.None) return;
    const n = nodeOf(ev, node);
    switch (n.kind) {
        case NodeKind.Block: {
            const locals = ev.localsLen;
            const defers = ev.defersLen;
            for (const i of n.a..n.b) {
                if (ev.flow != Flow.None) break;
                exec(ev, extraOf(ev, i));
            }
            runDefers(ev, defers);
            ev.localsLen = locals;
        }
        case NodeKind.UnsafeBlock, NodeKind.ComptimeBlock: exec(ev, n.a);
        case NodeKind.Const, NodeKind.Let: {
            const sym = infoOf(ev, node).symbol;
            if (sym == 0) return;
            const type = symbolOf(ev, sym).type;
            let v = n.b != 0 ? eval(ev, n.b) : newValue(ComptimeValueKind.Undef);
            if (ev.flow != Flow.None) return;
            if (v.kind == ComptimeValueKind.Undef) v = undefinedOf(ev, type);
            void declare(ev, sym, v);
        }
        case NodeKind.ExprStmt: {
            if (nodeOf(ev, n.a).kind == NodeKind.Switch) void switchOf(ev, n.a, false);
            else void eval(ev, n.a);
        }
        case NodeKind.Assign: {
            const target = place(ev, n.a);
            const v = eval(ev, n.b);
            if (ev.flow != Flow.None || target == null) return;
            const slot = target;
            const type = infoOf(ev, n.a).type;
            const op = @enumFromInt(BinOp, n.op);
            if (op == BinOp.None) {
                *slot = v.kind == ComptimeValueKind.Undef ? undefinedOf(ev, type) : copy(ev, v);
                return;
            }
            const old = *slot;
            if (old.kind == ComptimeValueKind.Undef) {
                fail(ev, n.a, "this reads an undefined value at compile time");
                return;
            }
            if (old.kind == ComptimeValueKind.Float || v.kind == ComptimeValueKind.Float) {
                const x = asFloat(old);
                const y = asFloat(v);
                const r = op == BinOp.Add ? x + y : op == BinOp.Sub ? x - y : op == BinOp.Mul ? x * y : x / y;
                *slot = cvFloat(typeOf(ev, type).bits == 32 ? (r as f32) as f64 : r);
                return;
            }
            if (!expectKind(ev, v, ComptimeValueKind.Int, n.b)) return;
            const r = intOp(ev, node, op, old.i, v.i, type);
            if (ev.flow == Flow.None) *slot = r;
        }
        case NodeKind.Increment, NodeKind.Decrement: {
            const slot = place(ev, n.a);
            if (slot == null || !expectKind(ev, *slot, ComptimeValueKind.Int, n.a)) return;
            const r = intOp(ev, node, n.kind == NodeKind.Increment ? BinOp.Add : BinOp.Sub, slot.i, 1, infoOf(ev, n.a).type);
            if (ev.flow == Flow.None) *slot = r;
        }
        case NodeKind.Return: {
            const v = n.a != 0 ? eval(ev, n.a) : newValue(ComptimeValueKind.Void);
            if (ev.flow != Flow.None) return;
            ev.ret = v;
            ev.flow = Flow.Return;
        }
        case NodeKind.Break, NodeKind.Continue: {
            ev.target = infoOf(ev, node).symbol;
            ev.flow = n.kind == NodeKind.Break ? Flow.Break : Flow.Continue;
        }
        case NodeKind.If: {
            const data = record<HxIfData>(ev.sema.ast!, n.a);
            const c = eval(ev, data.condition);
            if (ev.flow != Flow.None) return;
            let taken = false;
            const mark = ev.localsLen;
            if (data.captureToken != NoToken) {   // `if (const v = optional)`
                taken = c.kind != ComptimeValueKind.Null;
                if (taken && infoOf(ev, node).symbol != 0) void declare(ev, infoOf(ev, node).symbol, c);
            } else {
                if (!expectKind(ev, c, ComptimeValueKind.Bool, data.condition)) return;
                taken = c.b;
            }
            if (taken) exec(ev, data.thenBranch);
            else exec(ev, data.elseBranch);
            ev.localsLen = mark;
        }
        case NodeKind.While: {
            const data = record<HxWhileData>(ev.sema.ast!, n.a);
            while (true) {
                const c = eval(ev, data.condition);
                if (ev.flow != Flow.None) return;
                const mark = ev.localsLen;
                if (data.captureToken != NoToken) {
                    if (c.kind == ComptimeValueKind.Null) return;
                    if (infoOf(ev, node).symbol != 0) void declare(ev, infoOf(ev, node).symbol, c);
                } else {
                    if (!expectKind(ev, c, ComptimeValueKind.Bool, data.condition) || !c.b) return;
                }
                const more = loopBody(ev, node, data.body);
                ev.localsLen = mark;
                if (!more) return;
            }
        }
        case NodeKind.For: {
            const data = record<HxForData>(ev.sema.ast!, n.a);
            const mark = ev.localsLen;
            exec(ev, data.init);
            while (true) {
                if (data.condition != 0) {
                    const c = eval(ev, data.condition);
                    if (ev.flow != Flow.None || !expectKind(ev, c, ComptimeValueKind.Bool, data.condition) || !c.b) break;
                }
                if (!loopBody(ev, node, data.body)) break;
                exec(ev, data.step);
            }
            ev.localsLen = mark;
        }
        case NodeKind.ForOf: forOf(ev, node);
        case NodeKind.Defer, NodeKind.Errdefer: pushDefer(ev, node);
        case NodeKind.Switch: void switchOf(ev, node, false);
        case NodeKind.Throw: void evalRaw(ev, node);
        default: void eval(ev, node);
    }
}

/**
 * Runs a `for of` loop.
 *
 * @param ev - The evaluation
 * @param node - The loop
 *
 * @remarks
 * - **A range** gives each integer in it.
 * - **An iterator** calls its `next()` until it returns `null`, with the receiver by value, by address,
 *   or through a pointer as the checker decided.
 * - **An array, slice, or string** gives each element.
 *
 * The optional index variable takes the symbol after the item's, and counts from 0.
 *
 * @since 1.0.0
 */

function forOf(ev: *Evaluation, node: u32): void {
    const n = nodeOf(ev, node);
    const data = record<HxForOfData>(ev.sema.ast!, n.a);
    const item = infoOf(ev, node).symbol;
    const hasIndex = data.indexToken != NoToken;
    const mark = ev.localsLen;
    if (nodeOf(ev, data.iterable).kind == NodeKind.Range) {
        const range = nodeOf(ev, data.iterable);
        const lo = eval(ev, range.a);
        const hi = eval(ev, range.b);
        if (ev.flow != Flow.None || !expectKind(ev, lo, ComptimeValueKind.Int, range.a) || !expectKind(ev, hi, ComptimeValueKind.Int, range.b)) return;
        const end = hi.i + ((range.flags & FlagInclusive) != 0 ? 1 : 0);
        let i = lo.i;
        let k: i128 = 0;
        while (i < end) {
            void declare(ev, item, cvInt(i));
            if (hasIndex) void declare(ev, item + 1, cvInt(k));
            const more = loopBody(ev, node, data.body);
            ev.localsLen = mark;
            if (!more) break;
            i += 1;
            k += 1;
        }
        return;
    }
    const info = infoOf(ev, node);
    if ((info.flags & HxInfoIterator) != 0) {   // `next()` until it returns null
        if ((info.flags & HxInfoDyn) != 0) {
            unsupported(ev, data.iterable, "calls through `dyn`");
            return;
        }
        let self = newValue(ComptimeValueKind.Ptr);
        if ((info.flags & HxInfoDeref) != 0) {
            self = eval(ev, data.iterable);
            if (ev.flow != Flow.None || !expectKind(ev, self, ComptimeValueKind.Ptr, data.iterable)) return;
        } else if ((info.flags & HxInfoReceiverAddr) != 0) {
            self.target = place(ev, data.iterable);
            if (ev.flow != Flow.None || self.target == null) return;
        } else {
            const v = eval(ev, data.iterable);
            if (ev.flow != Flow.None) return;
            const target = slotOf(ev);
            *target = copy(ev, v);
            self.target = target;
        }
        let k: i128 = 0;
        while (true) {
            const args: ComptimeValue[1] = [self];
            const next = call(ev, info.aux, &args, data.iterable);
            if (ev.flow != Flow.None || next.kind == ComptimeValueKind.Null) break;
            void declare(ev, item, next);
            if (hasIndex) void declare(ev, item + 1, cvInt(k));
            const more = loopBody(ev, node, data.body);
            ev.localsLen = mark;
            if (!more) break;
            k += 1;
        }
        return;
    }
    let seq: Sequence = undefined;
    if (!sequence(ev, data.iterable, &seq)) return;
    for (const i of 0..seq.len) {
        void declare(ev, item, element(&seq, i as u64));
        if (hasIndex) void declare(ev, item + 1, cvInt(i as i128));
        const more = loopBody(ev, node, data.body);
        ev.localsLen = mark;
        if (!more) break;
    }
}

/**
 * Starts an evaluation.
 *
 * @param host - The checker's hooks
 * @param root - The `comptime` node being evaluated, which notes point at
 * @param instance - The generic instance whose node information is current
 * @returns The evaluation, without locals, defers, or steps yet
 *
 * @remarks
 * The evaluation starts with an empty arena of its own and borrows the checker state from the hooks.
 * Pair each call with `dispose`, which releases what the evaluation allocated.
 *
 * @since 1.0.0
 */

function make(host: readonly *HxEvalHost, root: u32, instance: u32): Evaluation {
    return Evaluation {
        host, sema: host.sema!, arena: HxArena { head: null }, instance, locals: null, localsLen: 0, localsCap: 0,
        frameBase: 0, defers: null, defersLen: 0, defersCap: 0, flow: Flow.None, ret: newValue(ComptimeValueKind.Undef), target: 0,
        steps: 0, depth: 0, root,
    };
}

/**
 * Releases what an evaluation allocated.
 *
 * @param ev - The evaluation
 *
 * @remarks
 * Every value lives in the evaluation's arena, which this drops with the lists of locals and defers.
 *
 * @since 1.0.0
 */

function dispose(ev: *Evaluation): void {
    unsafe {
        free(@ptrCast(?u8[*], ev.locals));
        free(@ptrCast(?u8[*], ev.defers));
    }
    hxArenaFree(&ev.arena);
}

/**
 * Runs a checked expression at compile time and keeps its value for the program.
 *
 * @param host - The checker's hooks, which check the body of a function before it runs
 * @param node - The checked expression
 * @param instance - The generic instance whose node information is current
 * @returns The value's index, {@link EvalVoid} for `void`, or 0 after reporting an error
 *
 * @remarks
 * This is the compile-time interpreter behind `comptime`.
 * It runs checked code, the tree plus the checker's node information, the same way codegen does,
 * so every type and conversion was already decided.
 * What would be a runtime panic, such as an overflow, an index out of bounds, or `@panic`,
 * is reported as a compile error at the line that caused it.
 * A `return` or `throw` that would leave the expression is an error.
 *
 * @example
 * ```hx
 * // const FIB = comptime fib(10);
 * const v = hxEvalExpr(&host, operand, c.instance); // the index of the value 55
 * ```
 *
 * @see hxEvalBlock
 * @since 1.0.0
 */

export extern "C" function hxEvalExpr(host: readonly *HxEvalHost, node: u32, instance: u32): u32 {
    let ev = make(host, node, instance);
    const v = eval(&ev, node);
    let result: u32 = 0;
    if (ev.flow == Flow.Return) {
        fail(&ev, node, "`return` and `throw` can't leave a `comptime` expression");
    } else if (ev.flow == Flow.None) {
        const info = infoOf(&ev, node);
        result = toValue(&ev, v, info.coerce != 0 ? info.coerce : info.type, node);
    }
    dispose(&ev);
    return result;
}

/**
 * Runs a checked block at compile time.
 *
 * @param host - The checker's hooks, which check the body of a function before it runs
 * @param block - The checked block
 * @param instance - The generic instance whose node information is current
 * @returns `true` when the block ran to its end, and `false` after reporting an error
 *
 * @remarks
 * A `comptime { }` block runs this way, so that `@compileError` inside it can stop the build.
 * A block that returns or throws is an error.
 *
 * @example
 * ```hx
 * // comptime { if (@sizeOf(Header) != 16) @compileError("Header must be 16 bytes"); }
 * hxEvalBlock(&host, block, c.instance); // true when Header is 16 bytes
 * ```
 *
 * @see hxEvalExpr
 * @since 1.0.0
 */

export extern "C" function hxEvalBlock(host: readonly *HxEvalHost, block: u32, instance: u32): bool {
    let ev = make(host, block, instance);
    exec(&ev, block);
    const ok = ev.flow == Flow.None;
    if (ev.flow == Flow.Return) fail(&ev, block, "a `comptime` block can't `return` or `throw`");
    dispose(&ev);
    return ok;
}
