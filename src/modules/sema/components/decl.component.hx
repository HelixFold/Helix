/**
 * Imports
 */

import { record } from "@models/ast.model";
import { hxIntern } from "@services/intern.service";
import { TypeKind } from "@constants/types.constant";
import { HxValueFunction } from "@constants/sema.constant";
import { hxSourceLineCol, files } from "@models/source.model";
import { hxsMarkUsed } from "@modules/sema/components/call.component";
import { hxZalloc, hxVecGrowImpl } from "@components/memory.component";
import { hxsCheckLocal } from "@modules/sema/components/stmt.component";
import { hxsCheckStmt } from "@modules/sema/components/switch.component";
import { hxsDeclareLocal } from "@modules/sema/components/scope.component";
import { instanceName } from "@modules/sema/components/generics.component";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { HxFnData, HxContainerData } from "@models/structs/ast-model.struct";
import { saveUnset, restoreUnset } from "@modules/sema/components/unset.component";
import { hxTypeBuiltin, hxTypeFunction, hxTypeErrorUnion } from "@models/types.model";
import { hxsFindMember, hxsMemberOf } from "@modules/sema/components/aggregate.component";
import { typeName, errorNode, errorToken } from "@modules/sema/components/base.component";
import { instanceNote, hxsSaveState, hxsRestoreState } from "@modules/sema/components/generics.component";
import { HxSymGeneric, HxSymResolving, HxScopeImported, HxValueAggregate } from "@constants/sema.constant";
import { HxSymFunction, HxSymArrow, HxSymFailed, HxSymUsed, HxSymResolved } from "@constants/sema.constant";
import { hxsReportRedeclared, pushU32, u32At, hxsAddSymbol } from "@modules/sema/components/scope.component";
import { HxSymExtern, HxScopeUsed, HxSymModule, HxScopeExported, HxSymMutable } from "@constants/sema.constant";
import { NodeKind, FlagExtern, FlagExport, FlagVariadic, FlagComptime, NoToken } from "@constants/ast.constant";
import { Ctx, HxValue, HxModule, Pending, HxSema, Reach, HxU32Vec, HxSymbol, FnState } from "@structs/sema.struct";
import { hxsScopeFind, hxsScopeInsert, hxsPushScope, hxsPopScope } from "@modules/sema/components/scope.component";
import { hxsValueOf, hxsFormatEscapes, types, tokenText, tokenStart } from "@modules/sema/components/base.component";
import { typeOf, symbolOf, infoOf, extraOf, hint, hintf, hxsTokName } from "@modules/sema/components/base.component";
import { HxSymChecked, HxSymChecking, HxSymLocal, HxSymParam, HxSymEntry, HxSymType } from "@constants/sema.constant";
import { hxsEnterInstance, hxsInstanceName, instance, instanceArg } from "@modules/sema/components/generics.component";
import { hxsUnsupported, hxsAggregateOf, infoAt, semaOf, astOf, nodeOf } from "@modules/sema/components/base.component";

/**
 * The C library function that releases the buffers of the pending-message pass.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;

/**
 * Compares two strings byte by byte.
 *
 * @param a - The first string
 * @param b - The second string
 * @returns `true` when both strings have the same bytes
 *
 * @remarks
 * Compares the lengths first, so texts of different lengths return early without reading a byte.
 * The comparison is exact, so letters of different case never match.
 *
 * @since 1.0.0
 */

function sameText(a: string, b: string): bool {
    if (a.len != b.len) return false;
    for (const ch, i of a) {
        if (b[i] != ch) return false;
    }
    return true;
}

