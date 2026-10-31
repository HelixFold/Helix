/**
 * Imports
 */

import { HxEvalHost, HxSema } from "@structs/sema.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { ComptimeValueKind, Flow } from "@modules/sema/constants/eval.constant";

/**
 * A value in the compile-time interpreter.
 *
 * @remarks
 * Scalars live inline, and arrays and structs keep their elements in `elems`.
 * Which fields mean something depends on the {@link ComptimeValueKind}.
 * Every value lives in the evaluation's arena, which is dropped when the evaluation ends.
 *
 * @example
 * ```hx
 * const v = cvInt(3);
 * v.i; // 3
 * ```
 *
 * @see ComptimeValueKind
 * @since 1.0.0
 */

export struct ComptimeValue {
    /**
     * The kind of value, which decides the fields it uses.
     *
     * @example
     * ```hx
     * v.kind; // ComptimeValueKind.Int
     * ```
     *
     * @since 1.0.0
     */

    kind: ComptimeValueKind,

    /**
     * The boolean of a `Bool` value.
     *
     * @example
     * ```hx
     * cvBool(true).b; // true
     * ```
     *
     * @since 1.0.0
     */

    b: bool,

    /**
     * The integer of an `Int` value, the code of an `Error`, or the symbol of a `Func`.
     *
     * @example
     * ```hx
     * cvInt(3).i; // 3
     * ```
     *
     * @since 1.0.0
     */

    i: i128,

    /**
     * The number of a `Float` value.
     *
     * @example
     * ```hx
     * cvFloat(0.5).f; // 0.5
     * ```
     *
     * @since 1.0.0
     */

    f: f64,

    /**
     * The read-only text of a `Bytes` value.
     *
     * @example
     * ```hx
     * v.bytes; // the bytes of "few"
     * ```
     *
     * @since 1.0.0
     */

    bytes: ?readonly u8[*],

    /**
     * The length of a `Bytes` or `Slice` value.
     *
     * @example
     * ```hx
     * v.len; // 3 for "few"
     * ```
     *
     * @since 1.0.0
     */

    len: u32,

    /**
     * The first element of a `Slice` within its target array.
     *
     * @example
     * ```hx
     * v.start; // 1 for a[1..3]
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The number of elements of an `Agg` value.
     *
     * @example
     * ```hx
     * v.count; // 2 for a struct with two fields
     * ```
     *
     * @since 1.0.0
     */

    count: u32,

    /**
     * The elements of an `Agg` value, as array elements or struct fields in field order.
     *
     * @example
     * ```hx
     * v.elems; // [1, 2, 3] as values
     * ```
     *
     * @since 1.0.0
     */

    elems: ?ComptimeValue[*],

    /**
     * The value that a `Ptr` points to, or the array that a `Slice` views.
     *
     * @example
     * ```hx
     * v.target; // the storage of x for &x
     * ```
     *
     * @since 1.0.0
     */

    target: ?*ComptimeValue,
}

/**
 * A local of a function that runs at compile time, with its storage.
 *
 * @remarks
 * Locals form a stack, and a call starts a frame at the current length,
 * so `findLocal` sees only the locals of the current call.
 *
 * @example
 * ```hx
 * const slot = declare(ev, sym, cvInt(1));
 * findLocal(ev, sym); // slot
 * ```
 *
 * @see declare
 * @since 1.0.0
 */

export struct Local {
    /**
     * The symbol of the local.
     *
     * @example
     * ```hx
     * local.sym; // the symbol of x
     * ```
     *
     * @since 1.0.0
     */

    sym: u32,

    /**
     * The storage of the local's value.
     *
     * @example
     * ```hx
     * *local.slot; // the current value of x
     * ```
     *
     * @since 1.0.0
     */

    slot: *ComptimeValue,
}

/**
 * The state of one compile-time evaluation.
 *
 * @remarks
 * Each call to {@link hxEvalExpr} or {@link hxEvalBlock} makes one, runs the code, and releases it.
 * Locals and defers form stacks that calls and blocks cut back when they end.
 *
 * @example
 * ```hx
 * let ev = make(host, node, instance);
 * const v = eval(&ev, node);
 * dispose(&ev);
 * ```
 *
 * @see hxEvalExpr
 * @since 1.0.0
 */

export struct Evaluation {
    /**
     * The checker's hooks, which check the body of a function before it runs.
     *
     * @example
     * ```hx
     * ev.host.ensureBody!(ev.host.user, sym); // true when the body checked
     * ```
     *
     * @since 1.0.0
     */

    host: readonly *HxEvalHost,

    /**
     * The checker state, with the tree, the types, the symbols, and the values.
     *
     * @example
     * ```hx
     * ev.sema.diags; // where the evaluation reports its errors
     * ```
     *
     * @since 1.0.0
     */

    sema: *HxSema,

