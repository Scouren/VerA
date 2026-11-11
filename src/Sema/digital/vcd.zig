//! §18.1 value change dumps in the digital lowering: a `$dumpfile`,
//! `$dumpvars`, `$dumpoff`, `$dumpon`, `$dumpall`, `$dumplimit` or
//! `$dumpflush` call in; its `Program.DumpCall`, and once every scope exists
//! the design's dump catalog (`Program.vcd`, parallel to `Program.scopes`),
//! out. As lib/sim/digital's `vcd.catalog` builds it: per scope its
//! `$scope` line; per instance (and static task or function) its variables
//! in declaration order, ports, nets, variables, then named events, an
//! array or a parameter left out.
//! Cites: IEEE 1364-2005 §18.1, §18.2.3.
//!
//! Contents:
//! - `pub fn task(l: *Lower, i: Inst.Index, op: Program.DumpOp, args: []const Inst.Ref) Error!u32`
//! - `pub fn ports(l: *Lower, i: Inst.Index, op: Program.PortsOp, all: []const Inst.Ref) Error!u32`
//! - `pub fn catalog(l: *Lower) Error!void`
//! - `pub fn target(l: *Lower, r: Inst.Ref) Error!struct { slot: bool, at: u32 }`
//! - `pub fn namesOf(l: *Lower, f: u32) Error!std.StringHashMapUnmanaged(Name)`
//! - `pub fn declText(vir: *const Vir, d: Inst.Index) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const tasks = @import("task.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Name = digital.Name;
const none = digital.none;
const Program = std_sim.Program;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// The `Program.DumpCall` (in `extra`) of dump task call `i`.
pub fn task(l: *Lower, i: Inst.Index, op: Program.DumpOp, args: []const Inst.Ref) Error!u32 {
    l.dumps = true;
    var arg: u32 = none;
    var call: Program.List = .empty;
    var targets: std.ArrayList(u32) = .empty;
    switch (op) {
        .file => if (args.len > 1) return l.reject(l.frame, i.toRef(), "$dumpfile takes at most one filename"),
        .off, .on, .all, .flush => if (args.len != 0) return l.reject(l.frame, i.toRef(), "$dumpoff, $dumpon, $dumpall and $dumpflush take no arguments"),
        else => {}, // else: checked below
    }
    switch (op) {
        .file => if (args.len == 1) {
            arg = try expr.self_(l, args[0], 0);
            call = try l.b.string(try callText(l, i));
        },
        .vars => if (args.len != 0) {
            arg = try expr.self_(l, args[0], 0);
            for (args[1..]) |e| {
                const t = try target(l, e);
                try targets.appendSlice(l.a, &.{ @intFromBool(t.slot), t.at });
            }
        } else for (l.roots.items) |sc| try targets.appendSlice(l.a, &.{ 0, sc }),
        .limit => {
            if (args.len != 1) return l.reject(l.frame, i.toRef(), "$dumplimit takes one file size");
            arg = try expr.self_(l, args[0], 0);
        },
        .off, .on, .all, .flush => {},
    }
    return l.b.extraOf(Program.DumpCall{ .op = op, .arg = arg, .call = call, .targets = try l.b.listOf(targets.items) });
}

