/**
 * Imports
 */

import * as fmt from "std/fmt";
import { ArrayList } from "std/list";
import { cAllocator } from "std/heap";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { hxFatalMessage, hxAlloc } from "@components/memory.component";
import { Attributes } from "@modules/codegen/constants/ptrauth.constant";
import { Cg, Value } from "@modules/codegen/components/structs/base-component.struct";
import { Signed } from "@modules/codegen/components/structs/ptrauth-component.struct";
import { llvmName, fromCString, int32, addStringAttribute } from "@modules/codegen/components/base.component";

/**
 * Formats the message of an internal error.
 *
 * @param text - The message
 * @returns The message as a NUL-terminated string, which the caller frees with `free`
 *
 * @remarks
 * The caller owns the message and frees it with `free`, since it reaches the driver through the error out-parameter.
 * A template that fails to format gives an empty message.
 *
 * @since 1.0.0
 */

function fail(text: Format): u8[*] {
    const n = fmt.count(text) catch 0;
    const buf = hxAlloc(n + 1);
    unsafe {
        void (fmt.bufPrint(buf[0..n], text) catch []);
        buf[n] = 0;
    }
    return buf;
}

/**
 * Stops the compiler with an out of memory error.
 *
 * @remarks
 * The lists of this component grow on the C heap, and a failed append has no sensible recovery, so it ends the process.
 *
 * @since 1.0.0
 */

function outOfMemory(): noreturn {
    hxFatalMessage("out of memory");
}

/**
 * Checks whether two LLVM values are the same value.
 *
 * @param a - The first value
 * @param b - The second value
 * @returns `true` when both refer to the same value
 *
 * @remarks
 * LLVM values are opaque pointers, so identity is address equality.
 *
 * @since 1.0.0
 */

function sameValue(a: Value, b: Value): bool {
    return @intFromPtr(a) == @intFromPtr(b);
}

/**
 * Checks whether a function is used other than as the callee of a call.
 *
 * @param fn - The function
 * @returns `true` when a use stores, passes, or otherwise takes the function as a value
 *
 * @remarks
 * A call that passes the function as an argument counts, since only the last operand of a call is its callee.
 *
 * @since 1.0.0
 */

function usedAsValue(fn: Value): bool {
    let use = llvm.LLVMGetFirstUse(fn);
    while (use != null) {
        const user = llvm.LLVMGetUser(use);
        if (llvm.LLVMIsACallInst(user) == null) return true;
        const n = llvm.LLVMGetNumOperands(user) as u32;
        for (const i of 0..n - 1) {   // the callee is the last operand
            if (sameValue(llvm.LLVMGetOperand(user, i), fn)) return true;
        }
        use = llvm.LLVMGetNextUse(use);
    }
    return false;
}

/**
 * Collects the calls whose callee is a value.
 *
 * @param v - The value
 * @param out - The list that receives the calls
 *
 * @remarks
 * A call that only passes the value as an argument does not count,
 * so the caller can give each collected call its original callee back.
 *
 * @since 1.0.0
 */

function callsOf(v: Value, out: *ArrayList<Value>): void {
    let use = llvm.LLVMGetFirstUse(v);
    while (use != null) {
        const user = llvm.LLVMGetUser(use);
        if (llvm.LLVMIsACallInst(user) != null && sameValue(llvm.LLVMGetCalledValue(user), v)) out.append(user) catch outOfMemory();
        use = llvm.LLVMGetNextUse(use);
    }
}

/**
 * Writes a name as a quoted LLVM IR identifier.
 *
 * @param out - The builder of the IR text
 * @param name - The name
 *
 * @remarks
 * The identifier is `@"<name>"`, with `"`, `\`, and bytes that do not print escaped as `\XX` in hexadecimal.
 *
 * @since 1.0.0
 */

function quote(out: *fmt.Builder, name: string): void {
    const hex = "0123456789ABCDEF";
    out.append("@\"") catch outOfMemory();
    for (const c of name) {
        if (c < 0x20 || c >= 0x7f || c == '"' || c == '\\') {
            const escaped: u8[3] = ['\\', hex[c >> 4], hex[c & 15]];
            out.write(&escaped) catch outOfMemory();
        } else {
            const plain: u8[1] = [c];
            out.write(&plain) catch outOfMemory();
        }
    }
    out.append("\"") catch outOfMemory();
}

/**
 * Returns the name of an LLVM value.
 *
 * @param v - The value
 * @returns The name, which may hold any byte
 *
 * @remarks
 * The text borrows LLVM's copy of the name, so it stays valid only until the value is renamed or deleted.
 *
 * @since 1.0.0
 */

function valueName(v: Value): string {
    let len: usize = 0;
    const name = llvm.LLVMGetValueName2(v, &len);
    unsafe {
        return name![0..len];
    }
}

/**
 * Adds a module flag that turns a pointer authentication feature on.
 *
 * @param cg - The code generator
 * @param name - The name of the flag
 *
 * @remarks
 * The flag is `!{i32 7, !"<name>", i32 1}` in `llvm.module.flags`, where 7 is the behavior "max", as clang adds it.
 *
 * @since 1.0.0
 */

