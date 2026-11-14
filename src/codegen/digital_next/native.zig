//! `--emit-exe`'s native step (docs/rewrite/digital.md step 2): a
//! `Program`'s hot instructions as Zig, the `std_sim.State.Native` the
//! interpreter calls before a compiled run (`State.native_pcs`'s bitset
//! marks which pc the interpreter hands it). One prong per compiled pc in
//! one labelled `switch`; a value of at most 64 bits is `small.V` words,
//! read and written at the slots' own words. What it compiles: blocking
//! and nonblocking assignments, branches, forward jumps and `case` over
//! such values. Everything else (a wide, real or effectful row, a
//! suspension, a backward jump) is the interpreter's: the prong's `else`
//! returns false with `pc` at it.
//! An operator inlined here is `small.value`'s fast path: an x or z operand
//! hands the whole row to `small.value`, so only rows without effects are
//! inlined (`pure`). Every prong that can reach the evaluator sets `s.pc`
//! first: `warn` and `fail` blame it. The oracle is the interpreter
//! itself: `diff-native` runs every `.v` fixture's binary with and without
//! its native step.
//! Cites: IEEE 1364-2005 §5.1, §9.2, §9.4, §9.5.
//!
//! Contents:
//! - `pub fn write(w: *std.Io.Writer, gpa: std.mem.Allocator, p: *const Program) (std.mem.Allocator.Error || std.Io.Writer.Error)!bool`

const std = @import("std");
const assert = std.debug.assert;
const std_sim = @import("std_sim");
const Program = std_sim.Program;
const small = std_sim.small;
const Error = std.Io.Writer.Error;
const Allocator = std.mem.Allocator;

/// Expression nesting past which a row is left to `small.value` whole.
const depth_max = 64;

