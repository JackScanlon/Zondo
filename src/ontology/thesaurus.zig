//! Builder module responsible for generating a Postgres FtS thesaurus from the MONDO
//! disease ontology.
//!
//! See:
//! - [MONDO Disease Ontology](https://www.ebi.ac.uk/ols4/ontologies/mondo)
//! - [Postgres FtS Thesaurus Configuration](https://www.postgresql.org/docs/current/textsearch-dictionaries.html#TEXTSEARCH-THESAURUS)
const std = @import("std");

const zimdjson = @import("zimdjson");

const core = @import("core");
const types = @import("types.zig");
const preprocess = @import("preprocessing.zig");

const queue = core.queue;

const Error = core.types.Error;
const Parser = zimdjson.ondemand.StreamParser(.default);
const OntologyIdentity = types.OntologyIdentity;

/// Thesaurus builder, responsible for parsing and then transforming ontological terms &
/// their synonyms before producing a Postgres FtS-ready thesaurus.
pub const Builder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    batch: *queue.Batch,
    opts: types.Options,

    /// Initialises the builder with the specified options (the specified allocator is used in any
    /// successive build calls).
    pub fn init(allocator: std.mem.Allocator, opts: types.Options) Self {
        return .{
            .allocator = allocator,
            .batch = undefined,
            .opts = opts,
        };
    }

    /// Attempt to parse the [MONDO JSON file](https://mondo.monarchinitiative.org/pages/download/)
    /// at the specified `in_path` to produce the FtS-ready thesaurus at `out_path`.
    pub fn build(self: *Self, in_path: []const u8, out_path: []const u8) Error!void {
        const out_file = try core.fs.ensureFilePath(
            out_path,
            self.opts.make_paths,
        );

        var parser = Parser.init;
        defer parser.deinit(self.allocator);

        const file = std.fs.cwd().openFile(in_path, .{}) catch {
            return error.OpenError;
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
            .{ self.allocator, &channel, out_file },
        );
        self.batch = try queue.Batch.init(self.allocator, self.opts.batch_size);

        var it = nodes.iterator();
        while (it.next() catch {
            return error.InvalidShape;
        }) |el| {
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

            const synonyms = meta.at("synonyms").asArray() catch continue;
            if ((synonyms.isEmpty() catch true)) {
                continue;
            }

            try self.buildSynonyms(&channel, onto.name, onto.ref, lbl, synonyms);

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

    /// Extracts, normalises, and signals synonyms assoc. w/ each ontological term.
    fn buildSynonyms(
        self: *Self,
        channel: *queue.BoundedChannel,
        onto: []const u8,
        ident: []const u8,
        label: []const u8,
        synonyms: Parser.Array,
    ) Error!void {
        var ont_buf: [128]u8 = undefined;
        const ont = preprocess.processTerm(&ont_buf, onto, ident);

        var syn_buf: [1024]u8 = undefined;
        try self.pushSynonym(channel, &syn_buf, ont, label);

        var it = synonyms.iterator();
        while (it.next() catch {
            return error.ParseFailure;
        }) |el| {
            const synonym = el.at("val").asString() catch continue;
            if (synonym.len == 0) {
                continue;
            }

            try self.pushSynonym(channel, &syn_buf, ont, synonym);
        }
    }

    /// Normalise & record synonym for a given ontological term.
    fn pushSynonym(
        self: *Self,
        channel: *queue.BoundedChannel,
        buf: []u8,
        ont: []const u8,
        synonym: []const u8,
    ) Error!void {
        var feature = try preprocess.processSynonym(self.allocator, synonym);
        if (feature.len == 0) {
            self.allocator.free(feature);
            return;
        }

        const slice = try std.fmt.bufPrint(buf, "{s} : {s}", .{ feature, ont });
        feature = try self.allocator.realloc(feature, feature.len + ont.len + 3);
        std.mem.copyForwards(u8, feature, slice);
        try self.batch.push(feature);

        if (self.batch.isFull()) {
            try channel.push(self.batch);
            self.batch = try queue.Batch.init(self.allocator, self.opts.batch_size);
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
