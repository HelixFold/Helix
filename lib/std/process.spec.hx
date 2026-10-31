/**
 * Imports
 */

import { free } from "./heap";
import { Env, Init, Output, ProcessError, capture, run } from "./process";

/**
 * Tests
 */

describe("Init") {
    test("should keep the program apart from its arguments") {
        const init = Init { program: "app", args: ["one", "two"], env: Env {} };

        expect(init.program).toBe("app");
        expect(init.args.len).toBe(2);
        expect(init.args[0]).toBe("one");
    }
}

describe("Env") {
    describe("get") {
        test("should return the value of a variable that is set") {
            const env = Env {};

            expect(env.get("PATH")).toBeDefined();
        }

        test("should return null for a variable that is not set") {
            const env = Env {};

            expect(env.get("HELIX_PROCESS_SPEC_SURELY_UNSET")).toBeNull();
        }

        test("should return null for a name with a NUL byte") {
            const env = Env {};

            expect(env.get("PATH\0")).toBeNull();
        }
    }
}

describe("ProcessError") {
    test("should name the failure to start a program") {
        const error: Error = ProcessError.CannotStart;

        expect(@errorName(error)).toBe("CannotStart");
    }
}

describe("run") {
    test("should return the exit status of the program") {
        expect(try run(["true"])).toBe(0);
        expect(try run(["false"])).toBe(1);
        expect(try run(["sh", "-c", "exit 3"])).toBe(3);
    }

    test("should return 128 plus the number of the signal that ended the program") {
        expect(try run(["sh", "-c", "kill -9 $$"])).toBe(137);
    }

    test("should fail with CannotStart for a program that does not exist") {
        expect(run(["/nonexistent/helix-process-spec"])).toThrow(ProcessError.CannotStart);
    }

    test("should fail with CannotStart for an empty command line") {
        expect(run([])).toThrow(ProcessError.CannotStart);
    }
}

describe("Output") {
    test("should hold the status and the bytes") {
        const output = Output { status: 4, stdout: [] };

        expect(output.status).toBe(4);
        expect(output.stdout.len).toBe(0);
    }
}

describe("capture") {
    test("should return everything that the program wrote to stdout") {
        const output = try capture(testing.allocator, ["printf", "a\\nb"]);
        const text: string = output.stdout;

        expect(output.status).toBe(0);
        expect(text).toBe("a\nb");
        free(testing.allocator, output.stdout);
    }

    test("should return the status of a program that fails") {
        const output = try capture(testing.allocator, ["sh", "-c", "printf partial; exit 5"]);
        const text: string = output.stdout;

        expect(output.status).toBe(5);
        expect(text).toBe("partial");
        free(testing.allocator, output.stdout);
    }

    test("should return no bytes for a program that writes nothing") {
        const output = try capture(testing.allocator, ["true"]);

        expect(output.stdout.len).toBe(0);
    }

    test("should fail with CannotStart for a program that does not exist") {
        expect(capture(testing.allocator, ["/nonexistent/helix-process-spec"])).toThrow(ProcessError.CannotStart);
    }
}
