//! The state of one `sites.collect` walk: the file, the module and its
//! declarations, and the rows written so far; the module's item lists,
//! parameters, ports, nets and variables. Its processes and drivers are
//! `Walk/body.zig`, its expressions `Walk/expr.zig`.
//! Cites: IEEE 1364-2005 §4.10, §12.2, §12.3.3.
//!
//! Contents:
//! - `pub fn row`
//! - `pub fn tag`
//! - `pub fn data`
//! - `pub fn payload`
//! - `pub fn node`
//! - `pub fn at`
//! - `pub fn mainAt`
//! - `pub fn string`
//! - `pub fn countParams`
//! - `pub fn moduleRows`
//! - `pub fn flattenItems`
//! - `pub fn declare`
//! - `pub fn declRows`
//! - `pub fn pulse`
//! - `pub fn redeclares`
//! - `pub fn rangeConst`
//! - `pub const processRows`
//! - `pub const stmtsOf`
//! - `pub const operands`
//! - `pub const flat`
//! - `pub const blockRow`
//! - `pub const leaves`
//! - `pub const driverRows`
//! - `pub const always`
//! - `pub const terms`
//! - `pub const targets`
//! - `pub const stmts`
//! - `pub const lvalue`
//! - `pub const expr`
//! - `pub const select`
//! - `pub const lvalueBase`
//! - `pub const known`
//! - `pub const refName`
//! - `pub const constant`
//! - `pub const unsized`
//! - `pub const paramAt`
//! - `pub const keywordAt`
//! - `pub fn last`
//! - `pub fn forInit`
//! - `pub fn literal`
//! - `pub fn literalAt`
//! - `pub fn isPull`
//! - `pub fn isSwitch`
//! - `pub fn firstTok`
//! - `pub const max_depth`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const decl = @import("../../decl.zig");
const sites = @import("../sites.zig");
const bodies = @import("Walk/body.zig");
const exprs = @import("Walk/expr.zig");
const Phase = sites.Phase;
const Kind = sites.Kind;
const Row = sites.Row;
const none = sites.none;
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Ast = vams.Ast;

/// Generate nesting and statement depth past this are not walked: the
/// front end bounds them first.
pub const max_depth = 4096;

/// `Walk/body.zig`'s `processRows`.
pub const processRows = bodies.processRows;
/// `Walk/body.zig`'s `stmtsOf`.
pub const stmtsOf = bodies.stmtsOf;
/// `Walk/body.zig`'s `operands`.
pub const operands = bodies.operands;
/// `Walk/body.zig`'s `flat`.
pub const flat = bodies.flat;
/// `Walk/body.zig`'s `blockRow`.
pub const blockRow = bodies.blockRow;
/// `Walk/body.zig`'s `leaves`.
pub const leaves = bodies.leaves;
/// `Walk/body.zig`'s `driverRows`.
pub const driverRows = bodies.driverRows;
/// `Walk/body.zig`'s `always`.
pub const always = bodies.always;
/// `Walk/body.zig`'s `terms`.
pub const terms = bodies.terms;
/// `Walk/body.zig`'s `targets`.
pub const targets = bodies.targets;
/// `Walk/body.zig`'s `stmts`.
pub const stmts = bodies.stmts;
/// `Walk/expr.zig`'s `lvalue`.
pub const lvalue = exprs.lvalue;
/// `Walk/expr.zig`'s `expr`.
pub const expr = exprs.expr;
/// `Walk/expr.zig`'s `select`.
pub const select = exprs.select;
/// `Walk/expr.zig`'s `lvalueBase`.
pub const lvalueBase = exprs.lvalueBase;
/// `Walk/expr.zig`'s `known`.
pub const known = exprs.known;
/// `Walk/expr.zig`'s `refName`.
pub const refName = exprs.refName;
/// `Walk/expr.zig`'s `constant`.
pub const constant = exprs.constant;
/// `Walk/expr.zig`'s `unsized`.
pub const unsized = exprs.unsized;
/// `Walk/expr.zig`'s `paramAt`.
pub const paramAt = exprs.paramAt;
/// `Walk/expr.zig`'s `keywordAt`.
pub const keywordAt = exprs.keywordAt;