    /**
     * The arena that holds every value of the evaluation, dropped when it ends.
     *
     * @example
     * ```hx
     * hxArenaFree(&ev.arena); // in dispose
     * ```
     *
     * @since 1.0.0
     */

    arena: HxArena,

    /**
     * The generic instance whose node information is current.
     *
     * @example
     * ```hx
     * ev.instance; // the instance of the function that runs now
     * ```
     *
     * @since 1.0.0
     */

    instance: u32,

    /**
     * The stack of locals, newest last.
     *
     * @example
     * ```hx
     * ev.locals; // the locals of every call that runs
     * ```
     *
     * @since 1.0.0
     */

    locals: ?Local[*],

    /**
     * The number of locals on the stack.
     *
     * @example
     * ```hx
     * ev.localsLen = mark; // a block drops its locals
     * ```
     *
     * @since 1.0.0
     */

    localsLen: u32,

    /**
     * The number of locals that the stack has room for.
     *
     * @example
     * ```hx
     * ev.localsCap; // grows as locals are declared
     * ```
     *
     * @since 1.0.0
     */

    localsCap: u32,

    /**
     * The first local of the current call, since the locals below it belong to callers.
     *
     * @example
     * ```hx
     * ev.frameBase; // equals ev.localsLen when a call starts
     * ```
     *
     * @since 1.0.0
     */

    frameBase: u32,

    /**
     * The stack of registered `defer` and `errdefer` statements.
     *
     * @example
     * ```hx
     * ev.defers; // run newest first when their block ends
     * ```
     *
     * @since 1.0.0
     */

    defers: ?u32[*],

    /**
     * The number of registered defers.
     *
     * @example
     * ```hx
     * ev.defersLen; // 2 inside { defer a(); defer b(); }
     * ```
     *
     * @since 1.0.0
     */

    defersLen: u32,

    /**
     * The number of defers that the stack has room for.
     *
     * @example
     * ```hx
     * ev.defersCap; // grows as defers are registered
     * ```
     *
     * @since 1.0.0
     */

    defersCap: u32,

    /**
     * The way control is leaving the code that runs.
     *
     * @example
     * ```hx
     * ev.flow; // Flow.None while the code runs on
     * ```
     *
     * @since 1.0.0
     */

    flow: Flow,

    /**
     * The returned value while the flow is `Return`, an `Error` value when the call returns an error.
     *
     * @example
     * ```hx
     * ev.ret; // 55 after return 55
     * ```
     *
     * @since 1.0.0
     */

    ret: ComptimeValue,

    /**
     * The loop that a `break` or `continue` leaves while the flow is `Break` or `Continue`.
     *
     * @example
     * ```hx
     * ev.target; // the outer loop for continue outer
     * ```
     *
     * @since 1.0.0
     */

    target: u32,

    /**
     * The number of steps taken, which {@link MaxSteps} bounds.
     *
     * @example
     * ```hx
     * ev.steps; // 10 after a loop of ten passes
     * ```
     *
     * @since 1.0.0
     */

    steps: u64,

    /**
     * The number of calls that run, which {@link MaxDepth} bounds.
     *
     * @example
     * ```hx
     * ev.depth; // 1 inside the first call
     * ```
     *
     * @since 1.0.0
     */

    depth: u32,

    /**
     * The `comptime` node being evaluated, which the note on an error points at.
     *
     * @example
     * ```hx
     * ev.root; // the node of comptime fib(10)
     * ```
     *
     * @since 1.0.0
     */

    root: u32,
}

/**
 * The array or string that a value indexes into, with its first element and length.
 *
 * @remarks
 * Indexing, slicing, and `for of` all read their elements through it,
 * so an array, a pointer to one, a slice, and a string look the same to them.
 *
 * @example
 * ```hx
 * let seq: Sequence = undefined;
 * sequence(ev, base, &seq); // seq.len is 3 for an i32[3]
 * ```
 *
 * @see sequence
 * @since 1.0.0
 */

export struct Sequence {
    /**
     * The array, an aggregate value, or `null` for the bytes of a string.
     *
     * @example
     * ```hx
     * seq.array; // null for a string
     * ```
     *
     * @since 1.0.0
     */

    array: ?*ComptimeValue,

    /**
     * The bytes of a string, when the array is `null`.
     *
     * @example
     * ```hx
     * seq.bytes; // the text of "abc"
     * ```
     *
     * @since 1.0.0
     */

    bytes: ?readonly u8[*],

    /**
     * The index of the first element within the array.
     *
     * @example
     * ```hx
     * seq.start; // 1 for a[1..3]
     * ```
     *
     * @since 1.0.0
     */

    start: u32,

    /**
     * The number of elements.
     *
     * @example
     * ```hx
     * seq.len; // 2 for a[1..3]
     * ```
     *
     * @since 1.0.0
     */

    len: u32,
}
