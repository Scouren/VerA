//! A name's declarations in one scope, judged as lib/sim/digital judges
//! them: one name's declarations (`decls`, the first first: a port
//! direction and the net or variable completing it) in; nothing, or the
//! E1100 rejection of the one that redeclares it or whose range differs.
//! And a scope's names across kinds (`bindOrder`): bound in lib/sim/digital's
//! order, a second binding of one name refused, each first's binding offset
//! kept for compiled code (`Lower.bound_at`).
//! Cites: IEEE 1364-2005 §4.2, §4.5, §10.2.1, §10.4.2, §12.3.3.
//!
//! Contents:
//! - `pub const Scope = enum`
//! - `pub fn check(l: *Lower, f: u32, decls: []const Inst.Index, scope: Scope, ports: Vir.Body) Error!void`
//! - `pub fn bindOrder(l: *Lower, f: u32, all: []const Inst.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const vars = @import("vars.zig");
const canonical = @import("../decl.zig").canonical;
const nameOf = @import("../decl.zig").nameOf;
const Lower = digital.Lower;
const Error = digital.Error;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// Where the declarations are: a module's items, or a task's or
/// function's (whose messages lib/sim/digital words apart).
pub const Scope = enum { module, subroutine };

/// §4.2/§12.3.3: `decls` declare their name once (a port direction
/// completed by at most one net or variable; a typed port, `output reg q`,
/// is that one), and a completing declaration's range is the port's.
/// `ports`: the module's list of ports, where a net's differing range is
/// reported (lib/sim/digital's reading).
pub fn check(l: *Lower, f: u32, decls: []const Inst.Index, scope: Scope, ports: Vir.Body) Error!void {
    assert(decls.len != 0);
    const vir = l.virOf(f);
    var port: ?Inst.Io = null;
    var port_at: Inst.Ref = .none;
    var typed = false;
    var declared = false;
    var completions: u32 = 0;
    for (decls) |d| {
        switch (Lower.tag(vir, d)) {
            .io => {
                const io = Lower.payload(vir, Inst.Io, d);
                port = io;
                port_at = listed(vir, ports, d) orelse d.toRef();
                typed = io.flags.net != .none or io.flags.storage != .none;
                if (!typed) continue;
            },
            .net => {
                const n = Lower.payload(vir, Inst.Net, d);
                // A VAMS discipline declaration declares no second net.
                if (n.flags.net == .none and n.discipline != .empty) continue;
                if (port) |p| if (p.range.len != 0 and n.range.len != 0 and !try sameRange(l, f, p.range, n.range))
                    return l.rejectFmt(f, port_at, "§12.3.3: the net declaration's range differs from its port declaration's: `{s}`", .{vir.string(p.name)});
            },
            .variable => if (port) |p| {
                completions += 1;
                if (scope == .subroutine) {
                    if (typed) return l.reject(f, d.toRef(), "§12.3.3: a port declared with a type is completely declared; this is a duplicate declaration of it");
                    if (completions > 1) return l.reject(f, d.toRef(), "§12.3.3: a duplicate declaration of a port's variable; a port is declared again at most once");
                }
                try varRange(l, f, d, p, scope);
            },
            else => {}, // else: no declaration of this kind completes a port
        }
        if (declared) return l.reject(f, d.toRef(), "duplicate digital variable");
        declared = true;
    }
}

