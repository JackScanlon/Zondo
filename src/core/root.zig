const strbuf = @import("strbuf.zig");
const strutil = @import("strutil.zig");

pub const fs = @import("fs.zig");
pub const types = @import("types.zig");
pub const queue = @import("queue.zig");

pub const string = struct {
    // Const
    pub const vec_size = strutil.vec_size;
    pub const use_simd = strutil.use_simd;

    // Types
    pub const SplitIteratorDirection = strutil.SplitIteratorDirection;

    // Helpers
    pub const getSizeUtf8 = strutil.getSizeUtf8;
    pub const isASCIIWhitespace = strutil.isASCIIWhitespace;

    // String operations
    pub const indexOfScalar = strutil.indexOfScalar;
    pub const startsWithSequence = strutil.startsWithSequence;
    pub const containsMoreThanScalar = strutil.containsMoreThanScalar;

    pub const splitSequence = strutil.splitSequence;
    pub const splitBackwardsSequence = strutil.splitBackwardsSequence;
    pub const tokenizeScalar = strutil.tokenizeScalar;

    pub const trimLeadingWhitespace = strutil.trimLeadingWhitespace;
    pub const trimTrailingWhitespace = strutil.trimTrailingWhitespace;
    pub const trimWhitespace = strutil.trimWhitespace;
    pub const findTrimmedBoundary = strutil.findTrimmedBoundary;

    pub const toLowerCase = strutil.toLowerCase;

    // Iterators
    pub const SplitIterator = strutil.SplitIterator;
    pub const ScalarTokenIterator = strutil.ScalarTokenIterator;

    // Buffer
    pub const StringBuffer = strbuf.StringBuffer;
    pub const StringBufferView = strbuf.StringBufferView;
};
