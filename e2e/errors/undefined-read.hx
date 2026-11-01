// expect-error: `x` is read before it's given a value
// expect-error: `x` is read before it's given a value
// expect-error: `x` is read before it's given a value
// expect-error: `x` is read before it's given a value
// expect-error: `p` is read before it's given a value

struct Point { x: i32, y: i32 }

function fill(p: *Point): void { p.x = 1; p.y = 2; }
function setTo(out: *i32, v: i32): void { *out = v; }

function readFirst(): i32 { let x: i32 = undefined; const y = x; x = 1; return x + y; }
function selfRead(): i32 { let x: i32 = undefined; x = x + 1; return x; }
function oneBranch(flag: bool): i32 { let x: i32 = undefined; if (flag) x = 1; return x; }
function oneCase(k: u8): i32 {
    let x: i32 = undefined;
    switch (k) {
        case 0: x = 1;
        default: {}
    }
    return x;
}
function pointer(): i32 { let p: ?*Point = undefined; if (p == null) return 0; p = null; return 1; }

// these are fine
function bothBranches(flag: bool): i32 { let x: i32 = undefined; if (flag) { x = 1; } else { x = 2; } return x; }
function earlyReturn(flag: bool): i32 { let x: i32 = undefined; if (!flag) return 0; else x = 3; return x; }
function viaAddress(): i32 { let x: i32 = undefined; setTo(&x, 4); return x; }
function viaPointer(): i32 { let p: Point = undefined; fill(&p); return p.x; }
function inLoop(): i32 { let x: i32 = undefined; for (const i of 0..3) x = i as i32; return x; }
function everyCase(k: u8): i32 {
    let x: i32 = undefined;
    switch (k) {
        case 0: x = 1;
        default: x = 2;
    }
    return x;
}

export function main(): void {
    println(`${readFirst()} ${selfRead()} ${oneBranch(true)} ${oneCase(1)} ${pointer()} ${bothBranches(true)}`);
    println(`${earlyReturn(true)} ${viaAddress()} ${viaPointer()} ${inLoop()} ${everyCase(0)}`);
}