const Gen = struct {
    p: *const Program,
    w: *std.Io.Writer,
    /// Block labels written so far: each block gets its own.
    labels: u32 = 0,
    /// A prong calls into the interpreter's evaluator, which takes `a`.
    uses_a: bool = false,

    /// The prong of `pc`, when it compiles; whether it did.
    fn inst(g: *Gen, pc: u32) Error!bool {
        assert(pc < g.p.insts.len);
        const p = g.p;
        const d = p.insts.items(.data)[pc];
        const w = g.w;
        switch (p.insts.items(.tag)[pc]) {
            .assign, .assign_nb => |tag| {
                const ty = p.exprs.items(.ty)[d.b];
                if (!small.fits(ty)) return false;
                try w.print("        {d} => {{\n            s.pc = {d};\n            var planes: [2]u64 = undefined;\n            const lit = small.literal(&planes, ", .{ pc, pc });
                try g.expr(d.b, 0);
                try w.print(", .{{ .width = {d}, .signed = {} , .real = false }});\n", .{ ty.width, ty.signed });
                const place = p.extraData(Program.Place, d.a);
                if (place.kind != .slot) {
                    g.uses_a = true;
                    try w.print("            try std_sim.eval.put(s, a, {d}, lit, {}, null);\n", .{ d.a, tag == .assign_nb });
                } else if (tag == .assign_nb) {
                    try w.print("            try s.scheduleWrite({d}, null, lit, null);\n", .{place.a});
                } else try w.print("            try s.store({d}, lit);\n", .{place.a});
                try g.goto(pc, pc + 1);
                try w.writeAll("        },\n");
            },
            .branch => {
                const ty = p.exprs.items(.ty)[d.a];
                if (!small.fits(ty)) return false;
                try w.print("        {d} => {{\n            s.pc = {d};\n            if (small.truthOf(", .{ pc, pc });
                try g.expr(d.a, 0);
                try w.print(", {d}) == .one) {{\n", .{ty.width});
                try g.goto(pc, pc + 1);
                try w.writeAll("            }\n");
                try g.goto(pc, d.b);
                try w.writeAll("        },\n");
            },
            .jump => {
                if (d.a <= pc) return false; // A loop counts against the budget: the interpreter's.
                try w.print("        {d} => {{\n", .{pc});
                try g.goto(pc, d.a);
                try w.writeAll("        },\n");
            },
            .case_select => {
                const c = p.extraData(Program.Case, d.a);
                const tys = p.exprs.items(.ty);
                if (!small.fits(tys[c.scrutinee]) or c.arms.len == 0) return false;
                var any_labels = false;
                for (p.list(c.arms)) |arm_at| for (p.list(p.extraData(Program.Arm, arm_at).labels)) |label| {
                    if (!small.fits(tys[label]) or tys[label].width != tys[c.scrutinee].width) return false;
                    any_labels = true;
                };
                try w.print("        {d} => {{\n            s.pc = {d};\n            const v: V = ", .{ pc, pc });
                try g.expr(c.scrutinee, 0);
                try w.writeAll(";\n");
                // A.6.7: a bare `default` is an arm with no labels (every
                // arm's labels may be empty, on a fixture that never
                // compares), so the label loop below reads `v` zero times;
                // `_ = v` marks it used without re-evaluating or
                // discarding whatever `g.expr` already emitted. A `_ = v`
                // when some arm does have a label is a *different* Zig
                // error ("pointless discard of local constant": the loop
                // below reads `v` right after), so this discard is only
                // ever the first.
                if (!any_labels) try w.writeAll("            _ = v;\n");
                // §9.5: equal planes bit for bit; §9.5.1 the wildcards.
                const wild = switch (c.kind) {
                    .normal => "0",
                    .casez => "(v.x & ~v.v) | (l.x & ~l.v)",
                    .casex => "v.x | l.x",
                };
                for (p.list(c.arms)) |arm_at| {
                    const arm = p.extraData(Program.Arm, arm_at);
                    for (p.list(arm.labels)) |label| {
                        try w.writeAll("            {\n                const l: V = ");
                        try g.expr(label, 0);
                        try w.print(";\n                if (((v.v ^ l.v) | (v.x ^ l.x)) & ~@as(u64, {s}) == 0) {{\n", .{wild});
                        try g.goto(pc, arm.target);
                        try w.writeAll("                }\n            }\n");
                    }
                }
                try g.goto(pc, c.fallback);
                try w.writeAll("        },\n");
            },
            // else: every other instruction is the interpreter's.
            else => return false,
        }
        return true;
    }

    /// Leaves prong `from` for pc `to`: on to its prong when it is later
    /// (a backward edge goes through the interpreter's loop count), after
    /// a §10.3 disable the running process returns.
    fn goto(g: *Gen, from: u32, to: u32) Error!void {
        assert(from < g.p.insts.len);
        assert(to <= g.p.insts.len); // one past the end: `from`'s own fallthrough off the last instruction.
        try g.w.print("            pc.* = {d};\n            if (s.unwind != null) return true;\n", .{to});
        try g.w.writeAll(if (to > from) "" else "            return false;\n");
        if (to > from) try g.w.print("            continue :sw {d};\n", .{to});
    }

    /// Row `e` (it `fits`) as a Zig expression of type `V`.
    fn expr(g: *Gen, e: u32, depth: u32) Error!void {
        const p = g.p;
        assert(e < p.exprs.len);
        const w = g.w;
        const tys = p.exprs.items(.ty);
        const ty = tys[e];
        assert(small.fits(ty));
        const d = p.exprs.items(.data)[e];
        const tag = p.exprs.items(.tag)[e];
        if (depth >= depth_max or !g.pure(e, depth)) return g.leaf(e);
        switch (tag) {
            .constant => try w.print("V{{ .v = 0x{x}, .x = 0x{x} }}", .{ p.consts[d.a], p.consts[d.a + 1] }),
            .slot => {
                const sl = p.slots.get(d.a);
                try w.print("small.resize(.{{ .v = s.v[{d}], .x = s.x[{d}] }}, {d}, {d}, {})", .{ sl.word, sl.word, @min(sl.ty.width, 64), ty.width, ty.signed });
            },
            .select => {
                const sl = p.extraData(Program.Select, d.a);
                const slot_w = p.slots.items(.ty)[sl.slot].width;
                const inside = sl.mode == .const_part and sl.first >= 0 and sl.first + sl.count <= slot_w;
                if (!inside or sl.elem != @backingInt(Program.Ref.none) or sl.count > 64) return g.leaf(e);
                try g.put(g.fresh(), "b$: {{\n const t$ = s.termBits({d}, {d}, {d});\n break :b$ small.resize(.{{ .v = t$[0], .x = t$[1] }}, {d}, {d}, {});\n}}", .{ sl.slot, sl.first, sl.count, sl.count, ty.width, ty.signed });
            },
            .neg, .not => {
                if (tys[d.a] != ty) return g.leaf(e);
                const l = try g.open(e, &.{d.a}, depth);
                try g.put(l, "break :b$ .{{ .v = ({s}) & 0x{x}, .x = 0 }};\n}}", .{ if (tag == .neg) "0 -% x$a.v" else "~x$a.v", small.mask(ty.width) });
            },
            .lnot, .truth => {
                if (!small.fits(tys[d.a])) return g.leaf(e);
                try w.writeAll("small.scalarIn(");
                if (tag == .lnot) try w.writeAll("switch (");
                try w.writeAll("small.truthOf(");
                try g.expr(d.a, depth + 1);
                try w.print(", {d})", .{tys[d.a].width});
                if (tag == .lnot) try w.writeAll(") { .one => .zero, .zero => .one, .x, .z => .x }");
                try w.print(", .{{ .width = {d}, .signed = {}, .real = false }})", .{ ty.width, ty.signed });
            },
            .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .bit_xnor => {
                if (tys[d.a] != ty or tys[d.b] != ty) return g.leaf(e);
                const l = try g.open(e, &.{ d.a, d.b }, depth);
                const op = switch (tag) {
                    .add => "x$a.v +% x$b.v",
                    .sub => "x$a.v -% x$b.v",
                    .mul => "x$a.v *% x$b.v",
                    .bit_and => "x$a.v & x$b.v",
                    .bit_or => "x$a.v | x$b.v",
                    .bit_xor => "x$a.v ^ x$b.v",
                    else => "~(x$a.v ^ x$b.v)", // else: `~^`
                };
                try g.put(l, "break :b$ .{{ .v = ({s}) & 0x{x}, .x = 0 }};\n}}", .{ op, small.mask(ty.width) });
            },
            .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor => {
                if (!small.fits(tys[d.a])) return g.leaf(e);
                const l = try g.open(e, &.{d.a}, depth);
                switch (tag) {
                    .red_and, .red_nand => try g.put(l, "const r$ = x$a.v == 0x{x};\n", .{small.mask(tys[d.a].width)}),
                    .red_or, .red_nor => try g.put(l, "const r$ = x$a.v != 0;\n", .{}),
                    else => try g.put(l, "const r$ = @popCount(x$a.v) & 1 == 1;\n", .{}), // else: the xor pair
                }
                const flip = tag == .red_nand or tag == .red_nor or tag == .red_xnor;
                try g.put(l, "break :b$ small.scalarIn(if (r$ != {}) .one else .zero, .{{ .width = {d}, .signed = {}, .real = false }});\n}}", .{ flip, ty.width, ty.signed });
            },
            .shl, .shr, .ashl, .ashr => {
                if (tys[d.a] != ty or !small.fits(tys[d.b])) return g.leaf(e);
                const l = try g.open(e, &.{ d.a, d.b }, depth);
                const wd = ty.width;
                try g.put(l, "const n$: u32 = @intCast(@min(x$b.v, {d}));\n", .{wd});
                if (tag == .shl or tag == .ashl)
                    try g.put(l, "const r$: u64 = if (n$ == {d}) 0 else x$a.v << @intCast(n$);\n", .{wd})
                else if (tag == .ashr and ty.signed)
                    try g.put(l, "const r$: u64 = @bitCast(@as(i64, @bitCast(small.signExtend(x$a.v, {d}))) >> @intCast(@min(n$, 63)));\n", .{wd})
                else
                    try g.put(l, "const r$: u64 = if (n$ == {d}) 0 else x$a.v >> @intCast(n$);\n", .{wd});
                try g.put(l, "break :b$ .{{ .v = r$ & 0x{x}, .x = 0 }};\n}}", .{small.mask(wd)});
            },
            .land, .lor => {
                if (!small.fits(tys[d.a]) or !small.fits(tys[d.b])) return g.leaf(e);
                const l = g.fresh();
                const ty_text = "{{ .width = {d}, .signed = {}, .real = false }}";
                try g.put(l, "b$: {{\n const l$ = small.truthOf(", .{});
                try g.expr(d.a, depth + 1);
                try g.put(l, ", {d});\n if (l$ == {s}) break :b$ small.scalarIn(l$, ." ++ ty_text ++ ");\n const r$ = small.truthOf(", .{ tys[d.a].width, if (tag == .land) ".zero" else ".one", ty.width, ty.signed });
                try g.expr(d.b, depth + 1);
                try w.print(", {d});\n", .{tys[d.b].width});
                if (tag == .land)
                    try g.put(l, " const t$: std_sim.logic.Bit = if (l$ == .zero or r$ == .zero) .zero else if (l$ == .one and r$ == .one) .one else .x;\n", .{})
                else
                    try g.put(l, " const t$: std_sim.logic.Bit = if (l$ == .one or r$ == .one) .one else if (l$ == .zero and r$ == .zero) .zero else .x;\n", .{});
                try g.put(l, " break :b$ small.scalarIn(t$, ." ++ ty_text ++ ");\n}}", .{ ty.width, ty.signed });
            },
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                const at = tys[d.a];
                if (!small.fits(at) or tys[d.b] != at) return g.leaf(e);
                const l = try g.open(e, &.{ d.a, d.b }, depth);
                const op = switch (tag) {
                    .eq, .case_eq => "==",
                    .neq, .case_neq => "!=",
                    .lt => "<",
                    .le => "<=",
                    .gt => ">",
                    else => ">=", // else: `>=`
                };
                if (at.signed and !(tag == .eq or tag == .neq or tag == .case_eq or tag == .case_neq))
                    try g.put(l, "const r$ = @as(i64, @bitCast(small.signExtend(x$a.v, {d}))) {s} @as(i64, @bitCast(small.signExtend(x$b.v, {d})));\n", .{ at.width, op, at.width })
                else
                    try g.put(l, "const r$ = x$a.v {s} x$b.v;\n", .{op});
                try g.put(l, "break :b$ small.scalarIn(if (r$) .one else .zero, .{{ .width = {d}, .signed = {}, .real = false }});\n}}", .{ ty.width, ty.signed });
            },
            .cond => {
                const arms = p.extra[d.b..][0..2];
                if (!small.fits(tys[d.a]) or tys[arms[0]] != ty or tys[arms[1]] != ty) return g.leaf(e);
                const l = g.fresh();
                g.uses_a = true;
                try g.put(l, "b$: {{\n const c$: V = ", .{});
                try g.expr(d.a, depth + 1);
                try g.put(l, ";\n break :b$ switch (small.truthOf(c$, {d})) {{\n .one => ", .{tys[d.a].width});
                try g.expr(arms[0], depth + 1);
                try w.writeAll(",\n .zero => ");
                try g.expr(arms[1], depth + 1);
                try w.print(",\n .x, .z => try small.value(s, a, {d}),\n }};\n}}", .{e});
            },
            .convert => {
                if (!small.fits(tys[d.a])) return g.leaf(e);
                try w.writeAll("small.resize(");
                try g.expr(d.a, depth + 1);
                try w.print(", {d}, {d}, {})", .{ tys[d.a].width, ty.width, ty.signed });
            },
            // else: the other rows are `small.value`'s.
            else => try g.leaf(e),
        }
    }

    /// Opens block `b<n>` binding `x<n>a` and `x<n>b` to `ops`' values, and
    /// hands an x or z among them to `small.value`; returns `n`. Every name
    /// a block declares carries its `n`, so nested blocks never shadow.
    fn open(g: *Gen, e: u32, ops: []const u32, depth: u32) Error!u32 {
        assert(ops.len >= 1 and ops.len <= 2);
        const l = g.fresh();
        g.uses_a = true;
        try g.put(l, "b$: {{\n", .{});
        for (ops, "ab"[0..ops.len]) |op, k| {
            try g.put(l, " const x${c}: V = ", .{k});
            try g.expr(op, depth + 1);
            try g.w.writeAll(";\n");
        }
        try g.put(l, " if ((x$a.x | x${c}.x) != 0) break :b$ try small.value(s, a, {d});\n ", .{ "ab"[ops.len - 1], e });
        return l;
    }

    /// `w.print(f, args)` with each `$` written as `l`: the names of
    /// block `b<l>`. Asserts the text fits 1 KiB.
    fn put(g: *Gen, l: u32, comptime f: []const u8, args: anytype) Error!void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, f, args) catch unreachable; // A prong's line is short.
        var parts = std.mem.splitScalar(u8, text, '$');
        try g.w.writeAll(parts.first());
        while (parts.next()) |rest| {
            try g.w.print("{d}", .{l});
            try g.w.writeAll(rest);
        }
    }

    fn fresh(g: *Gen) u32 {
        g.labels += 1;
        return g.labels;
    }

    /// Row `e` evaluated whole by the interpreter's `small.value`.
    fn leaf(g: *Gen, e: u32) Error!void {
        g.uses_a = true;
        try g.w.print("(try small.value(s, a, {d}))", .{e});
    }

    /// Whether row `e` has no effect: evaluating it twice is evaluating it
    /// once. False past `depth_max`.
    fn pure(g: *const Gen, e: u32, depth: u32) bool {
        assert(e < g.p.exprs.len);
        if (depth >= depth_max) return false;
        assert(depth < depth_max); // past the cutoff above: every recursive call lands here only while bounded.
        const p = g.p;
        const d = p.exprs.items(.data)[e];
        return switch (p.exprs.items(.tag)[e]) {
            .constant, .slot => true,
            .select => blk: {
                const sl = p.extraData(Program.Select, d.a);
                break :blk sl.elem == @backingInt(Program.Ref.none) and (sl.mode == .const_part or g.pure(sl.index, depth + 1));
            },
            .elem => blk: {
                const el = p.extraData(Program.Elem, d.a);
                const dims = p.list(el.dims);
                var k: usize = 0;
                while (k < dims.len) : (k += Program.Elem.dim_words) if (!g.pure(dims[k], depth + 1)) break :blk false;
                break :blk true;
            },
            .neg, .not, .lnot, .truth, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .convert, .replicate => g.pure(d.a, depth + 1),
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr, .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .land, .lor => g.pure(d.a, depth + 1) and g.pure(d.b, depth + 1),
            .cond => blk: {
                const arms = p.extra[d.b..][0..2];
                break :blk g.pure(d.a, depth + 1) and g.pure(arms[0], depth + 1) and g.pure(arms[1], depth + 1);
            },
            // else: a call, a system function, a real row, a concatenation:
            // left whole to `small.value`.
            else => false,
        };
    }
};

