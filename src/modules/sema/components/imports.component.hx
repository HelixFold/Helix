/**
 * Imports
 */

import { record } from "@models/ast.model";
import { HxScopeExported } from "@constants/sema.constant";
import { HxImportData } from "@models/structs/ast-model.struct";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { hxsScopeInsert } from "@modules/sema/components/scope.component";
import { Ctx, HxSema, HxScopeEntry, HxModule } from "@structs/sema.struct";
import { extraOf, tokenText } from "@modules/sema/components/base.component";
import { NodeKind, FlagExport, FlagNamespace, NoToken } from "@constants/ast.constant";
import { HxSymResolved, HxSymModule, HxSymUsed, HxScopeImported, HxScopeUsed } from "@constants/sema.constant";
import { hxsReportRedeclared, hxsLookup, hxsAddSymbol, hxsScopeFind } from "@modules/sema/components/scope.component";
import { errorToken, hint, hxsTokName, semaOf, astOf, nodeOf, symbolOf } from "@modules/sema/components/base.component";

/**
 * Views the scope table of the checker as an array of entries.
 *
 * @param s - The checker state that owns the table
 * @returns The entries, `scopesCap` of them
 *
 * @remarks
 * The scope table is a hash table, so some entries are empty, and the caller must stay below `scopesCap`.
 *
 * @since 1.0.0
 */

function entries(s: readonly *HxSema): HxScopeEntry[*] {
    unsafe {
        return @ptrCast(HxScopeEntry[*], s.scopes);
    }
}

/**
 * Finds the file node of a module in the program.
 *
 * @param s - The checker state, which must have a program
 * @param module - The index of the module
 * @returns The node of the parsed file, whose children are the module's declarations
 *
 * @remarks
 * It reads the program without a check, so calling it while the checker has no program is an error in the caller.
 *
 * @example
 * ```hx
 * const file = nodeOf(c, moduleRoot(s, 0)); // the file node of the first module
 * ```
 *
 * @since 1.0.0
 */

export function moduleRoot(s: readonly *HxSema, module: u32): u32 {
    unsafe {
        return @ptrCast(HxModule[*], s.program!.modules)[module].root;
    }
}

/**
 * Gives the quoted path of an import for an error message.
 *
 * @param c - The checker context
 * @param node - The import node
 * @returns The path token's text with its quotes, or `""` when the import has no path
 *
 * @remarks
 * The text keeps its quotes, so the message can show the path exactly as the source wrote it.
 *
 * @since 1.0.0
 */

function importPath(c: *Ctx, node: u32): string {
    const data = record<HxImportData>(astOf(c), nodeOf(c, node).a);
    return data.pathToken != NoToken ? tokenText(c, data.pathToken) : "\"\"";
}

/**
 * Binds a name in the current module to a symbol from another module.
 *
 * @param c - The checker context
 * @param name - The interned name to bind
 * @param symbol - The symbol the name stands for
 * @param token - The token of the name in the import
 * @param reexport - Whether the import also exports the name, as `export { a } from` does
 * @returns `true` when the name is bound, or `false` when the module already uses it for something else
 *
 * @remarks
 * Binding the same symbol under the same name twice is allowed and changes nothing.
 * A name that the module already uses for another symbol is reported as redeclared.
 * The entry is marked as imported, and a re-export also marks it as exported and as used,
 * so the unused import check leaves it alone.
 *
 * @example
 * ```hx
 * hxsBindImport(c, name, found.symbol, token, false); // true
 * ```
 *
 * @see hxsProcessImport
 * @since 1.0.0
 */

export extern "C" function hxsBindImport(c: *Ctx, name: u32, symbol: u32, token: u32, reexport: bool): bool {
    if (const existing = hxsScopeFind(semaOf(c), c.module, name)) {
        if (existing.symbol == symbol) return true;   // the same thing imported twice
        hxsReportRedeclared(c, token, existing.symbol);
        return false;
    }
    const entry = hxsScopeInsert(semaOf(c), c.module, name);
    entry.symbol = symbol;
    entry.token = token;
    entry.flags = (HxScopeImported | (reexport ? HxScopeExported | HxScopeUsed : 0)) as u8;
    return true;
}

