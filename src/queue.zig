//! Module implementing SPSC Queue-related logic.
const std = @import("std");

const types = @import("types.zig");

const Error = types.Error;

/// A container of strings to be sent as a batch to the writer consumer.
pub const Batch = struct {
    const Self = @This();

    items: [][]u8,
    next: usize,

    pub fn init(allocator: std.mem.Allocator, size: usize) Error!*Self {
        const new = try allocator.create(Batch);
        new.* = .{
            .items = try allocator.alloc([]u8, size),
            .next = 0,
        };

        return new;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (0..self.next) |i| {
            allocator.free(self.items[i]);
        }
        allocator.free(self.items);
    }

    pub fn isFull(self: *Self) bool {
        return (self.next >= self.items.len);
    }

    pub fn isEmpty(self: *Self) bool {
        return self.next < 1;
    }

    pub fn push(self: *Self, value: []u8) Error!void {
        if (self.next >= self.items.len) {
            return error.ReachedCapacity;
        }

        self.items[self.next] = value;
        self.next += 1;
    }
};

/// A simple Bounded Channel for passing batches of strings between a producer & consumer.
pub const BoundedChannel = struct {
    const Self = @This();

    buffer: []*Batch,
    head: usize = 0,
    tail: usize = 0,
    size: usize = 0,
    mutex: std.Thread.Mutex = .{},
    not_full: std.Thread.Condition = .{},
    not_empty: std.Thread.Condition = .{},
    is_closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, size: usize) Error!Self {
        return .{
            .buffer = try allocator.alloc(*Batch, size),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn push(self: *Self, batch: *Batch) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.size == self.buffer.len and !self.is_closed) {
            self.not_full.wait(&self.mutex);
        }

        if (self.is_closed) {
            return error.ChannelClosed;
        }

        self.buffer[self.tail] = batch;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.size += 1;
        self.not_empty.signal();
    }

    pub fn pop(self: *Self) ?*Batch {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.size == 0 and !self.is_closed) {
            self.not_empty.wait(&self.mutex);
        }

        if (self.size == 0 and self.is_closed) {
            return null;
        }

        const batch = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.size -= 1;
        self.not_full.signal();
        return batch;
    }
};
