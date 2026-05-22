//! Core type definitions.
const std = @import("std");

/// Thesaurus-related errors.
const BuilderError = error{
    /// The specified document could not be opened.
    OpenError,
    /// Failed to make directory path
    MakePathsError,
    /// Specified path is not likely to describe a path to a file
    ExpectedFilePath,
    /// Specified path is not likely to describe a path to a directory
    ExpectedDirPath,
    /// The specified document could not be parsed.
    ParseFailure,
    /// The document is not consistent with what is expected of a MONDO JSON format.
    InvalidShape,
    /// The document contains no ontological terms.
    NoTerms,
    /// The document contains no ontological relationships.
    NoEdges,
    /// The ontology type of the ontological term could not be derived from its ID.
    UnknownOntology,
};

/// Buffer-related errors.
const BufferError = error{
    /// Attempt to write outside of buffer bounds.
    OutOfCapacity,
};

/// SPSC-related errors.
const QueueError = error{
    /// Channel has already been closed.
    ChannelClosed,
    /// Batch has been saturated (Note: should be unreachable).
    ReachedCapacity,
};

// zig fmt: off
/// Error codes for program operation.
pub const Error = BuilderError
    || QueueError
    || BufferError
    || std.mem.Allocator.Error
    || std.fs.File.WriteError
    || std.fs.File.OpenError
    || std.Thread.SpawnError
    || std.fmt.BufPrintError
    || error{};
// zig fmt: on
