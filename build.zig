const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("spice", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const parg = b.dependency("parg", .{});

    const example = b.addExecutable(.{
        .name = "spice-example",
        .root_source_file = b.path("examples/zig-parallel-example/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("spice", mod);
    example.root_module.addImport("parg", parg.module("parg"));

    b.installArtifact(example);
}
