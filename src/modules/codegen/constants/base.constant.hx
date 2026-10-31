/**
 * The debug build mode: no optimization, with every safety check on.
 *
 * @remarks
 * The build modes follow Zig's.
 *
 * @example
 * ```hx
 * hxModeParse("debug", &mode);
 * mode; // ModeDebug, which is 0
 * ```
 *
 * @see ModeReleaseSafe
 * @since 1.0.0
 */

export const ModeDebug: u32 = 0;

/**
 * The release-safe build mode: optimized, with every safety check on.
 *
 * @example
 * ```hx
 * hxModeParse("release-safe", &mode);
 * mode; // ModeReleaseSafe, which is 1
 * ```
 *
 * @see ModeDebug
 * @since 1.0.0
 */

export const ModeReleaseSafe: u32 = 1;

/**
 * The release-fast build mode: optimized for speed, with the safety checks off.
 *
 * @remarks
 * Overflow and out-of-bounds access are undefined behavior in this mode.
 *
 * @example
 * ```hx
 * hxModeParse("release-fast", &mode);
 * mode; // ModeReleaseFast, which is 2
 * ```
 *
 * @see ModeReleaseSmall
 * @since 1.0.0
 */

export const ModeReleaseFast: u32 = 2;

/**
 * The release-small build mode: optimized for size, with the safety checks off.
 *
 * @example
 * ```hx
 * hxModeParse("release-small", &mode);
 * mode; // ModeReleaseSmall, which is 3
 * ```
 *
 * @see ModeReleaseFast
 * @since 1.0.0
 */

export const ModeReleaseSmall: u32 = 3;

/**
 * The deepest nesting of loops that one function may have, the size of the loop stack of the generator.
 *
 * @example
 * ```hx
 * cg.loops.len; // 64
 * ```
 *
 * @see Loop
 * @since 1.0.0
 */

export const MaxLoops: u32 = 64;