a: Allocator,
vir: *const Vir,
tree: *const Ast,
rows: std.MultiArrayList(Row) = .empty,
module: u32 = none,
phase: Phase = .file,
group: u32 = 0,
/// The module's declarations (generate items included), canonical
/// instruction to whether it is a reg (a variable, or a port completed
/// by or typed as one); and its parameters.
names: std.AutoHashMapUnmanaged(Inst.Index, bool) = .empty,
params: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty,
/// The parameters folded so far (§12.2: a default reads earlier ones).
seen: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty,
/// The module's items in the old lists' order, generate bodies inlined.
items: std.ArrayList(Inst.Index) = .empty,
/// Per module of the file, its parameter count (the old table's rows).
counts: std.StringHashMapUnmanaged(u32) = .empty,
/// The module's own generate constructs, in source order.
gens: std.ArrayList(Inst.Index) = .empty,

const Walk = @This();

/// Appends one refusal of the current module (none for a file row).
pub fn row(w: *Walk, phase: Phase, kind: Kind, offset: u32, name: []const u8) Allocator.Error!void {
    try w.rows.append(w.a, .{ .module = if (phase == .file) none else w.module, .phase = phase, .group = w.group, .kind = kind, .at = offset, .name = name });
}

/// The tag of instruction `i`.
pub fn tag(w: *const Walk, i: Inst.Index) Inst.Tag {
    return w.vir.instructions.items(.tag)[@backingInt(i)];
}

/// The data of instruction `i`.
pub fn data(w: *const Walk, i: Inst.Index) Inst.Data {
    return w.vir.instructions.items(.data)[@backingInt(i)];
}

/// The payload `T` of `pl_node` instruction `i`.
pub fn payload(w: *const Walk, comptime T: type, i: Inst.Index) T {
    return w.vir.extraData(T, w.data(i).pl_node.payload_index);
}

/// The tree node of `pl_node` instruction `i`.
pub fn node(w: *const Walk, i: Inst.Index) Ast.Node.Index {
    return w.data(i).pl_node.src_node;
}

/// The offset of instruction `i`'s first token, as the old parser's
/// `main_tok` of a statement or an expression.
pub fn at(w: *const Walk, i: Inst.Index) u32 {
    const d = w.data(i);
    return switch (Inst.dataKind(w.tag(i))) {
        .pl_node => firstTok(w.tree, d.pl_node.src_node),
        .un_node => firstTok(w.tree, d.un_node.src_node),
        .decl_tok => w.tree.tokenStart(d.decl_tok.src_tok),
        .str_tok => w.tree.tokenStart(d.str_tok.src_tok),
        .int, .float, .str => 0,
    };
}

/// The offset of `i`'s node's main token (a declared name, a keyword).
pub fn mainAt(w: *const Walk, i: Inst.Index) u32 {
    return w.tree.tokenStart(w.tree.nodeMainToken(w.node(i)));
}

/// The bytes of `s`.
pub fn string(w: *const Walk, s: Vir.String) []const u8 {
    return w.vir.string(s);
}

/// Each module's parameter count, the first module of a name kept.
pub fn countParams(w: *Walk, builtin_end: u32) Allocator.Error!void {
    w.counts.clearRetainingCapacity();
    for (w.vir.decls(), 0..) |d, k| {
        if (k < builtin_end or d.kind != .module) continue;
        const gop = try w.counts.getOrPut(w.a, w.string(d.name));
        if (gop.found_existing) continue;
        const m = w.payload(Inst.Module, d.inst);
        w.items.clearRetainingCapacity();
        w.gens.clearRetainingCapacity();
        try w.flattenItems(w.vir.body(m.params));
        try w.flattenItems(w.vir.body(m.body));
        var n: u32 = 0;
        for (w.items.items) |i| n += @intFromBool(w.tag(i) == .param);
        gop.value_ptr.* = n;
    }
}

