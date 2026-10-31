/**
 * Imports
 */

import { record } from "@models/ast.model";
import { emitf } from "@models/diagnostic.model";
import { hxTypeName } from "@models/types.model";
import { TypeKind } from "@constants/types.constant";
import { hxArenaStrndup } from "@services/arena.service";
import { DiagNote } from "@constants/diagnostic.constant";
import { NodeKind, FlagComptime } from "@constants/ast.constant";
import { hxZalloc, hxVecGrowImpl } from "@components/memory.component";
import { hxsCheckExpr } from "@modules/sema/components/expr.component";
import { MaxTypeArgs } from "@modules/sema/constants/generics.constant";
import { HxMemberMethod, HxSymFunction } from "@constants/sema.constant";
import { hxsResolveType } from "@modules/sema/components/resolve.component";
import { hxsModuleMember } from "@modules/sema/components/imports.component";
import { hxsResolveSignature } from "@modules/sema/components/decl.component";
import { hxsLookup, hxsAddSymbol } from "@modules/sema/components/scope.component";
import { hxsResolveAggregate } from "@modules/sema/components/aggregate.component";
import { HxFnData, HxContainerData, HxRange } from "@models/structs/ast-model.struct";
import { hxsMarkUsed, hxsCheckArgsUnknown } from "@modules/sema/components/call.component";
import { hxsResolveInterface, hxsImplOf } from "@modules/sema/components/interfaces.component";
import { hxsIsAggregate, hxsCoerce, hxNodeSpan } from "@modules/sema/components/base.component";
import { typeName, errorNode, hint, hintf, hxsPointedArray } from "@modules/sema/components/base.component";
import { hxsFindMember, hxsMemberOf, hxsDeclareAggregateNamed } from "@modules/sema/components/aggregate.component";
import { Ctx, HxValue, TypeParam, HxSema, HxAggregate, HxNodeInfo, HxInstance, FnState } from "@structs/sema.struct";
import { HxValueUndefined, HxSymUsed, HxSymGeneric, HxSymTemplateMethod, HxSymType } from "@constants/sema.constant";
import { hxsTokName, hxsValueOf, hxsImplicitOk, semaOf, astOf, nodeOf } from "@modules/sema/components/base.component";
import { typeOf, symbolOf, infoOf, extraOf, types, paramOf, tokenText } from "@modules/sema/components/base.component";

/**
 * The C library function that formats the `comptime` values of an instance name.
 *
 * @since 1.0.0
 */

extern "C" function snprintf(buf: u8[*], size: usize, fmt: readonly u8[*], ...): i32;

/**
 * Finds an instance by its one-based index.
 *
 * @param c - The checker context
 * @param index - The index of the instance, where 1 is the first one
 * @returns A pointer into the instance table
 *
 * @remarks
 * The index is one-based so that 0 can mean "not in an instance" everywhere else.
 * The pointer stays valid only until the next instance is added, since adding one may move the table.
 *
 * @example
 * ```hx
 * instance(c, 1); // the first instance that the program created
 * ```
 *
 * @see hxsAddInstance
 * @since 1.0.0
 */

export function instance(c: readonly *Ctx, index: u32): *HxInstance {
    unsafe {
        return &@ptrCast(HxInstance[*], semaOf(c).instances.items)[index - 1];
    }
}

/**
 * Reads one word of the shared table of instance arguments.
 *
 * @param s - The checker state
 * @param i - The position in the table, which is the `argsStart` of an instance plus the argument number
 * @returns A type for a type argument, or a value index for a `comptime` argument
 *
 * @remarks
 * Instances share one flat table of arguments, so an instance keeps only `argsStart` and `argsCount`.
 * The kind of the parameter that the word fills decides whether it is a type or a value index,
 * and this function does not tell them apart.
 *
 * @example
 * ```hx
 * // max(1, 2)   the instance is max<i64>
 * instanceArg(s, inst.argsStart); // the type i64
 * ```
 *
 * @see instanceName
 * @since 1.0.0
 */

export function instanceArg(s: readonly *HxSema, i: u32): u32 {
    unsafe {
        return s.instanceArgs.items![i];
    }
}

/**
 * Reads the name token that an instance argument binds.
 *
 * @param s - The checker state
 * @param i - The position in the table, which is the `argsStart` of an instance plus the argument number
 * @returns The token of the type parameter or the `comptime` parameter that the argument fills
 *
 * @remarks
 * The name table runs in step with the argument table,
 * so the same position reads the argument with {@link instanceArg}.
 *
 * @example
 * ```hx
 * // function max<T>(a: T, b: T): T
 * instanceName(s, inst.argsStart); // the token of T
 * ```
 *
 * @see instanceArg
 * @since 1.0.0
 */

export function instanceName(s: readonly *HxSema, i: u32): u32 {
    unsafe {
        return s.instanceNames.items![i];
    }
}

/**
 * Finds the instance that a struct, union, or interface type was made from.
 *
 * @param c - The checker context
 * @param type - The aggregate type
 * @returns The one-based index of the instance, or 0 for a type that is not an instance of a generic one
 *
 * @remarks
 * The type must be a struct, union, or interface type,
 * since the lookup goes through its aggregate record without a check.
 *
 * @example
 * ```hx
 * aggregateInstance(c, boxOfI32); // the index of the Box<i32> instance
 * aggregateInstance(c, plain);    // 0
 * ```
 *
 * @since 1.0.0
 */

export function aggregateInstance(c: readonly *Ctx, type: u32): u32 {
    unsafe {
        return @ptrCast(HxAggregate[*], semaOf(c).aggregates.items)[(typeOf(c, type).len as usize) - 1].instance;
    }
}

/**
 * Appends a word to a vector of words, growing it when it is full.
 *
 * @param items - The items of the vector
 * @param len - The length of the vector
 * @param cap - The capacity of the vector
 * @param v - The word to append
 *
 * @remarks
 * The caller passes the vector as three separate fields,
 * so the same function grows both the argument table and the name table of the instances.
 *
 * @since 1.0.0
 */

function pushWord(items: *?u32[*], len: *u32, cap: *u32, v: u32): void {
    unsafe {
        if (*len == *cap) hxVecGrowImpl(@ptrCast(*?u8[*], items), cap, *len + 1, 4);
        const arr = *items;
        arr![*len] = v;
    }
    *len += 1;
}

/**
 * Binds a type parameter name to a type for the code being checked.
 *
 * @param c - The checker context
 * @param name - The interned name of the type parameter
 * @param type - The type that the name stands for
 *
 * @remarks
 * Type resolution looks a name up in this list before the scopes.
 * Callers that bind names for a short while save the length of the list and set it back afterwards.
 *
 * @example
 * ```hx
 * pushTypeParam(c, nameOfT, types(c).i32); // T now resolves to i32
 * ```
 *
 * @since 1.0.0
 */

export function pushTypeParam(c: *Ctx, name: u32, type: u32): void {
    const list = &c.typeParams;
    unsafe {
        if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, @sizeOf(TypeParam));
        @ptrCast(TypeParam[*], list.items)[list.len] = TypeParam { name, type };
    }
    list.len += 1;
}

