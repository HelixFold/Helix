/**
 * Imports
 */

import { record } from "@models/ast.model";
import { TypeKind } from "@constants/types.constant";
import { Version } from "@constants/version.constant";
import { hxArenaFree } from "@services/arena.service";
import { equal, startsWith, endsWith } from "std/text";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { HxArena } from "@services/structs/arena-service.struct";
import { HxFnData, HxTestData } from "@models/structs/ast-model.struct";
import { hxStrndup, hxVecGrowImpl } from "@components/memory.component";
import { NodeKind, FlagComptime, NoToken } from "@constants/ast.constant";
import { ModeReleaseFast } from "@modules/codegen/constants/base.constant";
import { TestTable } from "@modules/codegen/structs/codegen-module.struct";
import { HookBeforeAll } from "@modules/codegen/constants/codegen.constant";
import { HxSema, HxInstance, HxU32Vec, HxModule } from "@structs/sema.struct";
import { hxSemaInstanceArg } from "@modules/sema/components/generics.component";
import { emitValue, errorName } from "@modules/codegen/components/expr.component";
import { detourBegin, detourEnd } from "@modules/codegen/components/base.component";
import { signFunctionPointers } from "@modules/codegen/components/ptrauth.component";
import { emitStmt, emitScoped, emitLocal } from "@modules/codegen/components/stmt.component";
import { ModeReleaseSmall, ModeDebug, ModeReleaseSafe } from "@modules/codegen/constants/base.constant";
import { TestEntryDescribe, TestEntryEnd, TestEntryTest } from "@modules/codegen/constants/codegen.constant";
import { errorUnionCode, localStorage, declareC, llvmName } from "@modules/codegen/components/base.component";
import { HxSymExtern, HxSymGlobal, HxSymAddressed, HxSymFunction, HxSymArrow } from "@constants/sema.constant";
import { extra, aggregate, errorUnionPayload, addAttribute } from "@modules/codegen/components/base.component";
import { needsCAbi, declareCFunction, emitCWrapper, targetArch } from "@modules/codegen/components/abi.component";
import { HookBeforeEach, HookAfterEach, ModeNames, ModeCnames } from "@modules/codegen/constants/codegen.constant";
import { fnType, call, lower, nodeOf, infoOf, typeOf, symbolOf } from "@modules/codegen/components/base.component";
import { Cg, Value, Type, Meta, HxCodegenOptions } from "@modules/codegen/components/structs/base-component.struct";
import { emitConst, condBr, compareIntegers, diFile, diPosition } from "@modules/codegen/components/base.component";
import { fromCString, llvmBool, tokenText, tokenName, finalType } from "@modules/codegen/components/base.component";
import { sourcePath, terminated, zeroed, release, push, vectorAt } from "@modules/codegen/components/base.component";
import { setLocation, declareVariable, positionAtEnd, int32, int64 } from "@modules/codegen/components/base.component";
import { addStringAttribute, lowerFunction, cstring, constErrorCode } from "@modules/codegen/components/base.component";

/**
 * The C library functions that this module declares.
 *
 * @remarks
 * `free` releases the vectors and the test table that the module grows on the C heap.
 * `strlen` has no caller here.
 *
 * @since 1.0.0
 */

extern "C" function free(ptr: ?u8[*]): void;
extern "C" function strlen(text: readonly u8[*]): usize;

/**
 * Reads the name of a build mode.
 *
 * @param text - The name to read, such as `release-safe`
 * @param mode - Receives the mode, one of the `MODE_` constants, when the name is known
 * @returns `true` for a known name, or `false` when the name is not one of the four modes
 *
 * @remarks
 * The names are `debug`, `release-safe`, `release-fast`, and `release-small`, in the order of their numbers.
 * The driver reads `--mode` with it, and leaves `mode` alone for a name that it does not know.
 *
 * @example
 * ```hx
 * let mode: u32 = 0;
 * hxModeParse("release-fast", &mode); // true, and mode is ModeReleaseFast
 * hxModeParse("fast", &mode);         // false
 * ```
 *
 * @see hxModeName
 * @since 1.0.0
 */

export extern "C" function hxModeParse(text: readonly u8[*], mode: *u32): bool {
    for (const name, i of ModeNames) {
        if (equal(fromCString(text), name)) {
            *mode = @truncate(u32, i);
            return true;
        }
    }
    return false;
}

/**
 * Names a build mode.
 *
 * @param mode - The mode, one of the `MODE_` constants
 * @returns The NUL-terminated name of the mode, such as `release-safe`
 *
 * @remarks
 * The name is a constant, so the caller does not free it.
 * The mode must be one of the four modes, since the name comes straight out of {@link ModeCnames}.
 *
 * @example
 * ```hx
 * hxModeName(ModeDebug); // "debug"
 * ```
 *
 * @see hxModeParse
 * @since 1.0.0
 */

export extern "C" function hxModeName(mode: u32): readonly u8[*] {
    return ModeCnames[mode];
}

/**
 * Gives the prefix of the symbol names of a module.
 *
 * @param cg - The code generator
 * @param module - The index of the module in the program
 * @returns The name of the module, or the module name of the options when there is no program
 *
 * @remarks
 * A single file checked without a program uses the module name of the options.
 *
 * @since 1.0.0
 */

function moduleName(cg: *Cg, module: u32): string {
    if (const program = cg.sema.program) {
        unsafe {
            return fromCString(@ptrCast(HxModule[*], program.modules)[module].name);
        }
    }
    return fromCString(cg.options.module_name);
}

/**
 * Finds a generic instance by its number.
 *
 * @param cg - The code generator
 * @param instance - The number of the instance, which starts at 1
 * @returns The instance in the instance table of the checker
 *
 * @remarks
 * Instance numbers start at 1, since 0 means code outside any generic instance, so the lookup subtracts one.
 * It does not check the number, so a caller tests for 0 first.
 *
 * @since 1.0.0
 */

function instanceAt(cg: *Cg, instance: u32): *HxInstance {
    unsafe {
        return &@ptrCast(HxInstance[*], cg.sema.instances.items)[instance - 1];
    }
}

/**
 * Builds the LLVM name of a function or a global.
 *
 * @param cg - The code generator
 * @param sym - The symbol to name
 * @returns The name, which lives as long as the code generator
 *
 * @remarks
 * - **Extern** - a function or global declared `extern` keeps its own name, which is its C name
 * - **Arrow function** - an anonymous function is numbered, as in `main.arrow.12`
 * - **Top level** - a plain function or global is `module.name`, as in `main.helper`
 * - **Member** - a method or member constant adds its owner, as in `main.User.rename` or `main.List<u8>.push`
 * - **Generic instance** - the type arguments follow in angle brackets,
 *   as in `main.max<i32>` or `main.List<u8>.map<i32>`
 *
 * The type arguments that belong to the owner already appear in its name,
 * so the instance adds only the ones after them.
 *
 * @since 1.0.0
 */