/**
 * Resolves a global or a type alias on first use, so its type and constant value are known.
 *
 * @param c - The checker context
 * @param sym - The symbol of the global or the type alias
 *
 * @remarks
 * The declaration is checked in its own module, with only globals in scope.
 * A global whose value refers back to itself draws a `depends on itself` error.
 * A generic type alias is not supported.
 * Where a global lives depends on its declaration:
 * - **`extern`** - a C global, mutable when it is a `let`, and kept in the list of globals.
 * - **A constant array or struct** - stored once in the list of globals and read where it is used.
 * - **Any other constant** - its value replaces every read, so it takes no storage.
 * - **A `let`** - a mutable global, kept in the list of globals.
 *
 * Later calls return at once.
 *
 * @example
 * ```hx
 * // const a: i32 = b; const b: i32 = a;
 * hxsResolveGlobal(c, a); // error: `a` depends on itself
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsResolveGlobal(c: *Ctx, sym: u32): void {
    if ((symbolOf(c, sym).flags & (HxSymResolved as u16)) != 0) return;
    if ((symbolOf(c, sym).flags & (HxSymResolving as u16)) != 0) {
        const diag = errorToken(c, symbolOf(c, sym).token, `\`${tokenText(c, symbolOf(c, sym).token)}\` depends on itself`);
        hint(c, diag, "a global's value can't refer back to the global being defined");
        symbolOf(c, sym).flags |= HxSymResolved as u16;
        return;
    }
    symbolOf(c, sym).flags |= HxSymResolving as u16;
    const saved = c.globalsOnly;
    const savedModule = c.module;
    c.globalsOnly = true;
    c.module = symbolOf(c, sym).module;
    const decl = symbolOf(c, sym).decl;
    const n = nodeOf(c, decl);
    const s = semaOf(c);
    if (symbolOf(c, sym).kind == HxSymType as u8) {
        const data = record<HxContainerData>(astOf(c), n.a);
        if (data.genericsStart != data.genericsEnd) hxsUnsupported(c, decl, "generic type aliases");
        const t = hxsResolveType(c, n.b);
        symbolOf(c, sym).type = t;
    } else {
        void hxsCheckLocal(c, decl, true);
        symbolOf(c, sym).type = infoOf(c, decl).type;   // fetched again: the symbol vector may have grown
        const v = n.b != 0 ? hxsValueOf(c, n.b) : null;
        if ((n.flags & FlagExtern) != 0) {
            symbolOf(c, sym).flags |= (HxSymExtern | (n.kind == NodeKind.Let ? HxSymMutable : 0)) as u16;
            pushU32(&s.globals, sym);
        } else if (n.kind == NodeKind.Const && v != null && v.kind == HxValueAggregate as u8) {
            pushU32(&s.globals, sym);   // a constant array or struct: stored once, read where used
        } else if (n.kind == NodeKind.Const && v != null) {
            symbolOf(c, sym).value = infoOf(c, n.b).value;
        } else {
            symbolOf(c, sym).flags |= HxSymMutable as u16;
            pushU32(&s.globals, sym);
        }
    }
    c.globalsOnly = saved;
    c.module = savedModule;
    symbolOf(c, sym).flags = (symbolOf(c, sym).flags & ~(HxSymResolving as u16)) | (HxSymResolved as u16);
}

/**
 * Finds the value bound to a `comptime` parameter in the current instance.
 *
 * @param c - The checker context
 * @param token - The name token of the parameter
 * @returns The value bound to the parameter, or 0 outside an instance or when the name has no binding
 *
 * @remarks
 * Only the value arguments of the instance are searched, never its type arguments.
 *
 * @example
 * ```hx
 * // function f(comptime n: usize): u8[n] { ... }  f(3);
 * hxsComptimeArg(c, token); // the value 3 while the f(3) instance is checked
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsComptimeArg(c: readonly *Ctx, token: u32): u32 {
    if (c.instance == 0) return 0;
    const inst = *instance(c, c.instance);
    const name = tokenText(c, token);
    for (const i of inst.typeCount..inst.argsCount) {
        if (sameText(name, tokenText(c, instanceName(semaOf(c), inst.argsStart + i)))) return instanceArg(semaOf(c), inst.argsStart + i);
    }
    return 0;
}

/**
 * Resolves the function type of a function from the module that declares it.
 *
 * @param c - The checker context
 * @param sym - The symbol of the function
 *
 * @remarks
 * The current module is switched to the function's own module and back,
 * so the names in the signature resolve where the function was written.
 *
 * @example
 * ```hx
 * // function add(a: i32, b: i32): i32 { ... }
 * hxsResolveSignature(c, sym); // the symbol's type becomes (i32, i32) => i32
 * ```
 *
 * @see hxsResolveSignatureInModule
 * @since 1.0.0
 */

export extern "C" function hxsResolveSignature(c: *Ctx, sym: u32): void {
    const savedModule = c.module;
    c.module = symbolOf(c, sym).module;
    hxsResolveSignatureInModule(c, sym);
    c.module = savedModule;
}

/**
 * Resolves the function type of a function in the current module.
 *
 * @param c - The checker context
 * @param sym - The symbol of the function
 *
 * @remarks
 * A generic function is a template, so only its instances get a signature and it is skipped.
 * A `comptime` parameter takes the value of the current instance and is visible to the types after it,
 * as in `(comptime n: usize): u8[n]`.
 * Only plain functions with a `comptime` parameter become templates,
 * so a `comptime` parameter without a bound value is an error on a C function or a method.
 * The checker also reports these mistakes:
 * - a `void` parameter
 * - a format value escaping through the return type
 * - a variadic function that is not `extern "C"`
 * - an `extern` with a calling convention other than `"C"`
 * - a function without a body that is not `extern "C"`
 *
 * The symbol gets its function type only when every parameter and the return type resolved.
 * The parameters stop at 256.
 *
 * @example
 * ```hx
 * // function f(x: void): void {}
 * hxsResolveSignatureInModule(c, sym); // error: a parameter can't be `void`
 * ```
 *
 * @see hxsResolveSignature
 * @since 1.0.0
 */

