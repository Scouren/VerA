//! The links of the digital lowering made once every process is compiled:
//! the compiled drivers, pass switches, named blocks and disables in; per
//! slot the pcs its change wakes (`Program.fan`), and each `disable`
//! pointed at its block's pc range or its task, out.
//! Cites: IEEE 1364-2005 §6.1, §7.6, §10.3, A.6.5.
//!
//! Contents:
//! - `pub fn fanout(l: *Lower) Error!void`
//! - `pub fn resolveDisables(l: *Lower) Error!void`
//! - `pub fn blockKey(l: *Lower, f: u32, name: []const u8) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// §6.1/§7.6 per slot, the pcs of the continuous drivers and controlled
/// pass switches that read it, drivers first.
pub fn fanout(l: *Lower) Error!void {
    const n = l.b.p.slots.len;
    var readers: std.ArrayList(struct { pc: u32, sensitivity: Program.List }) = .empty;
    for (l.b.p.drivers, l.driver_pcs.items) |d, at| try readers.append(l.a, .{ .pc = at, .sensitivity = d.sensitivity });
    for (l.trans.items) |t| if (t.pc != none) try readers.append(l.a, .{ .pc = t.pc, .sensitivity = t.sensitivity });
    const start = try l.a.alloc(u32, n + 1);
    @memset(start, 0);
    for (readers.items) |r| for (l.b.extra.items[r.sensitivity.start..][0..r.sensitivity.len]) |slot| {
        start[slot + 1] += 1;
    };
    for (1..n + 1) |k| start[k] += start[k - 1];
    const fill = try l.a.dupe(u32, start[0..n]);
    const fan = try l.a.alloc(u32, start[n]);
    for (readers.items) |r| for (l.b.extra.items[r.sensitivity.start..][0..r.sensitivity.len]) |slot| {
        fan[fill[slot]] = r.pc;
        fill[slot] += 1;
    };
    assert(std.mem.eql(u32, fill, start[1..]));
    l.b.p.fan_start = start;
    l.b.p.fan = fan;
}

/// A.6.5 every `disable`, now that every block is compiled: of the named
/// block its name finds in the frames around it (lexically, up to its
/// instance), else of the task of that name in its instance (§10.3).
pub fn resolveDisables(l: *Lower) Error!void {
    for (l.disables.items) |d| {
        var f = d.frame;
        var steps: u32 = 0;
        const range: ?[2]u32 = while (f != none) : (f = l.frames.items[f].parent) {
            steps += 1;
            assert(steps <= l.frames.items.len);
            if (l.block_ranges.get(try blockKey(l, f, d.name))) |r| break r;
        } else null;
        if (range) |r| {
            l.b.setInst(d.pc, .disable_block, r[0], r[1]);
            continue;
        }
        const root = l.rootFrame(d.frame);
        const row = for (l.subs.items, 0..) |s, k| {
            if (l.rootFrame(s.outer) != root) continue;
            const vir = l.virOf(s.outer);
            if (std.mem.eql(u8, vir.string(Lower.payload(vir, Inst.Function, s.decl).name), d.name)) break k;
        } else return l.refuseFmt("a disable of `{s}`, which names no block or task the lowering finds", .{d.name});
        if (l.subs.items[row].function) return l.refuse("§10.3 a disable of a function");
        l.b.setInst(d.pc, .disable_task, @intCast(row), 0);
    }
}

/// The key of the named block `name` compiled in frame `f`.
pub fn blockKey(l: *Lower, f: u32, name: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(l.a, "{d}:{s}", .{ f, name });
}

// ---- private ----
