const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const log = std.log;
const isMaybeNumberString = @import("string.zig").isMaybeNumberString;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

pub const FieldIteratorError = error{
    QuoteUnbalanced,
    QuoteInTheMiddle,
};

pub const Value = union(enum) {
    /// Empty field.
    Null,
    String: []const u8,
    Int: i64,
    Float: f64,
};

pub const FieldValue = struct {
    allocator: Allocator,
    value: Value,

    /// As `Value.String`.
    pub fn string(allocator: Allocator, raw: []const u8) !FieldValue {
        const x = try canonicalizeField(allocator, raw);
        return .{
            .allocator = allocator,
            .value = .{ .String = x },
        };
    }

    /// As proper `Value`.
    pub fn parse(allocator: Allocator, raw: []const u8) !FieldValue {
        if (raw.len == 0) return .{
            .allocator = allocator,
            .value = .Null,
        };
        const s = parseString(allocator, raw) catch null;
        if (s) |x| return .{
            .allocator = allocator,
            .value = .{ .String = x },
        };
        return parseValue(allocator, raw);
    }

    fn parseValue(allocator: Allocator, raw: []const u8) !FieldValue {
        if (parseInt(raw)) |x| return .{
            .allocator = allocator,
            .value = .{ .Int = x },
        };
        if (parseFloat(raw)) |x| return .{
            .allocator = allocator,
            .value = .{ .Float = x },
        };
        // fallback to string
        const s = try parseString(allocator, raw);
        return .{
            .allocator = allocator,
            .value = .{ .String = s.? },
        };
    }

    fn parseInt(raw: []const u8) ?i64 {
        return fmt.parseInt(i64, raw, 10) catch null;
    }

    fn parseFloat(raw: []const u8) ?f64 {
        return fmt.parseFloat(f64, raw) catch null;
    }

    fn parseString(allocator: Allocator, raw: []const u8) !?[]const u8 {
        const x = try canonicalizeField(allocator, raw);
        if (isMaybeNumberString(x)) { // may be parsed as a number
            defer allocator.free(x);
            return null;
        }
        return x;
    }

    pub fn deinit(self: FieldValue) void {
        switch (self.value) {
            .String => |x| self.allocator.free(x),
            else => {},
        }
    }
};

const testing = std.testing;

fn testFieldValueParse(input: []const u8, want: Value) !void {
    const got = try FieldValue.parse(testing.allocator, input);
    defer got.deinit();
    switch (want) {
        .String => |w| try testing.expectEqualStrings(w, got.value.String),
        else => try testing.expectEqual(want, got.value),
    }
}

test "fieldvalue parse int" {
    try testFieldValueParse("123", .{ .Int = 123 });
}

test "fieldvalue parse float" {
    try testFieldValueParse("123.4", .{ .Float = 123.4 });
}

test "fieldvalue parse string" {
    try testFieldValueParse("12a", .{ .String = "12a" });
}

test "fieldvalue parse null" {
    try testFieldValueParse("", .Null);
}

pub const Field = struct {
    raw: []const u8,

    const Self = @This();

    pub fn value(self: Self, allocator: Allocator) !FieldValue {
        return FieldValue.parse(allocator, self.raw);
    }

    pub fn string(self: Self, allocator: Allocator) !FieldValue {
        return FieldValue.string(allocator, self.raw);
    }
};

