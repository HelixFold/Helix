/**
 * Imports
 */

import { record } from "@models/ast.model";
import { HxAggregate } from "@structs/sema.struct";
import { TypeKind } from "@constants/types.constant";
import { hxArenaFree } from "@services/arena.service";
import { hxTypesInit, hxTypesFree } from "@models/types.model";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { hxZalloc, hxVecGrowImpl } from "@components/memory.component";
import { NodeKind, FlagExtern, NoToken } from "@constants/ast.constant";
import { hxsRunComptimeBlock } from "@modules/sema/components/expr.component";
import { hxsGenericParams } from "@modules/sema/components/generics.component";
import { HxAst, HxFnData, HxContainerData } from "@models/structs/ast-model.struct";
import { hxInternerInit, hxInternerFree, hxIntern } from "@services/intern.service";
import { HxSymGlobal, HxSymGeneric, HxScopeExported } from "@constants/sema.constant";
import { hxsCheckEntry, hxsReportPending } from "@modules/sema/components/decl.component";
import { hxsAddSymbol, hxsScopeFind, pushU32, u32At } from "@modules/sema/components/scope.component";
import { hxsDeclareAggregate, hxsResolveAggregate } from "@modules/sema/components/aggregate.component";
import { hxsCheckTests, hxsDeclareGlobal, hxsCheckFunctionBody } from "@modules/sema/components/decl.component";
import { HxProgram, Ctx, HxU32Vec, HxSema, HxValue, HxNodeInfo, HxInstance, HxSymbol } from "@structs/sema.struct";
import { HxSymUsed, HxSymType, HxSymResolved, HxSymFunction, HxSymTemplateMethod } from "@constants/sema.constant";
import { hxsProcessImports, hxsReportUnusedImports, moduleRoot } from "@modules/sema/components/imports.component";
import { hxsResolveGlobal, hxsResolveSignature, hxsDeclareTesting } from "@modules/sema/components/decl.component";
import { emptyValue, nodeOf, symbolOf, infoOf, extraOf, hxsUnsupported } from "@modules/sema/components/base.component";

/**
 * The C library functions that the checker uses to clear its state, release it, and measure names.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;
extern "C" function memset(to: u8[*], byte: i32, len: usize): ?u8[*];
extern "C" function strlen(text: readonly u8[*]): usize;

/**
 * Checks whether a declaration has type parameters, as `function max<T>(...)` and `struct List<T>` do.
 *
 * @param c - The checker context
 * @param decl - A function or container declaration
 * @returns `true` when its `<...>` list is not empty
 *
 * @remarks
 * Only the type parameter list counts, so a function with `comptime` parameters alone answers `false`.
 * Use {@link hxsHasComptimeParams} for those.
 *
 * @example
 * ```hx
 * // function max<T>(a: T, b: T): T { ... }
 * hxsHasGenerics(c, decl); // true
 * ```
 *
 * @see hxsHasComptimeParams
 * @since 1.0.0
 */

export extern "C" function hxsHasGenerics(c: readonly *Ctx, decl: u32): bool {
    let start: u32 = 0;
    let end: u32 = 0;
    let first: u32 = 0;
    hxsGenericParams(c, decl, &start, &end, &first);
    return start != end;
}

/**
 * Checks whether a function takes `comptime` parameters, which make it a template as type parameters do.
 *
 * @param c - The checker context
 * @param decl - A function declaration
 * @returns `true` when any parameter carries the `comptime` flag
 *
 * @remarks
 * It reads the `comptime` flag of each parameter node, so it works before the signature is resolved.
 *
 * @example
 * ```hx
 * // function repeat(comptime n: u32): void { ... }
 * hxsHasComptimeParams(c, decl); // true
 * ```
 *
 * @see hxsHasGenerics
 * @since 1.0.0
 */

export extern "C" function hxsHasComptimeParams(c: readonly *Ctx, decl: u32): bool {
    const fn = record<HxFnData>(c.ast!, nodeOf(c, decl).a);
    for (const i of fn.paramsStart..fn.paramsEnd) {
        if ((nodeOf(c, extraOf(c, i)).flags & 0x10) != 0) return true;   // FlagComptime
    }
    return false;
}

