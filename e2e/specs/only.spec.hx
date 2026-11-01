// With any `.only`, only those tests (and everything in an `.only` block) run; the rest count as skipped.
// expect-tests: 3 skipped, 3 passed, 6 total

test("should be skipped") {
    expect(1).toBe(2);
}

test.only("should run") {
    expect(1).toBe(1);
}

describe.only("focused") {
    test("should run everything inside") {
        expect(2).toBe(2);
    }

    test.skip("should still honor skip") {
        expect(1).toBe(2);
    }
}

describe("other") {
    test("should be skipped") {
        expect(1).toBe(2);
    }

    test.only("should run when marked") {
        expect(3).toBe(3);
    }
}
