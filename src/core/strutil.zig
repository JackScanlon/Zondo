//! Module defining a collection of string utility functions optimised w/ SIMD vectorisation.
const std = @import("std");

/// Direction of `SplitIterator`
pub const SplitIteratorDirection = enum { forwards, backwards };

/// Target-dependant int which specifies the appropriate SIMD vector-length for a u8 vector.
pub const vec_size = blk: {
    if (std.simd.suggestVectorLength(u8)) |recommended| {
        break :blk if (recommended >= 64) 32 else recommended;
    } else {
        break :blk (@sizeOf(usize));
    }
};

/// Target-dependant flag which specifies whether SIMD can be utilised.
pub const use_simd = blk: {
    const recommended = std.simd.suggestVectorLength(u8);
    break :blk (recommended == null);
};

/// Vector of u8 to support SIMD instructions.
///
/// See:
/// - https://ziglang.org/documentation/0.14.0/#Vectors
pub const Vec = @Vector(vec_size, u8);

// SIMD masks
const simd_mask_nul: Vec = @splat(0); // 0x00 ([NUL])
const simd_mask_lower: Vec = @splat(0x20); // Bit 5 (32, [space])
const simd_mask_A: Vec = @splat('A'); // 0x41 ([A])
const simd_mask_Z: Vec = @splat('Z'); // 0x5a ([Z])
const simd_mask_ff: Vec = @splat(0x0C); // 0x0C ([FF])
const simd_mask_nl: Vec = @splat('\n'); // 0x0A (['\n'])
const simd_mask_cr: Vec = @splat('\r'); // 0x0d (['\r'])
const simd_mask_tab: Vec = @splat('\t'); // 0x09 (['\t'])
const simd_mask_space: Vec = @splat(' '); // 0x20 ([' '])

// Maximum value of vector integer types
const simd_signed_max: std.meta.Int(.signed, vec_size) = ((1 << (vec_size - 1)) - 1);
const simd_unsigned_max: std.meta.Int(.unsigned, vec_size) = ((1 << (vec_size - 0)) - 1);

/// Inline fn to compute the size of a UTF-8 character.
inline fn getUtf8Size(char: u8) u3 {
    return std.unicode.utf8ByteSequenceLength(char) catch {
        return 1;
    };
}

/// Inline fn to det. whether the specified char is a ASCII whitespace-like character
inline fn isCharASCIIWhitespace(char: u8) bool {
    return (char == ' ' or char == '\t' or char == '\n' or char == '\r' or char == 0x0C);
}

/// Compute a UTF-8 character's size.
pub fn getSizeUtf8(char: u8) u3 {
    return getUtf8Size(char);
}

/// Det. whether the specified char is considered to be an ASCII whitespace char.
pub fn isASCIIWhitespace(char: u8) u3 {
    return isCharASCIIWhitespace(char);
}

/// Searches for the index of the scalar value inside of the specified input string using SIMD vectorisation
/// where appropriate.
///
/// Note:
/// - This fn will return `null` if the input's length is less than 1.
pub fn indexOfScalar(input: []const u8, trg: u8) ?usize {
    const n: usize = input.len;
    if (n == 0) {
        return null;
    }

    var i: usize = 0;

    // SIMD vectorisation
    if (use_simd) {
        const trg_vec: Vec = @splat(trg);
        while (i + vec_size <= n) : (i += vec_size) {
            const chunk: Vec = input[i..][0..vec_size].*;

            var found = @as(@Vector(vec_size, bool), @splat(false));
            found |= (chunk == trg_vec);

            const mask = @as(std.meta.Int(.unsigned, vec_size), @bitCast(found));
            if (mask != 0) {
                return i + @ctz(mask);
            }
        }
    }

    // Scalar fallback
    while (i < n) : (i += 1) {
        if (input[i] == trg) {
            return i;
        }
    }

    return null;
}

