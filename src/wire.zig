//! The byte format components use to cross the library boundary.
//!
//! Fields are written in declaration order, little-endian, with no padding.
//! Supported: bool, fixed-width ints and floats, enums, arrays, and structs of these.

const std = @import("std");

/// Encoded size of `T` in bytes.
pub fn size(comptime T: type) usize {
    return comptime switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| if (i.bits > 0 and i.bits <= 64 and i.bits % 8 == 0) i.bits / 8 else @compileError("unsupported wire integer"),
        .float => |f| if (f.bits == 32 or f.bits == 64) f.bits / 8 else @compileError("unsupported wire float"),
        .@"enum" => |e| size(e.tag_type),
        .array => |a| a.len * size(a.child),
        .@"struct" => |s| blk: {
            var n: usize = 0;
            for (s.field_types) |ty| n += size(ty);
            break :blk n;
        },
        else => @compileError("SDK components must contain only fixed-size values: " ++ @typeName(T)),
    };
}

fn signature(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .bool, .int, .float => @typeName(T),
        .@"enum" => |e| blk: {
            var s: []const u8 = "enum:" ++ signature(e.tag_type);
            for (e.field_names, e.field_values) |name, value| {
                s = s ++ ":" ++ name ++ "=" ++ std.fmt.comptimePrint("{d}", .{value});
            }
            break :blk s;
        },
        .array => |a| std.fmt.comptimePrint("[{d}]", .{a.len}) ++ signature(a.child),
        .@"struct" => |s| blk: {
            var text: []const u8 = "{";
            for (s.field_names, s.field_types) |name, ty| {
                text = text ++ name ++ ":" ++ signature(ty) ++ ";";
            }
            break :blk text ++ "}";
        },
        else => @compileError("unsupported wire type " ++ @typeName(T)),
    };
}

/// Fingerprint of `T`'s field names and types. Differs if the layout changes.
pub fn layout(comptime T: type) u64 {
    return comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk std.hash.Fnv1a_64.hash(signature(T));
    };
}

/// Writes `value` into `out`, which must be exactly `size(T)` bytes.
pub fn encode(comptime T: type, value: T, out: []u8) void {
    std.debug.assert(out.len == size(T));
    switch (@typeInfo(T)) {
        .bool => out[0] = @intFromBool(value),
        .int => std.mem.writeInt(T, out[0..comptime size(T)], value, .little),
        .float => |f| std.mem.writeInt(@Int(.unsigned, f.bits), out[0..comptime size(T)], @bitCast(value), .little),
        .@"enum" => |e| encode(e.tag_type, @backingInt(value), out),
        .array => |a| for (value, 0..) |v, i| encode(a.child, v, out[i * size(a.child) ..][0..size(a.child)]),
        .@"struct" => |s| {
            comptime var start: usize = 0;
            inline for (s.field_names, s.field_types) |name, ty| {
                encode(ty, @field(value, name), out[start..][0..size(ty)]);
                start += comptime size(ty);
            }
        },
        else => unreachable,
    }
}

/// Reads a `T` from `bytes`. Fails on wrong length or invalid bool/enum values.
pub fn decode(comptime T: type, bytes: []const u8) !T {
    if (bytes.len != size(T)) return error.InvalidWireSize;
    switch (@typeInfo(T)) {
        .bool => return switch (bytes[0]) {
            0 => false,
            1 => true,
            else => error.InvalidWireValue,
        },
        .int => return std.mem.readInt(T, bytes[0..comptime size(T)], .little),
        .float => |f| return @bitCast(std.mem.readInt(@Int(.unsigned, f.bits), bytes[0..comptime size(T)], .little)),
        .@"enum" => |e| return std.enums.fromInt(T, try decode(e.tag_type, bytes)) orelse error.InvalidEnumTag,
        .array => |a| {
            var out: T = undefined;
            for (&out, 0..) |*v, i| v.* = try decode(a.child, bytes[i * size(a.child) ..][0..size(a.child)]);
            return out;
        },
        .@"struct" => |s| {
            var out: T = undefined;
            comptime var start: usize = 0;
            inline for (s.field_names, s.field_types) |name, ty| {
                @field(out, name) = try decode(ty, bytes[start..][0..size(ty)]);
                start += comptime size(ty);
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

test "wire handles signed integers floats enums arrays and nested structs" {
    const Mode = enum(u8) { off = 0, on = 3 };
    const T = struct { signed: i16, ratio: f32, modes: [2]Mode, nested: struct { enabled: bool } };
    const value: T = .{ .signed = -2, .ratio = 1.0, .modes = .{ .off, .on }, .nested = .{ .enabled = false } };
    var bytes: [size(T)]u8 = undefined;
    encode(T, value, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0xff, 0, 0, 0x80, 0x3f, 0, 3, 0 }, &bytes);
    try std.testing.expectEqualDeep(value, try decode(T, &bytes));
    try std.testing.expectError(error.InvalidWireSize, decode(T, bytes[0 .. bytes.len - 1]));
    bytes[7] = 2;
    try std.testing.expectError(error.InvalidEnumTag, decode(T, &bytes));
}

test "wire layout changes with field names types and enum values" {
    const Base = struct { value: u32 };
    try std.testing.expect(layout(Base) != layout(struct { renamed: u32 }));
    try std.testing.expect(layout(Base) != layout(struct { value: i32 }));
    try std.testing.expect(layout(enum(u8) { a = 1 }) != layout(enum(u8) { a = 2 }));
}
