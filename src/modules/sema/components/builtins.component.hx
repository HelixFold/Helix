/**
 * Imports
 */

import { NodeKind } from "@constants/ast.constant";
import { Ctx, TypeParam, Pending } from "@structs/sema.struct";
import { TypeKind, Readonly } from "@constants/types.constant";
import { hxTypeBuiltin, hxTypePointer } from "@models/types.model";
import { hxsLookup } from "@modules/sema/components/scope.component";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { hxStrndup, hxVecGrowImpl } from "@components/memory.component";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { symbolOf, infoOf, extraOf } from "@modules/sema/components/base.component";
import { hxsResolveAggregate, hxsSizeAlign } from "@modules/sema/components/aggregate.component";
import { HxValueString, HxSymType, HxValueBool, HxValueFloat, HxValueInt } from "@constants/sema.constant";
import { hxsIntValue, hxsWrapInt, semaOf, astOf, nodeOf, typeOf } from "@modules/sema/components/base.component";
import { hxsI128Text, hxsAggregateOf, hxNodeSpan, hxsTypeNameText } from "@modules/sema/components/base.component";
import { tokenText, typeName, errorNode, hint, hxsTokName, hxsValueOf } from "@modules/sema/components/base.component";
import { hxsCoerce, hxsIsInteger, hxsIsComptimeNumber, types, memberAt } from "@modules/sema/components/base.component";

/**
 * The C library function that formats the pieces of a `@compileLog` message.
 *
 * @since 1.0.0
 */

extern "C" function snprintf(buf: u8[*], size: usize, fmt: readonly u8[*], ...): i32;

/**
 * Queues a `@compileError` or `@compileLog` message for the function being checked.
 *
 * @param c - The checker context
 * @param node - The builtin call node that the message points at
 * @param message - The message, a NUL-terminated copy that the queue now owns
 * @param log - `true` for a `@compileLog` message, `false` for a `@compileError` one
 *
 * @remarks
 * The message is not reported here.
 * It fires later, once the checker knows that the function is used.
 *
 * @since 1.0.0
 */

function pushPending(c: *Ctx, node: u32, message: u8[*], log: bool): void {
    const list = &c.pending;
    unsafe {
        if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, @sizeOf(Pending));
        @ptrCast(Pending[*], list.items)[list.len] = Pending { functionSymbol: c.functionSymbol, node, message, log };
    }
    list.len += 1;
}

/**
 * Compares a builtin's name with a word, byte by byte.
 *
 * @param name - The name as written, such as `@sizeOf`
 * @param word - The word to compare with
 * @returns `true` when both have the same length and the same bytes
 *
 * @remarks
 * The builtin checker dispatches on the name with a chain of these comparisons, one per builtin.
 * The comparison is exact, so the word includes the leading `@`.
 *
 * @since 1.0.0
 */

function isNamed(name: string, word: string): bool {
    if (name.len != word.len) return false;
    for (const ch, i of word) {
        if (name[i] != ch) return false;
    }
    return true;
}

/**
 * Checks whether a type is a pointer to one value or a many-item pointer.
 *
 * @param c - The checker context
 * @param t - The type to check
 * @param allowOptional - Whether an optional of such a pointer also counts
 * @returns `true` for a pointer type, or for an optional pointer when `allowOptional` is set
 *
 * @remarks
 * Builtins such as `@ptrCast`, `@intFromPtr`, and `@ptrFromInt` use it to accept their pointer operands.
 * Slices do not count, since they carry a length besides the address.
 *
 * @since 1.0.0
 */

function isPointerType(c: *Ctx, t: u32, allowOptional: bool): bool {
    const k = typeOf(c, t).kind;
    if (k == TypeKind.Pointer || k == TypeKind.ManyPointer) return true;
    if (!allowOptional || k != TypeKind.Optional) return false;
    const child = typeOf(c, typeOf(c, t).child).kind;
    return child == TypeKind.Pointer || child == TypeKind.ManyPointer;
}

