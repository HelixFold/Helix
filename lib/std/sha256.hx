/**
 * The 64 round constants of SHA-256.
 *
 * @remarks
 * FIPS 180-4 defines them as the first 32 bits of the fractional parts of the cube roots of the first 64 primes.
 * Round `i` of {@link Sha256.compress} adds constant `i`.
 *
 * @since 1.0.0
 */

const RoundConstants: u32[64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/**
 * The eight words that the state of every new hash starts from.
 *
 * @remarks
 * FIPS 180-4 defines them as the first 32 bits of the fractional parts of the square roots of the first 8 primes.
 *
 * @since 1.0.0
 */

const InitialState: u32[8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];

/**
 * Rotates a word to the right.
 *
 * @param x - The word to rotate
 * @param n - The number of bits to rotate by, from 1 to 31
 * @returns The word with its low `n` bits moved to the top
 *
 * @remarks
 * A count of 0 would shift `x` left by 32, so only call it with the nonzero counts of the SHA-256 rounds.
 *
 * @since 1.0.0
 */

function rotateRight(x: u32, n: u32): u32 {
    return (x >> n) | (x << (32 - n));
}

/**
 * A SHA-256 hasher that takes its input piece by piece.
 *
 * @remarks
 * It follows FIPS 180-4 and gives the same digest as {@link sha256} on the concatenation of every piece,
 * so reach for it when the input arrives in parts, such as a file read in chunks.
 * It buffers up to 63 bytes in `block` and compresses each full block of 64 bytes as soon as it fills.
 * The hasher allocates nothing and keeps all of its state in its own fields.
 *
 * @example
 * ```hx
 * let h = Sha256.init();
 * h.update("a");
 * h.update("bc");
 * const hexDigits = toHex(h.finish());   // "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
 * ```
 *
 * @see sha256
 * @since 1.0.0
 */

export struct Sha256 {
    /**
     * The eight words of the running hash.
     *
     * @remarks
     * Each full block updates them, and {@link Sha256.finish} writes them out big-endian as the digest.
     *
     * @example
     * ```hx
     * Sha256.init().state[0]; // 0x6a09e667
     * ```
     *
     * @since 1.0.0
     */

    state: u32[8],

    /**
     * The number of bytes fed in so far.
     *
     * @remarks
     * It wraps around at 2 to the power of 64, as FIPS 180-4 allows,
     * and {@link Sha256.finish} appends it in bits to the padding.
     *
     * @example
     * ```hx
     * let h = Sha256.init();
     * h.update("abc");
     * h.length; // 3
     * ```
     *
     * @since 1.0.0
     */

    length: u64,

    /**
     * The block of 64 bytes that fills up before each compression.
     *
     * @remarks
     * Only its first `used` bytes hold input, and the rest is left over from earlier blocks or undefined.
     *
     * @example
     * ```hx
     * let h = Sha256.init();
     * h.update("abc");
     * h.block[0]; // 0x61
     * ```
     *
     * @since 1.0.0
     */

    block: u8[64],

    /**
     * The number of bytes waiting in `block`.
     *
     * @remarks
     * It stays below 64 between calls, since a full block compresses at once.
     *
     * @example
     * ```hx
     * let h = Sha256.init();
     * h.update("abc");
     * h.used; // 3
     * ```
     *
     * @since 1.0.0
     */

    used: usize,

    /**
     * Creates a hasher for a new digest.
     *
     * @returns A hasher with the initial state and no input
     *
     * @remarks
     * Call it again for every digest, since {@link Sha256.finish} leaves the hasher used up.
     *
     * @example
     * ```hx
     * let h = Sha256.init();
     * toHex(h.finish()); // "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
     * ```
     *
     * @since 1.0.0
     */

    init(): Sha256 {
        return Sha256 { state: InitialState, length: 0, block: undefined, used: 0 };
    }

    /**
     * Feeds more bytes into the hash.
     *
     * @param this - The hasher to feed
     * @param bytes - The next part of the input
     *
     * @remarks
     * It copies the bytes into `block` and compresses each block of 64 that fills,
     * so splitting the input at any points gives the same digest.
     * An empty slice changes nothing.
     *
     * @example
     * ```hx
     * let h = Sha256.init();
     * h.update("a");
     * h.update("bc");
     * toHex(h.finish()) == toHex(sha256("abc")); // true
     * ```
     *
     * @since 1.0.0
     */

    update(this: *Sha256, bytes: readonly u8[]): void {
        this.length +%= bytes.len as u64;
        let at: usize = 0;
        while (at < bytes.len) {
            const take = 64 - this.used < bytes.len - at ? 64 - this.used : bytes.len - at;
            for (const i of 0..take) this.block[this.used + i] = bytes[at + i];
            this.used += take;
            at += take;
            if (this.used == 64) {
                this.compress();
                this.used = 0;
            }
        }
    }

    /**
     * Pads the input and returns the digest of everything fed in.
     *
     * @param this - The hasher to finish
     * @returns The 32 bytes of the digest
     *
     * @remarks
     * It feeds the padding of FIPS 180-4 through {@link Sha256.update}: a `0x80` byte, zeros up to byte 56 of a block,
     * and the length in bits as 8 big-endian bytes.
     * That padding becomes part of the state, so the hasher is used up afterwards,
     * and the next digest starts again with {@link Sha256.init}.
     *
     * @example
     * ```hx
     * let h = Sha256.init();
     * h.update("abc");
     * h.finish()[0]; // 0xba
     * ```
     *
     * @since 1.0.0
     */

    finish(this: *Sha256): u8[32] {
        const bits = this.length *% 8;
        const one: u8[1] = [0x80];
        const zero: u8[1] = [0];
        this.update(&one);
        while (this.used != 56) this.update(&zero);
        let length: u8[8] = undefined;
        for (const i of 0..8) length[i] = @truncate(u8, bits >> (56 - i * 8) as u64);
        this.update(&length);
        let digest: u8[32] = undefined;
        for (const i of 0..8) {
            digest[i * 4] = @truncate(u8, this.state[i] >> 24);
            digest[i * 4 + 1] = @truncate(u8, this.state[i] >> 16);
            digest[i * 4 + 2] = @truncate(u8, this.state[i] >> 8);
            digest[i * 4 + 3] = @truncate(u8, this.state[i]);
        }
        return digest;
    }

    /**
     * Runs the 64 rounds of SHA-256 on the full block and adds the result to the state.
     *
     * @param this - The hasher whose block to compress
     *
     * @remarks
     * It expands the 16 big-endian words of `block` to 64 words and mixes them into the state,
     * with every addition wrapping as the standard requires.
     * {@link Sha256.update} calls it each time `block` fills, so a caller never needs to.
     * It neither reads nor resets `used`.
     *
     * @example
     * ```hx
     * let h = Sha256.init();
     * h.compress();       // mixes whatever bytes `block` holds into the state
     * h.state[0];         // no longer 0x6a09e667
     * ```
     *
     * @since 1.0.0
     */

    compress(this: *Sha256): void {
        let w: u32[64] = undefined;
        for (const i of 0..16) {
            w[i] = (this.block[i * 4] as u32) << 24 | (this.block[i * 4 + 1] as u32) << 16 |
                   (this.block[i * 4 + 2] as u32) << 8 | (this.block[i * 4 + 3] as u32);
        }
        for (const i of 16..64) {
            const s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
        }
        let a = this.state[0];
        let b = this.state[1];
        let c = this.state[2];
        let d = this.state[3];
        let e = this.state[4];
        let f = this.state[5];
        let g = this.state[6];
        let h = this.state[7];
        for (const i of 0..64) {
            const t1 = h +% (rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)) +% ((e & f) ^ (~e & g)) +% RoundConstants[i] +% w[i];
            const t2 = (rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)) +% ((a & b) ^ (a & c) ^ (b & c));
            h = g;
            g = f;
            f = e;
            e = d +% t1;
            d = c;
            c = b;
            b = a;
            a = t1 +% t2;
        }
        this.state[0] +%= a;
        this.state[1] +%= b;
        this.state[2] +%= c;
        this.state[3] +%= d;
        this.state[4] +%= e;
        this.state[5] +%= f;
        this.state[6] +%= g;
        this.state[7] +%= h;
    }
}

