//! The digital half of a mixed design at its two seams with the analog
//! block. A module's variables by domain (VAMS §7.2.2: "the domain of a
//! variable is that of the context from which its value is assigned"), as
//! lib/sim/digital's mixed elaboration splits them: its discrete processes
//! in, the variables the digital half leaves to the analog block (`analog`)
//! and those it declares only to receive an analog value (`a2d`, §7.3.6.4)
//! out. And the lowered design's variables and nets by path (`names`), the
//! slots a host reads for D2A and writes for A2D.
//! Cites: VAMS-2023 §7.2.2, §7.3.1, §7.3.6.4.
//!
//! Contents:
//! - `pub const Domain = struct`
//! - `pub fn of(a: Allocator, vir: *const Vir, body: Vir.Body, root: bool) Allocator.Error!Domain`
//! - `pub fn names(l: *Lower) Error![]const digital.Named`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const decl = @import("../decl.zig");
const discrete = @import("../discrete.zig");
const digital = @import("../digital.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The variables of one module, each by its first declaration.
pub const Domain = struct {
    /// The analog block's: an initialized variable, or a real, string or
    /// `time` no discrete process writes. The digital half declares none.
    analog: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty,
    /// The root's variables a discrete process reads and none writes:
    /// declared without their initializer, for the host to write.
    a2d: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty,
};

/// The domains of the variables of module `body` (`root`: the design's
/// root instance's, the only one an analog value is written into).
pub fn of(a: Allocator, vir: *const Vir, body: Vir.Body, root: bool) Allocator.Error!Domain {
    var written: std.ArrayList(Inst.Index) = .empty;
    var read: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    for (vir.body(body)) |i| switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .initial, .always => {
            const p = decl.payloadOf(vir, Inst.Process, i).body;
            try discrete.writes(vir, p, &written, a, 0);
            try reads(a, vir, p, &read);
        },
        else => {}, // else: not a discrete process
    };
    var d: Domain = .{};
    for (vir.body(body)) |i| {
        if (vir.instructions.items(.tag)[@backingInt(i)] != .variable) continue;
        const first = decl.canonical(vir, i);
        const v = decl.payloadOf(vir, Inst.Variable, i);
        const writes = std.mem.findScalar(Inst.Index, written.items, first) != null;
        if (root and read.contains(first) and !writes) {
            try d.a2d.put(a, first, {});
            continue;
        }
        const analog_type = switch (v.flags.storage) {
            .real, .realtime, .string, .time => true,
            .none, .reg, .integer => false,
        };
        if (v.init.len != 0 or (analog_type and !writes)) try d.analog.put(a, first, {});
    }
    assert(d.analog.count() + d.a2d.count() <= vir.body(body).len);
    return d;
}

