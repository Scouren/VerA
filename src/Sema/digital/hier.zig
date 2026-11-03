//! Downward hierarchical names of the digital lowering (§12.5): a `field`
//! chain in `Lower.frame` (`u.n0`, `u.v.n0`) whose head is a child instance
//! of the current instance in; the `Name` the last part binds in the
//! instance the rest of the chain reaches, out. An upward or absolute name,
//! an element of an instance array and a name inside a generate block of
//! the child are refused by name.
//! Cites: IEEE 1364-2005 §12.5.
//!
//! Contents:
//! - `pub fn field(l: *Lower, i: Inst.Index) Error!Name`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Name = digital.Name;
const none = digital.none;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The name `field` instruction `i` (of `Lower.frame`) reaches.
pub fn field(l: *Lower, i: Inst.Index) Error!Name {
    const vir = l.virOf(l.frame);
    const fd = Lower.payload(vir, Inst.Field, i);
    const k = try instanceOf(l, vir, fd.operand, 0);
    const f = l.instance_frame[k];
    const want = vir.string(fd.name);
    const cvir = l.virOf(f);
    var it = l.frames.items[f].names.iterator();
    while (it.next()) |e| if (std.mem.eql(u8, declName(cvir, e.key_ptr.*), want)) {
        const n = l.names.items[e.value_ptr.*];
        if (n.kind == .sub or n.kind == .scope) return l.refuse("a hierarchical name of a task, function or scope read as a value");
        return n;
    };
    return l.refuse("a hierarchical name its instance does not declare at its top");
}

// ---- private ----

/// The child instance `r` names from `Lower.frame`: an `instance` the
/// current instance holds, or a child of one a shorter chain reaches.
fn instanceOf(l: *Lower, vir: *const Vir, r: Inst.Ref, depth: u32) Error!u32 {
    if (depth > l.frames.items.len) return l.refuse("a hierarchical name nested past the design");
    const i = r.toIndex() orelse return l.refuse("a hierarchical name of nothing");
    const root = l.rootFrame(l.frame);
    switch (Lower.tag(vir, i)) {
        .decl_ref => {
            const d = vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
            if (Lower.tag(vir, d) != .instance) return l.refuse("a hierarchical name whose head is no instance");
            return only(l, for (l.sites, 0..) |s, k| {
                if (s.frame != none and s.inst == d and l.rootFrame(s.frame) == root) break @intCast(k);
            } else none, d, root);
        },
        .field => {
            const fd = Lower.payload(vir, Inst.Field, i);
            const parent = try instanceOf(l, vir, fd.operand, depth + 1);
            const want = vir.string(fd.name);
            const pf = l.instance_frame[parent];
            const pvir = l.virOf(pf);
            for (l.sites, 0..) |s, k| {
                if (s.frame == none or l.rootFrame(s.frame) != pf) continue;
                if (std.mem.eql(u8, pvir.string(Lower.payload(pvir, Inst.Instance, s.inst).name), want)) {
                    if (Lower.payload(pvir, Inst.Instance, s.inst).range.len != 0) return l.refuse("a hierarchical name through an instance array");
                    return @intCast(k);
                }
            }
            return l.refuse("a hierarchical name of an instance its parent does not hold");
        },
        else => return l.refuse("an upward or absolute hierarchical name"),
    }
}

/// `k` when it is the one instance `d` makes in the instance of frame
/// `root` (an instance array makes several), else refused.
fn only(l: *Lower, k: u32, d: Inst.Index, root: u32) Error!u32 {
    if (k == none) return l.refuse("a hierarchical name of an instance the walk did not place");
    var count: u32 = 0;
    for (l.sites) |s| if (s.frame != none and s.inst == d and l.rootFrame(s.frame) == root) {
        count += 1;
    };
    if (count != 1) return l.refuse("a hierarchical name through an instance array");
    assert(k < l.sites.len);
    return k;
}

/// The name declaration `d` declares, or "" for one that names nothing a
/// hierarchical name reaches.
fn declName(vir: *const Vir, d: Inst.Index) []const u8 {
    return vir.string(switch (Lower.tag(vir, d)) {
        .variable => Lower.payload(vir, Inst.Variable, d).name,
        .net => Lower.payload(vir, Inst.Net, d).name,
        .io => Lower.payload(vir, Inst.Io, d).name,
        .param => Lower.payload(vir, Inst.Param, d).name,
        .event => Lower.payload(vir, Inst.Name, d).name,
        else => return "", // else: a subroutine, block or generate scope
    });
}
