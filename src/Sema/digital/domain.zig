//! The digital half of a mixed design at its two seams with the analog
//! block. A module's variables by domain (VAMS §7.2.2: "the domain of a
//! variable is that of the context from which its value is assigned"), as
//! lib/sim/digital's mixed elaboration splits them: its discrete processes
//! in, the variables the digital half leaves to the analog block (`analog`)
//! and those it declares only to receive an analog value (`a2d`, §7.3.6.4)
//! out. And the lowered design's variables and nets by path (`names`), the
//! slots a host reads for D2A and writes for A2D; the analog solution's
//! potentials a digital expression probes (`probe`) and the analog events
//! a digital event control waits on (`monitor`).
//! Cites: VAMS-2023 §7.2.2, §7.3.1, §7.3.5, §7.3.6.3, §7.3.6.4.
//!
//! Contents:
//! - `pub const Domain = struct`
//! - `pub fn of(a: Allocator, vir: *const Vir, body: Vir.Body, root: bool) Allocator.Error!Domain`
//! - `pub fn names(l: *Lower) Error![]const digital.Named`
//! - `pub fn isProbe(l: *Lower, i: Inst.Index) bool`
//! - `pub fn probe(l: *Lower, i: Inst.Index) Error!u32`
//! - `pub fn monitor(l: *Lower, i: Inst.Index) Error!?u32`
//! - `pub const Bridge = struct`, `pub fn bridgeOf(l: *Lower, k: u32) Error!?Bridge`
//! - `pub fn primitiveTerminals(l: *Lower, k: u32, f: u32) Error!void`
//! - `pub fn segmented(l: *Lower, w_placed_frame: u32, k: u32) Error!std.AutoHashMapUnmanaged(Inst.Index, u32)`
//! - `pub fn skipped(l: *Lower, f: u32, actual: Inst.Ref) Error!bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const decl = @import("../decl.zig");
const discrete = @import("../discrete.zig");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const vars = @import("vars.zig");
const Program = std_sim.Program;
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

/// A VAMS §7.8 connect module instance's place: the instance whose mixed
/// port it bridges, under the same parent, and that port's connection
/// there (`Zcu.ports`, in the parent's Vir).
/// `prim`: on a primitive's terminal, the primitive's instance
/// instruction in the parent (`child` then is the parent itself).
pub const Bridge = struct { child: u32, actual: Inst.Ref, prim: ?Inst.Index = null };

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
        // A continuous assignment's value is a digital read too.
        .assign => try reads(a, vir, decl.payloadOf(vir, Inst.Assign, i).rhs, &read),
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

/// Whether call `i` of `Lower.frame` is a VAMS §7.3.6.3 potential probe
/// `V(...)` of a mixed design's analog solution.
pub fn isProbe(l: *Lower, i: Inst.Index) bool {
    if (!l.options.mixed) return false;
    const vir = l.virOf(l.frame);
    if (Lower.tag(vir, i) != .call) return false;
    const callee = Lower.payload(vir, Inst.Call, i).callee.toIndex() orelse return false;
    if (Lower.tag(vir, callee) != .str_ref) return false;
    return std.mem.eql(u8, vir.string(vir.instructions.items(.data)[@backingInt(callee)].str_tok.start), "V");
}

/// The `.probe` row of probe call `i` (`isProbe`): its terminals by name,
/// as lib/sim/digital hands them to the mixed host.
pub fn probe(l: *Lower, i: Inst.Index) Error!u32 {
    assert(isProbe(l, i));
    const vir = l.virOf(l.frame);
    const args = vir.list(Inst.Ref, Lower.payload(vir, Inst.Call, i).args);
    if (args.len == 0 or args.len > 2) return l.refuse("a V() probe of other than one or two terminals");
    const a = try terminal(l, args[0]);
    const b = if (args.len == 2) try terminal(l, args[1]) else Program.List.empty;
    l.b.p.has_probes = true;
    return l.b.expr(.probe, Program.Ty.real_ty, try l.b.extraOf(Program.Probe{ .a = a, .b = b }), 0);
}

