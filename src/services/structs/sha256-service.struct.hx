/**
 * The running state of one SHA-256 digest.
 *
 * @remarks
 * Feed it bytes in any number of pieces, and the digest comes out the same as for one piece holding them all.
 * The package manager uses it to hash packages.
 *
 * @example
 * ```ts
 * let s: HxSha256 = undefined;
 * hx_sha256_init(&s);
 * hx_sha256_update(&s, "abc", 3);
 * let digest: u8[32] = undefined;
 * hx_sha256_finish(&s, &digest);
 * ```
 *
 * @see hx_sha256_init
 * @see hx_sha256_update
 * @see hx_sha256_finish
 *
 * @since 1.0.0
 */

export extern "C" struct HxSha256 {
    /**
     * The eight working words of the hash.
     *
     * @example
     * ```ts
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
     * ```ts
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
     * ```ts
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
     * ```ts
     * s.used; // 3 after 'abc'
     * ```
     *
     * @since 1.0.0
     */

    used: u32,
}