/**
 * Saves the per-function state of the checker before it checks something else in between.
 *
 * @param c - The checker context
 * @param st - The state to fill
 *
 * @remarks
 * The state holds the return type, the error set, the loops, the `unsafe`, `comptime`, and `defer` depths,
 * the narrowed names, the scope base, the bound type parameters, the current instance, and the module.
 * Instantiating a generic in the middle of a function body saves it first and restores it after.
 *
 * @example
 * ```hx
 * let saved: FnState = undefined;
 * hxsSaveState(c, &saved);
 * hxsEnterInstance(c, index); // check the instance
 * hxsRestoreState(c, &saved); // back in the function being checked
 * ```
 *
 * @see hxsRestoreState
 * @since 1.0.0
 */

export extern "C" function hxsSaveState(c: readonly *Ctx, st: *FnState): void {
    *st = FnState {
        returnType: c.returnType, errorSet: c.errorSet, functionSymbol: c.functionSymbol, loopCount: c.loopCount,
        deferFloor: c.deferFloor, unsafeDepth: c.unsafeDepth, comptimeDepth: c.comptimeDepth,
        narrowedLen: c.narrowed.len, scopeBase: c.scopeBase, typeParamsLen: c.typeParams.len,
        instance: c.instance, module: c.module, inDefer: c.inDefer, globalsOnly: c.globalsOnly,
        pointerBinding: c.pointerBinding, inTest: c.inTest, deadDepth: c.deadDepth, loops: c.loops,
    };
}

/**
 * Restores the per-function state that {@link hxsSaveState} saved.
 *
 * @param c - The checker context
 * @param st - The saved state
 *
 * @remarks
 * The lists of narrowed names and of type parameters go back to their saved lengths,
 * so whatever the code in between added to them is dropped.
 *
 * @example
 * ```hx
 * hxsRestoreState(c, &saved); // the context is as it was when saved
 * ```
 *
 * @see hxsSaveState
 * @since 1.0.0
 */

export extern "C" function hxsRestoreState(c: *Ctx, st: readonly *FnState): void {
    c.returnType = st.returnType;
    c.errorSet = st.errorSet;
    c.functionSymbol = st.functionSymbol;
    c.loopCount = st.loopCount;
    c.deferFloor = st.deferFloor;
    c.unsafeDepth = st.unsafeDepth;
    c.comptimeDepth = st.comptimeDepth;
    c.narrowed.len = st.narrowedLen;
    c.scopeBase = st.scopeBase;
    c.typeParams.len = st.typeParamsLen;
    c.instance = st.instance;
    c.module = st.module;
    c.inDefer = st.inDefer;
    c.globalsOnly = st.globalsOnly;
    c.pointerBinding = st.pointerBinding;
    c.inTest = st.inTest;
    c.deadDepth = st.deadDepth;
    c.loops = st.loops;
}

/**
 * Reads the `<T, U>` list of a function or a container declaration.
 *
 * @param c - The checker context
 * @param decl - The declaration node, a function or a struct, union, or interface
 * @param start - Set to the first extra slot of the list
 * @param end - Set to the extra slot past the list
 * @param firstNode - Set to the first node of the declaration
 *
 * @remarks
 * Each slot of the list holds a `GenericParam` node, whose token is the name and whose `a` is the constraint.
 * The first node and the declaration node bound the nodes that an instance keeps its own information for.
 *
 * @example
 * ```hx
 * // struct Pair<A, B> { ... }
 * hxsGenericParams(c, decl, &start, &end, &first);
 * end - start; // 2
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsGenericParams(c: readonly *Ctx, decl: u32, start: *u32, end: *u32, firstNode: *u32): void {
    if (nodeOf(c, decl).kind == NodeKind.Function) {
        const fn = record<HxFnData>(astOf(c), nodeOf(c, decl).a);
        *start = fn.genericsStart;
        *end = fn.genericsEnd;
        *firstNode = fn.firstNode;
    } else {
        const data = record<HxContainerData>(astOf(c), nodeOf(c, decl).a);
        *start = data.genericsStart;
        *end = data.genericsEnd;
        *firstNode = data.firstNode;
    }
}

/**
 * Makes an instance current, with its own node information and its type parameters bound to its type arguments.
 *
 * @param c - The checker context
 * @param index - The one-based index of the instance
 *
 * @remarks
 * Any type parameters bound before are dropped.
 * Only the type arguments are bound here, since the `comptime` values are bound as constant parameters instead.
 * Callers save the state first, since nothing here restores it.
 *
 * @example
 * ```hx
 * hxsEnterInstance(c, index); // inside max<i64>, T resolves to i64
 * ```
 *
 * @see hxsSaveState
 * @since 1.0.0
 */

export extern "C" function hxsEnterInstance(c: *Ctx, index: u32): void {
    const inst = *instance(c, index);
    c.instance = index;
    c.typeParams.len = 0;
    const s = semaOf(c);
    for (const i of 0..inst.typeCount) {   // `comptime` values are bound as constant parameters instead
        pushTypeParam(c, hxsTokName(c, instanceName(s, inst.argsStart + i)), instanceArg(s, inst.argsStart + i));
    }
}

/**
 * Checks whether two values known while compiling are the same.
 *
 * @param s - The checker state
 * @param a - The index of the first value
 * @param b - The index of the second value
 * @returns `true` when both values have the same kind and contents
 *
 * @remarks
 * This is what lets `repeat(3)` called twice share one instance.
 * Integers, errors, and functions compare their numbers, floats, booleans, and strings compare their contents,
 * and aggregates compare each element in turn.
 * Values of any other kind are the same whenever their kinds match.
 *
 * @example
 * ```hx
 * // repeat(3) and repeat(3)
 * hxsSameValue(s, first, second); // true
 * ```
 *
 * @see hxsFindInstance
 * @since 1.0.0
 */

export extern "C" function hxsSameValue(s: readonly *HxSema, a: u32, b: u32): bool {
    if (a == b) return true;
    let x: HxValue = undefined;
    let y: HxValue = undefined;
    unsafe {
        x = @ptrCast(HxValue[*], s.values.items)[a];
        y = @ptrCast(HxValue[*], s.values.items)[b];
    }
    if (x.kind != y.kind) return false;
    switch (x.kind as u32) {
        case 1, 7, 8: return x.integer == y.integer;   // INT, ERROR, FUNCTION
        case 2: return x.floating == y.floating;       // FLOAT
        case 3: return x.boolean == y.boolean;         // BOOL
        case 4: {                                      // STRING
            if (x.len != y.len) return false;
            unsafe {
                for (const i of 0..x.len) {
                    if (x.bytes![i] != y.bytes![i]) return false;
                }
            }
            return true;
        }
        case 9: {                                      // AGGREGATE
            if (x.count != y.count) return false;
            for (const i of 0..x.count) {
                unsafe {
                    if (!hxsSameValue(s, s.valueElems.items![x.elems + i], s.valueElems.items![y.elems + i])) return false;
                }
            }
            return true;
        }
        default: return true;
    }
}

/**
 * Looks for an instance of a declaration that already has these arguments.
 *
 * @param c - The checker context
 * @param decl - The generic declaration
 * @param args - The arguments, types first, then `comptime` values
 * @param count - The number of arguments
 * @param wantType - `true` to find a struct, union, or interface instance, `false` to find a function instance
 * @returns The one-based index of the instance, or 0 when there is none yet
 *
 * @remarks
 * Type arguments match when they are the same type.
 * The `comptime` arguments match by value through {@link hxsSameValue}.
 *
 * @example
 * ```hx
 * // max(1, 2) and then max(3, 4)
 * hxsFindInstance(c, decl, &args, 1, false); // the index of max<i64>, made by the first call
 * ```
 *
 * @see hxsAddInstance
 * @since 1.0.0
 */

