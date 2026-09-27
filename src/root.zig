const std = @import("std");

pub const descriptor = @import("descriptor.zig");
pub const components = @import("components.zig");
pub const schema = @import("schema.zig");
pub const wire = @import("wire.zig");
pub const math = @import("math.zig");
pub const abi = @import("abi.zig");

pub const Key = @import("key.zig").Key;
pub const Frame = abi.Frame;
pub const Vec3 = math.Vec3;
pub const Quat = math.Quat;

pub const scene_schema = struct {
    pub const SchemaMeta = @import("zimp").scene.SchemaMeta;
};

pub const World = struct {
    host: *const abi.Host,

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

pub const QuerySpec = struct {
    read: []const type = &.{},
    write: []const type = &.{},
};

pub fn Query(comptime spec: QuerySpec) type {
    const types = spec.read ++ spec.write;
    if (types.len == 0 or types.len > abi.max_query_terms) {
        @compileError(std.fmt.comptimePrint("query needs 1..{d} component types", .{abi.max_query_terms}));
    }

    return struct {
        world: World,
        cursor: abi.Cursor,

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

        pub const Row = struct {
            query: *Query(spec),
            entity: u64,
            pub fn read(self: Row, comptime T: type) !T {
                var bytes: [wire.size(T)]u8 = undefined;
                const host = self.query.world.host;
                try check(host.read(host.context, &self.query.cursor, comptime index(T), &bytes, bytes.len));

                return wire.decode(T, &bytes);
            }

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

pub fn exportGame(comptime module: *const abi.Game) void {
    const Entry = struct {
        fn get() callconv(.c) *const abi.Game {
            return module;
        }
    };
    @export(&Entry.get, .{ .name = abi.entry_symbol });
}

test {
    std.testing.refAllDecls(@This());
}
