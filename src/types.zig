//! Core type definitions.
const std = @import("std");

/// Thesaurus-related errors.
const BuilderError = error{
    /// The specified document could not be opened.
    IoError,
    /// The specified document could not be parsed.
    ParseFailure,
    /// The document is not consistent with what is expected of a MONDO JSON format.
    InvalidShape,
    /// The document contains no ontological terms.
    NoTerms,
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
    || std.mem.Allocator.Error
    || std.fs.File.WriteError
    || std.fs.File.OpenError
    || std.Thread.SpawnError
    || std.fmt.BufPrintError
    || error{};
// zig fmt: on
