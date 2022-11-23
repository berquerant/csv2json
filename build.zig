const std = @import("std");
const builtin = @import("builtin");
const heap = std.heap;
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const log = std.log;
const Allocator = std.mem.Allocator;

const needed_zig_version = std.SemanticVersion.parse("0.10.0") catch unreachable;

pub fn build(b: *std.build.Builder) !void {
    if (comptime builtin.zig_version.order(needed_zig_version) == .lt) {
        log.err("Need zig {} but got {}\n", .{ needed_zig_version, builtin.zig_version });
        std.os.exit(1);
    }

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    var gp = heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gp.deinit();
    const allocator = gp.allocator();

    var packages = try Packages.load(allocator, "requirements.txt", "libs");
    defer packages.deinit();

    const exe = b.addExecutable("csv2json", "src/main.zig");
    for (packages.list.items) |item| exe.addPackagePath(item.name, item.pkg_index_path);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    for (packages.list.items) |item| exe_tests.addPackagePath(item.name, item.pkg_index_path);
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

const requirements_file_max_byte = 4096;

const Packages = struct {
    list: std.ArrayList(Package),

    const Self = @This();

    pub fn load(allocator: Allocator, filename: []const u8, libDir: []const u8) !Self {
        const file = try fs.cwd().openFile(filename, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, requirements_file_max_byte);
        defer allocator.free(content);

        var lines = mem.split(u8, content, "\n");
        var packages = Self.init(allocator);
        var linum: u8 = 0;

        while (lines.next()) |line| {
            linum += 1;
            if (line.len == 0) continue;
            const package = Package.parse(allocator, line, libDir) catch |err| {
                std.log.warn("{any} at line {d} [{s}]", .{ err, linum, line });
                continue;
            };
            try packages.add(package);
            log.info("Add {s} to package path as {s}, line {d}", .{ package.location, package.name, linum });
        }

        return packages;
    }

    fn init(allocator: Allocator) Self {
        return Packages{
            .list = std.ArrayList(Package).init(allocator),
        };
    }

    fn add(self: *Self, package: Package) !void {
        try self.list.append(package);
    }

    pub fn deinit(self: Self) void {
        for (self.list.items) |item| item.deinit();
        self.list.deinit();
    }
};

const PackageError = error{
    MalformedPackage,
};

const Package = struct {
    allocator: Allocator,
    location: []const u8,
    version: []const u8,
    entrance: []const u8,
    name: []const u8,
    pkg_index_path: []const u8,
    repoName: []const u8,

    const Self = @This();
    pub const Error = PackageError;

    pub fn parse(allocator: Allocator, line: []const u8, libDir: []const u8) !Self {
        // verify format:
        // LOCATION VERSION ENTRANCE
        var parts = mem.split(u8, line, " ");
        var buf: [3][]const u8 = undefined;
        var count: u8 = 0;
        while (parts.next()) |x| {
            if (count >= buf.len) break; // ignore extra fields
            buf[count] = x;
            count += 1;
        }

        if (count != buf.len) {
            return Error.MalformedPackage;
        }

        const location = try allocator.alloc(u8, buf[0].len);
        const version = try allocator.alloc(u8, buf[1].len);
        const entrance = try allocator.alloc(u8, buf[2].len);

        std.mem.copy(u8, location, buf[0]);
        std.mem.copy(u8, version, buf[1]);
        std.mem.copy(u8, entrance, buf[2]);

        var name: []const u8 = undefined;
        var repoName: []const u8 = undefined;

        {
            var e_parts = mem.split(u8, entrance, ".");
            name = e_parts.first();
        }
        {
            var l_parts = mem.split(u8, location, "/");
            while (l_parts.next()) |x| {
                repoName = x;
            }
        }

        const pkg_index_path = try fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ libDir, repoName, entrance });
        return Package{
            .allocator = allocator,
            .location = location,
            .version = version,
            .entrance = entrance,
            .name = name,
            .pkg_index_path = pkg_index_path,
            .repoName = repoName,
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.location);
        self.allocator.free(self.version);
        self.allocator.free(self.entrance);
        self.allocator.free(self.pkg_index_path);
    }
};

const testing = @import("std").testing;

test "parse package" {
    const line = "github.com/Hejsil/zig-clap 0.6.0 clap.zig";
    const got = try Package.parse(testing.allocator, line, "lib");
    defer got.deinit();
    try testing.expectEqualSlices(u8, "github.com/Hejsil/zig-clap", got.location);
    try testing.expectEqualSlices(u8, "0.6.0", got.version);
    try testing.expectEqualSlices(u8, "clap.zig", got.entrance);
    try testing.expectEqualSlices(u8, "clap", got.name);
    try testing.expectEqualSlices(u8, "lib/zig-clap/clap.zig", got.pkg_index_path);
    try testing.expectEqualSlices(u8, "zig-clap", got.repoName);
}
