import { Point } from "../geometry";

export struct Circle {
    center: Point,
    radius: i32,
}

export enum Kind { Round, Square }
