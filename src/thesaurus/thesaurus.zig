//! Builder module responsible for generating a Postgres FtS thesaurus from the MONDO
//! disease ontology.
//!
//! See:
//! - [MONDO Disease Ontology](https://www.ebi.ac.uk/ols4/ontologies/mondo)
//! - [Postgres FtS Thesaurus Configuration](https://www.postgresql.org/docs/current/textsearch-dictionaries.html#TEXTSEARCH-THESAURUS)
const std = @import("std");

const zimdjson = @import("zimdjson");

const queue = @import("queue.zig");
const types = @import("types.zig");
const preprocess = @import("preprocessing.zig");

const Error = types.Error;
const Parser = zimdjson.ondemand.StreamParser(.default);

/// The available options when building the ontological thesaurus.
pub const Options = struct {
    pub const default: @This() = .{
        .queue_size = 10,
        .batch_size = 100,
    };

    /// This option specifies the channel buffer size.
    ///
    /// Defaults to size of 10.
    queue_size: usize,

    /// This option specifies the number of strings (lines) recorded in a batch
    /// before being broadcast to the bounded channel.
    ///
    /// Defaults to size of 100.
    batch_size: usize,
};

/// Thesaurus builder, responsible for parsing and then transforming ontological terms &
/// their synonyms before producing a Postgres FtS-ready thesaurus.
pub const Builder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    batch: *queue.Batch,
    opts: Options,

    /// Initialises the builder with the specified options (the specified allocator is used in any
    /// successive build calls).
    pub fn init(allocator: std.mem.Allocator, opts: Options) Self {
        return .{
            .allocator = allocator,
            .batch = undefined,
            .opts = opts,
        };
    }

    /// Attempt to parse the [MONDO JSON file](https://mondo.monarchinitiative.org/pages/download/)
    /// at the specified `in_path` to produce the FtS-ready thesaurus at `out_path`.
    pub fn build(self: *Self, in_path: []const u8, out_path: []const u8) Error!void {
        var parser = Parser.init;
        defer parser.deinit(self.allocator);

        const file = std.fs.cwd().openFile(in_path, .{}) catch {
            return error.IoError;
        };
        defer file.close();

        const doc = parser.parseFromReader(self.allocator, file.reader().any()) catch {
            return error.ParseFailure;
        };

        const root = doc.at("graphs").atIndex(0);
        const nodes = root.at("nodes").asArray() catch {
            return error.InvalidShape;
        };

        if ((nodes.isEmpty() catch true)) {
            return error.NoTerms;
        }

        var channel = try queue.BoundedChannel.init(
            self.allocator,
            self.opts.queue_size,
        );
        defer channel.deinit(self.allocator);

        const writer_thread = try std.Thread.spawn(
            .{},
            writerWorker,
            .{ self.allocator, &channel, out_path },
        );
        self.batch = try queue.Batch.init(self.allocator, self.opts.batch_size);

        var it = nodes.iterator();
        while (it.next() catch {
            return error.InvalidShape;
        }) |el| {
            const nil = el.at("id").isNull() catch true;
            if (nil) {
                continue;
            }

            const id = el.at("id").asString() catch {
                continue;
            };

            if (!std.mem.startsWith(u8, id, "http://purl.obolibrary.org/")) {
                continue;
            }

            var t0 = std.mem.splitBackwardsSequence(
                u8,
                id,
                "http://purl.obolibrary.org/",
            );
            var t1 = std.mem.splitBackwardsScalar(
                u8,
                t0.first(),
                '/',
            );

            const trg = t1.first();
            if (std.mem.indexOfScalar(u8, trg, '_') == null) {
                continue;
            }

            var t2 = std.mem.splitScalar(u8, trg, '_');
            const onto = t2.first();
            const ident = t2.next() orelse "";
            if (ident.len < 1 or !std.ascii.isDigit(ident[0])) {
                continue;
            }

            const meta = el.at("meta");
            if ((meta.isNull() catch true)) {
                continue;
            }

            const deprecated = meta.at("deprecated").asBool() catch false;
            if (deprecated) {
                continue;
            }

            const synonyms = meta.at("synonyms").asArray() catch continue;
            if ((synonyms.isEmpty() catch true)) {
                continue;
            }

            try self.buildSynonyms(&channel, onto, ident, synonyms);

            if (self.batch.isFull()) {
                try channel.push(self.batch);
                self.batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
            }
        }

        if (!self.batch.isEmpty()) {
            try channel.push(self.batch);
        } else {
            self.batch.deinit(self.allocator);
        }
        self.batch = undefined;

        {
            channel.mutex.lock();
            channel.is_closed = true;
            channel.not_empty.signal();
            channel.mutex.unlock();
        }

        writer_thread.join();
    }

    fn buildSynonyms(
        self: *Self,
        channel: *queue.BoundedChannel,
        onto: []const u8,
        ident: []const u8,
        synonyms: Parser.Array,
    ) Error!void {
        var ont_buf: [128]u8 = undefined;
        const ont = preprocess.processTerm(&ont_buf, onto, ident);

        var it = synonyms.iterator();
        var syn_buf: [1024]u8 = undefined;
        while (it.next() catch {
            return error.ParseFailure;
        }) |el| {
            const synonym = el.at("val").asString() catch continue;
            if (synonym.len == 0) {
                continue;
            }

            var feature = try preprocess.processSynonym(self.allocator, synonym);
            if (feature.len == 0) {
                self.allocator.free(feature);
                continue;
            }

            const slice = try std.fmt.bufPrint(&syn_buf, "{s} : {s}", .{ feature, ont });
            feature = try self.allocator.realloc(feature, feature.len + ont.len + 3);
            std.mem.copyForwards(u8, feature, slice);

            try self.batch.push(feature);

            if (self.batch.isFull()) {
                try channel.push(self.batch);
                self.batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
            }
        }
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
