/**
 * Imports
 */

import { cmdLsp } from "@modules/ide/ide.module";

/**
 * Tests
 */

describe("cmdLsp") {
    test("should fail to answer from a question file that cannot be read") {
        expect(cmdLsp("/nonexistent/helix-lsp-spec.question")).toBe(1);
    }
}
