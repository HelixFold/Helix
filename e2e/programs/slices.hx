// expect-stdout: array 4: 10 20 30 40 sum 100
// expect-stdout: slice 2: 20 30
// expect-stdout: string 5: h-e-l-l-o
// expect-stdout: index 3 of 4
// expect-stdout: filled 0 1 4 9 16 25 36 49
// expect-stdout: inclusive slice: 2 3 4

extern "C" function printf(format: readonly u8[*], ...): i32;

function sum(values: readonly i32[]): i32 {
    let total: i32 = 0;
    for (const v of values) total += v;
    return total;
}

function fill(out: u64[]): void {
    for (const _, i of out) out[i] = i * i;
}

export function main(): void {
    let numbers: i32[4] = undefined;
    numbers[0] = 10;
    numbers[1] = 20;
    numbers[2] = 30;
    numbers[3] = 40;
    void printf("array %zu: %d %d %d %d sum %d\n", numbers.len, numbers[0], numbers[1], numbers[2], numbers[3],
                sum(&numbers));

    const middle = numbers[1..3];
    void printf("slice %zu: %d %d\n", middle.len, middle[0], middle[1]);

    const word: string = "hello";
    void printf("string %zu: ", word.len);
    for (const c, i of word) {
        if (i > 0) void printf("-");
        void printf("%c", c);
    }
    void printf("\n");

    for (const v, i of numbers) {
        if (v == 40) void printf("index %zu of %zu\n", i, numbers.len);
    }

    let squares: u64[8] = undefined;
    fill(&squares);
    void printf("filled");
    for (const s of squares) void printf(" %llu", s);
    void printf("\n");

    const digits: string = "012345";
    const part = digits[2..=4];
    void printf("inclusive slice: %c %c %c\n", part[0], part[1], part[2]);
}
