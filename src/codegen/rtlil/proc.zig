//! A process's pc range in, RTLIL out: an `initial` of constant
//! assignments as `init` attributes, and an `always` as one `process`:
//! a temp per slot it writes, its body decoded back from the Program's
//! control flow (`branch`/`jump` to `switch`, `case_select` to `switch`
//! with `case` labels), and a `sync` per edge of its event control (or
//! `sync always` for a level one) updating each slot from its temp.
//! Cites: IEEE 1364-2005 §9.2.1, §9.2.2, §9.4, §9.5, §9.7.
//!
//! Contents:
//! - `pub fn initial(m: *Module, start: u32, inits: *std.AutoHashMapUnmanaged(u32, []const u8)) Module.Error!void`
//! - `pub fn always(m: *Module, start: u32, index: u32) Module.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const std_sim = @import("std_sim");
const Module = @import("Module.zig");
const expr = @import("expr.zig");
const Program = std_sim.Program;
const Sig = Module.Sig;
const Error = Module.Error;
const Writer = std.Io.Writer;

/// The deepest indentation written, in levels (as the old emitter's).
const max_indent = 32;

/// The structured body of one process, decoded from its pcs.
const Decoder = struct {
    m: *Module,
    out: *Writer,
    temps: *const std.AutoHashMapUnmanaged(u32, Sig),
    /// The slots a blocking assignment wrote so far: their reads take the temp.
    redirect: *std.AutoHashMapUnmanaged(u32, Sig),

    /// Writes pcs `[pc, limit)` at `indent`; returns where it stopped: at
    /// `limit`, or at a `jump` that closes an enclosing `if` or case arm.
    fn region(d: *Decoder, pc0: u32, limit: u32, indent: u32, depth: u32) Error!u32 {
        if (depth > 4096) return error.Unsupported;
        const p = d.m.p;
        var pc = pc0;
        while (pc < limit) {
            const data = p.insts.items(.data)[pc];
            switch (p.insts.items(.tag)[pc]) {
                .task => pc += 1,
                .jump => return pc,
                .assign, .assign_nb => {
                    const place = p.extraData(Program.Place, data.a);
                    d.m.redirect = d.redirect;
                    const target = try d.lvalue(place);
                    const v = try d.m.fit(try expr.row(d.m, data.b), target.w, false);
                    try d.line(indent, "assign {s} {s}\n", .{ target.s, v.s });
                    if (p.insts.items(.tag)[pc] == .assign) try d.blocking(place);
                    pc += 1;
                },
                .branch => {
                    d.m.redirect = d.redirect;
                    const c = try d.m.bit1(try expr.row(d.m, data.a));
                    const t = data.b;
                    try d.line(indent, "switch {s}\n", .{c.s});
                    try d.line(indent + 1, "case 1'1\n", .{});
                    const s = try d.region(pc + 1, t, indent + 2, depth + 1);
                    const has_else = s + 1 == t and p.insts.items(.tag)[s] == .jump and p.insts.items(.data)[s].a > t;
                    if (has_else) {
                        const e = p.insts.items(.data)[s].a;
                        try d.line(indent + 1, "case\n", .{});
                        if (try d.region(t, e, indent + 2, depth + 1) != e) return error.Unsupported;
                        pc = e;
                    } else {
                        if (s != t) return error.Unsupported;
                        pc = t;
                    }
                    try d.line(indent, "end\n", .{});
                },
                .case_select => pc = try d.caseOf(p.extraData(Program.Case, data.a), indent, depth),
                else => return error.Unsupported, // else: the refusals let no other statement through
            }
        }
        return pc;
    }

    /// A §9.5 `case` (no `casez`/`casex`: refused): returns the pc after it.
    fn caseOf(d: *Decoder, c: Program.Case, indent: u32, depth: u32) Error!u32 {
        const p = d.m.p;
        if (c.kind != .normal) return error.Unsupported;
        d.m.redirect = d.redirect;
        const sel = try expr.row(d.m, c.scrutinee);
        try d.line(indent, "switch {s}\n", .{sel.s});
        var end: u32 = std.math.maxInt(u32);
        for (p.list(c.arms)) |at| {
            const arm = p.extraData(Program.Arm, at);
            var labels: Writer.Allocating = .init(d.m.arena);
            for (p.list(arm.labels), 0..) |l, k| {
                d.m.redirect = d.redirect;
                const v = try d.m.fit(try expr.row(d.m, l), sel.w, sel.signed);
                try labels.writer.print("{s} {s}", .{ if (k == 0) "" else ",", v.s });
            }
            try d.line(indent + 1, "case{s}\n", .{labels.written()});
            const s = try d.region(arm.target, @intCast(p.insts.len), indent + 2, depth + 1);
            if (p.insts.items(.tag)[s] != .jump) return error.Unsupported;
            const e = p.insts.items(.data)[s].a;
            if (end != std.math.maxInt(u32) and e != end) return error.Unsupported;
            end = e;
        }
        try d.line(indent, "end\n", .{});
        return end;
    }

    /// Place `place` as the process's temps.
    fn lvalue(d: *Decoder, place: Program.Place) Error!Sig {
        const p = d.m.p;
        switch (place.kind) {
            .slot => return d.temps.get(place.a).?,
            .select => {
                const s = p.extraData(Program.Select, place.a);
                if (s.mode != .const_part or s.elem != std.math.maxInt(u32) or s.first < 0) return error.Unsupported;
                return d.m.part(d.temps.get(s.slot).?, @intCast(s.first), s.count);
            },
            .concat => {
                const parts = p.list(p.extraData(Program.List, place.a));
                var text: Writer.Allocating = .init(d.m.arena);
                try text.writer.writeAll("{");
                var w: u32 = 0;
                var k: usize = 0;
                while (k + 1 < parts.len) : (k += 2) {
                    const one = try d.lvalue(p.extraData(Program.Place, parts[k]));
                    w += one.w;
                    try text.writer.print(" {s}", .{one.s});
                }
                try text.writer.writeAll(" }");
                return .{ .s = text.written(), .w = w };
            },
            .elem => return error.Unsupported,
        }
    }

    /// §9.2.1: later reads of a slot a blocking assignment wrote take its temp.
    fn blocking(d: *Decoder, place: Program.Place) Error!void {
        var slots: std.ArrayList(u32) = .empty;
        try written(d.m, place, &slots);
        for (slots.items) |s| try d.redirect.put(d.m.arena, s, d.temps.get(s).?);
    }

    fn line(d: *Decoder, indent: u32, comptime fmt: []const u8, args: anytype) Error!void {
        try d.out.splatByteAll(' ', 2 * @as(usize, @min(indent, max_indent)));
        try d.out.print(fmt, args);
    }
};

