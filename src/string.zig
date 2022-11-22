const std = @import("std");
const ascii = std.ascii;
const all = @import("function.zig").all;

fn isDigitOrPoint(x: u8) bool {
    return ascii.isDigit(x) or x == '.';
}

pub fn isMaybeNumberString(s: []const u8) bool {
    return all(u8, s, isDigitOrPoint);
}