export extern "C" function hxsResolveSignatureInModule(c: *Ctx, sym: u32): void {
    const decl = symbolOf(c, sym).decl;
    const n = nodeOf(c, decl);
    const fn = record<HxFnData>(astOf(c), n.a);
    const isExtern = (n.flags & FlagExtern) != 0;
    const name = n.token != NoToken ? tokenText(c, n.token) : "?";
    const tys = types(c);
    if ((symbolOf(c, sym).flags & (HxSymGeneric as u16)) != 0) return;   // a template: only its instances get signatures

    let params: u32[256] = undefined;
    let count: u32 = 0;
    let ok = true;
    hxsPushScope(c);   // `comptime` parameters, visible to the types after them: `(comptime n: usize): u8[n]`
    for (const i of fn.paramsStart..fn.paramsEnd) {
        if (count >= 256) break;
        const p = extraOf(c, i);
        if ((nodeOf(c, p).flags & FlagComptime) != 0) {
            const t = hxsResolveType(c, nodeOf(c, p).a);
            infoOf(c, p).type = t;
            const v = hxsComptimeArg(c, nodeOf(c, p).token);
            if (v == 0) {
                void errorNode(c, p, isExtern ? "a C function can't take `comptime` parameters"
                                              : "`comptime` parameters only work on functions, not methods, for now");
                ok = false;
                continue;
            }
            const local = hxsDeclareLocal(c, HxSymLocal, nodeOf(c, p).token, p, t);
            if (local != 0) {
                symbolOf(c, local).value = v;
                symbolOf(c, local).flags |= HxSymUsed as u16;
            }
            continue;
        }
        const t = hxsResolveType(c, nodeOf(c, p).a);
        if (t == 0) ok = false;
        if (t == tys.voidType) {
            void errorNode(c, nodeOf(c, p).a, "a parameter can't be `void`");
            ok = false;
        }
        infoOf(c, p).type = t;
        params[count] = t;
        count += 1;
    }
    const ret = hxsResolveType(c, fn.returnType);
    if (fn.returnType != 0 && ret == 0) ok = false;
    if (hxsFormatEscapes(c, ret, fn.returnType)) ok = false;
    hxsPopScope(c);

    const variadic = (n.flags & FlagVariadic) != 0;
    if (variadic && !isExtern) {
        const diag = errorToken(c, n.token, "only `extern \"C\"` functions can be variadic");
        hint(c, diag, "take a slice instead: `args: readonly T[]`");
    }
    if (isExtern) {
        const abi = tokenText(c, fn.abiToken);
        if (abi.len != 3 || abi[1] != 'C') void errorToken(c, fn.abiToken, "only `extern \"C\"` is supported");
    }
    if (fn.body == 0 && !isExtern) {
        const diag = errorToken(c, n.token, `function \`${name}\` has no body`);
        hint(c, diag, "add `{ ... }`, or declare a C function with `extern \"C\"`");
    }
    if (ok) symbolOf(c, sym).type = hxTypeFunction(tys, ret, &params, count, variadic);
    infoOf(c, decl).type = symbolOf(c, sym).type;
}

