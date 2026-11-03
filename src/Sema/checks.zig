//! The compilation-wide declaration checks: every file's declarations in,
//! coded failures out, once per compilation and whether or not an instance
//! reaches the declaration (A.1.2 puts no order on descriptions, so a name
//! may be declared in any file). The disciplines net and reg declarations
//! name (E0371), the range order of every paramset parameter (E0347), and
//! the names and shapes §7.7 `connectrules` statements use (E0915, E0916,
//! E0923, E0982).
//! Cites: VAMS-2023 §3.4.2, §3.6.2, §6.4, §7.6 (Table 7-2), §7.7.1,
//! §7.7.2, §7.8, A.2.1.3.
//!
//! Contents:
//! - `pub fn run(s: *Sema) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const walk = @import("walk.zig");
const discipline = @import("discipline.zig");
const domainOf = discipline.domainOf;
const Domain = discipline.Domain;
const Vir = vams.Vir;
const Inst = Vir.Inst;
const payloadOf = walk.payloadOf;

/// Runs every check over every file.
pub fn run(s: *Sema) Allocator.Error!void {
    assert(s.zcu.instances.len == 0);
    const before = s.zcu.failed.len;
    defer assert(s.zcu.failed.len >= before);
    const zcu = s.zcu;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| switch (d.kind) {
            .module, .macromodule, .connectmodule => {
                if (zcu.isBuiltin(.{ .file = file, .index = @fromBackingInt(@intCast(k)) })) continue;
                try netDisciplines(s, file, payloadOf(vir, Inst.Module, d.inst));
            },
            .paramset => try paramsetRanges(s, file, d.inst),
            .connectrules => try connectRules(s, file, payloadOf(vir, Inst.ConnectRules, d.inst)),
            .primitive, .nature, .discipline, .config => {},
        };
    }
}

// ---- private ----

/// A.2.1.3 every net declaration, and every `reg` that names one, names a
/// declared discipline (E0371). The common form of the error, `kid c1;`
/// (an instance missing its parentheses), names a module.
/// ponytail: nets declared in a generate block are not visited.
fn netDisciplines(s: *Sema, file: Zcu.File.Index, m: Inst.Module) Allocator.Error!void {
    assert(m.body.start + m.body.len <= s.zcu.fileVir(file).extra.len);
    assert(@backingInt(file) < s.zcu.files.len);
    const zcu = s.zcu;
    const vir = zcu.fileVir(file);
    for (vir.body(m.body)) |i| {
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        if (tag != .net and tag != .variable) continue;
        const name, const disc = if (tag == .net) blk: {
            const n = payloadOf(vir, Inst.Net, i);
            break :blk .{ n.name, n.discipline };
        } else blk: {
            const v = payloadOf(vir, Inst.Variable, i);
            break :blk .{ v.name, v.discipline };
        };
        if (disc == .empty) continue;
        const text = vir.string(disc);
        const key = try zcu.intern_pool.getString(s.gpa, text);
        if (zcu.disciplines.contains(key)) continue;
        if (zcu.modules.contains(key))
            try s.fail(.E0371, file, i.toRef(), "`{s}` in the declaration of `{s}` is a module; an A.4.1 module_instance takes a parenthesised port list even when it is empty: `{s} {s}();`", .{ text, vir.string(name), text, vir.string(name) })
        else
            try s.fail(.E0371, file, i.toRef(), "`{s}` in the declaration of `{s}`", .{ text, vir.string(name) });
    }
}

