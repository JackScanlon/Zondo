///! Module responsible for generating minified, PGX-consumable CSVs describing vocabulary
///! terms and their relationships.
const std = @import("std");

const zimdjson = @import("zimdjson");

const core = @import("core");
const types = @import("types.zig");
const preprocess = @import("preprocessing.zig");

const queue = core.queue;

const Error = core.types.Error;
const Parser = zimdjson.dom.FullParser(.default);
const OntologyIdentity = types.OntologyIdentity;

/// Extract builder, responsible for generating minified CSVs to be consumed by an RDB.
pub const Builder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    opts: types.Options,

    /// Initialises the builder with the specified options (the specified allocator is used in any
    /// successive build calls).
    pub fn init(allocator: std.mem.Allocator, opts: types.Options) Self {
        return .{
            .allocator = allocator,
            .opts = opts,
        };
    }

    /// Attempt to parse the [MONDO JSON file](https://mondo.monarchinitiative.org/pages/download/)
    /// at the specified `in_path` to produce the PGX-consumable CSVs within the `out_dir`.
    pub fn build(self: *Self, in_path: []const u8, out_dir: []const u8) Error!void {
        const out_path = try core.fs.ensureDirPath(out_dir, self.opts.make_paths);

        var parser = Parser.init;
        defer parser.deinit(self.allocator);

        const file = std.fs.cwd().openFile(in_path, .{}) catch {
            return error.OpenError;
        };
        defer file.close();

        const doc = parser.parseFromReader(self.allocator, file.reader().any()) catch {
            return error.ParseFailure;
        };

        try self.buildNodes(doc, out_path);
        try self.buildEdges(doc, out_path);
    }

    /// Extracts, normalises, and minifies ontological terms to produce the `mondo_terms.csv` file.
    fn buildNodes(
        self: *Self,
        doc: Parser.Document,
        out_dir: []const u8,
    ) Error!void {
        const out_filepath = try std.fs.path.join(
            self.allocator,
            &[_][]const u8{ out_dir, "mondo_terms.csv" },
        );
        defer self.allocator.free(out_filepath);

        const root = doc.at("graphs").atIndex(0);
        const nodes = root.at("nodes").asArray() catch {
            return error.InvalidShape;
        };

        if (nodes.isEmpty()) {
            return error.NoTerms;
        }

        var batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
        var channel = try queue.BoundedChannel.init(
            self.allocator,
            self.opts.queue_size,
        );
        defer channel.deinit(self.allocator);

        const writer_thread = try std.Thread.spawn(
            .{},
            writerWorker,
            .{ self.allocator, &channel, out_filepath },
        );

        var buf = try core.string.StringBuffer.init(self.allocator, 1024);
        defer buf.deinit();

        try writeColumnValue(&buf, .{"name"}, false);
        try writeColumnValue(&buf, .{"type_id"}, false);
        try writeColumnValue(&buf, .{"reference_id"}, false);
        try writeColumnValue(&buf, .{"properties"}, true);
        try batch.push(try buf.copy(self.allocator));
        buf.reset();

        if (batch.isFull()) {
            try channel.push(batch);
            batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
        }

        var it = nodes.iterator();
        while (it.next()) |el| {
            const nil = el.at("id").isNull() catch true;
            if (nil) {
                continue;
            }

            const id = el.at("id").asString() catch {
                continue;
            };

            const onto = OntologyIdentity.fromIdentity(id) catch {
                continue;
            };

            const lbl = el.at("lbl").asString() catch {
                continue;
            };

            const meta = el.at("meta");
            if ((meta.isNull() catch true)) {
                continue;
            }

            const deprecated = meta.at("deprecated").asBool() catch false;
            if (deprecated) {
                continue;
            }

            // Schema:
            // | Column       | SQL Type       | Example                                                    |
            // |--------------|----------------|------------------------------------------------------------|
            // | name         | `varchar(255)` | Myocardial Infarction                                      |
            // | type_id      | `int`          | 1                                                          |
            // | reference_id | `varchar(64)`  | MONDO:0005068                                              |
            // | properties   | `jsonb`        | {"definition": "...", "synonyms": ["..."], "xref": ["..."] |
            //
            // Example:
            // |name|,|type_id|,|reference_id|,|properties|
            // |label|,|1|,|MONDO:000000|,|{"definition":"def","synonyms":["syn"],"xrefs":["xef"]}|
            //
            // Note:
            // - Columns are comma separated
            // - Quote char is represented by pipe, or `|`, and double quotes are escaped as two pipes, i.e. `||`
            // - Column values are printed with forced quotes
            //
            try writeColumnValue(&buf, .{lbl}, false);
            try writeColumnValue(&buf, .{'1'}, false);
            try writeColumnValue(&buf, .{ onto.name, ':', onto.ref }, false);

            try buf.write("|{");
            {
                var start = buf.pos;
                var append = false;
                if (meta.at("definition").at("val").asString()) |def| {
                    try writeJSONStringValue(&buf, "definition", def, append);
                    append = start < buf.pos;
                    start = buf.pos;
                } else |_| {}

                if (meta.at("synonyms").asArray()) |arr| {
                    try writeJSONArrayValue(&buf, arr, "synonyms", "val", append);
                    append = start < buf.pos;
                    start = buf.pos;
                } else |_| {}

                if (meta.at("xrefs").asArray()) |arr| {
                    try writeJSONArrayValue(&buf, arr, "xrefs", "val", append);
                    append = start < buf.pos;
                    start = buf.pos;
                } else |_| {}
            }
            try buf.write("}|");

            try batch.push(try buf.copy(self.allocator));

            if (batch.isFull()) {
                try channel.push(batch);
                batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
            }

            buf.reset();
        }

        if (!batch.isEmpty()) {
            try channel.push(batch);
        } else {
            batch.deinit(self.allocator);
        }

        {
            channel.mutex.lock();
            channel.is_closed = true;
            channel.not_empty.signal();
            channel.mutex.unlock();
        }

        writer_thread.join();
    }

    /// Extracts the relationships between ontological terms to produce the `mondo_rels.csv` file.
    fn buildEdges(
        self: *Self,
        doc: Parser.Document,
        out_dir: []const u8,
    ) Error!void {
        const out_filepath = try std.fs.path.join(
            self.allocator,
            &[_][]const u8{ out_dir, "mondo_rels.csv" },
        );
        defer self.allocator.free(out_filepath);

        const root = doc.at("graphs").atIndex(0);
        const edges = root.at("edges").asArray() catch {
            return error.InvalidShape;
        };

        if (edges.isEmpty()) {
            return error.NoEdges;
        }

        var batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
        var channel = try queue.BoundedChannel.init(
            self.allocator,
            self.opts.queue_size,
        );
        defer channel.deinit(self.allocator);

        const writer_thread = try std.Thread.spawn(
            .{},
            writerWorker,
            .{ self.allocator, &channel, out_filepath },
        );

        var buf = try core.string.StringBuffer.init(self.allocator, 1024);
        defer buf.deinit();

        try writeColumnValue(&buf, .{"child"}, false);
        try writeColumnValue(&buf, .{"parent"}, true);
        try batch.push(try buf.copy(self.allocator));
        buf.reset();

        if (batch.isFull()) {
            try channel.push(batch);
            batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
        }

        var it = edges.iterator();
        while (it.next()) |el| {
            const pred = el.at("pred").asString() catch {
                continue;
            };

            if (!std.mem.eql(u8, pred, "is_a")) {
                continue;
            }

            const sub = el.at("sub").asString() catch {
                continue;
            };

            const obj = el.at("obj").asString() catch {
                continue;
            };

            const child = OntologyIdentity.fromIdentity(sub) catch {
                continue;
            };

            const parent = OntologyIdentity.fromIdentity(obj) catch {
                continue;
            };

            // Schema:
            // | Column  | SQL Type      | Example       |
            // |---------|---------------|---------------|
            // | child   | `varchar(64)` | MONDO:0005068 |
            // | parent  | `varchar(64)` | MONDO:0024643 |
            //
            // Example:
            // |child|,|parent|
            // |MONDO:000000|,|MONDO:000001|
            //
            // Note:
            // - Columns are comma separated
            // - Quote char is represented by pipe, or `|`, and double quotes are escaped as two pipes, i.e. `||`
            // - Column values are printed with forced quotes
            //
            try writeColumnValue(&buf, .{ child.name, ':', child.ref }, false);
            try writeColumnValue(&buf, .{ parent.name, ':', parent.ref }, true);

            try batch.push(try buf.copy(self.allocator));

            if (batch.isFull()) {
                try channel.push(batch);
                batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
            }

            buf.reset();
        }

        if (!batch.isEmpty()) {
            try channel.push(batch);
        } else {
            batch.deinit(self.allocator);
        }

        {
            channel.mutex.lock();
            channel.is_closed = true;
            channel.not_empty.signal();
            channel.mutex.unlock();
        }

        writer_thread.join();
    }
};