/// The event slot of a VAMS §7.3.5 analog event term `i` (`cross`,
/// `above`, `timer`, `absdelta`) of a mixed design's digital event
/// control, its `Program.A2d` row appended; null for any other term.
pub fn monitor(l: *Lower, i: Inst.Index) Error!?u32 {
    if (!l.options.mixed) return null;
    const vir = l.virOf(l.frame);
    if (Lower.tag(vir, i) != .call_sys) return null;
    const c = Lower.payload(vir, Inst.SysCall, i);
    const kind = std.meta.stringToEnum(Program.A2d.Kind, vir.string(c.name)) orelse return null;
    const args = vir.list(Inst.Ref, c.args);
    const rows = try l.a.alloc(u32, args.len);
    for (args, rows) |x, *row| row.* = if (x == .none) digital.none else try expr.real(l, x);
    // An anonymous named event: the host triggers it, its waiters wake.
    const event = try vars.slots(l, .{ .width = 1, .signed = false }, 1, .x);
    try l.monitors.append(l.a, .{ .kind = kind, .args = try l.b.listOf(rows), .event = event });
    assert(l.monitors.items.len != 0);
    return event;
}

/// The bridge instance `k` is (`Zcu.inserts`), or null when it is none.
pub fn bridgeOf(l: *Lower, k: u32) Error!?Bridge {
    const zcu = l.zcu;
    const parents = zcu.instances.items(.parent);
    for (zcu.inserts.items(.bridge), zcu.inserts.items(.instance), zcu.inserts.items(.port), zcu.inserts.items(.terminal)) |b, at, port, term| {
        if (@backingInt(b) != k) continue;
        const child: u32 = @backingInt(at);
        // §7.8.5.1 a primitive's terminal: the row names the parent itself.
        if (parents[child] != parents[k]) return .{ .child = child, .actual = terminalOf(l, child, port, term), .prim = port };
        return .{ .child = child, .actual = try actualOf(l, child, port) };
    }
    return null;
}

/// VAMS §7.8 the bridge (an `Zcu.instances` row) each formal of instance
/// `k`'s module meets a continuous net of its parent through, by formal:
/// those connections are the bridge's segment. A bridge's own formals take
/// its own row when the port it bridges meets one.
pub fn segmented(l: *Lower, w_placed_frame: u32, k: u32) Error!std.AutoHashMapUnmanaged(Inst.Index, u32) {
    const zcu = l.zcu;
    var out: std.AutoHashMapUnmanaged(Inst.Index, u32) = .empty;
    for (zcu.inserts.items(.bridge), zcu.inserts.items(.instance), zcu.inserts.items(.port)) |b, at, port| {
        if (@backingInt(at) != k) continue;
        if (zcu.instances.items(.parent)[k] != zcu.instances.items(.parent)[@backingInt(b)]) continue; // a primitive's terminal
        if (try skipped(l, w_placed_frame, try actualOf(l, k, port))) try out.put(l.a, port, @backingInt(b));
    }
    return out;
}

/// Whether connection `actual` (in frame `f`) names a net the digital half
/// skipped: a continuous one, the analog solver's.
pub fn skipped(l: *Lower, f: u32, actual: Inst.Ref) Error!bool {
    const i = actual.toIndex() orelse return false;
    const vir = l.virOf(f);
    if (Lower.tag(vir, i) != .decl_ref) return false;
    const d = decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
    return l.lookup(f, d) == null;
}