/// Every row of the module at instruction `m_inst`.
pub fn moduleRows(w: *Walk, m_inst: Inst.Index) Allocator.Error!void {
    const m = w.payload(Inst.Module, m_inst);
    w.names.clearRetainingCapacity();
    w.params.clearRetainingCapacity();
    w.seen.clearRetainingCapacity();
    w.items.clearRetainingCapacity();
    w.gens.clearRetainingCapacity();
    w.group = 0;
    try w.flattenItems(w.vir.body(m.params));
    try w.flattenItems(w.vir.body(m.ports));
    try w.flattenItems(w.vir.body(m.body));
    try w.declare();
    const mod_at = w.tree.tokenStart(w.tree.nodeMainToken(w.node(m_inst)));
    // The item lists, in the old emitter's order of checks (`rtlil.zig`
    // ranks the kinds): generate constructs innermost first.
    for (w.gens.items) |g| try w.row(.item, .analog, w.mainAt(g), "");
    if (m.flags.kind == .connectmodule) try w.row(.item, .connect, mod_at, "");
    var genvar = false;
    for (w.items.items) |i| switch (w.tag(i)) {
        .analog, .analog_initial => try w.row(.item, .analog, w.mainAt(i), ""),
        .genvar => genvar = true,
        .defparam => if (last(w, w.payload(Inst.Assign, i).lhs).toIndex()) |l| try w.row(.item, .defparam, w.at(l), ""),
        .function => {
            const f = w.payload(Inst.Function, i);
            try w.row(.item, if (f.flags.analog) .analog_function else .task, w.mainAt(i), "");
        },
        .event => try w.row(.item, .event, w.mainAt(i), ""),
        .branch => try w.row(.item, .branch, w.mainAt(i), ""),
        .instance => {
            const inst = w.payload(Inst.Instance, i);
            if (inst.flags.kind != .gate) continue;
            const kw = w.string(inst.target);
            if (isPull(kw)) try w.row(.item, .pull, w.keywordAt(i, kw), "");
            if (isSwitch(kw)) try w.row(.item, .switch_prim, w.mainAt(i), "");
        },
        else => {}, // else: checked in a later phase
    };
    if (genvar) try w.row(.item, .genvar, mod_at, "");
    try w.declRows();
    try w.processRows(.initial);
    try w.driverRows();
    try w.processRows(.always);
}

/// The module's items; a generate construct is listed apart, its
/// block's items left on the block, as the old digital parse keeps them.
pub fn flattenItems(w: *Walk, body: []const Inst.Index) Allocator.Error!void {
    for (body) |i| switch (w.tag(i)) {
        .gen_for, .gen_if, .gen_case => try w.gens.append(w.a, i),
        // A `PATHPULSE$` limit is a pulse row of the old parser's, no parameter.
        .specify => for (w.vir.body(w.payload(Inst.Process, i).body)) |x| if (w.tag(x) == .param and !w.pulse(x)) try w.items.append(w.a, x),
        else => try w.items.append(w.a, i), // else: a module item
    };
}

/// Every module-level name: canonical declaration to whether it is a reg.
pub fn declare(w: *Walk) Allocator.Error!void {
    for (w.items.items) |i| {
        const t = w.tag(i);
        switch (t) {
            .io, .net, .variable, .param => {},
            else => continue, // else: declares no name the old table holds
        }
        const c = decl.canonical(w.vir, i);
        const reg = switch (t) {
            .variable => true,
            .io => w.payload(Inst.Io, i).flags.storage != .none,
            else => false, // else: a net or a parameter
        };
        const gop = try w.names.getOrPut(w.a, c);
        gop.value_ptr.* = (gop.found_existing and gop.value_ptr.*) or reg;
        if (t == .param) try w.params.put(w.a, c, {});
    }
}

