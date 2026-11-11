//! Hierarchical names of the digital lowering (§12.5): a `field` chain in
//! `Lower.frame` (`u.n0`, `top.u.n0`, `blk.x`, `g[1].r`) in; the `Name` its
//! last part binds in the scope the rest of the chain reaches, out. The
//! first part is searched for from the current scope outward: a child
//! scope of that name (an instance, a generate block, a named block, a task
//! or function), or the scope itself when it is an instance of that module
//! or instance name, then the enclosing scopes, then the roots by module
//! name; every later part is a child scope of the one before. An index
//! selects an instance array element or a loop generate iteration.
//! Cites: IEEE 1364-2005 §12.5, §12.6.
//!
//! Contents:
//! - `pub fn field(l: *Lower, i: Inst.Index) Error!Name`
//! - `pub fn scopeOf(l: *Lower, r: Inst.Ref) Error!u32`
//! - `pub fn frameOf(l: *Lower, s: u32) Error!u32`

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
    const s = try scopeOf(l, fd.operand);
    const f = try frameOf(l, s);
    // §10.2.1 "items declared within an automatic task or function ...
    // cannot be accessed by hierarchical references".
    if (l.frames.items[f].automatic) return l.rejectFmt(l.frame, fd.operand, "§10.2.1: `{s}` is automatic: its items cannot be accessed by hierarchical references", .{text(l, l.b.scopes.items[s].name)});
    const want = vir.string(fd.name);
    const cvir = l.virOf(f);
    var it = l.frames.items[f].names.iterator();
    while (it.next()) |e| if (std.mem.eql(u8, declName(cvir, e.key_ptr.*), want)) {
        const n = l.names.items[e.value_ptr.*];
        if (n.kind == .sub or n.kind == .scope) return l.refuse("a hierarchical name of a task, function or scope read as a value");
        return n;
    };
    return l.refuse("a hierarchical name its scope does not declare");
}

/// The `Program.scopes` row the scope part chain `r` names from
/// `Lower.frame`.
pub fn scopeOf(l: *Lower, r: Inst.Ref) Error!u32 {
    return part(l, l.virOf(l.frame), r, null, 0);
}

/// The frame binding scope `s`'s declarations: an instance's, a generate
/// block's, a named block's, or a static task's or function's.
pub fn frameOf(l: *Lower, s: u32) Error!u32 {
    for (l.frames.items, 0..) |fr, k| if (fr.scope == s) return @intCast(k);
    return l.refuse("a hierarchical name of a scope with no declarations");
}

// ---- private ----

fn part(l: *Lower, vir: *const Vir, r: Inst.Ref, index: ?i64, depth: u32) Error!u32 {
    if (depth > l.b.scopes.items.len) return l.refuse("a hierarchical name nested past the design");
    const i = r.toIndex() orelse return l.refuse("a hierarchical name of nothing");
    const data = vir.instructions.items(.data)[@backingInt(i)];
    switch (Lower.tag(vir, i)) {
        .field => {
            const fd = Lower.payload(vir, Inst.Field, i);
            const parent = try part(l, vir, fd.operand, null, depth + 1);
            return child(l, parent, vir.string(fd.name), index) orelse l.refuse("a hierarchical name of a scope its parent does not hold");
        },
        .elem => {
            if (index != null) return l.refuse("a hierarchical name of a multidimensional instance array");
            const b = Lower.payload(vir, Inst.Bin, i);
            return part(l, vir, b.lhs, try l.intOf(l.frame, b.rhs), depth + 1);
        },
        .str_ref => return head(l, r, vir.string(data.str_tok.start), index),
        .decl_ref => return head(l, r, declName(vir, data.decl_tok.decl), index),
        else => return l.refuse("a hierarchical name part that is no name"),
    }
}

/// §12.5 the first part `name` (and `index`), written at `r`: from the
/// current scope outward, a child of that name or the instance itself,
/// then a root; else lib/sim/digital's refusal.
fn head(l: *Lower, r: Inst.Ref, name: []const u8, index: ?i64) Error!u32 {
    if (name.len == 0) return l.refuse("a hierarchical name of an unnamed scope");
    var s = l.frames.items[l.frame].scope;
    var steps: usize = 0;
    while (steps <= l.b.scopes.items.len) : (steps += 1) {
        if (child(l, s, name, index)) |c| return c;
        if (index == null and instanceNamed(l, s, name)) return s;
        const parent = l.b.scopes.items[s].parent;
        if (parent == s) break;
        s = parent;
    }
    for (l.roots.items) |root| if (index == null and instanceNamed(l, root, name)) return root;
    if (index) |k| return l.rejectFmt(l.frame, r, "§12.5: `{s}[{d}]`: an instance select out of range, or of no array", .{ name, k });
    return l.reject(l.frame, r, "undeclared instance in a hierarchical reference");
}

/// The child scope of `s` named `name` with index `index`, or null.
fn child(l: *Lower, s: u32, name: []const u8, index: ?i64) ?u32 {
    for (l.b.scopes.items, 0..) |sc, k| {
        if (sc.parent != s or k == s or l.scopes.items[k].implicit) continue;
        if (!std.mem.eql(u8, text(l, sc.name), name)) continue;
        const ki: ?i64 = if (sc.index) |x| x else null;
        if (ki == index) return @intCast(k);
    }
    return null;
}

/// Whether scope `s` is an instance whose module or instance is `name`.
fn instanceNamed(l: *Lower, s: u32, name: []const u8) bool {
    if (std.mem.eql(u8, text(l, l.b.scopes.items[s].name), name) and l.b.scopes.items[s].index == null) return isInstance(l, s);
    for (l.instance_frame) |f| if (l.frames.items[f].scope == s) {
        const d = l.zcu.instances.items(.module)[@backingInt(l.frames.items[f].instance)];
        return std.mem.eql(u8, l.virOf(f).string(l.zcu.declRow(d).name), name);
    };
    return false;
}

fn isInstance(l: *Lower, s: u32) bool {
    for (l.instance_frame) |f| if (l.frames.items[f].scope == s) return true;
    return false;
}

fn text(l: *Lower, s: anytype) []const u8 {
    return l.b.string_bytes.items[s.start..][0..s.len];
}

/// The name declaration `d` declares, or "".
fn declName(vir: *const Vir, d: Inst.Index) []const u8 {
    return vir.string(switch (Lower.tag(vir, d)) {
        .variable => Lower.payload(vir, Inst.Variable, d).name,
        .net => Lower.payload(vir, Inst.Net, d).name,
        .io => Lower.payload(vir, Inst.Io, d).name,
        .param => Lower.payload(vir, Inst.Param, d).name,
        .event => Lower.payload(vir, Inst.Name, d).name,
        .instance => Lower.payload(vir, Inst.Instance, d).name,
        .gen_block => Lower.payload(vir, Inst.GenBlock, d).name,
        .block => Lower.payload(vir, Inst.Block, d).name,
        .function => Lower.payload(vir, Inst.Function, d).name,
        else => return "", // else: no other declaration names a scope or value
    });
}