function symbolName(cg: *Cg, sym: u32): readonly u8[*] {
    const s = symbolOf(cg, sym);
    const prefix = moduleName(cg, s.module);
    const text = tokenText(cg, s.token);
    if ((s.flags & (HxSymArrow as u16)) != 0) return llvmName(cg, `${prefix}.arrow.${sym}`);   // anonymous: numbered
    const isFunctionOrGlobal = s.kind == HxSymFunction as u8 || s.kind == HxSymGlobal as u8;
    if (isFunctionOrGlobal && (s.flags & (HxSymExtern as u16)) != 0) return llvmName(cg, `${text}`);
    if (s.owner == 0 && s.instance == 0) return llvmName(cg, `${prefix}.${text}`);

    // methods and member constants: `main.User.rename`, `main.List<u8>.push`, `main.List<u8>.map<i32>`;
    // generic function instances: `main.max<i32>`
    let base: string = "";
    let first: u32 = 0;   // instance arguments that belong to the owner, already in its name
    if (s.owner != 0) {
        const owner = typeOf(cg, s.owner);
        let ownerName: string = "";
        unsafe {
            if (owner.name != null) ownerName = owner.name![0..owner.nameLen];
        }
        base = fromCString(llvmName(cg, `${prefix}.${ownerName}.${text}`));
        const ownerInstance = aggregate(cg, s.owner).instance;
        if (ownerInstance != 0) first = instanceAt(cg, ownerInstance).argsCount;
    } else {
        base = fromCString(llvmName(cg, `${prefix}.${text}`));
    }
    if (s.instance == 0 || instanceAt(cg, s.instance).argsCount <= first) return llvmName(cg, `${base}`);
    const inst = instanceAt(cg, s.instance);
    let args: string = "";
    let arg: u8[96] = undefined;
    for (const i of first..inst.argsCount) {
        hxSemaInstanceArg(cg.sema, inst, i, &arg, 96);
        args = fromCString(llvmName(cg, `${args}${i > first ? ", " : ""}${fromCString(&arg)}`));
    }
    return llvmName(cg, `${base}<${args}>`);
}

/**
 * Declares every function and extern function of the program before any body exists.
 *
 * @param cg - The code generator
 *
 * @remarks
 * Every function can then call any other, whatever the order of the bodies.
 * An extern function whose signature needs the C calling convention goes through {@link declareCFunction}.
 * When such a function has a body, Helix calls it as `name.helix`,
 * and a wrapper that {@link emitCWrapper} writes later keeps the name `name` for C.
 * Two modules may declare the same C function, so they share one declaration.
 *
 * A function with a body is `nounwind`, keeps frame pointers in a safe mode for reliable stack traces,
 * and is `optsize` in `release-small`.
 * A release build makes every non-extern function internal,
 * while a debug build keeps their symbols visible so that a panic's stack trace can name them.
 * A function that returns `noreturn` is marked `noreturn`.
 *
 * @since 1.0.0
 */

function declareFunctions(cg: *Cg): void {
    for (const l of 0..2) {
        const list = l == 0 ? &cg.sema.functions : &cg.sema.externs;
        for (const i of 0..list.len) {
            const sym = vectorAt(list, i);
            if (symbolOf(cg, sym).type == 0) continue;
            let name = symbolName(cg, sym);
            const isExtern = (symbolOf(cg, sym).flags & (HxSymExtern as u16)) != 0;
            const hasBody = l == 0;
            const cAbi = isExtern && needsCAbi(cg, symbolOf(cg, sym).type);
            if (cAbi && hasBody) {   // Helix calls `name.helix`; C calls the wrapper named `name`
                name = llvmName(cg, `${fromCString(name)}.helix`);
                push(&cg.cWrappers, sym);
            }
            cg.cAbi[sym] = cAbi && !hasBody;
            // Two modules may declare the same C function; they share one declaration.
            let fn: Value = l == 1 ? llvm.LLVMGetNamedFunction(cg.mod, name) : null;
            if (fn == null && cg.cAbi[sym]) fn = declareCFunction(cg, name, symbolOf(cg, sym).type);
            else if (fn == null) fn = llvm.LLVMAddFunction(cg.mod, name, lowerFunction(cg, symbolOf(cg, sym).type));
            cg.storage[sym] = fn;
            if (cAbi && hasBody) llvm.LLVMSetLinkage(fn, llvm.LLVMInternalLinkage);
            if (hasBody) {
                addAttribute(cg, fn, "nounwind");
                if (cg.safe) addStringAttribute(cg, fn, "frame-pointer", "all");   // reliable stack traces
                if (cg.options.mode == ModeReleaseSmall) addAttribute(cg, fn, "optsize");
                // Debug builds keep symbols visible so panic stack traces can name the functions.
                if (!isExtern && cg.options.mode != ModeDebug) llvm.LLVMSetLinkage(fn, llvm.LLVMInternalLinkage);
            }
            if (typeOf(cg, typeOf(cg, symbolOf(cg, sym).type).child).kind == TypeKind.Noreturn) addAttribute(cg, fn, "noreturn");
        }
    }
}

/**
 * Starts the debug information of the function being emitted.
 *
 * @param cg - The code generator
 * @param name - The name of the function
 * @param token - The token where the function starts
 *
 * @remarks
 * The subprogram becomes the scope of the debug locations that follow.
 *
 * @since 1.0.0
 */

function beginSubprogram(cg: *Cg, name: string, token: u32): void {
    const pos = diPosition(cg, token);
    const file = diFile(cg, pos.file);
    const signature = llvm.LLVMDIBuilderCreateSubroutineType(cg.di, file, null, 0, llvm.LLVMDIFlagZero);
    cg.diScope = llvm.LLVMDIBuilderCreateFunction(cg.di, file, name.ptr, name.len, name.ptr, name.len, file, pos.line, signature,
                                                llvmBool(llvm.LLVMGetLinkage(cg.fn) == llvm.LLVMInternalLinkage), 1, pos.line,
                                                llvm.LLVMDIFlagZero, llvmBool(cg.options.mode != ModeDebug));
    llvm.LLVMSetSubprogram(cg.fn, cg.diScope);
}

/**
 * Starts emitting the body of a function.
 *
 * @param cg - The code generator
 * @param fn - The LLVM function
 * @param instance - The generic instance the body belongs to, or 0
 * @param returnType - The type the function returns
 *
 * @remarks
 * It adds the `entry` block, where the allocas of the locals go, and clears the defers and loops of the last function.
 *
 * @since 1.0.0
 */

function beginFunction(cg: *Cg, fn: Value, instance: u32, returnType: u32): void {
    cg.fn = fn;
    cg.instance = instance;
    cg.returnType = returnType;
    cg.entryBlock = llvm.LLVMAppendBasicBlockInContext(cg.ctx, cg.fn, "entry");
    cg.defers.len = 0;
    cg.loopCount = 0;
    positionAtEnd(cg, cg.entryBlock);
}

/**
 * Emits the body of a function.
 *
 * @param cg - The code generator
 * @param sym - The symbol of the function, which {@link declareFunctions} already declared
 *
 * @remarks
 * Each parameter goes into a local of its own.
 * A `comptime` parameter is a constant in this instance, so it gets none.
 * An arrow function such as `(x: i32): i32 => x * 2` returns the value of its expression.
 * A body that runs off its end returns nothing, or a success code for `void | Error`.
 * Any other function cannot run off its end, since the checker proved that every path returns,
 * so the end is unreachable.
 *
 * @since 1.0.0
 */

