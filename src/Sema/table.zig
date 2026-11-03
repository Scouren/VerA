//! §9.21 `$table_model` and §4.6.4.3's file form of `noise_table` (the
//! old `analog/table_model.zig`): the call in, one self-describing
//! `$table_model` call out,
//!
//!     $table_model(ND, NP, NCOL, dep, "<ctl>", site, previous, in₀…, row₀…)
//!
//! the dimensionality, the sample count, the column count, the dependent
//! column, one interpolation and two extrapolation bytes per dimension, the
//! array-source snapshot site (0 for a file), the previous snapshot call,
//! the lookup point and the sample block projected onto the columns the
//! lookup reads (independents outermost first, the dependent last). A data
//! file is never opened here: the first site that names one stops the
//! analysis with `zcu.data_want` set, and the caller answers it
//! (`Zcu.answerData`) before `Sema.analyze` runs again.
//! Cites: VAMS-2023 §3.4.8, §4.6.4.3, §9.21, §9.21.1, §9.21.2, §9.21.5.
//!
//! Contents:
//! - `pub fn lower(s: *Sema, b: *Block, args: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value`
//! - `pub fn noiseFile(s: *Sema, b: *Block, name: []const u8, src: Inst.Ref) Allocator.Error!?[]const f64`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const op = @import("op.zig");
const Inst = vams.Vir.Inst;
const SysFn = vams.SysFn;
const Block = Sema.Block;
const Value = Sema.Value;
const Ref = Air.Inst.Ref;

/// A data file's answer: its bytes, "not there", or not answered yet.
const Data = union(enum) { bytes: []const u8, absent, pending };

/// A parsed data file: row-major values and the column count every row shares.
const TableFile = struct { vals: []const f64, cols: usize };

/// The most dimensions a table is lowered with (2^30 samples' minimum).
const dims_max: usize = 30;

/// §9.21 `$table_model(inputs..., data_source [, control])`.
pub fn lower(s: *Sema, b: *Block, all: []const Inst.Ref, src: Inst.Ref) Allocator.Error!Value {
    var n = all.len;
    while (n > 0 and all[n - 1] == .none) n -= 1;
    const args = all[0..n];
    // Syntax 9-16: the inputs, then the data source (an array or a string).
    var i: usize = 0;
    while (i < args.len and args[i] != .none and !try isSource(s, b, args[i])) i += 1;
    const nd = i;
    if (nd == 0 or i == args.len) return refuse(s, b, src, "`$table_model(table_inputs, table_data_source [, table_control_string])` — one lookup expression per dimension, then the data source");
    if (nd > dims_max) return refuse(s, b, src, "more lookup dimensions than a table holds");
    var cols: std.ArrayList([]const Ref) = .empty;
    while (i < args.len and isArray(b, args[i])) : (i += 1) {
        var one: std.ArrayList(Ref) = .empty;
        _ = try op.vectorArg(s, b, args[i], &one);
        try cols.append(s.arena, one.items[1..]);
    }
    var strs: [2][]const u8 = .{ "", "" };
    var ns: usize = 0;
    while (i < args.len) : (i += 1) {
        if (args[i] == .none) continue;
        const c = (try decl.foldRef(s, b.unit, args[i])) orelse break;
        if (c != .str or ns == 2) break;
        strs[ns] = c.str;
        ns += 1;
    }
    if (i != args.len) return refuse(s, b, src, "trailing argument to `$table_model` is neither an array data source nor a constant string");
    var rows: []const Ref = &.{};
    var ncol: usize = 0;
    var np: usize = 0;
    var ctl: []const u8 = "";
    if (cols.items.len != 0) {
        if (ns > 1) return refuse(s, b, src, "an array data source takes at most one control string");
        ctl = strs[0];
        ncol = cols.items.len;
        np = cols.items[0].len;
        if (ncol <= nd) return refuse(s, b, src, "the lookup inputs need one independent array each plus an output array");
        for (cols.items) |c| if (c.len != np) return refuse(s, b, src, "the arrays of a `$table_model` data source are columns of one table and must be the same length");
        const flat = try s.arena.alloc(Ref, np * ncol);
        for (0..np) |r| for (cols.items, 0..) |c, k| {
            flat[r * ncol + k] = c[r];
        };
        rows = flat;
    } else {
        if (ns == 0) return refuse(s, b, src, "`$table_model` needs a data source: a file name, or one array per dimension plus an output array");
        ctl = strs[1];
        // §9.21.1 "The state of the data source is captured on the first
        // call": a file that is absent or no data set is that call's error,
        // so it lowers to an empty table the kernel refuses when reached.
        const text = switch (try data(s, strs[0])) {
            .pending => return expr.poison,
            .absent => null,
            .bytes => |t| t,
        };
        if (text) |t| if (parse(s, t)) |f| {
            if (f.cols <= nd) return refuse(s, b, src, "the data file has too few columns for its lookup inputs");
            ncol = f.cols;
            np = f.vals.len / ncol;
            const flat = try s.arena.alloc(Ref, f.vals.len);
            for (f.vals, flat) |v, *o| o.* = .fromIntern(try decl.intern(s, .{ .real = v }));
            rows = flat;
        };
        if (rows.len == 0) {
            ncol = nd + 1;
            np = 0;
            ctl = "";
        }
    }
    // §9.21: "at least two points per dimension (2ᴺ for N dimensions)".
    if (np != 0 and np < (@as(usize, 1) << @intCast(nd))) return refuse(s, b, src, "a table needs at least 2^N samples for N dimensions");
    const ext = try s.arena.alloc(u8, 3 * nd);
    const keep = try s.arena.alloc(usize, nd + 1);
    keep[nd] = (try parseCtl(s, b, src, ctl, nd, ncol, ext, keep[0..nd])) orelse return expr.poison;
    // Project the block onto the columns the lookup reads.
    const proj = try s.arena.alloc(Ref, np * (nd + 1));
    for (0..np) |r| for (keep, 0..) |c, j| {
        proj[r * (nd + 1) + j] = rows[r * ncol + c];
    };
    const site: usize = if (cols.items.len == 0) 0 else s.device.table_samples.items.len + 1;
    const previous: Ref = if (site == 0) .fromIntern(.zero_real) else try s.addInst(b, .{ .tag = .load, .data = .{ .un_op = .fromIndex(try effectSlot(s)) } });
    if (site != 0) try s.device.table_samples.append(s.gpa, @intCast(proj.len));
    var vals: std.ArrayList(Ref) = .empty;
    for ([_]usize{ nd, np, nd + 1, nd }) |x| try vals.append(s.arena, .fromIntern(try decl.intern(s, .{ .int = @intCast(x) })));
    try vals.append(s.arena, .fromIntern(try decl.intern(s, .{ .str = ext })));
    try vals.append(s.arena, .fromIntern(try decl.intern(s, .{ .int = @intCast(site) })));
    try vals.append(s.arena, previous);
    for (args[0..nd]) |a| try vals.append(s.arena, try expr.coerce(s, b, try expr.lower(s, b, a), .real));
    try vals.appendSlice(s.arena, proj);
    const result = try expr.call(s, b, @backingInt(SysFn.Tag.@"$table_model"), .real, vals.items);
    if (site != 0) _ = try s.addInst(b, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(try effectSlot(s)), .rhs = result } } });
    return .{ .ref = result, .ty = .real };
}

