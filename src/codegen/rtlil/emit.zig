//! A lowered IEEE 1364 design in, Yosys RTLIL text out (`--emit-rtlil`):
//! one RTLIL `module` per elaborated (module, parameters) spec
//! (`Lowered.specs`), written from its first instance's slots, drivers,
//! child instances and processes in the `std_sim.Program`. A spec at the
//! module's declared parameter values keeps the module's name, so a design
//! without overrides has the old emitter's module set. ponytail: another
//! spec is `$paramod\<module>\spec<n>` (Yosys's `$paramod` prefix; Yosys
//! derives `\P=value` from a Verilog read, which this text is not), the
//! values' spelling left out until a reader needs them.
//! Cites: IEEE 1364-2005 §6.1 (continuous assigns), §7 (gates), §12.1
//! (instances), §12.3 (ports).
//!
//! Contents:
//! - `pub const In = Module.In`, `pub const Error = Module.Error`
//! - `pub fn emit(w: *std.Io.Writer, arena: std.mem.Allocator, in: In) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const std_sim = @import("std_sim");
const Module = @import("Module.zig");
const expr = @import("expr.zig");
const proc = @import("proc.zig");
const Program = std_sim.Program;
const Sig = Module.Sig;

/// What the backend reads (`Module.In`).
pub const In = Module.In;
/// `Module.Error`: `Unsupported` is a shape the subset has no text for.
pub const Error = Module.Error;

const none = std.math.maxInt(u32);

/// Writes the RTLIL of every spec of `in.lowered` to `w`: `autoidx 1`,
/// then one `module` each.
pub fn emit(w: *Writer, arena: Allocator, in: In) Error!void {
    const l = in.lowered;
    assert(in.parent.len == in.name.len);
    assert(l.instance_spec.len == in.parent.len);
    try w.writeAll("autoidx 1\n");
    var next_id: u32 = 0;
    for (l.specs, 0..) |spec, j| {
        var m: Module = .{
            .arena = arena,
            .in = in,
            .p = &l.program,
            .k = spec.instance,
            .spec = @intCast(j),
            .wires = .init(arena),
            .cells = .init(arena),
            .next_id = &next_id,
        };
        try module(&m);
        try w.print("module {s}\n{s}{s}end\n", .{ try specName(arena, in, @intCast(j)), m.wires.written(), m.cells.written() });
    }
}

// ---- private ----

/// One spec's module: its initials (their constants are the wires' `init`
/// attributes), its ports in header order, its own wires, its drivers, its
/// child instances' cells, then its `always` processes.
fn module(m: *Module) Error!void {
    const l = m.in.lowered;
    const p = m.p;
    var inits: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    var alwayses: std.ArrayList(u32) = .empty;
    for (l.proc_sites) |site| {
        if (site.pc >= p.insts.len or l.scope_instance[p.inst_scope[site.pc]] != m.k) continue;
        switch (p.insts.items(.tag)[site.pc]) {
            .continuous => {},
            .wait_event => if (endsRestart(p, site.pc)) try alwayses.append(m.arena, site.pc) else try proc.initial(m, site.pc, &inits),
            else => try proc.initial(m, site.pc, &inits),
        }
    }
    const ports = l.specs[m.spec].ports;
    for (ports) |port| {
        if (port.slot == none) return error.Unsupported;
        const name = try Module.publicId(m.arena, port.name);
        try m.wireLine(name, port.ty, port.msb, port.lsb, port, inits.get(port.slot));
        try m.names.put(m.arena, port.slot, .{ .s = name, .w = port.ty.width, .signed = port.ty.signed });
    }
    for (0..p.slots.len) |s| {
        if (m.instanceOf(@intCast(s)) != m.k or l.slot_names[s].len == 0 or m.names.contains(@intCast(s))) continue;
        const ty = p.slots.items(.ty)[s];
        if (ty.real) return error.Unsupported;
        const name = try Module.publicId(m.arena, l.slot_names[s]);
        try m.wireLine(name, ty, l.slot_msb[s], l.slot_lsb[s], null, inits.get(@intCast(s)));
        try m.names.put(m.arena, @intCast(s), .{ .s = name, .w = ty.width, .signed = ty.signed });
    }
    for (p.drivers, 0..) |dr, di| if (try owner(m, dr) == m.k) try driver(m, @intCast(di));
    for (m.in.parent, 0..) |parent, c| if (parent == m.k) {
        const cw = &m.cells.writer;
        try cw.print("  cell {s} {s}\n", .{ try specName(m.arena, m.in, l.instance_spec[c]), try Module.publicId(m.arena, m.in.name[c]) });
        for (l.instance_ports[c]) |port| {
            if (port.slot == none) return error.Unsupported;
            const sig = try m.slot(port.slot);
            try m.cells.writer.print("    connect {s} {s}\n", .{ try Module.publicId(m.arena, port.name), sig.s });
        }
        try m.cells.writer.writeAll("  end\n");
    };
    for (alwayses.items) |pc| try proc.always(m, pc, pc);
}

/// The module name of spec `j` (see the file's header).
fn specName(arena: Allocator, in: In, j: u32) Error![]const u8 {
    const spec = in.lowered.specs[j];
    if (spec.defaults) return Module.publicId(arena, spec.module);
    return arena.print("$paramod\\{s}\\spec{d}", .{ spec.module, j });
}