/**
 * Binds the names of one import declaration.
 *
 * @param c - The checker context
 * @param node - The import node
 * @param report - Whether to report names that the target module does not export
 * @returns `true` when the import bound anything new
 *
 * @remarks
 * It handles `import { a, b as c } from "..."`, `import * as ns from "..."`, and the matching `export ... from` forms.
 * The driver maps each import node to its target module, and an import without one is skipped,
 * since the driver already reported the missing file.
 * `import * as ns` adds a module symbol named `ns`, and `export * from` binds every name that the target exports.
 * A name that the target does not export is only reported when `report` is set,
 * since a re-export through another module may still bring it in on a later pass.
 * When the name exists in the target but is private, the hint says to add `export` to its declaration.
 *
 * @example
 * ```hx
 * // import { a } from "./b";
 * hxsProcessImport(c, node, false); // true the first time, false once a is bound
 * ```
 *
 * @see hxsProcessImports
 * @since 1.0.0
 */

export extern "C" function hxsProcessImport(c: *Ctx, node: u32, report: bool): bool {
    const n = nodeOf(c, node);
    const s = semaOf(c);
    let target: u32 = 0;
    if (const program = s.program) {
        if (const targets = program.importTargets) {
            unsafe {
                target = targets[node];
            }
        }
    }
    if (target == 0) return false;   // the driver already reported a missing file
    target -= 1;
    const data = record<HxImportData>(astOf(c), n.a);
    const reexport = (n.flags & FlagExport) != 0;
    let changed = false;

    if ((n.flags & FlagNamespace) != 0) {
        if (reexport) {   // `export * from "...";`: everything the target exports
            let i: u32 = 0;
            while (i < s.scopesCap) {   // binding can grow the table, so its size is read on every step
                let entry: HxScopeEntry = undefined;
                unsafe {
                    entry = entries(s)[i];
                }
                i += 1;
                if (entry.key == 0 || (entry.key >> 32) != (target as u64) + 1 || (entry.flags & (HxScopeExported as u8)) == 0) continue;
                const name = @truncate(u32, entry.key);
                if (hxsScopeFind(s, c.module, name) != null) continue;
                void hxsBindImport(c, name, entry.symbol, entry.token, true);
                changed = true;
            }
            return changed;
        }
        if (data.aliasToken == NoToken || hxsScopeFind(s, c.module, hxsTokName(c, data.aliasToken)) != null) return false;
        const sym = hxsAddSymbol(c, HxSymModule, data.aliasToken, node, 0);
        symbolOf(c, sym).targetModule = target;
        symbolOf(c, sym).flags |= HxSymResolved as u16;
        void hxsBindImport(c, hxsTokName(c, data.aliasToken), sym, data.aliasToken, false);
        return true;
    }

    for (const i of data.specsStart..data.specsEnd) {
        const spec = nodeOf(c, extraOf(c, i));
        const local = spec.a != NoToken ? spec.a : spec.token;
        const found = hxsScopeFind(s, target, hxsTokName(c, spec.token));
        const exported = found != null && (found.flags & (HxScopeExported as u8)) != 0;
        if (exported) {
            const existing = hxsScopeFind(s, c.module, hxsTokName(c, local));
            if (existing != null && existing.symbol == found!.symbol) continue;
            void hxsBindImport(c, hxsTokName(c, local), found!.symbol, local, reexport);
            changed = true;
        } else if (report) {
            const diag = errorToken(c, spec.token, `${importPath(c, node)} has no export named \`${tokenText(c, spec.token)}\``);
            if (found != null) hint(c, diag, "it exists but is private; add `export` to its declaration");
        }
    }
    return changed;
}

/**
 * Binds the imports of every module in the program.
 *
 * @param c - The checker context
 *
 * @remarks
 * Re-exports can chain through several modules, so the imports of every module run again
 * until a pass binds nothing new, with at most two more passes than there are modules.
 * A last pass then reports the names that are still missing.
 * A single-file check has no program, so this does nothing there.
 *
 * @example
 * ```hx
 * hxsProcessImports(c); // every import is bound or reported
 * ```
 *
 * @see hxsProcessImport
 * @since 1.0.0
 */

export extern "C" function hxsProcessImports(c: *Ctx): void {
    const s = semaOf(c);
    if (s.program == null) return;
    const count = s.program!.count;
    for (const _ of 0..count + 2) {
        let changed = false;
        for (const m of 0..count) {
            c.module = m;
            const file = nodeOf(c, moduleRoot(s, m));
            for (const i of file.a..file.b) {
                if (nodeOf(c, extraOf(c, i)).kind == NodeKind.Import) changed = hxsProcessImport(c, extraOf(c, i), false) || changed;
            }
        }
        if (!changed) break;
    }
    for (const m of 0..count) {   // what's still missing really is missing
        c.module = m;
        const file = nodeOf(c, moduleRoot(s, m));
        for (const i of file.a..file.b) {
            if (nodeOf(c, extraOf(c, i)).kind == NodeKind.Import) void hxsProcessImport(c, extraOf(c, i), true);
        }
    }
    c.module = 0;
}