/// §4.6.4.3's file input: its frequency/power pairs, `f0, p0, f1, p1, ...`;
/// null when the analysis waits for the file, or after E0519.
pub fn noiseFile(s: *Sema, b: *Block, name: []const u8, src: Inst.Ref) Allocator.Error!?[]const f64 {
    const text = switch (try data(s, name)) {
        .pending => return null,
        .absent => {
            try s.fail(.E0519, b.unit.file, src, "cannot read the `noise_table` data source \"{s}\"", .{name});
            return null;
        },
        .bytes => |t| t,
    };
    const f = parse(s, text) orelse {
        try s.fail(.E0519, b.unit.file, src, "\"{s}\" is not frequency / power pairs of real or integer numbers", .{name});
        return null;
    };
    if (f.cols != 2) {
        try s.fail(.E0519, b.unit.file, src, "\"{s}\": LRM 4.6.4.3's input file is frequency / power PAIRS, one pair per line; found {d} numbers on a line", .{ name, f.cols });
        return null;
    }
    return f.vals;
}

// ---- private ----

fn refuse(s: *Sema, b: *Block, src: Inst.Ref, msg: []const u8) Allocator.Error!Value {
    try s.fail(.E0815, b.unit.file, src, "{s}", .{msg});
    return expr.poison;
}

/// The data file `name`: the caller's answer, or a request (`zcu.data_want`,
/// the first one unanswered) and `.pending`.
fn data(s: *Sema, name: []const u8) Allocator.Error!Data {
    const zcu = s.zcu;
    if (zcu.data_files.get(name)) |answer| return if (answer) |bytes| .{ .bytes = bytes } else .absent;
    if (zcu.data_want == null) zcu.data_want = try zcu.gpa.dupe(u8, name);
    return .pending;
}

/// The slot that orders array-source snapshots (each reads the last one's
/// result), seeded 0 at entry.
fn effectSlot(s: *Sema) Allocator.Error!Air.Inst.Index {
    if (s.table_effect) |slot| return slot;
    const slot = try decl.addAlloc(s, .real);
    try s.entry.append(s.arena, try s.air.addInst(s.gpa, .{ .tag = .assign, .data = .{ .bin_op = .{ .lhs = .fromIndex(slot), .rhs = .fromIntern(.zero_real) } } }));
    s.table_effect = slot;
    return slot;
}