/// Whether the process at `pc` loops (`restart`) rather than ends (`stop`).
fn endsRestart(p: *const Program, pc0: u32) bool {
    var pc = pc0;
    while (pc < p.insts.len) : (pc += 1) switch (p.insts.items(.tag)[pc]) {
        .restart => return true,
        .stop => return false,
        else => {}, // else: the body
    };
    return false;
}

/// The instance whose module writes driver `dr`: of the instances whose
/// slots it touches (and its scope's), the one every other is a child of.
/// A port connection touches a parent's and a child's; it is the parent's.
fn owner(m: *const Module, dr: Program.Driver) Error!u32 {
    const p = m.p;
    var touched: std.ArrayList(u32) = .empty;
    try touched.append(m.arena, p.nets[dr.net].slot);
    switch (dr.source) {
        .expr => |x| try expr.reads(p, x.value, &touched, m.arena),
        .bridge => |b| try touched.append(m.arena, b.src),
        .gate => |g| for (p.list(g.ins)) |r| try expr.reads(p, r, &touched, m.arena),
        else => {}, // else: refused before; `driver` reports it
    }
    const l = m.in.lowered;
    const x = l.scope_instance[dr.scope];
    if (x == none) return error.Unsupported;
    var crosses = false;
    var into_child = false;
    for (touched.items) |s| {
        if (visible(m, s, x)) continue;
        crosses = true;
        const i = m.instanceOf(s);
        if (i != none and m.in.parent[i] == x) into_child = true;
    }
    // An input's expression is written in the parent, onto the child's
    // port; an output's bridge in the child, onto the parent's net.
    if (!crosses or into_child) return x;
    return m.in.parent[x];
}

/// Whether instance `x`'s module names slot `s`: its own, or one of its
/// ports (a port joined to a whole parent net is that net's slot).
fn visible(m: *const Module, s: u32, x: u32) bool {
    if (m.instanceOf(s) == x) return true;
    for (m.in.lowered.instance_ports[x]) |port| if (port.slot == s) return true;
    return false;
}

/// One driver as `connect`s and cells.
fn driver(m: *Module, di: u32) Error!void {
    const p = m.p;
    const dr = p.drivers[di];
    const dst = try m.slot(p.nets[dr.net].slot);
    const cw = &m.cells.writer;
    switch (dr.source) {
        .expr => |x| {
            var v = try expr.row(m, x.value);
            if (x.slice) v = try m.part(v, x.lo, dr.width);
            try cw.print("  connect {s} {s}\n", .{ dst.s, (try m.fit(v, dst.w, false)).s });
        },
        .bridge => |b| {
            const src = try m.slot(b.src);
            try cw.print("  connect {s} {s}\n", .{ (try m.part(dst, b.dst_lo, b.width)).s, (try m.part(src, b.src_lo, b.width)).s });
            if (b.ext != 0) {
                const fill = if (b.sign_at) |at| (try m.part(src, at, 1)).s else "1'0";
                var bits: Writer.Allocating = .init(m.arena);
                try bits.writer.writeAll("{");
                for (0..b.ext) |_| try bits.writer.print(" {s}", .{fill});
                try bits.writer.writeAll(" }");
                try cw.print("  connect {s} {s}\n", .{ (try m.part(dst, b.dst_lo + b.width, b.ext)).s, bits.written() });
            }
        },
        .gate => |g| {
            if (g.lane != null) return error.Unsupported;
            const y = try gate(m, g.kind, p.list(g.ins));
            const out = if (g.out_bit) |bit| try m.part(dst, bit, 1) else try m.fit(dst, 1, false);
            try cw.print("  connect {s} {s}\n", .{ out.s, y.s });
        },
        else => return error.Unsupported, // else: a pull, a switch or a UDP (refused before)
    }
}

/// A.3.4's value gates over one-bit inputs: two or more inputs a reduction
/// over their concatenation, the enable gates `$tribuf`.
fn gate(m: *Module, kind: std_sim.net.GateKind, rows: []const u32) Error!Sig {
    if (rows.len == 0) return error.Unsupported;
    const ins = try m.arena.alloc(Sig, rows.len);
    for (rows, ins) |r, *s| s.* = try m.fit(try expr.row(m, r), 1, false);
    switch (kind) {
        .g_buf => return ins[0],
        .g_not => return m.cell1("$not", ins[0], 1),
        .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor => {
            var cat: Writer.Allocating = .init(m.arena);
            try cat.writer.writeAll("{");
            for (ins) |s| try cat.writer.print(" {s}", .{s.s});
            try cat.writer.writeAll(" }");
            const all: Sig = .{ .s = cat.written(), .w = @intCast(ins.len) };
            const v = try m.cell1(switch (kind) {
                .g_and, .g_nand => "$reduce_and",
                .g_or, .g_nor => "$reduce_or",
                .g_xor => "$reduce_xor",
                else => "$reduce_xnor", // else: `xnor`
            }, all, 1);
            return if (kind == .g_nand or kind == .g_nor) m.cell1("$not", v, 1) else v;
        },
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
            if (ins.len != 2) return error.Unsupported;
            const data = if (kind == .g_notif0 or kind == .g_notif1) try m.cell1("$not", ins[0], 1) else ins[0];
            const en = if (kind == .g_bufif0 or kind == .g_notif0) try m.cell1("$not", ins[1], 1) else ins[1];
            const y = try m.temp(1);
            try m.cells.writer.print("  cell $tribuf {s}\n    parameter \\WIDTH 1\n    connect \\A {s}\n    connect \\EN {s}\n    connect \\Y {s}\n  end\n", .{ try m.fresh('c'), data.s, en.s, y.s });
            return y;
        },
    }
}
