import { Build, Mode } from "std/build";

export function build(b: *Build): void | Error {
    const config = try b.addOptions("config");
    try config.addString("greeting", b.optionString("greeting", "What greet says") ?? "hello");
    const greet = try b.bin("greet");
    try greet.addOptions(config);

    // the same program for other targets is a new artifact, installed into a folder of its own
    const release = try b.step("release", "greet for Windows and Linux");
    const targets: string[2] = ["x86_64-windows", "x86_64-linux"];
    for (const target of targets) {
        const exe = try b.addExecutable({ name: "greet", root: "src/main.hx", target, mode: Mode.ReleaseSafe });
        try exe.addOptions(config);
        try release.dependOn(try b.addInstall(exe, target));
    }
    const listed = try b.addSystemCommand(["ls", ".helix-out/x86_64-windows", ".helix-out/x86_64-linux"]);
    try listed.dependOn(release);
    try (try b.step("release-ls", "release, then list it")).dependOn(listed);
}