/// §18.3 a port dump task's `Program.PortsCall` (in `extra`); for
/// `$dumpports`, its instances' ports, their drivers inside and outside
/// the instance, and its `$scope`/`$var port` header.
pub fn ports(l: *Lower, i: Inst.Index, op: Program.PortsOp, all: []const Inst.Ref) Error!u32 {
    const args = if (all.len == 1 and all[0] == .none) all[0..0] else all;
    switch (op) {
        .limit => if (args.len == 0 or args.len > 2) return l.reject(l.frame, i.toRef(), "$dumpportslimit takes a filesize, then optionally a file_pathname"),
        .off, .on, .all, .flush => if (args.len > 1) return l.reject(l.frame, i.toRef(), "$dumpportsoff, $dumpportson, $dumpportsall and $dumpportsflush take at most one file_pathname argument"),
        .ports => {},
    }
    if (op != .ports) {
        var c: Program.PortsCall = .{ .op = op, .ports = 0, .name = none, .size = none };
        if (args.len != 0 and (op != .limit or args.len == 2)) c.name = try expr.self_(l, args[args.len - 1], 0);
        if (op == .limit) c.size = try expr.self_(l, args[0], 0);
        return l.b.extraOf(c);
    }
    var insts: std.ArrayList(u32) = .empty;
    var name_row: u32 = none;
    // §18.3.1 "Only modules are allowed (not variables)" and "Each scope
    // specified in the scope_list shall be unique"; the last argument is
    // the file unless it names an instance.
    for (args, 0..) |e, k| {
        if (instanceTarget(l, e)) |inst| {
            if (std.mem.findScalar(u32, insts.items, inst) != null) return l.reject(l.frame, e, "§18.3.1: each $dumpports scope shall be unique");
            try insts.append(l.a, inst);
            continue;
        }
        if (k + 1 != args.len) return if (isSlot(l, e))
            l.reject(l.frame, e, "§18.3.1: a $dumpports scope is a module instance: only modules are allowed, not variables")
        else
            l.reject(l.frame, e, "§18.3.1: a $dumpports scope is a module instance");
        name_row = try expr.self_(l, e, 0);
    }
    if (insts.items.len == 0) try insts.append(l.a, @backingInt(l.frames.items[l.frame].instance));
    var header: std.ArrayList(u8) = .empty;
    var rows: std.ArrayList(u32) = .empty;
    var n: u32 = 0;
    for (insts.items) |k| {
        const f = l.instance_frame[k];
        const sc = l.frames.items[f].scope;
        try header.appendSlice(l.a, "$scope module ");
        try tasks.scopePath(l, sc, &header, 0);
        try header.appendSlice(l.a, " $end\n");
        const vir = l.virOf(f);
        const m = Lower.payload(vir, Inst.Module, l.zcu.declRow(l.zcu.instances.items(.module)[k]).inst);
        const names = try namesOf(l, f);
        for (vir.body(m.ports)) |p| {
            const text = declText(vir, p);
            const nm = names.get(text) orelse continue;
            var inside: std.ArrayList(u32) = .empty;
            var outside: std.ArrayList(u32) = .empty;
            if (nm.kind == .net) for (l.b.extra.items[l.nets.items[nm.net].drivers.start..][0..l.nets.items[nm.net].drivers.len]) |d| {
                if (below(l, l.b.p.drivers[d].scope, sc)) try inside.append(l.a, d) else try outside.append(l.a, d);
            };
            try l.b.evcd_ports.append(l.a, .{ .slot = nm.slot, .net = if (nm.kind == .net) nm.net else none, .dir = try portDir(l, vir, p), .inside = try l.b.listOf(inside.items), .outside = try l.b.listOf(outside.items) });
            try rows.append(l.a, @intCast(l.b.evcd_ports.items.len - 1));
            try header.appendSlice(l.a, "$var port ");
            if (nm.ty.width == 1) try header.append(l.a, '1') else try header.print(l.a, "[{d}:{d}]", .{ nm.msb, nm.lsb });
            // The first port name bound to the slot.
            const shown = for (vir.body(m.ports)) |q| {
                const qn = names.get(declText(vir, q)) orelse continue;
                if (qn.slot == nm.slot) break declText(vir, q);
            } else text;
            try header.print(l.a, " <{d} {s} $end\n", .{ n, shown });
            n += 1;
        }
        try header.appendSlice(l.a, "$upscope $end\n");
    }
    const dp = try l.b.extraOf(Program.DumpPorts{ .name_row = name_row, .call = try l.b.string(try callText(l, i)), .header = try l.b.string(header.items), .ports = try l.b.listOf(rows.items) });
    return l.b.extraOf(Program.PortsCall{ .op = .ports, .ports = dp, .name = none, .size = none });
}

