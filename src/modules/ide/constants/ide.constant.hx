/**
 * The seconds of quiet after a change before the server rebuilds the stale summaries.
 *
 * @remarks
 * Each change restarts the wait, so the summaries are rebuilt once typing pauses, not at every key.
 *
 * @example
 * ```hx
 * Debounce; // 0.2
 * ```
 *
 * @since 1.0.0
 */

export const Debounce: f64 = 0.2;

/**
 * The section of a summary that holds the diagnostics, as JSON.
 *
 * @remarks
 * Each document keeps its summary, which {@link writeSummary} produces, as {@link Sections} strings in a row:
 * JSON for diagnostics, tokens, symbols, lenses, and tests, then the files that the compile read.
 *
 * @example
 * ```hx
 * section(doc, Diagnostics); // '[{"uri":"file:///p/main.hx","diagnostics":[]}]'
 * ```
 *
 * @see Sections
 * @since 1.0.0
 */

export const Diagnostics: usize = 0;

/**
 * The section of a summary that holds the semantic tokens, as JSON.
 *
 * @example
 * ```hx
 * section(doc, Tokens); // '{"data":[0,0,6,12,0]}'
 * ```
 *
 * @since 1.0.0
 */

export const Tokens: usize = 1;

/**
 * The section of a summary that holds the outline, as JSON.
 *
 * @example
 * ```hx
 * section(doc, Symbols); // '[{"name":"main","kind":12,...}]'
 * ```
 *
 * @since 1.0.0
 */

export const Symbols: usize = 2;

/**
 * The section of a summary that holds the code lenses, as JSON.
 *
 * @example
 * ```hx
 * section(doc, Lenses); // '[]' for a file without a main or tests
 * ```
 *
 * @since 1.0.0
 */

export const Lenses: usize = 3;

/**
 * The section of a summary that holds the test tree, as JSON.
 *
 * @example
 * ```hx
 * section(doc, Tests); // '{"action":{...},"children":[]}'
 * ```
 *
 * @since 1.0.0
 */

export const Tests: usize = 4;

/**
 * The section of a summary that holds the real paths of the files that the compile read, one per line.
 *
 * @remarks
 * It is an empty string while the summary is stale.
 *
 * @example
 * ```hx
 * section(doc, Files); // '/p/main.hx\n/p/util.hx\n'
 * ```
 *
 * @since 1.0.0
 */

export const Files: usize = 5;

/**
 * The number of sections in the summary of a document.
 *
 * @example
 * ```hx
 * sections.items[doc * Sections + Files]; // the files section of document doc
 * ```
 *
 * @see Diagnostics
 * @since 1.0.0
 */

export const Sections: usize = 6;

/**
 * The question that asks a child for the summary of a document.
 *
 * @example
 * ```hx
 * ask(AskSummary, doc, Pos { line: 0, character: 0 }); // the sections, separated by NUL
 * ```
 *
 * @since 1.0.0
 */

export const AskSummary: u32 = 0;

/**
 * The question that asks a child where the name at a position is declared.
 *
 * @example
 * ```hx
 * ask(AskDefinition, doc, pos); // '{"uri":"file:///p/util.hx","range":{...}}'
 * ```
 *
 * @since 1.0.0
 */

export const AskDefinition: u32 = 1;

/**
 * The question that asks a child for the hover text at a position.
 *
 * @example
 * ```hx
 * ask(AskHover, doc, pos); // '{"contents":{"kind":"markdown",...},"range":{...}}'
 * ```
 *
 * @since 1.0.0
 */

export const AskHover: u32 = 2;

/**
 * The answer of {@link summarySection} for a request that no section of a summary answers.
 *
 * @remarks
 * Such a request needs a cursor, or the server does not handle it.
 *
 * @example
 * ```hx
 * summarySection("textDocument/hover"); // None
 * ```
 *
 * @since 1.0.0
 */

export const None: usize = 99;