export extern "C" function hxsFindInstance(c: readonly *Ctx, decl: u32, args: readonly u32[*], count: u32, wantType: bool): u32 {
    const s = semaOf(c);
    for (const i of 0..s.instances.len) {
        const inst = instance(c, i + 1);
        if (inst.decl != decl || inst.argsCount != count || (wantType ? inst.type == 0 : inst.symbol == 0)) continue;
        let same = true;
        for (const j of 0..count) {
            if (!same) break;
            const have = instanceArg(s, inst.argsStart + j);
            unsafe {
                same = j < inst.typeCount ? have == args[j] : hxsSameValue(s, have, args[j]);
            }
        }
        if (same) return i + 1;
    }
    return 0;
}

/**
 * Adds an instance of a generic declaration to the instance table.
 *
 * @param c - The checker context
 * @param decl - The generic declaration
 * @param firstNode - The first node of the declaration
 * @param names - The tokens of the parameters that the arguments bind
 * @param args - The arguments, types first, then `comptime` values
 * @param count - The number of arguments
 * @param typeCount - How many of the arguments are types
 * @returns The one-based index of the new instance
 *
 * @remarks
 * The instance gets its own zeroed node information for the nodes from `firstNode` to `decl`,
 * since the same nodes have different types in each instance.
 * The arguments and their names go to the end of the shared argument tables.
 * The caller fills in the symbol or the type of the instance.
 *
 * @example
 * ```hx
 * hxsAddInstance(c, decl, first, &names, &args, 1, 1); // 1 for the first instance
 * ```
 *
 * @see hxsFindInstance
 * @since 1.0.0
 */

export extern "C" function hxsAddInstance(c: *Ctx, decl: u32, firstNode: u32, names: readonly u32[*], args: readonly u32[*],
                                            count: u32, typeCount: u32): u32 {
    const s = semaOf(c);
    let inst = HxInstance {
        decl, lo: firstNode, hi: decl, info: null, argsStart: s.instanceArgs.len, argsCount: count, typeCount,
        symbol: 0, type: 0, site: 0,
    };
    unsafe {
        inst.info = @ptrCast(*HxNodeInfo, hxZalloc(((decl - firstNode + 1) as usize) * @sizeOf(HxNodeInfo)));
        for (const i of 0..count) {
            pushWord(&s.instanceArgs.items, &s.instanceArgs.len, &s.instanceArgs.cap, args[i]);
            pushWord(&s.instanceNames.items, &s.instanceNames.len, &s.instanceNames.cap, names[i]);
        }
        const list = &s.instances;
        if (list.len == list.cap) hxVecGrowImpl(@ptrCast(*?u8[*], &list.items), &list.cap, list.len + 1, @sizeOf(HxInstance));
        @ptrCast(HxInstance[*], list.items)[list.len] = inst;
    }
    s.instances.len += 1;
    return s.instances.len;
}

/**
 * Checks whether a text is exactly a given word.
 *
 * @param text - The text to compare
 * @param word - The word to compare against
 * @returns `true` when both have the same bytes
 *
 * @remarks
 * The comparison is exact and case-sensitive, and it compares lengths first, so a prefix never matches.
 *
 * @since 1.0.0
 */

function wordIs(text: string, word: string): bool {
    if (text.len != word.len) return false;
    for (const ch, i of word) {
        if (text[i] != ch) return false;
    }
    return true;
}

/**
 * Checks that a type fits the constraint of a type parameter.
 *
 * @param c - The checker context
 * @param constraint - The constraint node after `extends`
 * @param type - The type argument
 * @param site - The node to report at
 * @param module - The module that declared the generic, where the constraint's name is looked up
 * @param names - The tokens of all type parameters of the generic
 * @param bound - The types bound to those parameters
 * @param count - The number of type parameters
 * @returns `true` when the type fits, `false` after reporting
 *
 * @remarks
 * The names `Numeric`, `Integer`, and `Float` are built in.
 * `Numeric` takes any integer or float type, `Integer` takes integers, and `Float` takes floats.
 * They report that `bool` doesn't satisfy `Numeric` when the type is not one of them.
 * Any other constraint is an interface that the type must implement.
 * It is resolved with the other parameters bound,
 * so a constraint such as `I extends Iterator<T>` can use them.
 * A type without the implementation reports that it doesn't implement the interface,
 * with a hint that names the missing or mismatched method.
 *
 * @example
 * ```hx
 * // function max<T extends Numeric>(a: T, b: T): T, called as max(true, false)
 * hxsCheckConstraint(c, constraint, boolType, site, module, &names, &bound, 1); // false
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsCheckConstraint(c: *Ctx, constraint: u32, type: u32, site: u32, module: u32,
                                                names: readonly u32[*], bound: readonly u32[*], count: u32): bool {
    const name = tokenText(c, nodeOf(c, constraint).token);
    const k = typeOf(c, type).kind;
    const isIdent = nodeOf(c, constraint).kind == NodeKind.Ident;
    let ok = false;
    if (isIdent && wordIs(name, "Numeric")) {
        ok = k == TypeKind.Int || k == TypeKind.Float;
    } else if (isIdent && wordIs(name, "Integer")) {
        ok = k == TypeKind.Int;
    } else if (isIdent && wordIs(name, "Float")) {
        ok = k == TypeKind.Float;
    } else {
        const savedModule = c.module;
        const savedParams = c.typeParams.len;
        c.module = module;
        for (const i of 0..count) {   // the constraint may use the other parameters: `I extends Iterator<T>`
            unsafe {
                pushTypeParam(c, hxsTokName(c, names[i]), bound[i]);
            }
        }
        const iface = hxsResolveInterface(c, constraint, "`extends`");
        c.typeParams.len = savedParams;
        c.module = savedModule;
        if (iface == 0) return false;
        if (hxsImplOf(c, type, iface, 0xFFFF_FFFF, site) != 0) return true;
        const diag = errorNode(c, site, `\`${typeName(c, type)}\` doesn't implement \`${typeName(c, iface)}\``);
        void hxsImplOf(c, type, iface, diag, site);
        return false;
    }
    if (!ok) void errorNode(c, site, `\`${typeName(c, type)}\` doesn't satisfy \`${name}\``);
    return ok;
}

/**
 * Points the errors inside a generic body back at the use that instantiated it.
 *
 * @param c - The checker context
 * @param site - The node that instantiated the generic, where 0 adds no note
 * @param what - The name of the instance, such as `Box<i32>`
 * @param errorsBefore - The error count from before the instance was checked
 *
 * @remarks
 * The note names the instance at the site, as the example shows.
 * It follows the errors and appears only when checking the instance added at least one error.
 *
 * @example
 * ```hx
 * instanceNote(c, site, "bad<i64>", errors); // note: while instantiating `bad<i64>` here
 * ```
 *
 * @see hxsInstanceNote
 * @since 1.0.0
 */

export function instanceNote(c: *Ctx, site: u32, what: string, errorsBefore: u32): void {
    if (semaOf(c).diags!.errorCount == errorsBefore || site == 0) return;
    let start: u32 = 0;
    let len: u32 = 0;
    hxNodeSpan(astOf(c), site, &start, &len);
    void emitf(semaOf(c).diags!, DiagNote, semaOf(c).src, start, len, `while instantiating \`${what}\` here`);
}