/**
 * Checks the body of a function once its signature is known.
 *
 * @param c - The checker context
 * @param sym - The symbol of the function or the method instance
 *
 * @remarks
 * A function is skipped when it has no body or type, when it is a generic template or an arrow function,
 * or when it is already checked or being checked.
 * The checker's per-function state is saved, set up for the function, and restored afterwards,
 * so checking can start from inside another function's body.
 * The parameters become locals, and a `comptime` parameter takes the value of the current instance.
 * A body that can reach its end without a `return` draws an error, unless the payload of its result is `void`,
 * and a `noreturn` function must never reach its end.
 * For an instance of a generic function or method, the errors get a note that names the instance.
 * A body that drew an error marks its symbol as failed.
 *
 * @example
 * ```hx
 * // function f(): i32 { }
 * hxsCheckFunctionBody(c, sym); // error: `f` can reach its end without returning a `i32`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckFunctionBody(c: *Ctx, sym: u32): void {
    const decl = symbolOf(c, sym).decl;
    const n = nodeOf(c, decl);
    const fn = record<HxFnData>(astOf(c), n.a);
    const skip = (HxSymGeneric | HxSymArrow | HxSymChecked | HxSymChecking) as u16;
    if (fn.body == 0 || symbolOf(c, sym).type == 0 || (symbolOf(c, sym).flags & skip) != 0) return;
    symbolOf(c, sym).flags |= HxSymChecking as u16;
    const tys = types(c);

    let saved: FnState = undefined;
    hxsSaveState(c, &saved);
    const errorsBefore = semaOf(c).diags!.errorCount;
    c.instance = 0;
    c.typeParams.len = 0;
    c.scopeBase = c.scope.len;
    c.globalsOnly = false;
    c.inTest = false;
    c.deadDepth = 0;
    c.module = symbolOf(c, sym).module;
    if (symbolOf(c, sym).instance != 0) hxsEnterInstance(c, symbolOf(c, sym).instance);

    const ret = typeOf(c, symbolOf(c, sym).type).child;
    const fallible = typeOf(c, ret).kind == TypeKind.ErrorUnion;
    const payload = fallible ? typeOf(c, ret).child : ret;
    c.returnType = ret;
    c.errorSet = fallible ? @truncate(u32, typeOf(c, ret).len) : 0;
    c.functionSymbol = sym;
    c.loopCount = 0;
    c.inDefer = false;
    c.deferFloor = 0xFFFF_FFFF;
    c.unsafeDepth = 0;
    c.comptimeDepth = 0;

    const outerUnset = saveUnset(c);
    c.unset.len = 0;
    hxsPushScope(c);
    for (const i of fn.paramsStart..fn.paramsEnd) {
        const param = extraOf(c, i);
        const p = hxsDeclareLocal(c, HxSymParam, nodeOf(c, param).token, param, infoOf(c, param).type);
        infoOf(c, param).symbol = p;
        if (p != 0 && (nodeOf(c, param).flags & FlagComptime) != 0) symbolOf(c, p).value = hxsComptimeArg(c, nodeOf(c, param).token);
    }
    const terminated = hxsCheckStmt(c, fn.body);
    hxsPopScope(c);
    restoreUnset(c, outerUnset);

    if (!terminated && payload != tys.voidType) {
        const name = tokenText(c, n.token);
        if (payload == tys.noreturnType) {
            void errorToken(c, n.token, `\`${name}\` is declared \`noreturn\` but can return`);
        } else {
            const diag = errorToken(c, n.token, `\`${name}\` can reach its end without returning a \`${typeName(c, payload)}\``);
            hint(c, diag, "add a `return` on every path");
        }
    }
    if (symbolOf(c, sym).instance != 0) {
        const inst = *instance(c, symbolOf(c, sym).instance);
        const fnName = tokenText(c, nodeOf(c, decl).token);
        if (symbolOf(c, sym).owner != 0) {
            let what: u8[256] = undefined;
            let used: usize = 0;
            for (const ch of typeName(c, symbolOf(c, sym).owner)) {
                if (used < 255) {
                    what[used] = ch;
                    used += 1;
                }
            }
            if (used < 255) {
                what[used] = '.';
                used += 1;
            }
            for (const ch of fnName) {
                if (used < 255) {
                    what[used] = ch;
                    used += 1;
                }
            }
            instanceNote(c, inst.site, what[0..used], errorsBefore);
        } else {
            let nameLen: u32 = 0;
            const name = hxsInstanceName(c, nodeOf(c, decl).token, &inst, &nameLen);
            unsafe {
                instanceNote(c, inst.site, name[0..nameLen], errorsBefore);
            }
        }
    }
    const failed = semaOf(c).diags!.errorCount != errorsBefore ? HxSymFailed as u16 : 0;
    symbolOf(c, sym).flags = (symbolOf(c, sym).flags & ~(HxSymChecking as u16)) | (HxSymChecked as u16) | failed;
    hxsRestoreState(c, &saved);
}

/**
 * Finds the file node of a module of the program.
 *
 * @param s - The checker state, which must have a program
 * @param module - The index of the module
 * @returns The file node at the root of the module
 *
 * @remarks
 * Unwraps the program without a check, so a check without a program stops here.
 * The index counts from 0, so the testing module, which the program numbers from 1, needs one subtracted.
 *
 * @since 1.0.0
 */

function moduleRoot(s: readonly *HxSema, module: u32): u32 {
    unsafe {
        return @ptrCast(HxModule[*], s.program!.modules)[module].root;
    }
}

/**
 * Finds the `_startup` function that builds the standard library's `Init` for `main(init: Init)`.
 *
 * @param c - The checker context
 * @param type - The type of `main`'s parameter
 * @returns The symbol of `_startup`, or 0 when the type is not std's `Init`
 *
 * @remarks
 * The type must be a struct named `Init` declared in a file whose path ends with `/std/process.hx`,
 * wherever the compiler is installed.
 * That module's `_startup` must be a function that returns the type,
 * and it builds the value from argc and argv.
 * A single-file check has no program and always gives 0.
 *
 * @example
 * ```hx
 * // import { Init } from "std";  export function main(init: Init): void { ... }
 * hxsInitStartup(c, initType); // the symbol of std's _startup
 * ```
 *
 * @see hxsCheckEntry
 * @since 1.0.0
 */

export extern "C" function hxsInitStartup(c: *Ctx, type: u32): u32 {
    const s = semaOf(c);
    if (s.program == null || typeOf(c, type).kind != TypeKind.Struct) return 0;
    const t = typeOf(c, type);
    const module = hxsAggregateOf(c, type).module;
    if (t.nameLen != 4) return 0;
    unsafe {
        if (!sameText(t.name![0..4], "Init")) return 0;
    }
    // std's file, wherever the compiler is installed: `.../std/process.hx`
    const file = hxSourceLineCol(s.src!, tokenStart(c, nodeOf(c, moduleRoot(s, module)).token)).file;
    unsafe {
        const pathPtr = files(s.src!)[file].path;
        let len: usize = 0;
        while (pathPtr[len] != 0) len += 1;
        if (len < 15 || !sameText(pathPtr[len - 15..len], "/std/process.hx")) return 0;
    }
    const entry = hxsScopeFind(s, module, hxIntern(&s.names, "_startup", 8));
    if (entry == null || symbolOf(c, entry.symbol).kind != HxSymFunction as u8 || symbolOf(c, entry.symbol).type == 0) return 0;
    if (typeOf(c, symbolOf(c, entry.symbol).type).child != type) return 0;
    hxsMarkUsed(c, entry.symbol);
    return entry.symbol;
}