fn writerWorker(allocator: std.mem.Allocator, channel: *queue.BoundedChannel, out_path: []const u8) Error!void {
    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();

    var buffered_writer = std.io.bufferedWriter(file.writer());
    const writer = buffered_writer.writer();

    while (channel.pop()) |batch| {
        for (0..batch.next) |i| {
            const line = batch.items[i];
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        batch.deinit(allocator);

        try buffered_writer.flush();
    }
}

inline fn writeColumnValue(buf: *core.string.StringBuffer, data: anytype, last: bool) !void {
    const T = @TypeOf(data);
    if (T != @TypeOf(null)) {
        const tinfo = @typeInfo(T);
        if (tinfo != .@"struct" or !tinfo.@"struct".is_tuple) {
            @compileError("Expected a tuple, found " ++ @typeName(T));
        }

        if (data.len > 0) {
            try buf.writeByte('|');
            inline for (data) |str| {
                const V = @TypeOf(str);

                const value: ?[]const u8 = blk: {
                    switch (@typeInfo(V)) {
                        .comptime_int => {
                            const int_val = @as(std.math.IntFittingRange(str, str), str);
                            if (@typeInfo(@TypeOf(int_val)).int.bits <= 8) {
                                try buf.writeByte(@as(u8, int_val));
                                break :blk null;
                            } else {
                                @compileError("Cannot print integer that is larger than 8 bits as an ASCII character");
                            }
                        },
                        .pointer => |ptr_info| switch (ptr_info.size) {
                            .one => switch (@typeInfo(ptr_info.child)) {
                                .array => {
                                    const ainfo = @typeInfo(@TypeOf(str.*));
                                    if (ainfo == .array and ainfo.array.child == u8) {
                                        break :blk &str.*;
                                    }

                                    break :blk null;
                                },
                                else => break :blk null,
                            },
                            .many, .c => {
                                if (ptr_info.child == u8) {
                                    break :blk std.mem.span(str);
                                }

                                break :blk null;
                            },
                            .slice => {
                                if (ptr_info.child == u8) {
                                    break :blk str;
                                }

                                break :blk null;
                            },
                        },
                        .array => |arr| {
                            if (arr.child == u8) {
                                break :blk str;
                            }

                            break :blk null;
                        },
                        else => break :blk null,
                    }
                };

                if (value) |val| {
                    try buf.escapeWrite(val);
                }
            }
            try buf.writeByte('|');
        }
    }

    if (!last) {
        try buf.writeByte(',');
    }
}

inline fn writeJSONStringValue(buf: *core.string.StringBuffer, key: []const u8, value: []const u8, append: bool) !void {
    if (key.len < 1 or value.len < 1) {
        return;
    }

    if (append) {
        try buf.writeByte(',');
    }

    try buf.writeByte('"');
    try buf.escapeWrite(key);
    try buf.write("\":\"");
    try buf.escapeWrite(value);
    try buf.writeByte('"');
}

inline fn writeJSONArrayValue(buf: *core.string.StringBuffer, arr: Parser.Array, key: []const u8, target: []const u8, append: bool) !void {
    const n = arr.getSize();
    if (key.len < 1 or n < 1) {
        return;
    }

    if (append) {
        try buf.writeByte(',');
    }

    try buf.writeByte('"');
    try buf.escapeWrite(key);
    try buf.write("\":[");

    var i: usize = 0;
    var it = arr.iterator();
    while (it.next()) |el| {
        i += 1;

        const value = el.at(target).asString() catch {
            continue;
        };

        try buf.writeByte('"');
        try buf.escapeWrite(value);

        if (i < n) {
            try buf.write("\",");
        } else {
            try buf.writeByte('"');
        }
    }
    try buf.writeByte(']');
}
