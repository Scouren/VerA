//! §9.16 `$simprobe(inst_name, param_name [, expression])` and the §6.4.3
//! paramset output variables it reports (the old `analog/hier_name.zig`'s
//! `lowerSimprobe` and `elab/paramset.zig`'s `paramsetStatements`): a
//! sibling of the caller's instance is looked up by its flat name, and its
//! parameter or output variable read; a name that resolves to nothing is
//! the fallback, else E0817; a name known only at run time is E0823
//! (VD-030), fallback or not. A paramset instance's statements run after
//! its module's analog blocks, each paramset variable a slot; a described
//! one is the instance's output variable, an undescribed one hides the
//! module's variable of its name.
//! Cites: VAMS-2023 §6.4.1, §6.4.3, §9.16.
//!
//! Contents:
//! - `pub fn statements(s: *Sema, main: *Block, unit: *Unit) Allocator.Error!void`
//! - `pub fn lower(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`
//! - `pub fn dotted(s: *Sema, b: *Block, name: []const u8, src: Inst.Ref) Allocator.Error!Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;
const Unit = Sema.Unit;
const Value = Sema.Value;

/// §6.4.1 "Paramset statements may assign values to variables declared in
/// the paramset; the values need not be constant expressions", run after
/// the module's analog blocks (§6.4.3's `.gm` reads what they computed).
/// Only the selected paramset's own statements.
/// ponytail: a chain's earlier links' statements are not run; add them
/// when a fixture chains paramsets with statements.
pub fn statements(s: *Sema, main: *Block, unit: *Unit) Allocator.Error!void {
    const scope = unit.paramset orelse return;
    assert(scope.owner == unit);
    const zcu = s.zcu;
    const ps = zcu.instances.items(.paramset)[@backingInt(unit.instance)];
    const vir = scope.vir;
    const body = decl.payloadOf(vir, Inst.Paramset, zcu.declRow(ps).inst).body;
    for (vir.body(body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .variable) continue;
        const v = decl.payloadOf(vir, Inst.Variable, i);
        const first = decl.canonical(vir, i);
        if (scope.binds.contains(first)) continue;
        const ty = decl.tyOf(v.flags.storage);
        const slot: Sema.Slot = .{ .alloc = try decl.addAlloc(s, ty), .ty = ty };
        try scope.binds.put(s.arena, first, .{ .slot = slot });
        const flat = try std.fmt.allocPrint(s.arena, "{s}{s}", .{ unit.prefix, vir.string(v.name) });
        // §6.4.3 a described variable is the instance's output variable;
        // an undescribed one hides the module's of its name.
        if (described(vir, v)) try s.ps_outputs.put(s.arena, flat, slot) else try s.ps_hidden.put(s.arena, flat, {});
    }
    const saved = main.unit;
    defer main.unit = saved;
    main.unit = scope;
    var b = main.child();
    try @import("control.zig").body(s, &b, body);
    try main.insts.appendSlice(s.arena, b.insts.items);
}

/// §6.4.3 `.name` in a paramset statement: the instance's module's `name`.
pub fn dotted(s: *Sema, b: *Block, name: []const u8, src: Inst.Ref) Allocator.Error!Value {
    const owner = b.unit.owner orelse return refuse(s, b, src, "`.name` outside a paramset");
    const d = findDecl(owner, name) orelse return refuse(s, b, src, "`.name` that names nothing in the module");
    const bind = owner.binds.get(d) orelse return refuse(s, b, src, "`.name` with no analog binding");
    return switch (bind) {
        .param => |p| s.param_args.items[@backingInt(p)],
        .slot => |slot| .{ .ref = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot.alloc) } }), .ty = slot.ty },
        else => refuse(s, b, src, "`.name` of a net, branch or array"),
    };
}

