/**
 * Imports
 */

import { strlen } from "std/c";
import { cAllocator } from "std";
import { Builder } from "std/fmt";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { HxSema, HxInstance } from "@structs/sema.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { HxSource } from "@models/structs/source-model.struct";
import { hxAstFree, node, tokenText } from "@models/ast.model";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { hxsSameValue } from "@modules/sema/components/generics.component";
import { hxSemaInstanceArg, instanceArg, instanceName } from "@modules/sema/components/generics.component";

/**
 * Tests
 */

/**
 * A source with its tokens, tree, checker state, and diagnostics after one check.
 *
 * @remarks
 * The parser and the checker keep pointers into the source and the token list,
 * so a test declares the state on its stack and lets {@link check} fill it in place.
 *
 * @since 1.0.0
 */

struct Checked {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
    sema: HxSema,
    diags: HxDiagList,
}

let out: Builder = undefined;
let outReady = false;

/**
 * A NUL-terminated string as a slice.
 *
 * @param text - The NUL-terminated bytes
 * @returns The bytes before the NUL
 *
 * @remarks
 * Measures the text with `strlen` and slices it without a copy,
 * so the slice stays valid only as long as the bytes do.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * Lexes, parses, and checks a text as a single-file program, in a state that must stay where it is.
 *
 * @param ch - The state that receives every stage
 * @param text - The program source
 *
 * @remarks
 * Every stage writes into the same diagnostic list and runs even after an earlier stage reports errors.
 * The check passes no program, so the text stands alone as a single module.
 *
 * @since 1.0.0
 */

function check(ch: *Checked, text: string): void {
    ch.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&ch.src, "test.hx", text.ptr, text.len);
    void hxLex(&ch.src, &ch.tokens, &ch.diags);
    void hxParse(&ch.src, &ch.tokens, &ch.ast, &ch.diags);
    void hxSemaCheck(&ch.sema, &ch.ast, null, &ch.diags);
}

/**
 * Releases everything that one check allocated.
 *
 * @param ch - The state that {@link check} filled
 *
 * @remarks
 * Frees the stages in the reverse order of their creation, so the source goes last.
 * A test must not read the state afterwards.
 *
 * @since 1.0.0
 */

function release(ch: *Checked): void {
    hxSemaFree(&ch.sema);
    hxAstFree(&ch.ast);
    hxTokensFree(&ch.tokens);
    hxDiagListFree(&ch.diags);
    hxSourceFree(&ch.src);
}

/**
 * The shared output builder, emptied.
 *
 * @returns The shared builder, without any text
 *
 * @remarks
 * Creates the builder with the C allocator on the first call and only clears it afterwards,
 * so every helper that returns builder text shares one buffer.
 *
 * @since 1.0.0
 */

