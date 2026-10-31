/**
 * Imports
 */

import { hxAstInit } from "@models/ast.model";
import { NodeKind } from "@constants/ast.constant";
import { free } from "@components/memory.component";
import { HxAst } from "@models/structs/ast-model.struct";
import { HxSource } from "@models/structs/source-model.struct";
import { Sync } from "@modules/parser/constants/parser.constant";
import { TokenKind } from "@modules/lexer/constants/token.constant";
import { HxDiagList } from "@models/structs/diagnostic-model.struct";
import { atKind } from "@modules/parser/components/cursor.component";
import { HxTokens } from "@modules/lexer/structs/lexer-module.struct";
import { Parser } from "@modules/parser/structs/parser-module.struct";
import { recover } from "@modules/parser/components/report.component";
import { parseDeclaration } from "@modules/parser/components/declarations.component";
import { addNode, listFinish, scratchPush } from "@modules/parser/components/tree.component";

/**
 * Parses one file of a program into a tree.
 *
 * @param ast - The tree that receives the nodes, which may already hold other files
 * @param firstToken - The index of the first token of the file
 * @param diags - The list that receives the syntax errors
 * @param ok - The variable that is set to `false` after an error and left alone otherwise
 * @returns The index of the `File` node of the file
 *
 * @remarks
 * The parser reads up to the end-of-file token of the file, so each file of a program parses on its own.
 * It never stops at an error.
 * It reports the first error of each statement, skips to a point where it can resume,
 * and still returns a whole tree, with invalid nodes where a construct failed.
 *
 * @example
 * ```hx
 * let ok = true;
 * const file = hxParseModule(&ast, firstToken, &diags, &ok);
 * node(&ast, file).kind; // NodeKind.File
 * ```
 *
 * @see hxParse
 * @since 1.0.0
 */

export extern "C" function hxParseModule(ast: *HxAst, firstToken: u32, diags: *HxDiagList, ok: *bool): u32 {
    let p = Parser {
        src: ast.src, tokens: ast.tokens, ast, diags, pos: firstToken, depth: 0, panicking: false,
        scratch: null, scratchLen: 0, scratchCap: 0,
    };
    const errorsBefore = diags.errorCount;
    while (!atKind(&p, TokenKind.Eof)) {
        const before = p.pos;
        const decl = parseDeclaration(&p);
        if (decl != 0) scratchPush(&p, decl);
        recover(&p, Sync.Declaration, before);
    }
    const decls = listFinish(&p, 0);
    const file = addNode(&p, NodeKind.File, firstToken, decls.start, decls.end);
    unsafe {
        free(@ptrCast(?u8[*], p.scratch));
    }
    if (diags.errorCount != errorsBefore) *ok = false;
    return file;
}

/**
 * Parses a single-file program into a new tree.
 *
 * @param src - The source that the tokens point into
 * @param tokens - The tokens of the file
 * @param ast - The tree to set up and fill, whose previous contents are ignored
 * @param diags - The list that receives the syntax errors
 * @returns `true` when the file parsed without an error
 *
 * @remarks
 * The root of the tree is the `File` node of the file.
 * Release the tree with {@link hxAstFree}, whether or not parsing succeeded.
 *
 * @example
 * ```hx
 * let ast: HxAst = undefined;
 * hxParse(&src, &tokens, &ast, &diags); // true for 'const a = 1;'
 * node(&ast, ast.root).kind;            // NodeKind.File
 * hxAstFree(&ast);
 * ```
 *
 * @see hxParseModule
 * @since 1.0.0
 */

export extern "C" function hxParse(src: readonly *HxSource, tokens: readonly *HxTokens, ast: *HxAst, diags: *HxDiagList): bool {
    hxAstInit(ast, src, tokens);
    let ok = true;
    ast.root = hxParseModule(ast, 0, diags, &ok);
    return ok;
}
