/**
 * Imports
 */

import { cAllocator } from "std";
import { equal } from "std/text";
import { Builder } from "std/fmt";
import { strlen, free } from "std/c";
import { hxAstFree } from "@models/ast.model";
import { NodeKind } from "@constants/ast.constant";
import { TypeKind } from "@constants/types.constant";
import { HxValueInt } from "@constants/sema.constant";
import { hxArenaFree } from "@services/arena.service";
import { HxSema, HxU32Vec } from "@structs/sema.struct";
import { hxParse } from "@modules/parser/parser.module";
import { HxAst } from "@models/structs/ast-model.struct";
import { hxDiagListFree } from "@models/diagnostic.model";
import { hxCodegenIr } from "@modules/codegen/codegen.module";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { HxSource } from "@models/structs/source-model.struct";
import { HxArena } from "@services/structs/arena-service.struct";
import { hxLex, hxTokensFree } from "@modules/lexer/lexer.module";
import { hxSemaCheck, hxSemaFree } from "@modules/sema/sema.module";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { hxSourceFromString, hxSourceFree } from "@models/source.model";
import { int8Type, int32, int64, voidType } from "@modules/codegen/components/base.component";
import { optionalPayload, optionalSome, errorUnionCode } from "@modules/codegen/components/base.component";
import { detourBegin, tokenText, tokenStart, addAttribute } from "@modules/codegen/components/base.component";
import { nodeKindName, terminated, lowerFunction, constInt } from "@modules/codegen/components/base.component";
import { vectorAt, llvmName, fromCString, optionalIsPointer } from "@modules/codegen/components/base.component";
import { addStringAttribute, callIntrinsic, call, structType } from "@modules/codegen/components/base.component";
import { knownCondition, emitConst, detourEnd, helperFunction } from "@modules/codegen/components/base.component";
import { emitCheck, emitBoundsCheck, entryAlloca, localStorage } from "@modules/codegen/components/base.component";
import { isSigned, constUsize, constBool, constGlobal, cstring } from "@modules/codegen/components/base.component";
import { hasValue, lower, elementPointer, extract, insert, load } from "@modules/codegen/components/base.component";
import { Cg, Value, Type, Block, HxCodegenOptions } from "@modules/codegen/components/structs/base-component.struct";
import { constPair, buildPanicHandler, locationString, emitPanic } from "@modules/codegen/components/base.component";
import { symbolOf, extra, value, diPosition, declareC, tokenName } from "@modules/codegen/components/base.component";
import { typeName, zeroed, release, push, positionAtEnd, int1Type } from "@modules/codegen/components/base.component";
import { constStruct, constArray, llvmBool, nodeOf, infoOf, typeOf } from "@modules/codegen/components/base.component";
import { errorUnionPayload, errorUnionMake, fnType, constErrorCode } from "@modules/codegen/components/base.component";
import { store, branch, phiNode, sourceText, sourcePath, finalType } from "@modules/codegen/components/base.component";
import { condBr, compareIntegers, optionalPresent, errorUnionIsBare } from "@modules/codegen/components/base.component";
import { startDeadBlock, block, valueElem, param, aggregate, member } from "@modules/codegen/components/base.component";

/**
 * Tests
 */

/**
 * A checked source with a code generator set up over it, as the code generator module sets one up.
 *
 * @remarks
 * The generator keeps pointers into the checker state and the tree,
 * so the tests keep one fixture in a global that `open` fills and `close` frees.
 * It mirrors what the code generator module builds, but uses a fixed data layout instead of a target machine.
 *
 * @since 1.0.0
 */

struct Fixture {
    src: HxSource,
    tokens: HxTokens,
    ast: HxAst,
    sema: HxSema,
    diags: HxDiagList,
    options: HxCodegenOptions,
    cg: Cg,
}

/**
 * The data layout of a 64-bit little-endian target, so that sizes need no target machine.
 *
 * @since 1.0.0
 */

const Layout: readonly u8[*] = "e-m:o-i64:64-i128:128-n32:64-S128";

let fx: Fixture = undefined;
let out: Builder = undefined;
let source: Builder = undefined;
let outReady = false;

/**
 * Lexes, parses, and checks a text, then sets up a code generator over it with an empty module.
 *
 * @param text - The Helix source, as a format string
 * @returns The generator over the checked text, positioned nowhere yet
 * @remarks
 * It overwrites the single fixture, so each test calls `close` before the next `open`.
 * The generator runs in debug mode with safety checks on and pointer authentication off,
 * and it leaves the current function, the debug info, and the panic handlers unset.
 *
 * @since 1.0.0
 */

function open(text: Format): *Cg {
    if (!outReady) {
        out = Builder.init(cAllocator());
        source = Builder.init(cAllocator());
        outReady = true;
    }
    source.clear();
    source.append(text) catch unreachable;
    const program = source.text();
    fx.diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&fx.src, "test.hx", program.ptr, program.len);
    void hxLex(&fx.src, &fx.tokens, &fx.diags);
    void hxParse(&fx.src, &fx.tokens, &fx.ast, &fx.diags);
    void hxSemaCheck(&fx.sema, &fx.ast, null, &fx.diags);
    fx.options = HxCodegenOptions {
        mode: 0, module_name: "test", debugInfo: false, triple: null, cpu: null, freestanding: false,
    };
    const ctx = llvm.LLVMContextCreate();
    const ptr = llvm.LLVMPointerTypeInContext(ctx, 0);
    const usize = llvm.LLVMInt64TypeInContext(ctx);
    let sliceFields: Type[2] = [ptr, usize];
    let dynFields: Type[2] = [ptr, ptr];
    const items = fx.sema.types.itemsLen;
    fx.cg = Cg {
        sema: &fx.sema, ast: &fx.ast, types: &fx.sema.types, options: &fx.options, safe: true, ptrauth: false,
        arena: HxArena { head: null },
        ctx, mod: llvm.LLVMModuleCreateWithNameInContext("test", ctx), b: llvm.LLVMCreateBuilderInContext(ctx),
        machine: null,
        layout: llvm.LLVMCreateTargetData(Layout),
        storage: zeroed<Value>(fx.sema.symbols.len), typeCache: zeroed<Type>(items),
        stringGlobals: zeroed<Value>(fx.sema.values.len),
        sliceType: llvm.LLVMStructTypeInContext(ctx, &sliceFields, 2, 0), ptrType: ptr, usizeType: usize,
        dynType: llvm.LLVMStructTypeInContext(ctx, &dynFields, 2, 0), vtables: zeroed<Value>(fx.sema.impls.len + 1),
        fn: null, instance: 0, returnType: 0, entryBlock: null, defers: HxU32Vec { items: null, len: 0, cap: 0 },
        loops: undefined, loopCount: 0,
        panicFn: null, panicFnType: null, panicBoundsFn: null, panicBoundsFnType: null, errorNames: null,
        printFns: zeroed<Value>(items * 2), equalFns: zeroed<Value>(items), cAbi: zeroed<bool>(fx.sema.symbols.len),
        cWrappers: HxU32Vec { items: null, len: 0, cap: 0 },
        di: null, diUnit: null, diFiles: [], diTypes: [], diScope: null,
    };
    return &fx.cg;
}

