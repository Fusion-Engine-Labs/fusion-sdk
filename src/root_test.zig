const std = @import("std");
const sdk = @import("root.zig");
const abi = sdk.abi;
const wire = sdk.wire;

const Position = struct {
    x: i32 = 7,
    pub const schema_meta = sdk.scene_schema.SchemaMeta{
        .id = "11111111-1111-4111-8111-111111111111",
        .name = "test.position",
        .version = 1,
        .fields = &.{.{ .name = "x", .number = 1 }},
    };
};

const Velocity = struct {
    x: f32 = 1.5,
    pub const schema_meta = sdk.scene_schema.SchemaMeta{
        .id = "22222222-2222-4222-8222-222222222222",
        .name = "test.velocity",
        .version = 1,
        .fields = &.{.{ .name = "x", .number = 1 }},
    };
};

const MockHost = struct {
    register_status: abi.Status = .ok,
    next_status: abi.Status = .ok,
    read_status: abi.Status = .ok,
    write_status: abi.Status = .ok,
    resolve_ids: [2]u32 = .{ 11, 22 },
    resolve_calls: usize = 0,
    register_calls: usize = 0,
    next_calls: usize = 0,
    read_index: u32 = 999,
    write_index: u32 = 999,
    read_bytes: [4]u8 = .{ 7, 0, 0, 0 },
    written_bytes: [4]u8 = undefined,
    registered_name: bool = false,
    seen_layouts: [2]u64 = .{ 0, 0 },
    seen_sizes: [2]u32 = .{ 0, 0 },
    seen_ids: [2][16]u8 = undefined,

    fn table(self: *MockHost) abi.Host {
        return .{
            .context = self,
            .register_component = register,
            .resolve = resolve,
            .next = next,
            .read = read,
            .write = write,
        };
    }

    fn selfFrom(context: *anyopaque) *MockHost {
        return @ptrCast(@alignCast(context));
    }

    fn register(context: *anyopaque, bytes: abi.Bytes) callconv(.c) abi.Status {
        const self = selfFrom(context);
        self.register_calls += 1;
        self.registered_name = std.mem.indexOf(u8, bytes.slice(), "test.position") != null;
        return self.register_status;
    }

    fn resolve(context: *anyopaque, id: *const [16]u8, layout: u64, size: u32) callconv(.c) u32 {
        const self = selfFrom(context);
        const index = self.resolve_calls;
        self.resolve_calls += 1;
        self.seen_layouts[index] = layout;
        self.seen_sizes[index] = size;
        self.seen_ids[index] = id.*;
        return self.resolve_ids[index];
    }

    fn next(context: *anyopaque, cursor: *abi.Cursor, entity: *u64) callconv(.c) abi.Status {
        const self = selfFrom(context);
        self.next_calls += 1;
        if (self.next_status != .ok) return self.next_status;
        if (self.next_calls > 1) return .not_found;
        cursor.row = 1;
        entity.* = 42;
        return .ok;
    }

    fn read(context: *anyopaque, _: *const abi.Cursor, index: u32, out: [*]u8, len: usize) callconv(.c) abi.Status {
        const self = selfFrom(context);
        self.read_index = index;
        if (self.read_status != .ok) return self.read_status;
        std.debug.assert(len == self.read_bytes.len);
        @memcpy(out[0..len], &self.read_bytes);
        return .ok;
    }

    fn write(context: *anyopaque, _: *const abi.Cursor, index: u32, bytes: abi.Bytes) callconv(.c) abi.Status {
        const self = selfFrom(context);
        self.write_index = index;
        std.debug.assert(bytes.len == self.written_bytes.len);
        @memcpy(&self.written_bytes, bytes.slice());
        return self.write_status;
    }
};

fn update(_: sdk.World, frame: *const sdk.Frame) !void {
    if (frame.seconds < 0) return error.BadFrame;
}

const module = sdk.game(&.{Position}, update);
comptime {
    sdk.exportGame(&module);
}
extern fn fusion_get_game() callconv(.c) *const abi.Game;

