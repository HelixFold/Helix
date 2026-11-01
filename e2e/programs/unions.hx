// expect-stdout: click at 3,4
// expect-stdout: key 65 shift
// expect-stdout: resize ignored
// expect-stdout: resize 100x50
// expect-stdout: quit
// expect-stdout: clamped 100

extern "C" function printf(format: readonly u8[*], ...): i32;

struct Point { x: i32, y: i32 }

union Event {
    click: Point,
    key: struct { code: u32, shift: bool },
    resize: struct { w: u32, h: u32 },
    quit,
}

function handle(event: Event): bool {
    switch (event) {
        case Event.click(p):
            void printf("click at %d,%d\n", p.x, p.y);
        case Event.key({ code, shift }):
            void printf("key %u %s\n", code, shift ? "shift" : "plain");
        case Event.resize({ w, h }) if w == 0 || h == 0:
            void printf("resize ignored\n");
        case .resize(size):
            void printf("resize %ux%u\n", size.w, size.h);
        case .quit:
            void printf("quit\n");
            return false;
    }
    return true;
}

export function main(): void {
    void handle(Event.click(Point { x: 3, y: 4 }));
    void handle(Event.key({ code: 65, shift: true }));
    void handle(Event.resize({ w: 0, h: 10 }));
    void handle(.resize({ w: 100, h: 50 }));
    void handle(Event.quit);

    let event = Event.resize({ w: 10, h: 5 });
    switch (event) {
        case Event.resize(*r):
            if (r.w < 100) r.w = 100;
        default: {}
    }
    switch (event) {
        case .resize(r): void printf("clamped %u\n", r.w);
        default: {}
    }
}