/// Det. whether the specified `haystack` string starts with the specified `needle` string using SIMD vectorisation
/// where appropriate.
///
/// Note:
/// - This fn will return `true` if the needle's length is less than 1.
/// - This fn will return `false` if the needle's length exceeds that of the `haystack`.
pub fn startsWithSequence(haystack: []const u8, needle: []const u8) bool {
    const n: usize = needle.len;
    if (n == 0) {
        return true;
    } else if (n > haystack.len) {
        return false;
    }

    var i: usize = 0;

    // SIMD vectorisation
    if (use_simd) {
        while (i + vec_size <= n) : (i += vec_size) {
            const h_vec: Vec = haystack[i..][0..vec_size].*;
            const n_vec: Vec = needle[i..][0..vec_size].*;

            const matches = (h_vec == n_vec);
            if (!@reduce(.And, matches)) {
                return false;
            }
        }

        // Scalar tail
        while (i < n) : (i += 1) {
            if (haystack[i] != needle[i]) {
                return false;
            }
        }

        return true;
    }

    // Scalar fallback
    return std.mem.startsWith(u8, haystack, needle);
}

/// Det. whether a string has any characters aside from the specified u8 `trg` character using SIMD vectorisation
/// where appropriate.
///
/// Note:
/// - This fn will return `false` if the string's length is less than 1.
pub fn containsMoreThanScalar(input: []const u8, trg: u8) bool {
    const n = input.len;
    if (n == 0) {
        return false;
    }

    var i: usize = 0;

    // SIMD vectorisation
    if (use_simd) {
        const trg_vec: Vec = @splat(trg);
        while (i + vec_size <= n) : (i += vec_size) {
            const chunk: Vec = input[i..][0..vec_size].*;
            const mask = chunk != trg_vec;
            if (@reduce(.Or, mask)) {
                return true;
            }
        }
    }

    // Scalar fallback
    while (i < n) : (i += 1) {
        if (input[i] != trg) {
            return true;
        }
    }

    return false;
}

/// Returns a SIMD-accelerated iterator that iterates over the slices of `buffer` that are separated by the byte
/// sequence in `delimiter`.
///
/// Mimics:
/// - https://ziglang.org/documentation/master/std/#std.mem.splitSequence
pub fn splitSequence(buf: []const u8, delimiter: []const u8) SplitIterator {
    return SplitIterator.init(buf, delimiter, .forwards);
}

/// Returns a SIMD-accelerated iterator that iterates backwards over the slices of `buffer` that are separated
/// by the byte sequence in `delimiter`.
///
/// Mimics:
/// - https://ziglang.org/documentation/master/std/#std.mem.splitBackwardsSequence
pub fn splitBackwardsSequence(buf: []const u8, delimiter: []const u8) SplitIterator {
    return SplitIterator.init(buf, delimiter, .backwards);
}

/// Returns a `ScalarTokenIterator` over the slices of `buf` that are not `delimiter`
///
/// Mimics:
/// - https://ziglang.org/documentation/master/std/#std.mem.tokenizeScalar
pub fn tokenizeScalar(buf: []const u8, delimiter: u8) ScalarTokenIterator {
    return ScalarTokenIterator.init(buf, delimiter);
}

/// Trims leading whitespace from the specified `input` string using SIMD vectorisation where appropriate.
pub fn trimLeadingWhitespace(input: []const u8) []const u8 {
    const n = input.len;
    if (n == 0) {
        return input;
    }

    var i: usize = 0;

    // SIMD vectorisation
    if (use_simd) {
        while (i + vec_size <= n) : (i += vec_size) {
            const chunk: Vec = input[i..][0..vec_size].*;

            const is_ws = @as(@Vector(vec_size, bool), chunk == simd_mask_space) |
                @as(@Vector(vec_size, bool), chunk == simd_mask_tab) |
                @as(@Vector(vec_size, bool), chunk == simd_mask_nl) |
                @as(@Vector(vec_size, bool), chunk == simd_mask_cr) |
                @as(@Vector(vec_size, bool), chunk == simd_mask_ff);

            const mask = ~@as(std.meta.Int(.unsigned, vec_size), @bitCast(is_ws));
            if (mask != 0) {
                return input[i + @ctz(mask) ..];
            }
        }
    }

    // Scalar fallback
    while (i < n) : (i += 1) {
        if (!isCharASCIIWhitespace(input[i])) {
            return input[i..];
        }
    }

    return input[n..];
}

