/**
 * Imports
 */

import { HxSha256 } from "@services/structs/sha256-service.struct";
import { hx_sha256_init, hx_sha256_update, hx_sha256_finish, hx_sha256_hex } from "@services/sha256.service";

/**
 * Tests
 */

let hexBuf: u8[65] = undefined;

/**
 * The hex digest of a text repeated a number of times, fed one copy per update.
 */

function digest(text: string, repeat: usize): string {
    let s: HxSha256 = undefined;
    hx_sha256_init(&s);
    for (const _ of 0..repeat) hx_sha256_update(&s, text.ptr, text.len);
    let out: u8[32] = undefined;
    hx_sha256_finish(&s, &out);
    hx_sha256_hex(&out, &hexBuf);
    return hexBuf[0..64];
}

describe("hx_sha256_init") {
    test("should start with no bytes fed") {
        let s: HxSha256 = undefined;
        hx_sha256_init(&s);

        expect(s.length).toBe(0);
        expect(s.used).toBe(0);
        expect(s.state[0]).toBe(0x6a09e667);
    }
}

describe("hx_sha256_update") {
    test("should count the bytes fed") {
        let s: HxSha256 = undefined;
        hx_sha256_init(&s);
        hx_sha256_update(&s, "abc", 3);

        expect(s.length).toBe(3);
        expect(s.used).toBe(3);
    }

    test("should ignore an update of zero bytes") {
        let s: HxSha256 = undefined;
        hx_sha256_init(&s);
        hx_sha256_update(&s, "abc", 0);

        expect(s.length).toBe(0);
    }

    test("should give the same digest across many updates as one") {
        expect(digest("a", 3)).toBe(digest("aaa", 1));
    }
}

describe("hx_sha256_finish") {
    test("should match the published vectors") {
        expect(digest("", 1)).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        expect(digest("abc", 1)).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        expect(digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 1))
            .toBe("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
        expect(digest("a", 1000000)).toBe("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    }

    test("should pad correctly at 55, 56 and 64 bytes") {
        expect(digest("a", 55)).toBe("9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318");
        expect(digest("a", 56)).toBe("b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");
        expect(digest("a", 64)).toBe("ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
    }
}

describe("hx_sha256_hex") {
    test("should write 64 lowercase hex digits and a NUL") {
        let bytes: u8[32] = undefined;
        for (const i of 0..32) bytes[i] = @truncate(u8, i * 8);
        hx_sha256_hex(&bytes, &hexBuf);
        const text: string = hexBuf[0..8];

        expect(text).toBe("00081018");
        expect(hexBuf[64]).toBe(0);
    }
}