/// §3.4.2 "The first expression in the range shall be numerically smaller
/// than the second expression in the range", for every paramset parameter
/// whose bounds fold over the paramset's own defaults (E0347).
fn paramsetRanges(s: *Sema, file: Zcu.File.Index, inst: Inst.Index) Allocator.Error!void {
    assert(@backingInt(file) < s.zcu.files.len);
    assert(s.zcu.fileVir(file).instructions.items(.tag)[@backingInt(inst)] == .paramset);
    const zcu = s.zcu;
    const vir = zcu.fileVir(file);
    const ps = payloadOf(vir, Inst.Paramset, inst);
    var env: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, vir, &.{ps.body});
    defer env.deinit();
    for (env.positions.keys()) |p| {
        const decl = payloadOf(vir, Inst.Param, p);
        for (vir.list(Inst.ValueRange, decl.ranges)) |r| {
            if (r.flags.set or !r.flags.interval) continue;
            const lo = (try env.body(r.lo)) orelse continue;
            const hi = (try env.body(r.hi)) orelse continue;
            if (lo == .str or hi == .str or lo.asReal() < hi.asReal()) continue;
            try s.fail(.E0347, file, p.toRef(), "`{s}` of paramset `{s}`: bounds {d} and {d} are not in increasing order", .{ vir.string(decl.name), vir.string(ps.name), lo.asReal(), hi.asReal() });
        }
    }
}

