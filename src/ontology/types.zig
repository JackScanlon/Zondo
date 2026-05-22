///! Ontology-related types.
const std = @import("std");

const core = @import("core");

const types = core.types;
const string = core.string;

const Error = types.Error;

/// Ontology builder options.
pub const Options = struct {
    pub const default: @This() = .{
        .queue_size = 10,
        .batch_size = 100,
        .make_paths = true,
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

    /// This open specifies whether the Builder is allowed to make the directory path
    /// if it does not already exist on the system.
    ///
    /// Defaults to false.
    make_paths: bool,
};

/// An ontology identity struct describing the vocabulary name and its reference id.
pub const OntologyIdentity = struct {
    ref: []const u8,
    name: []const u8,

    /// Builds an identifier from the specified `id` string.
    pub fn fromIdentity(id: []const u8) Error!OntologyIdentity {
        if (!string.startsWithSequence(id, "http://purl.obolibrary.org/")) {
            return error.UnknownOntology;
        }

        var t0 = string.splitBackwardsSequence(
            id,
            "http://purl.obolibrary.org/",
        );

        var t1 = string.splitBackwardsSequence(
            t0.first(),
            "/",
        );

        const trg = t1.first();
        if (string.indexOfScalar(trg, '_') == null) {
            return error.UnknownOntology;
        }

        var t2 = string.splitSequence(trg, "_");
        const ont = t2.first();
        const ref = t2.next() orelse "";
        if (ref.len < 1 or !std.ascii.isDigit(ref[0])) {
            return error.UnknownOntology;
        }

        return .{
            .ref = ref,
            .name = ont,
        };
    }
};
