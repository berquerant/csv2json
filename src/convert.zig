const std = @import("std");
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const csv = @import("csv.zig");

pub const StringArrayList = std.ArrayList([]const u8);

pub const HeaderError = error{
    AppendFailed,
};

pub const Header = struct {
    allocator: Allocator,
    fields: StringArrayList,

    const Self = @This();
    pub const Error = HeaderError;

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .fields = StringArrayList.init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        for (self.fields.items) |item| self.allocator.free(item);
        self.fields.deinit();
    }

    pub fn append(self: *Self, value: csv.Value) !void {
        const s = selectString(value) orelse return Error.AppendFailed;
        const elem = try self.allocator.alloc(u8, s.len);
        mem.copy(u8, elem, s);
        try self.fields.append(elem);
    }

    fn selectString(value: csv.Value) ?[]const u8 {
        return switch (value) {
            .String => |x| x,
            else => null,
        };
    }
};

const testing = std.testing;

test "header append" {
    var header = Header.init(testing.allocator);
    defer header.deinit();
    try header.append(.{ .String = "a" });
    try header.append(.{ .String = "b" });
    try testing.expectError(Header.Error.AppendFailed, header.append(.Null));
    try header.append(.{ .String = "c" });
    try testing.expectEqualStrings("a", header.fields.items[0]);
    try testing.expectEqualStrings("b", header.fields.items[1]);
    try testing.expectEqualStrings("c", header.fields.items[2]);
}

fn intoJSONValue(v: csv.Value) json.Value {
    return switch (v) {
        .Null => .Null,
        .String => |x| .{ .String = x },
        .Int => |x| .{ .Integer = x },
        .Float => |x| .{ .Float = x },
    };
}

pub const FieldValueArrayList = std.ArrayList(csv.FieldValue);

/// Build a json from csv fields.
pub const Builder = struct {
    allocator: Allocator,
    header: ?Header,
    list: FieldValueArrayList,

    const Self = @This();

    pub fn init(allocator: Allocator, header: ?Header) Self {
        return .{
            .allocator = allocator,
            .header = header,
            .list = FieldValueArrayList.init(allocator),
        };
    }

    pub fn deinit(self: Self, deinit_header: bool) void {
        for (self.list.items) |item| item.deinit();
        self.list.deinit();
        if (self.header) |header|
            if (deinit_header) header.deinit();
    }

    pub fn reset(self: *Self) void {
        for (self.list.items) |item| item.deinit();
        self.list.clearAndFree();
    }

    pub fn append(self: *Self, value: csv.FieldValue) !void {
        try self.list.append(value);
    }

    /// Dump a json string.
    /// If no `header`, build a json array.
    /// Otherwise build a json object, key depends on value's index,
    /// e.g. if value is at `list[1]` then key will be `header[1]`.
    /// If the number of the values is fewer than the keys, shortage will be filled with `null`.
    /// If the number of the keys is fewer than the values, shortage will be ignored.
    pub fn dump(self: Self, out_stream: anytype) !void {
        if (self.header) |header| {
            var map = json.ObjectMap.init(self.allocator);
            defer map.deinit();
            for (header.fields.items) |key, index| {
                try map.put(
                    key,
                    if (index < self.list.items.len)
                        intoJSONValue(self.list.items[index].value)
                    else
                        .Null,
                );
            }
            const value = json.Value{ .Object = map };
            try value.jsonStringify(.{}, out_stream);
            return;
        }

        var list = json.Array.init(self.allocator);
        defer list.deinit();
        for (self.list.items) |item| {
            try list.append(intoJSONValue(item.value));
        }
        const value = json.Value{ .Array = list };
        try value.jsonStringify(.{}, out_stream);
    }
};

test "builder dump object header short" {
    const allocator = testing.allocator;

    var header = Header.init(allocator);
    try header.append(.{ .String = "string" });
    try header.append(.{ .String = "int" });

    const string_value = try csv.FieldValue.parse(allocator, "str");
    const int_value = try csv.FieldValue.parse(allocator, "128");
    const float_value = try csv.FieldValue.parse(allocator, "12.8");
    const null_value = try csv.FieldValue.parse(allocator, "");

    var builder = Builder.init(allocator, header);
    defer builder.deinit(true);
    try builder.append(string_value);
    try builder.append(int_value);
    try builder.append(float_value);
    try builder.append(null_value);

    var out_buffer: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buffer);
    try builder.dump(out_stream.writer());
    try testing.expectEqualStrings("{\"string\":\"str\",\"int\":128}", out_stream.getWritten());
}

test "builder dump object" {
    const allocator = testing.allocator;

    var header = Header.init(allocator);
    try header.append(.{ .String = "string" });
    try header.append(.{ .String = "int" });
    try header.append(.{ .String = "float" });
    try header.append(.{ .String = "null" });

    const string_value = try csv.FieldValue.parse(allocator, "str");
    const int_value = try csv.FieldValue.parse(allocator, "128");
    const float_value = try csv.FieldValue.parse(allocator, "12.8");
    const null_value = try csv.FieldValue.parse(allocator, "");

    var builder = Builder.init(allocator, header);
    defer builder.deinit(true);
    try builder.append(string_value);
    try builder.append(int_value);
    try builder.append(float_value);
    try builder.append(null_value);

    var out_buffer: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buffer);
    try builder.dump(out_stream.writer());
    try testing.expectEqualStrings("{\"string\":\"str\",\"int\":128,\"float\":1.28e+01,\"null\":null}", out_stream.getWritten());
}

test "builder dump object values short" {
    const allocator = testing.allocator;

    var header = Header.init(allocator);
    try header.append(.{ .String = "string" });
    try header.append(.{ .String = "int" });
    try header.append(.{ .String = "float" });
    try header.append(.{ .String = "null" });

    const string_value = try csv.FieldValue.parse(allocator, "str");
    const int_value = try csv.FieldValue.parse(allocator, "128");

    var builder = Builder.init(allocator, header);
    defer builder.deinit(true);
    try builder.append(string_value);
    try builder.append(int_value);

    var out_buffer: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buffer);
    try builder.dump(out_stream.writer());
    try testing.expectEqualStrings("{\"string\":\"str\",\"int\":128,\"float\":null,\"null\":null}", out_stream.getWritten());
}

test "builder dump array" {
    const allocator = testing.allocator;
    const string_value = try csv.FieldValue.parse(allocator, "str");
    const int_value = try csv.FieldValue.parse(allocator, "128");
    const float_value = try csv.FieldValue.parse(allocator, "12.8");
    const null_value = try csv.FieldValue.parse(allocator, "");

    var builder = Builder.init(allocator, null);
    defer builder.deinit(true);
    try builder.append(string_value);
    try builder.append(int_value);
    try builder.append(float_value);
    try builder.append(null_value);

    var out_buffer: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buffer);
    try builder.dump(out_stream.writer());
    try testing.expectEqualStrings("[\"str\",128,1.28e+01,null]", out_stream.getWritten());
}