/**
 * Checks whether a module mentions a name anywhere besides the import itself.
 *
 * @param c - The checker context
 * @param module - The index of the module
 * @param name - The interned name
 * @param importToken - The token of the name in the import, which does not count
 * @returns `true` when another identifier token of the module has the name
 *
 * @remarks
 * The checker only checks code inside a generic when something instantiates it,
 * so an import used only there never gets marked as used.
 * The tokens of the module are the reliable place to look.
 *
 * @example
 * ```hx
 * hxsModuleMentions(c, 0, name, token); // true when the module uses the name
 * ```
 *
 * @see hxsReportUnusedImports
 * @since 1.0.0
 */

export extern "C" function hxsModuleMentions(c: *Ctx, module: u32, name: u32, importToken: u32): bool {
    let t = nodeOf(c, moduleRoot(semaOf(c), module)).token;
    unsafe {
        const kinds = c.tokens!.kinds!;
        while (kinds[t] != TokenKind.Eof as u8) {
            if (t != importToken && kinds[t] == TokenKind.Ident as u8 && hxsTokName(c, t) == name) return true;
            t += 1;
        }
    }
    return false;
}

/**
 * Reports every imported name that its module never uses.
 *
 * @param c - The checker context
 *
 * @remarks
 * An imported entry that the lookups never marked as used is reported with a hint to remove it,
 * unless {@link hxsModuleMentions} finds the name elsewhere in the module.
 * A single-file check has no program, so this does nothing there.
 *
 * @example
 * ```hx
 * // import { a } from "./b";   a is never used
 * hxsReportUnusedImports(c); // error: unused import `a`
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsReportUnusedImports(c: *Ctx): void {
    const s = semaOf(c);
    if (s.program == null) return;
    for (const i of 0..s.scopesCap) {
        let entry: HxScopeEntry = undefined;
        unsafe {
            entry = entries(s)[i];
        }
        if (entry.key == 0 || (entry.flags & (HxScopeImported as u8)) == 0 || (entry.flags & (HxScopeUsed as u8)) != 0) continue;
        const module = @truncate(u32, entry.key >> 32) - 1;
        if (hxsModuleMentions(c, module, @truncate(u32, entry.key), entry.token)) continue;
        const diag = errorToken(c, entry.token, `unused import \`${tokenText(c, entry.token)}\``);
        hint(c, diag, "remove it");
    }
}

/**
 * Resolves `ns.name`, where `ns` is a namespace import.
 *
 * @param c - The checker context
 * @param base - The node on the left of the dot
 * @param nameToken - The token of the name on the right
 * @param report - Whether to report a name that the module does not export
 * @returns The exported symbol, 0 when `base` is not a namespace,
 * or `0xFFFFFFFF` when it is one but has no such export
 *
 * @remarks
 * A hit marks the namespace symbol as used.
 * When the name exists in the module but is private, the hint says to add `export` to its declaration.
 * The `0xFFFFFFFF` result tells the caller that the access is already settled, reported or not,
 * so it must not go on to treat `ns` as a value.
 *
 * @example
 * ```hx
 * // import * as ns from "./b";   ns.f()
 * hxsModuleMember(c, base, token, true); // the symbol of f
 * ```
 *
 * @since 1.0.0
 */

export extern "C" function hxsModuleMember(c: *Ctx, base: u32, nameToken: u32, report: bool): u32 {
    if (nodeOf(c, base).kind != NodeKind.Ident) return 0;
    const ns = hxsLookup(c, hxsTokName(c, nodeOf(c, base).token));
    if (ns == 0 || symbolOf(c, ns).kind != HxSymModule as u8) return 0;
    symbolOf(c, ns).flags |= HxSymUsed as u16;
    const found = hxsScopeFind(semaOf(c), symbolOf(c, ns).targetModule, hxsTokName(c, nameToken));
    if (found != null && (found.flags & (HxScopeExported as u8)) != 0) return found.symbol;
    if (report) {
        const diag = errorToken(c, nameToken, `\`${tokenText(c, nodeOf(c, base).token)}\` has no export named \`${tokenText(c, nameToken)}\``);
        if (found != null) hint(c, diag, "it exists but is private; add `export` to its declaration");
    }
    return 0xFFFF_FFFF;   // a module, but no such export: already reported
}