function cleared(): *Builder {
    if (!outReady) {
        out = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    return &out;
}

/**
 * Every diagnostic message that checking a text gives, one per line, or an empty string when it checks.
 *
 * @param text - The program source
 * @returns The messages, each followed by a newline
 *
 * @remarks
 * Diagnostics of every severity count, and their hints stay out of the text.
 * The text lives in the shared builder, which the next call clears,
 * so a test compares the result before it checks another source.
 *
 * @since 1.0.0
 */

function errors(text: string): string {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    const b = cleared();
    for (const i of 0..ch.diags.itemsLen) {
        unsafe {
            b.append(`${cString(ch.diags.items![i].message)}\n`) catch unreachable;
        }
    }
    return b.text();
}

/**
 * The instance at a zero-based position of the instance table.
 *
 * @param ch - The checked state
 * @param i - The zero-based position in the instance table
 * @returns A copy of the instance
 *
 * @remarks
 * The position is zero-based, unlike the one-based index that the checker hands out,
 * and nothing checks it against the length of the table.
 *
 * @since 1.0.0
 */

function nth(ch: readonly *Checked, i: u32): HxInstance {
    unsafe {
        return @ptrCast(HxInstance[*], ch.sema.instances.items)[i];
    }
}

/**
 * Every instance that checking a text creates, one per line, as `name<param=arg, ...>`.
 *
 * @param text - The program source
 * @returns The instances, one per line
 *
 * @remarks
 * Each argument shows the parameter name and the text from `hxSemaInstanceArg`,
 * so a `comptime` argument shows its value.
 * The text lives in the shared builder, which the next call clears.
 *
 * @since 1.0.0
 */

function instances(text: string): string {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    const b = cleared();
    for (const i of 0..ch.sema.instances.len) {
        const inst = nth(&ch, i);
        b.append(`${tokenText(&ch.ast, node(&ch.ast, inst.decl).token)}<`) catch unreachable;
        for (const k of 0..inst.argsCount) {
            let buf: u8[96] = undefined;
            hxSemaInstanceArg(&ch.sema, &inst, k, &buf, 96);
            const name = tokenText(&ch.ast, instanceName(&ch.sema, inst.argsStart + k));
            unsafe {
                b.append(`${k > 0 ? ", " : ""}${name}=${cString(&buf)}`) catch unreachable;
            }
        }
        b.append(">\n") catch unreachable;
    }
    return b.text();
}

/**
 * Whether the first arguments of the first two instances that checking a text creates are the same.
 *
 * @param text - The program source, which must create at least two instances
 * @param asValues - Whether to compare the arguments as `comptime` values rather than as types
 * @returns `true` when the two arguments match
 *
 * @remarks
 * Types compare by their index, and values compare through `hxsSameValue`,
 * so two equal values that sit at different indexes still match.
 *
 * @since 1.0.0
 */

function firstArgsSame(text: string, asValues: bool): bool {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    const a = instanceArg(&ch.sema, nth(&ch, 0).argsStart);
    const b = instanceArg(&ch.sema, nth(&ch, 1).argsStart);
    return asValues ? hxsSameValue(&ch.sema, a, b) : a == b;
}

/**
 * The number of instances that checking a text creates.
 *
 * @param text - The program source
 * @returns The length of the instance table
 *
 * @remarks
 * Struct and function instances share the table,
 * so a test can check that repeating the same arguments reuses one instance.
 *
 * @since 1.0.0
 */

function instanceCount(text: string): u32 {
    let ch: Checked = undefined;
    check(&ch, text);
    defer release(&ch);
    return ch.sema.instances.len;
}

describe("instance") {
    test("should keep one instance for each distinct set of type arguments") {
        expect(instances("function id<T>(x: T): T { return x; }\nexport function main(): void { void id(1); void id(true); void id(2); }"))
            .toBe("id<T=i64>\nid<T=bool>\n");
    }
}

describe("instanceArg") {
    test("should hold the same type for the same argument of two different generics") {
        expect(firstArgsSame("function a<T>(x: T): T { return x; }\nfunction b<U>(x: U): U { return x; }\nexport function main(): void { void a(true); void b(false); }", false)).toBe(true);
    }

    test("should hold a value index for a comptime argument") {
        expect(instances("function r(comptime n: i32): i32 { return n; }\nexport function main(): void { void r(7); }"))
            .toBe("r<n=7>\n");
    }
}

describe("instanceName") {
    test("should hold the token of the parameter that each argument binds") {
        expect(instances("function pair<A, B>(a: A, b: B): A { return a; }\nexport function main(): void { void pair(1, true); }"))
            .toBe("pair<A=i64, B=bool>\n");
    }
}

describe("aggregateInstance") {
    test("should give a method of a struct instance the type arguments of that instance") {
        expect(errors("struct Box<T> { value: T,\n    get(this: Box<T>): T { return this.value; } }\nexport function main(): void { const b = Box<bool> { value: true }; const x: i32 = b.get(); void x; }"))
            .toBe("expected `i32`, found `bool`\n");
    }
}

describe("pushTypeParam") {
    test("should resolve a type parameter in the body to the argument of each instance") {
        expect(errors("function f<T>(x: T): T { const y: i32 = x; void y; return x; }\nexport function main(): void { void f(1 as i32); void f(true); }"))
            .toBe("expected `i32`, found `bool`\nwhile instantiating `f<bool>` here\n");
    }
}

describe("hxsSaveState") {
    test("should leave the function that makes an instance free of the instance's state") {
        expect(errors("function id<T>(x: T): T { return x; }\nfunction f(): bool { const n = id(1); return n > 0; }\nexport function main(): void { void f(); }"))
            .toBe("");
    }
}

describe("hxsRestoreState") {
    test("should keep checking the calling function against its own return type") {
        expect(errors("function id<T>(x: T): T { return x; }\nfunction f(): bool { void id(1); return 1; }\nexport function main(): void { void f(); }"))
            .toBe("expected `bool`, found `integer literal`\n");
    }
}

describe("hxsGenericParams") {
    test("should count every parameter of the type parameter list") {
        expect(errors("struct Pair<A, B> { a: A, b: B }\nexport function main(): void { const p: Pair<i32> = undefined; void p; }"))
            .toBe("`Pair` takes 2 type arguments, but 1 was given\n");
    }
}

describe("hxsEnterInstance") {
    test("should report an error in the body only for the instance that causes it") {
        expect(errors("function neg<T>(x: T): T { return -x; }\nexport function main(): void { void neg(1); void neg(true); }"))
            .toBe("`-` needs a number, found `bool`\nwhile instantiating `neg<bool>` here\n");
    }
}

describe("hxsSameValue") {
    test("should tell two different comptime integers apart") {
        expect(firstArgsSame("function r(comptime n: i32): i32 { return n; }\nexport function main(): void { void r(3); void r(4); }", true)).toBe(false);
    }

    test("should share one instance between calls with equal comptime strings") {
        expect(instances("function s(comptime t: string): usize { return t.len; }\nexport function main(): void { void s(\"a\"); void s(\"a\"); }"))
            .toBe("s<t=\"a\">\n");
    }
}

describe("hxsFindInstance") {
    test("should reuse the instance of an earlier call with the same type arguments") {
        expect(instanceCount("function id<T>(x: T): T { return x; }\nexport function main(): void { void id(1); void id(2); }")).toBe(1);
    }

    test("should reuse the instance of a generic struct named twice") {
        expect(instanceCount("struct Box<T> { value: T }\nexport function main(): void { const a: Box<i32> = undefined; const b: Box<i32> = undefined; void a; void b; }")).toBe(1);
    }
}

describe("hxsAddInstance") {
    test("should store the type arguments before the comptime values") {
        expect(instances("function fill<T>(comptime n: usize, x: T): T { return x; }\nexport function main(): void { void fill(3, true); void fill(3, false); void fill(4, true); }"))
            .toBe("fill<T=bool, n=3>\nfill<T=bool, n=4>\n");
    }
}

describe("hxsCheckConstraint") {
    test("should accept integer and float types for Numeric") {
        expect(errors("function max<T extends Numeric>(a: T, b: T): T { return a > b ? a : b; }\nexport function main(): void { void max(1, 2); void max(1.5, 2.5); }")).toBe("");
    }

    test("should report a type that does not satisfy Numeric") {
        expect(errors("function max<T extends Numeric>(a: T, b: T): T { return a > b ? a : b; }\nexport function main(): void { void max(true, false); }"))
            .toBe("`bool` doesn't satisfy `Numeric`\n");
    }

    test("should keep Integer to integers and Float to floats") {
        expect(errors("function lo<T extends Integer>(a: T): T { return a; }\nfunction fl<T extends Float>(a: T): T { return a; }\nexport function main(): void { void lo(1.5); void fl(1); void lo(3); void fl(2.5); }"))
            .toBe("`f64` doesn't satisfy `Integer`\n`i64` doesn't satisfy `Float`\n");
    }

    test("should report a type that does not implement the interface") {
        expect(errors("interface Show { show(this: *Self): i32; }\nstruct A { show(this: *A): i32 { return 1; } }\nstruct B {}\nfunction s<T extends Show>(x: *T): i32 { return x.show(); }\nexport function main(): void { let a = A {}; let b = B {}; void s(&a); void s(&b); }"))
            .toBe("`B` doesn't implement `Show`\n");
    }

    test("should check the constraint of a generic struct") {
        expect(errors("struct Num<T extends Numeric> { value: T }\nexport function main(): void { const b: Num<bool> = undefined; void b; }"))
            .toBe("`bool` doesn't satisfy `Numeric`\n");
    }
}

describe("instanceNote") {
    test("should point an error in a generic body at the use that made the instance") {
        expect(errors("function add<T>(a: T, b: T): T { return a + b; }\nexport function main(): void { void add(true, false); }"))
            .toBe("`+` doesn't work on `bool`\nwhile instantiating `add<bool>` here\n");
    }

    test("should add no note for an instance that checks") {
        expect(errors("function add<T>(a: T, b: T): T { return a + b; }\nexport function main(): void { void add(1, 2); }")).toBe("");
    }
}

describe("hxSemaInstanceArg") {
    test("should write a type argument as its type name") {
        expect(instances("function id<T>(x: T): T { return x; }\nexport function main(): void { void id(2.5); void id(\"a\"); }"))
            .toBe("id<T=f64>\nid<T=string>\n");
    }

    test("should write a negative comptime integer with its sign") {
        expect(instances("function r(comptime n: i32): i32 { return n; }\nexport function main(): void { void r(-42); }"))
            .toBe("r<n=-42>\n");
    }

    test("should cut a comptime string to its first 24 bytes") {
        expect(instances("function s(comptime t: string): usize { return t.len; }\nexport function main(): void { void s(\"abcdefghijklmnopqrstuvwxyz0123\"); }"))
            .toBe("s<t=\"abcdefghijklmnopqrstuvwx\">\n");
    }

    test("should write comptime booleans and floats as their values") {
        expect(instances("function b(comptime t: bool): bool { return t; }\nfunction f(comptime t: f64): f64 { return t; }\nexport function main(): void { void b(true); void f(1.5); }"))
            .toBe("b<t=true>\nf<t=1.5>\n");
    }
}

describe("hxsInstanceName") {
    test("should separate the arguments of an instance name with a comma") {
        expect(errors("function pair<A, B>(a: A, b: B): A { void b; return a + true; }\nexport function main(): void { void pair(1, true); }"))
            .toBe("mismatched operand types `i64` and `bool`\nwhile instantiating `pair<i64, bool>` here\n");
    }
}

describe("hxsGenericArity") {
    test("should report too many type arguments") {
        expect(errors("struct Box<T> { value: T }\nexport function main(): void { const a: Box<i32, i32> = undefined; void a; }"))
            .toBe("`Box` takes 1 type argument, but 2 were given\n");
    }
}

describe("hxsInstantiateStruct") {
    test("should make a separate instance for each set of type arguments") {
        expect(instances("struct Box<T> { value: T }\nexport function main(): void { const a: Box<i32> = undefined; const c: Box<bool> = undefined; void a; void c; }"))
            .toBe("Box<T=i32>\nBox<T=bool>\n");
    }

    test("should point an error in the members at the use that made the instance") {
        expect(errors("struct Box<T> { value: T, other: Nope }\nexport function main(): void { const b: Box<i32> = undefined; void b; }"))
            .toBe("unknown type `Nope`\nwhile instantiating `Box<i32>` here\n");
    }
}

describe("hxsInstantiateTypeNode") {
    test("should report a name that is not generic") {
        expect(errors("struct Plain { v: i32 }\nexport function main(): void { const a: Plain<i32> = undefined; void a; }"))
            .toBe("`Plain` is not generic\n");
    }

    test("should report an unknown name") {
        expect(errors("export function main(): void { const b: Nope<i32> = undefined; void b; }"))
            .toBe("unknown type `Nope`\n");
    }
}

describe("hxsInstantiateFunction") {
    test("should stop a function that instantiates itself without end") {
        expect(errors("function down(comptime n: u32): u32 { return down(n + 1); }\nexport function main(): void { void down(0); }"))
            .toBe("`down` was instantiated 1000 times\nwhile instantiating `down<999>` here\n");
    }
}

describe("hxsMethodInstance") {
    test("should check a method of a struct instance with the instance's type arguments") {
        expect(errors("struct Box<T> { value: T,\n    get(this: Box<T>): T { return this.value; } }\nexport function main(): void { const b = Box<i32> { value: 1 }; const x: i32 = b.get(); void x; }"))
            .toBe("");
    }
}

describe("hxsRuntimeType") {
    test("should infer i64 from an integer literal") {
        expect(instances("function id<T>(x: T): T { return x; }\nexport function main(): void { void id(1); }")).toBe("id<T=i64>\n");
    }

    test("should infer f64 and string from float and string literals") {
        expect(instances("function id<T>(x: T): T { return x; }\nexport function main(): void { void id(2.5); void id(\"a\"); }"))
            .toBe("id<T=f64>\nid<T=string>\n");
    }
}

describe("hxsUnify") {
    test("should bind a type parameter through pointers, slices, and optionals") {
        expect(instances("function deref<T>(p: *T): T { return *p; }\nfunction first<T>(s: T[]): T { return s[0]; }\nfunction opt<T>(o: ?T): bool { return o != null; }\nexport function main(): void { let a: u8 = 1; void deref(&a); let arr: u16[2] = [1, 2]; void first(arr); void first(&arr); const o: ?i8 = null; void opt(o); }"))
            .toBe("deref<T=u8>\nfirst<T=u16>\nopt<T=i8>\n");
    }

    test("should widen a bound type to fit a later argument") {
        expect(instances("function big<T>(a: T, b: T): T { void b; return a; }\nexport function main(): void { const a: u8 = 1; const b: i32 = 2; void big(a, b); }"))
            .toBe("big<T=i32>\n");
    }
}

describe("hxsComptimeParamType") {
    test("should resolve a comptime parameter typed by a type parameter") {
        expect(instances("function fill<T>(comptime v: T): T { return v; }\nexport function main(): void { void fill<u8>(3); }"))
            .toBe("fill<T=u8, v=3>\n");
    }

    test("should convert the comptime argument to that type") {
        expect(errors("function fill<T>(comptime v: T): T { return v; }\nexport function main(): void { void fill<u8>(300); }"))
            .toBe("integer 300 does not fit in `u8`\n");
    }
}

describe("hxsUnifyConstraints") {
    test("should infer a type parameter that only an interface constraint mentions") {
        expect(instances("interface Iterator<T> { next(this: *Self): ?T; }\nstruct Counter { n: i32,\n    next(this: *Counter): ?i32 { this.n += 1; return this.n < 3 ? this.n : null; } }\nfunction sum<I extends Iterator<T>, T>(it: *I): ?T { return it.next(); }\nexport function main(): void { let c = Counter { n: 0 }; void sum(&c); }"))
            .toBe("Iterator<T=i32>\nsum<I=Counter, T=i32>\n");
    }
}

describe("hxsGenericCallInstance") {
    test("should report a type parameter that nothing binds") {
        expect(errors("function make<T>(): ?T { return null; }\nexport function main(): void { void make(); }"))
            .toBe("can't infer `T` for `make`\n");
    }

    test("should take explicit type arguments in place of inference") {
        expect(instances("function make<T>(): ?T { return null; }\nexport function main(): void { void make<i32>(); }"))
            .toBe("make<T=i32>\n");
    }

    test("should report a wrong number of arguments") {
        expect(errors("function two<T>(a: T, b: T): T { void b; return a; }\nexport function main(): void { void two(1); }"))
            .toBe("`two` takes 2 arguments, but 1 was given\n");
    }

    test("should report a wrong number of explicit type arguments") {
        expect(errors("function id<T>(x: T): T { return x; }\nexport function main(): void { void id<i32, i32>(1); }"))
            .toBe("`id` takes 1 type argument, but 2 were given\n");
    }

    test("should convert the arguments to the parameter types of the instance") {
        expect(errors("function id<T>(x: T): T { return x; }\nexport function main(): void { void id<bool>(1); }"))
            .toBe("expected `bool`, found `integer literal`\n");
    }

    test("should report a comptime argument that is only known when the program runs") {
        expect(errors("function repeat(comptime n: usize): usize { return n; }\nexport function main(): void { let k: usize = 3; k += 1; void repeat(k); }"))
            .toBe("`n` is a `comptime` parameter, so its argument must be known while compiling\n");
    }
}

describe("hxsCheckGenericCall") {
    test("should give the call the return type of the instance") {
        expect(errors("function id<T>(x: T): T { return x; }\nexport function main(): void { const x: bool = id(1); void x; }"))
            .toBe("expected `bool`, found `i64`\n");
    }
}
