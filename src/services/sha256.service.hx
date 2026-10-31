/**
 * Imports
 */

import { K, INITIAL } from "@constants/sha256.constant";
import { HxSha256 } from "@services/structs/sha256-service.struct";

/**
 * Rotates a 32-bit word to the right.
 *
 * @param x - The word to rotate
 * @param n - The number of bits to rotate by, from 1 to 31
 * @returns The rotated word
 */

function rotr(x: u32, n: u32): u32 {
    return (x >> n) | (x << (32 - n));
}

/**
 * Runs the 64 rounds of the compression function over the full block.
 *
 * @param s - The digest state whose block is full
 *
 * @remarks
 * The result is added into the working words, and the block is left for the caller to reset.
 */

function compress(s: *HxSha256): void {
    let w: u32[64] = undefined;
    for (const i of 0..16) {
        w[i] = (s.block[i * 4] as u32) << 24 | (s.block[i * 4 + 1] as u32) << 16 | (s.block[i * 4 + 2] as u32) << 8 |
               (s.block[i * 4 + 3] as u32);
    }
    for (const i of 16..64) {
        const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
    }
    let a = s.state[0];
    let b = s.state[1];
    let c = s.state[2];
    let d = s.state[3];
    let e = s.state[4];
    let f = s.state[5];
    let g = s.state[6];
    let h = s.state[7];
    for (const i of 0..64) {
        const t1 = h +% (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) +% ((e & f) ^ (~e & g)) +% K[i] +% w[i];
        const t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) +% ((a & b) ^ (a & c) ^ (b & c));
        h = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = b;
        b = a;
        a = t1 +% t2;
    }
    s.state[0] +%= a;
    s.state[1] +%= b;
    s.state[2] +%= c;
    s.state[3] +%= d;
    s.state[4] +%= e;
    s.state[5] +%= f;
    s.state[6] +%= g;
    s.state[7] +%= h;
}

/**
 * Starts a new digest.
 *
 * @param s - The state to reset, whose previous contents are ignored
 *
 * @remarks
 * Call it before the first {@link hx_sha256_update}, and again to reuse a state for another digest.
 *
 * @example
 * ```ts
 * let s: HxSha256 = undefined;
 * hx_sha256_init(&s);
 * s.length; // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_sha256_init(s: *HxSha256): void {
    s.state = INITIAL;
    s.length = 0;
    s.used = 0;
}

/**
 * Feeds bytes through the block, compressing it each time it fills.
 *
 * @param s - The digest state
 * @param bytes - The bytes to feed
 */

function feed(s: *HxSha256, bytes: readonly u8[]): void {
    s.length += bytes.len;
    let at: usize = 0;
    while (at < bytes.len) {
        const used = s.used as usize;
        const take = 64 - used < bytes.len - at ? 64 - used : bytes.len - at;
        for (const i of 0..take) s.block[used + i] = bytes[at + i];
        s.used += @truncate(u32, take);
        at += take;
        if (s.used == 64) {
            compress(s);
            s.used = 0;
        }
    }
}

/**
 * Adds bytes to a digest.
 *
 * @param s - The digest state
 * @param data - The first byte to add
 * @param len - The number of bytes to add, where 0 does nothing
 *
 * @remarks
 * Splitting the input across many calls gives the same digest as passing it in one.
 *
 * @example
 * ```ts
 * hx_sha256_update(&s, "ab", 2);
 * hx_sha256_update(&s, "c", 1); // the same digest as 'abc' in one call
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hx_sha256_update(s: *HxSha256, data: readonly u8[*], len: usize): void {
    if (len == 0) return;
    unsafe {
        feed(s, data[0..len]);
    }
}

/**
 * Pads the input and writes the 32-byte digest.
 *
 * @param s - The digest state
 * @param out - The 32 bytes that receive the digest
 *
 * @remarks
 * The state is spent afterwards, so call {@link hx_sha256_init} before using it for another digest.
 *
 * @example
 * ```ts
 * let digest: u8[32] = undefined;
 * hx_sha256_finish(&s, &digest); // digest[0]: 0xba for 'abc'
 * ```
 *
 * @see hx_sha256_hex
 * @since 1.0.0
 */

export extern "C" function hx_sha256_finish(s: *HxSha256, out: u8[*]): void {
    const bits = s.length *% 8;
    feed(s, [0x80]);
    while (s.used != 56) feed(s, [0]);
    let length: u8[8] = undefined;
    for (const i of 0..8) length[i] = @truncate(u8, bits >> (56 - i * 8));
    feed(s, &length);
    let digest: u8[] = [];
    unsafe {
        digest = out[0..32];
    }
    for (const i of 0..8) {
        digest[i * 4] = @truncate(u8, s.state[i] >> 24);
        digest[i * 4 + 1] = @truncate(u8, s.state[i] >> 16);
        digest[i * 4 + 2] = @truncate(u8, s.state[i] >> 8);
        digest[i * 4 + 3] = @truncate(u8, s.state[i]);
    }
}

/**
 * Writes a digest as 64 lowercase hex digits followed by a NUL.
 *
 * @param digest - The 32 bytes of the digest
 * @param out - The 65 bytes that receive the text
 *
 * @example
 * ```ts
 * let hex: u8[65] = undefined;
 * hx_sha256_hex(&digest, &hex); // 'ba7816bf...f20015ad' for 'abc'
 * ```
 *
 * @see hx_sha256_finish
 * @since 1.0.0
 */

export extern "C" function hx_sha256_hex(digest: readonly u8[*], out: u8[*]): void {
    const digits = "0123456789abcdef";
    let bytes: readonly u8[] = [];
    let text: u8[] = [];
    unsafe {
        bytes = digest[0..32];
        text = out[0..65];
    }
    for (const b, i of bytes) {
        text[i * 2] = digits[b >> 4];
        text[i * 2 + 1] = digits[b & 15];
    }
    text[64] = 0;
}