function emitFunction(cg: *Cg, sym: u32): void {
    if (symbolOf(cg, sym).type == 0) return;
    const decl = nodeOf(cg, symbolOf(cg, sym).decl);
    const data = record<HxFnData>(cg.ast, decl.a);
    beginFunction(cg, cg.storage[sym], symbolOf(cg, sym).instance, typeOf(cg, symbolOf(cg, sym).type).child);

    if (cg.di != null) {
        beginSubprogram(cg, fromCString(llvm.LLVMGetValueName(cg.fn)), decl.token);
        setLocation(cg, symbolOf(cg, sym).decl);
    }

    let index: u32 = 0;
    for (const i of data.paramsStart..data.paramsEnd) {
        if ((nodeOf(cg, extra(cg, i)).flags & FlagComptime) != 0) continue;   // a constant in this instance
        const p = infoOf(cg, extra(cg, i)).symbol;
        const v = llvm.LLVMGetParam(cg.fn, index);
        const name = tokenText(cg, symbolOf(cg, p).token);
        llvm.LLVMSetValueName2(v, name.ptr, name.len);
        void llvm.LLVMBuildStore(cg.b, v, localStorage(cg, p));
        declareVariable(cg, p, cg.storage[p], index + 1);
        index += 1;
    }

    if (nodeOf(cg, data.body).kind != NodeKind.Block) {   // `(x: i32): i32 => x * 2`
        const v = emitValue(cg, data.body);
        if (!terminated(cg)) {
            if (cg.returnType == cg.types.voidType) void llvm.LLVMBuildRetVoid(cg.b);
            else if (cg.returnType == cg.types.noreturnType) void llvm.LLVMBuildUnreachable(cg.b);
            else void llvm.LLVMBuildRet(cg.b, v);
        }
    } else {
        emitStmt(cg, data.body);
    }
    if (!terminated(cg)) {
        const ret = cg.returnType;
        if (ret == cg.types.voidType) {
            void llvm.LLVMBuildRetVoid(cg.b);
        } else if (typeOf(cg, ret).kind == TypeKind.ErrorUnion && typeOf(cg, ret).child == cg.types.voidType) {
            void llvm.LLVMBuildRet(cg.b, constErrorCode(cg, 0));
        } else {
            void llvm.LLVMBuildUnreachable(cg.b);   // sema proved every path returns
        }
    }
    cg.instance = 0;
    cg.diScope = null;
    llvm.LLVMSetCurrentDebugLocation2(cg.b, null);
}

/**
 * Emits the C `main` that calls the entry point of the program and turns its result into the exit status.
 *
 * @param cg - The code generator
 *
 * @remarks
 * On WebAssembly the function is named `__main_argc_argv`,
 * the name that C uses there and that the WASI start code calls.
 * For `main(init: Init)`, the standard library builds the `Init` from `argc` and `argv` first.
 * An error that reaches `main(): void | Error` is printed as `error: <name>` on stderr, and the process exits with 1.
 * A `void` result exits with 0, a `u8` result becomes the status, and a `noreturn` main never comes back.
 *
 * @since 1.0.0
 */

function emitEntryWrapper(cg: *Cg): void {
    const sym = cg.sema.entry;
    const i32t = int32(cg);
    const mainParams: Type[2] = [i32t, cg.ptrType];
    const mainType = fnType(i32t, &mainParams, false);
    // C on WebAssembly names `main(argc, argv)` this way; WASI's start code calls it
    const mainFn = llvm.LLVMAddFunction(cg.mod, targetArch(cg, "wasm32") ? "__main_argc_argv" : "main", mainType);
    addAttribute(cg, mainFn, "nounwind");
    positionAtEnd(cg, llvm.LLVMAppendBasicBlockInContext(cg.ctx, mainFn, "entry"));

    const fnT = symbolOf(cg, sym).type;
    let ret = typeOf(cg, fnT).child;
    let args: Value[1] = [null];
    let argCount: usize = 0;
    if (cg.sema.entryInit != 0) {   // `main(init: Init)`: std builds the Init from argc/argv
        const startup = cg.sema.entryInit;
        const startupArgs: Value[2] = [llvm.LLVMGetParam(mainFn, 0), llvm.LLVMGetParam(mainFn, 1)];
        args[0] = call(cg, lowerFunction(cg, symbolOf(cg, startup).type), cg.storage[startup], &startupArgs, "init");
        argCount = 1;
    }
    const allArgs: *Value[1] = &args;
    let result = call(cg, lowerFunction(cg, fnT), cg.storage[sym], allArgs[0..argCount],
                      ret == cg.types.voidType || ret == cg.types.noreturnType ? "" : "code");

    // `main(): void | Error`: an error that reaches main is printed and the process exits with status 1.
    if (typeOf(cg, ret).kind == TypeKind.ErrorUnion) {
        const errorUnion = ret;
        const code = errorUnionCode(cg, result, errorUnion);
        const failed = llvm.LLVMAppendBasicBlockInContext(cg.ctx, mainFn, "error");
        const ok = llvm.LLVMAppendBasicBlockInContext(cg.ctx, mainFn, "ok");
        condBr(cg, compareIntegers(cg, llvm.LLVMIntNE, code, constErrorCode(cg, 0)), failed, ok);

        positionAtEnd(cg, failed);
        cg.fn = mainFn;
        const dprintfParams: Type[2] = [i32t, cg.ptrType];
        const dprintfType = fnType(i32t, &dprintfParams, true);
        const dprintfFn = declareC(cg, "dprintf", dprintfType);
        const printArgs: Value[3] = [llvm.LLVMConstInt(i32t, 2, 0), cstring(cg, "error: %s\n", "main.error"), errorName(cg, code)];
        void call(cg, dprintfType, dprintfFn, &printArgs, "");
        void llvm.LLVMBuildRet(cg.b, llvm.LLVMConstInt(i32t, 1, 0));

        positionAtEnd(cg, ok);
        result = errorUnionPayload(cg, result, errorUnion);
        ret = typeOf(cg, errorUnion).child;
    }
    if (ret == cg.types.noreturnType) void llvm.LLVMBuildUnreachable(cg.b);
    else if (ret == cg.types.voidType) void llvm.LLVMBuildRet(cg.b, llvm.LLVMConstInt(i32t, 0, 0));
    else if (ret == cg.types.u8) void llvm.LLVMBuildRet(cg.b, llvm.LLVMBuildZExt(cg.b, result, i32t, ""));
    else void llvm.LLVMBuildRet(cg.b, result);
}

/**
 * Makes the C string of the title of a test or a `describe`.
 *
 * @param cg - The code generator
 * @param token - The string token of the title
 * @returns A pointer to the text between the quotes
 *
 * @remarks
 * The token is the string literal of the title, so the C string leaves out the quotes at both ends.
 * The text keeps any escape sequences as the source wrote them,
 * since it comes from the token rather than a checked value.
 *
 * @since 1.0.0
 */

function testTitle(cg: *Cg, token: u32): Value {
    const text = tokenText(cg, token);
    return cstring(cg, text[1..text.len - 1], "test.name");
}