/**
 * Adds the note of {@link instanceNote} for a name given as a NUL-terminated string.
 *
 * @param c - The checker context
 * @param site - The node that instantiated the generic, where 0 adds no note
 * @param what - The name of the instance, ended by a NUL byte
 * @param errorsBefore - The error count from before the instance was checked
 *
 * @remarks
 * It measures the name up to its NUL byte and hands the slice to {@link instanceNote},
 * which adds the note only when the instance added an error.
 *
 * @example
 * ```hx
 * hxsInstanceNote(c, site, "Box<i32>", errors); // note: while instantiating `Box<i32>` here
 * ```
 *
 * @see instanceNote
 * @since 1.0.0
 */

export extern "C" function hxsInstanceNote(c: *Ctx, site: u32, what: readonly u8[*], errorsBefore: u32): void {
    unsafe {
        let n: usize = 0;
        while (what[n] != 0) n += 1;
        instanceNote(c, site, what[0..n], errorsBefore);
    }
}

/**
 * Writes an instance argument as it reads in a name.
 *
 * @param s - The checker state
 * @param inst - The instance
 * @param i - The number of the argument within the instance
 * @param buf - The buffer that receives the NUL-terminated text
 * @param size - The size of the buffer
 *
 * @remarks
 * A type argument is written as its type name, such as `u8`.
 * A `comptime` argument is written as its value:
 * integers in decimal, booleans as `true` or `false`, floats with `%g`,
 * and strings in double quotes, cut to their first 24 bytes.
 * A value of any other kind is written as `#` and its value index.
 * Code generation also uses it to name the symbols of instances.
 *
 * @example
 * ```hx
 * // repeat(-42)
 * hxSemaInstanceArg(s, inst, 0, &buf, 96); // buf holds "-42"
 * ```
 *
 * @see hxsInstanceName
 * @since 1.0.0
 */

export extern "C" function hxSemaInstanceArg(s: readonly *HxSema, inst: readonly *HxInstance, i: u32, buf: u8[*], size: usize): void {
    const arg = instanceArg(s, inst.argsStart + i);
    if (i < inst.typeCount) {
        hxTypeName(&s.types, arg, buf, size);
        return;
    }
    let v: HxValue = undefined;
    unsafe {
        v = @ptrCast(HxValue[*], s.values.items)[arg];
    }
    switch (v.kind as u32) {
        case 1: {   // INT
            let digits: u8[48] = undefined;
            let n: usize = 0;
            let u: u128 = v.integer < 0 ? ((-(v.integer + 1)) as u128) + 1 : v.integer as u128;
            while (true) {
                digits[n] = '0' + @truncate(u8, u % 10);
                n += 1;
                u /= 10;
                if (u == 0 || n >= 48) break;
            }
            let used: usize = 0;
            unsafe {
                if (v.integer < 0 && used + 1 < size) {
                    buf[used] = '-';
                    used += 1;
                }
                while (n > 0 && used + 1 < size) {
                    n -= 1;
                    buf[used] = digits[n];
                    used += 1;
                }
                buf[used] = 0;
            }
        }
        case 3: void snprintf(buf, size, "%s", v.boolean ? "true" : "false");
        case 2: void snprintf(buf, size, "%g", v.floating);
        case 4: void snprintf(buf, size, "\"%.*s\"", v.len > 24 ? 24 : v.len as i32, v.bytes ?? "");
        default: void snprintf(buf, size, "#%u", arg);
    }
}

/**
 * Builds the name of an instance, such as `ArrayList<u8, i32>`.
 *
 * @param c - The checker context
 * @param nameToken - The token of the generic's name
 * @param inst - The instance
 * @param outLen - Set to the length of the name
 * @returns The name, kept in the checker's arena
 *
 * @remarks
 * Each argument is written by {@link hxSemaInstanceArg}, and the arguments are separated by `, `.
 * The name is cut at 255 bytes.
 *
 * @example
 * ```hx
 * hxsInstanceName(c, token, inst, &len); // "ArrayList<u8, i32>"
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsInstanceName(c: *Ctx, nameToken: u32, inst: readonly *HxInstance, outLen: *u32): readonly u8[*] {
    let buf: u8[256] = undefined;
    let used: usize = 0;
    const name = tokenText(c, nameToken);
    for (const ch of name) {
        if (used < 255) {
            buf[used] = ch;
            used += 1;
        }
    }
    if (used < 255) {
        buf[used] = '<';
        used += 1;
    }
    for (const i of 0..inst.argsCount) {
        let arg: u8[96] = undefined;
        hxSemaInstanceArg(semaOf(c), inst, i, &arg, 96);
        if (i > 0) {
            for (const ch of ", ") {
                if (used < 255) {
                    buf[used] = ch;
                    used += 1;
                }
            }
        }
        let k: usize = 0;
        while (arg[k] != 0 && used < 255) {
            buf[used] = arg[k];
            used += 1;
            k += 1;
        }
    }
    if (used < 255) {
        buf[used] = '>';
        used += 1;
    }
    *outLen = @truncate(u32, used);
    return hxArenaStrndup(&semaOf(c).arena, &buf, used);
}

/**
 * Checks that a generic was given as many type arguments as it takes.
 *
 * @param c - The checker context
 * @param template - The symbol of the generic
 * @param count - The number of type parameters that it takes
 * @param given - The number of type arguments given
 * @param site - The node to report at
 * @returns `true` when the numbers match, `false` after reporting
 *
 * @remarks
 * The error names the generic and both counts, with the singular or plural noun that each count needs.
 * It checks only the number of arguments, and the constraints are checked separately.
 *
 * @example
 * ```hx
 * // const pair: Box<i32, i32> = undefined;
 * hxsGenericArity(c, box, 1, 2, site); // false, `Box` takes 1 type argument, but 2 were given
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsGenericArity(c: *Ctx, template: u32, count: u32, given: u32, site: u32): bool {
    if (count == given) return true;
    const name = tokenText(c, symbolOf(c, template).token);
    void errorNode(c, site, `\`${name}\` takes ${count} type argument${count == 1 ? "" : "s"}, but ${given} ${given == 1 ? "was" : "were"} given`);
    return false;
}

/**
 * Finds or creates the instance of a generic struct, union, or interface for some type arguments.
 *
 * @param c - The checker context
 * @param template - The symbol of the generic type
 * @param args - The type arguments
 * @param count - The number of type arguments
 * @param site - The node that names the instance, where errors are reported
 * @returns The type of the instance, or 0 after reporting
 *
 * @remarks
 * The number of arguments and each constraint are checked first.
 * An argument of 0, a type that already failed, gives 0 without a new error.
 * The instance belongs to the module that declared the generic, and its members are resolved there,
 * with the type parameters bound.
 * Errors inside the declaration get a note at the site that names the instance, such as `Box<i32>`.
 *
 * @example
 * ```hx
 * // const b: Box<i32> = ...
 * hxsInstantiateStruct(c, box, &args, 1, site); // the type Box<i32>, the same one every time
 * ```
 *
 * @see hxsInstantiateTypeNode
 * @since 1.0.0
 */

