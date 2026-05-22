//! Module implementing FS-related utilities.
const std = @import("std");

const types = @import("types.zig");
const strutil = @import("strutil.zig");

const Error = types.Error;

/// Det. whether path is at least 1 char long and not just some variation of `.` or `..` _etc_.
pub fn isLikelyMakeablePath(path: []const u8) bool {
    const n = path.len;
    if (n == 0) {
        return false;
    }

    const input = std.fs.path.basename(path);
    if (input.len == 0) {
        return false;
    }

    return strutil.containsMoreThanScalar(input, '.');
}

/// Det. whether the specified path is likely to refer to a file rather than a dir.
pub fn ensureFilePath(path: []const u8, create_paths: bool) Error![]const u8 {
    if (path.len == 0) {
        return error.ExpectedFilePath;
    }

    const filepath = blk: {
        switch (path[path.len - 1]) {
            std.fs.path.sep, '/' => {
                return error.ExpectedFilePath;
            },
            else => break :blk path,
        }
    };

    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => return error.ExpectedFilePath,
        error.FileNotFound => {
            if (create_paths) {
                const dirname = std.fs.path.dirname(filepath) orelse "";
                if (isLikelyMakeablePath(dirname)) {
                    std.fs.cwd().makePath(dirname) catch {
                        return error.MakePathsError;
                    };
                }
            }

            return filepath;
        },
        else => |e| return e,
    };

    switch (stat.kind) {
        .file => return filepath,
        else => return error.ExpectedFilePath,
    }
}

/// Det. whether the specified path is likely to refer to a dir rather than a file.
pub fn ensureDirPath(path: []const u8, create_paths: bool) Error![]const u8 {
    if (path.len == 0) {
        return error.ExpectedDirPath;
    }

    const dirpath = blk: {
        switch (path[path.len - 1]) {
            std.fs.path.sep, '/' => break :blk path,
            else => {
                const basename = std.fs.path.basename(path);
                if (std.mem.indexOfScalar(u8, basename, '.') != null) {
                    break :blk (std.fs.path.dirname(path) orelse ".");
                }

                break :blk path;
            },
        }
    };

    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => return dirpath,
        error.FileNotFound => |e| {
            if (create_paths) {
                if (isLikelyMakeablePath(dirpath)) {
                    std.fs.cwd().makePath(dirpath) catch {
                        return error.MakePathsError;
                    };
                }

                return dirpath;
            }

            return e;
        },
        else => |e| return e,
    };

    switch (stat.kind) {
        .directory => return dirpath,
        else => return error.ExpectedDirPath,
    }
}