/// Trims trailing whitespace from the specified `input` string using SIMD vectorisation where appropriate.
pub fn trimTrailingWhitespace(input: []const u8) []const u8 {
    const n = input.len;
    if (n == 0) {
        return input;
    }

    var i: usize = n;

    // SIMD vectorisation
    if (use_simd) {
        while (i >= vec_size) {
            const start = i - vec_size;
            const chunk: Vec = input[start..][0..vec_size].*;

            const is_ws = @as(@Vector(vec_size, bool), chunk == simd_mask_space) |
                @as(@Vector(vec_size, bool), chunk == simd_mask_tab) |
                @as(@Vector(vec_size, bool), chunk == simd_mask_nl) |
                @as(@Vector(vec_size, bool), chunk == simd_mask_cr) |
                @as(@Vector(vec_size, bool), chunk == simd_mask_ff);

            const mask = @as(std.meta.Int(.unsigned, vec_size), @bitCast(is_ws));
            if (mask == simd_unsigned_max) {
                i -= vec_size;
            } else {
                return input[0 .. i - @clz(~mask)];
            }
        }
    }

    // Scalar fallback
    while (i > 0 and isCharASCIIWhitespace(input[i])) : (i -= 1) {}

    return input[0..i];
}

/// Trims both leading & trailing whitespace from the specified `input` string using SIMD vectorisation
/// where appropriate.
pub fn trimWhitespace(input: []const u8) []const u8 {
    const trimmed = trimLeadingWhitespace(input);
    return trimTrailingWhitespace(trimmed);
}

pub fn findTrimmedBoundary(input: []const u8) struct { start: usize, end: usize, size: usize } {
    const n = input.len;
    if (n == 0) {
        return .{ .start = 0, .end = 0, .size = 0 };
    }

    // SIMD vectorisation
    if (use_simd) {
        const start_index: usize = blk: {
            var i: usize = 0;
            while (i + vec_size <= n) : (i += vec_size) {
                const chunk: Vec = input[i..][0..vec_size].*;

                const is_ws = @as(@Vector(vec_size, bool), chunk == simd_mask_space) |
                    @as(@Vector(vec_size, bool), chunk == simd_mask_tab) |
                    @as(@Vector(vec_size, bool), chunk == simd_mask_nl) |
                    @as(@Vector(vec_size, bool), chunk == simd_mask_cr) |
                    @as(@Vector(vec_size, bool), chunk == simd_mask_ff);

                const mask = ~@as(std.meta.Int(.unsigned, vec_size), @bitCast(is_ws));
                if (mask != 0) {
                    break :blk i + @ctz(mask);
                }
            }

            while (i < n) : (i += 1) {
                if (!isCharASCIIWhitespace(input[i])) {
                    break :blk i;
                }
            }

            break :blk n;
        };

        if (start_index >= n) {
            return .{ .start = n, .end = n, .size = 0 };
        }

        var end_index = blk: {
            var i: usize = 0;
            while (i >= vec_size) {
                const start = i - vec_size;
                const chunk: Vec = input[start..][0..vec_size].*;

                const is_ws = @as(@Vector(vec_size, bool), chunk == simd_mask_space) |
                    @as(@Vector(vec_size, bool), chunk == simd_mask_tab) |
                    @as(@Vector(vec_size, bool), chunk == simd_mask_nl) |
                    @as(@Vector(vec_size, bool), chunk == simd_mask_cr) |
                    @as(@Vector(vec_size, bool), chunk == simd_mask_ff);

                const mask = @as(std.meta.Int(.unsigned, vec_size), @bitCast(is_ws));
                if (mask == simd_unsigned_max) {
                    i -= vec_size;
                } else {
                    break :blk i - @clz(~mask);
                }
            }

            while (i > 0 and isCharASCIIWhitespace(input[i])) : (i -= 1) {}

            break :blk i;
        };

        end_index = @max(end_index, start_index);
        return .{ .start = start_index, .end = end_index, .size = end_index - start_index };
    }

    // Scalar fallback
    var i: usize = 0;
    var j: usize = n;

    var flag: u8 = 0b0;
    while (i < n) {
        if (std.mem.indexOfScalar(u8, &std.ascii.whitespace, input[i]) != null) {
            flag |= 0b1;
            i += 1;
        }

        if (std.mem.indexOfScalar(u8, &std.ascii.whitespace, input[j - 1]) != null) {
            flag |= 0b1;
            j -= 1;
        }

        if ((flag & flag) == 0b0) {
            break;
        }
        flag = 0b0;
    }
    j = @max(j, i);

    return .{ .start = i, .end = j, .size = j - i };
}