/// Parameters, ports, nets and variables, each phase in source order.
pub fn declRows(w: *Walk) Allocator.Error!void {
    w.phase = .param;
    for (w.items.items) |i| if (w.tag(i) == .param) {
        const p = w.payload(Inst.Param, i);
        if (w.pulse(i)) continue;
        // The old table declares parameters first: a second one of a
        // name is the duplicate, a net or variable of it comes later.
        if (p.prev.toIndex()) |first| if (w.tag(first) == .param) {
            try w.row(.param, .duplicate, w.mainAt(i), "");
            continue;
        };
        try w.seen.ensureUnusedCapacity(w.a, 1);
        defer w.seen.putAssumeCapacity(decl.canonical(w.vir, i), {});
        const value = w.vir.body(p.value);
        const real_default = value.len != 0 and w.tag(value[value.len - 1]) == .real;
        if (p.flags.storage == .real or p.flags.storage == .realtime or (real_default and p.flags.storage == .none and p.range.len == 0)) continue;
        if (!try w.rangeConst(p.range, i, .param)) continue;
        if (value.len == 0 or !w.constant(value[value.len - 1].toRef(), true, 0))
            try w.row(.param, .param_value, w.mainAt(i), w.string(p.name));
    };
    for (w.items.items) |i| switch (w.tag(i)) {
        .port => {
            const p = w.payload(Inst.Port, i);
            const value = w.vir.body(p.value);
            if (value.len == 0) continue;
            const v = value[value.len - 1];
            if (w.tag(v) == .concat) {
                const parts = w.vir.list(Inst.Ref, w.payload(Inst.Refs, v));
                const second = if (parts.len > 1) parts[1].toIndex() else null;
                try w.row(.port, .port_expr, if (second) |x| w.at(x) else w.at(v), "");
            } else if (w.tree.nodeTag(w.node(i)) == .named_port) {
                try w.row(.port, .port_expr, w.at(v), "");
            } else if (w.tag(v) != .decl_ref) {
                try w.row(.port, .port_select, w.mainAt(i), try std.fmt.allocPrint(w.a, "{s}[...]", .{w.string(p.name)}));
            }
        },
        .io => {
            const io = w.payload(Inst.Io, i);
            if (io.flags.net == .wreal) try w.row(.port, .port_wreal, w.mainAt(i), "");
            _ = try w.rangeConst(io.range, i, .port);
        },
        else => {}, // else: a later phase
    };
    for (w.items.items) |i| if (w.tag(i) == .net) {
        const n = w.payload(Inst.Net, i);
        if (w.redeclares(n.prev, n.name)) {
            try w.row(.net, .duplicate, w.mainAt(i), "");
            continue;
        }
        if (n.prev != .none) continue; // §12.3.3: a net completing a port is the port
        if (n.flags.net == .wreal) try w.row(.net, .net_wreal, w.mainAt(i), "");
        if (n.dims.len != 0) try w.row(.net, .net_array, w.mainAt(i), "");
        _ = try w.rangeConst(n.range, i, .net);
    };
    for (w.items.items) |i| if (w.tag(i) == .variable) {
        const v = w.payload(Inst.Variable, i);
        if (w.redeclares(v.prev, v.name)) {
            try w.row(.variable, .duplicate, w.mainAt(i), "");
            continue;
        }
        if (v.prev != .none) continue;
        const name = w.string(v.name);
        if (v.dims.len != 0) try w.row(.variable, .var_array, w.mainAt(i), name);
        switch (v.flags.storage) {
            .real, .realtime => try w.row(.variable, .var_real, w.mainAt(i), ""),
            .string => try w.row(.variable, .var_string, w.mainAt(i), ""),
            .none, .reg, .integer, .time => {},
        }
        _ = try w.rangeConst(v.range, i, .variable);
    };
}

/// Whether specparam `i` is a §14.6.1 `PATHPULSE$` limit pair.
pub fn pulse(w: *const Walk, i: Inst.Index) bool {
    const v = last(w, w.payload(Inst.Param, i).value).toIndex() orelse return false;
    return w.tag(v) == .pulse_limits;
}

/// Whether a net or variable named `name`, whose first declaration is
/// `prev`, redeclares a name (§4.10): one a parameter has, or one
/// declared before it that is no port it completes (§12.3.3).
pub fn redeclares(w: *const Walk, prev: Inst.Ref, name: Vir.String) bool {
    if (prev.toIndex()) |first| if (w.tag(first) != .io) return true;
    for (w.items.items) |i| if (w.tag(i) == .param and w.payload(Inst.Param, i).name == name) return true;
    return false;
}

/// A declared `[msb:lsb]` whose bounds are not constant is E1220; one
/// of literal bounds past RTLIL's 32-bit `offset` E1221, or wider than
/// 2^31 - 1 bits E1222.
pub fn rangeConst(w: *Walk, range: Vir.Body, i: Inst.Index, phase: Phase) Allocator.Error!bool {
    for (w.vir.body(range)) |r| if (w.tag(r) == .range) {
        const b = w.payload(Inst.Bin, r);
        if (!w.constant(b.lhs, false, 0) or !w.constant(b.rhs, false, 0)) {
            try w.row(phase, .range_value, w.mainAt(i), "");
            return false;
        }
        const msb = literal(w, b.lhs) orelse continue;
        const lsb = literal(w, b.rhs) orelse continue;
        const text = try std.fmt.allocPrint(w.a, "[{d}:{d}]", .{ msb, lsb });
        if (std.math.cast(i32, msb) == null or std.math.cast(i32, lsb) == null) {
            try w.row(phase, .range_offset, w.mainAt(i), text);
            return false;
        }
        if (@abs(@as(i64, msb) - lsb) + 1 > std.math.maxInt(i32)) {
            try w.row(phase, .range_width, w.mainAt(i), text);
            return false;
        }
    };
    return true;
}