/// Writes `native` and its `native_pcs` bitset (the design's compiled
/// instructions) to `w`; whether it compiled any (none: writes neither,
/// and no `Config.native`/`Config.native_pcs`). `gpa` holds the prongs and
/// the bitset while they are written.
pub fn write(w: *std.Io.Writer, gpa: Allocator, p: *const Program) (Allocator.Error || Error)!bool {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var g: Gen = .{ .p = p, .w = &body.writer };
    const words = @divCeil(p.insts.len, 64);
    const bits = try gpa.alloc(u64, @max(words, 1));
    defer gpa.free(bits);
    @memset(bits, 0);
    var prongs: u32 = 0;
    for (0..p.insts.len) |pc| {
        if (g.inst(@intCast(pc)) catch return error.OutOfMemory) {
            bits[pc / 64] |= @as(u64, 1) << @intCast(pc % 64);
            prongs += 1;
        }
    }
    assert(prongs <= p.insts.len);
    if (prongs == 0) return false;
    var popcount: u32 = 0;
    for (bits[0..words]) |word| popcount += @popCount(word);
    assert(popcount == prongs); // Every set bit is one compiled prong, and no other.
    try w.writeAll(
        \\
        \\const std_sim = @import("std_sim");
        \\const State = std_sim.State;
        \\const small = std_sim.small;
        \\const V = small.V;
        \\
        \\fn native(s: *State, scratch: *@import("std").heap.ArenaAllocator, pc: *u32) State.Error!bool {
        \\
    );
    try w.writeAll(if (g.uses_a) "    const a = scratch.allocator();\n" else "    _ = scratch;\n");
    try w.writeAll("    sw: switch (pc.*) {\n");
    try w.writeAll(body.written());
    try w.writeAll("        else => return false,\n    }\n}\n\nconst native_pcs = [_]u64{\n");
    for (bits[0..words]) |word| try w.print("    0x{x},\n", .{word});
    try w.writeAll("};\n");
    return true;
}

// ---- private ----

test write {
    // Oracle: the text parses as Zig and holds a prong for the assignment
    // and none for the stop (what the prongs compute is `diff-native`'s).
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: std_sim.Builder = .init(a);
    const ty = Program.Ty.int(8, false);
    const x = try b.slot(ty, &.{0}, &.{0});
    const sum = try b.expr(.add, ty, try b.expr(.slot, ty, x, 0), try b.int(ty, 3));
    _ = try b.inst(.assign, try b.extraOf(Program.Place{ .kind = .slot, .a = x }), sum, 0);
    _ = try b.inst(.stop, 0, 0, 0);
    const p = b.finish();
    var aw: std.Io.Writer.Allocating = .init(a);
    try t.expect(try write(&aw.writer, a, &p));
    const text = try a.dupeSentinel(u8, aw.written(), 0);
    var tree = try std.zig.Ast.parse(a, text, .{});
    defer tree.deinit(a);
    try t.expectEqual(@as(usize, 0), tree.errors.len);
    try t.expect(std.mem.find(u8, text, "        0 => {") != null);
    try t.expect(std.mem.find(u8, text, "        1 => {") == null);
    try t.expect(std.mem.find(u8, text, "const native_pcs = [_]u64{") != null);
    // A design with nothing to compile writes nothing.
    var none: std_sim.Builder = .init(a);
    _ = try none.inst(.stop, 0, 0, 0);
    const q = none.finish();
    var empty: std.Io.Writer.Allocating = .init(a);
    try t.expect(!try write(&empty.writer, a, &q));
    try t.expectEqual(@as(usize, 0), empty.written().len);
}

test "case_select: a bare default (zero labels) still reads its scrutinee" {
    // Oracle: IEEE 1364-2005 A.6.7 allows `case (e) default ; endcase` — one
    // arm, zero labels. The scrutinee is bound (`const v = ...`) but the
    // label-comparison loop that would read it never runs when every arm
    // has zero labels, so it must be read some other way or Zig's "unused
    // local constant" fails the *generated* file, not this one: an
    // `std.zig.Ast.parse` on `text` cannot see it, since the rule is
    // AstGen's, not the parser's (confirmed with `zig ast-check` on a
    // standalone `const v = 3;` with no reader: it errors; parse alone
    // does not). This reproduces grammar_nullable_statement.v's regression
    // (exit status old 0, new 1) at the unit level.
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: std_sim.Builder = .init(a);
    const ty = Program.Ty.int(8, false);
    const scrutinee = try b.int(ty, 1);
    const dispatch = try b.inst(.case_select, 0, 0, 0);
    const target = try b.inst(.stop, 0, 0, 0);
    const arm = try b.extraOf(Program.Arm{ .labels = try b.listOf(&.{}), .target = target });
    const case = try b.extraOf(Program.Case{ .kind = .normal, .scrutinee = scrutinee, .arms = try b.listOf(&.{arm}), .fallback = target });
    b.setInst(dispatch, .case_select, case, 0);
    const p = b.finish();
    var aw: std.Io.Writer.Allocating = .init(a);
    try t.expect(try write(&aw.writer, a, &p));
    const text = try a.dupeSentinel(u8, aw.written(), 0);
    var tree = try std.zig.Ast.parse(a, text, .{});
    defer tree.deinit(a);
    try t.expectEqual(@as(usize, 0), tree.errors.len);
    try t.expect(std.mem.find(u8, text, "_ = v;") != null);
}

test "case_select: a labeled arm reads its scrutinee without a spurious discard" {
    // Regression: an unconditional `_ = v;` (the first cut of the fix
    // above) makes Zig's AstGen fail every *ordinary* `case` instead —
    // "pointless discard of local constant" wherever a label follows and
    // reads `v`, which is every arm with at least one label. This slipped
    // past both `diff-native` (its own oracle hole: a failed build
    // compared only against itself, `judge.buildFailed`) and this file's
    // own `case_default_only` test (zero labels, so the discard is never
    // spurious there) until the full corpus run named it on every
    // checked-in `native-gen/gen_*.v` fixture.
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: std_sim.Builder = .init(a);
    const ty = Program.Ty.int(8, false);
    const scrutinee = try b.int(ty, 1);
    const dispatch = try b.inst(.case_select, 0, 0, 0);
    const label = try b.int(ty, 1);
    const target = try b.inst(.stop, 0, 0, 0);
    const arm = try b.extraOf(Program.Arm{ .labels = try b.listOf(&.{label}), .target = target });
    const case = try b.extraOf(Program.Case{ .kind = .normal, .scrutinee = scrutinee, .arms = try b.listOf(&.{arm}), .fallback = target });
    b.setInst(dispatch, .case_select, case, 0);
    const p = b.finish();
    var aw: std.Io.Writer.Allocating = .init(a);
    try t.expect(try write(&aw.writer, a, &p));
    const text = try a.dupeSentinel(u8, aw.written(), 0);
    var tree = try std.zig.Ast.parse(a, text, .{});
    defer tree.deinit(a);
    try t.expectEqual(@as(usize, 0), tree.errors.len);
    try t.expect(std.mem.find(u8, text, "_ = v;") == null);
    try t.expect(std.mem.find(u8, text, "if (((v.v ^ l.v)") != null);
}
