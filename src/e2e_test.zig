const std = @import("std");
const mem = std.mem;
const io = std.io;
const Allocator = mem.Allocator;

const testing = std.testing;
const debug = std.debug;

const executableName = "csv2json"; // TODO: get from build.zig

test "end to end" {
    const allocator = testing.allocator;
    var executable = try Executable.init(allocator);
    defer executable.deinit();

    const testcases = [_]Testcase{
        .{
            .title = "run",
            .args = .{},
            .input =
            \\x,y,z
            \\x1,y1,z1
            \\x2,y2,z2
            ,
            .want =
            \\["x","y","z"]
            \\["x1","y1","z1"]
            \\["x2","y2","z2"]
            \\
            ,
            .want_error = .{},
        },
        .{
            .title = "with header",
            .args = .{
                .args = &[_][]const u8{"--header"},
            },
            .input =
            \\x,y,z
            \\x1,y1,z1
            \\x2,y2,z2
            ,
            .want =
            \\{"x":"x1","y":"y1","z":"z1"}
            \\{"x":"x2","y":"y2","z":"z2"}
            \\
            ,
            .want_error = .{},
        },
        .{
            .title = "continue on fail",
            .args = .{},
            .input =
            \\x,y,z
            \\x1,y"1,z1
            \\x2,y2,z2
            ,
            .want =
            \\["x","y","z"]
            \\["x2","y2","z2"]
            \\
            ,
            .want_error = .{ .has_stderr = true },
        },
        .{
            .title = "exit on fail",
            .args = .{
                .args = &[_][]const u8{"--failfast"},
            },
            .input =
            \\x,y,z
            \\x1,y"1,z1
            \\x2,y2,z2
            ,
            .want =
            \\["x","y","z"]
            \\
            ,
            .want_error = .{ .has_stderr = true },
        },
    };

    for (testcases) |case| {
        debug.print("START {s}...\n", .{case.title});
        try case.run(executable);
    }
}

const Testcase = struct {
    title: []const u8,
    args: ExecConfig,
    /// Data to be sent to stdin.
    input: []const u8,
    /// Expected data from stdout.
    want: []const u8,
    want_error: TestcaseConfig,

    const Self = @This();

    pub fn run(
        self: Self,
        executable: Executable,
    ) !void {
        const got = try executable.exec(self.input, self.args);
        defer got.deinit();

        errdefer {
            debug.print("term:{any}\n", .{got.term});
            debug.print("stdout:\n{s}", .{got.stdout});
            debug.print("stderr:\n{s}", .{got.stderr});
        }

        try testing.expectEqual(self.want_error.is_error, got.isError());
        if (self.want_error.has_stderr) {
            try testing.expect(got.stderr.len > 0);
        } else {
            try testing.expect(got.stderr.len == 0);
        }
        try testing.expectEqualStrings(self.want, got.stdout);
    }
};

const TestcaseConfig = struct {
    /// If true, expect that exit status is not 0.
    is_error: bool = false,
    /// If true, expect that some stderr output exist.
    has_stderr: bool = false,
};

const ExecConfig = struct {
    /// Additional cli arguments
    args: ?[]const []const u8 = null,
    stdout_buffer_size: usize = 1024,
    stderr_buffer_size: usize = 1024,
};

const ExecResult = struct {
    allocator: Allocator,
    term: std.ChildProcess.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn isError(self: ExecResult) bool {
        return self.term != .Exited;
    }

    pub fn deinit(self: ExecResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

const Executable = struct {
    allocator: Allocator,
    dir: testing.TmpDir,
    path: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator) !Executable {
        var dir = testing.tmpDir(.{});
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const dirPath = try std.os.getFdPath(dir.dir.fd, &buf);
        // compile the cli executable
        try run(allocator, &[_][]const u8{ "zig", "build", "install", "--prefix", dirPath, "-Drelease-fast=true" });
        const path = try dir.dir.realpathAlloc(allocator, "bin/" ++ executableName);
        // display help
        try run(allocator, &[_][]const u8{ path, "--help" });
        return .{
            .allocator = allocator,
            .dir = dir,
            .path = path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.dir.cleanup();
        self.allocator.free(self.path);
    }

    pub fn exec(self: Self, input: []const u8, config: ExecConfig) !ExecResult {
        const allocator = self.allocator;

        var argv_list = std.ArrayList([]const u8).init(allocator);
        defer argv_list.deinit();
        try argv_list.append(self.path);
        if (config.args) |args| {
            for (args) |arg| try argv_list.append(arg);
        }
        const argv = argv_list.toOwnedSlice();
        defer allocator.free(argv);

        debug.print("argv:{s}\n", .{argv});

        const dir = self.dir.dir;
        const stdin_filename = "stdin.txt";
        {
            var stdin_file = try dir.createFile(stdin_filename, .{ .read = true });
            defer stdin_file.close();
            try stdin_file.writer().writeAll(input);
        }
        const stdin_filepath = try dir.realpathAlloc(allocator, stdin_filename);
        defer allocator.free(stdin_filepath);

        var cat_proc = std.ChildProcess.init(&[_][]const u8{ "cat", stdin_filepath }, allocator);
        var main_proc = std.ChildProcess.init(argv, allocator);

        cat_proc.stdout_behavior = .Pipe;
        try cat_proc.spawn();

        main_proc.stdin = cat_proc.stdout;
        main_proc.stdout_behavior = .Pipe;
        main_proc.stderr_behavior = .Pipe;
        try main_proc.spawn();

        const stdout = try main_proc.stdout.?.readToEndAlloc(allocator, config.stdout_buffer_size);
        const stderr = try main_proc.stderr.?.readToEndAlloc(allocator, config.stderr_buffer_size);

        const cat_term = try cat_proc.wait();
        const main_term = try main_proc.wait();

        const term = if (cat_term != std.ChildProcess.Term.Exited) cat_term else main_term;
        return .{
            .allocator = self.allocator,
            .term = term,
            .stdout = stdout,
            .stderr = stderr,
        };
    }
};

const RunError = error{
    Failed,
};

fn run(allocator: Allocator, argv: []const []const u8) !void {
    var result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    debug.print("[run][{s}][{any}]\n", .{ argv, result.term });
    debug.print("out:\n{s}", .{result.stdout});
    debug.print("err:\n{s}", .{result.stderr});

    if (result.term != .Exited) return RunError.Failed;
}
