//! Annex E.2.1 from the netlist's side: SPICE is case-insensitive and the
//! netlist is lower-cased at ingest, so a module or parameter name it
//! writes matches the Verilog-AMS declaration regardless of case when
//! nothing matches exactly (`.model nch bsim4` and `module BSIM4`'s `W`).
//! An exact match always wins.
//! Cites: VAMS-2023 Annex E.2.1, §9.18.
//!
//! Contents:
//! - `pub fn moduleNamed(s: *Sema, name: InternPool.String) Allocator.Error!?InternPool.String`
//! - `pub fn inNetlist(zcu: *const Zcu, i: Zcu.Instance.Index) bool`
//! - `pub fn respell(s: *Sema, env: *const Env, givens: []walk.Given) Allocator.Error!void`
//! - `pub fn shadows(s: *Sema) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const walk = @import("walk.zig");
const eval = @import("eval.zig");
const Inst = vams.Vir.Inst;
const Env = eval.Env;
const payloadOf = walk.payloadOf;

/// The netlist module `name` names regardless of case, or null.
pub fn moduleNamed(s: *Sema, name: InternPool.String) Allocator.Error!?InternPool.String {
    assert(name != .empty);
    const zcu = s.zcu;
    const want = zcu.intern_pool.stringToSlice(name);
    for (zcu.netlist_modules) |d| {
        const spelled = zcu.fileVir(d.file).string(zcu.declRow(d).name);
        if (std.ascii.eqlIgnoreCase(spelled, want)) return try zcu.intern_pool.getString(s.gpa, spelled);
    }
    return null;
}

/// Whether instance `i` is of a module the netlist stands for.
pub fn inNetlist(zcu: *const Zcu, i: Zcu.Instance.Index) bool {
    if (i == .none) return false;
    const m = zcu.instances.items(.module)[@backingInt(i)];
    for (zcu.netlist_modules) |d| if (std.meta.eql(d, m)) return true;
    return false;
}

/// Respells each named value of `givens` that no parameter or alias of
/// `env` spells exactly as the one it folds to, when exactly one does.
/// §9.18 system parameters (`$`) are not the module's.
pub fn respell(s: *Sema, env: *const Env, givens: []walk.Given) Allocator.Error!void {
    const ip = &s.zcu.intern_pool;
    const vir = env.vir;
    for (givens) |*g| {
        if (g.name == .empty) continue;
        const name = ip.stringToSlice(g.name);
        assert(name.len != 0);
        if (name[0] == '$' or env.named(name) != null) continue;
        var to: ?[]const u8 = null;
        var n: u32 = 0;
        for (env.positions.keys()) |p| {
            const spelled = vir.string(payloadOf(vir, Inst.Param, p).name);
            if (!std.ascii.eqlIgnoreCase(spelled, name)) continue;
            to = spelled;
            n += 1;
        }
        for (env.aliases.items) |a| {
            const spelled = vir.string(payloadOf(vir, Inst.Aliasparam, a).name);
            if (!std.ascii.eqlIgnoreCase(spelled, name)) continue;
            to = spelled;
            n += 1;
        }
        if (n == 1) g.name = try ip.getString(s.gpa, to.?);
    }
}

/// E.3.3: a user module or paramset of a netlist module's name is "used
/// instead of" it, with a warning (W0951) at the declaration: for each
/// netlist module, the modules then the paramsets. Netlist names are lower
/// case, so a differently cased declaration does not shadow.
pub fn shadows(s: *Sema) Allocator.Error!void {
    const zcu = s.zcu;
    const before = zcu.failed.len;
    defer assert(zcu.failed.len >= before);
    for (zcu.netlist_modules) |n| {
        const name = zcu.fileVir(n.file).string(zcu.declRow(n).name);
        for ([_]vams.Vir.Decl.Kind{ .module, .paramset }) |kind| for (0..zcu.files.len) |f| {
            const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
            const vir = zcu.fileVir(file);
            for (vir.decls(), 0..) |d, k| {
                if (d.kind != kind or !std.mem.eql(u8, vir.string(d.name), name)) continue;
                if (zcu.isBuiltin(.{ .file = file, .index = @fromBackingInt(@intCast(k)) })) continue;
                try s.fail(.W0951, file, d.inst.toRef(), "{t} `{s}` is used instead of the SPICE model or subcircuit when this name is instantiated", .{ kind, name });
            }
        };
    }
}
