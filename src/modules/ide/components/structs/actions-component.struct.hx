/**
 * Imports
 */

import { Strings } from "@modules/driver/components/structs/os-component.struct";

/**
 * A ready-made command line that an editor runs for a Helix project.
 *
 * @remarks
 * Editors execute an action without knowing Helix.
 * Which command runs a project, where a debug build goes, which debugger and formatters to use,
 * and how tests report are all decided here, once, for VS Code, CLion, and every other client.
 * {@link writeAction} writes it as `{ "kind", "title", "cwd", "argv", "file"?, "name"? }`.
 *
 * - **run** - runs a program in a terminal
 * - **build** - runs `helix build`, whose errors are `error: ...` lines followed by ` --> file:line:col` lines
 * - **test** - runs `helix test ... --reporter`, and the client appends the reporter it wants, `json` or `teamcity`
 * - **debug** - runs `helix debug-launch <file>`, which prints the launch settings as JSON for the client to start
 *   the debug adapter with
 *
 * @example
 * ```hx
 * const a = buildAction("/p/src/main.hx");
 * a.kind; // 'build'
 * a.argv; // [ '/usr/local/bin/helix', 'build' ]
 * ```
 *
 * @see writeAction
 * @since 1.0.0
 */

export struct Action {
    /**
     * The kind of the action: `run`, `build`, `test`, or `debug`.
     *
     * @example
     * ```hx
     * runAction("/p/main.hx").kind; // 'run'
     * ```
     *
     * @since 1.0.0
     */

    kind: string,

    /**
     * The label that the editor shows for the action.
     *
     * @example
     * ```hx
     * debugAction("/p/main.hx").title; // 'Debug'
     * ```
     *
     * @since 1.0.0
     */

    title: string,

    /**
     * The folder that the command runs in, which is the project folder.
     *
     * @example
     * ```hx
     * runAction("/p/src/main.hx").cwd; // '/p'
     * ```
     *
     * @since 1.0.0
     */

    cwd: string,

    /**
     * The command line, starting with the path of the compiler.
     *
     * @example
     * ```hx
     * debugAction("/p/main.hx").argv; // [ '/usr/local/bin/helix', 'debug-launch', '/p/main.hx' ]
     * ```
     *
     * @since 1.0.0
     */

    argv: Strings,

    /**
     * The file or folder that a run, debug, or test action is about, or an empty string for none.
     *
     * @example
     * ```hx
     * buildAction("/p/main.hx").file; // ''
     * ```
     *
     * @since 1.0.0
     */

    file: string,

    /**
     * The names of the describe or test that the action runs, outermost first.
     *
     * @remarks
     * It stays empty for every action except one that runs a single describe or test.
     *
     * @example
     * ```hx
     * const names: string[2] = ["parser", "should read"];
     * testAction("/p/a.spec.hx", &names, false).name; // [ 'parser', 'should read' ]
     * ```
     *
     * @since 1.0.0
     */

    name: Strings,
}
