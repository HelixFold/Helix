import { Build } from "std/build";

export function build(b: *Build): void | Error {
    const app = try b.addExecutable({ name: "cabi", root: "src/main.hx" });
    try app.addCSources({ files: ["c/shapes.c"] });
    try b.install(app);
    try b.addRunStep(app);
}
