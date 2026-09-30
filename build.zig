const std = @import("std");

pub fn build(b: *std.Build) void {
  const target   = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target           = target,
    .optimize         = optimize,
    .imports          = &.{},
  });

  const exe = b.addExecutable(.{
    .name        = "shutter",
    .root_module = exe_mod,
  });
  b.installArtifact(exe);
  const run_cmd = b.addRunArtifact(exe);
  run_cmd.step.dependOn(b.getInstallStep());
  if (b.args) |args| run_cmd.addArgs(args);
  const run_step = b.step("run", "Run the app");
  run_step.dependOn(&run_cmd.step);

  const gen_wayland = b.addExecutable(.{
    .name = "gen_wayland",
    .root_module = b.createModule(.{
      .root_source_file = b.path("src/gen_wayland.zig"),
      .target = target,
      .optimize = optimize,
    }),
  });
  const gen_wayland_run = b.addRunArtifact(gen_wayland);
  gen_wayland_run.setCwd(b.path("."));
  const gen_wayland_step = b.step("gen_wayland", "Generate src/wayland.zig from thirdparty/*.xml");
  gen_wayland_step.dependOn(&gen_wayland_run.step);

  const test_step = b.step("test", "Run unit tests");
  for ([_][]const u8{ "src/wayland.zig", "src/gen_wayland.zig" }) |path| {
    const tests = b.addTest(.{
      .root_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
      }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
  }
}
