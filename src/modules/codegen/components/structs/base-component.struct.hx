/**
 * Imports
 */

import { HxSema, HxU32Vec } from "@structs/sema.struct";
import { HxAst } from "@models/structs/ast-model.struct";
import { HxTypes } from "@models/structs/types-model.struct";
import * as llvm from "@modules/codegen/bindings/llvm.binding";
import { HxArena } from "@services/structs/arena-service.struct";

/**
 * An LLVM value: an instruction, a constant, a function, or a global.
 *
 * @example
 * ```hx
 * const one: Value = constUsize(cg, 1); // i64 1
 * ```
 *
 * @since 1.0.0
 */

export type Value = llvm.LLVMValueRef;

/**
 * An LLVM type.
 *
 * @example
 * ```hx
 * const t: Type = lower(cg, cg.types.i32); // i32
 * ```
 *
 * @since 1.0.0
 */

export type Type = llvm.LLVMTypeRef;

/**
 * An LLVM basic block.
 *
 * @example
 * ```hx
 * const ok: Block = block(cg, "ok"); // %ok
 * ```
 *
 * @since 1.0.0
 */

export type Block = llvm.LLVMBasicBlockRef;

/**
 * An LLVM metadata node, which debug info is made of.
 *
 * @example
 * ```hx
 * const file: Meta = diFile(cg, 0); // !DIFile(...)
 * ```
 *
 * @since 1.0.0
 */

export type Meta = llvm.LLVMMetadataRef;

/**
 * The options of one code generation run: the build mode, the names, the debug info, and the target.
 *
 * @remarks
 * The driver fills them from the command line and the project file.
 * The struct has the C layout, since the code generator entry points take it from C callers too.
 *
 * @example
 * ```hx
 * const options = HxCodegenOptions {
 *     mode: ModeDebug, module_name: "main", debugInfo: true, triple: null, cpu: null, freestanding: false,
 * };
 * ```
 *
 * @since 1.0.0
 */

export extern "C" struct HxCodegenOptions {
    /**
     * The build mode, one of the four `MODE_` constants.
     *
     * @example
     * ```hx
     * options.mode; // ModeDebug
     * ```
     *
     * @see ModeDebug
     * @since 1.0.0
     */

    mode: u32,

    /**
     * The name of the module, which prefixes the names of its symbols.
     *
     * @example
     * ```hx
     * options.module_name; // "main", so add becomes @main.add
     * ```
     *
     * @since 1.0.0
     */

    module_name: readonly u8[*],

    /**
     * Whether to emit DWARF: line tables, functions, and variables for debuggers and stack traces.
     *
     * @example
     * ```hx
     * options.debugInfo; // true in a debug build
     * ```
     *
     * @since 1.0.0
     */

    debugInfo: bool,

    /**
     * The LLVM target triple, or null for the host, tuned for its CPU.
     *
     * @example
     * ```hx
     * options.triple; // "x86_64-unknown-linux-gnu"
     * ```
     *
     * @since 1.0.0
     */

    triple: ?readonly u8[*],

    /**
     * The CPU to generate for: `native`, `generic`, or an LLVM CPU name.
     *
     * @remarks
     * Null means the host's own CPU for a host build, and a generic one for another target.
     *
     * @example
     * ```hx
     * options.cpu; // "apple-m1"
     * ```
     *
     * @since 1.0.0
     */

    cpu: ?readonly u8[*],

    /**
     * Whether the target has no OS, as `<arch>-freestanding` targets do.
     *
     * @remarks
     * Nothing relocates such a program, so its code is static, and a linker script places it.
     *
     * @example
     * ```hx
     * options.freestanding; // true for thumbv7em-freestanding
     * ```
     *
     * @since 1.0.0
     */

    freestanding: bool,
}

/**
 * A loop that `break` and `continue` statements inside it can jump out of.
 *
 * @remarks
 * Statement code pushes one onto the loop stack of the generator for each loop body
 * and pops it when the body ends.
 *
 * @example
 * ```hx
 * cg.loops[cg.loopCount] = Loop { node, breakBlock: end, continueBlock: next, deferMark: cg.defers.len };
 * ```
 *
 * @see MaxLoops
 * @since 1.0.0
 */

export struct Loop {
    /**
     * The loop node, which the checker names as the target of a `break` or `continue`.
     *
     * @example
     * ```hx
     * loop.node; // the id of the while node
     * ```
     *
     * @since 1.0.0
     */

    node: u32,

