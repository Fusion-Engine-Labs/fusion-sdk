//! Fusion SDK: write gameplay code as a native library the Fusion engine loads.
//!
//! A game is one `update` function plus the component types it owns:
//!
//! ```zig
//! const sdk = @import("fusion_sdk");
//!
//! const Movement = struct {
//!     speed: f32 = 1,
//!
//!     pub const schema_meta = sdk.scene_schema.SchemaMeta{
//!         .id = "0f6d3a52-1c1e-4c8e-9a51-2b7f0d6e4a10", // any fixed UUID
//!         .name = "my_game.movement",
//!         .version = 1,
//!         .fields = &.{.{ .name = "speed", .number = 1 }},
//!     };
//! };
//!
//! const module = sdk.game(&.{Movement}, update);
//! comptime {
//!     sdk.exportGame(&module);
//! }
//!
//! fn update(world: sdk.World, frame: *const sdk.Frame) !void {
//!     var query = try world.query(.{
//!         .read = &.{Movement},
//!         .write = &.{sdk.components.TransformComponent},
//!     });
//!     while (try query.each()) |row| {
//!         const movement = try row.read(Movement);
//!         var transform = try row.read(sdk.components.TransformComponent);
//!         transform.position.x += movement.speed * frame.seconds;
//!         try row.write(sdk.components.TransformComponent, transform);
//!     }
//! }
//! ```
//!
//! Start with `game`, `World`, and `Query`. The other modules describe the
//! host boundary and are rarely needed directly.

const std = @import("std");

/// Component descriptors sent to the host at registration.
pub const descriptor = @import("descriptor.zig");
/// Built-in engine components.
pub const components = @import("components.zig");
/// Editor/serialization schemas derived from `schema_meta`.
pub const schema = @import("schema.zig");
/// Byte encoding used to copy components across the boundary.
pub const wire = @import("wire.zig");
/// Vectors, matrices, and quaternions.
pub const math = @import("math.zig");
/// C ABI shared by the host and the game library.
pub const abi = @import("abi.zig");

/// Keyboard key codes.
pub const Key = @import("key.zig").Key;
/// Per-tick input passed to `update`.
pub const Frame = abi.Frame;
pub const Vec3 = math.Vec3;
pub const Quat = math.Quat;

/// Types needed to declare a component's `schema_meta`.
pub const scene_schema = struct {
    pub const SchemaMeta = @import("zimp").scene.SchemaMeta;
};

/// Access to the host's ECS during a callback. Only valid for that callback.
pub const World = struct {
    host: *const abi.Host,

    /// Registers component `T` with the host. `game` calls this for you.
    pub fn register(self: World, comptime T: type) !void {
        const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, descriptor.describe(T), .{});
        defer std.heap.page_allocator.free(json);

        try check(self.host.register_component(self.host.context, abi.Bytes.from(json)));
    }

    fn resolve(self: World, comptime T: type) !u32 {
        const desc = comptime schema.deriveSchema(T);

        const id = self.host.resolve(self.host.context, &desc.id.uuid.bytes, wire.layout(T), comptime wire.size(T));
        if (id == 0) {
            return error.IncompatibleComponent;
        }
        return id;
    }

    /// Starts a query over every entity that has all `spec` components.
    /// Fails with `error.IncompatibleComponent` if the host's copy of a
    /// component has a different layout.
    pub fn query(self: World, comptime spec: QuerySpec) !Query(spec) {
        const types = spec.read ++ spec.write;
        var q: Query(spec) = .{
            .world = self,
            .cursor = .{ .count = types.len, .ids = @splat(0) },
        };

        inline for (types, 0..) |T, i| {
            q.cursor.ids[i] = try self.resolve(T);
        }
        return q;
    }
};

/// Components a query reads and writes. Entities must have all of them.
pub const QuerySpec = struct {
    /// Readable components.
    read: []const type = &.{},
    /// Readable and writable components.
    write: []const type = &.{},
};

