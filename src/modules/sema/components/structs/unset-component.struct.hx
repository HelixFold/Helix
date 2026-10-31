/**
 * A snapshot of the locals that have no value yet at one point of a function.
 *
 * @remarks
 * Branching code saves one before each branch, then merges the snapshots where the branches meet.
 * The items live on the C heap and are not released, which a single check of a function can afford.
 *
 * @example
 * ```hx
 * const before = saveUnset(c);
 * // check the then branch
 * const a = saveUnset(c);
 * restoreUnset(c, before);
 * // check the else branch
 * mergeUnset(c, before, a, saveUnset(c));
 * ```
 *
 * @see saveUnset
 * @see mergeUnset
 *
 * @since 1.0.0
 */

export struct Unset {
    /**
     * The symbols of the locals without a value.
     *
     * @example
     * ```hx
     * snapshot.items[0]; // the symbol of a local declared = undefined
     * ```
     *
     * @since 1.0.0
     */

    items: u32[*],

    /**
     * The number of symbols in the snapshot.
     *
     * @example
     * ```hx
     * snapshot.len; // 0 once every local has a value
     * ```
     *
     * @since 1.0.0
     */

    len: u32,
}
