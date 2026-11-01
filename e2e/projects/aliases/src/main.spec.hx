import { area } from "@shapes/circle";

test("should reach a module through an alias") {
    expect(area(1)).toBe(3);
}