/**
 * Emits one function of a test build, which runs a list of nodes in order and returns an error code.
 *
 * @param cg - The code generator
 * @param label - The kind of the function, which starts its name, such as `test` or `beforeEach`
 * @param title - The token of the title, which ends its name
 * @param nodes - The fixture declarations and the hook or test bodies to run
 * @returns The function, or `null` when there are no nodes
 *
 * @remarks
 * The function is named after its label and title, as in `test "adds"`.
 * A hook runs its block in a scope of its own, and a fixture stores into the global that {@link declareFixtures} made.
 * The function returns success when it runs off its end.
 *
 * @since 1.0.0
 */

function emitTestFn(cg: *Cg, label: string, title: u32, nodes: readonly u32[]): Value {
    if (nodes.len == 0) return null;
    const name = fromCString(llvmName(cg, `${label} ${tokenText(cg, title)}`));
    const fn = llvm.LLVMAddFunction(cg.mod, name.ptr, fnType(lower(cg, cg.types.errorCode), [], false));
    addAttribute(cg, fn, "nounwind");
    if (cg.safe) addStringAttribute(cg, fn, "frame-pointer", "all");
    if (cg.options.mode != ModeDebug) llvm.LLVMSetLinkage(fn, llvm.LLVMInternalLinkage);

    beginFunction(cg, fn, 0, cg.sema.testResult);
    if (cg.di != null) beginSubprogram(cg, name, title);
    for (const node of nodes) {
        if (terminated(cg)) break;
        if (cg.di != null) setLocation(cg, node);
        const kind = nodeOf(cg, node).kind;
        if (kind == NodeKind.Let || kind == NodeKind.Const) emitLocal(cg, node);
        else emitScoped(cg, kind == NodeKind.Hook ? nodeOf(cg, node).a : node);
    }
    if (!terminated(cg)) void llvm.LLVMBuildRet(cg.b, constErrorCode(cg, 0));
    cg.diScope = null;
    llvm.LLVMSetCurrentDebugLocation2(cg.b, null);
    return fn;
}

/**
 * Reads the timeout of a test.
 *
 * @param cg - The code generator
 * @param token - The number token of `{ timeout: 10_000 }`, or `NoToken`
 * @returns The milliseconds, or 0 for the default of the runner
 *
 * @remarks
 * Only the digits count, so `10_000` reads as 10000.
 *
 * @since 1.0.0
 */

function testTimeout(cg: *Cg, token: u32): u64 {
    if (token == NoToken) return 0;
    let ms: u64 = 0;
    for (const ch of tokenText(cg, token)) {
        if (ch >= '0' && ch <= '9') ms = ms * 10 + ((ch - '0') as u64);
    }
    return ms;
}

/**
 * Turns a missing function into a null pointer.
 *
 * @param cg - The code generator
 * @param v - The function, or `null`
 * @returns The function, or a constant null pointer in its place
 *
 * @remarks
 * A test or a `describe` without hooks has no function for them,
 * and the row of the test table needs a constant pointer in each slot.
 *
 * @since 1.0.0
 */

function orNull(cg: *Cg, v: Value): Value {
    return v != null ? v : llvm.LLVMConstNull(cg.ptrType);
}

/**
 * Appends one row to the table of a test build.
 *
 * @param cg - The code generator
 * @param table - The table to append to
 * @param kind - The kind of the row, one of the `TEST_ENTRY_` constants
 * @param mode - The modifier of the test or `describe`, such as skip, only, or todo, where 0 is a plain one
 * @param title - The token of the title, or `NoToken` for an end row
 * @param message - The expected message of `test.panics`, or `NoToken`
 * @param fn - The body of a test, the set-up of a `describe`, or the `afterAll` hooks of an end row
 * @param before - The `beforeEach` hooks of a `describe`, or `null`
 * @param after - The `afterEach` hooks of a `describe`, or `null`
 * @param timeout - The timeout in milliseconds, or 0 for the default of the runner
 *
 * @remarks
 * The row matches the `Entry` struct of the runtime, field for field.
 * A row with a title also records its place as `file:line:col`.
 *
 * @since 1.0.0
 */

function addTestEntry(cg: *Cg, table: *TestTable, kind: u32, mode: u16, title: u32, message: u32, fn: Value, before: Value,
                      after: Value, timeout: u64): void {
    const i32t = int32(cg);
    const nul = llvm.LLVMConstNull(cg.ptrType);
    let location = nul;
    if (title != NoToken) {
        const pos = diPosition(cg, title);
        location = cstring(cg, fromCString(llvmName(cg, `${sourcePath(cg, pos.file)}:${pos.line}:${pos.col}`)), "test.at");
    }
    let fields: Value[9] = [
        llvm.LLVMConstInt(i32t, kind as u64, 0),
        llvm.LLVMConstInt(i32t, mode as u64, 0),
        title != NoToken ? testTitle(cg, title) : nul,
        message != NoToken ? testTitle(cg, message) : nul,
        orNull(cg, fn),
        orNull(cg, before),
        orNull(cg, after),
        location,
        llvm.LLVMConstInt(int64(cg), timeout, 0),
    ];
    unsafe {
        if (table.len == table.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &table.entries), &table.cap, table.len + 1, @sizeOf(Value));
        table.entries![table.len] = llvm.LLVMConstNamedStruct(table.entryType, &fields, 9);
    }
    table.len += 1;
}

/**
 * Gives the `let` and `const` fixtures of a `describe` global storage, so every function of the block can reach them.
 *
 * @param cg - The code generator
 * @param describe - The `describe` node, whose nested `describe` blocks get the same treatment
 *
 * @remarks
 * A constant fixture whose address is never taken needs no storage, since its uses read the value directly.
 *
 * @since 1.0.0
 */

function declareFixtures(cg: *Cg, describe: u32): void {
    const n = nodeOf(cg, describe);
    for (const i of n.a..n.b) {
        const item = extra(cg, i);
        const kind = nodeOf(cg, item).kind;
        if (kind == NodeKind.Describe) {
            declareFixtures(cg, item);
            continue;
        }
        if (kind != NodeKind.Let && kind != NodeKind.Const) continue;
        const sym = infoOf(cg, item).symbol;
        if (sym == 0 || symbolOf(cg, sym).type == 0) continue;
        if (symbolOf(cg, sym).value != 0 && (symbolOf(cg, sym).flags & (HxSymAddressed as u16)) == 0) continue;
        const global = llvm.LLVMAddGlobal(cg.mod, lower(cg, symbolOf(cg, sym).type), tokenName(cg, symbolOf(cg, sym).token));
        llvm.LLVMSetInitializer(global, llvm.LLVMConstNull(lower(cg, symbolOf(cg, sym).type)));
        llvm.LLVMSetLinkage(global, llvm.LLVMInternalLinkage);
        cg.storage[sym] = global;
    }
}

/**
 * Views a vector of numbers as a slice.
 *
 * @param vec - The vector
 * @returns The numbers in the vector, or an empty slice for an empty vector
 *
 * @remarks
 * An empty vector may hold no items pointer at all, so it gives an empty slice instead of reading through null.
 * The slice borrows the vector and goes stale when the vector grows.
 *
 * @since 1.0.0
 */

