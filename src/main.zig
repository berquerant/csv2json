const std = @import("std");
const io = std.io;
const heap = std.heap;
const mem = std.mem;
const clap = @import("clap");
const scan = @import("scan.zig");
const lambda = @import("lambda.zig").lambda;
const convert = @import("convert.zig");
const csv = @import("csv.zig");

const usage =
    \\Usage: csv2json [options...]
    \\
    \\Convert csv data from stdin into json
    \\
    \\Options:
;

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-i, --header           Read header line.
        \\--failfast             Exit on error.
    );
    var diag = clap.Diagnostic{};

    var err_stream = io.bufferedWriter(io.getStdErr().writer());
    defer err_stream.flush() catch {};
    var stderr = err_stream.writer();

    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help) {
        try stderr.print("{s}\n", .{usage});
        return clap.help(stderr, clap.Help, &params, .{});
    }

    var gpa = heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    comptime var scan_stream = scan.scanner(io.getStdIn().reader());

    defer deinitHeader();
    if (res.args.header) {
        if (scan_stream.next(allocator, buffer_size)) |line| {
            defer allocator.free(line);
            try initHeader(allocator, line);
        } else return;
    }

    var out_stream = io.bufferedWriter(io.getStdOut().writer());
    defer out_stream.flush() catch {};
    var stdout = out_stream.writer();

    var runner = lambda(scan_stream);
    try runner.run(
        allocator,
        callback,
        stdout,
        stderr,
        .{ .exit_on_error = res.args.failfast },
    );
}

const buffer_size = 4096;
var header: ?convert.Header = null;

fn initHeader(allocator: mem.Allocator, line: []const u8) !void {
    header = convert.Header.init(allocator);
    var it = csv.FieldIterator.init(line);
    while (it.next()) |item| {
        const value = try item.string(allocator);
        defer value.deinit();
        try header.?.append(value.value);
    }
    if (it.err) |err| return err;
}

fn deinitHeader() void {
    if (header) |x| x.deinit();
}

fn callback(allocator: mem.Allocator, line: []const u8) anyerror![]const u8 {
    var builder = convert.Builder.init(allocator, header);
    defer builder.deinit(false);

    var it = csv.FieldIterator.init(line);
    while (it.next()) |item| {
        const value = try item.value(allocator);
        try builder.append(value);
    }
    if (it.err) |err| return err;

    var buffer = try allocator.alloc(u8, buffer_size);
    var stream = io.fixedBufferStream(buffer);
    try builder.dump(stream.writer());
    return stream.getWritten();
}

test {
    std.testing.refAllDecls(@This());
}
