const std = @import("std");

pub const abi_version: u32 = 1;

// 'F' 'U' 'Z', 0
pub const magic = 0x4655_5A00;

pub const Header = extern struct {
    magic: u32 = magic,
    version: u32 = abi_version,
    struct_size: u32,
    reserved: u32 = 0,
};

// Borrowed immutable pointer/count view.
pub const Bytes = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub const empty: Bytes = .{};

    pub fn fromSlice(slice: []const u8) Bytes {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }

    pub fn asSlice(self: Bytes) ?[]const u8 {
        if (self.len == 0) {
            return &.{};
        }

        const ptr = self.ptr orelse return null;
        return ptr[0..self.len];
    }
};

// Borrorwed mutable pointer/count view.
pub const MutBytes = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,

    pub const empty: MutBytes = .{};

    pub fn fromSlice(slice: []u8) MutBytes {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }

    pub fn asSlice(self: MutBytes) ?[]u8 {
        if (self.len == 0) {
            return &.{};
        }

        const ptr = self.ptr orelse return null;
        return ptr[0..self.len];
    }
};

pub const Uuid = extern struct {
    bytes: [16]u8,

    pub const zero: Uuid = .{ .bytes = [_]u8{0} ** 16 };

    pub fn eql(self: Uuid, other: Uuid) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn isZero(self: Uuid) bool {
        return self.eql(zero);
    }

    /// Parse canonical `8-4-4-4-12` lowercase or uppercase text
    pub fn parseComptime(comptime text: []const u8) Uuid {
        const parsed = comptime blk: {
            if (text.len != 36) {
                @compileError("uuid must be 36 characters: " ++ text);
            }

            var out: [16]u8 = undefined;
            var byte: usize = 0;
            var i: usize = 0;
            while (i < text.len) {
                if (i == 8 or i == 13 or i == 18 or i == 23) {
                    if (text[i] != '-') {
                        @compileError("uuid is missing a dash: " ++ text);
                    }
                    i += 1;
                    continue;
                }
                out[byte] = (nibble(text[i]) << 4) | nibble(text[i + 1]);
                byte += 1;
                i += 2;
            }
            break :blk out;
        };
        return .{ .bytes = parsed };
    }

    fn nibble(comptime ch: u8) u8 {
        return switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => @compileError("uuid contains a non-hex character"),
        };
    }
};

pub const Entity = u64;
pub const ComponentId = u32;

pub const Result = enum(u32) {
    ok = 0,
    result = 1,
    invalid_argument = 2,
    invalid_handle = 3,
    not_found = 4,
    incompatible = 5,
    out_of_memory = 6,
    query_conflict = 7,
    limit_exceeded = 8,
    _,
};

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Vec2 = .{};
};

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};
    pub const one: Vec3 = .{ .x = 1, .y = 1, .z = 1 };
};

pub const Quat = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quat = .{};
};

pub const limits = struct {
    pub const max_custom_components: u32 = 1024;
    pub const max_fields_per_component: u32 = 256;
    pub const max_component_size: u32 = 4096;
    pub const max_component_alignment: u32 = 64;
    pub const max_query_terms: u32 = 64;
    pub const max_copied_metadata_bytes: usize = 4 * 1024 * 1024;
};

pub fn viewIsValid(ptr: ?*const anyopaque, count: usize, stride: usize) bool {
    if (count == 0) {
        return true;
    }

    if (ptr == null) {
        return false;
    }

    const total = std.math.mul(usize, count, stride) catch return false;
    return total <= std.math.maxInt(isize);
}

pub fn addrIsAligned(addr: usize, alignment: u32) bool {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
        return false;
    }

    return addr % alignment == 0;
}

pub fn validateHeader(header: *const Header, expected_size: usize) Result {
    if (header.magic != magic) {
        return .incompatible;
    }

    if (header.version != abi_version) {
        return .incompatible;
    }

    if (header.struct_size != expected_size) {
        return .incompatible;
    }

    if (header.reserved != 0) {
        return .incompatible;
    }

    return .ok;
}

const testing = std.testing;

test "Header validation rejects wrong magic, revision, size, and reserved bits" {
    const good: Header = .{ .struct_size = 16 };
    try testing.expectEqual(Result.ok, validateHeader(&good, 16));

    var bad = good;
    bad.magic = 0;
    try testing.expectEqual(Result.incompatible, validateHeader(&bad, 16));

    bad = good;
    bad.version = abi_version + 1;
    try testing.expectEqual(Result.incompatible, validateHeader(&bad, 16));

    bad = good;
    try testing.expectEqual(Result.incompatible, validateHeader(&bad, 24));

    bad = good;
    bad.reserved = 1;
    try testing.expectEqual(Result.incompatible, validateHeader(&bad, 16));
}

test "empty views may be null but positive counts may not" {
    try testing.expect(viewIsValid(null, 0, 4));
    try testing.expect(!viewIsValid(null, 1, 4));

    var storage: [4]u8 = .{ 1, 2, 3, 4 };
    try testing.expect(viewIsValid(&storage, 4, 1));
    try testing.expect(!viewIsValid(&storage, std.math.maxInt(usize), 2));
}

test "Bytes round-trips a slice and normalizes an empty view" {
    const source = "fusion";
    const view = Bytes.fromSlice(source);
    try testing.expectEqualStrings(source, view.asSlice().?);
    try testing.expectEqual(@as(usize, 0), Bytes.empty.asSlice().?.len);
    const dangling: Bytes = .{ .ptr = null, .len = 3 };
    try testing.expect(dangling.asSlice() == null);
}

test "MutBytes round-trips a mutable slice" {
    var storage: [3]u8 = .{ 0, 0, 0 };
    const view = MutBytes.fromSlice(&storage);
    view.asSlice().?[1] = 7;
    try testing.expectEqual(@as(u8, 7), storage[1]);
    const dangling: MutBytes = .{ .ptr = null, .len = 1 };
    try testing.expect(dangling.asSlice() == null);
}

test "addrIsAligned rejects zero and non-power-of-two alignments" {
    try testing.expect(addrIsAligned(64, 64));
    try testing.expect(!addrIsAligned(63, 64));
    try testing.expect(!addrIsAligned(0, 0));
    try testing.expect(!addrIsAligned(0, 3));
}

test "Uuid.parseComptime matches the canonical byte order" {
    const id = Uuid.parseComptime("7fb84f38-52b6-4fd9-8c2f-fbd08c7a9001");
    try testing.expectEqual(@as(u8, 0x7f), id.bytes[0]);
    try testing.expectEqual(@as(u8, 0x52), id.bytes[4]);
    try testing.expectEqual(@as(u8, 0x01), id.bytes[15]);
    try testing.expect(!id.isZero());
    try testing.expect(Uuid.zero.isZero());
}
