/**
 * Imports
 */

import { Sha256, sha256, toHex } from "./sha256";

/**
 * Tests
 */

/**
 * Returns the hex digest of a byte slice as an owned array.
 *
 * @param bytes - The input to hash
 * @returns The 64 lowercase hex digits of the digest
 *
 * @remarks
 * It chains {@link sha256} and {@link toHex},
 * so a test can compare the digest with a known vector after taking `&` of the result.
 *
 * @since 1.0.0
 */

function hexOf(bytes: readonly u8[]): u8[64] {
    return toHex(sha256(bytes));
}

/**
 * Fills an array with the byte `a`.
 *
 * @param out - The bytes to fill
 *
 * @remarks
 * The long known vectors of FIPS 180-4 hash runs of `a`, and this builds such a run without a literal.
 *
 * @since 1.0.0
 */

function fillWithA(out: u8[]): void {
    for (const i of 0..out.len) out[i] = 'a';
}

describe("Sha256") {
    describe("init") {
        test("should start from the initial state of the standard and no input") {
            const h = Sha256.init();

            expect(h.state[0]).toBe(0x6a09e667);
            expect(h.state[7]).toBe(0x5be0cd19);
            expect(h.length).toBe(0);
            expect(h.used).toBe(0);
        }

        test("should give the digest of the empty input when nothing is fed in") {
            let h = Sha256.init();
            const hex = toHex(h.finish());
            const text: string = &hex;

            expect(text).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        }
    }

    describe("update") {
        test("should count the bytes and keep a partial block waiting") {
            let h = Sha256.init();
            h.update("abc");

            expect(h.length).toBe(3);
            expect(h.used).toBe(3);
            expect(h.block[0]).toBe('a');
        }

        test("should compress a full block and start the next one") {
            let block: u8[70] = undefined;
            fillWithA(&block);
            let h = Sha256.init();
            h.update(&block);

            expect(h.length).toBe(70);
            expect(h.used).toBe(6);
            expect(h.state[0] == 0x6a09e667).toBeFalse();
        }

        test("should give the same digest however the input is split") {
            let h = Sha256.init();
            h.update("The quick ");
            h.update("");
            h.update("brown fox jumps over the lazy dog");
            const hex = toHex(h.finish());
            const text: string = &hex;

            expect(text).toBe("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592");
        }

        test("should give the same digest when fed one byte at a time") {
            const input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
            let h = Sha256.init();
            for (const i of 0..input.len) h.update(input[i..i + 1]);
            const hex = toHex(h.finish());
            const text: string = &hex;

            expect(text).toBe("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
        }

        test("should hash a million bytes fed in chunks") {
            let chunk: u8[1000] = undefined;
            fillWithA(&chunk);
            let h = Sha256.init();
            for (const _ of 0..1000) h.update(&chunk);
            const hex = toHex(h.finish());
            const text: string = &hex;

            expect(h.length).toBe(1_000_000 + 64);
            expect(text).toBe("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
        }
    }

    describe("finish") {
        test("should give the digest of the standard abc vector") {
            let h = Sha256.init();
            h.update("abc");
            const digest = h.finish();

            expect(digest[0]).toBe(0xba);
            expect(digest[31]).toBe(0xad);
        }

        test("should pad an input that leaves no room for the length in its last block") {
            let bytes: u8[56] = undefined;
            fillWithA(&bytes);
            let h = Sha256.init();
            h.update(&bytes);
            const hex = toHex(h.finish());
            const text: string = &hex;

            expect(text).toBe("b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");
        }

        test("should leave the hasher used up with its padding counted") {
            let h = Sha256.init();
            h.update("abc");
            void h.finish();

            expect(h.used).toBe(0);
            expect(h.length).toBe(64);
        }
    }

    describe("compress") {
        test("should mix the block into the state without touching the count of waiting bytes") {
            let h = Sha256.init();
            h.update("abc");
            h.compress();

            expect(h.state[0] == 0x6a09e667).toBeFalse();
            expect(h.used).toBe(3);
        }
    }
}

describe("sha256") {
    test("should give the digest of the empty input") {
        const hex = hexOf("");
        const text: string = &hex;

        expect(text).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    }

    test("should give the digest of the standard abc vector") {
        const hex = hexOf("abc");
        const text: string = &hex;

        expect(text).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    test("should give the digest of the standard two-block vector") {
        const hex = hexOf("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
        const text: string = &hex;

        expect(text).toBe("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    }

    test("should give the digest of inputs at the block boundaries") {
        let short: u8[55] = undefined;
        let full: u8[64] = undefined;
        fillWithA(&short);
        fillWithA(&full);
        const shortHex = hexOf(&short);
        const fullHex = hexOf(&full);
        const shortText: string = &shortHex;
        const fullText: string = &fullHex;

        expect(shortText).toBe("9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318");
        expect(fullText).toBe("ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
    }
}

describe("toHex") {
    test("should write each byte as two lowercase digits, high half first") {
        let digest: u8[32] = undefined;
        for (const i of 0..32) digest[i] = 0;
        digest[0] = 0xAB;
        digest[1] = 0x0F;
        digest[31] = 0xF0;
        const hex = toHex(digest);
        const text: string = &hex;

        expect(text[0..4]).toBe("ab0f");
        expect(text[4..62]).toBe("0000000000000000000000000000000000000000000000000000000000");
        expect(text[62..64]).toBe("f0");
    }
}