/// The value of a body: its last instruction.
pub fn last(w: *const Walk, b: Vir.Body) Inst.Ref {
    const xs = w.vir.body(b);
    return if (xs.len == 0) .none else xs[xs.len - 1].toRef();
}

/// Whether statement `k` of `body` is a `for`'s init, which Vir writes
/// before the loop and the old parser kept inside it.
pub fn forInit(w: *const Walk, body: []const Inst.Index, k: usize) bool {
    if (k + 1 >= body.len or w.tag(body[k + 1]) != .loop) return false;
    return w.at(body[k]) > w.at(body[k + 1]);
}

/// The value of an integer literal, or of a negated one, when it fits 64
/// bits signed; null for anything else. ponytail: literals only, as the
/// refusals that need a value (a range past 32 bits, a zero replication)
/// are written with literals; a parameter's value is Sema's to fold.
pub fn literal(w: *const Walk, r: Inst.Ref) ?i64 {
    return literalAt(w, r, 0);
}

pub fn literalAt(w: *const Walk, r: Inst.Ref, depth: u32) ?i64 {
    const i = r.toIndex() orelse return null;
    if (depth > 64) return null;
    switch (w.tag(i)) {
        .add, .sub => {
            const b = w.payload(Inst.Bin, i);
            const x = literalAt(w, b.lhs, depth + 1) orelse return null;
            const y = literalAt(w, b.rhs, depth + 1) orelse return null;
            return (if (w.tag(i) == .add) std.math.add(i64, x, y) else std.math.sub(i64, x, y)) catch null;
        },
        .decl_ref => {
            const c = decl.canonical(w.vir, w.data(i).decl_tok.decl);
            if (w.tag(c) != .param) return null;
            return literalAt(w, last(w, w.payload(Inst.Param, c).value), depth + 1);
        },
        .int => return std.math.cast(i64, w.data(i).int),
        .neg => {
            const v = literalAt(w, w.data(i).un_node.operand, depth + 1) orelse return null;
            return if (v == std.math.minInt(i64)) null else -v;
        },
        .big_int => {
            const n = w.payload(Inst.BigInt, i);
            const digits = w.string(n.digits);
            return std.fmt.parseInt(i64, digits, n.flags.radix) catch null;
        },
        else => return null, // else: no literal
    }
}

/// Whether gate keyword `kw` is a pull (A.3.1).
pub fn isPull(kw: []const u8) bool {
    return std.mem.eql(u8, kw, "pullup") or std.mem.eql(u8, kw, "pulldown");
}

/// Whether gate keyword `kw` is a §7.6 switch.
pub fn isSwitch(kw: []const u8) bool {
    const all = [_][]const u8{ "nmos", "pmos", "cmos", "rnmos", "rpmos", "rcmos", "tran", "rtran", "tranif0", "tranif1", "rtranif0", "rtranif1" };
    for (all) |s| if (std.mem.eql(u8, kw, s)) return true;
    return false;
}

/// The first token of `n`: an assignment's or a select's left operand's,
/// a call's callee's, else its main token.
pub fn firstTok(tree: *const Ast, n0: Ast.Node.Index) u32 {
    var n = n0;
    var depth: u32 = 0;
    while (depth < max_depth) : (depth += 1) {
        const d = tree.nodeData(n);
        n = switch (tree.nodeTag(n)) {
            .assign, .nonblocking_assign, .contribution, .binary, .index, .net_assign => d.node_and_node[0],
            .assign_timed, .nonblocking_assign_timed, .range_select, .indexed_select_up, .indexed_select_down, .call, .ternary => d.node_and_extra[0],
            .field_access => d.node_and_token[0],
            .task_enable => d.node,
            else => break, // else: the node starts at its main token
        };
    }
    return tree.tokenStart(tree.nodeMainToken(n));
}