/**
 * Registers a struct, enum, union, error set, or interface declaration and the methods it declares.
 *
 * @param c - The checker context
 * @param decl - The declaration
 * @param kindNumber - The {@link TypeKind} of the declaration as a number
 *
 * @remarks
 * The declaration gets a type symbol in the current module, and a declaration that is not generic gets its type.
 * A generic struct is a template instead, and `ArrayList<u8>` creates the real type when it is first used.
 * A generic enum is reported as unsupported.
 * Each method becomes a function symbol whose owner is the type.
 * A method of a generic type, or a method with its own type or `comptime` parameters, is marked generic,
 * and the second kind is also marked as a template method that gets an instance for each call.
 * Error sets and interfaces declare no methods, since the members of an interface are only signatures.
 *
 * @example
 * ```hx
 * // struct Point { x: i32, function len(this: *Point): i32 { ... } }
 * hxsDeclareType(c, decl, TypeKind.Struct as u32); // declares Point and Point.len
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsDeclareType(c: *Ctx, decl: u32, kindNumber: u32): void {
    const kind = @enumFromInt(TypeKind, @truncate(u8, kindNumber));
    const sym = hxsDeclareGlobal(c, HxSymType, decl);
    if (sym == 0) return;
    const generic = kind != TypeKind.ErrorSet && hxsHasGenerics(c, decl);
    if (generic && kind == TypeKind.Enum) {
        hxsUnsupported(c, decl, "generic enums");
        return;
    }
    // a generic struct is a template: `ArrayList<u8>` creates the real type when it's first used
    const type = generic ? 0 : hxsDeclareAggregate(c, kindNumber, decl, nodeOf(c, decl).token);
    symbolOf(c, sym).type = type;
    symbolOf(c, sym).flags |= (HxSymResolved | HxSymUsed | (generic ? HxSymGeneric : 0)) as u16;
    if (kind == TypeKind.ErrorSet || kind == TypeKind.Interface) return;   // interface members are only signatures
    const data = record<HxContainerData>(c.ast!, nodeOf(c, decl).a);
    for (const i of data.membersStart..data.membersEnd) {
        const mem = extraOf(c, i);
        if (nodeOf(c, mem).kind != NodeKind.Function || nodeOf(c, mem).token == NoToken) continue;
        const own = hxsHasGenerics(c, mem) || hxsHasComptimeParams(c, mem);   // `map<U>(...)`: instantiated per call
        const method = hxsAddSymbol(c, HxSymFunction, nodeOf(c, mem).token, mem, 0);
        symbolOf(c, method).owner = type;
        symbolOf(c, method).flags |= (HxSymUsed | (generic || own ? HxSymGeneric : 0) | (own ? HxSymTemplateMethod : 0)) as u16;
        infoOf(c, mem).symbol = method;
    }
}

/**
 * Appends one entry to a growable array.
 *
 * @typeParam T - The type of the entries
 * @param items - The array, which may move when it grows
 * @param len - The number of entries, which grows by one
 * @param cap - The capacity of the array
 * @param blank - The entry to append
 *
 * @remarks
 * The checker uses it to reserve index 0 of its tables for the empty entry.
 *
 * @since 1.0.0
 */

function pushBlank<T>(items: *?T[*], len: *u32, cap: *u32, blank: T): void {
    unsafe {
        if (*len == *cap) hxVecGrowImpl(@ptrCast(*?u8[*], items), cap, *len + 1, @sizeOf(T));
        const array = *items;
        array![*len] = blank;
    }
    *len += 1;
}

/**
 * Checks a program: resolves names, checks types, and folds constants.
 *
 * @param s - The checker state to fill, whose previous contents are ignored
 * @param a - The syntax tree of the root file
 * @param program - The files of the program as the driver loaded them, or `null` to check one file alone
 * @param diags - The list that receives the diagnostics
 * @returns `true` when the check reported no new error
 *
 * @remarks
 * The output is a side table of node info indexed by node, plus the symbol table.
 * Code generation reads both and never derives a type again.
 * Checking works in passes over the declarations:
 * - **Collect** - registers every top-level name of every module, so declaration order never matters,
 *   then connects the imports
 * - **Signatures** - resolves type aliases, function and method signatures, then the members of every aggregate
 * - **Globals** - resolves global constants and variables, lazily and with cycle detection
 * - **Bodies** - checks every function body, then the tests of a test build, then the instances that those made
 * - **Comptime** - runs the top-level `comptime` blocks in source order
 *
 * It then checks the entry point, reports the `@compileError` and `@compileLog` calls of used functions,
 * and reports unused imports.
 * Expressions are checked with an optional expected type.
 * Number literals keep a literal type until they meet a concrete type,
 * and an expression whose operands are all known is folded where it stands,
 * so overflow and out-of-range errors in constants are reported while compiling.
 * Without a program, imports are reported as unsupported and pointers are 8 bytes.
 * Release the state with {@link hxSemaFree}, even after errors.
 *
 * @example
 * ```hx
 * let sema: HxSema = undefined;
 * hxSemaCheck(&sema, &ast, null, &diags); // true for a program without errors
 * hxSemaFree(&sema);
 * ```
 *
 * @see hxSemaFree
 * @since 1.0.0
 */

