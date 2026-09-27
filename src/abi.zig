pub const version: u32 = 3;
pub const max_component_size = 4096;
pub const max_descriptor_size = 64 * 1024;
pub const max_query_terms = 16;

pub const key_count = @intFromEnum(@import("key.zig").Key.Menu) + 1;

pub const Status = enum(u32) {
    ok,
    failed,
    incompatible,
    invalid_argument,
    not_found,
};

pub const Bytes = extern struct {
    ptr: [*]const u8,
    len: usize,
    pub fn from(bytes: []const u8) Bytes {
        return .{ .ptr = bytes.ptr, .len = bytes.len };
    }

    pub fn slice(self: Bytes) []const u8 {
        return self.ptr[0..self.len];
    }
};

/// Query state owned by the game and advanced by the host. `read` and `write`
/// address the row most recently returned by `next`.
pub const Cursor = extern struct {
    count: u32,
    ids: [max_query_terms]u32,
    archetype: u32 = 0,
    chunk: u32 = 0,
    /// One past the row most recently returned by `next`.
    row: u32 = 0,
    /// Host cache for the current archetype: each term's column and change-tick slot.
    columns: [max_query_terms]u32 = @splat(0),
    ticks: [max_query_terms]u32 = @splat(0),
};

pub const Frame = extern struct {
    seconds: f32 = 0,
    keys: [key_count]u8 = @splat(0),
    pub fn isKeyDown(self: *const Frame, key: @import("key.zig").Key) bool {
        return self.keys[@intFromEnum(key)] != 0;
    }
};

pub const Host = extern struct {
    context: *anyopaque,
    register_component: *const fn (*anyopaque, Bytes) callconv(.c) Status,
    resolve: *const fn (*anyopaque, *const [16]u8, u64, u32) callconv(.c) u32,
    next: *const fn (*anyopaque, *Cursor, *u64) callconv(.c) Status,
    read: *const fn (*anyopaque, *const Cursor, u32, [*]u8, usize) callconv(.c) Status,
    write: *const fn (*anyopaque, *const Cursor, u32, Bytes) callconv(.c) Status,
};

pub const Game = extern struct {
    version: u32 = version,
    size: u32 = @sizeOf(Game),
    register_components: *const fn (*const Host) callconv(.c) Status,
    fixed_update: *const fn (*const Host, *const Frame) callconv(.c) Status,
};

pub const entry_symbol = "fusion_get_game";
pub const GetGame = *const fn () callconv(.c) *const Game;