/// An `initial` from pc `start`: each assignment of a constant to a whole
/// slot is that slot's `init` value (the last one wins); a task (simulation
/// output) is dropped.
pub fn initial(m: *Module, start: u32, inits: *std.AutoHashMapUnmanaged(u32, []const u8)) Error!void {
    const p = m.p;
    var pc = start;
    while (pc < p.insts.len) : (pc += 1) {
        const d = p.insts.items(.data)[pc];
        switch (p.insts.items(.tag)[pc]) {
            .stop => return,
            .task => {},
            .assign, .assign_nb, .init_var => {
                const s, const value = if (p.insts.items(.tag)[pc] == .init_var) .{ d.a, d.b } else blk: {
                    const place = p.extraData(Program.Place, d.a);
                    if (place.kind != .slot) return error.Unsupported;
                    break :blk .{ place.a, d.b };
                };
                if (p.exprs.items(.tag)[value] != .constant) return error.Unsupported;
                const c = p.constOf(@fromBackingInt(@intCast(value)));
                const ty = p.slots.items(.ty)[s];
                if (p.exprs.items(.ty)[value].width != ty.width) return error.Unsupported;
                try inits.put(m.arena, s, (try m.constant(c.v, c.x, ty.width, false)).s);
            },
            else => return error.Unsupported, // else: the refusals let only constant assignments through
        }
    }
}