/// Writes `Program.vcd` when a dump task was lowered.
pub fn catalog(l: *Lower) Error!void {
    if (!l.dumps) return;
    const n = l.b.scopes.items.len;
    const scopes = try l.a.alloc(Program.Vcd.VcdScope, n);
    const var_start = try l.a.alloc(u32, n + 1);
    var vars: std.ArrayList(Program.Vcd.Var) = .empty;
    // Per scope, the frame whose declarations it dumps: an instance's, or
    // a static task's or function's (§18.2.3.4: a scope of its own).
    const frame_of = try l.a.alloc(u32, n);
    @memset(frame_of, none);
    const sub_of = try l.a.alloc(?u32, n);
    @memset(sub_of, null);
    for (l.instance_frame) |f| frame_of[l.frames.items[f].scope] = f;
    for (l.subs.items, 0..) |r, k| if (!r.automatic) {
        frame_of[r.scope] = r.own.frame;
        sub_of[r.scope] = @intCast(k);
    };
    for (l.b.scopes.items, scopes, 0..) |sc, *o, s| {
        const lexical = frame_of[s] == none;
        const kind = if (sub_of[s]) |k| (if (l.subs.items[k].function) "function" else "task") else if (lexical) "begin" else "module";
        var line: std.ArrayList(u8) = .empty;
        try line.print(l.a, "$scope {s} {s}", .{ kind, l.b.string_bytes.items[sc.name.start..][0..sc.name.len] });
        if (sc.index) |k| try line.print(l.a, "[{d}]", .{k});
        try line.appendSlice(l.a, " $end\n");
        o.* = .{ .line = try l.b.string(line.items), .parent = sc.parent, .lexical = lexical, .child = sub_of[s] != null or !(lexical and sc.index == null) };
        var_start[s] = @intCast(vars.items.len);
        if (frame_of[s] != none) try scopeVars(l, frame_of[s], sub_of[s], &vars);
    }
    var_start[n] = @intCast(vars.items.len);
    l.b.p.vcd = .{ .scopes = scopes, .var_start = var_start, .vars = vars.items };
}

/// §18.1.2 what a `$dumpvars` argument names: an instance's scope (a root
/// module by its name, a child instance, or one a hierarchical name
/// reaches), or a variable's slot.
pub fn target(l: *Lower, r: Inst.Ref) Error!struct { slot: bool, at: u32 } {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return l.refuse("an omitted $dumpvars argument");
    switch (Lower.tag(vir, i)) {
        .str_ref => {
            const k = rootNamed(l, vir.string(vir.instructions.items(.data)[@backingInt(i)].str_tok.start)) orelse return l.reject(l.frame, r, "$dumpvars names a module instance or a variable");
            return .{ .slot = false, .at = l.frames.items[l.instance_frame[k]].scope };
        },
        .decl_ref => {
            const d = vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
            if (Lower.tag(vir, d) == .instance) return .{ .slot = false, .at = l.frames.items[l.instance_frame[try childOf(l, l.rootFrame(l.frame), d)]].scope };
            return .{ .slot = true, .at = (try varName(l, try expr.leafName(l, i))).slot };
        },
        .field => {
            const fd = Lower.payload(vir, Inst.Field, i);
            const k = try instanceAt(l, vir, fd.operand, 0);
            const want = vir.string(fd.name);
            const f = l.instance_frame[k];
            if (try childNamed(l, f, want)) |c| return .{ .slot = false, .at = l.frames.items[l.instance_frame[c]].scope };
            const n = (try namesOf(l, f)).get(want) orelse return l.refuse("a $dumpvars argument its instance does not declare");
            return .{ .slot = true, .at = (try varName(l, n)).slot };
        },
        else => return l.reject(l.frame, r, "$dumpvars names a module instance or a variable"), // else: no scope or variable
    }
}