/// VAMS §7.8.5.1 the primitive terminals of instance `k`'s module (frame
/// `f`) that a bridge re-points at its segment (`Lower.segment_refs`). An
/// instance array's rows come one per lane, lowest index first (connect.zig
/// `gateTerminals`' lane loop); when the lanes' bridges differ, each lane is
/// keyed by its bit (§12.1.2: the leftmost index the most significant).
pub fn primitiveTerminals(l: *Lower, k: u32, f: u32) Error!void {
    const zcu = l.zcu;
    const parents = zcu.instances.items(.parent);
    const vir = zcu.fileVir(zcu.instances.items(.module)[k].file);
    var rows: std.AutoArrayHashMapUnmanaged(digital.SegmentRef, std.ArrayList(u32)) = .empty;
    for (zcu.inserts.items(.bridge), zcu.inserts.items(.instance), zcu.inserts.items(.port), zcu.inserts.items(.terminal)) |b, at, port, term| {
        if (@backingInt(at) != k or parents[@backingInt(b)] != at) continue;
        const gop = try rows.getOrPut(l.a, .{ .instance = k, .inst = terminalOf(l, k, port, term).toIndex().? });
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(l.a, @backingInt(b));
    }
    for (rows.keys(), rows.values()) |key, bridges| {
        const one = for (bridges.items[1..]) |b| {
            if (b != bridges.items[0]) break false;
        } else true;
        if (one) {
            try l.segment_refs.put(l.a, key, bridges.items[0]);
            continue;
        }
        const g = gateOf(vir, key.inst) orelse return l.refuse("a bridged terminal of no primitive instance");
        const range = Lower.payload(vir, Inst.Instance, g).range;
        if (range.len == 0) return l.refuse("one primitive terminal taking several connect modules");
        const r = try vars.rangeOf(l, f, range);
        if (bridges.items.len != r.width) return l.refuse("a primitive array with connect modules on only some lanes");
        const lo = @min(r.msb, r.lsb);
        for (bridges.items, 0..) |b, n| {
            const index = lo + @as(i64, @intCast(n));
            const bit: u32 = r.width - 1 - @as(u32, @intCast(@abs(index - r.msb)));
            try l.segment_refs.put(l.a, .{ .instance = k, .inst = key.inst, .lane = bit }, b);
        }
        try l.lane_split.put(l.a, key, {});
    }
}

// ---- private ----

/// Terminal `term` of primitive instance `g` in instance `k`'s module:
/// its connection's value (connect.zig's `gateTerminals` numbering).
fn terminalOf(l: *Lower, k: u32, g: Inst.Index, term: u32) Inst.Ref {
    const zcu = l.zcu;
    const vir = zcu.fileVir(zcu.instances.items(.module)[k].file);
    const conns = vir.list(Inst.Arg, Lower.payload(vir, Inst.Instance, g).conns);
    const value = vir.body(conns[term].value);
    assert(value.len != 0); // connect.zig bridges only a connected terminal
    return value[value.len - 1].toRef();
}

/// The primitive instance instruction among module body `vir`'s that holds
/// terminal instruction `t` as a connection's value.
fn gateOf(vir: *const Vir, t: Inst.Index) ?Inst.Index {
    for (vir.decls()) |d| if (d.kind == .module) {
        for (vir.body(Lower.payload(vir, Inst.Module, d.inst).body)) |g| {
            if (Lower.tag(vir, g) != .instance) continue;
            for (vir.list(Inst.Arg, Lower.payload(vir, Inst.Instance, g).conns)) |c| {
                const v = vir.body(c.value);
                if (v.len != 0 and v[v.len - 1] == t) return g;
            }
        }
    };
    return null;
}

/// Formal `port` of instance `child`'s module: its connection in the
/// parent (`Zcu.ports`).
fn actualOf(l: *Lower, child: u32, port: Inst.Index) Error!Inst.Ref {
    const zcu = l.zcu;
    const d = zcu.instances.items(.module)[child];
    const vir = zcu.fileVir(d.file);
    const formals = vir.body(Lower.payload(vir, Inst.Module, zcu.declRow(d).inst).ports);
    const pos = std.mem.findScalar(Inst.Index, formals, port) orelse return l.refuse("a connect module on a port its module does not list");
    const rows = zcu.instances.items(.ports)[child];
    if (pos >= rows.len) return l.refuse("a connect module on an unconnected port");
    return zcu.ports.items(.actual)[rows.start + pos];
}

/// A probe terminal's name as the source writes it.
fn terminal(l: *Lower, r: Inst.Ref) Error!Program.List {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return l.refuse("an omitted probe terminal");
    const name = switch (Lower.tag(vir, i)) {
        .decl_ref => vir.string(decl.nameOf(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl)),
        .str_ref => vir.string(vir.instructions.items(.data)[@backingInt(i)].str_tok.start),
        else => return l.refuse("a probe terminal that is no simple name"), // ponytail: lib/sim/digital also takes a hierarchical one
    };
    const s = try l.b.string(name);
    return .{ .start = s.start, .len = s.len };
}

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
    const before = out.count();
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
    // Each name this call added came from an instruction it visited.
    assert(out.count() - before <= seen.count());
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
