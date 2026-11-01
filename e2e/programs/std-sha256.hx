// expect-stdout: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
// expect-stdout: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
// expect-stdout: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

import { sha256, toHex, Sha256 } from "std/sha256";

export function main(): void {
    const d = toHex(sha256("abc"));
    println(`${d[0..64]}`);
    let h = Sha256.init();
    h.update("a");
    h.update("bc");
    const e = toHex(h.finish());
    println(`${e[0..64]}`);
    const empty = toHex(sha256(""));
    println(`${empty[0..64]}`);
}