/// Writes a lower case copy of the `src` string to the `dest` buffer using SIMD vectorisation where appropriate.
///
/// Note:
/// - Asserts `output.len >= ascii_string.len`.
/// - Returns a sliced result.
pub fn toLowerCase(dest: []u8, src: []const u8) []u8 {
    std.debug.assert(dest.len >= src.len);

    if (src.len == 0) {
        return dest[0..0];
    }

    // SIMD vectorisation
    if (use_simd) {
        var i: usize = 0;

        // Process vectorised chunks
        while (i + vec_size <= src.len) : (i += vec_size) {
            const chunk: Vec = src[i..][0..vec_size].*;

            const greater_than_A = chunk >= simd_mask_A;
            const less_than_Z = chunk <= simd_mask_Z;
            const is_upper = greater_than_A & less_than_Z;

            // Where `is_upper`, select the lowercase bit (0x20), otherwise 0x00
            const lower_mask = @select(u8, is_upper, simd_mask_lower, simd_mask_nul);

            // Bitwise OR flips the 5th bit only on the uppercase characters
            const lowered = chunk | lower_mask;

            dest[i..][0..vec_size].* = @as([vec_size]u8, lowered);
        }

        // Scalar tail
        while (i < src.len) : (i += 1) {
            dest[i] = std.ascii.toLower(src[i]);
        }

        return dest[0..src.len];
    }

    // Scalar fallback
    return std.ascii.lowerString(dest, src);
}

