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
    read_buffer_size: usize = 4096,
    /// Max bytes of an output line.
    write_buffer_size: usize = 4096,
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
            comptime func: fn (buf: []u8, line: []const u8) anyerror![]const u8,
            out_stream: anytype,
            err_stream: anytype,
            config: Config,
        ) !void {
            var linum: u16 = 0;
            var read_buf = try allocator.alloc(u8, config.read_buffer_size);
            defer allocator.free(read_buf);
            var write_buf = try allocator.alloc(u8, config.write_buffer_size);
            defer allocator.free(write_buf);

            while (self.scan_stream.next(read_buf)) |line| {
                linum += 1;
                log.debug("[Lambda] Line {d} - {s}", .{ linum, line });

                const result = func(write_buf, line) catch |err| { // func allocates some output line
                    log.debug("[Lambda] Line {d} func returned error {any}", .{ linum, err });
                    _ = err_stream.print("Line {d} {s} {any}\n", .{ linum, line, err }) catch {};
                    if (config.exit_on_error) return err;
                    continue;
                };

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
const testing = std.testing;

fn testLambda(
    comptime func: fn (buf: []u8, line: []const u8) anyerror![]const u8,
    comptime input: []const u8,
    options: Config,
    comptime want_output: []const u8,
    comptime has_error: bool,
) !void {
    comptime var in_stream = std.io.fixedBufferStream(input);
    comptime var scanner = scan.scanner(in_stream.reader());

    const buf_size = 255;
    var out_buf: [buf_size]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);
    var err_buf: [buf_size]u8 = undefined;
    var err_stream = std.io.fixedBufferStream(&err_buf);

    var runner = lambda(scanner);
    runner.run(
        testing.allocator,
        func,
        out_stream.writer(),
        err_stream.writer(),
        options,
    ) catch |err| {
        if (!has_error) return err;
        try testing.expect(err_stream.getWritten().len > 0);
    };
    try testing.expectEqualStrings(want_output, out_stream.getWritten());
    if (!has_error) {
        try testing.expect(err_stream.getWritten().len == 0);
    }
}

test "lambda" {
    const func = struct {
        fn call(buf: []u8, line: []const u8) anyerror![]const u8 {
            return std.fmt.bufPrint(buf, "Got '{s}'", .{line});
        }
    }.call;
    const input =
        \\a
        \\bc
        \\def
    ;
    const want =
        \\Got 'a'
        \\Got 'bc'
        \\Got 'def'
        \\
    ;
    try testLambda(
        func,
        input,
        .{},
        want,
        false,
    );
}

test "lambda continue on error" {
    const func = struct {
        fn call(buf: []u8, line: []const u8) anyerror![]const u8 {
            if (std.mem.eql(u8, line, "bc")) return error.UnexpectedExit;
            return std.fmt.bufPrint(buf, "Got '{s}'", .{line});
        }
    }.call;
    const input =
        \\a
        \\bc
        \\def
    ;
    const want =
        \\Got 'a'
        \\Got 'def'
        \\
    ;
    try testLambda(
        func,
        input,
        .{ .exit_on_error = false },
        want,
        true,
    );
}

test "lambda exit on error" {
    const func = struct {
        fn call(buf: []u8, line: []const u8) anyerror![]const u8 {
            if (std.mem.eql(u8, line, "bc")) return error.UnexpectedExit;
            return std.fmt.bufPrint(buf, "Got '{s}'", .{line});
        }
    }.call;
    const input =
        \\a
        \\bc
        \\def
    ;
    const want =
        \\Got 'a'
        \\
    ;
    try testLambda(
        func,
        input,
        .{ .exit_on_error = true },
        want,
        true,
    );
}