test "World registers a JSON descriptor and reports host failure" {
    const described = comptime sdk.descriptor.describe(Position);
    try std.testing.expectEqual(wire.layout(Position), described.layout);
    try std.testing.expectEqual(@as(i32, 7), (try wire.decode(Position, described.defaults)).x);
    const empty = comptime sdk.descriptor.describe(sdk.components.ActiveCamera);
    try std.testing.expectEqual(@as(usize, 0), empty.defaults.len);
    try std.testing.expectEqual(@as(usize, 0), empty.schema.fields.len);
    var mock = MockHost{};
    const host = mock.table();
    const world = sdk.World{ .host = &host };
    try world.register(Position);
    try std.testing.expectEqual(@as(usize, 1), mock.register_calls);
    try std.testing.expect(mock.registered_name);

    mock.register_status = .failed;
    try std.testing.expectError(error.HostOperationFailed, world.register(Position));
    try std.testing.expectEqual(@as(usize, 2), mock.register_calls);
}

test "query resolves every term and iterates host rows" {
    var mock = MockHost{};
    const host = mock.table();
    const world = sdk.World{ .host = &host };
    var query = try world.query(.{ .read = &.{Position}, .write = &.{Velocity} });
    try std.testing.expectEqual(@as(usize, 2), mock.resolve_calls);
    try std.testing.expectEqual(@as(u32, 2), query.cursor.count);
    try std.testing.expectEqual(@as(u32, 11), query.cursor.ids[0]);
    try std.testing.expectEqual(@as(u32, 22), query.cursor.ids[1]);
    try std.testing.expectEqual(wire.layout(Position), mock.seen_layouts[0]);
    try std.testing.expectEqual(wire.layout(Velocity), mock.seen_layouts[1]);
    try std.testing.expectEqual(@as(u32, @intCast(wire.size(Position))), mock.seen_sizes[0]);
    try std.testing.expectEqual(@as(u32, @intCast(wire.size(Velocity))), mock.seen_sizes[1]);
    try std.testing.expectEqual(sdk.schema.deriveSchema(Position).id.uuid.bytes, mock.seen_ids[0]);
    try std.testing.expectEqual(sdk.schema.deriveSchema(Velocity).id.uuid.bytes, mock.seen_ids[1]);

    const row = (try query.each()).?;
    try std.testing.expectEqual(@as(u64, 42), row.entity);
    try std.testing.expectEqual(@as(i32, 7), (try row.read(Position)).x);
    try std.testing.expectEqual(@as(u32, 0), mock.read_index);
    try row.write(Velocity, .{ .x = 2.5 });
    try std.testing.expectEqual(@as(u32, 1), mock.write_index);
    try std.testing.expectEqual(@as(f32, 2.5), (try wire.decode(Velocity, &mock.written_bytes)).x);
    try std.testing.expect((try query.each()) == null);
}

test "query and row propagate host and wire errors" {
    var mock = MockHost{};
    const host = mock.table();
    const world = sdk.World{ .host = &host };

    mock.resolve_ids[0] = 0;
    try std.testing.expectError(error.IncompatibleComponent, world.query(.{ .read = &.{Position} }));
    mock.resolve_ids[0] = 11;
    mock.resolve_calls = 0;

    var query = try world.query(.{ .read = &.{Position}, .write = &.{Velocity} });
    mock.next_status = .failed;
    try std.testing.expectError(error.HostOperationFailed, query.each());
    mock.next_status = .ok;
    mock.next_calls = 0;
    const row = (try query.each()).?;

    mock.read_status = .invalid_argument;
    try std.testing.expectError(error.HostOperationFailed, row.read(Position));
    mock.read_status = .ok;
    mock.write_status = .failed;
    try std.testing.expectError(error.HostOperationFailed, row.write(Velocity, .{ .x = 3 }));
}

test "game table forwards registration and update results" {
    try std.testing.expectEqual(&module, fusion_get_game());
    try std.testing.expectEqual(abi.version, module.version);
    try std.testing.expectEqual(@as(u32, @sizeOf(abi.Game)), module.size);

    var mock = MockHost{};
    const host = mock.table();
    try std.testing.expectEqual(abi.Status.ok, module.register_components(&host));
    try std.testing.expectEqual(@as(usize, 1), mock.register_calls);
    mock.register_status = .failed;
    try std.testing.expectEqual(abi.Status.failed, module.register_components(&host));

    try std.testing.expectEqual(abi.Status.ok, module.fixed_update(&host, &.{ .seconds = 0.1 }));
    try std.testing.expectEqual(abi.Status.failed, module.fixed_update(&host, &.{ .seconds = -1 }));
}