/// Iterator type for SIMD-accelerated splitting operations, _incl._ empty sequences between delimiters,
/// somewhat mimicking the behaviour of `std.mem.SplitIterator` and `std.mem.SplitBackwardsIterator`
///
/// See:
/// - https://ziglang.org/documentation/master/std/#std.mem.SplitIterator
/// - https://ziglang.org/documentation/master/std/#std.mem.SplitBackwardsIterator
pub const SplitIterator = struct {
    buffer: []const u8,
    delimiter: []const u8,
    direction: SplitIteratorDirection,
    index: ?usize,

    pub fn init(buf: []const u8, delim: []const u8, dir: SplitIteratorDirection) SplitIterator {
        std.debug.assert(delim.len > 0); // std.mem.splitSequence requires non-empty delimiter

        const idx = val: switch (dir) {
            .forwards => break :val 0,
            .backwards => break :val buf.len,
        };

        return .{
            .buffer = buf,
            .delimiter = delim,
            .direction = dir,
            .index = idx,
        };
    }

    /// Returns a slice of the first field. Call this only to get the first field and then use next
    /// to get all subsequent fields. Asserts that iteration has not begun.
    pub fn first(self: *SplitIterator) []const u8 {
        switch (self.direction) {
            .forwards => {
                std.debug.assert(self.index.? == 0);
                return self.next().?;
            },
            .backwards => {
                std.debug.assert(self.index.? == self.buffer.len);
                return self.next().?;
            },
        }
    }

    /// Returns a slice for the next token (empty tokens included if delimiters are consecutive)
    /// or null when tokenization is complete.
    pub fn next(self: *SplitIterator) ?[]const u8 {
        const idx = val: {
            // If index is null, iteration has completely finished
            if (self.index == null) return null;
            // Otherwise return current index
            break :val self.index.?;
        };

        switch (self.direction) {
            .forwards => {
                // Find the next occurrence of the delimiter sequence
                if (self.findNextDelimiterSequence(idx)) |delim_start_idx| {
                    const token = self.buffer[idx..delim_start_idx];
                    self.index = delim_start_idx + self.delimiter.len;
                    return token;
                }

                // Return remainder if no delimiter sequence can be found
                self.index = null;
                return self.buffer[idx..];
            },
            .backwards => {
                // Find the next occurrence of the delimiter sequence looking backwards
                // and set up the next iteration's right boundary right before this delimiter.
                if (self.findPreviousDelimiterSequence(idx)) |delim_start_idx| {
                    const token = self.buffer[delim_start_idx + self.delimiter.len .. idx];
                    if (delim_start_idx == 0) {
                        self.index = null; // Next iteration will be out of bounds
                    } else {
                        self.index = delim_start_idx;
                    }

                    return token;
                }

                // Return remainder on the left if no delimiter sequence can be found
                self.index = null;
                return self.buffer[0..idx];
            },
        }
    }

    /// Returns a slice of the next field, or null if splitting is complete. This method does not advance iterator.
    pub fn peek(self: *SplitIterator) ?[]const u8 {
        const idx = val: {
            // If index is null, iteration has completely finished
            if (self.index == null) return null;
            // Otherwise return current index
            break :val self.index.?;
        };

        switch (self.direction) {
            .forwards => {
                // Find the next occurrence of the delimiter sequence
                if (self.findNextDelimiterSequence(idx)) |delim_start_idx| {
                    const token = self.buffer[idx..delim_start_idx];
                    return token;
                }

                // Return remainder if no delimiter sequence can be found
                return self.buffer[idx..];
            },
            .backwards => {
                if (self.findPreviousDelimiterSequence(idx)) |delim_start_idx| {
                    return self.buffer[delim_start_idx + self.delimiter.len .. idx];
                }

                // Return remainder on the left if no delimiter sequence can be found
                return self.buffer[0..idx];
            },
        }
    }

    /// Returns a slice of the remaining bytes. Does not affect iterator state.
    pub fn rest(self: *SplitIterator) []const u8 {
        switch (self.direction) {
            .forwards => {
                const end = self.buffer.len;
                const start = self.index orelse end;
                return self.buffer[start..end];
            },
            .backwards => {
                const end = self.index orelse 0;
                return self.buffer[0..end];
            },
        }
    }

    /// Resets the iterator to the initial slice.
    pub fn reset(self: *SplitIterator) void {
        self.index = val: switch (self.direction) {
            .forwards => break :val 0,
            .backwards => break :val self.buffer.len,
        };
    }

    /// Scans the buffer to locate the start index of the delimiter sequence, using SIMD where appropriate.
    fn findNextDelimiterSequence(self: *SplitIterator, start_pos: usize) ?usize {
        var i = start_pos;
        const first_byte = self.delimiter[0];

        // SIMD vectorisation
        if (use_simd) {
            const v_first: Vec = @splat(first_byte);

            while (i + vec_size <= self.buffer.len) {
                const chunk: Vec = self.buffer[i..][0..vec_size].*;
                const matches = (chunk == v_first);

                var mask = @as(std.meta.Int(.unsigned, vec_size), @bitCast(matches));

                // Iterate matching candidate bytes
                while (mask != 0) {
                    const offset = @ctz(mask);
                    const candidate_idx = i + offset;

                    // Confirm whole delimiter can be found from this position
                    if (candidate_idx + self.delimiter.len <= self.buffer.len) {
                        if (std.mem.eql(u8, self.buffer[candidate_idx .. candidate_idx + self.delimiter.len], self.delimiter)) {
                            return candidate_idx;
                        }
                    }

                    // Clear the lowest set bit to evaluate the next potential match in this chunk
                    mask &= mask -% 1;
                }

                // No valid delimiter started in this block
                i += vec_size;
            }
        }

        // Scalar fallback
        while (i + self.delimiter.len <= self.buffer.len) : (i += 1) {
            if (self.buffer[i] == first_byte) {
                if (std.mem.eql(u8, self.buffer[i .. i + self.delimiter.len], self.delimiter)) {
                    return i;
                }
            }
        }

        return null;
    }

    /// Scans the buffer backwards to locate the start index of the delimiter sequence, using SIMD where appropriate.
    fn findPreviousDelimiterSequence(self: *SplitIterator, end_pos: usize) ?usize {
        if (end_pos < self.delimiter.len) {
            return null;
        }

        var i = end_pos - self.delimiter.len;
        const first_byte = self.delimiter[0];

        // SIMD vectorisation
        if (use_simd) {
            const v_first: Vec = @splat(first_byte);

            while (i >= vec_size - 1) {
                const start = i + 1 - vec_size;
                const chunk: Vec = self.buffer[start..][0..vec_size].*;

                const matches = (chunk == v_first);

                var mask = @as(std.meta.Int(.unsigned, vec_size), @bitCast(matches));

                // Iterate matching candidate bytes
                while (mask != 0) {
                    const leading_zeros = @clz(mask);
                    const offset = vec_size - 1 - leading_zeros;
                    const candidate_idx = start + offset;

                    // Confirm whole delimiter can be found from this position
                    if (candidate_idx + self.delimiter.len <= self.buffer.len) {
                        if (std.mem.eql(u8, self.buffer[candidate_idx .. candidate_idx + self.delimiter.len], self.delimiter)) {
                            return candidate_idx;
                        }
                    }

                    // Clear the highest set bit (most significant bit) to look leftward next
                    // by shifting left on the leading zero count to clear out the matched bit, then reconstruct
                    const bits_to_keep = @as(u4, @intCast(15 - leading_zeros));
                    if (bits_to_keep == 0) {
                        mask = 0;
                    } else {
                        mask &= (@as(u16, 1) << bits_to_keep) - 1;
                    }
                }

                if (i < vec_size) {
                    if (i == 0) {
                        return null;
                    }

                    i = 0;
                    break;
                }

                i -= vec_size;
            }
        }

        // Scalar fallback
        while (i > 0) : (i -= 1) {
            if (self.buffer[i] == first_byte) {
                if (std.mem.eql(u8, self.buffer[i .. i + self.delimiter.len], self.delimiter)) {
                    return i;
                }
            }
        }

        return null;
    }
};

