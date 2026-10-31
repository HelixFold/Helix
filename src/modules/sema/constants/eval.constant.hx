/**
 * The number of loop iterations and calls that one compile-time evaluation may take.
 *
 * @remarks
 * Every call and every pass through a loop body counts as one step.
 * Past the limit the evaluation stops with an error and a hint that asks whether a loop is endless,
 * since compile-time work this big is better done at runtime.
 *
 * @example
 * ```hx
 * // const B = comptime forever();
 * MaxSteps; // 1000000, after which the evaluation reports an error
 * ```
 *
 * @since 1.0.0
 */

export const MaxSteps: u64 = 1000000;

/**
 * The deepest that compile-time calls may nest.
 *
 * @remarks
 * A call that would go deeper reports `compile-time calls nest more than 200 deep` and stops the evaluation.
 * The interpreter keeps only the Helix call stack on the machine stack, so this limit also bounds its recursion.
 *
 * @example
 * ```hx
 * MaxDepth; // 200
 * ```
 *
 * @since 1.0.0
 */

export const MaxDepth: u32 = 200;

/**
 * The result of {@link hxEvalExpr} for an expression of type `void` or `noreturn`.
 *
 * @remarks
 * Such an expression has no value to keep, so the result is neither a value index nor the 0 that marks an error.
 *
 * @example
 * ```hx
 * hxEvalExpr(host, node, 0); // EvalVoid for a call to a function that returns void
 * ```
 *
 * @since 1.0.0
 */

export const EvalVoid: u32 = 0xFFFF_FFFF;

/**
 * The kind of value that the compile-time interpreter holds in a {@link ComptimeValue}.
 *
 * @remarks
 * Each kind uses only some of the fields of a {@link ComptimeValue}, as each member describes.
 * Values that can live in the binary convert back to an `HxValue` at the end of an evaluation,
 * while a pointer only exists while the compiler evaluates.
 *
 * @example
 * ```hx
 * cvInt(3).kind; // ComptimeValueKind.Int
 * ```
 *
 * @see ComptimeValue
 * @since 1.0.0
 */

export enum ComptimeValueKind: u8 {
    /**
     * A value that the program has not given yet, such as a local declared `= undefined`.
     *
     * @remarks
     * Reading one in an operation reports `this reads an undefined value at compile time`.
     *
     * @example
     * ```hx
     * newValue(ComptimeValueKind.Undef); // the value of let x: i32 = undefined
     * ```
     *
     * @since 1.0.0
     */

    Undef,

    /**
     * The value of an expression or call that produces nothing.
     *
     * @example
     * ```hx
     * newValue(ComptimeValueKind.Void); // the result of a call to a void function
     * ```
     *
     * @since 1.0.0
     */

    Void,

    /**
     * An integer or an enum value, held in the `i` field.
     *
     * @example
     * ```hx
     * cvInt(42).i; // 42
     * ```
     *
     * @since 1.0.0
     */

    Int,

    /**
     * A floating-point value, held in the `f` field.
     *
     * @example
     * ```hx
     * cvFloat(1.5).f; // 1.5
     * ```
     *
     * @since 1.0.0
     */

    Float,

    /**
     * A boolean value, held in the `b` field.
     *
     * @example
     * ```hx
     * cvBool(true).b; // true
     * ```
     *
     * @since 1.0.0
     */

    Bool,

    /**
     * A string, read-only, with its text in `bytes` and its length in `len`.
     *
     * @example
     * ```hx
     * // "few"
     * value.len; // 3
     * ```
     *
     * @since 1.0.0
     */

    Bytes,

    /**
     * The `null` of an optional.
     *
     * @example
     * ```hx
     * newValue(ComptimeValueKind.Null); // the value of return null
     * ```
     *
     * @since 1.0.0
     */

    Null,

    /**
     * An error code, held in the `i` field.
     *
     * @remarks
     * A `throw` sets the thrown value to this kind and returns it,
     * so `try` and `catch` can tell an error from a result.
     *
     * @example
     * ```hx
     * // throw ParseError.Bad;
     * ev.ret.kind; // ComptimeValueKind.Error
     * ```
     *
     * @since 1.0.0
     */

    Error,

    /**
     * A function, held as its symbol in the `i` field.
     *
     * @example
     * ```hx
     * // const f = double;
     * value.i; // the symbol of double
     * ```
     *
     * @since 1.0.0
     */

    Func,

    /**
     * The elements of an array or the fields of a struct, in `elems`, with their number in `count`.
     *
     * @example
     * ```hx
     * // [1, 2, 3]
     * value.count; // 3
     * ```
     *
     * @since 1.0.0
     */

    Agg,

    /**
     * A pointer to the value in `target`.
     *
     * @remarks
     * A pointer works while the compiler evaluates, but it can't be kept for the program.
     *
     * @example
     * ```hx
     * // &x
     * value.target; // the slot of x
     * ```
     *
     * @since 1.0.0
     */

    Ptr,

    /**
     * The `len` elements of the array in `target`, starting at `start`.
     *
     * @example
     * ```hx
     * // a[1..3]
     * value.start; // 1
     * ```
     *
     * @since 1.0.0
     */

    Slice,
}

/**
 * The way control leaves the code that the interpreter runs.
 *
 * @remarks
 * Control flow is a flag that every step checks rather than a jump on the machine stack,
 * so the machine stack only ever holds the Helix call stack.
 * Each step returns early when the flag is not `None`, and the loop, call, or entry point that it targets clears it.
 *
 * @example
 * ```hx
 * ev.flow; // Flow.Return after return 1;
 * ```
 *
 * @since 1.0.0
 */

export enum Flow {
    /**
     * The code runs on to the next step.
     *
     * @example
     * ```hx
     * ev.flow; // Flow.None between statements
     * ```
     *
     * @since 1.0.0
     */

    None,

    /**
     * A `return` or `throw` leaves the current call, with its value in the `ret` field.
     *
     * @example
     * ```hx
     * ev.flow; // Flow.Return, with ev.ret holding the returned value
     * ```
     *
     * @since 1.0.0
     */

    Return,

    /**
     * A `break` leaves the loop named in the `target` field.
     *
     * @example
     * ```hx
     * ev.flow; // Flow.Break until the loop in ev.target sees it
     * ```
     *
     * @since 1.0.0
     */

    Break,

    /**
     * A `continue` ends the current pass of the loop named in the `target` field.
     *
     * @example
     * ```hx
     * ev.flow; // Flow.Continue until the loop in ev.target sees it
     * ```
     *
     * @since 1.0.0
     */

    Continue,

    /**
     * A compile error was reported, and everything unwinds.
     *
     * @remarks
     * Nothing clears this flag, so the evaluation ends and its entry point returns a failure.
     *
     * @example
     * ```hx
     * ev.flow; // Flow.Abort after an overflow at compile time
     * ```
     *
     * @since 1.0.0
     */

    Abort,
}

/**
 * The largest `i128`, which bounds the integers that the interpreter computes with.
 *
 * @remarks
 * The smallest `i128` is `-I128Max - 1`, which has no positive opposite,
 * so dividing it by -1 counts as an overflow.
 *
 * @example
 * ```hx
 * I128Max; // 2 ** 127 - 1
 * ```
 *
 * @since 1.0.0
 */

export const I128Max: i128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