function u32Items(vec: readonly *HxU32Vec): readonly u32[] {
    if (vec.len == 0) return [];
    unsafe {
        return vec.items![0..vec.len];
    }
}

/**
 * Releases the items of a vector of numbers.
 *
 * @param vec - The vector whose items to release
 *
 * @remarks
 * It frees only the items and leaves the length and capacity as they were, so the vector must not be used afterwards.
 *
 * @since 1.0.0
 */

function freeVec(vec: *HxU32Vec): void {
    unsafe {
        free(@ptrCast(?u8[*], vec.items));
    }
}

/**
 * Emits the functions and table rows of a test or a `describe`.
 *
 * @param cg - The code generator
 * @param table - The table to append to
 * @param node - The test or `describe` node, where any other node does nothing
 *
 * @remarks
 * A test becomes one function and one row.
 * A `describe` sorts its items into its set-up, which holds the fixtures and `beforeAll` hooks,
 * and its `beforeEach`, `afterEach`, and `afterAll` hooks, which become one function each.
 * Its row comes first, then the rows of its items in source order,
 * then an end row that carries the `afterAll` function.
 *
 * @since 1.0.0
 */

function emitTestItem(cg: *Cg, table: *TestTable, node: u32): void {
    const n = nodeOf(cg, node);
    if (n.kind == NodeKind.Test) {
        const data = record<HxTestData>(cg.ast, n.b);
        let body: u32[1] = [n.a];
        const bodies: *u32[1] = &body;
        const fn = emitTestFn(cg, "test", n.token, bodies[0..(n.a != 0 ? 1 : 0)]);
        addTestEntry(cg, table, TestEntryTest, n.op, n.token, data.messageToken, fn, null, null, testTimeout(cg, data.timeoutToken));
        return;
    }
    if (n.kind != NodeKind.Describe) return;

    let setup = HxU32Vec { items: null, len: 0, cap: 0 };
    let before = HxU32Vec { items: null, len: 0, cap: 0 };
    let after = HxU32Vec { items: null, len: 0, cap: 0 };
    let afterAll = HxU32Vec { items: null, len: 0, cap: 0 };
    for (const i of n.a..n.b) {
        const item = extra(cg, i);
        const it = nodeOf(cg, item);
        if (it.kind == NodeKind.Let || it.kind == NodeKind.Const) push(&setup, item);
        if (it.kind != NodeKind.Hook) continue;
        if (it.op == HookBeforeAll) push(&setup, item);
        else if (it.op == HookBeforeEach) push(&before, item);
        else if (it.op == HookAfterEach) push(&after, item);
        else push(&afterAll, item);
    }
    const setupFn = emitTestFn(cg, "describe", n.token, u32Items(&setup));
    const beforeFn = emitTestFn(cg, "beforeEach", n.token, u32Items(&before));
    const afterFn = emitTestFn(cg, "afterEach", n.token, u32Items(&after));
    const afterAllFn = emitTestFn(cg, "afterAll", n.token, u32Items(&afterAll));
    freeVec(&setup);
    freeVec(&before);
    freeVec(&after);
    freeVec(&afterAll);

    addTestEntry(cg, table, TestEntryDescribe, n.op, n.token, NoToken, setupFn, beforeFn, afterFn, 0);
    for (const i of n.a..n.b) emitTestItem(cg, table, extra(cg, i));
    addTestEntry(cg, table, TestEntryEnd, n.op, NoToken, NoToken, afterAllFn, null, null, 0);
}

/**
 * Emits `helix.test.error_name`, so the runtime can name an error that ends a test.
 *
 * @param cg - The code generator
 * @returns The function, which takes an error code and returns the name of the error
 *
 * @remarks
 * The function maps an error code to its name through {@link errorName}, the lookup behind `@errorName`,
 * so a failed test reports the name of its error rather than a number.
 *
 * @since 1.0.0
 */

function testErrorNameFn(cg: *Cg): Value {
    const params: Type[1] = [lower(cg, cg.types.errorCode)];
    const fn = llvm.LLVMAddFunction(cg.mod, "helix.test.error_name", fnType(cg.ptrType, &params, false));
    llvm.LLVMSetLinkage(fn, llvm.LLVMInternalLinkage);
    const saved = detourBegin(cg, fn);
    void llvm.LLVMBuildRet(cg.b, errorName(cg, llvm.LLVMGetParam(fn, 0)));
    detourEnd(cg, saved);
    return fn;
}

/**
 * Emits the table of tests and the C `main` of a test build.
 *
 * @param cg - The code generator
 *
 * @remarks
 * A test build has no `main` of its own.
 * Each test body, the set-up of each `describe`, which holds its fixtures and `beforeAll` hooks,
 * and the `beforeEach`, `afterEach`, and `afterAll` hooks of each block become a function that returns an error code.
 * Fixtures live in globals, so all the functions of a block share them.
 * A table lists the tree in source order, and `main` hands it to `hx_test_main` of the runtime,
 * which runs each test in a process of its own.
 * `main` also passes the error names, the `beginTest` and `endTest` functions of the testing module,
 * and the error code of `RequireFailed`.
 *
 * @since 1.0.0
 */

function emitTests(cg: *Cg): void {
    let root: u32 = 0;
    unsafe {
        root = @ptrCast(HxModule[*], cg.sema.program!.modules)[0].root;
    }
    const file = nodeOf(cg, root);
    for (const i of file.a..file.b) {
        if (nodeOf(cg, extra(cg, i)).kind == NodeKind.Describe) declareFixtures(cg, extra(cg, i));
    }

    const i32t = int32(cg);
    const i64t = int64(cg);
    const ptr = cg.ptrType;
    let table = TestTable { entryType: llvm.LLVMStructCreateNamed(cg.ctx, "helix.test.entry"), entries: null, len: 0, cap: 0 };
    let body: Type[9] = [i32t, i32t, ptr, ptr, ptr, ptr, ptr, ptr, i64t];
    llvm.LLVMStructSetBody(table.entryType, &body, 9, 0);
    for (const i of 0..file.b - file.a) emitTestItem(cg, &table, extra(cg, file.a + i));

    let entries: Value = null;
    unsafe {
        entries = llvm.LLVMConstArray2(table.entryType, table.entries, table.len as u64);
        free(@ptrCast(?u8[*], table.entries));
    }
    const global = llvm.LLVMAddGlobal(cg.mod, llvm.LLVMTypeOf(entries), "helix.tests");
    llvm.LLVMSetInitializer(global, entries);
    llvm.LLVMSetGlobalConstant(global, 1);
    llvm.LLVMSetLinkage(global, llvm.LLVMPrivateLinkage);

    const mainParams: Type[2] = [i32t, ptr];
    const mainFn = llvm.LLVMAddFunction(cg.mod, "main", fnType(i32t, &mainParams, false));
    addAttribute(cg, mainFn, "nounwind");
    const errorNames = testErrorNameFn(cg);
    positionAtEnd(cg, llvm.LLVMAppendBasicBlockInContext(cg.ctx, mainFn, "entry"));
    const params: Type[8] = [i32t, ptr, ptr, i64t, ptr, ptr, ptr, i32t];
    const args: Value[8] = [
        llvm.LLVMGetParam(mainFn, 0), llvm.LLVMGetParam(mainFn, 1), global, llvm.LLVMConstInt(i64t, table.len as u64, 0), errorNames,
        cg.storage[cg.sema.testBegin], cg.storage[cg.sema.testEnd], llvm.LLVMConstInt(i32t, cg.sema.requireCode as u64, 0),
    ];
    const runType = fnType(i32t, &params, false);
    void llvm.LLVMBuildRet(cg.b, call(cg, runType, declareC(cg, "hx_test_main", runType), &args, ""));
}