/// Frame `f`'s names by their text.
pub fn namesOf(l: *Lower, f: u32) Error!std.StringHashMapUnmanaged(Name) {
    const vir = l.virOf(f);
    var out: std.StringHashMapUnmanaged(Name) = .empty;
    var it = l.frames.items[f].names.iterator();
    while (it.next()) |e| {
        const text = declText(vir, e.key_ptr.*);
        if (text.len != 0) try out.put(l.a, text, l.names.items[e.value_ptr.*]);
    }
    return out;
}

/// The name declaration `d` declares, or "".
pub fn declText(vir: *const Vir, d: Inst.Index) []const u8 {
    return vir.string(switch (Lower.tag(vir, d)) {
        .variable => Lower.payload(vir, Inst.Variable, d).name,
        .net => Lower.payload(vir, Inst.Net, d).name,
        .io => Lower.payload(vir, Inst.Io, d).name,
        .event => Lower.payload(vir, Inst.Name, d).name,
        .port => Lower.payload(vir, Inst.Port, d).name,
        .param => Lower.payload(vir, Inst.Param, d).name,
        else => return "", // else: no other declaration is dumped
    });
}

// ---- private ----

/// §18.2.3.8 the call as written, for `$version`: from its `$` to the `)`
/// closing its arguments.
fn callText(l: *Lower, i: Inst.Index) Error![]const u8 {
    const text = l.options.sources[@backingInt(l.fileOf(l.frame))].pp.text;
    // The call's main token is past its name: back to the `$` before it.
    const at = l.srcOffset(l.frame, i);
    if (at >= text.len) return l.refuse("a $dumpfile call whose text is not found");
    const start = std.mem.findScalarLast(u8, text[0 .. at + 1], '$') orelse return l.refuse("a $dumpfile call whose text is not found");
    if (!std.mem.startsWith(u8, text[start..], "$dump")) return l.refuse("a $dumpfile call whose text is not found");
    var depth: u32 = 0;
    var quoted = false;
    var k: usize = start;
    while (k < text.len) : (k += 1) switch (text[k]) {
        '"' => quoted = !quoted,
        '\\' => k += @intFromBool(quoted),
        '(' => depth += @intFromBool(!quoted),
        ')' => if (!quoted) {
            // A `)` before any `(` ends the call there.
            if (depth == 0) return text[start..k];
            depth -= 1;
            if (depth == 0) return text[start .. k + 1];
        },
        else => {},
    };
    return text[start..];
}

/// The instance a `$dumpports` argument names, or null when it names none
/// (it is then the file name).
fn instanceTarget(l: *Lower, r: Inst.Ref) ?u32 {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return null;
    switch (Lower.tag(vir, i)) {
        .str_ref, .decl_ref, .field => {},
        else => return null,
    }
    const t = target(l, r) catch return null;
    if (t.slot) return null;
    for (l.instance_frame, 0..) |f, k| if (l.frames.items[f].scope == t.at) return @intCast(k);
    return null;
}

/// Whether `r` is a name of a variable or net.
fn isSlot(l: *Lower, r: Inst.Ref) bool {
    const i = r.toIndex() orelse return false;
    switch (Lower.tag(l.virOf(l.frame), i)) {
        .str_ref, .decl_ref, .field => {},
        else => return false, // else: no name
    }
    const t = target(l, r) catch return false;
    return t.slot;
}

/// Whether scope `s` is scope `inst` or inside it.
fn below(l: *Lower, s: u32, inst: u32) bool {
    var at = s;
    var steps: usize = 0;
    while (steps <= l.b.scopes.items.len) : (steps += 1) {
        if (at == inst) return true;
        const parent = l.b.scopes.items[at].parent;
        if (parent == at) return false;
        at = parent;
    }
    return false;
}

