const std = @import("std");

const zon: struct {
    name: enum { zondo },
    version: []const u8,
    fingerprint: u64,
    dependencies: struct {
        clap: Dependency,
        zimdjson: Dependency,
    },
    paths: []const []const u8,
    const Dependency = struct { url: []const u8, hash: []const u8, lazy: bool = false };
} = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const cwd = std.fs.cwd();
    const cwd_realpath = try cwd.realpathAlloc(alloc, ".");
    defer alloc.free(cwd_realpath);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_release = optimize != .Debug;

    // opts
    const options_opt = b.addOptions();
    options_opt.addOption([]const u8, "version", zon.version);

    const options = options_opt.createModule();

    // deps
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const zimdjson_dep = b.dependency("zimdjson", .{
        .target = target,
        .optimize = optimize,
    });

    const clap = clap_dep.module("clap");
    const zimdjson = zimdjson_dep.module("zimdjson");

    // modules
    const thesaurus = b.createModule(.{
        .root_source_file = b.path("src/thesaurus/thesaurus.zig"),
        .imports = &.{
            .{ .name = "zimdjson", .module = zimdjson },
        },
    });

    // artefacts
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
                .{ .name = "clap", .module = clap },
                .{ .name = "options", .module = options },
                .{ .name = "thesaurus", .module = thesaurus },
            },
        }),
    });
    b.installArtifact(exe);

    // tests
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
                .{ .name = "thesaurus", .module = thesaurus },
                .{ .name = "clap", .module = clap },
            },
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