    /**
     * The block that `break` jumps to, after the loop.
     *
     * @example
     * ```hx
     * loop.breakBlock; // %while.end
     * ```
     *
     * @since 1.0.0
     */

    breakBlock: Block,

    /**
     * The block that `continue` jumps to, which starts the next iteration.
     *
     * @example
     * ```hx
     * loop.continueBlock; // %while.cond
     * ```
     *
     * @since 1.0.0
     */

    continueBlock: Block,

    /**
     * The number of pending defers when the loop started.
     *
     * @remarks
     * A jump out of the loop runs the defers above this mark first.
     *
     * @example
     * ```hx
     * loop.deferMark; // 1 when one defer is pending outside the loop
     * ```
     *
     * @since 1.0.0
     */

    deferMark: u32,
}

/**
 * The state of the code generator, which lowers a checked program straight to LLVM IR.
 *
 * @remarks
 * The checker decided every type and conversion, and code generation only reads them and never derives a type again.
 * Locals live in allocas in the entry block, and LLVM's `mem2reg` turns them into registers when it optimizes.
 * A `defer` body is emitted again at every exit of its scope, in reverse order, so there is no bookkeeping at run time.
 *
 * Safety checks for overflow, bounds, division, casts, and shifts are on in debug and release-safe builds.
 * Each is a branch to a cold block that calls the panic handler with a message and location prepared at compile time.
 * Release-fast and release-small builds leave them out,
 * and the operations carry `nsw` or `nuw` so LLVM can optimize freely.
 *
 * @example
 * ```hx
 * let cg = make(sema, options);
 * if (buildModule(&cg, &error)) ir = llvm.LLVMPrintModuleToString(cg.mod);
 * dispose(&cg);
 * ```
 *
 * @see HxCodegenOptions
 * @since 1.0.0
 */

export struct Cg {
    /**
     * The checker's results for the program: symbols, node info, values, and aggregates.
     *
     * @example
     * ```hx
     * cg.sema.functions.len; // the number of functions to emit
     * ```
     *
     * @since 1.0.0
     */

    sema: readonly *HxSema,

    /**
     * The syntax tree of the program, with its tokens and source.
     *
     * @example
     * ```hx
     * cg.ast.root; // the id of the root node
     * ```
     *
     * @since 1.0.0
     */

    ast: readonly *HxAst,

    /**
     * The type table of the checker.
     *
     * @example
     * ```hx
     * cg.types.usize; // the type id of usize
     * ```
     *
     * @since 1.0.0
     */

    types: readonly *HxTypes,

    /**
     * The options of this run.
     *
     * @example
     * ```hx
     * cg.options.mode; // ModeDebug
     * ```
     *
     * @since 1.0.0
     */

    options: readonly *HxCodegenOptions,

    /**
     * Whether the build emits safety checks, which debug and release-safe builds do.
     *
     * @example
     * ```hx
     * cg.safe; // false in release-fast
     * ```
     *
     * @since 1.0.0
     */

    safe: bool,

    /**
     * Whether the target is arm64e, where function pointers are signed.
     *
     * @example
     * ```hx
     * cg.ptrauth; // true for arm64e-macos
     * ```
     *
     * @since 1.0.0
     */

    ptrauth: bool,

    /**
     * The arena for names and other short-lived text, freed with the generator.
     *
     * @example
     * ```hx
     * llvmName(cg, `${name}.thunk`); // allocated in cg.arena
     * ```
     *
     * @since 1.0.0
     */

    arena: HxArena,

    /**
     * The LLVM context that owns every type and constant.
     *
     * @example
     * ```hx
     * llvm.LLVMInt1TypeInContext(cg.ctx); // i1
     * ```
     *
     * @since 1.0.0
     */

    ctx: llvm.LLVMContextRef,

    /**
     * The LLVM module being built.
     *
     * @example
     * ```hx
     * llvm.LLVMPrintModuleToString(cg.mod); // the IR text
     * ```
     *
     * @since 1.0.0
     */

    mod: llvm.LLVMModuleRef,

    /**
     * The instruction builder, positioned where the next instruction goes.
     *
     * @example
     * ```hx
     * llvm.LLVMGetInsertBlock(cg.b); // the current block
     * ```
     *
     * @since 1.0.0
     */

    b: llvm.LLVMBuilderRef,

    /**
     * The LLVM target machine, which writes the object file.
     *
     * @example
     * ```hx
     * llvm.LLVMCreateTargetDataLayout(cg.machine); // the data layout of the target
     * ```
     *
     * @since 1.0.0
     */