export extern "C" function hxSemaCheck(s: *HxSema, a: *HxAst, program: ?readonly *HxProgram, diags: *HxDiagList): bool {
    unsafe {
        void memset(@ptrCast(u8[*], s), 0, @sizeOf(HxSema));
    }
    s.ast = a;
    s.src = a.src;
    s.diags = diags;
    const pointerBytes = program != null && program.pointerBytes != 0 ? program.pointerBytes : 8;
    hxTypesInit(&s.types, pointerBytes);
    hxInternerInit(&s.names);
    unsafe {
        s.info = @ptrCast(*HxNodeInfo, hxZalloc((a.nodesLen as usize) * @sizeOf(HxNodeInfo)));
        pushBlank<HxSymbol>(@ptrCast(*?HxSymbol[*], &s.symbols.items), &s.symbols.len, &s.symbols.cap, HxSymbol {
            kind: 0, flags: 0, name: 0, token: 0, decl: 0, type: 0, value: 0, owner: 0, instance: 0, module: 0, targetModule: 0,
        });
        pushBlank<HxValue>(@ptrCast(*?HxValue[*], &s.values.items), &s.values.len, &s.values.cap, emptyValue(0));
    }
    unsafe {
        pushU32(@ptrCast(*HxU32Vec, &s.errorNames), 0);
    }

    let ctx: Ctx = undefined;
    unsafe {
        void memset(@ptrCast(u8[*], &ctx), 0, @sizeOf(Ctx));
    }
    ctx.sema = s;
    ctx.ast = a;
    ctx.tokens = a.tokens;
    unsafe {
        ctx.text = @ptrCast(?readonly u8[*], a.src.text);
    }
    ctx.types = &s.types;
    ctx.deferFloor = 0xFFFF_FFFF;
    const c = &ctx;
    const errorsBefore = diags.errorCount;
    s.program = program;
    const moduleCount: u32 = program != null ? program.count : 1;

    // 1. collect every module's declarations, then connect imports
    for (const m of 0..moduleCount) {
        c.module = m;
        const file = nodeOf(c, program != null ? moduleRoot(s, m) : a.root);
        for (const i of file.a..file.b) {
            const decl = extraOf(c, i);
            switch (nodeOf(c, decl).kind) {
                case NodeKind.Function: {
                    const sym = hxsDeclareGlobal(c, HxSymFunction, decl);
                    const isExtern = (nodeOf(c, decl).flags & FlagExtern) != 0;
                    if (sym != 0 && (hxsHasGenerics(c, decl) || (!isExtern && hxsHasComptimeParams(c, decl)))) {
                        symbolOf(c, sym).flags |= HxSymGeneric as u16;
                    }
                }
                case NodeKind.Const, NodeKind.Let: void hxsDeclareGlobal(c, HxSymGlobal, decl);
                case NodeKind.TypeAlias: void hxsDeclareGlobal(c, HxSymType, decl);
                case NodeKind.Struct: hxsDeclareType(c, decl, TypeKind.Struct as u32);
                case NodeKind.Enum: hxsDeclareType(c, decl, TypeKind.Enum as u32);
                case NodeKind.Union: hxsDeclareType(c, decl, TypeKind.Union as u32);
                case NodeKind.ErrorSet: hxsDeclareType(c, decl, TypeKind.ErrorSet as u32);
                case NodeKind.Import: if (program == null) hxsUnsupported(c, decl, "imports in a single-file check");
                case NodeKind.Interface: hxsDeclareType(c, decl, TypeKind.Interface as u32);
                default: {}   // `comptime` blocks run after the bodies are checked
            }
        }
    }
    c.module = 0;
    hxsProcessImports(c);
    hxsDeclareTesting(c);

    // 2. type aliases, function and method signatures, then every aggregate's members
    // these lists grow while they're walked (resolving can add symbols, types and instances), so their lengths are
    // read on every step
    let sym: u32 = 1;
    while (sym < s.symbols.len) {
        if (symbolOf(c, sym).kind == HxSymType as u8 && nodeOf(c, symbolOf(c, sym).decl).kind == NodeKind.TypeAlias) hxsResolveGlobal(c, sym);
        sym += 1;
    }
    sym = 1;
    while (sym < s.symbols.len) {
        if (symbolOf(c, sym).kind == HxSymFunction as u8 && (symbolOf(c, sym).flags & (HxSymGeneric as u16)) == 0) {
            hxsResolveSignature(c, sym);
            const fn = record<HxFnData>(a, nodeOf(c, symbolOf(c, sym).decl).a);
            pushU32(fn.body != 0 ? &s.functions : &s.externs, sym);
        }
        sym += 1;
    }
    let agg: u32 = 0;
    while (agg < s.aggregates.len) {
        unsafe {
            hxsResolveAggregate(c, @ptrCast(HxAggregate[*], s.aggregates.items)[agg].type);
        }
        agg += 1;
    }

    // 3. globals
    const globalCount = s.symbols.len;
    for (const g of 1..globalCount) {
        if (symbolOf(c, g).kind == HxSymGlobal as u8) hxsResolveGlobal(c, g);
    }

    // 4. bodies, then the tests of a test build, then the instances those made
    let f: u32 = 0;
    while (f < s.functions.len) {
        hxsCheckFunctionBody(c, u32At(&s.functions, f));
        f += 1;
    }
    hxsCheckTests(c);
    f = 0;
    while (f < s.functions.len) {
        hxsCheckFunctionBody(c, u32At(&s.functions, f));
        f += 1;
    }

    // 5. top-level `comptime { }` blocks, in source order
    for (const m of 0..moduleCount) {
        const file = nodeOf(c, program != null ? moduleRoot(s, m) : a.root);
        for (const i of file.a..file.b) {
            const decl = extraOf(c, i);
            if (nodeOf(c, decl).kind == NodeKind.ComptimeBlock) hxsRunComptimeBlock(c, decl, m);
        }
    }

    hxsCheckEntry(c);
    hxsReportPending(c);
    hxsReportUnusedImports(c);
    unsafe {
        free(@ptrCast(?u8[*], ctx.scope.items));
        free(@ptrCast(?u8[*], ctx.scopeMarks.items));
        free(@ptrCast(?u8[*], ctx.narrowed.items));
        free(@ptrCast(?u8[*], ctx.unset.items));
        free(@ptrCast(?u8[*], ctx.unsetReads.items));
        free(@ptrCast(?u8[*], ctx.unsetWrites.items));
        free(@ptrCast(?u8[*], ctx.typeParams.items));
    }
    return diags.errorCount == errorsBefore;
}

