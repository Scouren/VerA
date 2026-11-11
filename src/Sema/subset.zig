//! Annex C's Verilog-A subset (`Sema.Config.verilog_a`, `--sim=verilogA`)
//! where it needs the discipline table: C.4 "the domain binding type
//! discrete shall be an error in Verilog-A", E0250 at each port, net or
//! `reg` whose discipline declares `domain discrete`. The definition itself
//! is ignored (C.17). The parser refuses the subset's other constructs.
//! Cites: VAMS-2023 annex C.4, C.17; §3.6.2.2.
//!
//! Contents:
//! - `pub fn run(s: *Sema) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const walk = @import("walk.zig");
const decl = @import("decl.zig");
const discipline = @import("discipline.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const payloadOf = walk.payloadOf;

/// Refuses every use of a discrete discipline in every source module: a
/// header port at the port (its declarations merged, as the old parser
/// kept them), then the other nets, then the `reg`s, in source order.
pub fn run(s: *Sema) Allocator.Error!void {
    assert(s.config.verilog_a);
    const before = s.zcu.failed.len;
    defer assert(s.zcu.failed.len >= before);
    const zcu = s.zcu;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| switch (d.kind) {
            .module, .macromodule, .connectmodule => {
                if (zcu.isBuiltin(.{ .file = file, .index = @fromBackingInt(@intCast(k)) })) continue;
                try module(s, file, payloadOf(vir, Inst.Module, d.inst));
            },
            .paramset, .connectrules, .primitive, .nature, .discipline, .config => {},
        };
    }
}

// ---- private ----

fn module(s: *Sema, file: Zcu.File.Index, m: Inst.Module) Allocator.Error!void {
    const vir = s.zcu.fileVir(file);
    assert(m.body.start + m.body.len <= vir.extra.len);
    const tags = vir.instructions.items(.tag);
    var ports: std.ArrayList(Vir.String) = .empty;
    for (vir.body(m.ports)) |p| {
        const named = decl.portDecl(vir, p) orelse continue;
        const name = decl.nameOf(vir, named);
        try ports.append(s.arena, name);
        if (try discreteName(s, vir, m, name)) try refuse(s, file, p);
    }
    inline for (.{ Inst.Net, Inst.Variable }) |T| for (vir.body(m.body)) |i| {
        if (tags[@backingInt(i)] != (if (T == Inst.Net) .net else .variable)) continue;
        const x = payloadOf(vir, T, i);
        if (std.mem.findScalar(Vir.String, ports.items, x.name) != null) continue;
        if (try discrete(s, vir, x.discipline)) try refuse(s, file, i);
    };
}

/// Whether any declaration of `name` in `m` (a direction, a net, a `reg`)
/// names a discrete discipline.
fn discreteName(s: *Sema, vir: *const Vir, m: Inst.Module, name: Vir.String) Allocator.Error!bool {
    const tags = vir.instructions.items(.tag);
    inline for (.{ m.ports, m.body }) |b| for (vir.body(b)) |i| {
        const disc: Vir.String = switch (tags[@backingInt(i)]) {
            .io => if (payloadOf(vir, Inst.Io, i).name == name) payloadOf(vir, Inst.Io, i).discipline else continue,
            .net => if (payloadOf(vir, Inst.Net, i).name == name) payloadOf(vir, Inst.Net, i).discipline else continue,
            .variable => if (payloadOf(vir, Inst.Variable, i).name == name) payloadOf(vir, Inst.Variable, i).discipline else continue,
            else => continue, // else: no other item declares a net's discipline
        };
        if (try discrete(s, vir, disc)) return true;
    };
    return false;
}

/// Whether discipline `name` declares `domain discrete` (C.4).
fn discrete(s: *Sema, vir: *const Vir, name: Vir.String) Allocator.Error!bool {
    if (name == .empty) return false;
    return try discipline.domainOf(s, vir.string(name)) == .discrete;
}

fn refuse(s: *Sema, file: Zcu.File.Index, at: Inst.Index) Allocator.Error!void {
    try s.fail(.E0250, file, at.toRef(), "`domain discrete` under --sim=verilogA", .{});
}
