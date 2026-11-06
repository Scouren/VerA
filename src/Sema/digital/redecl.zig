//! A name's declarations in one scope, judged as lib/sim/digital judges
//! them: one name's declarations (`decls`, the first first: a port
//! direction and the net or variable completing it) in; nothing, or the
//! E1100 rejection of the one that redeclares it or whose range differs.
//! Cites: IEEE 1364-2005 §4.2, §10.2.1, §12.3.3.
//!
//! Contents:
//! - `pub const Scope = enum`
//! - `pub fn check(l: *Lower, f: u32, decls: []const Inst.Index, scope: Scope, ports: Vir.Body) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const vars = @import("vars.zig");
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
