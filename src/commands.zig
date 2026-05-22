const std = @import("std");

const clap = @import("clap");
const options = @import("options");

const ontology = @import("ontology");

const buildParams = clap.parseParamsComptime(
    \\-h, --help          Display this help and exit.
    \\-i, --input   <str> The file path to the MONDO JSON input file.
    \\-o, --outfile <str> The output file path.
    \\
);

const extractParams = clap.parseParamsComptime(
    \\-h, --help         Display this help and exit.
    \\-i, --input  <str> The file path to the MONDO JSON input file.
    \\-o, --outdir <str> The output file directory.
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
        &buildParams,
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

    var builder = ontology.ThesaurusBuilder.init(allocator, .default);
    try builder.build(
        res.args.input orelse {
            std.debug.print("Input file path must be specified.\n", .{});
            std.process.exit(1);
        },
        res.args.outfile orelse {
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
    try clap.help(stderr, clap.Help, &buildParams, .{});
}

pub fn runExtract(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &extractParams,
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

    var builder = ontology.ExtractBuilder.init(allocator, .default);
    try builder.build(
        res.args.input orelse {
            std.debug.print("Input file path must be specified.\n", .{});
            std.process.exit(1);
        },
        res.args.outdir orelse {
            std.debug.print("Output file path must be specified.\n", .{});
            std.process.exit(1);
        },
    );
}

fn usageExtract() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\zondo build
        \\Extract ontological terms as RDBMS consumable CSV files for a given MONDO release.
        \\
        \\Usage:
        \\  zondo extract <input_file_path> [flags]
        \\
        \\Flags:
        \\
    ,
        .{},
    );
    try clap.help(stderr, clap.Help, &extractParams, .{});
}
