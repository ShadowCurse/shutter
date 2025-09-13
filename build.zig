const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("shutter", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shutter", .module = lib_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "shutter",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{
        .name = "unit_tests",
        .root_module = lib_mod,
        .filters = b.args orelse &.{},
    });
    b.installArtifact(lib_tests);
    const run_lib_unit_tests = b.addRunArtifact(lib_tests);
    run_lib_unit_tests.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
