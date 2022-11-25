const std = @import("std");

pub fn Scanner(comptime ReaderType: type) type {
    return struct {
        in_stream: ReaderType,
        err: ?anyerror,

        const Self = @This();

        pub fn next(self: *Self, buf: []u8) ?[]const u8 {
            if (self.err) |_| return null;

            return self.in_stream.readUntilDelimiterOrEof(
                buf,
                '\n',
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
    var buf: [255]u8 = undefined;

    if (scan_stream.next(&buf)) |x| {
        try testing.expectEqualSlices(u8, "first", x);
    } else try testing.expect(false);
    if (scan_stream.next(&buf)) |x| {
        try testing.expectEqualSlices(u8, "second", x);
    } else try testing.expect(false);
    try testing.expect(scan_stream.next(&buf) == null);
    try testing.expect(scan_stream.next(&buf) == null);
    try testing.expect(scan_stream.err == null);
}