/// §18.4 a port's direction, from its declaration.
fn portDir(l: *Lower, vir: *const Vir, p: Inst.Index) Error!Program.PortDir {
    const io: Inst.Index = switch (Lower.tag(vir, p)) {
        .io => p,
        .port => blk: {
            const v = vir.body(Lower.payload(vir, Inst.Port, p).value);
            if (v.len == 0 or Lower.tag(vir, v[0]) != .decl_ref) return .inout;
            break :blk vir.instructions.items(.data)[@backingInt(v[0])].decl_tok.decl;
        },
        else => return l.refuse("a port of no declaration"),
    };
    if (Lower.tag(vir, io) != .io) return .inout;
    var dir = Lower.payload(vir, Inst.Io, io).flags.dir;
    // A header port's direction may be in a later declaration.
    if (dir == .none) for (vir.instructions.items(.tag), 0..) |t, k| if (t == .io) {
        const later = Lower.payload(vir, Inst.Io, @fromBackingInt(@intCast(k)));
        if (later.prev.toIndex() == io and later.flags.dir != .none) dir = later.flags.dir;
    };
    return switch (dir) {
        .input => .input,
        .output => .output,
        .inout, .none => .inout,
    };
}

fn varName(l: *Lower, n: Name) Error!Name {
    if (n.kind != .variable and n.kind != .net) return l.refuse("a $dumpvars argument naming no variable");
    return n;
}

/// The instance `r` names (a root module by its name, or a child instance)
/// from `Lower.frame`, through a hierarchical name's parts.
fn instanceAt(l: *Lower, vir: *const Vir, r: Inst.Ref, depth: u32) Error!u32 {
    if (depth > l.frames.items.len) return l.refuse("a hierarchical name nested past the design");
    const i = r.toIndex() orelse return l.refuse("a hierarchical name of nothing");
    switch (Lower.tag(vir, i)) {
        .str_ref => return rootNamed(l, vir.string(vir.instructions.items(.data)[@backingInt(i)].str_tok.start)) orelse l.refuse("a hierarchical name of no root module"),
        .decl_ref => {
            const d = vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl;
            if (Lower.tag(vir, d) != .instance) return l.refuse("a hierarchical name whose head is no instance");
            return childOf(l, l.rootFrame(l.frame), d);
        },
        .field => {
            const fd = Lower.payload(vir, Inst.Field, i);
            const k = try instanceAt(l, vir, fd.operand, depth + 1);
            return (try childNamed(l, l.instance_frame[k], vir.string(fd.name))) orelse l.refuse("a hierarchical name of an instance its parent does not hold");
        },
        else => return l.refuse("a hierarchical name of no instance"),
    }
}

/// The root instance whose module is named `name`.
fn rootNamed(l: *Lower, name: []const u8) ?u32 {
    for (l.sites, 0..) |s, k| if (s.frame == none) {
        const vir = l.virOf(l.instance_frame[k]);
        const d = l.zcu.instances.items(.module)[k];
        if (std.mem.eql(u8, vir.string(l.zcu.declRow(d).name), name)) return @intCast(k);
    };
    return null;
}

/// The instance `d` (an `instance` instruction) makes in the instance of
/// root frame `root`; an instance array is refused.
fn childOf(l: *Lower, root: u32, d: Inst.Index) Error!u32 {
    var found: u32 = none;
    for (l.sites, 0..) |s, k| if (s.frame != none and s.inst == d and l.rootFrame(s.frame) == root) {
        if (found != none) return l.refuse("a $dumpvars argument naming an instance array");
        found = @intCast(k);
    };
    if (found == none) return l.refuse("a $dumpvars argument naming an instance the walk did not place");
    return found;
}

/// The child instance named `name` of the instance of root frame `root`.
fn childNamed(l: *Lower, root: u32, name: []const u8) Error!?u32 {
    const vir = l.virOf(root);
    for (l.sites, 0..) |s, k| if (s.frame != none and l.rootFrame(s.frame) == root) {
        const in = Lower.payload(vir, Inst.Instance, s.inst);
        if (std.mem.eql(u8, vir.string(in.name), name)) {
            if (in.range.len != 0) return l.refuse("a $dumpvars argument naming an instance array");
            return @intCast(k);
        }
    };
    return null;
}

