//! IEEE 1364-2005 §19.8 the digital lowering's time scales: each module's
//! `timescale in (its Vir stamp, the preprocessor's directive regions),
//! its `Program.Time` (`Lower.module_times`) and the design's tick out; a
//! directive written inside a module, and some modules with one and some
//! without, refused as lib/sim/digital refused them.
//! Cites: IEEE 1364-2005 §19.8.
//!
//! Contents:
//! - `pub fn timeScales(l: *Lower) Error!void`
//! - `pub fn moduleAt(l: *const Lower, d: Zcu.Decl) u32`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const Zcu = @import("../../Zcu.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// IEEE 1364-2005 §19.8: each module's `timescale (the last before it, or
/// none); some modules with one and some without is an error. The design's
/// tick is the finest precision of all of them, `s` when none is given. A
/// mixed design's modules before its first `timescale take that one, as
/// lib/sim/digital's `mixedTimescales` moves it to the text's start: the
/// shipped prelude's modules come ahead of every directive the source wrote.
pub fn timeScales(l: *Lower) Error!void {
    const zcu = l.zcu;
    const first = if (l.options.mixed) firstTimescale(l) else null;
    var finest: i32 = 0;
    var set: u32 = 0;
    var total: u32 = 0;
    var ahead = true;
    for (0..zcu.files.len) |f| {
        const vir = zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.decls()) |d| {
            if (d.kind != .module and d.kind != .macromodule and d.kind != .connectmodule) continue;
            try timescaleOutside(l, f, d.inst);
            const m = Lower.payload(vir, Inst.Module, d.inst);
            total += 1;
            const stamp = stampOf(m, first, &ahead) orelse continue;
            set += 1;
            const p = try quantum(l, stamp.precision.get());
            finest = @min(finest, @backingInt(p));
        }
    }
    if (set != 0 and set != total) {
        l.why = "§19.8: it shall be an error if some modules have a `timescale specified and others do not";
        l.why_at = moduleAt(l, zcu.instances.items(.module)[0]);
        return error.Rejected;
    }
    l.b.p.finest = finest;
    const global: std_sim.time.Quantum = @fromBackingInt(@intCast(finest));
    ahead = true;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| {
            if (d.kind != .module and d.kind != .macromodule and d.kind != .connectmodule and d.kind != .primitive) continue;
            var unit: std_sim.time.Quantum = .s;
            var precision: std_sim.time.Quantum = .s;
            if (d.kind != .primitive) if (stampOf(Lower.payload(vir, Inst.Module, d.inst), first, &ahead)) |stamp| {
                unit = try quantum(l, stamp.unit.get());
                precision = try quantum(l, stamp.precision.get());
            };
            const scale = std_sim.time.Scale.init(unit, precision, global) catch return l.refuse("an invalid timescale");
            try l.module_times.put(l.a, .{ .file = file, .index = @fromBackingInt(@intCast(k)) }, .{ .scale = scale, .unit_exp = @backingInt(unit) });
        }
    }
}

/// The source offset of module `d`'s declaration (its main token), where
/// lib/sim/digital reports a whole-design error.
pub fn moduleAt(l: *const Lower, d: Zcu.Decl) u32 {
    const vir = l.zcu.fileVir(d.file);
    const tree = l.options.sources[@backingInt(d.file)].tree;
    const n = vir.instructions.items(.data)[@backingInt(l.zcu.declRow(d).inst)].pl_node.src_node;
    return tree.tokenStart(tree.nodeMainToken(n));
}

// ---- private ----

/// §19.8 a `timescale written between module `m`'s header and its
/// `endmodule` (file `f`): §19.8 gives a directive to "all modules that
/// follow" and says nothing of one inside a module; lib/sim/digital refused
/// it at the module's name, as iverilog does.
fn timescaleOutside(l: *Lower, f: usize, m: Inst.Index) Error!void {
    const tree = l.options.sources[f].tree;
    const vir = l.zcu.fileVir(@fromBackingInt(@intCast(f)));
    const first = tree.nodeMainToken(vir.instructions.items(.data)[@backingInt(m)].pl_node.src_node);
    var end = first;
    while (end + 1 < tree.tokens.len and tree.tokenTag(end) != .keyword_endmodule) end += 1;
    assert(end >= first);
    for (l.options.sources[f].pp.directives.timescales) |t| if (t.at > tree.tokenStart(first) and t.at < tree.tokenStart(end)) {
        l.why = "§19.8: a `timescale directive is written outside a module definition, not inside one";
        l.why_at = tree.tokenStart(first);
        return error.Rejected;
    };
}

/// The stamp of a mixed design's first module with a `timescale.
fn firstTimescale(l: *Lower) ?Inst.Module.Stamp {
    assert(l.options.mixed);
    for (0..l.zcu.files.len) |f| {
        const vir = l.zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.decls()) |d| {
            if (d.kind != .module and d.kind != .macromodule and d.kind != .connectmodule) continue;
            const m = Lower.payload(vir, Inst.Module, d.inst);
            if (m.stamp.flags.has_timescale) return m.stamp;
        }
    }
    return null;
}

/// Module `m`'s `timescale: its own, else `first` (a mixed design's) while
/// no module before it had one (`ahead`, cleared at the first that does),
/// else none.
fn stampOf(m: Inst.Module, first: ?Inst.Module.Stamp, ahead: *bool) ?Inst.Module.Stamp {
    if (m.stamp.flags.has_timescale) {
        ahead.* = false;
        return m.stamp;
    }
    return if (ahead.*) first else null;
}

fn quantum(l: *Lower, seconds: f64) Error!std_sim.time.Quantum {
    return std_sim.time.Quantum.fromSeconds(seconds) catch l.refuse("an unsupported time unit");
}
