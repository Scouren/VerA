//! Each module's nets as declared in its own scope: a name's discipline
//! from its one discipline declaration. A second is E0902 (§7.4.4: "More
//! than one conflicting discipline declaration from the same context ... is
//! an error", whether or not the two are compatible); two nets of
//! incompatible disciplines (§3.11.1) joined by a branch declaration or an
//! access function's two arguments are E0355 (§3.11: "It shall be an error
//! to connect two ports or nets of the same domain with incompatible
//! disciplines"). A net with no declared discipline, or ground, is not
//! judged here. A port joining a `wreal` to a net type other than wire,
//! tri or wreal is E0919 (§3.7: "A wreal ... can only be connected to
//! ... wire, tri and wreal").
//! Cites: VAMS-2023 §3.6.5, §3.7, §3.11, §3.11.1, §3.12, §7.4.4.
//!
//! Contents:
//! - `pub fn run(s: *Sema, file: Zcu.File.Index) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const walk = @import("walk.zig");
const discipline = @import("discipline.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const payloadOf = walk.payloadOf;
const resolve = @import("resolve.zig");
const NetKind = Inst.NetKind;

/// A net of one module: the module's declaration row and the net's name.
const Key = struct { module: u32, name: Vir.String };

/// Checks every user module of `file`: E0902 for each second discipline
/// declaration, module by module in source order, then E0355 for each
/// branch and access call, in instruction order, then E0919 for each
/// module's instances in source order.
pub fn run(s: *Sema, file: Zcu.File.Index) Allocator.Error!void {
    const before = s.zcu.failed.len;
    defer assert(s.zcu.failed.len >= before);
    const zcu = s.zcu;
    const vir = zcu.fileVir(file);
    // Each declaration instruction's net, and each net's discipline.
    var nets: std.AutoHashMapUnmanaged(Inst.Index, Key) = .empty;
    var discs: std.AutoHashMapUnmanaged(Key, Vir.String) = .empty;
    var grounds: std.AutoHashMapUnmanaged(Key, void) = .empty;
    for (vir.decls(), 0..) |row, k| {
        if (row.kind != .module and row.kind != .macromodule and row.kind != .connectmodule) continue;
        if (zcu.isBuiltin(.{ .file = file, .index = @fromBackingInt(@intCast(k)) })) continue;
        const m = payloadOf(vir, Inst.Module, row.inst);
        for ([_]Vir.Body{ m.ports, m.body }) |b| for (vir.body(b)) |i| {
            const name, const d, const ground = switch (vir.instructions.items(.tag)[@backingInt(i)]) {
                .io => io: {
                    const io = payloadOf(vir, Inst.Io, i);
                    break :io .{ io.name, io.discipline, io.flags.net == .ground };
                },
                .net => net: {
                    const n = payloadOf(vir, Inst.Net, i);
                    break :net .{ n.name, n.discipline, n.flags.net == .ground };
                },
                else => continue, // else: only net and port declarations declare a discipline
            };
            // An out-of-context declaration names another scope's net (resolve.zig).
            if (std.mem.findAny(u8, vir.string(name), ".$") != null) continue;
            const key: Key = .{ .module = @intCast(k), .name = name };
            try nets.put(s.arena, i, key);
            if (ground) try grounds.put(s.arena, key, {});
            if (d == .empty) continue;
            const gop = try discs.getOrPut(s.arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = d;
                continue;
            }
            const note = try std.fmt.allocPrint(s.arena, "`{s}` would be its second, and §7.4.4 forbids a second declaration whether or not the two are compatible", .{vir.string(d)});
            try s.failRule(.{ .note = note }, .E0902, file, i.toRef(), "`{s}` is already of discipline `{s}`", .{ vir.string(name), vir.string(gop.value_ptr.*) });
        };
    }
    try wrealPorts(s, file);
    if (discs.count() < 2) return;
    const tags = vir.instructions.items(.tag);
    for (tags, 0..) |tag, k| {
        const i: Inst.Index = @fromBackingInt(@intCast(k));
        const pair: [2]Inst.Ref = switch (tag) {
            .branch => br: {
                const b = payloadOf(vir, Inst.Branch, i);
                break :br .{ last(vir, b.hi), last(vir, b.lo) };
            },
            .call => call: {
                const args = vir.list(Inst.Ref, payloadOf(vir, Inst.Call, i).args);
                if (args.len != 2 or !try isAccess(s, vir, payloadOf(vir, Inst.Call, i))) continue;
                break :call .{ args[0], args[1] };
            },
            // §5.4.1 the generic forms access either half by name.
            .call_sys => sys: {
                const c = payloadOf(vir, Inst.SysCall, i);
                const args = vir.list(Inst.Ref, c.args);
                const name = vir.string(c.name);
                if (args.len != 2 or !(std.mem.eql(u8, name, "potential") or std.mem.eql(u8, name, "flow"))) continue;
                break :sys .{ args[0], args[1] };
            },
            else => continue, // else: only a branch and an access call join two nets
        };
        var keys: [2]Key = undefined;
        var names: [2][]const u8 = undefined;
        const ok = for (pair, &keys, &names) |r, *key, *d| {
            const ri = r.toIndex() orelse break false;
            if (tags[@backingInt(ri)] != .decl_ref) break false;
            key.* = nets.get(vir.instructions.items(.data)[@backingInt(ri)].decl_tok.decl) orelse break false;
            if (grounds.contains(key.*)) break false;
            d.* = vir.string(discs.get(key.*) orelse break false);
        } else true;
        if (!ok or keys[0].module != keys[1].module) continue;
        const why = try discipline.conflict(s, names[0], names[1]) orelse continue;
        try s.failRule(.{ .note = why }, .E0355, file, i.toRef(), "`{s}` is of discipline `{s}` and `{s}` is of discipline `{s}`", .{ vir.string(keys[0].name), names[0], vir.string(keys[1].name), names[1] });
    }
}

// ---- private ----

/// §3.7 E0919 for each connection of each user module's instances in
/// `file` that joins a wreal to a net of a type other than wire or tri.
/// A name the parent never declared is a variable or an implicit wire.
fn wrealPorts(s: *Sema, file: Zcu.File.Index) Allocator.Error!void {
    const zcu = s.zcu;
    const vir = zcu.fileVir(file);
    for (vir.decls(), 0..) |row, k| {
        if (row.kind != .module and row.kind != .macromodule and row.kind != .connectmodule) continue;
        if (zcu.isBuiltin(.{ .file = file, .index = @fromBackingInt(@intCast(k)) })) continue;
        const m = payloadOf(vir, Inst.Module, row.inst);
        for (vir.body(m.body)) |i| {
            if (vir.instructions.items(.tag)[@backingInt(i)] != .instance) continue;
            const ins = payloadOf(vir, Inst.Instance, i);
            const child = zcu.modules.get(try zcu.intern_pool.getString(s.gpa, vir.string(ins.target))) orelse continue;
            if (zcu.declRow(child).kind == .primitive) continue;
            const cvir = zcu.fileVir(child.file);
            const cm = payloadOf(cvir, Inst.Module, zcu.declRow(child).inst);
            const header = cvir.body(cm.ports);
            const conns = vir.list(Inst.Arg, ins.conns);
            for (conns, 0..) |c, n| {
                const value = vir.body(c.value);
                if (value.len == 0 or vir.instructions.items(.tag)[@backingInt(value[value.len - 1])] != .decl_ref) continue;
                const outer_decl = vir.instructions.items(.data)[@backingInt(value[value.len - 1])].decl_tok.decl;
                const outer_name = declName(vir, outer_decl) orelse continue;
                const outer = kindOf(vir, m, vir.string(outer_name)) orelse continue;
                const formal = if (c.name == .empty) (if (n < header.len) header[n] else continue) else for (header) |h| {
                    if (std.mem.eql(u8, resolve.portName(cvir, h), vir.string(c.name))) break h;
                } else continue;
                const port_name = resolve.portName(cvir, formal);
                const inner = kindOf(cvir, cm, resolve.internalName(cvir, formal)) orelse .wire;
                if ((outer == .wreal) == (inner == .wreal)) continue;
                const other = if (outer == .wreal) inner else outer;
                if (other == .wire or other == .tri) continue;
                try s.failRule(.{ .part = .{ .conn = @intCast(n) } }, .E0919, file, i.toRef(), "`{s}` is a {t} and port `{s}` is a {t}", .{ vir.string(outer_name), outer, port_name, inner });
            }
        }
    }
}

/// The name a net or port declaration declares, or null for another
/// instruction.
fn declName(vir: *const Vir, i: Inst.Index) ?Vir.String {
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .io => payloadOf(vir, Inst.Io, i).name,
        .net => payloadOf(vir, Inst.Net, i).name,
        else => null, // else: only these declare a net
    };
}

