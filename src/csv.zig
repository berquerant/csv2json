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

test "fieldvalue parse int" {
    const got = try FieldValue.parse(testing.allocator, "123");
    defer got.deinit();
    try testing.expectEqual(Value{ .Int = 123 }, got.value);
}

test "fieldvalue parse float" {
    const got = try FieldValue.parse(testing.allocator, "123.4");
    defer got.deinit();
    try testing.expectEqual(Value{ .Float = 123.4 }, got.value);
}

test "fieldvalue parse string" {
    const got = try FieldValue.parse(testing.allocator, "12a");
    defer got.deinit();
    try testing.expectEqualSlices(u8, "12a", got.value.String);
}

test "fieldvalue parse null" {
    const got = try FieldValue.parse(testing.allocator, "");
    defer got.deinit();
    try testing.expectEqual(Value.Null, got.value);
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
/// In the end, should check the `err` field that keeps an error during iteration.
pub const FieldIterator = struct {
    buffer: []const u8,
    index: ?usize, // null means the end of the iterator
    err: ?Error,

    const Self = @This();
    pub const Error = FieldIteratorError;

    pub fn init(buffer: []const u8) Self {
        return .{
            .buffer = buffer,
            .index = 0,
            .err = null,
        };
    }

    pub fn next(self: *Self) ?Field {
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
                '"' => self.nextQuoated(start),
                else => self.nextRaw(start),
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

    fn nextRaw(self: *Self, start: usize) ?Field {
        while (self.getChar()) |c| {
            switch (c) {
                '"' => {
                    // found quote but no left quote
                    self.fail(Error.QuoteInTheMiddle);
                    return null;
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
    fn nextQuoated(self: *Self, start: usize) ?Field {
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
                            self.fail(Error.QuoteUnbalanced);
                            return null;
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
        self.fail(Error.QuoteUnbalanced);
        return null;
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

    /// Set `self.err` and terminate the iterator.
    fn fail(self: *Self, err: Error) void {
        self.err = err;
        self.index = null;
    }

    /// Cut `self.buffer`.
    fn slice(self: *const Self, start: usize, end: usize) []const u8 {
        log.debug("[FieldIterator] slice [{s}][{d}..{d}] => {s}", .{ self.buffer, start, end, self.buffer[start..end] });
        return self.buffer[start..end];
    }
};

const testing = std.testing;

test "split fields" {
    const line = "aaa,10,c";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "aaa", it.next().?.raw);
    try testing.expectEqualSlices(u8, "10", it.next().?.raw);
    try testing.expectEqualSlices(u8, "c", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err == null);
}

test "split quated fields" {
    const line = "\"aaa,10,c\",X";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "aaa,10,c", it.next().?.raw);
    try testing.expectEqualSlices(u8, "X", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err == null);
}

test "split empty string" {
    const line = "";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err == null);
}

test "split empty fields" {
    const line = "a,,b,";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "a", it.next().?.raw);
    try testing.expectEqualSlices(u8, "", it.next().?.raw);
    try testing.expectEqualSlices(u8, "b", it.next().?.raw);
    try testing.expectEqualSlices(u8, "", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err == null);
}

test "split quoated empty fields" {
    const line = "a,\"\",b,\"\"";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "a", it.next().?.raw);
    try testing.expectEqualSlices(u8, "", it.next().?.raw);
    try testing.expectEqualSlices(u8, "b", it.next().?.raw);
    try testing.expectEqualSlices(u8, "", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err == null);
}

test "split quated line" {
    const line = "\"a,b,c\"";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "a,b,c", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err == null);
}

test "split error quote in the middle" {
    const line = "a,b\"d,c";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "a", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err.? == FieldIteratorError.QuoteInTheMiddle);
}

test "split error unbalanced quote" {
    const line = "a,\"z\"x,c";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "a", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err.? == FieldIteratorError.QuoteUnbalanced);
}

test "split escaped quote field" {
    const line = "\"a,\"\"b,c\"";
    var it = FieldIterator.init(line);
    try testing.expectEqualSlices(u8, "a,\"\"b,c", it.next().?.raw);
    try testing.expect(it.next() == null);
    try testing.expect(it.err == null);
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