/// VAMS §7.3 the mixed host's view of the lowered design: every variable
/// and net by its path below the root, spelled as Sema's discrete card rows
/// (`n`, `u.clk`), sorted by path.
pub fn names(l: *Lower) Error![]const digital.Named {
    var out: std.ArrayList(digital.Named) = .empty;
    var path: std.ArrayList(u8) = .empty;
    for (l.frames.items, 0..) |fr, f| {
        const vir = l.virOf(@intCast(f));
        var it = fr.names.iterator();
        while (it.next()) |e| {
            const n = l.names.items[e.value_ptr.*];
            if (n.kind != .variable and n.kind != .net) continue;
            // ponytail: no array; Sema refuses one the analog block reads (E0512).
            if (n.dims.len != 0) continue;
            // A net's row is the slot its resolved value is stored in and read
            // from, as a variable's is: one D2A watch serves both.
            if (n.kind == .net) assert(l.nets.items[n.net].slot == n.slot);
            path.clearRetainingCapacity();
            try below(l, fr.scope, &path);
            try path.appendSlice(l.a, vir.string(decl.nameOf(vir, e.key_ptr.*)));
            try out.append(l.a, .{ .path = try l.a.dupe(u8, path.items), .slot = n.slot, .ty = try l.tyOf(n.ty) });
        }
    }
    std.mem.sort(digital.Named, out.items, {}, struct {
        fn lt(_: void, x: digital.Named, y: digital.Named) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    if (out.items.len > 1) for (out.items[1..], out.items[0 .. out.items.len - 1]) |x, y| assert(!std.mem.eql(u8, x.path, y.path));
    return out.items;
}

// ---- private ----

/// Appends scope `scope`'s path below the root, each scope then a `.`
/// (nothing for the root's own scope).
fn below(l: *Lower, scope: u32, out: *std.ArrayList(u8)) Error!void {
    var chain: std.ArrayList(u32) = .empty;
    var at = scope;
    while (l.b.scopes.items[at].parent != at) : (at = l.b.scopes.items[at].parent) {
        if (chain.items.len > l.b.scopes.items.len) return l.refuse("a scope chain with a cycle");
        try chain.append(l.a, at);
    }
    var k = chain.items.len;
    while (k != 0) {
        k -= 1;
        const sc = l.b.scopes.items[chain.items[k]];
        try out.appendSlice(l.a, l.b.string_bytes.items[sc.name.start..][0..sc.name.len]);
        if (sc.index) |x| try out.print(l.a, "[{d}]", .{x});
        try out.append(l.a, '.');
    }
}

/// Adds every declaration process body `b` names to `out`: one worklist
/// over each payload's operands and bodies, so no statement form is missed
/// and a deep expression costs no stack.
fn reads(a: Allocator, vir: *const Vir, b: Vir.Body, out: *std.AutoHashMapUnmanaged(Inst.Index, void)) Allocator.Error!void {
    var stack: std.ArrayList(Inst.Index) = .empty;
    var seen: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
    try stack.appendSlice(a, vir.body(b));
    while (stack.pop()) |i| {
        if ((try seen.getOrPut(a, i)).found_existing) continue;
        const data = vir.instructions.items(.data)[@backingInt(i)];
        switch (vir.instructions.items(.tag)[@backingInt(i)]) {
            .decl_ref => try out.put(a, decl.canonical(vir, data.decl_tok.decl), {}),
            inline else => |t| switch (comptime Inst.dataKind(t)) {
                .un_node => if (data.un_node.operand.toIndex()) |o| try stack.append(a, o),
                .pl_node => if (Inst.Payload(t) != void) try children(a, vir, Inst.Payload(t), vir.extraData(Inst.Payload(t), data.pl_node.payload_index), &stack),
                .str_tok, .decl_tok, .int, .float, .str => {},
            },
        }
    }
    assert(seen.count() >= out.count() or out.count() == 0);
}

/// Pushes payload `p`'s operands and the instructions of its bodies.
fn children(a: Allocator, vir: *const Vir, comptime P: type, p: P, stack: *std.ArrayList(Inst.Index)) Allocator.Error!void {
    inline for (@typeInfo(P).@"struct".field_names) |name| {
        const x = @field(p, name);
        switch (@FieldType(P, name)) {
            Inst.Ref => if (x.toIndex()) |o| try stack.append(a, o),
            Vir.List(Inst.Ref) => for (vir.list(Inst.Ref, x)) |r| if (r.toIndex()) |o| try stack.append(a, o),
            Vir.Body => try stack.appendSlice(a, vir.body(x)),
            Inst.Exprs => {
                try stack.appendSlice(a, vir.body(x.body));
                for (vir.list(Inst.Ref, x.values)) |r| if (r.toIndex()) |o| try stack.append(a, o);
            },
            Vir.List(Inst.Arm) => for (vir.list(Inst.Arm, x)) |arm| {
                try stack.appendSlice(a, vir.body(arm.labels));
                try stack.appendSlice(a, vir.body(arm.body));
                for (vir.list(Inst.Ref, arm.values)) |r| if (r.toIndex()) |o| try stack.append(a, o);
            },
            else => {}, // else: a name, flags or a list no process holds
        }
    }
}