/// Iterator type for SIMD-accelerated tokenisation operations, skipping empty & delimiter-related sequences,
/// mimicking the behaviour of `std.mem.TokenIterator`.
///
/// See:
/// - https://ziglang.org/documentation/master/std/#std.mem.TokenIterator
pub const ScalarTokenIterator = struct {
    buffer: []const u8,
    delimiter: u8,
    index: usize,

    pub fn init(buf: []const u8, delimiter: u8) ScalarTokenIterator {
        return .{
            .buffer = buf,
            .delimiter = delimiter,
            .index = 0,
        };
    }

    /// Returns a slice for the next token, or null when tokenisation is complete.
    pub fn next(self: *ScalarTokenIterator) ?[]const u8 {
        // Skip leading delimiters
        while (self.index < self.buffer.len and self.buffer[self.index] == self.delimiter) {
            self.index = self.fastForwardDelimiters(self.index);
        }

        if (self.index >= self.buffer.len) {
            return null;
        }

        // Find token by resolving the next delimiter
        const start = self.index;
        if (self.findNextDelimiter(self.index)) |delim_idx| {
            self.index = delim_idx;
            return self.buffer[start..self.index];
        }

        // Resolve end of buffer if no delimiter is found
        const end = self.buffer.len;
        self.index = end;

        return self.buffer[start..end];
    }

    /// Returns a slice of the current token, or null if tokenisation is complete. Does not advance to the next token.
    pub fn peek(self: *ScalarTokenIterator) ?[]const u8 {
        // Skip leading delimiters
        var index = self.index;
        while (index < self.buffer.len and self.buffer[index] == self.delimiter) {
            index = self.fastForwardDelimiters(index);
        }

        const start = index;
        if (start >= self.buffer.len) {
            return null;
        }

        // Find token by resolving the next delimiter
        if (self.findNextDelimiter(index)) |delim_idx| {
            index = delim_idx;
            return self.buffer[start..index];
        }

        // Resolve end of buffer if no delimiter is found
        const end = self.buffer.len;
        return self.buffer[start..end];
    }

    /// Returns a slice of the remaining bytes. Does not affect iterator state.
    pub fn rest(self: *ScalarTokenIterator) []const u8 {
        // move to beginning of token
        var index: usize = self.index;
        while (index < self.buffer.len and self.buffer[index] == self.delimiter) {
            index = self.fastForwardDelimiters(index);
        }

        return self.buffer[index..];
    }

    /// Resets the iterator to the initial token.
    pub fn reset(self: *ScalarTokenIterator) void {
        self.index = 0;
    }

    /// SIMD-accelerated strategy to skip consecutive delimiters.
    fn fastForwardDelimiters(self: *ScalarTokenIterator, start: usize) usize {
        var idx = start;
        const len = self.buffer.len;

        // SIMD vectorisation
        if (use_simd) {
            const v_delim: Vec = @splat(self.delimiter);
            while (idx + vec_size <= len) {
                const chunk: Vec = self.buffer[idx..][0..vec_size].*;
                const matches = (chunk == v_delim);

                const mask = @as(std.meta.Int(.unsigned, vec_size), @bitCast(matches));
                if (mask == simd_unsigned_max) {
                    // Chunk can be skipped as all `vec_size` bytes are delimiters
                    idx += vec_size;
                } else {
                    // Count trailing ones (matching bits) to find token start after finding non-delimiter character
                    idx += @ctz(~mask);
                    return idx;
                }
            }
        }

        // Scalar fallback
        while (idx < len and self.buffer[idx] == self.delimiter) : (idx += 1) {}

        return idx;
    }

    /// SIMD-accelerated strategy to locate the next delimiter.
    fn findNextDelimiter(self: *ScalarTokenIterator, start: usize) ?usize {
        var idx = start;
        const len = self.buffer.len;

        // SIMD vectorisation
        if (use_simd) {
            const v_delim: Vec = @splat(self.delimiter);
            while (idx + vec_size <= len) {
                const chunk: Vec = self.buffer[idx..][0..vec_size].*;
                const matches = (chunk == v_delim);

                const mask = @as(std.meta.Int(.unsigned, vec_size), @bitCast(matches));
                if (mask != 0) {
                    // Find the index of the first true bit after at least one delimiter is found to resolve
                    // the delimiter position
                    return idx + @ctz(mask);
                }

                // Skipping chunk if no-delimiter found
                idx += vec_size;
            }
        }

        // Scalar fallback
        while (idx < len) : (idx += 1) {
            if (self.buffer[idx] == self.delimiter) {
                return idx;
            }
        }

        return null;
    }
};
