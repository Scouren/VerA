//! The root instance's interface for a host that drives the lowered design
//! as a device (the `.v` device backend, src/codegen/digital/device.zig's
//! `contractDecls` in the old pipeline): its ports in list-of-ports order,
//! each with the slot behind it, its type, declared range and kind, and the
//! source offset of its `module` keyword.
//! Cites: IEEE 1364-2005 §4.3.1, §12.3.2, §12.3.3.
//!
//! Contents:
//! - `pub fn ports(l: *Lower) Error![]const digital.Port`
//! - `pub fn topAt(l: *const Lower) u32`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const decl = @import("../decl.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The root instance's ports, in its list of ports' order; a port that
/// names no one declaration with a direction is left out.
pub fn ports(l: *Lower) Error![]const digital.Port {
    assert(l.zcu.instances.len != 0);
    const f = l.instance_frame[0];
    const vir = l.virOf(f);
    const m = Lower.payload(vir, Inst.Module, l.zcu.declRow(l.zcu.instances.items(.module)[0]).inst);
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