    machine: llvm.LLVMTargetMachineRef,

    /**
     * The data layout of the target, for sizes, alignments, and field offsets.
     *
     * @example
     * ```hx
     * llvm.LLVMABISizeOfType(cg.layout, lower(cg, cg.types.i32)); // 4
     * ```
     *
     * @since 1.0.0
     */

    layout: llvm.LLVMTargetDataRef,

    /**
     * The storage of each symbol by symbol id: its alloca, its global, or its function.
     *
     * @example
     * ```hx
     * cg.storage[sym]; // @main.add
     * ```
     *
     * @since 1.0.0
     */

    storage: Value[],

    /**
     * The LLVM type of each type id, which {@link lower} fills.
     *
     * @example
     * ```hx
     * cg.typeCache[cg.types.i32]; // i32 once lowered, null before
     * ```
     *
     * @since 1.0.0
     */

    typeCache: Type[],

    /**
     * The private string constant of each value index, created on first use.
     *
     * @example
     * ```hx
     * cg.stringGlobals[index]; // @str
     * ```
     *
     * @since 1.0.0
     */

    stringGlobals: Value[],

    /**
     * The `{ ptr, usize }` type of every slice and string.
     *
     * @example
     * ```hx
     * cg.sliceType; // { ptr, i64 }
     * ```
     *
     * @since 1.0.0
     */

    sliceType: Type,

    /**
     * The opaque pointer type.
     *
     * @example
     * ```hx
     * cg.ptrType; // ptr
     * ```
     *
     * @since 1.0.0
     */

    ptrType: Type,

    /**
     * The `usize` type, which is `i64`, or `i32` on 32-bit targets.
     *
     * @example
     * ```hx
     * cg.usizeType; // i64
     * ```
     *
     * @since 1.0.0
     */

    usizeType: Type,

    /**
     * The `{ data pointer, vtable pointer }` type of a `dyn` value.
     *
     * @example
     * ```hx
     * cg.dynType; // { ptr, ptr }
     * ```
     *
     * @since 1.0.0
     */

    dynType: Type,

    /**
     * The vtable of each impl by impl index, built on first use.
     *
     * @example
     * ```hx
     * cg.vtables[index - 1]; // the vtable global of the impl
     * ```
     *
     * @since 1.0.0
     */

    vtables: Value[],

    /**
     * The function being emitted.
     *
     * @example
     * ```hx
     * block(cg, "ok"); // appended to cg.fn
     * ```
     *
     * @since 1.0.0
     */

    fn: Value,

    /**
     * The generic instance being emitted as its index plus 1, or 0 outside one.
     *
     * @example
     * ```hx
     * cg.instance; // 0 in a function that is not generic
     * ```
     *
     * @since 1.0.0
     */

    instance: u32,

    /**
     * The result type of the function being emitted.
     *
     * @example
     * ```hx
     * cg.returnType; // the type id of i32 in function f(): i32
     * ```
     *
     * @since 1.0.0
     */

    returnType: u32,

    /**
     * The entry block of the function being emitted, where {@link entryAlloca} places the stack slots.
     *
     * @example
     * ```hx
     * cg.entryBlock; // %entry
     * ```
     *
     * @since 1.0.0
     */

    entryBlock: Block,

    /**
     * The `defer` and `errdefer` nodes in scope, innermost last.
     *
     * @remarks
     * A scope remembers the length when it starts and cuts the list back to it when it ends.
     *
     * @example
     * ```hx
     * cg.defers.len; // 2 inside two nested defers
     * ```
     *
     * @since 1.0.0
     */

    defers: HxU32Vec,

    /**
     * The stack of loops that the current statement is inside, innermost last.
     *
     * @example
     * ```hx
     * cg.loops[cg.loopCount - 1]; // the innermost loop
     * ```
     *
     * @see MaxLoops
     * @since 1.0.0
     */

    loops: Loop[64],

    /**
     * The number of loops on the loop stack.
     *
     * @example
     * ```hx
     * cg.loopCount; // 0 outside every loop
     * ```
     *
     * @since 1.0.0
     */

    loopCount: u32,

    /**
     * The `helix.panic` handler, or null until the first panic needs it.
     *
     * @example
     * ```hx
     * buildPanicHandler(cg);
     * cg.panicFn; // @helix.panic
     * ```
     *
     * @since 1.0.0
     */

    panicFn: Value,