/// Yield csv fields.
pub const FieldIterator = struct {
    buffer: []const u8,
    index: ?usize, // null means the end of the iterator

    const Self = @This();
    pub const Error = FieldIteratorError;

    pub fn init(buffer: []const u8) Self {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }

    pub fn next(self: *Self) !?Field {
        return self.doNext() catch |err| {
            self.index = null; // terminate the iterator
            return err;
        };
    }

    fn doNext(self: *Self) !?Field {
        const start = self.index orelse return null;
        log.debug("[FieldIterator] start is [{s}][{d}] => {u} {any}", .{
            self.buffer,
            start,
            self.peekChar() orelse '?',
            self.peekChar() != null,
        });

        if (self.buffer.len == 0) return self.nextEmpty();

        if (self.peekChar()) |c| {
            return switch (c) {
                '"' => try self.nextQuoated(start),
                else => try self.nextRaw(start),
            };
        }

        if (self.lookBehindChar()) |c|
            if (c == ',') return self.nextEmpty();
        return null;
    }

    /// Yield a empty string field and terminate the iterator.
    fn nextEmpty(self: *Self) ?Field {
        self.index = null;
        return .{
            .raw = "",
        };
    }

    fn nextRaw(self: *Self, start: usize) !?Field {
        while (self.getChar()) |c| {
            switch (c) {
                '"' => {
                    // found quote but no left quote
                    return Error.QuoteInTheMiddle;
                },
                ',' => {
                    return .{
                        .raw = self.slice(start, self.index.? - 1), // ignore last ','
                    };
                },
                else => continue,
            }
        }

        return .{
            .raw = self.slice(start, self.index.?), // last field
        };
    }

    /// Cut a quoated csv field.
    fn nextQuoated(self: *Self, start: usize) !?Field {
        assert(self.peekChar().? == '"');
        _ = self.getChar(); // ignore first '"'

        while (self.getChar()) |c| {
            switch (c) {
                '"' => {
                    if (self.getChar()) |d| switch (d) {
                        '"' => continue, // escaped quote
                        ',' => return .{ // quote closed and field terminated
                            .raw = self.slice(start + 1, self.index.? - 2),
                        },
                        else => {
                            return Error.QuoteUnbalanced;
                        },
                    };

                    return .{ // quote closed, last field
                        .raw = self.slice(start + 1, self.index.? - 1),
                    };
                },
                else => continue,
            }
        }
        // right quote not found
        return Error.QuoteUnbalanced;
    }

    /// Returns the previous char, keep the index.
    fn lookBehindChar(self: Self) ?u8 {
        if (self.index) |x|
            if (x - 1 >= 0) return self.buffer[x - 1];
        return null;
    }

    /// Returns the next char and advance the index.
    fn getChar(self: *Self) ?u8 {
        if (self.index) |x| {
            const c = if (x < self.buffer.len) self.buffer[x] else return null;
            self.index = x + 1;
            return c;
        }
        return null;
    }

    /// Returns the next character but keep the index.
    fn peekChar(self: *const Self) ?u8 {
        if (self.index) |x|
            if (x < self.buffer.len) return self.buffer[x];
        return null;
    }

    /// Cut `self.buffer`.
    fn slice(self: *const Self, start: usize, end: usize) []const u8 {
        log.debug("[FieldIterator] slice [{s}][{d}..{d}] => {s}", .{ self.buffer, start, end, self.buffer[start..end] });
        return self.buffer[start..end];
    }
};

fn testFieldIterator(input: []const u8, want: []const []const u8, err: ?anyerror) !void {
    var it = FieldIterator.init(input);
    var i: usize = 0;

    while (it.next() catch |got_err| {
        try testing.expectEqual(err, got_err);
        try testing.expectEqual(i, want.len);
        return;
    }) |got| {
        try testing.expect(i < want.len);
        const w = want[i];
        try testing.expectEqualStrings(w, got.raw);
        i += 1;
    }
    try testing.expectEqual(i, want.len);
    try testing.expect(err == null);
}

test "split fields" {
    try testFieldIterator("aaa,10,c", &[_][]const u8{ "aaa", "10", "c" }, null);
}

test "split quated fields" {
    try testFieldIterator("\"aaa,10,c\",X", &[_][]const u8{ "aaa,10,c", "X" }, null);
}

test "split empty string" {
    try testFieldIterator("", &[_][]const u8{""}, null);
}

test "split empty fields" {
    try testFieldIterator("a,,b,", &[_][]const u8{ "a", "", "b", "" }, null);
}

test "split quoated empty fields" {
    try testFieldIterator("a,\"\",b,\"\"", &[_][]const u8{ "a", "", "b", "" }, null);
}

test "split quated line" {
    try testFieldIterator("\"a,b,c\"", &[_][]const u8{"a,b,c"}, null);
}

test "split error quote in the middle" {
    try testFieldIterator("a,b\"d,c", &[_][]const u8{"a"}, FieldIteratorError.QuoteInTheMiddle);
}

test "split error unbalanced quote" {
    try testFieldIterator("a,\"z\"x,c", &[_][]const u8{"a"}, FieldIteratorError.QuoteUnbalanced);
}

test "split escaped quote field" {
    try testFieldIterator("\"a,\"\"b,c\"", &[_][]const u8{"a,\"\"b,c"}, null);
}

fn canonicalizeField(allocator: Allocator, raw: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    var quoated = false;
    for (raw) |c| {
        if (c != '"') {
            assert(!quoated);
            try list.append(c);
            continue;
        }
        if (quoated) {
            try list.append(c);
            quoated = false;
            continue;
        }
        quoated = true;
    }
    return list.toOwnedSlice();
}

test "capitalize field no changes" {
    const allocator = testing.allocator;
    const line = "a,b,c";
    const got = try canonicalizeField(allocator, line);
    defer allocator.free(got);
    try testing.expectEqualSlices(u8, "a,b,c", got);
}

test "capitalize field" {
    const allocator = testing.allocator;
    const line = "a,b\"\",c";
    const got = try canonicalizeField(allocator, line);
    defer allocator.free(got);
    try testing.expectEqualSlices(u8, "a,b\",c", got);
}
