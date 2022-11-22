const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedExit,
};

pub const Config = struct {
    /// If true, exit `run()` when an error occurs.
    exit_on_error: bool = false,
    /// Max bytes of an input line.
    max_line_buffer_size: usize = 4096,
};

pub fn Lambda(
    comptime ScannerType: type,
) type {
    return struct {
        scan_stream: ScannerType,

        const Self = @This();

        pub fn run(
            self: *Self,
            allocator: Allocator,
            comptime func: fn (allocator: Allocator, line: []const u8) anyerror![]const u8,
            out_stream: anytype,
            err_stream: anytype,
            config: Config,
        ) !void {
            var linum: u16 = 0;

            while (self.scan_stream.next(allocator, config.max_line_buffer_size)) |line| {
                defer allocator.free(line); // lifetime of the input line is in the loop
                linum += 1;
                log.debug("[Lambda] Line {d} - {s}", .{ linum, line });

                const result = func(allocator, line) catch |err| { // func allocates some output line
                    log.debug("[Lambda] Line {d} func returned error {any}", .{ linum, err });
                    _ = err_stream.print("Line {d} {s} {any}\n", .{ linum, line, err }) catch {};
                    if (config.exit_on_error) return err;
                    continue;
                };
                defer allocator.free(result); // lifetime of the output line is in the loop

                log.debug("[Lambda] Line {d} func returned {s}", .{ linum, result });

                out_stream.print("{s}\n", .{result}) catch |err| {
                    log.debug("[Lambda] Line {d} failed to write result", .{linum});
                    _ = err_stream.print("Failed to write result {any}, line {d} {s} {s}\n", .{
                        err, linum, line, result,
                    }) catch {};
                    if (config.exit_on_error) return err;
                    continue;
                };
            }

            if (self.scan_stream.err) |err| {
                return err;
            }
        }
    };
}

/// Map the lines and write results.
///
/// - 1. Read a line from `scan_stream`.
/// - 2. Call `func`.
/// - 3. Write result to `out_stream` or error to `err_stream`.
///
/// `func` should allocate a new string and return it.
pub fn lambda(
    comptime scan_stream: anytype,
) Lambda(
    @TypeOf(scan_stream),
) {
    return .{
        .scan_stream = scan_stream,
    };
}

const scan = @import("scan.zig");

test "lambda" {
    const func = struct {
        fn call(allocator: Allocator, line: []const u8) anyerror![]const u8 {
            return std.fmt.allocPrint(allocator, "Got '{s}'", .{line});
        }
    }.call;
    const lines =
        \\a
        \\bc
        \\def
    ;
    comptime var in_stream = std.io.fixedBufferStream(lines);
    comptime var scanner = scan.scanner(in_stream.reader());

    var out_buf: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err_stream = std.io.fixedBufferStream(&err_buf);
    var runner = lambda(scanner);
    try runner.run(
        std.testing.allocator,
        func,
        out_stream.writer(),
        err_stream.writer(),
        .{},
    );

    const want =
        \\Got 'a'
        \\Got 'bc'
        \\Got 'def'
        \\
    ;
    try std.testing.expectEqualStrings(want, out_stream.getWritten());
    try std.testing.expect(err_stream.getWritten().len == 0);
}

test "lambda continue on error" {
    const func = struct {
        fn call(allocator: Allocator, line: []const u8) anyerror![]const u8 {
            if (std.mem.eql(u8, line, "bc")) return error.UnexpectedExit;
            return std.fmt.allocPrint(allocator, "Got '{s}'", .{line});
        }
    }.call;
    const lines =
        \\a
        \\bc
        \\def
    ;
    comptime var in_stream = std.io.fixedBufferStream(lines);
    comptime var scanner = scan.scanner(in_stream.reader());

    var buf: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&buf);
    var err_buf: [256]u8 = undefined;
    var err_stream = std.io.fixedBufferStream(&err_buf);
    var runner = lambda(scanner);
    try runner.run(
        std.testing.allocator,
        func,
        out_stream.writer(),
        err_stream.writer(),
        .{},
    );

    const want =
        \\Got 'a'
        \\Got 'def'
        \\
    ;
    try std.testing.expectEqualStrings(want, out_stream.getWritten());
    try std.testing.expect(err_stream.getWritten().len > 0);
}

test "lambda exit on error" {
    const func = struct {
        fn call(allocator: Allocator, line: []const u8) anyerror![]const u8 {
            if (std.mem.eql(u8, line, "bc")) return error.UnexpectedExit;
            return std.fmt.allocPrint(allocator, "Got '{s}'", .{line});
        }
    }.call;
    const lines =
        \\a
        \\bc
        \\def
    ;
    comptime var in_stream = std.io.fixedBufferStream(lines);
    comptime var scanner = scan.scanner(in_stream.reader());

    var buf: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&buf);
    var err_buf: [256]u8 = undefined;
    var err_stream = std.io.fixedBufferStream(&err_buf);
    var runner = lambda(scanner);
    try std.testing.expectError(
        error.UnexpectedExit,
        runner.run(
            std.testing.allocator,
            func,
            out_stream.writer(),
            err_stream.writer(),
            .{ .exit_on_error = true },
        ),
    );

    const want =
        \\Got 'a'
        \\
    ;
    try std.testing.expectEqualStrings(want, out_stream.getWritten());
    try std.testing.expect(err_stream.getWritten().len > 0);
}
