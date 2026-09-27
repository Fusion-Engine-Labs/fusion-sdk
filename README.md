# Fusion SDK

A small Zig gameplay SDK for independently built native game libraries. A
ReleaseFast editor/runtime can load a Debug game using the same SDK ABI.

Component types, math, keyboard keys, and schema derivation are defined here
once. The runtime re-exports these exact definitions. Game code imports
`fusion_sdk`, not `fusion_runtime`.

## Boundary

`abi.zig` defines the C-compatible host/game function tables. Export the game table
with `comptime { sdk.exportGame(&module); }`; the host rejects a library built
against a different ABI version.
Host tables and frame pointers are borrowed for the current callback only.

`wire.zig` derives a canonical little-endian byte representation from ordinary
Zig values. It encodes fields in declaration order, recursively, without native
padding or addresses. A generated layout fingerprint checks component resolution.
There are no second declarations of built-in components and no requirement to
convert gameplay structs to `extern struct`.

The host owns the ECS, allocators, schemas, and codecs. Custom component schemas
are derived from `schema_meta`, sent as JSON once during registration, and copied
into host-owned storage. The descriptor carries the schema and packed defaults;
the host derives field positions from the schema's field order. Inspector edits
and scene serialization execute entirely in the host.
JSON is not used for gameplay reads or writes.

## Gameplay

Use `sdk.game(&.{MyComponent}, update)` to construct the game table. The update
function receives `sdk.World` and `*const sdk.Frame`. Export it with
`sdk.exportGame`, as shown in `sandbox-game/src/root.zig`.

```zig
var query = try world.query(.{
    .read = &.{Movement},
    .write = &.{sdk.components.TransformComponent},
});
while (try query.each()) |row| {
    const movement = try row.read(Movement);
    var transform = try row.read(sdk.components.TransformComponent);
    transform.position.x += movement.speed * frame.seconds;
    try row.write(sdk.components.TransformComponent, transform);
}
```

Reads return values; writes explicitly commit them. A row is valid until the
next `each`. No component pointers or ECS objects cross the library boundary. Only types in the query's write set can be
written through its typed API. The host records normal ECS change ticks.

## MVP scope

- Existing built-in components use their original definitions and methods.
- Game components use default-initializable, fixed-size fields: bool, i32, u32,
  f32, Vec2, Vec3, Quat, asset IDs, and scene entity IDs with existing schema hints.
- Game-owned strings, containers, pointers, custom enums, and transient fields
  are not supported in registered component schemas yet.
- Queries match all declared read/write types. Input exposes held keyboard keys
  and simulation delta time. There are no structural commands, resource API,
  reload hooks, or game-state lifecycle hooks in this increment. Project switching
  is disabled while a game library is bound.
- Queries copy component values and make host calls per read/write. This trades
  throughput for a small boundary; batch access can be added without duplicating
  component definitions.
- Native library loading currently supports Linux and macOS; Linux is tested.
  Native panics still terminate the host process.

Use the SDK and dependency versions shipped with the engine. Layout checks and
ABI negotiation validate this contract, not arbitrary native Zig compatibility.

Run SDK tests with `zig build test`. See the sandbox README for the mixed-mode
build and integration-test commands.
