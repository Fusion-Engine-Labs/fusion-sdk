//! The C ABI between the host engine and a game library.
//!
//! The game exports `entry_symbol`, which returns its `Game` table. The host
//! calls into that table and passes a `Host` table back for ECS access.
//! Pointers passed to a callback are only valid during that callback.

/// Bumped on any breaking ABI change. The host rejects mismatched games.
pub const version: u32 = 3;
/// Largest encoded component, in bytes.
pub const max_component_size = 4096;
/// Largest registration descriptor, in bytes.
pub const max_descriptor_size = 64 * 1024;
/// Most components a single query can name.
pub const max_query_terms = 16;

/// Length of `Frame.keys`.
pub const key_count = @intFromEnum(@import("key.zig").Key.Menu) + 1;

/// Result of every host and game callback.
pub const Status = enum(u32) {
    ok,
    failed,
    incompatible,
    invalid_argument,
    /// Also means "no more rows" from `Host.next`.
    not_found,
};

/// A borrowed byte slice that can cross the C ABI.
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

/// Input for one fixed update.
pub const Frame = extern struct {
    /// Simulation time step, in seconds.
    seconds: f32 = 0,
    /// Nonzero while held, indexed by `Key` value. Prefer `isKeyDown`.
    keys: [key_count]u8 = @splat(0),

    /// True while `key` is held.
    pub fn isKeyDown(self: *const Frame, key: @import("key.zig").Key) bool {
        return self.keys[@intFromEnum(key)] != 0;
    }
};

/// Functions the host provides to the game. `World` wraps these.
pub const Host = extern struct {
    context: *anyopaque,
    register_component: *const fn (*anyopaque, Bytes) callconv(.c) Status,
    resolve: *const fn (*anyopaque, *const [16]u8, u64, u32) callconv(.c) u32,
    next: *const fn (*anyopaque, *Cursor, *u64) callconv(.c) Status,
    read: *const fn (*anyopaque, *const Cursor, u32, [*]u8, usize) callconv(.c) Status,
    write: *const fn (*anyopaque, *const Cursor, u32, Bytes) callconv(.c) Status,
};

/// Functions the game provides to the host. Build one with `game`.
pub const Game = extern struct {
    version: u32 = version,
    size: u32 = @sizeOf(Game),
    /// Called once after load.
    register_components: *const fn (*const Host) callconv(.c) Status,
    /// Called every fixed simulation step.
    fixed_update: *const fn (*const Host, *const Frame) callconv(.c) Status,
};

/// Name of the exported function returning the `Game` table.
pub const entry_symbol = "fusion_get_game";
/// Type of the `entry_symbol` function.
pub const GetGame = *const fn () callconv(.c) *const Game;
