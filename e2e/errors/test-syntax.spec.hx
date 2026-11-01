// expect-error: unknown `test` modifier
// expect-error: unknown `describe` modifier
// expect-error: a `test.todo` has no body
// expect-error: expected the test's name as a string
// expect-error: expected a test, a hook or a `let`/`const`
// expect-error: a hook takes a block, not arguments
// expect-error: expected test options

test.sometimes("a") {
}

describe.todo("b") {
}

test.todo("c") {
}

test(name) {
}

describe("d") {
    function helper(): void {}

    beforeEach() {
    }

    test("e", { retries: 2 }) {
    }
}
