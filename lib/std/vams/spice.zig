//! STUB: the API of the annex E.2 netlist reader, no behaviour yet.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Diag = @import("Diag.zig");

pub const Request = union(enum) {
    file: struct { path: []const u8 },
};

pub const File = struct { name: []const u8, text: []const u8 };

pub const Refusal = struct {
    code: Code,
    file: u32,
    at: u32,
    len: u32,
    message: []const u8,

    pub const Code = enum(u8) { E0928, E0953 };
};

pub const Output = struct {
    text: []const u8 = "",
    modules: u32 = 0,
    refusals: []const Refusal = &.{},
    unsupported: []const []const u8 = &.{},
    files: []const File = &.{},
    hdl: []const []const u8 = &.{},
};

pub const Netlist = struct {
    gpa: Allocator,
    path: []const u8,
    text: []const u8,
    result: Output = .{},

    pub fn init(gpa: Allocator, path: []const u8, text: []const u8) Netlist {
        return .{ .gpa = gpa, .path = path, .text = text };
    }

    pub fn deinit(n: *Netlist) void {
        n.* = undefined;
    }

    pub fn run(n: *Netlist) Allocator.Error!?Request {
        _ = n;
        return null;
    }

    pub fn answer(n: *Netlist, bytes: ?[]const u8) Allocator.Error!void {
        _ = n;
        _ = bytes;
    }

    pub fn output(n: *const Netlist) Output {
        return n.result;
    }
};