/**
 * Releases the code generator and everything that the check allocated.
 *
 * @remarks
 * It disposes of the LLVM objects first and the checker stages last, the reverse of the order that `open` creates them.
 *
 * @since 1.0.0
 */

function close(): void {
    const cg = &fx.cg;
    llvm.LLVMDisposeBuilder(cg.b);
    llvm.LLVMDisposeModule(cg.mod);
    llvm.LLVMDisposeTargetData(cg.layout);
    llvm.LLVMContextDispose(cg.ctx);
    release(cg.storage);
    release(cg.typeCache);
    release(cg.stringGlobals);
    release(cg.vtables);
    release(cg.printFns);
    release(cg.equalFns);
    release(cg.cAbi);
    hxArenaFree(&cg.arena);
    hxSemaFree(&fx.sema);
    hxAstFree(&fx.ast);
    hxTokensFree(&fx.tokens);
    hxDiagListFree(&fx.diags);
    hxSourceFree(&fx.src);
}

/**
 * Adds a function named `probe` that takes the given parameters, and points the builder at its entry block.
 *
 * @param cg - The generator to add the function to
 * @param params - The parameter types of `probe`
 * @returns The new function, which also becomes the current one
 * @remarks
 * The function returns `void` and has a single `entry` block, so a test can emit instructions into it right away.
 *
 * @since 1.0.0
 */

function enter(cg: *Cg, params: readonly Type[]): Value {
    cg.fn = llvm.LLVMAddFunction(cg.mod, "probe", fnType(voidType(cg), params, false));
    cg.entryBlock = block(cg, "entry");
    positionAtEnd(cg, cg.entryBlock);
    return cg.fn;
}

/**
 * Copies a message that LLVM allocated into the arena of the generator, then disposes of it.
 *
 * @param cg - The generator whose arena receives the copy
 * @param message - The text that LLVM allocated
 * @returns The copy, which lives as long as the arena
 * @remarks
 * LLVM hands back strings that only `LLVMDisposeMessage` may free,
 * so the copy lets a test keep the text after the disposal.
 *
 * @since 1.0.0
 */

function keep(cg: *Cg, message: ?u8[*]): string {
    defer llvm.LLVMDisposeMessage(message);
    unsafe {
        return fromCString(llvmName(cg, `${fromCString(@ptrCast(?readonly u8[*], message))}`));
    }
}

/**
 * The LLVM text of a value, such as a constant, an instruction, or a whole function.
 *
 * @param cg - The generator that owns the value
 * @param v - The value to print
 * @returns The printed form of the value
 * @remarks
 * It prints through LLVM and keeps the text in the arena, so the result outlives the LLVM message.
 *
 * @since 1.0.0
 */

function show(cg: *Cg, v: Value): string {
    return keep(cg, llvm.LLVMPrintValueToString(v));
}

/**
 * The LLVM text of a type.
 *
 * @param cg - The generator that owns the type
 * @param t - The type to print
 * @returns The printed form of the type
 * @remarks
 * It prints through LLVM and keeps the text in the arena, so the result outlives the LLVM message.
 *
 * @since 1.0.0
 */

function showType(cg: *Cg, t: Type): string {
    return keep(cg, llvm.LLVMPrintTypeToString(t));
}

/**
 * The symbol whose declaration names a given identifier, or 0 when no symbol does.
 *
 * @param cg - The generator over the fixture
 * @param name - The identifier to look for
 * @returns The index of the first matching symbol, or 0
 * @remarks
 * It scans the symbols in order and skips any whose token lies outside the token list of the fixture.
 *
 * @since 1.0.0
 */

function symbolNamed(cg: *Cg, name: string): u32 {
    for (const i of 1..fx.sema.symbols.len) {
        const s = symbolOf(cg, i);
        if (s.token < fx.tokens.len && equal(tokenText(cg, s.token), name)) return i;
    }
    return 0;
}

/**
 * The type of the symbol that a given identifier names.
 *
 * @param cg - The generator over the fixture
 * @param name - The identifier of the symbol
 * @returns The index of the symbol's type
 * @remarks
 * It does not check that the name exists, so a missing name reads the entry of symbol 0.
 *
 * @since 1.0.0
 */

function typeNamed(cg: *Cg, name: string): u32 {
    return symbolOf(cg, symbolNamed(cg, name)).type;
}

/**
 * The initializer node of the `const` or `let` declaration of a given identifier.
 *
 * @param cg - The generator over the fixture
 * @param name - The identifier that the declaration binds
 * @returns The node of the initializer expression
 * @remarks
 * It reads the `b` child of the declaration node, which holds the initializer of a variable declaration.
 *
 * @since 1.0.0
 */

function initOf(cg: *Cg, name: string): u32 {
    return nodeOf(cg, symbolOf(cg, symbolNamed(cg, name)).decl).b;
}

/**
 * The text of a NUL-terminated string.
 *
 * @param text - The NUL-terminated bytes to view
 * @returns A slice over the bytes before the terminator
 * @remarks
 * The slice borrows the bytes and copies nothing, so it stays valid only while the caller keeps them alive.
 *
 * @since 1.0.0
 */

function cString(text: readonly u8[*]): string {
    unsafe {
        return text[0..strlen(text)];
    }
}

/**
 * The LLVM IR that the code generator gives for a single-file program, or the error it reports.
 *
 * @param text - The Helix source of the program
 * @param debugInfo - Whether to emit debug info
 * @returns The module's IR, or an `error:` line from the code generator
 * @remarks
 * Unlike `open`, it runs the whole code generator module, so it covers what the module adds around the components.
 * It does not report check diagnostics, and the next call overwrites the shared output.
 *
 * @since 1.0.0
 */

