/**
 * The size in bytes of the data area of a regular arena chunk.
 *
 * @remarks
 * A request larger than this, alignment included, gets a chunk of its own sized to fit.
 *
 * @example
 * ```ts
 * CHUNK_SIZE; // 65536
 * ```
 *
 * @see hx_arena_alloc
 * @since 1.0.0
 */

export const CHUNK_SIZE: usize = 64 * 1024;

/**
 * The size in bytes reserved for the header at the front of each arena chunk.
 *
 * @remarks
 * The header itself needs 24 bytes.
 * It is rounded up to 32 so that the data after it starts 16-byte aligned.
 *
 * @example
 * ```ts
 * HEADER; // 32
 * ```
 *
 * @see Chunk
 * @since 1.0.0
 */

export const HEADER: usize = 32;
