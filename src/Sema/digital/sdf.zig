//! §16 SDF annotation in the digital lowering: an `$sdf_annotate` call in;
//! its `Program.SdfCall`, and once every scope exists, per scope what an
//! annotation matches by name (`Program.sdf_scopes`: its module's name,
//! whether it is lexical, its ports and its module's specparams, each with
//! the slot the scope binds it to), out, as the bridge builds them from
//! lib/sim/digital's scopes.
//! Cites: IEEE 1364-2005 §16.1, §17.2.10.
//!
//! Contents:
//! - `pub fn task(l: *Lower, args: []const Inst.Ref) Error!u32`
//! - `pub fn scopes(l: *Lower) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const vcd = @import("vcd.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// §17.2.10 `$sdf_annotate(file [, scope [, config, log, mtm ...]])`.
pub fn task(l: *Lower, args: []const Inst.Ref) Error!u32 {
    if (args.len == 0 or args[0] == .none) return l.refuse("an $sdf_annotate with no file");
    l.sdf = true;
    const scope = if (args.len > 1 and args[1] != .none) blk: {
        const t = try vcd.target(l, args[1]);
        if (t.slot) return l.refuse("an $sdf_annotate scope that names a variable");
        break :blk t.at;
    } else l.frames.items[l.rootFrame(l.frame)].scope;
    const call: Program.SdfCall = .{ .name = try expr.self_(l, args[0], 0), .scope = scope, .mtm = if (args.len > 4 and args[4] != .none) try expr.self_(l, args[4], 0) else none };
    return l.b.extraOf(call);
}

/// Writes `Program.sdf_scopes` when an `$sdf_annotate` was lowered: an
/// instance's scope its ports and specparams; any other (lexical) scope its
/// module's names, bound to nothing of its own.
pub fn scopes(l: *Lower) Error!void {
    if (!l.sdf) return;
    const n = l.b.scopes.items.len;
    const out = try l.a.alloc(Program.SdfScope, n);
    const frame_of = try l.a.alloc(u32, n);
    @memset(frame_of, none);
    for (l.instance_frame) |f| frame_of[l.frames.items[f].scope] = f;
    for (out, 0..) |*o, s| {
        // The instance whose module the scope is part of.
        var at: u32 = @intCast(s);
        var steps: usize = 0;
        while (frame_of[at] == none and steps <= n) : (steps += 1) at = l.b.scopes.items[at].parent;
        const f = frame_of[at];
        if (f == none) return l.refuse("a scope in no instance");
        const vir = l.virOf(f);
        const d = l.zcu.instances.items(.module)[@backingInt(l.frames.items[f].instance)];
        const m = Lower.payload(vir, Inst.Module, l.zcu.declRow(d).inst);
        const own = frame_of[s] != none;
        const names = try vcd.namesOf(l, f);
        var ports: std.ArrayList(u32) = .empty;
        for (vir.body(m.ports)) |p| {
            const text = vcd.declText(vir, p);
            const name = try l.b.string(text);
            const slot = if (own) if (names.get(text)) |nm| nm.slot else none else none;
            try ports.appendSlice(l.a, &.{ name.start, name.len, slot });
        }
        var specs: std.ArrayList(u32) = .empty;
        if (own) try specparams(l, vir, vir.body(m.body), names, &specs, 0);
        o.* = .{ .module = try l.b.string(vir.string(l.zcu.declRow(d).name)), .lexical = !own, .ports = try l.b.listOf(ports.items), .specparams = try l.b.listOf(specs.items) };
    }
    l.b.p.sdf_scopes = out;
}

// ---- private ----

/// The specparams of `items` (and of the specify blocks among them), each
/// as its name's text and the slot `names` binds it to.
fn specparams(l: *Lower, vir: *const Vir, items: []const Inst.Index, names: std.StringHashMapUnmanaged(digital.Name), out: *std.ArrayList(u32), depth: u32) Error!void {
    assert(depth <= 1);
    for (items) |i| switch (Lower.tag(vir, i)) {
        .param => {
            const p = Lower.payload(vir, Inst.Param, i);
            if (p.flags.kind != .specparam) continue;
            const text = vir.string(p.name);
            const nm = names.get(text) orelse continue;
            const s = try l.b.string(text);
            try out.appendSlice(l.a, &.{ s.start, s.len, nm.slot });
        },
        .specify => if (depth == 0) try specparams(l, vir, vir.body(Lower.payload(vir, Inst.Process, i).body), names, out, depth + 1),
        else => {}, // else: no other item declares a specparam
    };
}
