// expect-error: switch on `Role` doesn't handle every case
// expect-error: switch on `i32` needs a `default` case
// expect-error: switch on `Shape` doesn't handle every case
// expect-error: `Role` has no member `Owner`

enum Role { Admin, Member, Guest }

union Shape {
    circle: f64,
    square: f64,
    empty,
}

function label(role: Role): i32 {
    return switch (role) {
        case Role.Admin: 1;
        case Role.Member: 2;
    };
}

function code(n: i32): i32 {
    return switch (n) {
        case 0: 1;
        case 1: 2;
    };
}

function area(shape: Shape): f64 {
    switch (shape) {
        case Shape.circle(r): return r * r;
        case .empty: return 0.0;
    }
    return 1.0;
}

export function main(): void {
    void label(Role.Owner);
    void code(1);
    void area(Shape.empty);
}
