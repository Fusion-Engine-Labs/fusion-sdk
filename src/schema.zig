//! Derives a component's editor/serialization schema from its `schema_meta`.
//!
//! Every field needs a `schema_meta` entry and a default value (a Zig default
//! or `default_override`). Types without an obvious kind (such as asset IDs)
//! need a `kind_override`. Mistakes are compile errors.

const zimp = @import("zimp");
const std = @import("std");

const math = @import("math.zig");

const id_types = zimp.id.types;
const FieldKind = zimp.scene.FieldKind;
const Value = zimp.scene.Value;

fn autoFieldKind(comptime FT: type) ?FieldKind {
    return switch (FT) {
        i32 => .i32,
        u32 => .u32,
        f32 => .f32,
        bool => .bool,
        math.Vec2 => .vec2,
        math.Vec3 => .vec3,
        math.Quat => .quat,
        []const u8 => .string,
        id_types.SceneEntityId => .entity_ref,
        else => null,
    };
}

/// Wraps a raw field value as a schema `Value` of the given kind.
pub fn toValue(comptime kind: std.meta.Tag(FieldKind), raw: anytype) Value {
    return switch (kind) {
        .i32 => .{ .i32 = raw },
        .u32 => .{ .u32 = raw },
        .f32 => .{ .f32 = raw },
        .bool => .{ .bool = raw },
        .vec2 => .{ .vec2 = .{ raw.x, raw.y } },
        .vec3 => .{ .vec3 = .{ raw.x, raw.y, raw.z } },
        .quat => .{ .quat = .{ raw.x, raw.y, raw.z, raw.w } },
        .string => .{ .string = raw },
        .asset_ref => .{ .asset_ref = raw },
        .entity_ref => .{ .entity_ref = raw },
        else => @compileError("unsupported derived kind: " ++ @tagName(kind)),
    };
}

const StructField = struct {
    name: [:0]const u8,
    type: type,
    attrs: std.builtin.Type.Struct.FieldAttributes,
};

/// Returns a struct field's Zig default value, if it has one.
pub fn structFieldDefault(comptime sf: StructField) ?sf.type {
    return sf.attrs.defaultValue(sf.type);
}

/// A struct field paired with its `schema_meta` entry.
pub const PersistedField = struct {
    name: [:0]const u8,
    number: u32,
    kind: FieldKind,
    sf: StructField,
    meta: zimp.scene.FieldMeta,

    /// All fields of `T` in declaration order. Validates `T.schema_meta`.
    pub fn Fields(comptime T: type) []const PersistedField {
        const meta: zimp.scene.SchemaMeta = T.schema_meta;
        const struct_info = @typeInfo(T).@"struct";
        comptime {
            // every meta entry must name a real field
            for (meta.fields) |fm| {
                for (struct_info.field_names) |name| {
                    if (std.mem.eql(u8, fm.name, name)) {
                        break;
                    }
                } else @compileError(@typeName(T) ++ ".schema_meta names unknown field '" ++ fm.name ++ "'");
            }

            var out: []const PersistedField = &.{};
            for (struct_info.field_names, struct_info.field_types, struct_info.field_attrs) |name, FieldType, attrs| {
                const entry: zimp.scene.FieldMeta = for (meta.fields) |fm| {
                    if (std.mem.eql(u8, name, fm.name)) {
                        break fm;
                    }
                } else @compileError(@typeName(T) ++ ".schema_meta is missing field '" ++ name ++ "' (add an entry or mark it transient)");

                const kind = entry.kind_override orelse (autoFieldKind(FieldType) orelse
                    @compileError(@typeName(T) ++ "." ++ name ++ ": type " ++ @typeName(FieldType) ++
                        " needs a kind_override (AssetId fields must declare their asset kind)"));

                for (out) |prev| {
                    if (prev.number == entry.number) {
                        @compileError(@typeName(T) ++ ".schema_meta '" ++ name ++ "' has duplicate number '" ++ entry.number ++ "'");
                    }
                }

                out = out ++ .{PersistedField{
                    .name = name,
                    .number = entry.number,
                    .kind = kind,
                    .sf = .{ .name = name, .type = FieldType, .attrs = attrs },
                    .meta = entry,
                }};
            }

            return out;
        }
    }
};

/// Builds the full component schema for `T`.
pub fn deriveSchema(comptime T: type) zimp.scene.ComponentSchema {
    const meta: zimp.scene.SchemaMeta = T.schema_meta;
    const pfs = comptime PersistedField.Fields(T);

    const frozen = comptime blk: {
        var fields: [pfs.len]zimp.scene.FieldSchema = undefined;
        for (pfs, 0..) |pf, i| {
            const default_value = dv: {
                if (pf.meta.default_override) |v| {
                    break :dv v;
                }

                if (structFieldDefault(pf.sf)) |raw| {
                    break :dv toValue(std.meta.activeTag(pf.kind), raw);
                }

                @compileError(@typeName(T) ++ "." ++ pf.name ++
                    ": no Zig default value and no default_override in schema_meta");
            };

            fields[i] = .{
                .number = pf.number,
                .name = pf.name,
                .display_name = pf.meta.display_name orelse pf.name,
                .kind = pf.kind,
                .default_value = default_value,
                .editor = pf.meta.editor,
            };
        }

        break :blk fields;
    };

    return .{
        .id = id_types.ComponentTypeId.parseComptime(meta.id),
        .name = meta.name,
        .display_name = meta.display_name orelse meta.name,
        .version = meta.version,
        .fields = &frozen,
    };
}

test "derive schemas from Zig defaults and metadata overrides" {
    const components = @import("components.zig");
    const camera = comptime deriveSchema(components.CameraComponent);
    const mesh = comptime deriveSchema(components.MeshRenderComponent);

    try std.testing.expectEqual(@as(usize, 3), camera.fields.len);
    try std.testing.expectEqual(@as(f32, std.math.pi / 4.0), camera.fields[0].default_value.f32);
    try std.testing.expectEqual(@as(usize, 1), mesh.fields.len);
    try std.testing.expectEqual(id_types.AssetId.zero, mesh.fields[0].default_value.asset_ref);
}
