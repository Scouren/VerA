//! The lowered design's interface for its backends: the root instance's
//! ports for a host that drives it as a device (the `.v` device backend,
//! src/codegen/digital/device.zig's `contractDecls` in the old pipeline)
//! and the source offset of its `module` keyword; for a netlist backend
//! (`--emit-rtlil`), every module specialization with its ports, each
//! scope's, and each slot's declared name and source offset.
//! Cites: IEEE 1364-2005 §4.3.1, §12.2, §12.3.2, §12.3.3.
//!
//! Contents:
//! - `pub fn ports(l: *Lower, k: u32) Error![]const digital.Port`
//! - `pub fn topAt(l: *const Lower) u32`
//! - `pub fn specs(l: *Lower) Error!Specs`, `pub const Specs = struct`
//! - `pub fn slotNames(l: *Lower, tys: []const std_sim.Program.Ty) Error!SlotNames`, `pub const SlotNames = struct`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const decl = @import("../decl.zig");
const std_sim = @import("std_sim");
const Zcu = @import("../../Zcu.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// `Lowered.specs` and `Lowered.scope_spec`.
pub const Specs = struct {
    rows: []const digital.Spec,
    of_scope: []const u32,
    of_instance: []const u32,
    scope_instance: []const u32,
    instance_ports: []const []const digital.Port,
};

/// `Lowered.slot_names` and `Lowered.slot_at`.
pub const SlotNames = struct { names: []const []const u8, at: []const u32, scope: []const u32, msb: []const i64, lsb: []const i64 };

/// Instance `k`'s ports (a `Zcu.instances` row), in its list of ports'
/// order; a port that names no one declaration with a direction is left out.
pub fn ports(l: *Lower, k: u32) Error![]const digital.Port {
    assert(k < l.zcu.instances.len);
    const f = l.instance_frame[k];
    const vir = l.virOf(f);
    const m = Lower.payload(vir, Inst.Module, l.zcu.declRow(l.zcu.instances.items(.module)[k]).inst);
    var out: std.ArrayList(digital.Port) = .empty;
    for (vir.body(m.ports), 1..) |formal, position| {
        const first: Inst.Index, const name: []const u8 = switch (Lower.tag(vir, formal)) {
            .io => .{ decl.canonical(vir, formal), vir.string(Lower.payload(vir, Inst.Io, formal).name) },
            .port => blk: {
                const p = Lower.payload(vir, Inst.Port, formal);
                const value = vir.body(p.value);
                // ponytail: a null or expression port (§12.3.6) stands for no one
                // declaration and is left out; a device host refuses what it lacks.
                if (value.len != 1 or Lower.tag(vir, value[0]) != .decl_ref) continue;
                break :blk .{ decl.canonical(vir, vir.instructions.items(.data)[@backingInt(value[0])].decl_tok.decl), vir.string(p.name) };
            },
            else => continue, // else: a header holds only ports and port declarations
        };
        var dir: ?Inst.Direction = null;
        var integer = false;
        for (vir.body(m.body)) |i| {
            if (decl.canonical(vir, i) != first) continue;
            switch (Lower.tag(vir, i)) {
                .io => {
                    const io = Lower.payload(vir, Inst.Io, i);
                    dir = io.flags.dir;
                    integer = integer or io.flags.storage == .integer or io.flags.storage == .time;
                },
                .variable => {
                    const s = Lower.payload(vir, Inst.Variable, i).flags.storage;
                    integer = integer or s == .integer or s == .time;
                },
                else => {}, // else: a net declaration adds no direction or kind
            }
        }
        if (Lower.tag(vir, first) == .io) {
            const io = Lower.payload(vir, Inst.Io, first);
            dir = io.flags.dir;
            integer = integer or io.flags.storage == .integer or io.flags.storage == .time;
        }
        const d = dir orelse continue; // §12.3.3 refused where the port is declared
        if (d == .none) continue;
        const n: ?digital.Name = if (l.lookup(f, first)) |at| l.names.items[at] else null;
        try out.append(l.a, .{
            .name = name,
            .position = @intCast(position),
            .dir = switch (d) {
                .input => .input,
                .output => .output,
                .inout => .inout,
                .none => unreachable, // skipped above
            },
            .slot = if (n) |x| x.slot else std.math.maxInt(u32),
            .ty = if (n) |x| try l.tyOf(x.ty) else .bit,
            .msb = if (n) |x| x.msb else 0,
            .lsb = if (n) |x| x.lsb else 0,
            .scalar = if (n) |x| x.scalar else true,
            .integer = integer,
        });
    }
    return out.items;
}

/// The source offset of the root module's `module` keyword.
pub fn topAt(l: *const Lower) u32 {
    const d = l.zcu.instances.items(.module)[0];
    const vir = l.zcu.fileVir(d.file);
    const tree = l.options.sources[@backingInt(d.file)].tree;
    const n = vir.instructions.items(.data)[@backingInt(l.zcu.declRow(d).inst)].pl_node.src_node;
    var t = tree.nodeMainToken(n);
    // The node's main token may be its name: back up to the keyword.
    while (t > 0 and tree.tokenTag(t) != .keyword_module and tree.tokenTag(t) != .keyword_macromodule) t -= 1;
    return tree.tokenStart(t);
}

/// The distinct (module, parameters) pairs in `Zcu.instances` order, each
/// with its first instance's ports, and per scope its frame's instance's.
pub fn specs(l: *Lower) Error!Specs {
    const zcu = l.zcu;
    const n = zcu.instances.len;
    assert(l.instance_frame.len == n);
    var rows: std.ArrayList(digital.Spec) = .empty;
    var by_key: std.AutoHashMapUnmanaged(Zcu.Instance.Key, u32) = .empty;
    const of_instance = try l.a.alloc(u32, n);
    const instance_ports = try l.a.alloc([]const digital.Port, n);
    for (0..n) |k| {
        const key: Zcu.Instance.Key = .{ .module = zcu.instances.items(.module)[k], .params = zcu.instances.items(.params)[k] };
        instance_ports[k] = try ports(l, @intCast(k));
        const gop = try by_key.getOrPut(l.a, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(rows.items.len);
            const vir = zcu.fileVir(key.module.file);
            try rows.append(l.a, .{ .module = vir.string(zcu.declRow(key.module).name), .key = key, .instance = @intCast(k), .ports = instance_ports[k], .defaults = false });
        }
        // Equal values: one instance without an override shows them defaults.
        if (!overridden(l, @intCast(k))) rows.items[gop.value_ptr.*].defaults = true;
        of_instance[k] = gop.value_ptr.*;
    }
    const of_scope = try l.a.alloc(u32, l.b.scopes.items.len);
    const scope_instance = try l.a.alloc(u32, l.b.scopes.items.len);
    @memset(of_scope, digital.none);
    @memset(scope_instance, digital.none);
    for (l.frames.items) |fr| {
        of_scope[fr.scope] = of_instance[@backingInt(fr.instance)];
        scope_instance[fr.scope] = @backingInt(fr.instance);
    }
    assert(rows.items.len <= n);
    return .{ .rows = rows.items, .of_scope = of_scope, .of_instance = of_instance, .scope_instance = scope_instance, .instance_ports = instance_ports };
}

/// Per slot of `n` (of types `tys`), the name, source offset, scope and
/// declared `[msb:lsb]` of the first declaration bound to it
/// (`Lower.declared`), then of the implicit net it is; a cell no
/// declaration names keeps "", `none`, `none` and `width - 1 : 0`.
pub fn slotNames(l: *Lower, tys: []const std_sim.Program.Ty) Error!SlotNames {
    const n = tys.len;
    const names = try l.a.alloc([]const u8, n);
    const at = try l.a.alloc(u32, n);
    const scope = try l.a.alloc(u32, n);
    const msb = try l.a.alloc(i64, n);
    const lsb = try l.a.alloc(i64, n);
    @memset(names, "");
    @memset(at, digital.none);
    @memset(scope, digital.none);
    for (msb, lsb, tys) |*m, *s, t| {
        m.* = @as(i64, t.width) - 1;
        s.* = 0;
    }
    for (l.declared.items) |d| {
        assert(d.slot + d.count <= n);
        const vir = l.virOf(d.frame);
        const named = Inst.dataKind(Lower.tag(vir, d.decl)) == .pl_node;
        for (d.slot..d.slot + d.count) |k| if (scope[k] == digital.none) {
            scope[k] = l.frames.items[d.frame].scope;
            msb[k] = d.msb;
            lsb[k] = d.lsb;
            if (!named) continue;
            names[k] = vir.string(decl.nameOf(vir, d.decl));
            at[k] = l.srcOffset(d.frame, d.decl);
        };
    }
    var it = l.implicit.iterator();
    while (it.next()) |e| {
        const slot = l.names.items[e.value_ptr.*].slot;
        if (scope[slot] != digital.none) continue;
        names[slot] = l.virOf(e.key_ptr.frame).string(e.key_ptr.name);
        scope[slot] = l.frames.items[e.key_ptr.frame].scope;
    }
    return .{ .names = names, .at = at, .scope = scope, .msb = msb, .lsb = lsb };
}

// ---- private ----

/// Whether an override reached instance `k`: a `#(...)` on its instance,
/// a §6.3.1 defparam, or a §6.4 paramset.
fn overridden(l: *const Lower, k: u32) bool {
    const zcu = l.zcu;
    if (zcu.instances.items(.paramset)[k].file != Zcu.Decl.none.file) return true;
    for (zcu.defparams.keys()) |d| if (@backingInt(d.instance) == k) return true;
    const parent = zcu.instances.items(.parent)[k];
    if (parent == .none) return false;
    const src = zcu.instances.items(.src)[k].toIndex() orelse return false;
    const vir = zcu.fileVir(zcu.instances.items(.module)[@backingInt(parent)].file);
    if (Lower.tag(vir, src) != .instance) return false;
    return Lower.payload(vir, Inst.Instance, src).params.len != 0;
}
