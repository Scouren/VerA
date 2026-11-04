//! The analog testbench backend behind `--run` and `--emit-exe`
//! (docs/rewrite/exe.md): a fixture's `//!` directives (`Spec`) and the
//! analysed device (`Air.Device`) in, a runner's Zig source out. `link`
//! builds it beside the device; it prints the transcript the fixture's
//! harness compares: every `$strobe`, plus the residual and Jacobian per
//! operating point. It reads no AST and no old module; the runner imports
//! only `contract` and the device. Named for what it writes; renamed `exe`
//! at the switch-over, when the old `codegen/exe` goes.
//!
//! ```zig
//! const s = try bench.Spec.parse(arena, source, null);
//! var facts = bench.facts(arena, &analysis.device);
//! var aw: std.Io.Writer.Allocating = .init(gpa);
//! try bench.writeRunner(&aw.writer, arena, stem, &s.bench, facts);
//! // then `link.buildExe(file, ..., device_text, aw.written())`
//! ```
//!
//! Cites: §2.4, §4.5.2, §9.4; each file cites its own clauses.
//!
//! Contents:
//! - from `bench/spec.zig`: `Spec`, `Bench`, `Harness`, `Facts`, `Digital`, `Binding`, `ParseError`, `RenderError`, `points_max`
//! - from `bench/runner.zig`: `writeRunner`
//! - `pub fn facts(arena: Allocator, device: *const Air.Device) Allocator.Error!Facts`
//! - `pub fn digital(arena: Allocator, program: *const std_sim.Program, names: []const Digital.Name) Allocator.Error!Digital`
//! - `pub fn gridEvent(air: *const Air) ?Air.Inst.Index`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const SysFn = @import("vams").SysFn;
const std_sim = @import("std_sim");
const spec = @import("bench/spec.zig");
const runner = @import("bench/runner.zig");

pub const Spec = spec.Spec;
pub const Bench = spec.Bench;
pub const Harness = spec.Harness;
pub const Facts = spec.Facts;
pub const Digital = spec.Digital;
pub const Binding = spec.Binding;
pub const ParseError = spec.ParseError;
pub const RenderError = spec.RenderError;
pub const points_max = spec.points_max;
pub const writeRunner = runner.writeRunner;

/// What the runner needs from the device besides its text: the §4.5.2
/// operator unknowns' `U` indices, ascending (never forced). The caller
/// sets the switches. `op_states` is allocated in `arena`.
pub fn facts(arena: Allocator, device: *const Air.Device) Allocator.Error!Facts {
    const kinds = device.nodes.items(.kind);
    var ops: std.ArrayList(u32) = .empty;
    for (kinds, 0..) |k, i| if (k == .op_state) try ops.append(arena, @intCast(i));
    assert(ops.items.len <= kinds.len);
    // ponytail: `mem_bytes` 0 sizes `bigStack` by unknowns alone; count the
    // §3.2.2 arrays when a large array overflows the 8 MiB main stack.
    return .{ .op_states = ops.items };
}

/// A mixed design's digital half as the runner embeds it (`Facts.mixed`):
/// `program` saved by `std_sim.serial`, beside its `names`; in `arena`.
pub fn digital(arena: Allocator, program: *const std_sim.Program, names: []const Digital.Name) Allocator.Error!Digital {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std_sim.serial.save(program, &aw.writer) catch return error.OutOfMemory;
    assert(aw.written().len != 0);
    return .{ .program = aw.written(), .names = names };
}

/// The first §5.10.3 `cross`, `above` or `timer` call in `air`, or null:
/// the fixed-grid runner inserts no timepoint at it, so it fires at the
/// first `//! time` past its own (W0750 points at it).
pub fn gridEvent(air: *const Air) ?Air.Inst.Index {
    const tags = air.instructions.items(.tag);
    const data = air.instructions.items(.data);
    for (tags, data, 0..) |t, d, i| {
        if (t != .call) continue;
        const callee = air.extraData(Air.Call, d.ty_pl.payload).data.callee;
        const ev = for ([_]SysFn.Tag{ .cross, .above, .timer }) |e| {
            if (callee == @backingInt(e)) break true;
        } else false;
        if (ev) return @fromBackingInt(@intCast(i));
    }
    return null;
}

test {
    _ = @import("bench/parse.zig");
    _ = @import("bench/operands.zig");
    _ = @import("bench/points.zig");
    _ = @import("bench/parts.zig");
    _ = @import("bench/test.zig");
}