/**
 * Checks the `main` function of the root module and records it as the entry point.
 *
 * @param c - The checker context
 *
 * @remarks
 * A root module without a `main` function of its own has no entry point, and nothing is checked.
 * An imported `main` and an `extern` one do not count.
 * `main` takes nothing or a single `init: Init` from std.
 * Its result is `void`, `noreturn`, `u8`, or `i32`, optionally joined with errors such as `void | Error`,
 * and the returned number becomes the exit code of the process.
 * Any other shape draws an error with a hint.
 *
 * @example
 * ```hx
 * // export function main(): bool { ... }
 * hxsCheckEntry(c); // error: `main` must return `void`, `u8` or `i32`, found `bool`
 * ```
 *
 * @see hxsInitStartup
 * @since 1.0.0
 */

export extern "C" function hxsCheckEntry(c: *Ctx): void {
    const s = semaOf(c);
    const tys = types(c);
    const entry = hxsScopeFind(s, 0, hxIntern(&s.names, "main", 4));   // `main` of the root module
    const sym = entry != null && (entry.flags & (HxScopeImported as u8)) == 0 ? entry.symbol : 0;
    if (sym == 0 || symbolOf(c, sym).kind != HxSymFunction as u8 || (symbolOf(c, sym).flags & (HxSymExtern as u16)) != 0) return;
    const type = symbolOf(c, sym).type;
    if (type == 0) return;
    const fn = typeOf(c, type);
    const token = symbolOf(c, sym).token;
    let badParams = fn.len > 1;
    if (fn.len == 1) {
        unsafe {
            s.entryInit = hxsInitStartup(c, tys.params![fn.params]);
        }
        badParams = s.entryInit == 0;
    }
    if (badParams) {
        const diag = errorToken(c, token, "`main` takes nothing, or `init: Init`");
        hint(c, diag, "import `Init` from \"std\": `export function main(init: Init): void | Error`");
        return;
    }
    const ret = fn.child;
    const payload = typeOf(c, ret).kind == TypeKind.ErrorUnion ? typeOf(c, ret).child : ret;
    if (payload != tys.voidType && payload != tys.noreturnType && payload != tys.u8 && payload != tys.i32) {
        const diag = errorToken(c, token, `\`main\` must return \`void\`, \`u8\` or \`i32\`, found \`${typeName(c, ret)}\``);
        hint(c, diag, "the returned number becomes the process exit code; errors may be added: `void | Error`");
        return;
    }
    symbolOf(c, sym).flags |= (HxSymEntry | HxSymUsed) as u16;
    s.entry = sym;
}

/**
 * Marks a function as reached and queues its body for the walk.
 *
 * @param r - The state of the walk
 * @param sym - The symbol, where 0 and symbols that are not functions do nothing
 *
 * @remarks
 * A function is queued only the first time it is reached.
 *
 * @example
 * ```hx
 * hxsReach(&r, s.entry); // main is reached and queued
 * ```
 *
 * @see hxsReportPending
 * @since 1.0.0
 */

export extern "C" function hxsReach(r: *Reach, sym: u32): void {
    const s = r.sema!;
    if (sym == 0 || sym >= s.symbols.len) return;
    unsafe {
        const reached = @ptrCast(bool[*], r.reached!);
        if (reached[sym] || @ptrCast(HxSymbol[*], s.symbols.items)[sym].kind != HxSymFunction as u8) return;
        reached[sym] = true;
    }
    pushU32(&r.work, sym);
}

/**
 * Reaches the functions that a node refers to.
 *
 * @param r - The state of the walk
 * @param inst - The instance that the node is checked in, or 0
 * @param node - The node
 *
 * @remarks
 * The node's symbol covers a call, and a function constant covers a function used as a value.
 *
 * @example
 * ```hx
 * // const h = g;
 * hxsReachFrom(&r, 0, node); // g is reached
 * ```
 *
 * @see hxsReach
 * @since 1.0.0
 */

export extern "C" function hxsReachFrom(r: *Reach, inst: u32, node: u32): void {
    const info = *infoAt(r.sema!, inst, node);
    hxsReach(r, info.symbol);
    if (info.value != 0) {
        unsafe {
            const v = @ptrCast(HxValue[*], r.sema!.values.items)[info.value];
            if (v.kind == HxValueFunction as u8) hxsReach(r, @truncate(u32, v.integer));
        }
    }
}

/**
 * Views a NUL-terminated string as a slice.
 *
 * @param text - The first byte of the text
 * @returns The text up to the NUL byte, sharing the bytes
 *
 * @remarks
 * Counts the bytes up to the NUL and then slices without a copy, so the result lives only as long as the text.
 *
 * @since 1.0.0
 */

