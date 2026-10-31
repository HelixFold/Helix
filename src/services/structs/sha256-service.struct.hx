/**
 * The running state of one SHA-256 digest.
 *
 * @remarks
 * Feed it bytes in any number of pieces, and the digest comes out the same as for one piece holding them all.
 * The package manager uses it to hash packages.
 *
 * @example
 * ```hx
 * let s: HxSha256 = undefined;
 * hxSha256Init(&s);
 * hxSha256Update(&s, "abc", 3);
 * let digest: u8[32] = undefined;
 * hxSha256Finish(&s, &digest);
 * ```
 *
 * @see hxSha256Init
 * @see hxSha256Update
 * @see hxSha256Finish
 *
 * @since 1.0.0
 */

export extern "C" struct HxSha256 {
    /**
     * The eight working words of the hash.
     *
     * @example
     * ```hx
     * s.state[0]; // 0x6a09e667 before any block is compressed
     * ```
     *
     * @since 1.0.0
     */

    state: u32[8],

    /**
     * The number of bytes fed so far.
     *
     * @example
     * ```hx
     * s.length; // 3 after 'abc'
     * ```
     *
     * @since 1.0.0
     */

    length: u64,

    /**
     * The 64-byte block that collects bytes until it is full.
     *
     * @example
     * ```hx
     * s.block[0..s.used]; // the bytes waiting for compression
     * ```
     *
     * @since 1.0.0
     */

    block: u8[64],

    /**
     * The number of bytes waiting in the block.
     *
     * @example
     * ```hx
     * s.used; // 3 after 'abc'
     * ```
     *
     * @since 1.0.0
     */

    used: u32,
}