function ir(text: string, debugInfo: bool): string {
    let src: HxSource = undefined;
    let tokens: HxTokens = undefined;
    let ast: HxAst = undefined;
    let sema: HxSema = undefined;
    let diags = HxDiagList { items: null, itemsLen: 0, itemsCap: 0, arena: HxArena { head: null }, errorCount: 0 };
    hxSourceFromString(&src, "test.hx", text.ptr, text.len);
    void hxLex(&src, &tokens, &diags);
    void hxParse(&src, &tokens, &ast, &diags);
    void hxSemaCheck(&sema, &ast, null, &diags);
    if (!outReady) {
        out = Builder.init(cAllocator());
        source = Builder.init(cAllocator());
        outReady = true;
    }
    out.clear();
    const options = HxCodegenOptions {
        mode: 0, module_name: "test", debugInfo: debugInfo, triple: null, cpu: null, freestanding: false,
    };
    let error: ?u8[*] = null;
    if (const result = hxCodegenIr(&sema, &options, &error)) {
        out.append(`${cString(result)}`) catch unreachable;
        free(result);
    } else if (error != null) {
        out.append(`error: ${cString(error!)}`) catch unreachable;
        free(error);
    }
    hxSemaFree(&sema);
    hxAstFree(&ast);
    hxTokensFree(&tokens);
    hxDiagListFree(&diags);
    hxSourceFree(&src);
    return out.text();
}

/**
 * Opens a program with a declaration of each shape that the tests below reach for.
 *
 * @returns The generator over the program
 * @remarks
 * The program holds constants, optionals, a struct, and functions with each kind of return,
 * so most tests find what they need by name instead of opening a program of their own.
 *
 * @since 1.0.0
 */

function openProgram(): *Cg {
    return open(`const x: i32 = 5;
const o: ?i32 = 5;
const n: ?i32 = null;
const q: ?*i32 = null;
const s: string = "hi";
const a: i32[2] = [3, 4];
const t = 1 < 2;
const f = 2 < 1;
const u: u8 = 1;
struct P { x: i32, y: i64 }
function fn1(a1: i32, b1: bool): i64 { return 0; }
function point(p: P): void {}
function bare(): void | Error {}
function full(): i32 | Error { return 1; }
function stop(): noreturn { unreachable; }
function local(k1: bool): void { const k = k1; let y: i32 = 1; }
`);
}

/**
 * Whether two LLVM handles point at the same object.
 *
 * @typeParam handle - The opaque pointer type of the handles
 * @param a - The first handle
 * @param b - The second handle
 * @returns `true` when both handles hold the same address
 * @remarks
 * LLVM handles are opaque pointers, so the comparison goes through their addresses.
 *
 * @since 1.0.0
 */

function same<handle>(a: handle, b: handle): bool {
    return @intFromPtr(a) == @intFromPtr(b);
}



/**
 * The text of the whole module of the generator.
 *
 * @param cg - The generator whose module to print
 * @returns The printed module
 * @remarks
 * It keeps the text in the arena, so a test can match against it after the LLVM message is gone.
 *
 * @since 1.0.0
 */

function showModule(cg: *Cg): string {
    return keep(cg, llvm.LLVMPrintModuleToString(cg.mod));
}

/**
 * The first node of a given kind in the tree, or 0 when there is none.
 *
 * @param cg - The generator over the fixture
 * @param kind - The node kind to look for
 * @returns The index of the first node of that kind, or 0
 * @remarks
 * It scans the nodes in index order, which is the order that the parser created them.
 *
 * @since 1.0.0
 */

function firstNode(cg: *Cg, kind: NodeKind): u32 {
    for (const i of 1..fx.ast.nodesLen) {
        if (nodeOf(cg, i).kind == kind) return i;
    }
    return 0;
}

/**
 * The return type of the function that a given identifier names.
 *
 * @param cg - The generator over the fixture
 * @param name - The identifier of the function
 * @returns The index of the return type
 * @remarks
 * It reads the `child` of the function type, which holds the return type of a function.
 *
 * @since 1.0.0
 */

function returnOf(cg: *Cg, name: string): u32 {
    return typeOf(cg, typeNamed(cg, name)).child;
}

describe("zeroed") {
    test("should give the asked number of entries, each holding zero") {
        const items = zeroed<u32>(3);
        defer release(items);

        expect(items.len).toBe(3);
        expect(items[0] + items[1] + items[2]).toBe(0);
    }
}

describe("push") {
    test("should append values and grow the vector past its first capacity") {
        let vec = HxU32Vec { items: null, len: 0, cap: 0 };
        for (const i of 0..6) push(&vec, (i * 10) as u32);

        expect(vec.len).toBe(6);
        expect(vectorAt(&vec, 5)).toBe(50);
        unsafe {
            free(@ptrCast(?u8[*], vec.items));
        }
    }
}

describe("vectorAt") {
    test("should read the value at an index") {
        let vec = HxU32Vec { items: null, len: 0, cap: 0 };
        push(&vec, 7);
        push(&vec, 9);

        expect(vectorAt(&vec, 0)).toBe(7);
        expect(vectorAt(&vec, 1)).toBe(9);
        unsafe {
            free(@ptrCast(?u8[*], vec.items));
        }
    }
}

describe("llvmName") {
    test("should give the formatted text, terminated by NUL") {
        const cg = open("");
        defer close();

        expect(fromCString(llvmName(cg, `v${42}`))).toBe("v42");
    }
}

describe("fromCString") {
    test("should read a C string up to its NUL") {
        expect(fromCString("abc")).toBe("abc");
    }

    test("should give an empty string for null") {
        expect(fromCString(null)).toBe("");
    }
}

describe("llvmBool") {
    test("should give 1 for true and 0 for false") {
        expect(llvmBool(true)).toBe(1);
        expect(llvmBool(false)).toBe(0);
    }
}

describe("nodeOf") {
    test("should give the node at an index") {
        const cg = openProgram();
        defer close();

        expect(nodeOf(cg, symbolOf(cg, symbolNamed(cg, "x")).decl).kind == NodeKind.Const).toBe(true);
        expect(nodeOf(cg, 0).kind == NodeKind.None).toBe(true);
    }
}

describe("infoOf") {
    test("should give what the checker found out about a node") {
        const cg = openProgram();
        defer close();
        const info = infoOf(cg, initOf(cg, "x"));

        expect(info.value).not.toBe(0);
        expect(info.coerce).toBe(cg.types.i32);
    }
}

describe("typeOf") {
    test("should give the type at an id") {
        const cg = openProgram();
        defer close();
        const t = typeOf(cg, cg.types.i32);

        expect(t.kind == TypeKind.Int).toBe(true);
        expect(t.bits).toBe(32);
    }
}

describe("symbolOf") {
    test("should give the symbol at an id") {
        const cg = openProgram();
        defer close();

        expect(symbolOf(cg, symbolNamed(cg, "u")).type).toBe(cg.types.u8);
    }
}

describe("extra") {
    test("should read the list of children that a node keeps in the side table") {
        const cg = open("describe(\"d\") { test(\"t\") {} }\n");
        defer close();
        const d = nodeOf(cg, firstNode(cg, NodeKind.Describe));

        expect(d.b - d.a).toBe(1);
        expect(nodeOf(cg, extra(cg, d.a)).kind == NodeKind.Test).toBe(true);
    }
}