export extern "C" function hxsInstantiateStruct(c: *Ctx, template: u32, args: readonly u32[*], count: u32, site: u32): u32 {
    const decl = symbolOf(c, template).decl;
    let gs: u32 = 0;
    let ge: u32 = 0;
    let first: u32 = 0;
    hxsGenericParams(c, decl, &gs, &ge, &first);
    if (!hxsGenericArity(c, template, ge - gs, count, site)) return 0;
    unsafe {
        for (const i of 0..count) {
            if (args[i] == 0) return 0;
        }
    }
    const existing = hxsFindInstance(c, decl, args, count, true);
    if (existing != 0) return instance(c, existing).type;

    let names: u32[16] = undefined;
    for (const i of 0..count) names[i] = nodeOf(c, extraOf(c, gs + i)).token;
    for (const i of 0..count) {
        const constraint = nodeOf(c, extraOf(c, gs + i)).a;
        unsafe {
            if (constraint != 0 && !hxsCheckConstraint(c, constraint, args[i], site, symbolOf(c, template).module, &names, args, count)) return 0;
        }
    }

    const errors = semaOf(c).diags!.errorCount;
    const savedModule = c.module;
    c.module = symbolOf(c, template).module;   // the instance belongs to the module that declared the template
    const index = hxsAddInstance(c, decl, first, &names, args, count, count);
    let nameLen: u32 = 0;
    const name = hxsInstanceName(c, symbolOf(c, template).token, instance(c, index), &nameLen);
    const declKind = nodeOf(c, decl).kind;
    const kind = declKind == NodeKind.Union ? TypeKind.Union : declKind == NodeKind.Interface ? TypeKind.Interface : TypeKind.Struct;
    const type = hxsDeclareAggregateNamed(c, kind as u32, decl, name, nameLen);
    unsafe {
        @ptrCast(HxAggregate[*], semaOf(c).aggregates.items)[(typeOf(c, type).len as usize) - 1].instance = index;
    }
    instance(c, index).type = type;
    c.module = savedModule;

    let saved: FnState = undefined;
    hxsSaveState(c, &saved);
    hxsEnterInstance(c, index);
    c.module = symbolOf(c, template).module;
    c.scopeBase = c.scope.len;
    hxsResolveAggregate(c, type);
    hxsRestoreState(c, &saved);
    unsafe {
        instanceNote(c, site, name[0..nameLen], errors);
    }
    return type;
}

/**
 * Resolves a `Name<Args>` node to the instance that it names.
 *
 * @param c - The checker context
 * @param node - The generic instance node, used as a type or as the base of `ArrayList<u8>.init()`
 * @returns The type of the instance, or 0 after reporting
 *
 * @remarks
 * The name is a plain name or a member of an imported module, such as `list.ArrayList<u8>`.
 * It reports an unknown type when no symbol has the name,
 * and reports that the name is not generic when the symbol is not a generic type.
 * More than {@link MaxTypeArgs} arguments report `too many type arguments`.
 * The type is also stored as the type of the node.
 *
 * @example
 * ```hx
 * // const b: Box<i32> = undefined;
 * hxsInstantiateTypeNode(c, node); // the type Box<i32>
 * ```
 *
 * @see hxsInstantiateStruct
 * @since 1.0.0
 */

export extern "C" function hxsInstantiateTypeNode(c: *Ctx, node: u32): u32 {
    const n = nodeOf(c, node);
    const args = record<HxRange>(astOf(c), n.b);
    const base = n.a;
    let sym: u32 = 0;
    if (nodeOf(c, base).kind == NodeKind.FieldAccess) {
        sym = hxsModuleMember(c, nodeOf(c, base).a, nodeOf(c, base).token, true);
        if (sym == 0xFFFF_FFFF) return 0;
    } else if (nodeOf(c, base).kind == NodeKind.Ident) {
        sym = hxsLookup(c, hxsTokName(c, nodeOf(c, base).token));
    } else {
        void errorNode(c, node, "expected the name of a generic type");
        return 0;
    }
    const name = tokenText(c, nodeOf(c, base).token);
    if (sym == 0 || symbolOf(c, sym).kind != HxSymType as u8 || (symbolOf(c, sym).flags & (HxSymGeneric as u16)) == 0) {
        if (sym == 0) void errorNode(c, n.a, `unknown type \`${name}\``);
        else void errorNode(c, n.a, `\`${name}\` is not generic`);
        return 0;
    }
    hxsMarkUsed(c, sym);
    let argTypes: u32[16] = undefined;
    let count: u32 = 0;
    for (const i of args.start..args.end) {
        if (count == MaxTypeArgs) {
            void errorNode(c, node, "too many type arguments");
            return 0;
        }
        argTypes[count] = hxsResolveType(c, extraOf(c, i));
        count += 1;
    }
    const type = hxsInstantiateStruct(c, sym, &argTypes, count, node);
    infoOf(c, node).type = type;
    return type;
}

/**
 * Finds or creates the instance of a generic function for some arguments.
 *
 * @param c - The checker context
 * @param template - The symbol of the generic function
 * @param names - The tokens of the parameters that the arguments bind
 * @param args - The arguments, types first, then `comptime` values
 * @param count - The number of arguments
 * @param typeCount - How many of the arguments are types
 * @param owner - The struct instance for a method of a generic struct, or 0
 * @param site - The node that instantiated it, where notes go
 * @returns The symbol of the instance, or 0 after reporting
 *
 * @remarks
 * A new instance gets its own function symbol, marked as used, and has its signature resolved right away.
 * Its body is queued to be checked with the other functions.
 * A function that already has 1000 instances reports that it was instantiated 1000 times,
 * which catches a function that calls itself with a new `comptime` argument each time.
 * Errors in the signature get a note that names the instance, such as `max<i64>` or `Box<i32>.get` for a method.
 *
 * @example
 * ```hx
 * // max(1, 2)
 * hxsInstantiateFunction(c, max, &names, &args, 1, 1, 0, site); // the symbol of max<i64>
 * ```
 *
 * @see hxsGenericCallInstance
 * @since 1.0.0
 */