/// Whether `a` is part of the data source: an array or a constant string.
fn isSource(s: *Sema, b: *Block, a: Inst.Ref) Allocator.Error!bool {
    if (isArray(b, a)) return true;
    const c = (try decl.foldRef(s, b.unit, a)) orelse return false;
    return c == .str;
}

/// §9.21.1 one array column: a pattern, or a one-dimensional array's name.
fn isArray(b: *Block, a: Inst.Ref) bool {
    const vir = b.unit.vir;
    const i = a.toIndex() orelse return false;
    return switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .pattern, .concat => true,
        .decl_ref => if (b.unit.binds.get(decl.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl))) |x| x == .array and x.array.dims.len == 1 else false,
        else => false, // else: neither §9.21.1 array shape
    };
}

/// §9.21.1's text format: rows separated by newlines, columns by spaces or
/// tabs, `#` to the end of a line a comment, blank lines ignored, every
/// number real or integer, every row as wide as the first. Null for text
/// that is no data set.
fn parse(s: *Sema, text: []const u8) ?TableFile {
    var vals: std.ArrayList(f64) = .empty;
    var cols: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.findScalar(u8, raw, '#')) |h| raw[0..h] else raw;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |tok| {
            const x = std.fmt.parseFloat(f64, tok) catch return null;
            vals.append(s.arena, x) catch return null;
            n += 1;
        }
        if (n == 0) continue;
        if (cols == 0) cols = n;
        if (n != cols) return null;
    }
    if (cols == 0) return null;
    return .{ .vals = vals.items, .cols = cols };
}

/// §9.21.2 the control string: `3*nd` bytes into `ext` (interpolation, low
/// and high extrapolation, Tables 9-30/9-31; `1LL` by default, §9.21.5), the
/// source column of each dimension into `cmap`, and the dependent column
/// returned; null after E0815.
fn parseCtl(s: *Sema, b: *Block, src: Inst.Ref, ctl: []const u8, nd: usize, ncol: usize, ext: []u8, cmap: []usize) Allocator.Error!?usize {
    @memset(ext, 'L');
    for (0..nd) |dim| ext[3 * dim] = '1';
    const semi = std.mem.findScalar(u8, ctl, ';');
    const head = if (semi) |x| ctl[0..x] else ctl;
    var sel: usize = 1;
    if (semi) |x| {
        const tail = std.mem.trim(u8, ctl[x + 1 ..], " \t");
        if (tail.len != 0) sel = std.fmt.parseInt(usize, tail, 10) catch 0;
    }
    var d: usize = 0;
    var col: usize = 0;
    var it = std.mem.splitScalar(u8, head, ',');
    while (it.next()) |raw| {
        const sub = std.mem.trim(u8, raw, " \t");
        // Table 9-30 `I`: "Ignore this input column".
        if (sub.len != 0 and sub[0] == 'I') {
            if (sub.len != 1) return fail(s, b, src, "Table 9-30's `I` ignores a column and takes no extrapolation characters");
            col += 1;
            continue;
        }
        if (d >= nd) {
            if (sub.len == 0) continue;
            return fail(s, b, src, "the control string has more interpolation sub-strings than lookup inputs");
        }
        cmap[d] = col;
        col += 1;
        defer d += 1;
        var j: usize = 0;
        if (sub.len != 0 and std.mem.findScalar(u8, "D123", sub[0]) != null) {
            ext[3 * d] = sub[0];
            j = 1;
        }
        const xs = sub[j..];
        if (xs.len > 2) return fail(s, b, src, "a control sub-string carries at most 2 extrapolation characters");
        for (xs) |c| if (std.mem.findScalar(u8, "CLE", c) == null) return fail(s, b, src, "a character in neither Table 9-30 nor Table 9-31");
        if (xs.len == 1) {
            ext[3 * d + 1] = xs[0];
            ext[3 * d + 2] = xs[0];
        } else if (xs.len == 2) {
            ext[3 * d + 1] = xs[0];
            ext[3 * d + 2] = xs[1];
        }
    }
    while (d < nd) : (d += 1) {
        cmap[d] = col;
        col += 1;
    }
    if (sel == 0 or col >= ncol or sel > ncol - col) return fail(s, b, src, "the dependent selector names no dependent column");
    assert(col + sel - 1 < ncol);
    return col + sel - 1;
}

fn fail(s: *Sema, b: *Block, src: Inst.Ref, msg: []const u8) Allocator.Error!?usize {
    try s.fail(.E0815, b.unit.file, src, "{s}", .{msg});
    return null;
}
