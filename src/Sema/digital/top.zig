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
//! - `pub fn slotNames(l: *Lower, n: usize) Error!SlotNames`, `pub const SlotNames = struct`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const decl = @import("../decl.zig");
const Zcu = @import("../../Zcu.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// `Lowered.specs` and `Lowered.scope_spec`.
pub const Specs = struct { rows: []const digital.Spec, of_scope: []const u32 };

/// `Lowered.slot_names` and `Lowered.slot_at`.
pub const SlotNames = struct { names: []const []const u8, at: []const u32 };

/// Instance `k`'s ports (a `Zcu.instances` row), in its list of ports'
/// order; a port that names no one declaration with a direction is left out.
pub fn ports(l: *Lower, k: u32) Error![]const digital.Port {
    assert(k < l.zcu.instances.len);
    const f = l.instance_frame[k];
    const vir = l.virOf(f);
    const m = Lower.payload(vir, Inst.Module, l.zcu.declRow(l.zcu.instances.items(.module)[k]).inst);
    var out: std.ArrayList(digital.Port) = .empty;
    for (vir.body(m.ports)) |formal| {
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
    for (0..n) |k| {
        const key: Zcu.Instance.Key = .{ .module = zcu.instances.items(.module)[k], .params = zcu.instances.items(.params)[k] };
        const gop = try by_key.getOrPut(l.a, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(rows.items.len);
            const vir = zcu.fileVir(key.module.file);
            try rows.append(l.a, .{ .module = vir.string(zcu.declRow(key.module).name), .key = key, .instance = @intCast(k), .ports = try ports(l, @intCast(k)) });
        }
        of_instance[k] = gop.value_ptr.*;
    }
    const of_scope = try l.a.alloc(u32, l.b.scopes.items.len);
    @memset(of_scope, digital.none);
    for (l.frames.items) |fr| of_scope[fr.scope] = of_instance[@backingInt(fr.instance)];
    assert(rows.items.len <= n);
    return .{ .rows = rows.items, .of_scope = of_scope };
}

/// Per slot of `n`, the name and source offset of the first declaration
/// bound to it (`Lower.declared`), then of the implicit net it is.
pub fn slotNames(l: *Lower, n: usize) Error!SlotNames {
    const names = try l.a.alloc([]const u8, n);
    const at = try l.a.alloc(u32, n);
    @memset(names, "");
    @memset(at, digital.none);
    for (l.declared.items) |d| {
        assert(d.slot + d.count <= n);
        const vir = l.virOf(d.frame);
        if (Inst.dataKind(Lower.tag(vir, d.decl)) != .pl_node) continue;
        const name = vir.string(decl.nameOf(vir, d.decl));
        for (names[d.slot..][0..d.count], at[d.slot..][0..d.count]) |*nm, *o| if (nm.len == 0) {
            nm.* = name;
            o.* = l.srcOffset(d.frame, d.decl);
        };
    }
    var it = l.implicit.iterator();
    while (it.next()) |e| {
        const slot = l.names.items[e.value_ptr.*].slot;
        if (names[slot].len == 0) names[slot] = l.virOf(e.key_ptr.frame).string(e.key_ptr.name);
    }
    return .{ .names = names, .at = at };
}