/**
 * Computes the SHA-256 digest of a byte slice in one call.
 *
 * @param bytes - The whole input
 * @returns The 32 bytes of the digest
 *
 * @remarks
 * It runs a {@link Sha256} hasher over the slice, so reach for the hasher itself when the input arrives in parts.
 * Pass the digest to {@link toHex} for the usual text form.
 *
 * @example
 * ```hx
 * const digest = sha256("abc");
 * digest[0];      // 0xba
 * toHex(digest);  // "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
 * ```
 *
 * @see Sha256
 * @since 1.0.0
 */

export function sha256(bytes: readonly u8[]): u8[32] {
    let h = Sha256.init();
    h.update(bytes);
    return h.finish();
}

/**
 * Writes a digest as 64 lowercase hex digits.
 *
 * @param digest - The digest to write out
 * @returns The hex digits, two for each byte of the digest, high half first
 *
 * @remarks
 * The result is a fixed array, so no allocator is involved, and `&result` gives a `string` view of it.
 *
 * @example
 * ```hx
 * const hex = toHex(sha256(""));
 * const text: string = &hex; // "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
 * ```
 *
 * @since 1.0.0
 */

export function toHex(digest: u8[32]): u8[64] {
    const digits = "0123456789abcdef";
    let text: u8[64] = undefined;
    for (const b, i of digest) {
        text[i * 2] = digits[b >> 4];
        text[i * 2 + 1] = digits[b & 15];
    }
    return text;
}