/// An `always` from pc `start` (its `wait_event`) as `process $proc$<index>`.
pub fn always(m: *Module, start: u32, index: u32) Error!void {
    const p = m.p;
    if (p.insts.items(.tag)[start] != .wait_event) return error.Unsupported;
    const end = blk: {
        var pc = start + 1;
        while (pc < p.insts.len) : (pc += 1) if (p.insts.items(.tag)[pc] == .restart) break :blk pc;
        return error.Unsupported;
    };
    // The slots the body writes, each with its temp, defaulted to the slot.
    var temps: std.AutoHashMapUnmanaged(u32, Sig) = .empty;
    var order: std.ArrayList(u32) = .empty;
    for (start + 1..end) |pc| switch (p.insts.items(.tag)[pc]) {
        .assign, .assign_nb => try written(m, p.extraData(Program.Place, p.insts.items(.data)[pc].a), &order),
        else => {}, // else: writes nothing
    };
    var body: Writer.Allocating = .init(m.arena);
    for (order.items) |s| {
        const reg = try m.slot(s);
        const t: Sig = .{ .s = try m.arena.print("${d}{s}", .{ index, reg.s }), .w = reg.w, .signed = reg.signed };
        try m.wires.writer.print("  wire width {d} {s}\n", .{ t.w, t.s });
        try temps.put(m.arena, s, t);
        try body.writer.print("    assign {s} {s}\n", .{ t.s, reg.s });
    }
    var redirect: std.AutoHashMapUnmanaged(u32, Sig) = .empty;
    var d: Decoder = .{ .m = m, .out = &body.writer, .temps = &temps, .redirect = &redirect };
    const stop = d.region(start + 1, end, 2, 0) catch |e| {
        m.redirect = null;
        return e;
    };
    m.redirect = null;
    if (stop != end) return error.Unsupported;
    // §9.7: the event control's terms; a level term makes it combinational.
    const terms = p.list(p.extraData(Program.List, p.insts.items(.data)[start].a));
    var syncs: Writer.Allocating = .init(m.arena);
    var level = terms.len == 0;
    var k: usize = 0;
    while (k + Program.Term.words <= terms.len) : (k += Program.Term.words) {
        const t: Program.Term = .{ .slot = terms[k], .edge = @fromBackingInt(@intCast(terms[k + 1])), .lo = terms[k + 2], .width = terms[k + 3] };
        if (t.edge == .any) {
            level = true;
            continue;
        }
        var sig = try m.slot(t.slot);
        sig = try m.part(sig, t.lo, if (t.width == 0) 1 else 1);
        try syncs.writer.print("    sync {s} {s}\n", .{ if (t.edge == .posedge) "posedge" else "negedge", sig.s });
        for (order.items) |s| try syncs.writer.print("      update {s} {s}\n", .{ (try m.slot(s)).s, temps.get(s).?.s });
    }
    if (level) {
        if (syncs.written().len != 0) return error.Unsupported;
        try syncs.writer.writeAll("    sync always\n");
        for (order.items) |s| try syncs.writer.print("      update {s} {s}\n", .{ (try m.slot(s)).s, temps.get(s).?.s });
    }
    try m.cells.writer.print("  process $proc${d}\n{s}{s}  end\n", .{ index, body.written(), syncs.written() });
}

// ---- private ----

/// The slots `place` writes, each once, into `out`.
fn written(m: *Module, place: Program.Place, out: *std.ArrayList(u32)) Error!void {
    const p = m.p;
    const s: u32 = switch (place.kind) {
        .slot => place.a,
        .select => p.extraData(Program.Select, place.a).slot,
        .concat => {
            const parts = p.list(p.extraData(Program.List, place.a));
            var k: usize = 0;
            while (k + 1 < parts.len) : (k += 2) try written(m, p.extraData(Program.Place, parts[k]), out);
            return;
        },
        .elem => return error.Unsupported,
    };
    for (out.items) |x| if (x == s) return;
    try out.append(m.arena, s);
}
