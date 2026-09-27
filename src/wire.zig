const std = @import("std");

pub fn size(comptime T: type) usize {
    return comptime switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| if (i.bits > 0 and i.bits <= 64 and i.bits % 8 == 0) i.bits / 8 else @compileError("unsupported wire integer"),
        .float => |f| if (f.bits == 32 or f.bits == 64) f.bits / 8 else @compileError("unsupported wire float"),
        .@"enum" => |e| size(e.tag_type),
        .array => |a| a.len * size(a.child),
        .@"struct" => |s| blk: {
            var n: usize = 0;
            for (s.fields) |f| n += size(f.type);
            break :blk n;
        },
        else => @compileError("SDK components must contain only fixed-size values: " ++ @typeName(T)),
    };
}

fn signature(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .bool, .int, .float => @typeName(T),
        .@"enum" => |e| blk: {
            var s = "enum:" ++ signature(e.tag_type);
            for (e.fields) |f| s = s ++ ":" ++ f.name ++ "=" ++ std.fmt.comptimePrint("{d}", .{f.value});
            break :blk s;
        },
        .array => |a| std.fmt.comptimePrint("[{d}]", .{a.len}) ++ signature(a.child),
        .@"struct" => |s| blk: {
            var text: []const u8 = "{";
            for (s.fields) |f| text = text ++ f.name ++ ":" ++ signature(f.type) ++ ";";
            break :blk text ++ "}";
        },
        else => @compileError("unsupported wire type " ++ @typeName(T)),
    };
}

pub fn layout(comptime T: type) u64 {
    return comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk std.hash.Fnv1a_64.hash(signature(T));
    };
}

pub fn encode(comptime T: type, value: T, out: []u8) void {
    std.debug.assert(out.len == size(T));
    switch (@typeInfo(T)) {
        .bool => out[0] = @intFromBool(value),
        .int => std.mem.writeInt(T, out[0..comptime size(T)], value, .little),
        .float => |f| std.mem.writeInt(std.meta.Int(.unsigned, f.bits), out[0..comptime size(T)], @bitCast(value), .little),
        .@"enum" => |e| encode(e.tag_type, @intFromEnum(value), out),
        .array => |a| for (value, 0..) |v, i| encode(a.child, v, out[i * size(a.child) ..][0..size(a.child)]),
        .@"struct" => |s| {
            comptime var start: usize = 0;
            inline for (s.fields) |f| {
                encode(f.type, @field(value, f.name), out[start..][0..size(f.type)]);
                start += comptime size(f.type);
            }
        },
        else => unreachable,
    }
}

pub fn decode(comptime T: type, bytes: []const u8) !T {
    if (bytes.len != size(T)) return error.InvalidWireSize;
    switch (@typeInfo(T)) {
        .bool => return switch (bytes[0]) {
            0 => false,
            1 => true,
            else => error.InvalidWireValue,
        },
        .int => return std.mem.readInt(T, bytes[0..comptime size(T)], .little),
        .float => |f| return @bitCast(std.mem.readInt(std.meta.Int(.unsigned, f.bits), bytes[0..comptime size(T)], .little)),
        .@"enum" => |e| return std.meta.intToEnum(T, try decode(e.tag_type, bytes)),
        .array => |a| {
            var out: T = undefined;
            for (&out, 0..) |*v, i| v.* = try decode(a.child, bytes[i * size(a.child) ..][0..size(a.child)]);
            return out;
        },
        .@"struct" => |s| {
            var out: T = undefined;
            comptime var start: usize = 0;
            inline for (s.fields) |f| {
                @field(out, f.name) = try decode(f.type, bytes[start..][0..size(f.type)]);
                start += comptime size(f.type);
            }
            return out;
        },
        else => unreachable,
    }
}

test "wire encoding excludes native padding and rejects invalid booleans" {
    const T = struct { a: u8, b: u32, enabled: bool };
    var bytes: [size(T)]u8 = undefined;
    encode(T, .{ .a = 7, .b = 0x12345678, .enabled = true }, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0x78, 0x56, 0x34, 0x12, 1 }, &bytes);
    try std.testing.expectEqual(@as(u32, 0x12345678), (try decode(T, &bytes)).b);
    bytes[5] = 2;
    try std.testing.expectError(error.InvalidWireValue, decode(T, &bytes));
}
