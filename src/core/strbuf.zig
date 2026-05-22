//! StringBuffer / StringBuilder implementation.
const std = @import("std");

const types = @import("types.zig");
const strutil = @import("strutil.zig");

const Error = types.Error;

/// A variable length, resizable collection of u8 elements.
pub const StringBuffer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    pos: usize,
    buf: []u8,

    pub fn init(allocator: std.mem.Allocator, size: usize) Error!Self {
        const buf = try allocator.alloc(u8, size);
        return .{
            .allocator = allocator,
            .pos = 0,
            .buf = buf,
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.buf);
    }

    pub fn len(self: Self) usize {
        return self.pos;
    }

    pub fn bufSize(self: Self) usize {
        return self.buf.len;
    }

    pub fn string(self: Self) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn reset(self: *Self) void {
        self.pos = 0;
    }

    pub fn truncate(self: *Self, n: usize) void {
        const pos = self.pos;
        if (n >= pos) {
            self.pos = 0;
            return;
        }
        self.pos = pos - n;
    }

    pub fn skip(self: *Self, n: usize) Error!StringBufferView {
        try self.ensureUnusedCapacity(n);

        const pos = self.pos;
        self.pos = pos + n;
        return .{
            .pos = pos,
            .size = pos + n,
            .buf = self,
        };
    }

    pub fn write(self: *Self, data: []const u8) Error!void {
        try self.ensureUnusedCapacity(data.len);
        self.writeAssumeCapacity(data);
    }

    pub fn writeByte(self: *Self, b: u8) Error!void {
        try self.ensureUnusedCapacity(1);
        self.writeByteAssumeCapacity(b);
    }

    pub fn escapeWrite(self: *Self, data: []const u8) !void {
        // Ref:
        // - https://ziglang.org/documentation/master/std/#std.Io.Writer.printInt
        const n = data.len;
        var i: usize = 0;
        while (i < n) {
            const sz = strutil.getSizeUtf8(data[i]);
            switch (sz) {
                1 => switch (data[i]) {
                    '\n' => try self.write("\\n"),
                    '\r' => try self.write("\\r"),
                    '\t' => try self.write("\\t"),
                    '\\' => try self.write("\\\\"),
                    '"' => try self.write("\\\""),
                    '|' => try self.write("||"),
                    '\'' => try self.writeByte('\''),
                    else => |byte| try self.writeByte(byte),
                },
                else => try self.write(data[i..(i + sz)]),
            }

            i += sz;
        }
    }

    pub fn ensureUnusedCapacity(self: *Self, n: usize) Error!void {
        return self.ensureTotalCapacity(self.pos + n);
    }

    pub fn ensureTotalCapacity(self: *Self, required_capacity: usize) Error!void {
        const buf = self.buf;
        if (required_capacity <= buf.len) {
            return;
        }

        var new_capacity = buf.len;
        while (true) {
            new_capacity +|= new_capacity / 2 + 8;
            if (new_capacity >= required_capacity) break;
        }

        if (self.allocator.resize(buf, new_capacity)) {
            const new_buffer = buf.ptr[0..new_capacity];
            self.buf = new_buffer;
            return;
        }

        const new_buffer = try self.allocator.alloc(u8, new_capacity);
        @memcpy(new_buffer[0..buf.len], buf);

        self.allocator.free(self.buf);
        self.buf = new_buffer;
    }

    pub fn writeAssumeCapacity(self: *Self, data: []const u8) void {
        const pos = self.pos;
        writeBytesInto(self.buf, pos, data);
        self.pos = pos + data.len;
    }

    pub fn writeByteAssumeCapacity(self: *Self, b: u8) void {
        const pos = self.pos;
        writeByteInto(self.buf, pos, b);
        self.pos = pos + 1;
    }

    pub fn writeAt(self: *Self, data: []const u8, pos: usize) void {
        @memcpy(self.buf[pos .. pos + data.len], data);
    }

    pub fn copy(self: Self, allocator: std.mem.Allocator) Error![]u8 {
        return try allocator.dupe(u8, self.buf[0..self.pos]);
    }
};

/// A fixed length view of the StringBuffer.
pub const StringBufferView = struct {
    pos: usize,
    size: usize,
    buf: *StringBuffer,

    pub fn write(self: *StringBufferView, data: []const u8) Error!void {
        const pos = self.pos;
        if (pos >= self.size) {
            return error.OutOfCapacity;
        }
        writeBytesInto(self.buf.buf, pos, data);
        self.pos = pos + data.len;
    }

    pub fn writeByte(self: *StringBufferView, b: u8) Error!void {
        const pos = self.pos;
        if (pos >= self.size) {
            return error.OutOfCapacity;
        }
        writeByteInto(self.buf.buf, pos, b);
        self.pos = pos + 1;
    }
};

inline fn writeByteInto(buf: []u8, pos: usize, b: u8) void {
    buf[pos] = b;
}

inline fn writeBytesInto(buf: []u8, pos: usize, data: []const u8) void {
    const end_pos = pos + data.len;
    @memcpy(buf[pos..end_pos], data);
}
