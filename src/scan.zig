const std = @import("std");

pub fn Scanner(comptime ReaderType: type) type {
    return struct {
        in_stream: ReaderType,

        const Self = @This();

        pub fn next(self: *Self, buf: []u8) !?[]const u8 {
            return try self.in_stream.readUntilDelimiterOrEof(
                buf,
                '\n',
            );
        }
    };
}

/// Return a new iterator that reads all the lines.
/// A line does not contain a trailing newline.
pub fn scanner(comptime in_stream: anytype) Scanner(@TypeOf(in_stream)) {
    return .{
        .in_stream = in_stream,
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

    if (try scan_stream.next(&buf)) |x| {
        try testing.expectEqualSlices(u8, "first", x);
    } else try testing.expect(false);
    if (try scan_stream.next(&buf)) |x| {
        try testing.expectEqualSlices(u8, "second", x);
    } else try testing.expect(false);
    try testing.expect(try scan_stream.next(&buf) == null);
    try testing.expect(try scan_stream.next(&buf) == null);
}