/// §7.7 the names a `connectrules` block uses: each insertion's connect
/// module (E0915), its discipline overrides one discrete and one continuous
/// (E0923, §7.8) and its ports a Table 7-2 direction pair (E0982); each
/// resolution's disciplines (E0916).
fn connectRules(s: *Sema, file: Zcu.File.Index, cr: Inst.ConnectRules) Allocator.Error!void {
    assert(cr.body.start + cr.body.len <= s.zcu.fileVir(file).extra.len);
    assert(@backingInt(file) < s.zcu.files.len);
    const zcu = s.zcu;
    const vir = zcu.fileVir(file);
    for (vir.body(cr.body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .connect_insert => {
            const ins = payloadOf(vir, Inst.ConnectInsert, i);
            const name = vir.string(ins.module);
            const m = zcu.modules.get(try zcu.intern_pool.getString(s.gpa, name)) orelse {
                try s.fail(.E0915, file, i.toRef(), "nothing declares `{s}`", .{name});
                continue;
            };
            if (zcu.declRow(m).kind != .connectmodule) {
                try s.fail(.E0915, file, i.toRef(), "`{s}` is not declared with `connectmodule`", .{name});
                continue;
            }
            try connectParams(s, file, i, ins, m);
            if (ins.a != .empty or ins.b != .empty) {
                const da = try domainOf(s, vir.string(ins.a));
                const db = try domainOf(s, vir.string(ins.b));
                if (da == null or db == null or da == db) {
                    try s.fail(.E0923, file, i.toRef(), "`{s}` and `{s}`: one shall be discrete and the other continuous", .{ vir.string(ins.a), vir.string(ins.b) });
                    continue;
                }
                // ponytail: an override's directions and §3.11.1 discipline
                // compatibility are judged when insertion reads the rule.
                continue;
            }
            try tableDirections(s, file, i, m);
        },
        .connect_resolve => {
            const r = payloadOf(vir, Inst.ConnectResolve, i);
            for (vir.list(Vir.String, r.disciplines)) |d| if (!zcu.disciplines.contains(try zcu.intern_pool.getString(s.gpa, vir.string(d))))
                try s.fail(.E0916, file, i.toRef(), "nothing declares a discipline `{s}`", .{vir.string(d)});
            if (!r.flags.exclude and !zcu.disciplines.contains(try zcu.intern_pool.getString(s.gpa, vir.string(r.result))))
                try s.fail(.E0916, file, i.toRef(), "nothing declares a discipline `{s}`", .{vir.string(r.result)});
        },
        else => {}, // else: a connectrules body holds only the two statements
    };
}

/// §7.7.3 "Any parameters declared in the connect module can be
/// specified": a connect statement's values name overridable parameters of
/// it, no more in order than it has (E0907, as for an instance).
fn connectParams(s: *Sema, file: Zcu.File.Index, at: Inst.Index, ins: Inst.ConnectInsert, m: Zcu.Decl) Allocator.Error!void {
    const before = s.zcu.failed.len;
    defer assert(s.zcu.failed.len >= before);
    assert(s.zcu.declRow(m).kind == .connectmodule);
    assert(s.zcu.fileVir(file).instructions.items(.tag)[@backingInt(at)] == .connect_insert);
    const zcu = s.zcu;
    const vir = zcu.fileVir(file);
    const args = vir.list(Inst.Arg, ins.params);
    if (args.len == 0) return;
    const mvir = zcu.fileVir(m.file);
    const mod = payloadOf(mvir, Inst.Module, zcu.declRow(m).inst);
    var env: eval.Env = try .init(s.gpa, s.arena, &zcu.intern_pool, mvir, &.{ mod.params, mod.body });
    defer env.deinit();
    var overridable: u32 = 0;
    for (env.positions.keys()) |p| overridable += @intFromBool(walk.isOverridable(mvir, p));
    if (args[0].name == .empty) {
        if (args.len > overridable)
            try s.fail(.E0907, file, at.toRef(), "`{s}` declares {d} overridable parameters, and this connect statement sets {d}", .{ mvir.string(mod.name), overridable, args.len });
        return;
    }
    for (args) |a| {
        const n = vir.string(a.name);
        if (env.systemNamed(n) != null) continue;
        if (env.named(n)) |p| if (walk.isOverridable(mvir, p)) continue;
        try s.fail(.E0907, file, at.toRef(), "`{s}` is not an overridable parameter of connect module `{s}`", .{ n, mvir.string(mod.name) });
    }
}

/// §7.6 Table 7-2: a connect module's continuous and discrete ports are
/// input/output, output/input or inout/inout (E0982). A module whose ports
/// do not split into one of each is judged by insertion.
fn tableDirections(s: *Sema, file: Zcu.File.Index, at: Inst.Index, m: Zcu.Decl) Allocator.Error!void {
    const before = s.zcu.failed.len;
    defer assert(s.zcu.failed.len <= before + 1);
    assert(s.zcu.declRow(m).kind == .connectmodule);
    assert(s.zcu.fileVir(file).instructions.items(.tag)[@backingInt(at)] == .connect_insert);
    const zcu = s.zcu;
    const vir = zcu.fileVir(m.file);
    const mod = payloadOf(vir, Inst.Module, zcu.declRow(m).inst);
    const header = vir.body(mod.ports);
    if (header.len != 2) return;
    var dirs: [2]Inst.Direction = undefined;
    var domains: [2]?Domain = undefined;
    for (header, &dirs, &domains) |h, *dir, *dom| {
        const name = switch (vir.instructions.items(.tag)[@backingInt(h)]) {
            .io => payloadOf(vir, Inst.Io, h).name,
            .port => payloadOf(vir, Inst.Port, h).name,
            else => unreachable, // else: a module header holds only ports and port declarations
        };
        dir.* = .none;
        dom.* = null;
        for ([_]Vir.Body{ mod.ports, mod.body }) |b| for (vir.body(b)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .io => {
                const io = payloadOf(vir, Inst.Io, i);
                if (io.name != name) continue;
                dir.* = io.flags.dir;
                if (io.discipline != .empty) dom.* = try domainOf(s, vir.string(io.discipline));
            },
            .net => {
                const n = payloadOf(vir, Inst.Net, i);
                if (n.name == name and n.discipline != .empty) dom.* = try domainOf(s, vir.string(n.discipline));
            },
            else => {}, // else: only port and net declarations give a port its direction and discipline
        };
    }
    const c: usize = if (domains[0] == .continuous and domains[1] == .discrete) 0 else if (domains[1] == .continuous and domains[0] == .discrete) 1 else return;
    const cd = dirs[c];
    const dd = dirs[1 - c];
    if (cd == .none or dd == .none) return;
    if ((cd == .input and dd == .output) or (cd == .output and dd == .input) or (cd == .inout and dd == .inout)) return;
    try s.fail(.E0982, file, at.toRef(), "the continuous port is `{t}` and the discrete port is `{t}`", .{ cd, dd });
}