describe("value") {
    test("should give a value that the checker computed") {
        const cg = openProgram();
        defer close();
        const v = value(cg, infoOf(cg, initOf(cg, "x")).value);

        expect(v.kind as u32).toBe(HxValueInt);
        expect(v.integer == 5).toBe(true);
    }
}

describe("valueElem") {
    test("should give the value of an element of a computed array") {
        const cg = openProgram();
        defer close();
        const v = value(cg, infoOf(cg, initOf(cg, "a")).value);

        expect(v.count).toBe(2);
        expect(value(cg, valueElem(cg, v.elems + 1)).integer == 4).toBe(true);
    }
}

describe("param") {
    test("should give the type of a parameter of a function type") {
        const cg = openProgram();
        defer close();
        const f = typeOf(cg, typeNamed(cg, "fn1"));

        expect(param(cg, f, 0)).toBe(cg.types.i32);
        expect(param(cg, f, 1)).toBe(cg.types.boolType);
    }
}

describe("aggregate") {
    test("should give the members of a struct type") {
        const cg = openProgram();
        defer close();
        const agg = aggregate(cg, typeNamed(cg, "p"));

        expect(agg.fieldCount).toBe(2);
    }
}

describe("member") {
    test("should give a member of an aggregate by its position") {
        const cg = openProgram();
        defer close();
        const m = member(cg, aggregate(cg, typeNamed(cg, "p")), 1);

        expect(tokenText(cg, m.token)).toBe("y");
        expect(m.type).toBe(cg.types.i64);
    }
}

describe("tokenText") {
    test("should give the source text of a token") {
        const cg = open("const x: i32 = 5;\n");
        defer close();

        expect(tokenText(cg, 0)).toBe("const");
        expect(tokenText(cg, 1)).toBe("x");
    }
}

describe("tokenStart") {
    test("should give the byte offset of a token") {
        const cg = open("const x: i32 = 5;\n");
        defer close();

        expect(tokenStart(cg, 1)).toBe(6);
    }
}

describe("sourceText") {
    test("should give the source text of a byte range") {
        const cg = open("const x: i32 = 5;\n");
        defer close();

        expect(sourceText(cg, 9, 3)).toBe("i32");
    }
}

describe("sourcePath") {
    test("should give the path of a source file") {
        const cg = open("const x: i32 = 5;\n");
        defer close();

        expect(sourcePath(cg, 0)).toBe("test.hx");
    }
}

describe("finalType") {
    test("should give the type that a node is converted to") {
        const cg = openProgram();
        defer close();

        expect(finalType(cg, initOf(cg, "x"))).toBe(cg.types.i32);
    }
}

describe("isSigned") {
    test("should tell signed integer types from unsigned ones") {
        const cg = openProgram();
        defer close();

        expect(isSigned(cg, cg.types.i32)).toBe(true);
        expect(isSigned(cg, cg.types.u8)).toBe(false);
    }
}

describe("typeName") {
    test("should give the name of a type as Helix writes it") {
        const cg = openProgram();
        defer close();

        expect(typeName(cg, typeNamed(cg, "o"))).toBe("?i32");
    }
}

describe("tokenName") {
    test("should give the text of a token as a C string") {
        const cg = open("const x: i32 = 5;\n");
        defer close();

        expect(fromCString(tokenName(cg, 1))).toBe("x");
    }

    test("should give an empty name for the missing token") {
        const cg = open("const x: i32 = 5;\n");
        defer close();

        expect(fromCString(tokenName(cg, 0xFFFF_FFFF))).toBe("");
    }
}

describe("nodeKindName") {
    test("should give the name of a node kind") {
        expect(nodeKindName(NodeKind.If as u32)).toBe("if");
    }
}

describe("terminated") {
    test("should tell whether the current block already ends") {
        const cg = open("");
        defer close();
        void enter(cg, []);
        const before = terminated(cg);
        void llvm.LLVMBuildRetVoid(cg.b);

        expect(before).toBe(false);
        expect(terminated(cg)).toBe(true);
    }
}

describe("startDeadBlock") {
    test("should continue in a fresh block named dead") {
        const cg = open("");
        defer close();
        void enter(cg, []);
        void llvm.LLVMBuildRetVoid(cg.b);
        startDeadBlock(cg);

        expect(terminated(cg)).toBe(false);
        expect(fromCString(llvm.LLVMGetBasicBlockName(llvm.LLVMGetInsertBlock(cg.b)))).toBe("dead");
    }
}

describe("block") {
    test("should append a named block to the current function") {
        const cg = open("");
        defer close();
        const fn = enter(cg, []);
        const next = block(cg, "next");

        expect(llvm.LLVMCountBasicBlocks(fn)).toBe(2);
        expect(fromCString(llvm.LLVMGetBasicBlockName(next))).toBe("next");
    }
}

describe("positionAtEnd") {
    test("should move the builder to the end of a block") {
        const cg = open("");
        defer close();
        void enter(cg, []);
        const next = block(cg, "next");
        positionAtEnd(cg, next);

        expect(same(llvm.LLVMGetInsertBlock(cg.b), next)).toBe(true);
    }
}

describe("int1Type") {
    test("should give the LLVM type of a bool") {
        const cg = open("");
        defer close();

        expect(showType(cg, int1Type(cg))).toBe("i1");
    }
}

describe("int8Type") {
    test("should give the LLVM type of a byte") {
        const cg = open("");
        defer close();

        expect(showType(cg, int8Type(cg))).toBe("i8");
    }
}

describe("int32") {
    test("should give the 32-bit LLVM integer type") {
        const cg = open("");
        defer close();

        expect(showType(cg, int32(cg))).toBe("i32");
    }
}

describe("int64") {
    test("should give the 64-bit LLVM integer type") {
        const cg = open("");
        defer close();

        expect(showType(cg, int64(cg))).toBe("i64");
    }
}

describe("voidType") {
    test("should give the LLVM void type") {
        const cg = open("");
        defer close();

        expect(showType(cg, voidType(cg))).toBe("void");
    }
}

describe("fnType") {
    test("should build a function type from its result and parameters") {
        const cg = open("");
        defer close();
        const params: Type[2] = [int8Type(cg), cg.ptrType];

        expect(showType(cg, fnType(int32(cg), &params, false))).toBe("i32 (i8, ptr)");
        expect(showType(cg, fnType(int32(cg), &params, true))).toBe("i32 (i8, ptr, ...)");
    }
}