/// The variables of frame `f` (an instance's, or static task or function
/// `sub`'s) in `vcd.catalog`'s order, each name once.
fn scopeVars(l: *Lower, f: u32, sub: ?u32, out: *std.ArrayList(Program.Vcd.Var)) Error!void {
    const vir = l.virOf(f);
    const names = try namesOf(l, f);
    var order: std.ArrayList(Inst.Index) = .empty;
    if (sub) |k| {
        const s = Lower.payload(vir, Inst.Function, l.subs.items[k].decl);
        try order.appendSlice(l.a, vir.body(s.formals));
        for (vir.body(s.body)) |d| if (Lower.tag(vir, d) == .variable) try order.append(l.a, d);
    } else {
        const d = l.zcu.instances.items(.module)[@backingInt(l.frames.items[f].instance)];
        const m = Lower.payload(vir, Inst.Module, l.zcu.declRow(d).inst);
        const items = try std.mem.concat(l.a, Inst.Index, &.{ vir.body(m.ports), vir.body(m.body) });
        for (vir.body(m.ports)) |p| try order.append(l.a, p);
        for (vir.body(m.body)) |p| if (Lower.tag(vir, p) == .io and !Lower.payload(vir, Inst.Io, p).flags.header) try order.append(l.a, p);
        for ([_]Inst.Tag{ .net, .variable, .event }) |want| for (items) |x| if (Lower.tag(vir, x) == want) try order.append(l.a, x);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (order.items) |d| {
        const text = declText(vir, d);
        if (text.len == 0 or seen.contains(text)) continue;
        try seen.put(l.a, text, {});
        const n = names.get(text) orelse continue;
        if (n.dims.len != 0 or (n.kind != .variable and n.kind != .net and n.kind != .event)) continue;
        try out.append(l.a, try variable(l, vir, text, n, order.items));
    }
}

/// One `$var`: its type and width before the identifier code, its name and
/// declared range after.
fn variable(l: *Lower, vir: *const Vir, text: []const u8, n: Name, decls: []const Inst.Index) Error!Program.Vcd.Var {
    const event = n.kind == .event;
    var ranged = false;
    var storage: Inst.Storage = .none;
    for (decls) |d| {
        if (!std.mem.eql(u8, declText(vir, d), text)) continue;
        switch (Lower.tag(vir, d)) {
            .io => {
                const io = Lower.payload(vir, Inst.Io, d);
                ranged = ranged or io.range.len != 0;
                if (io.flags.storage != .none) storage = io.flags.storage;
            },
            .net => ranged = ranged or Lower.payload(vir, Inst.Net, d).range.len != 0,
            .variable => {
                const v = Lower.payload(vir, Inst.Variable, d);
                ranged = ranged or v.range.len != 0;
                if (v.flags.storage != .none) storage = v.flags.storage;
            },
            else => {}, // else: an event, no type or range
        }
    }
    const kind: []const u8 = if (event) "event" else if (n.kind == .net) switch (l.nets.items[n.net].kind) {
        // "a net of net type uwire shall have a variable type of wire"
        .uwire => "wire",
        .wreal => "real",
        inline else => |k| @tagName(k), // else: every other net type is its own variable type
    } else if (n.ty.real) "real" else switch (storage) {
        .time => "time",
        .integer => "integer",
        else => "reg", // else: a reg, or a port of no storage
    };
    const width: u32 = if (event) 1 else n.ty.width;
    const head = try std.fmt.allocPrint(l.a, "$var {s} {d} ", .{ kind, width });
    var tail: std.ArrayList(u8) = .empty;
    try tail.print(l.a, " {s}", .{text});
    if (ranged) try tail.print(l.a, " [{d}:{d}]", .{ n.msb, n.lsb });
    try tail.appendSlice(l.a, " $end\n");
    assert(width != 0);
    return .{ .slot = n.slot, .width = width, .real = n.ty.real, .event = event, .head = try l.b.string(head), .tail = try l.b.string(tail.items) };
}