/// §9.16 the probe: names that fold resolve now, among the caller's
/// siblings ("an instance called inst_name in the parent of the current
/// instance").
pub fn lower(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    const unit = b.unit;
    if (args.len < 2 or args[0] == .none or args[1] == .none) {
        try s.fail(.E0809, unit.file, src, "`$simprobe` takes an instance name and a parameter name", .{});
        return expr.poison;
    }
    const inst = try decl.foldRef(s, unit, args[0]);
    const param = try decl.foldRef(s, unit, args[1]);
    // §9.16 a string variable's name is known only when the probe runs;
    // VerA resolves names at compile time (VD-030), so it refuses one.
    if (inst == null or param == null or inst.? != .str or param.? != .str) {
        try s.fail(.E0823, unit.file, src, "this `$simprobe` name has no value until the analog block runs; spell it as a string literal or a string parameter", .{});
        return expr.poison;
    }
    const path = try std.fmt.allocPrint(s.arena, "{s}{s}.{s}", .{ parentPrefix(unit.prefix), inst.?.str, param.?.str });
    if (try resolve(s, b, path)) |v| return v;
    if (args.len >= 3 and args[2] != .none) return expr.lower(s, b, args[2]);
    try s.fail(.E0817, unit.file, src, "`$simprobe(\"{s}\", \"{s}\")` names no parameter of the elaborated design", .{ inst.?.str, param.?.str });
    return expr.poison;
}

// ---- private ----

/// The old `resolveProbe`: a paramset's output variable first, then the
/// instance's parameter, then its module's variable unless a paramset
/// variable hides it; null when `path` is none of them.
fn resolve(s: *Sema, b: *Block, path: []const u8) Allocator.Error!?Value {
    if (s.ps_outputs.get(path)) |slot| return .{ .ref = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot.alloc) } }), .ty = slot.ty };
    const dot = std.mem.findScalarLast(u8, path, '.').?;
    const prefix = path[0 .. dot + 1];
    const name = path[dot + 1 ..];
    for (s.units.items) |*u| {
        if (!std.mem.eql(u8, u.prefix, prefix)) continue;
        const d = findDecl(u, name) orelse return null;
        const bind = u.binds.get(d) orelse return null;
        switch (bind) {
            .param => |p| return s.param_args.items[@backingInt(p)],
            .slot => |slot| {
                if (s.ps_hidden.contains(path)) return null;
                return .{ .ref = try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(slot.alloc) } }), .ty = slot.ty };
            },
            else => return null, // else: §9.16 names a parameter or variable
        }
    }
    return null;
}

/// `prefix` less its last instance (`u_mid.u_m.` to `u_mid.`).
fn parentPrefix(prefix: []const u8) []const u8 {
    if (prefix.len == 0) return prefix;
    assert(prefix[prefix.len - 1] == '.');
    const cut = std.mem.findScalarLast(u8, prefix[0 .. prefix.len - 1], '.') orelse return "";
    return prefix[0 .. cut + 1];
}

/// The canonical module-level parameter or variable of `unit` named `name`.
fn findDecl(unit: *const Unit, name: []const u8) ?Inst.Index {
    const vir = unit.vir;
    for (vir.body(unit.module.body)) |i| {
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .variable, .param => {},
            else => continue, // else: §9.16 reads a parameter or a variable
        }
        if (std.mem.eql(u8, vir.string(decl.nameOf(vir, i)), name)) return decl.canonical(vir, i);
    }
    return null;
}

/// Whether variable `v` carries a `desc` attribute (§6.4.3).
fn described(vir: *const Vir, v: Inst.Variable) bool {
    for (vir.list(Inst.Attr, v.attrs)) |a| if (std.mem.eql(u8, vir.string(a.name), "desc")) return true;
    return false;
}

fn refuse(s: *Sema, b: *Block, src: Inst.Ref, what: []const u8) Allocator.Error!Value {
    try s.fail(.E0512, b.unit.file, src, "{s} is not lowered by Sema yet", .{what});
    return expr.poison;
}