function fromCString(text: readonly u8[*]): string {
    unsafe {
        let n: usize = 0;
        while (text[n] != 0) n += 1;
        return text[0..n];
    }
}

/**
 * Reports the `@compileError`s and `@compileLog`s of the functions that the program uses.
 *
 * @param c - The checker context
 *
 * @remarks
 * Like Zig, an `@compileError` in a function that nothing reaches does not fire.
 * The walk starts from these roots:
 * - `main` and the `_startup` that builds its `Init`
 * - std/testing's `beginTest` and `endTest` in a test build
 * - functions that C can call, which are `extern "C"` functions with a body
 * - interface implementations
 * - whatever the code outside function bodies refers to, such as globals and `comptime` blocks
 *
 * Checking a file without `main` that is not a test build treats it as a library,
 * so every function of the root module counts as used.
 * The walk then follows the calls and function values of each reached body.
 * A reached `@compileLog` is reported as an error too, which stops the build so that it is never left in by mistake.
 * An `@compileError` inside a generic instance gets a hint that names the instance.
 * The pending messages and their buffers are released afterwards.
 *
 * @example
 * ```hx
 * // function f(): void { @compileError("boom"); }  export function main(): void { f(); }
 * hxsReportPending(c); // error: boom
 * ```
 *
 * @see hxsReach
 * @since 1.0.0
 */

export extern "C" function hxsReportPending(c: *Ctx): void {
    if (c.pending.len == 0) return;
    const s = semaOf(c);
    const a = astOf(c);
    let r = Reach { sema: s, reached: null, work: HxU32Vec { items: null, len: 0, cap: 0 } };
    let inside: bool[*] = undefined;   // nodes of some function's (or template's) body
    unsafe {
        r.reached = @ptrCast(*bool, hxZalloc((s.symbols.len as usize) * @sizeOf(bool)));
        inside = @ptrCast(bool[*], hxZalloc(a.nodesLen as usize));
    }
    for (const id of 1..a.nodesLen) {
        const k = nodeOf(c, id).kind;
        if (k != NodeKind.Function && k != NodeKind.ArrowFunction) continue;
        const fn = record<HxFnData>(a, nodeOf(c, id).a);
        if (fn.body == 0) continue;
        unsafe {
            for (const j of fn.firstNode..id + 1) inside[j] = true;
        }
    }
    for (const id of 1..a.nodesLen) {
        unsafe {
            if (!inside[id]) hxsReachFrom(&r, 0, id);
        }
    }
    hxsReach(&r, s.entry);
    hxsReach(&r, s.entryInit);
    hxsReach(&r, s.testBegin);
    hxsReach(&r, s.testEnd);
    const library = s.entry == 0 && !(s.program != null && s.program!.test);
    for (const i of 0..s.functions.len) {
        const sym = u32At(&s.functions, i);
        if ((symbolOf(c, sym).flags & (HxSymExtern as u16)) != 0 || (library && symbolOf(c, sym).module == 0)) hxsReach(&r, sym);
    }
    for (const i of 0..s.implMethods.len) hxsReach(&r, u32At(&s.implMethods, i));

    while (r.work.len > 0) {
        r.work.len -= 1;
        const sym = u32At(&r.work, r.work.len);
        const decl = symbolOf(c, sym).decl;
        const k = nodeOf(c, decl).kind;
        if (k != NodeKind.Function && k != NodeKind.ArrowFunction) continue;
        const fn = record<HxFnData>(a, nodeOf(c, decl).a);
        for (const j of fn.firstNode..decl + 1) hxsReachFrom(&r, symbolOf(c, sym).instance, j);
    }

    for (const i of 0..c.pending.len) {
        let p: Pending = undefined;
        unsafe {
            p = @ptrCast(Pending[*], c.pending.items)[i];
        }
        let reached = p.functionSymbol == 0;
        unsafe {
            if (!reached) reached = @ptrCast(bool[*], r.reached!)[p.functionSymbol];
        }
        if (reached) {
            const message = fromCString(p.message!);
            if (p.log) {
                const diag = errorNode(c, p.node, `compile log: ${message}`);
                hint(c, diag, "`@compileLog` stops the build, so it's never left in by mistake; remove it when you're done");
            } else {
                const diag = errorNode(c, p.node, `${message}`);
                if (p.functionSymbol != 0 && symbolOf(c, p.functionSymbol).instance != 0) {
                    const inst = *instance(c, symbolOf(c, p.functionSymbol).instance);
                    let nameLen: u32 = 0;
                    const name = hxsInstanceName(c, nodeOf(c, symbolOf(c, p.functionSymbol).decl).token, &inst, &nameLen);
                    unsafe {
                        hintf(c, diag, `in \`${name[0..nameLen]}\``);
                    }
                }
            }
        }
        free(p.message);
    }
    unsafe {
        free(@ptrCast(?u8[*], c.pending.items));
        free(@ptrCast(?u8[*], r.work.items));
        free(@ptrCast(?u8[*], r.reached));
        free(@ptrCast(?u8[*], inside));
    }
    c.pending.items = null;
    c.pending.len = 0;
    c.pending.cap = 0;
}

