import { add } from "./main";

describe("add") {
    test("should add two numbers") {
        expect(add(2, 3)).toBe(5);
    }

    test("should add negative numbers") {
        expect(add(-4, 1)).toBe(-3);
    }

    test("should keep a number added to zero") {
        expect(add(0, 7)).toBe(7);
    }
}