export extern "C" function hxsInstantiateFunction(c: *Ctx, template: u32, names: readonly u32[*], args: readonly u32[*],
                                                    count: u32, typeCount: u32, owner: u32, site: u32): u32 {
    const decl = symbolOf(c, template).decl;
    const existing = hxsFindInstance(c, decl, args, count, false);
    if (existing != 0) return instance(c, existing).symbol;

    let sameDecl: u32 = 0;
    for (const i of 0..semaOf(c).instances.len) {
        if (instance(c, i + 1).decl == decl) sameDecl += 1;
    }
    if (sameDecl >= 1000) {
        const diag = errorNode(c, site, `\`${tokenText(c, nodeOf(c, decl).token)}\` was instantiated 1000 times`);
        hint(c, diag, "does it call itself with a new `comptime` argument each time, without stopping?");
        return 0;
    }

    const fn = record<HxFnData>(astOf(c), nodeOf(c, decl).a);
    const index = hxsAddInstance(c, decl, fn.firstNode, names, args, count, typeCount);
    const sym = hxsAddSymbol(c, HxSymFunction, nodeOf(c, decl).token, decl, 0);
    symbolOf(c, sym).module = symbolOf(c, template).module;
    symbolOf(c, sym).owner = owner;
    symbolOf(c, sym).instance = index;
    symbolOf(c, sym).flags |= HxSymUsed as u16;
    instance(c, index).symbol = sym;
    instance(c, index).site = site;

    const errors = semaOf(c).diags!.errorCount;
    let saved: FnState = undefined;
    hxsSaveState(c, &saved);
    hxsEnterInstance(c, index);
    c.module = symbolOf(c, sym).module;
    c.scopeBase = c.scope.len;
    c.globalsOnly = false;
    hxsResolveSignature(c, sym);
    hxsRestoreState(c, &saved);
    if (symbolOf(c, sym).type != 0 && fn.body != 0) {   // its body is checked with the others
        const s = semaOf(c);
        pushWord(&s.functions.items, &s.functions.len, &s.functions.cap, sym);
    }

    if (semaOf(c).diags!.errorCount != errors) {
        if (owner != 0) {
            let what: u8[256] = undefined;
            const ownerName = typeName(c, owner);
            const method = tokenText(c, nodeOf(c, decl).token);
            let n: usize = 0;
            for (const ch of ownerName) {
                if (n < 255) {
                    what[n] = ch;
                    n += 1;
                }
            }
            if (n < 255) {
                what[n] = '.';
                n += 1;
            }
            for (const ch of method) {
                if (n < 255) {
                    what[n] = ch;
                    n += 1;
                }
            }
            instanceNote(c, site, what[0..n], errors);
        } else {
            let nameLen: u32 = 0;
            const name = hxsInstanceName(c, nodeOf(c, decl).token, instance(c, index), &nameLen);
            unsafe {
                instanceNote(c, site, name[0..nameLen], errors);
            }
        }
    } else if (owner == 0) {
        let nameLen: u32 = 0;
        void hxsInstanceName(c, nodeOf(c, decl).token, instance(c, index), &nameLen);   // as the C version did: names it once
    }
    return sym;
}

/**
 * Finds the instance of a generic struct's method for one instance of the struct.
 *
 * @param c - The checker context
 * @param method - The symbol of the method
 * @param owner - The type that the method is called on
 * @param site - The node that uses the method
 * @returns The symbol of the method instance, or `method` itself for a method that is not generic
 *
 * @remarks
 * The method instance takes the type arguments of the owner, so `get` on a `Box<i32>` is checked with `T` as `i32`.
 * A method of an owner that is not an instance is returned as it is too.
 *
 * @example
 * ```hx
 * // b.get()   b is a Box<i32>
 * hxsMethodInstance(c, get, boxOfI32, site); // the symbol of Box<i32>.get
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsMethodInstance(c: *Ctx, method: u32, owner: u32, site: u32): u32 {
    if ((symbolOf(c, method).flags & (HxSymGeneric as u16)) == 0) return method;
    const inst = aggregateInstance(c, owner);
    if (inst == 0) return method;
    const in = *instance(c, inst);
    let names: u32[16] = undefined;
    let args: u32[16] = undefined;
    const s = semaOf(c);
    for (const i of 0..in.argsCount) {   // copies: instantiating appends to these vectors
        names[i] = instanceName(s, in.argsStart + i);
        args[i] = instanceArg(s, in.argsStart + i);
    }
    return hxsInstantiateFunction(c, method, &names, &args, in.argsCount, in.argsCount, owner, site);
}

/**
 * Gives a literal type the runtime type that it stands for.
 *
 * @param c - The checker context
 * @param t - The type
 * @returns `i64` for an integer literal, `f64` for a float literal, `string` for a string literal, and `t` otherwise
 *
 * @remarks
 * Literals have no runtime type, so inferring `T` from one picks the natural type for it.
 *
 * @example
 * ```hx
 * // id(1)
 * hxsRuntimeType(c, literal); // i64
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsRuntimeType(c: *Ctx, t: u32): u32 {
    return switch (typeOf(c, t).kind) {
        case TypeKind.ComptimeInt: types(c).i64;
        case TypeKind.ComptimeFloat: types(c).f64;
        case TypeKind.StringLiteral: types(c).string;
        default: t;
    };
}

/**
 * Matches the type syntax of a parameter against the type of an argument and binds the type parameters it mentions.
 *
 * @param c - The checker context
 * @param pattern - The type node of the parameter
 * @param actualType - The type of the argument
 * @param names - The tokens of the type parameters to bind
 * @param count - The number of type parameters
 * @param bound - The bound types, where 0 means not bound yet
 *
 * @remarks
 * The match walks pointers, slices, arrays, optionals, error unions, `dyn` types, function types,
 * and the arguments of generic instances, so `*T` against `*u8` binds `T` to `u8`.
 * A slice pattern also matches an array and a pointer to an array.
 * A literal binds its runtime type.
 * A parameter bound before is widened when the new type takes the old one implicitly,
 * so `max(1 as u8, 2 as i32)` binds `T` to `i32`.
 * Parts that do not match bind nothing.
 *
 * @example
 * ```hx
 * // function first<T>(items: T[]): T, called with a u8[4]
 * hxsUnify(c, pattern, arrayOfU8, &names, 1, &bound);
 * bound[0]; // u8
 * ```
 *
 * @see hxsRuntimeType
 * @since 1.0.0
 */

export extern "C" function hxsUnify(c: *Ctx, pattern: u32, actualType: u32, names: readonly u32[*], count: u32, bound: u32[*]): void {
    if (pattern == 0 || actualType == 0) return;
    const actual = hxsRuntimeType(c, actualType);
    const p = nodeOf(c, pattern);
    const a = typeOf(c, actual);
    switch (p.kind) {
        case NodeKind.Ident: {
            const name = hxsTokName(c, p.token);
            for (const i of 0..count) {
                unsafe {
                    if (hxsTokName(c, names[i]) != name) continue;
                    if (bound[i] == 0 || hxsImplicitOk(c, bound[i], actual)) bound[i] = actual;   // widen to fit every argument
                }
                return;
            }
        }
        case NodeKind.TypePointer: if (a.kind == TypeKind.Pointer) hxsUnify(c, p.a, a.child, names, count, bound);
        case NodeKind.TypeManyPointer: if (a.kind == TypeKind.ManyPointer) hxsUnify(c, p.a, a.child, names, count, bound);
        case NodeKind.TypeSlice: {
            const array = hxsPointedArray(c, actual);
            if (a.kind == TypeKind.Slice || a.kind == TypeKind.Array) hxsUnify(c, p.a, a.child, names, count, bound);
            else if (array != 0) hxsUnify(c, p.a, typeOf(c, array).child, names, count, bound);
        }
        case NodeKind.TypeArray: if (a.kind == TypeKind.Array) hxsUnify(c, p.a, a.child, names, count, bound);
        case NodeKind.TypeReadonly: hxsUnify(c, p.a, actual, names, count, bound);
        case NodeKind.TypeOptional: hxsUnify(c, p.a, a.kind == TypeKind.Optional ? a.child : actual, names, count, bound);
        case NodeKind.TypeErrorUnion: if (a.kind == TypeKind.ErrorUnion) hxsUnify(c, p.a, a.child, names, count, bound);
        case NodeKind.TypeFunction: {
            if (a.kind != TypeKind.Function) return;
            const fn = record<HxFnData>(astOf(c), p.a);
            let i: u32 = 0;
            while (i < fn.paramsEnd - fn.paramsStart && (i as u64) < a.len) {
                hxsUnify(c, nodeOf(c, extraOf(c, fn.paramsStart + i)).a, paramOf(c, a, i as u64), names, count, bound);
                i += 1;
            }
            hxsUnify(c, fn.returnType, a.child, names, count, bound);
        }
        case NodeKind.TypeDyn: if (a.kind == TypeKind.Dyn) hxsUnify(c, p.a, a.child, names, count, bound);
        case NodeKind.GenericInstance: {
            if (a.kind != TypeKind.Struct && a.kind != TypeKind.Union && a.kind != TypeKind.Interface) return;
            const inst = aggregateInstance(c, actual);
            if (inst == 0) return;
            const in = *instance(c, inst);
            const args = record<HxRange>(astOf(c), p.b);
            let i: u32 = 0;
            while (i < args.end - args.start && i < in.argsCount) {
                hxsUnify(c, extraOf(c, args.start + i), instanceArg(semaOf(c), in.argsStart + i), names, count, bound);
                i += 1;
            }
        }
        default: {}
    }
}

