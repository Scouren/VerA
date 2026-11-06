//! The time-0 order of the digital lowering's processes: the scope tree
//! and each scope's processes in; §9.9's order (the scope tree depth first
//! from each root, a scope's children before itself) and whether an
//! `always` starts on a level-only event control (queued first, as
//! iverilog does) out.
//! Cites: IEEE 1364-2005 §9.9, §11.4.
//!
//! Contents:
//! - `pub fn processOrder(l: *Lower) Error![]const u32`
//! - `pub fn levelControlled(l: *Lower, p: Proc) Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const digital = @import("../digital.zig");
const stmt = @import("stmt.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Proc = digital.Proc;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// §9.9 the order processes are queued in: the scope tree depth first from
/// each root, each scope's children (by source position) before itself.
pub fn processOrder(l: *Lower) Error![]const u32 {
    const n = l.scopes.items.len;
    const children = try l.a.alloc(std.ArrayList(u32), n);
    @memset(children, .empty);
    for (l.b.scopes.items, 0..) |s, k| if (s.parent != k and l.scopes.items[k].queued) try children[s.parent].append(l.a, @intCast(k));
    for (children) |c| std.sort.block(u32, c.items, l, struct {
        fn less(ll: *Lower, x: u32, y: u32) bool {
            return ll.scopes.items[x].at < ll.scopes.items[y].at;
        }
    }.less);
    var out: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList([2]u32) = .empty;
    for (l.roots.items) |root| {
        try stack.append(l.a, .{ root, 0 });
        var steps: usize = 0;
        while (stack.items.len != 0) : (steps += 1) {
            assert(steps <= 2 * n);
            const top = &stack.items[stack.items.len - 1];
            const kids = children[top[0]].items;
            if (top[1] < kids.len) {
                const c = kids[top[1]];
                top[1] += 1;
                try stack.append(l.a, .{ c, 0 });
                continue;
            }
            try out.append(l.a, top[0]);
            _ = stack.pop();
        }
    }
    return out.items;
}

/// Whether `always` process `p` starts with an event control on levels
/// only (`@(a or b)`, `@*`): VerA starts these first at time 0, so they see
/// the time-0 changes the others make (iverilog's order).
pub fn levelControlled(l: *Lower, p: Proc) Error!bool {
    const vir = l.virOf(p.frame);
    const b = vir.body(Lower.payload(vir, Inst.Process, p.inst).body);
    var first: ?Inst.Index = null;
    for (b) |i| if (stmt.isStatement(Lower.tag(vir, i))) {
        first = i;
        break;
    };
    const s = first orelse return false;
    if (Lower.tag(vir, s) != .event_wait) return false;
    const e = Lower.payload(vir, Inst.EventWait, s).event;
    return e == .none or levelOnly(vir, e);
}

// ---- private ----

fn levelOnly(vir: *const Vir, r: Inst.Ref) bool {
    const i = r.toIndex() orelse return true;
    return switch (Lower.tag(vir, i)) {
        .event_or => levelOnly(vir, Lower.payload(vir, Inst.Bin, i).lhs) and levelOnly(vir, Lower.payload(vir, Inst.Bin, i).rhs),
        .posedge, .negedge, .driver_update => false,
        .decl_ref => Lower.tag(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl) != .event,
        else => true, // else: an expression term
    };
}
