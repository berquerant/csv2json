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

    if (res.args.header) {
        var buf: [read_buffer_size]u8 = undefined;
        if (try scan_stream.next(&buf)) |line| {
            try initHeader(allocator, line);
        } else return;
    }
    defer deinitHeader();

    var out_stream = io.bufferedWriter(io.getStdOut().writer());
    defer out_stream.flush() catch {};
    var stdout = out_stream.writer();

    var runner = lambda(scan_stream);
    try runner.run(
        allocator,
        callback,
        stdout,
        stderr,
        .{
            .exit_on_error = res.args.failfast,
            .read_buffer_size = read_buffer_size,
            .write_buffer_size = write_buffer_size,
        },
    );
}

const read_buffer_size = 4096;
const write_buffer_size = 4096;

var header: ?convert.Header = null;

fn initHeader(allocator: mem.Allocator, line: []const u8) !void {
    header = convert.Header.init(allocator);
    var it = csv.FieldIterator.init(line);
    while (try it.next()) |item| {
        const value = try item.string(allocator);
        defer value.deinit();
        try header.?.append(value.value);
    }
}

fn deinitHeader() void {
    if (header) |x| x.deinit();
}

fn callback(buf: []u8, line: []const u8) anyerror![]const u8 {
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = convert.Builder.init(allocator, header);
    defer builder.deinit(false);

    var it = csv.FieldIterator.init(line);
    while (try it.next()) |item| {
        const value = try item.value(allocator);
        try builder.append(value);
    }

    var stream = io.fixedBufferStream(buf);
    try builder.dump(stream.writer());
    return stream.getWritten();
}

test {
    std.testing.refAllDecls(@This());
}