/// The net type module `m` declares `name` with (a port declaration
/// without one is a wire), or null when it declares no net of the name.
fn kindOf(vir: *const Vir, m: Inst.Module, name: []const u8) ?NetKind {
    var found: ?NetKind = null;
    for ([_]Vir.Body{ m.ports, m.body }) |b| for (vir.body(b)) |i| {
        const n, const kind = switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .io => .{ payloadOf(vir, Inst.Io, i).name, payloadOf(vir, Inst.Io, i).flags.net },
            .net => .{ payloadOf(vir, Inst.Net, i).name, payloadOf(vir, Inst.Net, i).flags.net },
            else => continue, // else: only these declare a net
        };
        if (!std.mem.eql(u8, vir.string(n), name)) continue;
        if (kind != .none) return if (kind == .ground) .wire else kind;
        found = .wire;
    };
    return found;
}

/// The value a body ends in, or none for an empty body.
fn last(vir: *const Vir, b: Vir.Body) Inst.Ref {
    const insts = vir.body(b);
    return if (insts.len == 0) .none else insts[insts.len - 1].toRef();
}

/// Whether call `c` calls a nature's access function: an `access`
/// attribute's name (`V`, `I`).
fn isAccess(s: *Sema, vir: *const Vir, c: Inst.Call) Allocator.Error!bool {
    const callee = c.callee.toIndex() orelse return false;
    if (vir.instructions.items(.tag)[@backingInt(callee)] != .str_ref) return false;
    const name = vir.string(vir.instructions.items(.data)[@backingInt(callee)].str_tok.start);
    const zcu = s.zcu;
    for (zcu.natures.values()) |d| {
        const nvir = zcu.fileVir(d.file);
        for (nvir.list(Inst.Attr, payloadOf(nvir, Inst.Nature, zcu.declRow(d).inst).attrs)) |a| {
            if (!std.mem.eql(u8, nvir.string(a.name), "access")) continue;
            const v = nvir.body(a.value);
            if (v.len == 0 or nvir.instructions.items(.tag)[@backingInt(v[v.len - 1])] != .str_ref) continue;
            if (std.mem.eql(u8, nvir.string(nvir.instructions.items(.data)[@backingInt(v[v.len - 1])].str_tok.start), name)) return true;
        }
    }
    return false;
}
