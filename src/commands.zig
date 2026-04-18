const std = @import("std");

const clap = @import("clap");
const options = @import("options");

const thesaurus = @import("thesaurus");

const params = clap.parseParamsComptime(
    \\-h, --help         Display this help and exit.
    \\-i, --input  <str> The file path to the MONDO JSON input file.
    \\-o, --output <str> The output file path.
    \\
);

pub fn runVersion(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    _, _ = .{ allocator, iter };

    const stderr = std.io.getStdErr().writer();
    try stderr.print("zondo v{s}\n", .{options.version});
}

pub fn runBuild(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &params,
        clap.parsers.default,
        iter,
        .{
            .diagnostic = &diag,
            .allocator = allocator,
        },
    ) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return usageBuild();

    var builder = thesaurus.Builder.init(allocator, .default);
    try builder.build(
        res.args.input orelse {
            std.debug.print("Input file path must be specified.\n", .{});
            std.process.exit(1);
        },
        res.args.output orelse {
            std.debug.print("Output file path must be specified.\n", .{});
            std.process.exit(1);
        },
    );
}

fn usageBuild() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\zondo build
        \\Build a PGXS thesaurus for a given MONDO release.
        \\
        \\Usage:
        \\  zondo build <input_file_path> [flags]
        \\
        \\Flags:
        \\
    ,
        .{},
    );
    try clap.help(stderr, clap.Help, &params, .{});
}