describe("call") {
    test("should call a function directly") {
        const cg = open("");
        defer close();
        void enter(cg, []);
        const params: Type[1] = [int32(cg)];
        const type = fnType(int32(cg), &params, false);
        const callee = llvm.LLVMAddFunction(cg.mod, "g", type);
        const args: Value[1] = [constInt(int32(cg), 7)];

        expect(show(cg, call(cg, type, callee, &args, "r"))).toInclude("%r = call i32 @g(i32 7)");
    }

    test("should check the signature of a call through a pointer when pointers are signed") {
        const cg = open("");
        defer close();
        const params: Type[1] = [cg.ptrType];
        const fn = enter(cg, &params);
        cg.ptrauth = true;
        const type = fnType(voidType(cg), [], false);

        expect(show(cg, call(cg, type, llvm.LLVMGetParam(fn, 0), [], ""))).toInclude("[ \"ptrauth\"(i32 0, i64 0) ]");
    }
}

describe("structType") {
    test("should build an unnamed struct type") {
        const cg = open("");
        defer close();
        const fields: Type[2] = [int32(cg), int1Type(cg)];

        expect(showType(cg, structType(cg, &fields))).toBe("{ i32, i1 }");
    }
}

describe("constStruct") {
    test("should build a constant of an unnamed struct") {
        const cg = open("");
        defer close();
        const fields: Value[2] = [constInt(int32(cg), 1), constBool(cg, true)];

        expect(show(cg, constStruct(cg, &fields))).toBe("{ i32, i1 } { i32 1, i1 true }");
    }
}

describe("constArray") {
    test("should build a constant array") {
        const cg = open("");
        defer close();
        const items: Value[2] = [constInt(int32(cg), 1), constInt(int32(cg), 2)];

        expect(show(cg, constArray(int32(cg), &items))).toBe("[2 x i32] [i32 1, i32 2]");
    }
}

describe("phiNode") {
    test("should join one value from each incoming block") {
        const cg = open("");
        defer close();
        void enter(cg, []);
        const left = block(cg, "left");
        const right = block(cg, "right");
        const join = block(cg, "join");
        positionAtEnd(cg, join);
        const values: Value[2] = [constInt(int32(cg), 1), constInt(int32(cg), 2)];
        const blocks: Block[2] = [left, right];

        expect(show(cg, phiNode(cg, int32(cg), &values, &blocks, "v")))
            .toInclude("%v = phi i32 [ 1, %left ], [ 2, %right ]");
    }
}

describe("elementPointer") {
    test("should give the address of an element inside its bounds") {
        const cg = open("");
        defer close();
        const params: Type[1] = [cg.ptrType];
        const fn = enter(cg, &params);
        const array = llvm.LLVMArrayType2(int32(cg), 4);
        const indices: Value[2] = [constInt(int64(cg), 0), constInt(int64(cg), 2)];

        expect(show(cg, elementPointer(cg, array, llvm.LLVMGetParam(fn, 0), &indices, "e")))
            .toInclude("%e = getelementptr inbounds [4 x i32], ptr %0, i64 0, i64 2");
    }
}

describe("extract") {
    test("should read a field of an aggregate value") {
        const cg = open("");
        defer close();
        const fields: Type[2] = [int32(cg), int1Type(cg)];
        const params: Type[1] = [structType(cg, &fields)];
        const fn = enter(cg, &params);

        expect(show(cg, extract(cg, llvm.LLVMGetParam(fn, 0), 1, "f")))
            .toInclude("%f = extractvalue { i32, i1 } %0, 1");
    }
}

describe("insert") {
    test("should give the aggregate with one field replaced") {
        const cg = open("");
        defer close();
        const fields: Type[2] = [int32(cg), int1Type(cg)];
        const params: Type[1] = [structType(cg, &fields)];
        const fn = enter(cg, &params);

        expect(show(cg, insert(cg, llvm.LLVMGetParam(fn, 0), constBool(cg, true), 1)))
            .toInclude("insertvalue { i32, i1 } %0, i1 true, 1");
    }
}

describe("load") {
    test("should read a value through a pointer") {
        const cg = open("");
        defer close();
        const params: Type[1] = [cg.ptrType];
        const fn = enter(cg, &params);

        expect(show(cg, load(cg, int32(cg), llvm.LLVMGetParam(fn, 0), "v"))).toInclude("%v = load i32, ptr %0");
    }
}

describe("store") {
    test("should write a value through a pointer") {
        const cg = open("");
        defer close();
        const params: Type[1] = [cg.ptrType];
        const fn = enter(cg, &params);
        store(cg, constInt(int32(cg), 5), llvm.LLVMGetParam(fn, 0));

        expect(show(cg, fn)).toInclude("store i32 5, ptr %0");
    }
}

describe("branch") {
    test("should end the current block with a jump") {
        const cg = open("");
        defer close();
        const fn = enter(cg, []);
        branch(cg, block(cg, "next"));

        expect(terminated(cg)).toBe(true);
        expect(show(cg, fn)).toInclude("br label %next");
    }
}

describe("condBr") {
    test("should end the current block with a jump that a condition picks") {
        const cg = open("");
        defer close();
        const params: Type[1] = [int1Type(cg)];
        const fn = enter(cg, &params);
        condBr(cg, llvm.LLVMGetParam(fn, 0), block(cg, "yes"), block(cg, "no"));

        expect(show(cg, fn)).toInclude("br i1 %0, label %yes, label %no");
    }
}

describe("compareIntegers") {
    test("should compare two integers with a predicate") {
        const cg = open("");
        defer close();
        const params: Type[2] = [int32(cg), int32(cg)];
        const fn = enter(cg, &params);

        expect(show(cg, compareIntegers(cg, llvm.LLVMIntSLT, llvm.LLVMGetParam(fn, 0), llvm.LLVMGetParam(fn, 1))))
            .toInclude("icmp slt i32 %0, %1");
    }
}

describe("optionalIsPointer") {
    test("should tell an optional pointer from an optional value") {
        const cg = openProgram();
        defer close();

        expect(optionalIsPointer(cg, typeNamed(cg, "q"))).toBe(true);
        expect(optionalIsPointer(cg, typeNamed(cg, "o"))).toBe(false);
    }
}

describe("errorUnionIsBare") {
    test("should tell an error union without a value from one with a value") {
        const cg = openProgram();
        defer close();

        expect(errorUnionIsBare(cg, returnOf(cg, "bare"))).toBe(true);
        expect(errorUnionIsBare(cg, returnOf(cg, "full"))).toBe(false);
    }
}

describe("hasValue") {
    test("should tell a result type with a value from void and noreturn") {
        const cg = openProgram();
        defer close();

        expect(hasValue(cg, cg.types.i32)).toBe(true);
        expect(hasValue(cg, cg.types.voidType)).toBe(false);
        expect(hasValue(cg, returnOf(cg, "stop"))).toBe(false);
    }
}