/**
 * Counts the bytes of a NUL-terminated string.
 *
 * @param text - The string
 * @returns The number of bytes before the NUL
 *
 * @remarks
 * Reads until the first NUL, so the text must contain one within its buffer.
 *
 * @since 1.0.0
 */

function cStringLength(text: readonly u8[*]): usize {
    let n: usize = 0;
    unsafe {
        while (text[n] != 0) n += 1;
    }
    return n;
}

/**
 * Writes the message of a `@compileLog` call, such as `x = 3, T = u8`.
 *
 * @param c - The checker context
 * @param node - The `@compileLog` call node
 * @param out - The buffer that receives the NUL-terminated message
 * @returns The number of bytes written, which stops growing once the buffer is full
 *
 * @remarks
 * An argument that names a type, such as a type parameter, a builtin type, or a declared type, logs that type.
 * Any other argument is checked as an expression and logs its source text with its value,
 * which is an integer, a float, a `bool`, or a quoted string.
 * An argument whose value is known only when the program runs logs its type instead.
 * Each piece holds at most 255 bytes.
 *
 * @since 1.0.0
 */

function compileLogText(c: *Ctx, node: u32, out: *u8[1024]): usize {
    const n = nodeOf(c, node);
    let used: usize = 0;
    out[0] = 0;
    for (const i of 0..n.b - n.a) {
        const arg = extraOf(c, n.a + i);
        let piece: u8[256] = undefined;
        const sym = nodeOf(c, arg).kind == NodeKind.Ident ? hxsLookup(c, hxsTokName(c, nodeOf(c, arg).token)) : 0;
        const argText = tokenText(c, nodeOf(c, arg).token);
        let asType: u32 = 0;   // `@compileLog(T)` logs a type
        if (nodeOf(c, arg).kind == NodeKind.Ident) {
            let t = c.typeParams.len;
            while (t > 0 && asType == 0) {
                unsafe {
                    const tp = @ptrCast(TypeParam[*], c.typeParams.items)[t - 1];
                    if (tp.name == hxsTokName(c, nodeOf(c, arg).token)) asType = tp.type;
                }
                t -= 1;
            }
        }
        if (asType == 0 && nodeOf(c, arg).kind == NodeKind.Ident && sym == 0) asType = hxTypeBuiltin(types(c), argText.ptr, @truncate(u32, argText.len));
        if (asType == 0 && sym != 0 && symbolOf(c, sym).kind == HxSymType as u8) asType = hxsResolveType(c, arg);
        if (asType != 0) {
            void snprintf(&piece, 256, "%.*s = %s", argText.len as i32, argText.ptr, hxsTypeNameText(c, asType));
        } else {
            const t = hxsCheckExpr(c, arg, 0);
            let start: u32 = 0;
            let spanLen: u32 = 0;
            hxNodeSpan(astOf(c), arg, &start, &spanLen);
            let src: readonly u8[*] = undefined;
            unsafe {
                src = @ptrFromInt(u8[*], @intFromPtr(semaOf(c).src!.text!) + (start as usize));
            }
            const v = hxsValueOf(c, arg);
            if (v != null && v.kind == HxValueInt as u8) {
                let digits: u8[48] = undefined;
                hxsI128Text(v.integer, &digits, 48);
                void snprintf(&piece, 256, "%.*s = %s", spanLen as i32, src, &digits);
            } else if (v != null && v.kind == HxValueFloat as u8) {
                void snprintf(&piece, 256, "%.*s = %g", spanLen as i32, src, v.floating);
            } else if (v != null && v.kind == HxValueBool as u8) {
                void snprintf(&piece, 256, "%.*s = %s", spanLen as i32, src, v.boolean ? "true" : "false");
            } else if (v != null && v.kind == HxValueString as u8) {
                void snprintf(&piece, 256, "%.*s = \"%.*s\"", spanLen as i32, src, v.len as i32, v.bytes ?? "");
            } else {
                void snprintf(&piece, 256, "%.*s: %s (known only when the program runs)", spanLen as i32, src, t != 0 ? hxsTypeNameText(c, t) : "?");
            }
        }
        if (used < 1024) {
            unsafe {
                const at = @ptrFromInt(u8[*], @intFromPtr(out) + used);
                used += snprintf(at, 1024 - used, "%s%s", i != 0 ? ", " : "", &piece) as usize;
            }
        }
    }
    return used;
}

