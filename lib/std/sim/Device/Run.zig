//! One run of a contract device's program (`Device`): a `State` on the
//! heap in an arena of its own, its transcript held until `flush`, and
//! `fork`, the deep copy a step works on. The copy is generic over
//! `State`'s fields, so a field added there is copied without an edit
//! here; a many-pointer in one fails to compile until it has a form.
//! Cites: IEEE 1364-2005 §11.4 (a fork is taken at a tick boundary).
//!
//! Contents:
//! - `pub fn init(p: *const Program) !*Run`
//! - `pub fn fork(r: *const Run) !*Run`
//! - `pub fn flush(r: *Run) void`
//! - `pub fn free(r: *Run) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("../Program.zig");
const SimState = @import("../State.zig");
const gpa = std.heap.smp_allocator;

arena: std.heap.ArenaAllocator,
say: std.Io.Writer.Allocating,
s: SimState,

const Run = @This();

/// Time 0 of `p`.
pub fn init(p: *const Program) !*Run {
    const r = try gpa.create(Run);
    r.arena = .init(gpa);
    errdefer r.free();
    r.say = .init(r.arena.allocator());
    r.s = try SimState.init(r.arena.allocator(), p, &r.say.writer);
    // §17.2 file tasks and §18 dumps work beside the host's cwd.
    // ponytail: a rejected step's writes stay written; buffer them per
    // step if a host must see files roll back.
    r.s.io = std.Io.Threaded.global_single_threaded.io();
    assert(r.s.out == &r.say.writer);
    return r;
}

/// A deep copy of `r` at its tick boundary, with an empty transcript.
pub fn fork(r: *const Run) !*Run {
    const c = try gpa.create(Run);
    c.arena = .init(gpa);
    errdefer c.free();
    const a = c.arena.allocator();
    c.say = .init(a);
    c.s = try dupe(SimState, a, r.s);
    c.s.arena = a;
    c.s.out = &c.say.writer;
    c.s.scratch = .init(a);
    assert(c.s.p == r.s.p);
    return c;
}

/// The held transcript to stderr: a host's stdout may carry its own
/// results.
pub fn flush(r: *Run) void {
    const said = r.say.written();
    if (said.len != 0) std.debug.print("{s}", .{said});
    r.say.clearRetainingCapacity();
    assert(r.say.written().len == 0);
}

/// Frees the run and everything it allocated; `r` is gone after.
pub fn free(r: *Run) void {
    r.arena.deinit();
    gpa.destroy(r);
}

// ---- private ----

/// A deep copy of `x` into `a`: every slice and list it reaches is new;
/// single pointers (the `Program`, the writer) are shared. The fields
/// `fork` resets (allocators, the scratch arena) are copied shallow here.
fn dupe(comptime T: type, a: Allocator, x: T) Allocator.Error!T {
    if (comptime !hasSlice(T)) return x;
    if (comptime isMulti(T)) return x.clone(a);
    if (comptime isList(T)) {
        var out = try @TypeOf(x).initCapacity(a, x.capacity);
        for (x.items) |e| out.appendAssumeCapacity(try dupe(@TypeOf(x.items[0]), a, e));
        return out;
    }
    if (comptime isQueue(T)) {
        const buf = try a.alloc(@TypeOf(x.items[0]), x.cap);
        for (buf[0..x.items.len], x.items) |*d, e| d.* = try dupe(@TypeOf(e), a, e);
        var out = x;
        out.items = buf[0..x.items.len];
        return out;
    }
    if (comptime isHashMap(T)) {
        var out = try x.clone(a);
        var it = out.valueIterator();
        while (it.next()) |v| v.* = try dupe(@TypeOf(v.*), a, v.*);
        return out;
    }
    switch (@typeInfo(T)) {
        .optional => |o| return if (x) |v| try dupe(o.child, a, v) else null,
        .array => |ar| {
            var out: T = undefined;
            for (&out, x) |*d, e| d.* = try dupe(ar.child, a, e);
            return out;
        },
        .pointer => |ptr| {
            comptime assert(ptr.size == .slice);
            const out = try a.alloc(ptr.child, x.len);
            for (out, x) |*d, e| d.* = try dupe(ptr.child, a, e);
            return out;
        },
        .@"struct" => |s| {
            var out: T = x;
            inline for (s.field_names, s.field_types) |name, F| @field(out, name) = try dupe(F, a, @field(x, name));
            return out;
        },
        .@"union" => switch (x) {
            inline else => |v, tag| return @unionInit(T, @tagName(tag), try dupe(@TypeOf(v), a, v)),
        },
        else => @compileError("Device.dupe: no copy for " ++ @typeName(T)),
    }
}

/// Whether a value of `T` reaches memory a copy must duplicate: a slice,
/// or a container of the standard library holding one.
fn hasSlice(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == Allocator or T == std.heap.ArenaAllocator or T == std.Io) return false;
    if (isMulti(T) or isList(T) or isQueue(T) or isHashMap(T)) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| hasSlice(o.child),
        .array => |ar| hasSlice(ar.child),
        .pointer => |ptr| switch (ptr.size) {
            .slice => true,
            // The `Program` and the writer: shared.
            .one => false,
            .many, .c => @compileError("Device.dupe: a many-pointer in " ++ @typeName(T)),
        },
        .@"struct" => |s| inline for (s.field_types) |F| {
            if (hasSlice(F)) break true;
        } else false,
        .@"union" => |u| inline for (u.field_types) |F| {
            if (hasSlice(F)) break true;
        } else false,
        else => false,
    };
}

fn isMulti(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Field") and @hasDecl(T, "Slice") and @hasField(T, "bytes");
}

fn isList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "capacity");
}

fn isQueue(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "cap");
}

fn isHashMap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "KV") and @hasField(T, "metadata");
}
