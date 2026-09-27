const zimp = @import("zimp");

const schema = @import("schema.zig");
const wire = @import("wire.zig");

pub const Descriptor = struct {
    schema: zimp.scene.ComponentSchema,
    layout: u64,
    /// Fields packed in `schema.fields` order, as `wire` encodes them.
    defaults: []const u8,
};

pub fn describe(comptime T: type) Descriptor {
    const defaults = comptime blk: {
        var bytes: [wire.size(T)]u8 = undefined;
        wire.encode(T, T{}, &bytes);
        break :blk bytes;
    };

    comptime for (schema.PersistedField.Fields(T)) |f| {
        if (f.meta.transient) {
            @compileError("SDK game components do not support transient fields yet");
        }
        switch (f.kind) {
            .string, .enum_ref => @compileError("SDK game components currently support only fixed-size scalar, vector, and ID fields"),
            else => {},
        }
    };
    return .{
        .schema = schema.deriveSchema(T),
        .layout = wire.layout(T),
        .defaults = &defaults,
    };
}