/**
 * Resolves the type of a `comptime` parameter of a generic, with its type parameters bound.
 *
 * @param c - The checker context
 * @param template - The symbol of the generic function
 * @param paramNode - The parameter node
 * @param names - The tokens of the type parameters
 * @param bound - The types bound to them
 * @param count - The number of type parameters
 * @returns The type of the parameter, or 0 when it does not resolve
 *
 * @remarks
 * The type is resolved in the module that declared the generic, so `comptime n: T` works.
 *
 * @example
 * ```hx
 * // function fill<T>(comptime v: T): T, called as fill<u8>(3)
 * hxsComptimeParamType(c, fill, param, &names, &bound, 1); // u8
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsComptimeParamType(c: *Ctx, template: u32, paramNode: u32, names: readonly u32[*],
                                                   bound: readonly u32[*], count: u32): u32 {
    const savedModule = c.module;
    const savedParams = c.typeParams.len;
    c.module = symbolOf(c, template).module;
    for (const i of 0..count) {
        unsafe {
            pushTypeParam(c, hxsTokName(c, names[i]), bound[i]);
        }
    }
    const type = hxsResolveType(c, nodeOf(c, paramNode).a);
    c.typeParams.len = savedParams;
    c.module = savedModule;
    return type;
}

/**
 * Binds the type parameters that only a generic interface constraint mentions.
 *
 * @param c - The checker context
 * @param fn - The function data of the generic
 * @param template - The symbol of the generic function
 * @param names - The tokens of the type parameters
 * @param count - The number of type parameters
 * @param bound - The bound types, where 0 means not bound yet
 *
 * @remarks
 * In `<I extends Iterator<T>, T>`, `T` appears in no parameter,
 * but once `I` is known, the `next` method of `I` says what it is.
 * For each bound parameter whose constraint is a generic interface,
 * the interface's method signatures are matched against the type's methods to find the interface's arguments,
 * and those are matched against the arguments of the constraint.
 * The receiver is left out of the match, and methods with type parameters of their own are skipped.
 *
 * @example
 * ```hx
 * // function sum<I extends Iterator<T>, T>(it: *I): T, called with a *Counter whose next gives ?i32
 * hxsUnifyConstraints(c, &fn, sum, &names, 2, &bound);
 * bound[1]; // i32
 * ```
 *
 * @see hxsUnify
 * @since 1.0.0
 */

