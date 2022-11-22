const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Scanner(comptime ReaderType: type) type {
    return struct {
        in_stream: ReaderType,
        err: ?anyerror,

        const Self = @This();

        pub fn next(self: *Self, allocator: Allocator, max_size: usize) ?[]const u8 {
            if (self.err) |_| return null;

            return self.in_stream.readUntilDelimiterOrEofAlloc(
                allocator,
                '\n',
                max_size,
            ) catch |err| {
                self.err = err;
                return null;
            };
        }
    };
}

/// Return a new iterator that reads all the lines.
/// A line does not contain a trailing newline.
/// In the end, should check the `err` field that keeps an error during iteration.
pub fn scanner(comptime in_stream: anytype) Scanner(@TypeOf(in_stream)) {
    return .{
        .in_stream = in_stream,
        .err = null,
    };
}

const testing = std.testing;

test "scan" {
    const lines =
        \\first
        \\second
    ;
    comptime var in_stream = std.io.fixedBufferStream(lines);
    var scan_stream = scanner(in_stream.reader());
    const allocator = std.testing.allocator;
    const max_size = 255;

    if (scan_stream.next(allocator, max_size)) |x| {
        defer allocator.free(x);
        try testing.expectEqualSlices(u8, "first", x);
    } else try testing.expect(false);
    if (scan_stream.next(allocator, max_size)) |x| {
        defer allocator.free(x);
        try testing.expectEqualSlices(u8, "second", x);
    } else try testing.expect(false);
    try testing.expect(scan_stream.next(allocator, max_size) == null);
    try testing.expect(scan_stream.next(allocator, max_size) == null);
    try testing.expect(scan_stream.err == null);
}
