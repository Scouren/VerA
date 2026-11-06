//! §2.9 attributes on declarations and instances (the old
//! `param.checkAttributes` and `var.scratchOn`): one instance's declarations
//! in; out, the §2.9.2 judgements (E0357 a value that does not fold, E0358
//! a `desc`/`units` that is no string or an `op`/`multiplicity` outside its
//! list) and VerA's `vera_scratch` mode for a variable (E0534 a value that
//! needs the model card, E0538 an unknown string, E0535 on anything but a
//! variable).
//! Cites: VAMS-2023 §2.9, §2.9.2, §3.2.
//!
//! Contents:
//! - `pub const Scratch = enum`
//! - `pub fn check(s: *Sema, unit: *Unit) Allocator.Error!void`
//! - `pub fn scratch(s: *Sema, unit: *Unit, attrs: Vir.List(Inst.Attr), src: Inst.Ref) Allocator.Error!Scratch`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Unit = Sema.Unit;

/// VerA's `vera_scratch`: none (the variable may be held), a zero start each
/// evaluation, or no start at all (`"uninit"`).
pub const Scratch = enum { off, zero, uninit };

/// Judges every attribute spec on the instance's module-level declarations
/// and instances.
pub fn check(s: *Sema, unit: *Unit) Allocator.Error!void {
    const vir = unit.vir;
    for ([_]Vir.Body{ unit.module.ports, unit.module.params, unit.module.body }) |body| for (vir.body(body)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        const attrs: Vir.List(Inst.Attr) = switch (tag) {
            .variable => decl.payloadOf(vir, Inst.Variable, i).attrs,
            .param => decl.payloadOf(vir, Inst.Param, i).attrs,
            .net => decl.payloadOf(vir, Inst.Net, i).attrs,
            .io => decl.payloadOf(vir, Inst.Io, i).attrs,
            .instance => decl.payloadOf(vir, Inst.Instance, i).attrs,
            else => continue, // else: carries no attributes
        };
        for (vir.list(Inst.Attr, attrs), 0..) |a, k| {
            const name = vir.string(a.name);
            if (std.mem.eql(u8, name, "vera_scratch") and tag != .variable) try s.fail(.E0535, unit.file, i.toRef(), "", .{});
            try judge(s, unit, name, a.value, i.toRef(), @intCast(k));
        }
    };
}

/// The `vera_scratch` mode `attrs` (a variable's) gives: the last spec
/// wins; §2.9's default 1 when it has no value.
pub fn scratch(s: *Sema, unit: *Unit, attrs: Vir.List(Inst.Attr), src: Inst.Ref) Allocator.Error!Scratch {
    const vir = unit.vir;
    var spec: ?Inst.Attr = null;
    for (vir.list(Inst.Attr, attrs)) |a| if (std.mem.eql(u8, vir.string(a.name), "vera_scratch")) {
        spec = a;
    };
    const a = spec orelse return .off;
    if (a.value.len == 0) return .zero;
    const c = (try decl.foldBody(s, unit, a.value)) orelse {
        try s.fail(.E0534, unit.file, src, "", .{});
        return .off;
    };
    return switch (c) {
        .str => |t| if (std.mem.eql(u8, t, "uninit")) .uninit else {
            try s.fail(.E0538, unit.file, src, "`\"{s}\"`", .{t});
            return .off;
        },
        .int, .real => if (c.isTrue()) .zero else .off,
    };
}

// ---- private ----

/// §2.9 one spec: a value folds (E0357); §2.9.2 fixes four names' values,
/// with a "must" each (E0358); every other name has no stated domain.
/// Reported at spec `k`'s name.
fn judge(s: *Sema, unit: *Unit, name: []const u8, value: Vir.Body, src: Inst.Ref, k: u32) Allocator.Error!void {
    if (value.len == 0) return;
    const at: Sema.Why = .{ .part = .{ .attr = k } };
    const c = (try decl.foldBody(s, unit, value)) orelse {
        var why = at;
        why.note = "§2.9 Syntax 2-4: `attr_spec ::= attr_name [ = constant_expression ]`";
        return s.failRule(why, .E0357, unit.file, src, "`{s}`", .{name});
    };
    const allowed: []const []const u8 = if (std.mem.eql(u8, name, "desc") or std.mem.eql(u8, name, "units"))
        &.{}
    else if (std.mem.eql(u8, name, "op"))
        &.{ "yes", "no" }
    else if (std.mem.eql(u8, name, "multiplicity"))
        &.{ "multiply", "divide", "none" }
    else
        return;
    if (c != .str) return s.failRule(at, .E0358, unit.file, src, "`{s}` must be assigned a string", .{name});
    if (allowed.len == 0) return;
    for (allowed) |ok| if (std.mem.eql(u8, c.str, ok)) return;
    var why = at;
    why.help = if (allowed.len == 2) "§2.9.2 lists the values for `op`: \"yes\" or \"no\"" else "§2.9.2 lists the values for `multiplicity`: \"multiply\", \"divide\" or \"none\"";
    try s.failRule(why, .E0358, unit.file, src, "`{s} = \"{s}\"`", .{ name, c.str });
}