describe("lower") {
    test("should give the LLVM type of a scalar") {
        const cg = openProgram();
        defer close();

        expect(showType(cg, lower(cg, cg.types.i32))).toBe("i32");
        expect(showType(cg, lower(cg, cg.types.boolType))).toBe("i1");
        expect(showType(cg, lower(cg, cg.types.f64))).toBe("double");
    }

    test("should give an optional value a presence flag and an optional pointer none") {
        const cg = openProgram();
        defer close();

        expect(showType(cg, lower(cg, typeNamed(cg, "o")))).toBe("{ i32, i1 }");
        expect(showType(cg, lower(cg, typeNamed(cg, "q")))).toBe("ptr");
    }

    test("should give a slice a pointer and a length") {
        const cg = openProgram();
        defer close();

        expect(showType(cg, lower(cg, typeNamed(cg, "s")))).toBe("{ ptr, i64 }");
    }

    test("should give an array its element count") {
        const cg = openProgram();
        defer close();

        expect(showType(cg, lower(cg, typeNamed(cg, "a")))).toBe("[2 x i32]");
    }

    test("should give an error union its value and an error code") {
        const cg = openProgram();
        defer close();

        expect(showType(cg, lower(cg, returnOf(cg, "full")))).toBe("{ i32, i16 }");
        expect(showType(cg, lower(cg, returnOf(cg, "bare")))).toBe("i16");
    }

    test("should name a struct after the module") {
        const cg = openProgram();
        defer close();
        const p = lower(cg, typeNamed(cg, "p"));

        expect(showType(cg, p)).toBe("%test.P = type { i32, i64 }");
        expect(showType(cg, llvm.LLVMStructGetTypeAtIndex(p, 1))).toBe("i64");
    }

    test("should give the same type for the same id") {
        const cg = openProgram();
        defer close();

        expect(same(lower(cg, typeNamed(cg, "o")), lower(cg, typeNamed(cg, "o")))).toBe(true);
    }
}

describe("lowerFunction") {
    test("should give the LLVM function type of a function type") {
        const cg = openProgram();
        defer close();

        expect(showType(cg, lowerFunction(cg, typeNamed(cg, "fn1")))).toBe("i64 (i32, i1)");
    }
}

describe("constInt") {
    test("should build an integer constant of a type") {
        const cg = open("");
        defer close();

        expect(show(cg, constInt(int32(cg), -1))).toBe("i32 -1");
    }

    test("should build a constant wider than 64 bits") {
        const cg = open("");
        defer close();
        const wide = llvm.LLVMIntTypeInContext(cg.ctx, 128);

        expect(show(cg, constInt(wide, (1 as i128) << 100))).toBe("i128 1267650600228229401496703205376");
    }
}

describe("constUsize") {
    test("should build a constant of the usize type") {
        const cg = openProgram();
        defer close();

        expect(show(cg, constUsize(cg, 3))).toBe("i64 3");
    }
}

describe("constBool") {
    test("should build an i1 constant") {
        const cg = open("");
        defer close();

        expect(show(cg, constBool(cg, true))).toBe("i1 true");
        expect(show(cg, constBool(cg, false))).toBe("i1 false");
    }
}

describe("constGlobal") {
    test("should hold a constant in a private global with an unnamed address") {
        const cg = open("");
        defer close();

        expect(show(cg, constGlobal(cg, constInt(int32(cg), 7), "g"))).toBe("@g = private unnamed_addr constant i32 7");
    }
}

describe("cstring") {
    test("should hold the bytes in a global that ends in NUL") {
        const cg = open("");
        defer close();

        expect(show(cg, cstring(cg, "hi", "s"))).toBe("@s = private unnamed_addr constant [3 x i8] c\"hi\\00\"");
    }
}

describe("constPair") {
    test("should build a constant of a struct with two fields") {
        const cg = open("");
        defer close();

        expect(show(cg, constPair(cg, constInt(int32(cg), 1), constBool(cg, false))))
            .toBe("{ i32, i1 } { i32 1, i1 false }");
    }
}

describe("constErrorCode") {
    test("should build a constant of the error code type") {
        const cg = openProgram();
        defer close();

        expect(show(cg, constErrorCode(cg, 3))).toBe("i16 3");
    }
}

describe("knownCondition") {
    test("should give 1 for a condition that the checker found true") {
        const cg = openProgram();
        defer close();

        expect(knownCondition(cg, initOf(cg, "t"))).toBe(1);
    }

    test("should give 0 for a condition that the checker found false") {
        const cg = openProgram();
        defer close();

        expect(knownCondition(cg, initOf(cg, "f"))).toBe(0);
    }

    test("should give -1 for a condition only known at run time") {
        const cg = openProgram();
        defer close();

        expect(knownCondition(cg, initOf(cg, "k"))).toBe(-1);
    }
}

describe("emitConst") {
    test("should build a constant for a computed integer") {
        const cg = openProgram();
        defer close();

        expect(show(cg, emitConst(cg, infoOf(cg, initOf(cg, "x")).value, cg.types.i32))).toBe("i32 5");
    }

    test("should wrap a value in an optional with its presence flag set") {
        const cg = openProgram();
        defer close();

        expect(show(cg, emitConst(cg, infoOf(cg, initOf(cg, "o")).value, typeNamed(cg, "o"))))
            .toBe("{ i32, i1 } { i32 5, i1 true }");
    }

    test("should give null an optional of zeros") {
        const cg = openProgram();
        defer close();

        expect(show(cg, emitConst(cg, infoOf(cg, initOf(cg, "n")).value, typeNamed(cg, "n"))))
            .toBe("{ i32, i1 } zeroinitializer");
    }

    test("should point a string at a global holding its bytes") {
        const cg = openProgram();
        defer close();

        expect(show(cg, emitConst(cg, infoOf(cg, initOf(cg, "s")).value, typeNamed(cg, "s"))))
            .toBe("{ ptr, i64 } { ptr @str, i64 2 }");
    }

    test("should build a constant array for a computed array") {
        const cg = openProgram();
        defer close();

        expect(show(cg, emitConst(cg, infoOf(cg, initOf(cg, "a")).value, typeNamed(cg, "a"))))
            .toBe("[2 x i32] [i32 3, i32 4]");
    }
}

describe("optionalPresent") {
    test("should read the presence flag of an optional value") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [lower(cg, typeNamed(cg, "o"))];
        const fn = enter(cg, &params);

        expect(show(cg, optionalPresent(cg, llvm.LLVMGetParam(fn, 0), typeNamed(cg, "o"))))
            .toInclude("%present = extractvalue { i32, i1 } %0, 1");
    }

    test("should compare an optional pointer with null") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [cg.ptrType];
        const fn = enter(cg, &params);

        expect(show(cg, optionalPresent(cg, llvm.LLVMGetParam(fn, 0), typeNamed(cg, "q"))))
            .toInclude("%present = icmp ne ptr %0, null");
    }
}