/// An iterator over matching entities. Create one with `World.query`.
pub fn Query(comptime spec: QuerySpec) type {
    const types = spec.read ++ spec.write;
    if (types.len == 0 or types.len > abi.max_query_terms) {
        @compileError(std.fmt.comptimePrint("query needs 1..{d} component types", .{abi.max_query_terms}));
    }

    return struct {
        world: World,
        cursor: abi.Cursor,

        /// Advances to the next matching entity, or returns `null` when done.
        /// The previous `Row` becomes invalid.
        pub fn each(self: *@This()) !?Row {
            var entity: u64 = undefined;
            const result = self.world.host.next(self.world.host.context, &self.cursor, &entity);
            if (result == .not_found) {
                return null;
            }

            try check(result);
            return .{ .query = self, .entity = entity };
        }

        fn index(comptime T: type) usize {
            inline for (types, 0..) |Type, i| {
                if (Type == T) return i;
            }
            @compileError("component is not in the query");
        }

        /// One matching entity. Valid until the next `each`.
        pub const Row = struct {
            query: *Query(spec),
            /// Host entity handle.
            entity: u64,

            /// Returns a copy of component `T`. Changes need `write` to take effect.
            pub fn read(self: Row, comptime T: type) !T {
                var bytes: [wire.size(T)]u8 = undefined;
                const host = self.query.world.host;
                try check(host.read(host.context, &self.query.cursor, comptime index(T), &bytes, bytes.len));

                return wire.decode(T, &bytes);
            }

            /// Stores `value` as this entity's `T`. `T` must be in `spec.write`.
            pub fn write(self: Row, comptime T: type, value: T) !void {
                comptime for (spec.write) |Type| {
                    if (Type == T) break;
                } else @compileError("component is not writable in this query");

                var bytes: [wire.size(T)]u8 = undefined;
                wire.encode(T, value, &bytes);
                const host = self.query.world.host;
                try check(host.write(host.context, &self.query.cursor, comptime index(T), abi.Bytes.from(&bytes)));
            }
        };
    };
}

fn check(status: abi.Status) !void {
    if (status != .ok) {
        return error.HostOperationFailed;
    }
}

/// Builds the game table from the components the game owns and its
/// fixed-step `update`. Errors from `update` are logged and reported to the host.
pub fn game(comptime component_types: []const type, comptime update: fn (World, *const Frame) anyerror!void) abi.Game {
    const Impl = struct {
        fn register(host: *const abi.Host) callconv(.c) abi.Status {
            const world: World = .{ .host = host };
            inline for (component_types) |T| world.register(T) catch |err| {
                std.debug.print("game registration: {s}\n", .{@errorName(err)});
                return .failed;
            };
            return .ok;
        }

        fn tick(host: *const abi.Host, frame: *const Frame) callconv(.c) abi.Status {
            update(.{ .host = host }, frame) catch |err| {
                std.debug.print("game update: {s}\n", .{@errorName(err)});
                return .failed;
            };
            return .ok;
        }
    };
    return .{
        .register_components = Impl.register,
        .fixed_update = Impl.tick,
    };
}

/// Exports `module` as the library entry point. Call from a `comptime` block.
pub fn exportGame(comptime module: *const abi.Game) void {
    const Entry = struct {
        fn get() callconv(.c) *const abi.Game {
            return module;
        }
    };
    @export(&Entry.get, .{ .name = abi.entry_symbol });
}

test {
    refAllDeclsRecursive(@This());
    inline for (.{ descriptor, components, schema, wire, math, abi, @import("key.zig") }) |file| {
        refAllDeclsRecursive(file);
    }
}

/// Like `std.testing.refAllDecls`, but also descends into container types
/// declared inside `T`. Aliases to types defined elsewhere (dependencies,
/// sibling files) are referenced but not descended into.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        const value = @field(T, decl.name);
        if (@TypeOf(value) == type) {
            switch (@typeInfo(value)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => {
                    const prefix = @typeName(T) ++ ".";
                    if (comptime std.mem.startsWith(u8, @typeName(value), prefix)) {
                        refAllDeclsRecursive(value);
                    }
                },
                else => {},
            }
        }
        _ = &value;
    }
}