export extern "C" function hxsUnifyConstraints(c: *Ctx, fn: readonly *HxFnData, template: u32, names: readonly u32[*], count: u32,
                                                 bound: u32[*]): void {
    for (const i of 0..count) {
        const constraint = nodeOf(c, extraOf(c, fn.genericsStart + i)).a;
        let type: u32 = 0;
        unsafe {
            type = bound[i];
        }
        if (type == 0 || constraint == 0 || nodeOf(c, constraint).kind != NodeKind.GenericInstance || !hxsIsAggregate(c, type)) continue;
        const base = nodeOf(c, constraint).a;
        const savedModule = c.module;
        c.module = symbolOf(c, template).module;
        let sym: u32 = 0;
        if (nodeOf(c, base).kind == NodeKind.Ident) sym = hxsLookup(c, hxsTokName(c, nodeOf(c, base).token));
        else if (nodeOf(c, base).kind == NodeKind.FieldAccess) sym = hxsModuleMember(c, nodeOf(c, base).a, nodeOf(c, base).token, false);
        c.module = savedModule;
        if (sym == 0 || sym == 0xFFFF_FFFF || symbolOf(c, sym).kind != HxSymType as u8 || (symbolOf(c, sym).flags & (HxSymGeneric as u16)) == 0) continue;
        const decl = symbolOf(c, sym).decl;
        if (nodeOf(c, decl).kind != NodeKind.Interface) continue;

        const data = record<HxContainerData>(astOf(c), nodeOf(c, decl).a);
        const ifaceCount = data.genericsEnd - data.genericsStart;
        if (ifaceCount > MaxTypeArgs) continue;
        let ifaceNames: u32[16] = undefined;
        let ifaceBound: u32[16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        for (const k of 0..ifaceCount) ifaceNames[k] = nodeOf(c, extraOf(c, data.genericsStart + k)).token;
        for (const m of data.membersStart..data.membersEnd) {
            const mem = extraOf(c, m);
            if (nodeOf(c, mem).kind != NodeKind.Function) continue;
            const index = hxsFindMember(c, type, hxsTokName(c, nodeOf(c, mem).token));
            if (index < 0 || hxsMemberOf(c, type, index).kind != HxMemberMethod as u8) continue;
            const method = hxsMemberOf(c, type, index).symbol;
            if ((symbolOf(c, method).flags & (HxSymTemplateMethod as u16)) != 0) continue;
            const given = symbolOf(c, hxsMethodInstance(c, method, type, 0)).type;
            if (given == 0) continue;
            const sig = record<HxFnData>(astOf(c), nodeOf(c, mem).a);
            const g = typeOf(c, given);
            let p: u32 = 1;   // past the receiver
            while (p < sig.paramsEnd - sig.paramsStart && (p as u64) < g.len) {
                hxsUnify(c, nodeOf(c, extraOf(c, sig.paramsStart + p)).a, paramOf(c, g, p as u64), &ifaceNames, ifaceCount, &ifaceBound);
                p += 1;
            }
            hxsUnify(c, sig.returnType, g.child, &ifaceNames, ifaceCount, &ifaceBound);
        }
        const args = record<HxRange>(astOf(c), nodeOf(c, constraint).b);
        let k: u32 = 0;
        while (k < ifaceCount && k < args.end - args.start) {
            if (ifaceBound[k] != 0) hxsUnify(c, extraOf(c, args.start + k), ifaceBound[k], names, count, bound);
            k += 1;
        }
    }
}

/**
 * Finds the instance that a call to a generic function or method makes.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param template - The symbol of the generic function
 * @param explicitArgs - The node that gives the type arguments, as in `max<i64>(a, b)`, or 0 to infer them
 * @param namePtr - The name of the callee for messages
 * @param nameLen - The length of the name
 * @param owner - The type of the receiver for a method, or 0
 * @param skip - The number of leading parameters that have no argument in the list, such as the receiver
 * @returns The symbol of the instance, or 0 after reporting
 *
 * @remarks
 * Without explicit type arguments, each argument is checked and its type matched against its parameter,
 * then the interface constraints fill in what is left.
 * A call with the wrong number of arguments reports how many the function takes and how many it was given.
 * A type parameter that nothing binds reports that the checker can't infer it, with a hint to pass it explicitly.
 * A method also gets the type arguments of its owner, so `ArrayList<T>.map<U>` binds `T` and `U`.
 * Each `comptime` parameter takes a value known while compiling, converted to the parameter's type,
 * and each distinct value makes its own instance, like a type argument does.
 * An argument that is only known when the program runs reports that the parameter is a `comptime` parameter.
 * The other arguments end up converted to the parameter types of the instance.
 *
 * @example
 * ```hx
 * // max(1, 2)
 * hxsGenericCallInstance(c, node, max, 0, "max", 3, 0, 0); // the symbol of max<i64>
 * ```
 *
 * @see hxsCheckGenericCall
 * @since 1.0.0
 */

export extern "C" function hxsGenericCallInstance(c: *Ctx, node: u32, template: u32, explicitArgs: u32, namePtr: readonly u8[*],
                                                     nameLen: i32, owner: u32, skip: u32): u32 {
    let name: string = "";
    unsafe {
        name = namePtr[0..nameLen as usize];
    }
    const decl = symbolOf(c, template).decl;
    const fn = record<HxFnData>(astOf(c), nodeOf(c, decl).a);
    const count = fn.genericsEnd - fn.genericsStart;
    const paramCount = fn.paramsEnd - fn.paramsStart;
    if (count > MaxTypeArgs || paramCount > MaxTypeArgs * 3) {
        void errorNode(c, node, "too many type parameters");
        hxsCheckArgsUnknown(c, node);
        return 0;
    }
    // the owner's type arguments come first (`ArrayList<T>.map<U>` binds `T` and `U`), then the function's own
    let names: u32[80] = undefined;
    let bound: u32[80] = undefined;
    for (const i of 0..80) bound[i] = 0;
    let prefix: u32 = 0;
    const ownerInst = owner != 0 ? aggregateInstance(c, owner) : 0;
    if (ownerInst != 0) {
        const in = *instance(c, ownerInst);
        while (prefix < in.argsCount && prefix < MaxTypeArgs) {
            names[prefix] = instanceName(semaOf(c), in.argsStart + prefix);
            bound[prefix] = instanceArg(semaOf(c), in.argsStart + prefix);
            prefix += 1;
        }
    }
    let ownNames: u32[*] = undefined;
    let own: u32[*] = undefined;
    unsafe {
        ownNames = @ptrFromInt(u32[*], @intFromPtr(&names) + (prefix as usize) * 4);
        own = @ptrFromInt(u32[*], @intFromPtr(&bound) + (prefix as usize) * 4);
        for (const i of 0..count) ownNames[i] = nodeOf(c, extraOf(c, fn.genericsStart + i)).token;
    }

    const args = record<HxRange>(astOf(c), nodeOf(c, node).b);
    const argCount = args.end - args.start;
    if (argCount + skip != paramCount) {
        const want = paramCount - skip;
        void errorNode(c, node, `\`${name}\` takes ${want} argument${want == 1 ? "" : "s"}, but ${argCount} ${argCount == 1 ? "was" : "were"} given`);
        hxsCheckArgsUnknown(c, node);
        return 0;
    }

    if (explicitArgs != 0) {
        const given = record<HxRange>(astOf(c), nodeOf(c, explicitArgs).b);
        if (!hxsGenericArity(c, template, count, given.end - given.start, node)) {
            hxsCheckArgsUnknown(c, node);
            return 0;
        }
        unsafe {
            for (const i of 0..count) own[i] = hxsResolveType(c, extraOf(c, given.start + i));
        }
        for (const i of 0..argCount) void hxsCheckExpr(c, extraOf(c, args.start + i), 0);
    } else {
        for (const i of 0..argCount) {
            const t = hxsCheckExpr(c, extraOf(c, args.start + i), 0);
            hxsUnify(c, nodeOf(c, extraOf(c, fn.paramsStart + skip + i)).a, t, ownNames, count, own);
        }
        hxsUnifyConstraints(c, &fn, template, ownNames, count, own);
        for (const i of 0..count) {
            unsafe {
                if (own[i] != 0) continue;
                const diag = errorNode(c, node, `can't infer \`${tokenText(c, ownNames[i])}\` for \`${name}\``);
                hintf(c, diag, `pass it explicitly: \`${name}<i32>(...)\``);
            }
            return 0;
        }
    }
    const typeCount = prefix + count;
    for (const i of 0..count) {
        const constraint = nodeOf(c, extraOf(c, fn.genericsStart + i)).a;
        unsafe {
            if (own[i] == 0) return 0;
            if (constraint != 0 && !hxsCheckConstraint(c, constraint, own[i], node, symbolOf(c, template).module, &names, &bound, typeCount)) return 0;
        }
    }

    // `comptime` arguments: converted to the parameter's type and known now
    let total = typeCount;
    for (const i of 0..argCount) {
        const paramNode = extraOf(c, fn.paramsStart + skip + i);
        if ((nodeOf(c, paramNode).flags & FlagComptime) == 0) continue;
        const arg = extraOf(c, args.start + i);
        const type = hxsComptimeParamType(c, template, paramNode, &names, &bound, typeCount);
        if (type == 0 || !hxsCoerce(c, arg, type)) return 0;
        const v = hxsValueOf(c, arg);
        if (v == null || v.kind == HxValueUndefined as u8) {
            const diag = errorNode(c, arg, `\`${tokenText(c, nodeOf(c, paramNode).token)}\` is a \`comptime\` parameter, so its argument must be known while compiling`);
            hint(c, diag, "pass a constant, or compute it with `comptime f(...)`");
            return 0;
        }
        names[total] = nodeOf(c, paramNode).token;
        bound[total] = infoOf(c, arg).value;
        total += 1;
    }

    const inst = hxsInstantiateFunction(c, template, &names, &bound, total, typeCount, owner, node);
    if (inst == 0 || symbolOf(c, inst).type == 0) return 0;
    // the other arguments convert to the instance's parameter types, which leave the `comptime` ones out
    const ft = typeOf(c, symbolOf(c, inst).type);
    let runtime = skip;
    for (const i of 0..argCount) {
        if ((nodeOf(c, extraOf(c, fn.paramsStart + skip + i)).flags & FlagComptime) != 0) continue;
        if ((runtime as u64) < ft.len) void hxsCoerce(c, extraOf(c, args.start + i), paramOf(c, ft, runtime as u64));
        runtime += 1;
    }
    return inst;
}

/**
 * Checks a call to a generic function that is not a method.
 *
 * @param c - The checker context
 * @param node - The call node
 * @param template - The symbol of the generic function
 * @param explicitArgs - The node that gives the type arguments, or 0 to infer them
 * @param name - The name of the callee for messages
 * @param len - The length of the name
 * @returns The return type of the instance, or 0 after reporting
 *
 * @remarks
 * The call node records the instance as its symbol, which is the function that code generation calls.
 *
 * @example
 * ```hx
 * // max(1, 2)
 * hxsCheckGenericCall(c, node, max, 0, "max", 3); // i64
 * ```
 *
 * @see hxsGenericCallInstance
 * @since 1.0.0
 */

export extern "C" function hxsCheckGenericCall(c: *Ctx, node: u32, template: u32, explicitArgs: u32, name: readonly u8[*], len: i32): u32 {
    const inst = hxsGenericCallInstance(c, node, template, explicitArgs, name, len, 0, 0);
    if (inst == 0) return 0;
    infoOf(c, node).symbol = inst;
    return typeOf(c, symbolOf(c, inst).type).child;
}