describe("optionalPayload") {
    test("should read the value of an optional value") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [lower(cg, typeNamed(cg, "o"))];
        const fn = enter(cg, &params);

        expect(show(cg, optionalPayload(cg, llvm.LLVMGetParam(fn, 0), typeNamed(cg, "o"))))
            .toInclude("%payload = extractvalue { i32, i1 } %0, 0");
    }

    test("should give an optional pointer back as it is") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [cg.ptrType];
        const fn = enter(cg, &params);
        const p = llvm.LLVMGetParam(fn, 0);

        expect(same(optionalPayload(cg, p, typeNamed(cg, "q")), p)).toBe(true);
    }
}

describe("optionalSome") {
    test("should wrap a value with the presence flag set") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [int32(cg)];
        const fn = enter(cg, &params);
        const some = optionalSome(cg, llvm.LLVMGetParam(fn, 0), typeNamed(cg, "o"));

        expect(show(cg, some)).toInclude("i1 true, 1");
        expect(show(cg, fn)).toInclude("insertvalue { i32, i1 } undef, i32 %0, 0");
    }

    test("should give a pointer back as it is") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [cg.ptrType];
        const fn = enter(cg, &params);
        const p = llvm.LLVMGetParam(fn, 0);

        expect(same(optionalSome(cg, p, typeNamed(cg, "q")), p)).toBe(true);
    }
}

describe("errorUnionCode") {
    test("should read the error code of an error union with a value") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [lower(cg, returnOf(cg, "full"))];
        const fn = enter(cg, &params);

        expect(show(cg, errorUnionCode(cg, llvm.LLVMGetParam(fn, 0), returnOf(cg, "full"))))
            .toInclude("%code = extractvalue { i32, i16 } %0, 1");
    }

    test("should give a bare error union back as its own code") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [lower(cg, returnOf(cg, "bare"))];
        const fn = enter(cg, &params);
        const v = llvm.LLVMGetParam(fn, 0);

        expect(same(errorUnionCode(cg, v, returnOf(cg, "bare")), v)).toBe(true);
    }
}

describe("errorUnionPayload") {
    test("should read the value of an error union") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [lower(cg, returnOf(cg, "full"))];
        const fn = enter(cg, &params);

        expect(show(cg, errorUnionPayload(cg, llvm.LLVMGetParam(fn, 0), returnOf(cg, "full"))))
            .toInclude("%value = extractvalue { i32, i16 } %0, 0");
    }

    test("should give null for a bare error union") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [lower(cg, returnOf(cg, "bare"))];
        const fn = enter(cg, &params);

        expect(errorUnionPayload(cg, llvm.LLVMGetParam(fn, 0), returnOf(cg, "bare")) == null).toBe(true);
    }
}

describe("errorUnionMake") {
    test("should build an error union from a value and a code") {
        const cg = openProgram();
        defer close();

        expect(show(cg, errorUnionMake(cg, constInt(int32(cg), 1), constErrorCode(cg, 0), returnOf(cg, "full"))))
            .toBe("{ i32, i16 } { i32 1, i16 0 }");
    }

    test("should leave the value undefined when there is none") {
        const cg = openProgram();
        defer close();

        expect(show(cg, errorUnionMake(cg, null, constErrorCode(cg, 3), returnOf(cg, "full"))))
            .toBe("{ i32, i16 } { i32 undef, i16 3 }");
    }

    test("should give the code alone for a bare error union") {
        const cg = openProgram();
        defer close();
        const code = constErrorCode(cg, 3);

        expect(same(errorUnionMake(cg, null, code, returnOf(cg, "bare")), code)).toBe(true);
    }
}

describe("callIntrinsic") {
    test("should declare and call an overloaded intrinsic") {
        const cg = open("");
        defer close();
        const params: Type[1] = [int1Type(cg)];
        const fn = enter(cg, &params);
        const args: Value[2] = [llvm.LLVMGetParam(fn, 0), constBool(cg, false)];

        expect(show(cg, callIntrinsic(cg, "llvm.expect", int1Type(cg), &args)))
            .toInclude("call i1 @llvm.expect.i1(i1 %0, i1 false)");
    }
}

describe("addAttribute") {
    test("should add an attribute to a function") {
        const cg = open("");
        defer close();
        const fn = llvm.LLVMAddFunction(cg.mod, "h", fnType(voidType(cg), [], false));
        addAttribute(cg, fn, "cold");

        expect(showModule(cg)).toInclude("attributes #0 = { cold }");
    }
}

describe("addStringAttribute") {
    test("should add a key and value attribute to a function") {
        const cg = open("");
        defer close();
        const fn = llvm.LLVMAddFunction(cg.mod, "h", fnType(voidType(cg), [], false));
        addStringAttribute(cg, fn, "frame-pointer", "all");

        expect(showModule(cg)).toInclude("attributes #0 = { \"frame-pointer\"=\"all\" }");
    }
}

describe("diFile") {
    test("should describe the source file in the debug info") {
        expect(ir("export function f(): i32 { return 1; }\n", true))
            .toInclude("!DIFile(filename: \"test.hx\", directory: \".\")");
    }
}

describe("diPosition") {
    test("should give the line and column of a token") {
        const cg = open("const x: i32 = 5;\nconst y: i32 = 6;\n");
        defer close();
        const pos = diPosition(cg, symbolOf(cg, symbolNamed(cg, "y")).token);

        expect(pos.line).toBe(2);
        expect(pos.col).toBe(7);
    }
}

describe("setLocation") {
    test("should tie the instructions of a function to their source lines") {
        const text = ir("export function f(a: i32): i32 {\n    return a;\n}\n", true);

        expect(text).toInclude("!DILocation(line: 2,");
    }

    test("should leave instructions without a location when there is no debug info") {
        expect(ir("export function f(a: i32): i32 {\n    return a;\n}\n", false)).not.toInclude("!dbg");
    }
}

describe("diType") {
    test("should describe an integer type by its name and sign") {
        expect(ir("export function f(a: i32): i32 { return a; }\n", true))
            .toInclude("!DIBasicType(name: \"i32\", size: 32, encoding: DW_ATE_signed)");
    }

    test("should describe a struct with its fields") {
        const text = ir("struct P { x: i32, y: i64 }\nexport function f(p: P): i32 { return p.x; }\n", true);

        expect(text).toInclude("!DICompositeType(tag: DW_TAG_structure_type, name: \"P\"");
        expect(text).toInclude("!DIDerivedType(tag: DW_TAG_member, name: \"y\"");
    }
}

describe("debuggable") {
    test("should describe a local of a type that a debugger can show") {
        expect(ir("export function f(): i32 { let y: i32 = 1; return y; }\n", true)).toInclude("#dbg_declare(");
    }
}