    /**
     * The function type of `helix.panic`.
     *
     * @example
     * ```hx
     * cg.panicFnType; // void (ptr, i64, ptr)
     * ```
     *
     * @since 1.0.0
     */

    panicFnType: Type,

    /**
     * The `helix.panic_bounds` handler, or null until the first bounds check needs it.
     *
     * @example
     * ```hx
     * cg.panicBoundsFn; // @helix.panic_bounds
     * ```
     *
     * @since 1.0.0
     */

    panicBoundsFn: Value,

    /**
     * The function type of `helix.panic_bounds`.
     *
     * @example
     * ```hx
     * cg.panicBoundsFnType; // void (ptr, i64, i64)
     * ```
     *
     * @since 1.0.0
     */

    panicBoundsFnType: Type,

    /**
     * The global table from error code to error name, built on first use.
     *
     * @example
     * ```hx
     * cg.errorNames; // @helix.errorNames
     * ```
     *
     * @since 1.0.0
     */

    errorNames: Value,

    /**
     * The generated formatting function of each type, quoted and not.
     *
     * @remarks
     * The key is the type id times 2, plus 1 for the quoted form.
     *
     * @example
     * ```hx
     * cg.printFns[type * 2 + 1]; // the quoted formatter of the type
     * ```
     *
     * @since 1.0.0
     */

    printFns: Value[],

    /**
     * The generated `toEqual` comparison of each type.
     *
     * @example
     * ```hx
     * cg.equalFns[type]; // the comparison function of the type
     * ```
     *
     * @since 1.0.0
     */

    equalFns: Value[],

    /**
     * Whether each symbol is an `extern "C"` function whose structs follow the C ABI.
     *
     * @example
     * ```hx
     * cg.cAbi[sym]; // true for an extern "C" declaration without a body
     * ```
     *
     * @since 1.0.0
     */

    cAbi: bool[],

    /**
     * The `extern "C"` functions with a body that need a C ABI entry point.
     *
     * @example
     * ```hx
     * cg.cWrappers.len; // 1 for one exported C function that takes a struct
     * ```
     *
     * @since 1.0.0
     */

    cWrappers: HxU32Vec,

    /**
     * The debug info builder, or null when debug info is off.
     *
     * @example
     * ```hx
     * cg.di; // null in a build without debug info
     * ```
     *
     * @since 1.0.0
     */

    di: llvm.LLVMDIBuilderRef,

    /**
     * The DWARF compile unit of the module.
     *
     * @example
     * ```hx
     * cg.diUnit; // !DICompileUnit(producer: "helix ...", ...)
     * ```
     *
     * @since 1.0.0
     */

    diUnit: Meta,

    /**
     * The DWARF file of each source file, created on first use.
     *
     * @example
     * ```hx
     * cg.diFiles[0]; // !DIFile(filename: "main.hx", ...)
     * ```
     *
     * @since 1.0.0
     */

    diFiles: Meta[],

    /**
     * The DWARF type of each type id, which {@link diType} fills.
     *
     * @example
     * ```hx
     * cg.diTypes[cg.types.i32]; // the typedef named i32
     * ```
     *
     * @since 1.0.0
     */

    diTypes: Meta[],

    /**
     * The DWARF subprogram of the current function, or null outside a Helix function.
     *
     * @example
     * ```hx
     * cg.diScope; // null inside a generated helper
     * ```
     *
     * @since 1.0.0
     */

    diScope: Meta,
}

/**
 * Where the builder was, saved while code generation builds a helper function.
 *
 * @remarks
 * {@link detourBegin} gives a helper its own builder, so the position in the function being emitted survives untouched.
 * It holds no ownership, and {@link detourEnd} disposes of the helper's builder before it restores these fields.
 *
 * @example
 * ```hx
 * const saved: Detour = detourBegin(cg, helper);
 * detourEnd(cg, saved);
 * ```
 *
 * @see detourBegin
 * @since 1.0.0
 */

export struct Detour {
    /**
     * The builder to go back to.
     *
     * @example
     * ```hx
     * saved.b; // the builder of the function being emitted
     * ```
     *
     * @since 1.0.0
     */

    b: llvm.LLVMBuilderRef,

    /**
     * The function to go back to.
     *
     * @example
     * ```hx
     * saved.fn; // @main.main
     * ```
     *
     * @since 1.0.0
     */

    fn: Value,

    /**
     * The entry block to go back to.
     *
     * @example
     * ```hx
     * saved.entry; // %entry of the function being emitted
     * ```
     *
     * @since 1.0.0
     */

    entry: Block,
}