function addFlag(cg: *Cg, name: string): void {
    const i32t = int32(cg);
    let ops: llvm.LLVMMetadataRef[3] = [
        llvm.LLVMValueAsMetadata(llvm.LLVMConstInt(i32t, 7, 0)),
        llvm.LLVMMDStringInContext2(cg.ctx, name.ptr, name.len),
        llvm.LLVMValueAsMetadata(llvm.LLVMConstInt(i32t, 1, 0)),
    ];
    const node = llvm.LLVMMDNodeInContext2(cg.ctx, &ops, 3);
    llvm.LLVMAddNamedMetadataOperand(cg.mod, "llvm.module.flags", llvm.LLVMMetadataAsValue(cg.ctx, node));
}

/**
 * Signs the function pointers of the module and asks LLVM to sign return addresses, for arm64e.
 *
 * @param cg - The code generator
 * @param error - Receives the message of an internal error, which the caller frees
 * @returns `false` when the signed constants could not be made
 *
 * @remarks
 * On arm64e, return addresses and function pointers carry a signature in their top bits,
 * made with a per-process key, and are checked before they are used, so a forged or corrupted one traps.
 * Helix follows the C ABI of arm64e, so its function pointers and those of C mix.
 * A function used as a value is signed with key IA and no discriminator,
 * and a call through a pointer checks that signature. Direct calls are not signed.
 * LLVM signs the return addresses itself, as the {@link Attributes} that every function gets ask.
 *
 * The signing runs after the module is emitted.
 * Every use of a function other than as the callee of a call becomes `ptrauth (ptr @f, i32 0)`.
 * The LLVM C API can read such constants but not make them,
 * so this parses a few lines of IR that hold them and links that module into this one.
 *
 * @example
 * ```hx
 * // const callback = onEvent;   for arm64e-apple-macos
 * signFunctionPointers(cg, &error); // true, and the store now holds ptrauth (ptr @onEvent, i32 0)
 * ```
 *
 * @since 1.0.0
 */

export function signFunctionPointers(cg: *Cg, error: *?u8[*]): bool {
    for (const name of Attributes[1..]) addFlag(cg, name);

    let signed = ArrayList<Signed>.init(cAllocator());
    defer signed.deinit();
    let fn = llvm.LLVMGetFirstFunction(cg.mod);
    while (fn != null) {
        if (llvm.LLVMGetIntrinsicID(fn) == 0) {
            for (const name of Attributes) addStringAttribute(cg, fn, name, "");
            if (usedAsValue(fn)) signed.append(Signed { fn, placeholder: null, linkage: llvm.LLVMGetLinkage(fn) }) catch outOfMemory();
        }
        fn = llvm.LLVMGetNextFunction(fn);
    }
    if (signed.items.len == 0) return true;

    // every use moves to a placeholder, and calls get their callee back
    let calls = ArrayList<Value>.init(cAllocator());
    defer calls.deinit();
    for (const s, i of signed.items) {
        const placeholder = llvm.LLVMAddGlobal(cg.mod, cg.ptrType, llvmName(cg, `hx.ptrauth.placeholder.${i}`));
        llvm.LLVMReplaceAllUsesWith(s.fn, placeholder);
        calls.clear();
        callsOf(placeholder, &calls);
        for (const c of calls.items) llvm.LLVMSetOperand(c, llvm.LLVMGetNumOperands(c) as u32 - 1, s.fn);
        signed.items[i].placeholder = placeholder;
        // a local function can't be named from another module, even one being linked in: public until linked
        llvm.LLVMSetLinkage(s.fn, llvm.LLVMExternalLinkage);
    }

    // the signed constants, as IR, linked in
    let ir = fmt.Builder.init(cAllocator());
    defer ir.deinit();
    ir.append(`target datalayout = "${fromCString(llvm.LLVMGetDataLayoutStr(cg.mod))}"\ntarget triple = "${fromCString(llvm.LLVMGetTarget(cg.mod))}"\n`) catch outOfMemory();
    for (const s, i of signed.items) {
        ir.append("declare void ") catch outOfMemory();
        quote(&ir, valueName(s.fn));
        ir.append(`()\n@hx.ptrauth.${i} = constant ptr ptrauth (ptr `) catch outOfMemory();
        quote(&ir, valueName(s.fn));
        ir.append(", i32 0)\n") catch outOfMemory();
    }
    const text = ir.text();
    const buffer = llvm.LLVMCreateMemoryBufferWithMemoryRangeCopy(text.ptr, text.len, "ptrauth");
    let parsed: llvm.LLVMModuleRef[1] = [null];
    let message: (?u8[*])[1] = [null];
    if (llvm.LLVMParseIRInContext(cg.ctx, buffer, &parsed, &message) != 0) {
        unsafe {
            *error = fail(`internal compiler error: signing function pointers: ${fromCString(@ptrCast(?readonly u8[*], message[0]))}`);
        }
        llvm.LLVMDisposeMessage(message[0]);
        return false;
    }
    if (llvm.LLVMLinkModules2(cg.mod, parsed[0]) != 0) {
        *error = fail("internal compiler error: signing function pointers: linking failed");
        return false;
    }

    for (const s, i of signed.items) {
        const holder = llvm.LLVMGetNamedGlobal(cg.mod, llvmName(cg, `hx.ptrauth.${i}`));
        llvm.LLVMReplaceAllUsesWith(s.placeholder, llvm.LLVMGetInitializer(holder));
        llvm.LLVMDeleteGlobal(s.placeholder);
        llvm.LLVMDeleteGlobal(holder);
        llvm.LLVMSetLinkage(s.fn, s.linkage);
    }
    return true;
}