describe("declareVariable") {
    test("should name a parameter and a local in the debug info") {
        const text = ir("export function f(a: i32): i32 { let y: i32 = a; return y; }\n", true);

        expect(text).toInclude("!DILocalVariable(name: \"a\", arg: 1");
        expect(text).toInclude("!DILocalVariable(name: \"y\"");
    }
}

describe("declareC") {
    test("should declare a C function once and give it back after that") {
        const cg = open("");
        defer close();
        const params: Type[1] = [cg.ptrType];
        const type = fnType(int32(cg), &params, false);
        const first = declareC(cg, "puts", type);

        expect(same(declareC(cg, "puts", type), first)).toBe(true);
        expect(show(cg, first)).toInclude("declare i32 @puts(ptr)");
    }
}

describe("buildPanicHandler") {
    test("should add the panic functions once") {
        const cg = openProgram();
        defer close();
        buildPanicHandler(cg);
        buildPanicHandler(cg);
        const text = showModule(cg);

        expect(text).toInclude("define internal void @helix.panic(ptr %0, i64 %1, ptr %2)");
        expect(text).toInclude("define internal void @helix.panic_bounds(ptr %0, i64 %1, i64 %2)");
        expect(text).not.toInclude("@helix.panic.1");
    }

    test("should flush the output, print the message, and abort") {
        const cg = openProgram();
        defer close();
        buildPanicHandler(cg);
        const text = show(cg, cg.panicFn);

        expect(text).toInclude("call i32 @fflush(ptr null)");
        expect(text).toInclude("@dprintf(i32 2, ptr @panic.fmt");
        expect(text).toInclude("call void @hx_stack_trace()");
        expect(text).toInclude("call void @abort()");
    }
}

describe("locationString") {
    test("should hold the source location of a node as it shows in a diagnostic") {
        const cg = openProgram();
        defer close();

        expect(show(cg, locationString(cg, initOf(cg, "x")))).toInclude("c\" --> test.hx:1:16\\0A");
    }
}

describe("emitPanic") {
    test("should call the panic handler with the message and the location, then end the block") {
        const cg = openProgram();
        defer close();
        const fn = enter(cg, []);
        emitPanic(cg, initOf(cg, "x"), "boom");
        const text = show(cg, fn);

        expect(text).toInclude("call void @helix.panic(ptr @panic.msg, i64 4, ptr @panic.at)");
        expect(text).toInclude("unreachable");
    }
}

describe("emitCheck") {
    test("should branch to a panic when the condition holds and go on in a block named ok") {
        const cg = openProgram();
        defer close();
        const params: Type[1] = [int1Type(cg)];
        const fn = enter(cg, &params);
        emitCheck(cg, llvm.LLVMGetParam(fn, 0), initOf(cg, "x"), "boom");
        const text = show(cg, fn);

        expect(text).toInclude("call i1 @llvm.expect.i1(i1 %0, i1 false)");
        expect(text).toInclude("label %panic, label %ok");
        expect(fromCString(llvm.LLVMGetBasicBlockName(llvm.LLVMGetInsertBlock(cg.b)))).toBe("ok");
    }
}

describe("emitBoundsCheck") {
    test("should panic with the index and the length when the index is out of bounds") {
        const cg = openProgram();
        defer close();
        const params: Type[2] = [int64(cg), int64(cg)];
        const fn = enter(cg, &params);
        emitBoundsCheck(cg, llvm.LLVMGetParam(fn, 0), llvm.LLVMGetParam(fn, 1), initOf(cg, "x"));
        const text = show(cg, fn);

        expect(text).toInclude("%oob = icmp uge i64 %0, %1");
        expect(text).toInclude("call void @helix.panic_bounds(ptr @panic.at, i64 %0, i64 %1)");
    }

    test("should emit nothing when safety checks are off") {
        const cg = openProgram();
        defer close();
        cg.safe = false;
        const params: Type[2] = [int64(cg), int64(cg)];
        const fn = enter(cg, &params);
        emitBoundsCheck(cg, llvm.LLVMGetParam(fn, 0), llvm.LLVMGetParam(fn, 1), initOf(cg, "x"));

        expect(llvm.LLVMCountBasicBlocks(fn)).toBe(1);
        expect(llvm.LLVMGetFirstInstruction(cg.entryBlock) == null).toBe(true);
    }
}

describe("entryAlloca") {
    test("should put the slot at the top of the entry block") {
        const cg = open("");
        defer close();
        const params: Type[1] = [cg.ptrType];
        const fn = enter(cg, &params);
        void load(cg, int32(cg), llvm.LLVMGetParam(fn, 0), "v");
        positionAtEnd(cg, block(cg, "later"));
        const slot = entryAlloca(cg, int32(cg), "slot");

        expect(same(llvm.LLVMGetFirstInstruction(cg.entryBlock), slot)).toBe(true);
        expect(show(cg, slot)).toInclude("%slot = alloca i32");
    }
}

describe("localStorage") {
    test("should give a local one slot named after it") {
        const cg = openProgram();
        defer close();
        void enter(cg, []);
        const y = symbolNamed(cg, "y");
        const slot = localStorage(cg, y);

        expect(same(localStorage(cg, y), slot)).toBe(true);
        expect(show(cg, slot)).toInclude("%y = alloca i32");
    }
}

describe("detourBegin") {
    test("should point the builder at the entry block of another function") {
        const cg = open("");
        defer close();
        void enter(cg, []);
        const helper = llvm.LLVMAddFunction(cg.mod, "h", fnType(voidType(cg), [], false));
        const d = detourBegin(cg, helper);
        const inside = same(cg.fn, helper) && same(llvm.LLVMGetInsertBlock(cg.b), llvm.LLVMGetEntryBasicBlock(helper));
        detourEnd(cg, d);

        expect(inside).toBe(true);
    }
}

describe("detourEnd") {
    test("should return the builder to where it was") {
        const cg = open("");
        defer close();
        const fn = enter(cg, []);
        const next = block(cg, "next");
        positionAtEnd(cg, next);
        const helper = llvm.LLVMAddFunction(cg.mod, "h", fnType(voidType(cg), [], false));
        detourEnd(cg, detourBegin(cg, helper));

        expect(same(cg.fn, fn)).toBe(true);
        expect(same(llvm.LLVMGetInsertBlock(cg.b), next)).toBe(true);
    }
}

describe("helperFunction") {
    test("should add an internal function that does not unwind") {
        const cg = open("");
        defer close();
        const fn = helperFunction(cg, "h", fnType(voidType(cg), [], false));
        void detourBegin(cg, fn);
        void llvm.LLVMBuildRetVoid(cg.b);

        expect(showModule(cg)).toInclude("define internal void @h() #0");
        expect(showModule(cg)).toInclude("attributes #0 = { nounwind }");
    }
}
