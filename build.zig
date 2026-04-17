const std = @import("std");

pub fn build(b: *std.Build) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const cwd_realpath = try cwd.realpathAlloc(alloc, ".");
    defer alloc.free(cwd_realpath);

    // const project_name = std.fs.path.basename(cwd_realpath);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimdjson_dep = b.dependency("zimdjson", .{
        .target = target,
        .optimize = optimize,
    });

    const zimdjson = zimdjson_dep.module("zimdjson");

    const is_release = optimize != .Debug;
    const exe = b.addExecutable(.{
        .name = "zondo",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .strip = b.option(
                bool,
                "strip",
                "Omit debug symbols",
            ) orelse is_release,
            .imports = &.{
                .{ .name = "zimdjson", .module = zimdjson },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zimdjson", .module = zimdjson },
            },
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