/**
 * Releases everything that a check allocated.
 *
 * @param s - The checker state to release
 *
 * @remarks
 * The syntax tree and the diagnostics belong to the caller and stay as they are.
 *
 * @example
 * ```hx
 * hxSemaCheck(&sema, &ast, null, &diags);
 * hxSemaFree(&sema);
 * ```
 *
 * @see hxSemaCheck
 * @since 1.0.0
 */

export extern "C" function hxSemaFree(s: *HxSema): void {
    unsafe {
        free(@ptrCast(?u8[*], s.info));
        free(@ptrCast(?u8[*], s.scopes));
        free(@ptrCast(?u8[*], s.symbols.items));
        free(@ptrCast(?u8[*], s.values.items));
        free(@ptrCast(?u8[*], s.valueElems.items));
        free(@ptrCast(?u8[*], s.functions.items));
        free(@ptrCast(?u8[*], s.externs.items));
        free(@ptrCast(?u8[*], s.globals.items));
        free(@ptrCast(?u8[*], s.aggregates.items));
        free(@ptrCast(?u8[*], s.members.items));
        free(@ptrCast(?u8[*], s.errorNames.items));
        for (const i of 0..s.instances.len) free(@ptrCast(?u8[*], @ptrCast(HxInstance[*], s.instances.items)[i].info));
        free(@ptrCast(?u8[*], s.instances.items));
        free(@ptrCast(?u8[*], s.instanceArgs.items));
        free(@ptrCast(?u8[*], s.instanceNames.items));
        free(@ptrCast(?u8[*], s.impls.items));
        free(@ptrCast(?u8[*], s.implMethods.items));
    }
    hxTypesFree(&s.types);
    hxInternerFree(&s.names);
    hxArenaFree(&s.arena);
}

/**
 * Finds the symbol that a module exports under a name.
 *
 * @param s - The checked state
 * @param module - The module index, where 0 is the root
 * @param name - The name, NUL-terminated
 * @returns The symbol, or 0 when the module declares no such name or does not export it
 *
 * @remarks
 * It reads the scope of the module after a check, so it finds only top-level declarations.
 * A name that the module declares without `export` gives 0, just like a missing one.
 *
 * @example
 * ```hx
 * // export function main(): void {}
 * hxSemaExport(&sema, 0, "main"); // the symbol of main
 * hxSemaExport(&sema, 0, "other"); // 0
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxSemaExport(s: *HxSema, module: u32, name: readonly u8[*]): u32 {
    const entry = hxsScopeFind(s, module, hxIntern(&s.names, name, @truncate(u32, strlen(name))));
    return entry != null && (entry.flags & (HxScopeExported as u8)) != 0 ? entry.symbol : 0;
}
