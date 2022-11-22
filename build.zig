const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    var gp = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gp.deinit();
    const allocator = gp.allocator();

    var packages = try loadPackages(allocator, "requirements.txt");
    defer packages.deinit();

    const exe = b.addExecutable("json2csv", "src/main.zig");
    const libDir = "libs";
    for (packages.list.items) |item| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ libDir, item.repoName(), item.entrance });
        std.log.info("Add {s} to package path as {s}", .{ path, item.importPath() });
        defer allocator.free(path);
        exe.addPackagePath(item.importPath(), path);
    }
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

fn loadPackages(allocator: Allocator, filename: []const u8) !Packages {
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 2048);
    defer allocator.free(content);

    var lines = std.mem.split(u8, content, "\n");
    var packages = Packages.init(allocator);
    var linum: u8 = 0;

    while (lines.next()) |line| {
        linum += 1;
        if (line.len == 0) continue;
        const package = Package.parse(allocator, line) catch |err| {
            std.log.warn("{any} at line {d} [{s}]", .{ err, linum, line });
            continue;
        };
        try packages.add(package);
    }

    return packages;
}

const Packages = struct {
    list: std.ArrayList(Package),

    pub fn init(allocator: Allocator) Packages {
        return Packages{
            .list = std.ArrayList(Package).init(allocator),
        };
    }

    pub fn add(self: *@This(), package: Package) !void {
        try self.list.append(package);
    }

    pub fn deinit(self: @This()) void {
        for (self.list.items) |item| {
            item.deinit();
        }
        self.list.deinit();
    }
};

const PackageError = error{
    MalformedPackage,
};

const Package = struct {
    location: []const u8,
    version: []const u8,
    entrance: []const u8,
    allocator: Allocator,

    pub fn parse(allocator: Allocator, line: []const u8) !Package {
        // verify format:
        // LOCATION VERSION ENTRANCE
        var parts = std.mem.split(u8, line, " ");
        var buf: [3][]const u8 = undefined;
        var count: u8 = 0;
        while (parts.next()) |x| {
            if (count >= buf.len) break;
            buf[count] = x;
            count += 1;
        }

        if (count != buf.len) {
            return PackageError.MalformedPackage;
        }

        const location = try allocator.alloc(u8, buf[0].len);
        const version = try allocator.alloc(u8, buf[1].len);
        const entrance = try allocator.alloc(u8, buf[2].len);

        std.mem.copy(u8, location, buf[0]);
        std.mem.copy(u8, version, buf[1]);
        std.mem.copy(u8, entrance, buf[2]);

        return Package{
            .location = location,
            .version = version,
            .entrance = entrance,
            .allocator = allocator,
        };
    }

    pub fn importPath(self: @This()) []const u8 {
        var parts = std.mem.split(u8, self.entrance, ".");
        return parts.first();
    }

    pub fn repoName(self: @This()) []const u8 {
        var parts = std.mem.split(u8, self.location, "/");
        var last: []const u8 = undefined;
        while (parts.next()) |x| {
            last = x;
        }
        return last;
    }

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.location);
        self.allocator.free(self.version);
        self.allocator.free(self.entrance);
    }
};

const testing = @import("std").testing;

test "parse package" {
    const line = "github.com/Hejsil/zig-clap 0.6.0 clap.zig";
    const got = try Package.parse(testing.allocator, line);
    defer got.deinit();
    try testing.expectEqualSlices(u8, "github.com/Hejsil/zig-clap", got.location);
    try testing.expectEqualSlices(u8, "0.6.0", got.version);
    try testing.expectEqualSlices(u8, "clap.zig", got.entrance);
    try testing.expectEqualSlices(u8, "zig-clap", got.repoName());
    try testing.expectEqualSlices(u8, "clap", got.importPath());
}