/**
 * Emits every global of the program.
 *
 * @param cg - The code generator
 *
 * @remarks
 * It runs after {@link declareFunctions}, since a global can point to a function.
 * An extern global is defined in C, so it is only declared here, under its C name.
 * Any other global is internal and starts with its constant value, or with zero when it has none.
 * A `const` global is constant.
 *
 * @since 1.0.0
 */

function emitGlobals(cg: *Cg): void {
    for (const i of 0..cg.sema.globals.len) {
        const sym = vectorAt(&cg.sema.globals, i);
        if (symbolOf(cg, sym).type == 0) continue;
        const name = symbolName(cg, sym);
        const isConst = nodeOf(cg, symbolOf(cg, sym).decl).kind == NodeKind.Const;
        if ((symbolOf(cg, sym).flags & (HxSymExtern as u16)) != 0) {   // defined in C: only declared here, under its C name
            let global = llvm.LLVMGetNamedGlobal(cg.mod, name);
            if (global == null) global = llvm.LLVMAddGlobal(cg.mod, lower(cg, symbolOf(cg, sym).type), name);
            if (isConst) llvm.LLVMSetGlobalConstant(global, 1);
            cg.storage[sym] = global;
            continue;
        }
        const global = llvm.LLVMAddGlobal(cg.mod, lower(cg, symbolOf(cg, sym).type), name);
        const init = nodeOf(cg, symbolOf(cg, sym).decl).b;
        const v = init != 0 ? infoOf(cg, init).value : 0;
        llvm.LLVMSetInitializer(global, v != 0 ? emitConst(cg, v, finalType(cg, init)) : llvm.LLVMConstNull(lower(cg, symbolOf(cg, sym).type)));
        llvm.LLVMSetLinkage(global, llvm.LLVMInternalLinkage);
        if (isConst) llvm.LLVMSetGlobalConstant(global, 1);
        cg.storage[sym] = global;
    }
}

/**
 * Views an LLVM message, which LLVM hands out as a mutable `char *`, as text to read.
 *
 * @param text - The message
 * @returns The same pointer, as read-only
 *
 * @remarks
 * It only changes the pointer type, and the message still belongs to LLVM and needs disposing afterwards.
 *
 * @since 1.0.0
 */

function asReadonly(text: ?u8[*]): ?readonly u8[*] {
    unsafe {
        return @ptrCast(?readonly u8[*], text);
    }
}

/**
 * Registers the targets that Helix compiles for with LLVM.
 *
 * @remarks
 * These are AArch64, ARM, RISC-V, WebAssembly, and x86, the targets that the LLVM of a release has.
 * `LLVMInitializeAllTargets` and its kind are inline in C, so they cannot be called from here.
 *
 * @since 1.0.0
 */

function initializeTargets(): void {
    llvm.LLVMInitializeAArch64TargetInfo(); llvm.LLVMInitializeAArch64Target(); llvm.LLVMInitializeAArch64TargetMC(); llvm.LLVMInitializeAArch64AsmPrinter();
    llvm.LLVMInitializeARMTargetInfo(); llvm.LLVMInitializeARMTarget(); llvm.LLVMInitializeARMTargetMC(); llvm.LLVMInitializeARMAsmPrinter();
    llvm.LLVMInitializeRISCVTargetInfo(); llvm.LLVMInitializeRISCVTarget(); llvm.LLVMInitializeRISCVTargetMC(); llvm.LLVMInitializeRISCVAsmPrinter();
    llvm.LLVMInitializeWebAssemblyTargetInfo(); llvm.LLVMInitializeWebAssemblyTarget(); llvm.LLVMInitializeWebAssemblyTargetMC(); llvm.LLVMInitializeWebAssemblyAsmPrinter();
    llvm.LLVMInitializeX86TargetInfo(); llvm.LLVMInitializeX86Target(); llvm.LLVMInitializeX86TargetMC(); llvm.LLVMInitializeX86AsmPrinter();
}

/**
 * Picks the optimization pipeline of a build mode.
 *
 * @param mode - The mode, one of the `MODE_` constants
 * @returns `default<O2>` for `release-safe`, `default<O3>` for `release-fast`, `default<Oz>` for `release-small`,
 * or `null` for a debug build, which runs no passes
 *
 * @remarks
 * The names are LLVM pass pipeline strings.
 * `ReleaseSafe` optimizes at O2 and keeps the safety checks that code generation emitted.
 *
 * @since 1.0.0
 */

function pipelineFor(mode: u32): ?readonly u8[*] {
    if (mode == ModeReleaseSafe) return "default<O2>";
    if (mode == ModeReleaseFast) return "default<O3>";
    if (mode == ModeReleaseSmall) return "default<Oz>";
    return null;
}

/**
 * Copies an LLVM message into memory that the caller frees with `free`, and disposes of the message.
 *
 * @param message - The message from LLVM
 * @returns The copy
 *
 * @remarks
 * LLVM messages need `LLVMDisposeMessage`,
 * while the error out-parameter of this module promises memory from the C heap,
 * so the copy keeps one rule for every error that the driver receives.
 *
 * @since 1.0.0
 */

function takeMessage(message: ?u8[*]): u8[*] {
    const text = fromCString(asReadonly(message));
    const copy = hxStrndup(text.ptr, text.len);
    llvm.LLVMDisposeMessage(message);
    return copy;
}

/**
 * Copies text into a NUL-terminated string on the C heap.
 *
 * @param text - The text to copy
 * @returns The copy, which the caller frees with `free`
 *
 * @remarks
 * It serves errors that do not come from an LLVM message, so the caller frees every error the same way.
 *
 * @since 1.0.0
 */

function strdup(text: string): u8[*] {
    return hxStrndup(text.ptr, text.len);
}

/**
 * Builds, verifies, and optimizes the LLVM module of the program.
 *
 * @param cg - The code generator, which {@link make} filled
 * @param error - Receives the message on failure, which the caller frees with `free`
 * @returns `true` when the module is ready, or `false` with the message in `error`
 *
 * @remarks
 * - **Target** - without a triple in the options it builds for this machine with its own CPU and features.
 *   Another target gets a generic CPU, or `apple-a12` on `arm64e`, the first with pointer authentication.
 *   RISC-V 64 means `rv64gc` with doubles in float registers (`lp64d`), as clang and the musl builds of Helix assume.
 *   A Thumb target without `eabihf` uses soft floats, and one with `eabihf` gets the single-precision FPU.
 * - **Freestanding** - without an OS nothing relocates the program, so its code is static.
 *   On RISC-V it also uses the `medany` code model, which reaches code linked anywhere,
 *   since QEMU's RAM starts at 0x80000000, out of the reach of the default model.
 * - **Order** - the functions are declared first, then the globals, which can point to them, then every body,
 *   the C wrappers, and the table of tests or the entry wrapper.
 * - **Checks** - an `arm64e` module signs its function pointers, and the module is verified.
 *   Invalid IR is printed on stderr and reported as an internal compiler error.
 * - **Optimization** - a release mode then runs the pipeline that {@link pipelineFor} picks.
 *
 * @since 1.0.0
 */

