const std = @import("std");

const thesaurus = @import("thesaurus.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();

    var builder = thesaurus.Builder.init(allocator, .default);
    try builder.build(
        "./.project/resources/mondo.json",
        "./.output/en_ontology.ths",
    );
}