/**
 * Starts checking a test body, hook, or fixture as if it were the body of a `(): void | Error` function.
 *
 * @param c - The checker context
 *
 * @remarks
 * The per-function state is reset for the root module, so `try` works inside a test,
 * and the code is marked as test code.
 * The caller saves the state before and restores it afterwards.
 *
 * @example
 * ```hx
 * hxsEnterTestCode(c); // a test body may now use try
 * ```
 *
 * @see hxsCheckTestBlock
 * @since 1.0.0
 */

export extern "C" function hxsEnterTestCode(c: *Ctx): void {
    c.instance = 0;
    c.typeParams.len = 0;
    c.globalsOnly = false;
    c.module = 0;
    c.returnType = semaOf(c).testResult;
    c.errorSet = types(c).anyError;
    c.functionSymbol = 0;
    c.loopCount = 0;
    c.inDefer = false;
    c.deferFloor = 0xFFFF_FFFF;
    c.unsafeDepth = 0;
    c.comptimeDepth = 0;
    c.inTest = true;
}

/**
 * Checks the block of a test or hook as test code.
 *
 * @param c - The checker context
 * @param block - The block node
 *
 * @remarks
 * Saves the state of the function being checked, switches to test code, and restores the state afterward,
 * so checking a test block in the middle of another check leaves the settings of that check intact.
 * Test code returns the test result type, so a test body may use `try`.
 *
 * @example
 * ```hx
 * // test("adds") { const x: i32 = true; }
 * hxsCheckTestBlock(c, block); // error: expected `i32`, found `bool`
 * ```
 *
 * @see hxsEnterTestCode
 * @since 1.0.0
 */

export extern "C" function hxsCheckTestBlock(c: *Ctx, block: u32): void {
    let saved: FnState = undefined;
    hxsSaveState(c, &saved);
    hxsEnterTestCode(c);
    void hxsCheckStmt(c, block);
    hxsRestoreState(c, &saved);
}

/**
 * Checks a `describe`, `test`, or hook, or a fixture inside a `describe`.
 *
 * @param c - The checker context
 * @param node - The item node
 *
 * @remarks
 * A `describe` opens a scope for its items.
 * Its `let` and `const` declarations are its fixtures, which are locals that every test and hook inside it sees.
 * Each test runs in its own process, so it gets its own copy of them.
 * A fixture's initializer is checked as test code, so it may use `try`.
 *
 * @example
 * ```hx
 * // describe("a") { const n: i32 = 1; test("b") { const x: i32 = n; } }
 * hxsCheckTestItem(c, node); // n is visible in the test
 * ```
 *
 * @see hxsCheckTests
 * @since 1.0.0
 */

export extern "C" function hxsCheckTestItem(c: *Ctx, node: u32): void {
    const n = nodeOf(c, node);
    switch (n.kind) {
        case NodeKind.Describe: {
            hxsPushScope(c);
            for (const i of n.a..n.b) hxsCheckTestItem(c, extraOf(c, i));
            hxsPopScope(c);
        }
        case NodeKind.Test, NodeKind.Hook: if (n.a != 0) hxsCheckTestBlock(c, n.a);
        case NodeKind.Let, NodeKind.Const: {
            let saved: FnState = undefined;
            hxsSaveState(c, &saved);
            hxsEnterTestCode(c);   // an initializer may use `try`
            void hxsCheckLocal(c, node, false);
            hxsRestoreState(c, &saved);
        }
        default: {}
    }
}

/**
 * Finds an exported symbol of std/testing that test builds rely on.
 *
 * @param c - The checker context
 * @param namePtr - The NUL-terminated name of the symbol
 * @param kind - The symbol kind that the name must have
 * @returns The symbol, or 0 after reporting that it is missing
 *
 * @remarks
 * A missing symbol means that the standard library next to the compiler is broken, which the error says.
 * A symbol of the right kind without a type counts as missing.
 *
 * @example
 * ```hx
 * hxsTestingSymbol(c, "beginTest", HxSymFunction); // the symbol of std/testing's beginTest
 * ```
 *
 * @see hxsCheckTests
 * @since 1.0.0
 */

export extern "C" function hxsTestingSymbol(c: *Ctx, namePtr: readonly u8[*], kind: u32): u32 {
    const s = semaOf(c);
    const name = fromCString(namePtr);
    const module = s.program!.testingModule - 1;
    const entry = hxsScopeFind(s, module, hxIntern(&s.names, name.ptr, @truncate(u32, name.len)));
    if (entry != null && symbolOf(c, entry.symbol).kind == kind as u8 && symbolOf(c, entry.symbol).type != 0) {
        hxsMarkUsed(c, entry.symbol);
        return entry.symbol;
    }
    void errorToken(c, nodeOf(c, moduleRoot(s, module)).token, `std/testing has no \`${name}\`; the standard library next to the compiler is broken`);
    return 0;
}

