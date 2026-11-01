// expect-stdout: admin user user
// expect-stdout: values 1 2 4
// expect-stdout: same true different true
// expect-stdout: next member size 1

extern "C" function printf(format: readonly u8[*], ...): i32;

enum Role {
    Admin,
    Member,
    Guest,

    const DEFAULT = Role.Member;

    label(this: Role): readonly u8[*] {
        return switch (this) {
            case Role.Admin: "admin";
            case .Member, .Guest: "user";
        };
    }

    next(this: Role): Role {
        return switch (this) {
            case .Admin: .Member;
            case .Member: .Guest;
            case .Guest: .Admin;
        };
    }
}

enum Color: u8 { Red = 1, Green = 2, Blue = 4 }

export function main(): void {
    const admin = Role.Admin;
    const guest: Role = .Guest;
    void printf("%s %s %s\n", admin.label(), Role.DEFAULT.label(), guest.label());
    void printf("values %d %d %d\n", Color.Red as u8, Color.Green as u8, Color.Blue as u8);
    void printf("same %s different %s\n", admin == .Admin ? "true" : "false", admin != guest ? "true" : "false");
    const n = admin.next();
    void printf("next %s size %d\n", n == Role.Member ? "member" : "other", @sizeOf(Role));
}
