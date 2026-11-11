//! §3.4 the judgements of a parameter's default: its expression in, the
//! first read of the operating point or the simulation state it makes out
//! (E0363 at the caller).
//! Cites: VAMS-2023 §3.4, §4.5, §5.10.3, §9.
//!
//! Contents:
//! - `pub fn stateRead(s: *Sema, unit: *Unit, b: Vir.Body) Allocator.Error!?[]const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Unit = Sema.Unit;

/// §3.4 a default is a constant expression over "constant numbers and
/// previously defined parameters": the first read in `b` of the operating
/// point or the simulation state (an access, an analog operator, a noise
/// source, an event, `$abstime` and the like, a module variable), or null.
pub fn stateRead(s: *Sema, unit: *Unit, b: Vir.Body) Allocator.Error!?[]const u8 {
    const vir = unit.vir;
    for (vir.body(b)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .call => if (try @import("access.zig").accessCall(s, unit, i.toRef())) |a| return a.name,
        .call_sys => {
            const name = vir.string(decl.payloadOf(vir, Inst.SysCall, i).name);
            const t = vams.SysFn.Tag.fromName(name) orelse continue;
            switch (vams.SysFn.get(t).family) {
                .analog_op, .event => return name,
                else => {}, // else: by name below
            }
            for ([_][]const u8{ "$abstime", "$realtime", "$temperature", "$vt", "$random", "$arandom", "analysis" }) |n| if (std.mem.eql(u8, n, name)) return name;
            if (std.mem.startsWith(u8, name, "$dist_") or std.mem.startsWith(u8, name, "$rdist_")) return name;
        },
        .decl_ref => {
            const d = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
            if (vir.instructions.items(.tag)[@backingInt(d)] == .variable) return vir.string(decl.nameOf(vir, d));
        },
        else => {}, // else: an operator over its operands, walked in the body
    };
    return null;
}
