const std = @import("std");
const builtin = @import("builtin");

const clap = @import("clap");

const commands = @import("commands.zig");

const SubCommands = enum {
    version,
    build,
};

const parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
};

const params = clap.parseParamsComptime(
    \\-h, --help Display this help and exit.
    \\<command>
    \\
);

var debug_alloc: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const alloc, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{
                debug_alloc.allocator(),
                true,
            },
            .ReleaseFast, .ReleaseSmall => .{
                std.heap.smp_allocator,
                false,
            },
        };
    };
    defer {
        if (is_debug and debug_alloc.deinit() == .leak) {
            std.process.exit(1);
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const allocator = arena.allocator();

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &params,
        parsers,
        &iter,
        .{
            .diagnostic = &diag,
            .allocator = allocator,
            .terminating_positional = 0,
        },
    ) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return usage();
    }

    const command = res.positionals[0] orelse return error.MissingCommand;
    switch (command) {
        .version => try commands.runVersion(allocator, &iter),
        .build => try commands.runBuild(allocator, &iter),
    }
}

fn usage() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\zondo
        \\Extract & transform ontological terms for Postgres Full-Text Search.
        \\
        \\Usage:
        \\  zondo <command> [flags]
        \\
        \\Available Commands:
        \\  * version   Display the program version and exit.
        \\  * build     Build a PGXS thesaurus for a given MONDO release.
        \\
        \\Flags:
        \\
    ,
        .{},
    );
    try clap.help(stderr, clap.Help, &params, .{});
}