function buildModule(cg: *Cg, error: *?u8[*]): bool {
    initializeTargets();

    cg.ctx = llvm.LLVMContextCreate();
    cg.mod = llvm.LLVMModuleCreateWithNameInContext(cg.options.module_name, cg.ctx);
    cg.b = llvm.LLVMCreateBuilderInContext(cg.ctx);
    cg.ptrType = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    cg.usizeType = llvm.LLVMIntTypeInContext(cg.ctx, cg.types.pointerBytes * 8);
    let sliceFields: Type[2] = [cg.ptrType, cg.usizeType];
    cg.sliceType = llvm.LLVMStructTypeInContext(cg.ctx, &sliceFields, 2, 0);
    let dynFields: Type[2] = [cg.ptrType, cg.ptrType];
    cg.dynType = llvm.LLVMStructTypeInContext(cg.ctx, &dynFields, 2, 0);
    cg.vtables = zeroed<Value>(cg.sema.impls.len + 1);
    cg.storage = zeroed<Value>(cg.sema.symbols.len);
    cg.typeCache = zeroed<Type>(cg.types.itemsLen);
    cg.stringGlobals = zeroed<Value>(cg.sema.values.len);
    cg.printFns = zeroed<Value>(cg.types.itemsLen * 2);
    cg.equalFns = zeroed<Value>(cg.types.itemsLen);
    cg.cAbi = zeroed<bool>(cg.sema.symbols.len);

    const host = cg.options.triple == null;
    const triple = host ? llvm.LLVMGetDefaultTargetTriple() : llvm.LLVMCreateMessage(cg.options.triple);
    let target: llvm.LLVMTargetRef[1] = [null];
    let message: (?u8[*])[1] = [null];
    if (llvm.LLVMGetTargetFromTriple(asReadonly(triple), &target, &message) != 0) {
        *error = takeMessage(message[0]);
        llvm.LLVMDisposeMessage(triple);
        return false;
    }
    // the host's own CPU unless told otherwise; another machine gets a generic one (no host-only features)
    const asked = cg.options.cpu;
    const native = asked != null ? equal(fromCString(asked), "native") : host;
    let cpu: ?u8[*] = null;
    if (native) cpu = llvm.LLVMGetHostCPUName();
    else if (asked != null && !equal(fromCString(asked), "generic")) cpu = llvm.LLVMCreateMessage(asked);
    else if (startsWith(fromCString(asReadonly(triple)), "arm64e")) cpu = llvm.LLVMCreateMessage("apple-a12");   // the first with pointer authentication
    else cpu = llvm.LLVMCreateMessage("generic");
    // riscv64 means rv64gc with doubles in float registers (lp64d), as clang and the musl Helix builds assume
    const riscv = startsWith(fromCString(asReadonly(triple)), "riscv64");
    let features: ?u8[*] = null;
    if (native) features = llvm.LLVMGetHostCPUFeatures();
    else if (riscv) features = llvm.LLVMCreateMessage("+m,+a,+f,+d,+c,+zicsr,+zifencei");
    else if (startsWith(fromCString(asReadonly(triple)), "thumb") && !endsWith(fromCString(asReadonly(triple)), "eabihf")) {
        features = llvm.LLVMCreateMessage("+soft-float");   // a Cortex-M without an FPU (or not using it): no float registers
    } else if (startsWith(fromCString(asReadonly(triple)), "thumb")) {
        // `-eabihf`: the single-precision FPU every Cortex-M with one has (a --cpu like cortex-m7 can add more)
        features = llvm.LLVMCreateMessage(startsWith(fromCString(asReadonly(triple)), "thumbv8m") ? "+fp-armv8d16sp" : "+vfp4d16sp");
    } else features = llvm.LLVMCreateMessage("");
    const mode = cg.options.mode;
    const level = mode == ModeDebug ? llvm.LLVMCodeGenLevelNone : mode == ModeReleaseFast ? llvm.LLVMCodeGenLevelAggressive : llvm.LLVMCodeGenLevelDefault;
    // without an OS nothing relocates the program, so its code is static; on RISC-V the `medany` model reaches
    // code linked anywhere (QEMU's RAM starts at 0x80000000, out of the default model's reach)
    const reloc = cg.options.freestanding ? llvm.LLVMRelocStatic : llvm.LLVMRelocPIC;
    const model = cg.options.freestanding && riscv ? llvm.LLVMCodeModelMedium : llvm.LLVMCodeModelDefault;
    cg.machine = llvm.LLVMCreateTargetMachine(target[0], asReadonly(triple), asReadonly(cpu), asReadonly(features), level, reloc, model);
    llvm.LLVMSetTarget(cg.mod, asReadonly(triple));
    if (riscv) {
        llvm.LLVMAddModuleFlag(cg.mod, llvm.LLVMModuleFlagBehaviorError, "target-abi", 10,
                            llvm.LLVMMDStringInContext2(llvm.LLVMGetModuleContext(cg.mod), "lp64d", 5));
    }
    cg.ptrauth = startsWith(fromCString(asReadonly(triple)), "arm64e");
    cg.layout = llvm.LLVMCreateTargetDataLayout(cg.machine);
    llvm.LLVMSetModuleDataLayout(cg.mod, cg.layout);
    llvm.LLVMDisposeMessage(triple);
    llvm.LLVMDisposeMessage(cpu);
    llvm.LLVMDisposeMessage(features);

    if (cg.options.debugInfo) {
        cg.di = llvm.LLVMCreateDIBuilder(cg.mod);
        cg.diFiles = zeroed<Meta>(cg.ast.src.fileCount + 1);
        cg.diTypes = zeroed<Meta>(cg.types.itemsLen);
        const producer = fromCString(llvmName(cg, `helix ${Version}`));
        cg.diUnit = llvm.LLVMDIBuilderCreateCompileUnit(cg.di, llvm.LLVMDWARFSourceLanguageC, diFile(cg, 0), producer.ptr, producer.len,
                                                      llvmBool(mode != ModeDebug), "", 0, 0, "", 0, llvm.LLVMDWARFEmissionFull, 0, 0, 0,
                                                      "", 0, "", 0);
        const i32t = int32(cg);
        llvm.LLVMAddModuleFlag(cg.mod, llvm.LLVMModuleFlagBehaviorWarning, "Debug Info Version", 18,
                            llvm.LLVMValueAsMetadata(llvm.LLVMConstInt(i32t, llvm.LLVMDebugMetadataVersion() as u64, 0)));
        llvm.LLVMAddModuleFlag(cg.mod, llvm.LLVMModuleFlagBehaviorWarning, "Dwarf Version", 13,
                            llvm.LLVMValueAsMetadata(llvm.LLVMConstInt(i32t, 4, 0)));
    }

    declareFunctions(cg);
    emitGlobals(cg);   // after the functions, which a global can point to
    for (const i of 0..cg.sema.functions.len) emitFunction(cg, vectorAt(&cg.sema.functions, i));
    for (const i of 0..cg.cWrappers.len) emitCWrapper(cg, vectorAt(&cg.cWrappers, i));
    if (cg.sema.testResult != 0) emitTests(cg);
    else if (cg.sema.entry != 0) emitEntryWrapper(cg);
    if (cg.di != null) llvm.LLVMDIBuilderFinalize(cg.di);
    if (cg.ptrauth && !signFunctionPointers(cg, error)) return false;

    message[0] = null;
    if (llvm.LLVMVerifyModule(cg.mod, llvm.LLVMReturnStatusAction, &message) != 0) {
        const ir = llvm.LLVMPrintModuleToString(cg.mod);
        eprint(`${fromCString(asReadonly(ir))}\n`);
        llvm.LLVMDisposeMessage(ir);
        const text = llvmName(cg, `internal compiler error: invalid LLVM IR:\n${fromCString(asReadonly(message[0]))}`);
        *error = strdup(fromCString(text));
        llvm.LLVMDisposeMessage(message[0]);
        return false;
    }
    llvm.LLVMDisposeMessage(message[0]);

    if (const pipeline = pipelineFor(mode)) {
        const options = llvm.LLVMCreatePassBuilderOptions();
        const err = llvm.LLVMRunPasses(cg.mod, pipeline, cg.machine, options);
        llvm.LLVMDisposePassBuilderOptions(options);
        if (err != null) {
            const text = llvm.LLVMGetErrorMessage(err);
            *error = strdup(fromCString(asReadonly(text)));
            llvm.LLVMDisposeErrorMessage(text);
            return false;
        }
    }
    return true;
}

