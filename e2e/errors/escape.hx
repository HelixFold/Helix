// expect-error: this points into `x`, a local that's gone once the function returns
// expect-error: this points into `p`, a local that's gone once the function returns
// expect-error: this points into `arr`, a local that's gone once the function returns
// expect-error: this points into `arr`, a local that's gone once the function returns
// expect-error: this points into `x`, a local that's gone once the function returns
// expect-error: this points into `x`, a local that's gone once the function returns
// expect-error: this points into `v`, a parameter that's gone once the function returns

struct Point { x: i32, y: i32 }
struct Holder { p: *i32 }

function a(): *i32 { let x: i32 = 1; return &x; }
function b(): *i32 { let p = Point { x: 1, y: 2 }; return &p.y; }
function c(): i32[] { let arr: i32[3] = [1, 2, 3]; return arr[0..2]; }
function d(): i32[] { let arr: i32[3] = [1, 2, 3]; return &arr; }
function e(flag: bool): *i32 { let x: i32 = 1; let y: i32 = 2; return flag ? &x : &y; }
function f(): Holder { let x: i32 = 1; return Holder { p: &x }; }
function g(v: i32): readonly *i32 { return &v; }

// these are fine: memory the caller owns, or a global
function fromPointer(p: *Point): *i32 { return &p.x; }
function fromSlice(s: i32[]): i32[] { return s[0..1]; }
let global: i32 = 3;
function fromGlobal(): *i32 { return &global; }

export function main(): void {
    println(`${*a()} ${*b()} ${c().len} ${d().len} ${*e(true)} ${*f().p} ${*g(1)} ${fromSlice(c()).len} ${*fromGlobal()}`);
    let p = Point { x: 1, y: 2 };
    println(`${*fromPointer(&p)}`);
}
