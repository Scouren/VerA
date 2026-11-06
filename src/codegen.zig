//! The `codegen` module (Zig's `src/codegen.zig`): one analysed device
//! (`Air`, its `Air.Device` tables, the float verdict) in, one device's
//! source out as a `link.Output`, through the backend the caller names.
//! It reads nothing else: no AST, no elaboration (docs/rewrite/codegen.md).
//! One backend today, `zig` (`codegen/zig.zig`); the others of lib/TODO.md
//! §5 join `Backend` as they are written.
//!
//! ```zig
//! const roots = try codegen.floatRoots(arena, &a.air, &a.device);
//! var f = try Air.Float.analyze(gpa, a.air, ip, .{ .params = params, .roots = roots }, &wip);
//! var r = try codegen.generate(gpa, .zig, .{ .air = &a.air, .ip = ip, .device = &a.device, .verdict = &f.verdict }, .{});
//! defer r.deinit(gpa);
//! switch (r) { .ok => |out| ... link.File.flush(..., out, ...), .fail => |why| ... }
//! ```
//!
//! Cites: VAMS-2023 §5.6 and §5.6.1.3 (a contribution is a float unit).
//!
//! Contents:
//! - `pub const zig`: the Zig backend; `pub const bench`: the analog testbench backend; `pub const digital_next`: the `.v` backends; `pub const rtlil`: the RTLIL backend; `pub const examples`: hand-built devices (test support)
//! - `pub const Backend = enum { zig }`
//! - `pub const Input = struct`, `pub const Options = struct`
//! - `pub const Result = union(enum) { ok: link.Output, fail: []u8 }`, `Result.deinit`
//! - `pub fn generate(gpa: Allocator, backend: Backend, in: Input, options: Options) Allocator.Error!Result`
//! - `pub fn floatRoots(arena: Allocator, air: *const Air, device: *const Air.Device) Allocator.Error![]const Air.Float.Root`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const link = @import("link");
/// The Zig backend.
pub const zig = @import("codegen/zig.zig");
/// Hand-built devices for shapes Sema does not lower yet (test support).
pub const examples = @import("codegen/examples.zig");
/// The analog testbench backend (`--run`, `--emit-exe`).
pub const bench = @import("codegen/bench.zig");
/// The `--emit-rtlil` backend: its refusals and its text.
pub const rtlil = @import("codegen/rtlil.zig");
/// The `.v` backends over `std_sim.Program` (`--emit-exe` today).
pub const digital_next = @import("codegen/digital_next.zig");

/// The language a backend writes.
pub const Backend = enum { zig };

/// One analysed device. Borrowed for the call.
pub const Input = struct {
    air: *const Air,
    ip: *const InternPool,
    device: *const Air.Device,
    /// `Air.Float`'s verdict over `floatRoots`' roots, in their order; null
    /// writes every unit strict.
    verdict: ?*const Air.Float.Verdict = null,
};

/// What the caller decides beyond the input.
pub const Options = struct {
    /// Every unit strict, whatever the verdict: the oracle's bit-identity
    /// mode (docs/rewrite/codegen.md, oracle step 3).
    strict: bool = false,
};

/// A device's text, or why the backend cannot write it yet. Both payloads
/// are the `gpa`'s passed to `generate`; free with `deinit`.
pub const Result = union(enum) {
    ok: link.Output,
    fail: []u8,

    /// Frees the payload.
    pub fn deinit(r: *Result, gpa: Allocator) void {
        switch (r.*) {
            .ok => |o| gpa.free(o.text),
            .fail => |m| gpa.free(m),
        }
        r.* = undefined;
    }
};

/// Writes `in`'s device with `backend`.
pub fn generate(gpa: Allocator, backend: Backend, in: Input, options: Options) Allocator.Error!Result {
    assert(in.air.instructions.len != 0);
    if (in.verdict) |v| assert(v.modes.len == in.device.contributions.len);
    return switch (backend) {
        .zig => zig.generate(gpa, in, options),
    };
}

/// The float units `generate` reads a verdict for: one per §5.6.1.3
/// contribution, its slice every `assign` to its resistive and reactive
/// sums and to its charge sites' slots. Allocated in `arena`.
pub fn floatRoots(arena: Allocator, air: *const Air, device: *const Air.Device) Allocator.Error![]const Air.Float.Root {
    const n = device.contributions.len;
    const of = try arena.alloc(u32, air.instructions.len);
    @memset(of, std.math.maxInt(u32));
    for (device.contributions.items(.resist), device.contributions.items(.react), 0..) |r, q, k| {
        of[@backingInt(r)] = @intCast(k);
        of[@backingInt(q)] = @intCast(k);
    }
    for (device.charge_sites.items(.slot), device.charge_sites.items(.contrib)) |s, c| of[@backingInt(s)] = @backingInt(c);
    const refs = try arena.alloc(std.ArrayList(Air.Inst.Ref), n);
    @memset(refs, .empty);
    for (air.instructions.items(.tag), air.instructions.items(.data), 0..) |tag, data, i| {
        if (tag != .assign) continue;
        const k = of[@backingInt(data.bin_op.lhs.toIndex().?)];
        if (k == std.math.maxInt(u32)) continue;
        try refs[k].append(arena, .fromIndex(@fromBackingInt(@intCast(i))));
    }
    const roots = try arena.alloc(Air.Float.Root, n);
    for (roots, refs) |*r, l| r.* = .{ .refs = l.items };
    assert(roots.len == n);
    return roots;
}

test {
    _ = zig;
    _ = bench;
    _ = digital_next;
    _ = @import("codegen/test.zig");
}
