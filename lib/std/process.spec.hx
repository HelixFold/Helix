/**
 * Imports
 */

import { free } from "./heap";
import { Env, Init, Output, ProcessError, CaptureOptions, capture, captureAll, captureAllWith, run } from "./process";

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
        const output = Output { status: 4, stdout: [], stderr: [] };

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

describe("captureAll") {
    test("should keep what the program wrote to stdout apart from what it wrote to stderr") {
        const output = try captureAll(testing.allocator, ["sh", "-c", "printf out; printf err >&2; exit 3"]);
        const out: string = output.stdout;
        const err: string = output.stderr;

        expect(output.status).toBe(3);
        expect(out).toBe("out");
        expect(err).toBe("err");
        free(testing.allocator, output.stdout);
        free(testing.allocator, output.stderr);
    }

    test("should read a stream that fills its pipe while the other stays quiet") {
        const output = try captureAll(testing.allocator, ["sh", "-c", "head -c 200000 /dev/zero >&2"]);

        expect(output.status).toBe(0);
        expect(output.stdout.len).toBe(0);
        expect(output.stderr.len).toBe(200000);
        free(testing.allocator, output.stdout);
        free(testing.allocator, output.stderr);
    }

    test("should fail with CannotStart for a program that does not exist") {
        expect(captureAll(testing.allocator, ["/nonexistent/helix-process-spec"])).toThrow(ProcessError.CannotStart);
    }
}

describe("CaptureOptions") {
    test("should run the program as captureAll does when no field is given") {
        const options = CaptureOptions {};

        expect(options.dir.len).toBe(0);
        expect(options.timeout).toBe(0);
    }
}

describe("captureAllWith") {
    test("should start the program in the given folder") {
        const output = try captureAllWith(testing.allocator, ["pwd", "-P"], CaptureOptions { dir: "/" });
        const out: string = output.stdout;

        expect(out).toBe("/\n");
        free(testing.allocator, output.stdout);
        free(testing.allocator, output.stderr);
    }

    test("should kill a program that runs past its time and keep what it wrote") {
        const output = try captureAllWith(testing.allocator, ["sh", "-c", "echo early; sleep 10"], CaptureOptions { timeout: 200 });
        const out: string = output.stdout;

        expect(output.status).toBe(137);
        expect(out).toBe("early\n");
        free(testing.allocator, output.stdout);
        free(testing.allocator, output.stderr);
    }
}
