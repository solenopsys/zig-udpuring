const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Create the library
    const lib = b.addStaticLibrary(.{
        .name = "udp",
        .root_source_file = b.path("src/udp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependency for the library
    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    lib.root_module.addImport("xev", xev.module("xev"));

    // Install the library
    b.installArtifact(lib);

    // Create an executable
    const exe = b.addExecutable(.{
        .name = "udp_uring",
        .root_source_file = b.path("src/rps.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependency for the executable
    exe.root_module.addImport("xev", xev.module("xev"));

    // Link the library to the executable
    exe.linkLibrary(lib);

    // Install the executable
    b.installArtifact(exe);

    // Setup run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // If the user provides arguments when running `zig build run`, pass them to the executable
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Add tests if needed
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/udp.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.root_module.addImport("xev", xev.module("xev"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Add run step
    const run_step = b.step("run", "Run the UDP server");
    run_step.dependOn(&run_cmd.step);
}