/// The items `all` of frame `f`'s scope bound as lib/sim/digital's
/// `declareHead`/`declareBody` bind them: parameters, events, variables,
/// nets, then ports (one name's port, net and variable are one binding, at
/// its variable, else its port, else its net). A name bound twice is
/// "duplicate digital variable" at the second (§4.2); a task or function
/// named like a bound name is §10.4.2's error at it; a net declared after a
/// continuous assignment names it was §4.5's implicit net there, so it
/// declares the name twice.
pub fn bindOrder(l: *Lower, f: u32, all: []const Inst.Index) Error!void {
    const vir = l.virOf(f);
    const Entry = struct { stage: u8, at: u32, decl: Inst.Index, first: Inst.Index };
    var entries: std.ArrayList(Entry) = .empty;
    var groups: std.AutoArrayHashMapUnmanaged(Inst.Index, Entry) = .empty;
    for (all) |i| {
        const stage: u8 = switch (Lower.tag(vir, i)) {
            .param => if (Lower.payload(vir, Inst.Param, i).flags.kind == .specparam) continue else 0,
            .event => 1,
            .variable => 2,
            .net => blk: {
                const n = Lower.payload(vir, Inst.Net, i);
                // A VAMS discipline declaration declares no second net.
                if (n.flags.net == .none and n.discipline != .empty) continue;
                break :blk 3;
            },
            .io => 4,
            else => continue, // else: binds no name of this table
        };
        const e: Entry = .{ .stage = stage, .at = l.srcOffset(f, i), .decl = i, .first = canonical(vir, i) };
        if (stage <= 1) {
            try entries.append(l.a, e);
            continue;
        }
        // A port's net is folded into the port: it binds at the port.
        const gop = try groups.getOrPut(l.a, e.first);
        if (!gop.found_existing) {
            gop.value_ptr.* = e;
        } else if (stage == 2 and gop.value_ptr.stage != 2 or stage == 4 and gop.value_ptr.stage == 3) {
            gop.value_ptr.* = e;
        }
    }
    try entries.appendSlice(l.a, groups.values());
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return x.stage < y.stage or x.stage == y.stage and x.at < y.at;
        }
    }.lt);
    var bound: std.AutoHashMapUnmanaged(Vir.String, Entry) = .empty;
    for (entries.items) |e| {
        const gop = try bound.getOrPut(l.a, nameOf(vir, e.decl));
        if (gop.found_existing) return l.reject(f, e.decl.toRef(), "duplicate digital variable");
        gop.value_ptr.* = e;
        try l.bound_at.put(l.a, .{ .frame = f, .decl = e.first }, e.at);
    }
    var gates: std.AutoHashMapUnmanaged(Vir.String, void) = .empty;
    for (all) |i| switch (Lower.tag(vir, i)) {
        // §7.1.5 one instance identifier, one range: a gate array named twice.
        .instance => {
            const in = Lower.payload(vir, Inst.Instance, i);
            if (in.flags.kind != .gate or in.name == .empty) continue;
            if ((try gates.getOrPut(l.a, in.name)).found_existing)
                return l.rejectFmt(f, i.toRef(), "§7.1.5: `{s}` names two instances; one instance identifier has one range", .{vir.string(in.name)});
        },
        .function => {
            const s = Lower.payload(vir, Inst.Function, i);
            if (s.flags.analog or !bound.contains(s.name)) continue;
            return l.rejectFmt(f, i.toRef(), "§10.4.2: duplicate declaration of `{s}`, a task or function name in this scope", .{vir.string(s.name)});
        },
        .assign => {
            const lhs = vir.body(Lower.payload(vir, Inst.Assign, i).lhs);
            // ponytail: a bare name only, not a concatenation's or a terminal's.
            if (lhs.len != 1 or Lower.tag(vir, lhs[0]) != .decl_ref) continue;
            const d = vir.instructions.items(.data)[@backingInt(lhs[0])].decl_tok.decl;
            if (Lower.tag(vir, d) != .net) continue;
            const e = bound.get(nameOf(vir, d)) orelse continue;
            if (e.stage == 3 and e.at > l.srcOffset(f, lhs[0])) return l.reject(f, e.decl.toRef(), "duplicate digital variable");
        },
        else => {}, // else: no rule of this table reads it
    };
}

// ---- private ----

/// §12.3.3 "the range specification between the two declarations of a
/// port shall be identical": a reg's range, and none for `integer` or
/// `time` (whose port then writes none). A real is not judged.
fn varRange(l: *Lower, f: u32, d: Inst.Index, p: Inst.Io, scope: Scope) Error!void {
    const vir = l.virOf(f);
    const v = Lower.payload(vir, Inst.Variable, d);
    const differs = switch (v.flags.storage) {
        .reg, .none => if (p.range.len != 0 and v.range.len != 0) !try sameRange(l, f, p.range, v.range) else (p.range.len != 0) != (v.range.len != 0),
        .integer, .time => p.range.len != 0,
        .real, .realtime, .string => false,
    };
    if (!differs) return;
    if (scope == .module) return l.rejectFmt(f, d.toRef(), "§12.3.3: the variable declaration's range differs from its port declaration's: `{s}`", .{vir.string(p.name)});
    if (v.flags.storage != .reg and v.flags.storage != .none) return l.reject(f, d.toRef(), "§12.3.3: this variable's range differs from its port declaration's: a port with a range is declared again only as a reg of the same range");
    return l.reject(f, d.toRef(), "§12.3.3: this variable's range differs from its port declaration's; the two shall be identical");
}

/// The list-of-ports entry naming port declaration `io` alone.
fn listed(vir: *const Vir, ports: Vir.Body, io: Inst.Index) ?Inst.Ref {
    for (vir.body(ports)) |p| {
        if (Lower.tag(vir, p) != .port) continue;
        const value = vir.body(Lower.payload(vir, Inst.Port, p).value);
        if (value.len != 1 or Lower.tag(vir, value[0]) != .decl_ref) continue;
        if (vir.instructions.items(.data)[@backingInt(value[0])].decl_tok.decl == io) return p.toRef();
    }
    return null;
}

fn sameRange(l: *Lower, f: u32, a: Vir.Body, b: Vir.Body) Error!bool {
    const x = try vars.rangeOf(l, f, a);
    const y = try vars.rangeOf(l, f, b);
    return x.msb == y.msb and x.lsb == y.lsb;
}
