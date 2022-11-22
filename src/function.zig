const std = @import("std");

pub fn all(
    comptime T: type,
    xs: []const T,
    comptime predFn: fn (x: T) bool,
) bool {
    for (xs) |x|
        if (!predFn(x)) return false;
    return true;
}

const testing = std.testing;

test "all digits" {
    const line = "12345";
    try testing.expect(all(u8, line, std.ascii.isDigit));
}

test "exist not digit" {
    const line = "12345a";
    try testing.expect(!all(u8, line, std.ascii.isDigit));
}

pub fn any(
    comptime T: type,
    xs: []const T,
    comptime predFn: fn (x: T) bool,
) bool {
    for (xs) |x|
        if (predFn(x)) return true;
    return false;
}

test "any digit" {
    const line = "abc1e";
    try testing.expect(any(u8, line, std.ascii.isDigit));
}

test "no digits" {
    const line = "abcde";
    try testing.expect(!any(u8, line, std.ascii.isDigit));
}