/**
 * Checks a call of an `@` builtin.
 *
 * @param c - The checker context
 * @param node - The builtin call node, whose token is the name and whose range holds the arguments
 * @returns The type of the call, or 0 after an error
 *
 * @remarks
 * The builtins are the following.
 * - **`@sizeOf(T)`, `@alignOf(T)`** - the size or alignment of a type, as an integer constant
 * - **`@truncate(T, x)`** - an integer cut down to a smaller integer type, folded when `x` is a constant
 * - **`@panic(msg)`** - a stop at run time, which gives `noreturn`
 * - **`@compileError(msg)`** - an error with a message known while compiling
 * - **`@compileLog(...)`** - prints its arguments while compiling and fails the build, as in Zig
 * - **`@ptrCast(T, p)`** - reinterprets one pointer type as another, inside `unsafe { }`
 * - **`@enumFromInt(E, n)`** - the enum value with this number, which must exist when `n` is a constant
 * - **`@intFromPtr(p)`** - the address of a pointer, as a `usize`
 * - **`@ptrFromInt(T, a)`** - a pointer to an address, inside `unsafe { }`
 * - **`@volatileLoad(p)`, `@volatileStore(p, v)`** - a read or write of `*p` that the optimizer keeps as written,
 *   for hardware registers in freestanding code
 * - **`@errorName(e)`** - the name of an error, as a read-only many-item `u8` pointer
 *
 * Inside `comptime`, the evaluator reports `@compileError` when it runs.
 * Elsewhere it fires when its function is used, and never in a branch that a condition known while compiling rules out.
 * A `@compileLog` in such a branch is skipped as well.
 * An unknown name is an error that lists the builtins, and its arguments are still checked.
 *
 * @example
 * ```hx
 * // const n = @sizeOf(u32);
 * hxsCheckBuiltin(c, node); // the comptime integer type, with the value 4
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckBuiltin(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const name = tokenText(c, n.token);
    const argc = n.b - n.a;
    const tys = types(c);
    const arg0 = argc > 0 ? extraOf(c, n.a) : 0;
    const arg1 = argc > 1 ? extraOf(c, n.a + 1) : 0;

    if (isNamed(name, "@sizeOf") || isNamed(name, "@alignOf")) {
        if (argc != 1) {
            void errorNode(c, node, `\`${name}\` takes one type: \`${name}(T)\``);
            return 0;
        }
        const t = hxsResolveType(c, arg0);
        if (t == 0) return 0;
        let size: u64 = 0;
        let align: u64 = 0;
        hxsSizeAlign(c, t, &size, &align);
        infoOf(c, node).value = hxsIntValue(c, (isNamed(name, "@sizeOf") ? size : align) as i128);
        return tys.comptimeInt;
    }
    if (isNamed(name, "@truncate")) {
        if (argc != 2) {
            void errorNode(c, node, "`@truncate` takes a type and a value: `@truncate(u8, x)`");
            return 0;
        }
        const to = hxsResolveType(c, arg0);
        const from = hxsCheckExpr(c, arg1, 0);
        if (to == 0 || from == 0) return 0;
        if (typeOf(c, to).kind != TypeKind.Int || !hxsIsInteger(c, from)) {
            void errorNode(c, node, `\`@truncate\` converts integers, found \`${typeName(c, from)}\` to \`${typeName(c, to)}\``);
            return 0;
        }
        if (const v = hxsValueOf(c, arg1)) {
            infoOf(c, node).value = hxsIntValue(c, hxsWrapInt(c, to, v.integer));
        } else if (hxsIsComptimeNumber(c, from)) {
            void hxsCoerce(c, arg1, tys.i64);
        }
        return to;
    }
    if (isNamed(name, "@panic") || isNamed(name, "@compileError")) {
        if (argc != 1) {
            void errorNode(c, node, `\`${name}\` takes a message: \`${name}("message")\``);
            return tys.noreturnType;
        }
        if (hxsCheckExpr(c, arg0, tys.string) != 0) void hxsCoerce(c, arg0, tys.string);
        // inside `comptime` the evaluator reports it when it runs; elsewhere it fires when its function is used, and
        // never in a branch a compile-time condition rules out
        if (isNamed(name, "@compileError") && c.comptimeDepth == 0 && c.deadDepth == 0) {
            const v = hxsValueOf(c, arg0);
            if (v == null || v.kind != HxValueString as u8) {
                void errorNode(c, arg0, "`@compileError` needs a message known while compiling");
            } else {
                pushPending(c, node, hxStrndup(v.bytes ?? "", v.len as usize), false);
            }
        }
        return tys.noreturnType;
    }
    if (isNamed(name, "@compileLog")) {   // prints what it's given while compiling, and fails the build, as in Zig
        let text: u8[1024] = undefined;
        void compileLogText(c, node, &text);
        if (c.deadDepth == 0) pushPending(c, node, hxStrndup(&text, cStringLength(&text)), true);
        return tys.voidType;
    }
    if (isNamed(name, "@ptrCast")) {   // reinterprets one pointer type as another
        if (argc != 2) {
            void errorNode(c, node, "`@ptrCast` takes a pointer type and a pointer: `@ptrCast(u8[*], p)`");
            return 0;
        }
        const to = hxsResolveType(c, arg0);
        const from = hxsCheckExpr(c, arg1, 0);
        if (to == 0 || from == 0) return 0;
        const toOk = isPointerType(c, to, true) && !(typeOf(c, to).kind == TypeKind.Optional && typeOf(c, typeOf(c, to).child).kind == TypeKind.Optional);
        if (!toOk || !isPointerType(c, from, true)) {
            void errorNode(c, node, `\`@ptrCast\` converts between pointer types, not \`${typeName(c, from)}\` to \`${typeName(c, to)}\``);
            return 0;
        }
        if (c.unsafeDepth == 0) {
            const diag = errorNode(c, node, "`@ptrCast` needs `unsafe { }`");
            hint(c, diag, "nothing checks that the memory really holds the new type");
        }
        return to;
    }
    if (isNamed(name, "@enumFromInt")) {   // the enum value with this number
        if (argc != 2) {
            void errorNode(c, node, "`@enumFromInt` takes an enum type and an integer: `@enumFromInt(Color, n)`");
            return 0;
        }
        const to = hxsResolveType(c, arg0);
        const from = hxsCheckExpr(c, arg1, 0);
        if (to == 0 || from == 0) return 0;
        if (typeOf(c, to).kind != TypeKind.Enum) {
            void errorNode(c, node, `\`@enumFromInt\` makes an enum, not \`${typeName(c, to)}\``);
            return 0;
        }
        if (!hxsIsInteger(c, from) && typeOf(c, from).kind != TypeKind.ComptimeInt) {
            void errorNode(c, node, `\`@enumFromInt\` takes an integer, not \`${typeName(c, from)}\``);
            return 0;
        }
        hxsResolveAggregate(c, to);
        if (typeOf(c, from).kind == TypeKind.ComptimeInt) void hxsCoerce(c, arg1, typeOf(c, to).child);
        if (const v = hxsValueOf(c, arg1)) {   // a number known now must be one of the enum's values
            const agg = *hxsAggregateOf(c, to);
            let found = false;
            for (const i of 0..agg.fieldCount) {
                if (memberAt(c, agg.membersStart + i).value == v.integer) found = true;
            }
            if (!found) {
                let buf: u8[48] = undefined;
                hxsI128Text(v.integer, &buf, 48);
                unsafe {
                    void errorNode(c, node, `${buf[0..cStringLength(&buf)]} isn't a value of \`${typeName(c, to)}\``);
                }
            }
        }
        return to;
    }
    if (isNamed(name, "@intFromPtr")) {   // a pointer's address
        if (argc != 1) {
            void errorNode(c, node, "`@intFromPtr` takes a pointer: `@intFromPtr(p)`");
            return 0;
        }
        const from = hxsCheckExpr(c, arg0, 0);
        if (from == 0) return 0;
        if (!isPointerType(c, from, true)) {
            void errorNode(c, node, `\`@intFromPtr\` takes a pointer, not \`${typeName(c, from)}\``);
            return 0;
        }
        return tys.usize;
    }
    if (isNamed(name, "@ptrFromInt")) {   // a pointer to an address
        if (argc != 2) {
            void errorNode(c, node, "`@ptrFromInt` takes a pointer type and an address: `@ptrFromInt(u8[*], address)`");
            return 0;
        }
        const to = hxsResolveType(c, arg0);
        if (to == 0) return 0;
        void hxsCheckExpr(c, arg1, tys.usize);
        if (!isPointerType(c, to, true)) {
            void errorNode(c, node, `\`@ptrFromInt\` makes a pointer, not \`${typeName(c, to)}\``);
            return 0;
        }
        if (c.unsafeDepth == 0) {
            const diag = errorNode(c, node, "`@ptrFromInt` needs `unsafe { }`");
            hint(c, diag, "nothing checks that the address holds a valid value");
        }
        return to;
    }
    // `@volatileLoad(p)`, `@volatileStore(p, v)`: a read or write of `*p` the optimizer keeps exactly as written,
    // for hardware registers (a UART's data register, a timer) in freestanding code
    if (isNamed(name, "@volatileLoad") || isNamed(name, "@volatileStore")) {
        const store = isNamed(name, "@volatileStore");
        if (argc != (store ? 2 : 1)) {
            void errorNode(c, node, store ? "`@volatileStore` takes a pointer and a value: `@volatileStore(p, v)`"
                                          : "`@volatileLoad` takes a pointer: `@volatileLoad(p)`");
            return 0;
        }
        const p = hxsCheckExpr(c, arg0, 0);
        if (p == 0) return 0;
        if (typeOf(c, p).kind != TypeKind.Pointer) {
            void errorNode(c, arg0, `\`${name}\` needs a pointer to one value (\`*T\`), found \`${typeName(c, p)}\``);
            return 0;
        }
        const pointee = typeOf(c, p).child;
        if (!store) return pointee;
        if ((typeOf(c, p).flags & Readonly) != 0) {
            void errorNode(c, arg0, `\`@volatileStore\` can't write through \`${typeName(c, p)}\``);
            return 0;
        }
        void hxsCheckExpr(c, arg1, pointee);
        void hxsCoerce(c, arg1, pointee);
        return tys.voidType;
    }
    if (isNamed(name, "@errorName")) {
        if (argc != 1) {
            void errorNode(c, node, "`@errorName` takes one error: `@errorName(e)`");
            return 0;
        }
        const t = hxsCheckExpr(c, arg0, 0);
        if (t != 0 && typeOf(c, t).kind != TypeKind.ErrorSet) {
            void errorNode(c, arg0, `\`@errorName\` needs an error, found \`${typeName(c, t)}\``);
            return 0;
        }
        return hxTypePointer(tys, TypeKind.ManyPointer as u32, tys.u8, true);
    }
    const diag = errorNode(c, node, `unknown builtin \`${name}\``);
    hint(c, diag, "the alpha has `@sizeOf`, `@alignOf`, `@truncate`, `@panic`, `@compileError`, `@errorName`, `@ptrCast`, `@intFromPtr`, `@ptrFromInt`, `@enumFromInt`, `@volatileLoad` and `@volatileStore`");
    for (const i of 0..argc) void hxsCheckExpr(c, extraOf(c, n.a + i), 0);
    return 0;
}