/**
 * Releases everything that the code generator allocated, LLVM objects included.
 *
 * @param cg - The code generator
 *
 * @remarks
 * It checks each LLVM object for null first, so it is safe after a setup that failed partway.
 * The context goes last among the LLVM objects, since the module and the builder belong to it.
 *
 * @since 1.0.0
 */

function dispose(cg: *Cg): void {
    if (cg.di != null) llvm.LLVMDisposeDIBuilder(cg.di);
    release(cg.diFiles);
    release(cg.diTypes);
    if (cg.b != null) llvm.LLVMDisposeBuilder(cg.b);
    if (cg.mod != null) llvm.LLVMDisposeModule(cg.mod);
    if (cg.layout != null) llvm.LLVMDisposeTargetData(cg.layout);
    if (cg.machine != null) llvm.LLVMDisposeTargetMachine(cg.machine);
    if (cg.ctx != null) llvm.LLVMContextDispose(cg.ctx);
    release(cg.storage);
    release(cg.typeCache);
    release(cg.stringGlobals);
    release(cg.printFns);
    release(cg.equalFns);
    release(cg.cAbi);
    freeVec(&cg.cWrappers);
    release(cg.vtables);
    freeVec(&cg.defers);
    hxArenaFree(&cg.arena);
}

/**
 * Creates a code generator for a checked program, before any LLVM state exists.
 *
 * @param sema - The checker state of the program
 * @param options - The options of the build
 * @returns The code generator, which {@link buildModule} fills
 *
 * @remarks
 * The safety checks are on in `debug` and `release-safe`.
 *
 * @since 1.0.0
 */

function make(sema: readonly *HxSema, options: readonly *HxCodegenOptions): Cg {
    return Cg {
        sema, ast: sema.ast!, types: &sema.types, options, safe: options.mode == ModeDebug || options.mode == ModeReleaseSafe,
        ptrauth: false, arena: HxArena { head: null },
        ctx: null, mod: null, b: null, machine: null, layout: null,
        storage: [], typeCache: [], stringGlobals: [], sliceType: null, ptrType: null, usizeType: null, dynType: null,
        vtables: [],
        fn: null, instance: 0, returnType: 0, entryBlock: null, defers: HxU32Vec { items: null, len: 0, cap: 0 },
        loops: undefined, loopCount: 0,
        panicFn: null, panicFnType: null, panicBoundsFn: null, panicBoundsFnType: null, errorNames: null,
        printFns: [], equalFns: [], cAbi: [], cWrappers: HxU32Vec { items: null, len: 0, cap: 0 },
        di: null, diUnit: null, diFiles: [], diTypes: [], diScope: null,
    };
}

/**
 * Compiles a checked program to a native object file.
 *
 * @param sema - The checker state of a program that checked without errors
 * @param options - The mode, module name, target, CPU, and debug information of the build
 * @param path - The path of the object file to write
 * @param error - Receives the message on failure, which the caller frees with `free`
 * @returns `true` when the file is written, or `false` with the message in `error`
 *
 * @remarks
 * This is the last step of `helix build`.
 * The module holds the symbols, functions, and globals of the program,
 * and the entry point or, in a test build, the table of tests.
 *
 * @example
 * ```hx
 * let error: ?u8[*] = null;
 * hxCodegenObject(&sema, &options, "main.o", &error); // true, and main.o is written
 * ```
 *
 * @see hxCodegenIr
 * @since 1.0.0
 */

export extern "C" function hxCodegenObject(sema: readonly *HxSema, options: readonly *HxCodegenOptions, path: readonly u8[*],
                                             error: *?u8[*]): bool {
    let cg = make(sema, options);
    let ok = buildModule(&cg, error);
    if (ok) {
        let message: (?u8[*])[1] = [null];
        if (llvm.LLVMTargetMachineEmitToFile(cg.machine, cg.mod, path, llvm.LLVMObjectFile, &message) != 0) {
            *error = strdup(fromCString(asReadonly(message[0])));
            ok = false;
        }
        llvm.LLVMDisposeMessage(message[0]);
    }
    dispose(&cg);
    return ok;
}

/**
 * Compiles a checked program and returns its LLVM IR as text.
 *
 * @param sema - The checker state of a program that checked without errors
 * @param options - The mode, module name, target, CPU, and debug information of the build
 * @param error - Receives the message on failure, which the caller frees with `free`
 * @returns The IR, which the caller frees with `free`, or `null` with the message in `error`
 *
 * @remarks
 * `helix ir` prints this text.
 * It builds the same module as {@link hxCodegenObject}, after the passes of the mode,
 * so a release mode returns optimized IR and `debug` returns it as emitted.
 *
 * @example
 * ```hx
 * // export function add(a: i32, b: i32): i32 { return a + b; }
 * const ir = hxCodegenIr(&sema, &options, &error); // "...define i32 @test.add(i32 %a, i32 %b)..."
 * ```
 *
 * @see hxCodegenObject
 * @since 1.0.0
 */

export extern "C" function hxCodegenIr(sema: readonly *HxSema, options: readonly *HxCodegenOptions, error: *?u8[*]): ?u8[*] {
    let cg = make(sema, options);
    let result: ?u8[*] = null;
    if (buildModule(&cg, error)) result = takeMessage(llvm.LLVMPrintModuleToString(cg.mod));
    dispose(&cg);
    return result;
}