/**
 * Makes `testing` visible in the root module of a test build without an import.
 *
 * @param c - The checker context
 *
 * @remarks
 * The name refers to the std/testing module.
 * A root module that declares its own `testing` keeps it, and builds that are not test builds are left alone.
 *
 * @example
 * ```hx
 * // test("b") { const a = testing.allocator; }
 * hxsDeclareTesting(c); // testing resolves without an import
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsDeclareTesting(c: *Ctx): void {
    const s = semaOf(c);
    if (s.program == null || !s.program!.test || s.program!.testingModule == 0) return;
    const program = s.program!;
    const name = hxIntern(&s.names, "testing", 7);
    if (hxsScopeFind(s, 0, name) != null) return;
    const token = nodeOf(c, moduleRoot(s, program.testingModule - 1)).token;
    const sym = HxSymbol {
        kind: HxSymModule as u8, flags: (HxSymResolved | HxSymUsed) as u16, name, token, decl: 0, type: 0,
        value: 0, owner: 0, instance: 0, module: 0, targetModule: program.testingModule - 1,
    };
    const list = &s.symbols;
    unsafe {
        if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, @sizeOf(HxSymbol));
        @ptrCast(HxSymbol[*], list.items)[list.len] = sym;
    }
    list.len += 1;
    const entry = hxsScopeInsert(s, 0, name);
    entry.symbol = list.len - 1;
    entry.token = token;
    entry.flags = (HxScopeImported | HxScopeUsed) as u8;
}

/**
 * Checks the `describe` and `test` blocks of the root module in a test build.
 *
 * @param c - The checker context
 *
 * @remarks
 * Other builds skip the blocks entirely.
 * The checker first finds std/testing's `beginTest`, `endTest`, and `TestError`,
 * and records the code of `TestError.RequireFailed`.
 * A top-level `let` or `const` is a global, which the checker handles with the other globals, not a fixture.
 *
 * @example
 * ```hx
 * // test("b") { const x: i32 = true; }
 * hxsCheckTests(c); // error: expected `i32`, found `bool`
 * ```
 *
 * @see hxsCheckTestItem
 * @since 1.0.0
 */

export extern "C" function hxsCheckTests(c: *Ctx): void {
    const s = semaOf(c);
    if (s.program == null || !s.program!.test || s.program!.testingModule == 0) return;
    const tys = types(c);
    s.testResult = hxTypeErrorUnion(tys, tys.voidType, tys.anyError);
    s.testBegin = hxsTestingSymbol(c, "beginTest", HxSymFunction);
    s.testEnd = hxsTestingSymbol(c, "endTest", HxSymFunction);
    const errorSet = hxsTestingSymbol(c, "TestError", HxSymType);
    if (errorSet != 0) {
        const type = symbolOf(c, errorSet).type;
        const index = hxsFindMember(c, type, hxIntern(&s.names, "RequireFailed", 13));
        if (index >= 0) s.requireCode = @truncate(u32, hxsMemberOf(c, type, index).value);
    }
    c.module = 0;
    const file = nodeOf(c, moduleRoot(s, 0));
    for (const i of file.a..file.b) {   // a top-level `let`/`const` is a global, checked with the others, not a fixture
        const kind = nodeOf(c, extraOf(c, i)).kind;
        if (kind != NodeKind.Let && kind != NodeKind.Const) hxsCheckTestItem(c, extraOf(c, i));
    }
}

/**
 * Declares a top-level function, global, or type alias in the current module.
 *
 * @param c - The checker context
 * @param kind - The symbol kind
 * @param decl - The declaration node
 * @returns The new symbol, or 0 when the declaration has no name or the name is taken
 *
 * @remarks
 * A built-in type name such as `i32` cannot be declared,
 * and a name that the module already declares draws a redeclaration error.
 * An `extern` function is marked as extern, and an `export` makes the name visible to importers.
 *
 * @example
 * ```hx
 * // const a = 1; const a = 2;
 * hxsDeclareGlobal(c, HxSymGlobal, second); // 0, the name is already declared
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsDeclareGlobal(c: *Ctx, kind: u32, decl: u32): u32 {
    const token = nodeOf(c, decl).token;
    if (token == NoToken) return 0;
    const name = hxsTokName(c, token);
    const text = tokenText(c, token);
    if (hxTypeBuiltin(types(c), text.ptr, @truncate(u32, text.len)) != 0) {
        void errorToken(c, token, `\`${text}\` is a built-in type name`);
        return 0;
    }
    if (const existing = hxsScopeFind(semaOf(c), c.module, name)) {
        hxsReportRedeclared(c, token, existing.symbol);
        return 0;
    }
    const sym = hxsAddSymbol(c, kind, token, decl, 0);
    if (kind == HxSymFunction && (nodeOf(c, decl).flags & FlagExtern) != 0) symbolOf(c, sym).flags |= HxSymExtern as u16;
    const entry = hxsScopeInsert(semaOf(c), c.module, name);
    entry.symbol = sym;
    entry.token = token;
    entry.flags = (nodeOf(c, decl).flags & FlagExport) != 0 ? HxScopeExported as u8 : 0;
    infoOf(c, decl).symbol = sym;
    return sym;
}
