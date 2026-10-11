const std = @import("std");

pub const addProjectCookStep = @import("zimp").addProjectCookStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("fusion_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zlm_mod = b.dependency("zlm", .{ .target = target, .optimize = optimize }).module("zlm");
    const zimp_mod = b.dependency("zimp", .{ .target = target, .optimize = optimize }).module("zimp");
    mod.addImport("zlm", zlm_mod);
    mod.addImport("zimp", zimp_mod);

    b.modules.put(b.graph.arena, b.dupe("zimp"), zimp_mod) catch @panic("OOM");

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const check_step = b.step("check", "Compile all code without running tests");
    check_step.dependOn(&mod_tests.step);

    const docs_lib = b.addLibrary(.{
        .name = "fusion_sdk_docs",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
