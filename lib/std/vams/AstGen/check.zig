//! The per-module rules that need the module's names but no other file:
//! one `module_decl` in, its diagnostics out. They match names to names
//! over the whole module, as the old parser and elaborator did, gathering
//! the module's declarations once (`Facts`) with the old parser's
//! hoisting out of generate blocks (§6.6: branches, functions, genvars,
//! nets, aliasparams, processes and assignments are the module's).
//! - §6.2/§6.5.2: a port declared twice (E0218), a body port declaration
//!   that names no header port (E0206), a header port with no direction
//!   (E0376, §6.5.2.2).
//! - §3.7: a `wreal` net with a second driver in its module (E0918).
//! - §4.7.1: an analog function formal with no data type (E0225).
//! - A.4.2/§6.6.2: a loop generate index that is no genvar (E0238), a
//!   generate block name that clashes in its scope (E0230).
//! - IEEE 1364-2005 §14.2-§14.3 module paths (E0245, `paths.zig`).
//! Cites: VAMS-2023 §3.7, §4.7.1, §6.2, §6.5.2, §6.5.2.2, §6.6.1, §6.6.2,
//! A.4.2; IEEE 1364-2005 §4.11, §12.3.3.
//!
//! Contents:
//! - `pub const Port = struct`, `pub const Facts = struct` (`Named`)
//! - `pub fn module(ag: *AstGen, node: Node.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const AstGen = @import("../AstGen.zig");
const decl = @import("decl.zig");
const stmt = @import("stmt.zig");
const paths = @import("paths.zig");
const Node = Ast.Node;
const Error = AstGen.Error;
const full = Ast.full;

/// One header port reference, its direction and range as the body's
/// declarations complete them (IEEE 1364-2005 §12.3.3).
pub const Port = struct {
    name: []const u8,
    tok: Ast.TokenIndex,
    dir: Vir.Inst.Direction = .none,
    /// The direction declaration's range, else a net or variable
    /// declaration's (the old `type_range`).
    range: Node.OptionalIndex = .none,
    wreal: bool = false,
};

/// What the module declares, by name, gathered with the old hoisting.
pub const Facts = struct {
    name: []const u8,
    ansi: bool,
    ports: std.ArrayList(Port) = .empty,
    /// The first port of each name.
    port_index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Module-level parameters, variables (and variable ports) and tasks.
    params: Names = .empty,
    vars: Names = .empty,
    tasks: Names = .empty,
    /// Module-level and hoisted.
    nets: Names = .empty,
    branches: Names = .empty,
    functions: Names = .empty,
    genvars: Names = .empty,
    aliasparams: Names = .empty,
    /// Names of the blocks `initial`/`always` open, past an event control.
    process_blocks: Names = .empty,
    /// `wreal` nets that complete no port, with whether they have an initializer.
    wreal_nets: std.ArrayList(struct { name: []const u8, init: bool }) = .empty,
    /// Continuous assignment targets and gate outputs (IEEE 1364-2005 §14.2.1's drivers).
    assigns: std.ArrayList(Node.Index) = .empty,
    gate_outs: std.ArrayList(Node.Index) = .empty,
    /// Named generate blocks and loop generate indices, with the outermost
    /// construct each is in.
    gen_blocks: std.ArrayList(Named) = .empty,
    gen_loops: std.ArrayList(Named) = .empty,
    analog_functions: std.ArrayList(Node.Index) = .empty,
    path_decls: std.ArrayList(Node.Index) = .empty,
    /// Net and variable declaration ranges by name (a port's `type_range`).
    type_ranges: std.StringHashMapUnmanaged(Node.Index) = .empty,

    pub const Named = struct { name: []const u8, tok: Ast.TokenIndex, construct: u32 };
};

const Names = std.StringHashMapUnmanaged(void);

/// The module walk: module-level items (`in_gen` false) and generate
/// blocks' items, hoisted as the old parser hoisted them.
const Walk = struct {
    ag: *AstGen,
    f: *Facts,
    /// Outermost generate constructs seen; the current one's number.
    constructs: u32 = 0,
    construct: u32 = 0,

    fn items(w: *Walk, list: []const Node.Index, in_gen: bool) Error!void {
        for (list) |it| try w.item(it, in_gen);
    }

    fn item(w: *Walk, it: Node.Index, in_gen: bool) Error!void {
        const tree = w.ag.tree;
        const a = w.ag.arena;
        const f = w.f;
        switch (tree.nodeTag(it)) {
            .port_decl => if (!in_gen) try w.bodyPorts(it),
            .param_decl => if (!in_gen) for (full.decl(tree, it).items) |p| try f.params.put(a, name(tree, p), {}),
            .var_decl => if (!in_gen) {
                const d = full.decl(tree, it);
                for (d.items) |x| {
                    try f.vars.put(a, name(tree, x), {});
                    if (d.range.unwrap()) |r| try f.type_ranges.put(a, name(tree, x), r);
                }
            },
            .net_decl => try w.nets(it, in_gen),
            .branch_decl => {
                const x = tree.extraData(tree.nodeData(it).extra, Node.Branch);
                for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Node.Index)) |d| try f.branches.put(a, name(tree, d), {});
            },
            .genvar_decl => for (full.list(tree, it)) |d| try f.genvars.put(a, name(tree, d), {}),
            .aliasparam_decl => try f.aliasparams.put(a, AstGen.identText(tree, tree.nodeMainToken(it) + 1), {}),
            .function_decl => {
                try f.functions.put(a, AstGen.identText(tree, stmt.functionName(tree, it)), {});
                if (tree.tokenTag(tree.nodeMainToken(it)) == .keyword_analog) try f.analog_functions.append(a, it);
            },
            .task_decl => if (!in_gen) try f.tasks.put(a, AstGen.identText(tree, stmt.functionName(tree, it)), {}),
            .initial, .always => try w.processBlock(tree.nodeData(it).node),
            .continuous_assign => for (full.decl(tree, it).items) |x| try f.assigns.append(a, tree.nodeData(x).node_and_node[0]),
            .gate_instantiation => if (gateDriver(tree.tokenTag(tree.nodeMainToken(it)))) for (full.decl(tree, it).items) |g| {
                const gi = tree.extraData(tree.nodeData(g).extra, Node.GateInstance);
                try f.gate_outs.append(a, tree.extraDataSlice(.{ .start = gi.terms_start, .end = gi.terms_end }, Node.Index)[0]);
            },
            .specify_block => for (full.list(tree, it)) |s| switch (tree.nodeTag(s)) {
                .path_decl => try f.path_decls.append(a, s),
                .param_decl => for (full.decl(tree, s).items) |p| try f.params.put(a, name(tree, p), {}),
                else => {}, // else: timing checks and pulse styles name no declaration
            },
            .generate_region => try w.items(full.list(tree, it), in_gen),
            .generate_for, .generate_if, .generate_case => {
                const outer = w.construct;
                if (!in_gen) {
                    w.constructs += 1;
                    w.construct = w.constructs;
                }
                defer w.construct = outer;
                try w.genConstruct(it);
            },
            else => {}, // else: instances, processes and the rest declare nothing these rules read
        }
    }

    /// §6.5.2 body port declarations: complete a header port, or E0218/E0206.
    fn bodyPorts(w: *Walk, it: Node.Index) Error!void {
        const tree = w.ag.tree;
        const f = w.f;
        const d = full.decl(tree, it);
        const words = decl.typeWords(tree, d.main_token);
        for (d.items) |x| {
            const t = tree.nodeMainToken(x);
            const n = AstGen.identText(tree, t);
            if (words.storage != .none) try f.vars.put(w.ag.arena, n, {});
            const p = &f.ports.items[
                f.port_index.get(n) orelse {
                    try w.ag.report(.E0206, t, "`{s}`", .{n});
                    continue;
                }
            ];
            // §6.2: a port the header or an earlier body declaration gave a
            // direction is already declared.
            if (p.dir != .none) {
                try w.ag.report(.E0218, t, "`{s}`", .{n});
                continue;
            }
            p.dir = direction(tree, d.main_token);
            if (d.range != .none) p.range = d.range;
            if (words.net == .wreal) p.wreal = true;
        }
    }

    fn nets(w: *Walk, it: Node.Index, in_gen: bool) Error!void {
        const tree = w.ag.tree;
        const f = w.f;
        const a = w.ag.arena;
        const main = tree.nodeMainToken(it);
        const words = decl.typeWords(tree, main);
        const x = tree.extraData(tree.nodeData(it).extra, Node.NetDecl);
        for (tree.extraDataSlice(.{ .start = x.items_start, .end = x.items_end }, Node.Index)) |d| {
            const t = tree.nodeMainToken(d);
            if (tree.tokenTag(t) == .system_identifier or tree.tokenTag(t + 1) == .period) continue;
            const n = AstGen.identText(tree, t);
            const has_init = tree.nodeData(d).extra_and_opt_node[1] != .none;
            try f.nets.put(a, n, {});
            if (x.range.unwrap()) |r| try f.type_ranges.put(a, n, r);
            const port = if (in_gen or words.net == .ground) null else f.port_index.get(n);
            if (port) |pi| {
                // §6.2: an ANSI port is not redeclared by a net type alone.
                if (f.ansi and words.discipline == null) try w.ag.report(.E0218, t, "`{s}`", .{n});
                if (words.net == .wreal) f.ports.items[pi].wreal = true;
                if (!has_init) continue;
            }
            if (words.net == .wreal and port == null) try f.wreal_nets.append(a, .{ .name = n, .init = has_init });
        }
    }

    /// IEEE 1364-2005 §4.11: an `initial`/`always` block's name, past an
    /// event control, is in the module's name space.
    fn processBlock(w: *Walk, body: Node.Index) Error!void {
        const tree = w.ag.tree;
        var s = body;
        while (tree.nodeTag(s) == .event_stmt) s = tree.nodeData(s).opt_node_and_node[1];
        if (tree.nodeTag(s) != .block) return;
        const kw = tree.nodeMainToken(s);
        if (tree.tokenTag(kw + 1) == .colon) try w.f.process_blocks.put(w.ag.arena, AstGen.identText(tree, kw + 2), {});
    }

    fn genConstruct(w: *Walk, it: Node.Index) Error!void {
        const tree = w.ag.tree;
        switch (tree.nodeTag(it)) {
            .generate_for => {
                const f = tree.extraData(tree.nodeData(it).extra, Node.For);
                if (tree.nodeTag(f.init) == .assign) {
                    const lhs = tree.nodeData(f.init).node_and_node[0];
                    if (tree.nodeTag(lhs) == .identifier) try w.f.gen_loops.append(w.ag.arena, .{ .name = name(tree, lhs), .tok = tree.nodeMainToken(lhs), .construct = w.construct });
                }
                try w.genArm(f.body);
            },
            .generate_if => {
                const x = tree.extraData(tree.nodeData(it).node_and_extra[1], Node.If);
                try w.genArm(x.then);
                if (x.@"else".unwrap()) |e| try w.genArm(e);
            },
            else => { // else: `generate_case`, the third construct
                const arms = tree.extraDataSlice(tree.extraData(tree.nodeData(it).node_and_extra[1], Node.SubRange), Node.Index);
                for (arms) |arm| try w.genArm(tree.nodeData(arm).extra_and_node[1]);
            },
        }
    }

    fn genArm(w: *Walk, arm: Node.Index) Error!void {
        const tree = w.ag.tree;
        switch (tree.nodeTag(arm)) {
            .null_stmt => {},
            .generate_block => {
                const kw = tree.nodeMainToken(arm);
                if (tree.tokenTag(kw + 1) == .colon) try w.f.gen_blocks.append(w.ag.arena, .{ .name = AstGen.identText(tree, kw + 2), .tok = kw + 2, .construct = w.construct });
                try w.items(full.list(tree, arm), true);
            },
            else => try w.item(arm, true), // else: a single item, a block of one
        }
    }
};

/// Runs every per-module rule on `node`.
pub fn module(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const m = full.moduleDecl(tree, node);
    var f: Facts = .{ .name = AstGen.identText(tree, m.name), .ansi = false };
    const a = ag.arena;
    for (m.params) |d| for (full.decl(tree, d).items) |p| try f.params.put(a, AstGen.identText(tree, tree.nodeMainToken(p)), {});
    for (m.ports) |p| try headerPort(ag, &f, p);
    var walk: Walk = .{ .ag = ag, .f = &f };
    try walk.items(m.items, false);
    // IEEE 1364-2005 §12.3.3: one declaration covers every reference to its
    // name (`(a, a)`, `(a[7:4], a[3:0])`), so the first port of a name answers.
    for (f.ports.items) |p| if (f.ports.items[f.port_index.get(p.name).?].dir == .none)
        try ag.report(.E0376, p.tok, "port `{s}` of module `{s}` is not declared `input`, `output` or `inout`", .{ p.name, f.name });
    try wreal(ag, &f);
    for (f.analog_functions.items) |fn_node| try formals(ag, fn_node);
    try generates(ag, &f);
    try paths.check(ag, &f);
}

// ---- private ----

/// A header port: an ANSI declaration's names, or each reference of a
/// non-ANSI port expression (a null port has none).
fn headerPort(ag: *AstGen, f: *Facts, p: Node.Index) Error!void {
    const tree = ag.tree;
    if (tree.nodeTag(p) == .port_decl) {
        f.ansi = true;
        const d = full.decl(tree, p);
        const words = decl.typeWords(tree, d.main_token);
        for (d.items) |x| {
            const t = tree.nodeMainToken(x);
            try addPort(ag, f, .{ .name = AstGen.identText(tree, t), .tok = t, .dir = direction(tree, d.main_token), .range = d.range, .wreal = words.net == .wreal });
            if (words.storage != .none) try f.vars.put(ag.arena, AstGen.identText(tree, t), {});
        }
        return;
    }
    const e = tree.nodeData(p).opt_node.unwrap() orelse return;
    const refs: []const Node.Index = if (tree.nodeTag(e) == .concat) full.list(tree, e) else (&e)[0..1];
    for (refs) |r| {
        const base = refBase(tree, r) orelse continue;
        const t = tree.nodeMainToken(base);
        try addPort(ag, f, .{ .name = AstGen.identText(tree, t), .tok = t });
    }
}

fn addPort(ag: *AstGen, f: *Facts, p: Port) Error!void {
    const gop = try f.port_index.getOrPut(ag.arena, p.name);
    if (!gop.found_existing) gop.value_ptr.* = f.ports.items.len;
    try f.ports.append(ag.arena, p);
}

/// The identifier a port reference or select names.
fn refBase(tree: *const Ast, r: Node.Index) ?Node.Index {
    return switch (tree.nodeTag(r)) {
        .identifier => r,
        .index => tree.nodeData(r).node_and_node[0],
        .range_select, .indexed_select_up, .indexed_select_down => tree.nodeData(r).node_and_extra[0],
        else => null, // else: no other shape names a port
    };
}

fn direction(tree: *const Ast, kw: Ast.TokenIndex) Vir.Inst.Direction {
    return switch (tree.tokenTag(kw)) {
        .keyword_input => .input,
        .keyword_output => .output,
        .keyword_inout => .inout,
        else => .none, // else: no direction keyword
    };
}

fn name(tree: *const Ast, n: Node.Index) []const u8 {
    return AstGen.identText(tree, tree.nodeMainToken(n));
}

/// The A.3.1 gates whose first terminal drives (the old parser's `gates`).
fn gateDriver(tag: @import("../tokenizer.zig").Token.Tag) bool {
    return switch (tag) {
        .keyword_and, .keyword_nand, .keyword_or, .keyword_nor, .keyword_xor, .keyword_xnor, .keyword_buf, .keyword_not, .keyword_bufif0, .keyword_bufif1, .keyword_notif0, .keyword_notif1 => true,
        else => false,
    };
}

/// §3.7 E0918: a wreal net driven twice in its module, its declaration's
/// `=` counting as a driver; reported at the second.
fn wreal(ag: *AstGen, f: *const Facts) Error!void {
    for (f.wreal_nets.items) |n| try drivers(ag, f, n.name, n.init);
    for (f.ports.items, 0..) |p, i| if (p.wreal and f.port_index.get(p.name).? == i) try drivers(ag, f, p.name, false);
}

fn drivers(ag: *AstGen, f: *const Facts, n: []const u8, declared: bool) Error!void {
    const tree = ag.tree;
    var count: u32 = @intFromBool(declared);
    for (f.assigns.items) |target| {
        if (tree.nodeTag(target) != .identifier or !std.mem.eql(u8, name(tree, target), n)) continue;
        count += 1;
        if (count == 2) try ag.report(.E0918, tree.nodeMainToken(target), "`{s}` is already driven", .{n});
    }
}

/// §4.7.1 E0225: "all formal arguments shall have an associated block item
/// declaration specifying the data type"; `output integer|time` types one.
fn formals(ag: *AstGen, node: Node.Index) Error!void {
    const tree = ag.tree;
    const f = full.function(tree, node);
    const a = ag.arena;
    var typed: Names = .empty;
    var order: std.ArrayList(Ast.TokenIndex) = .empty;
    var seen: Names = .empty;
    for ([_][]const Node.Index{ f.ports, f.items }) |list| for (list) |it| switch (tree.nodeTag(it)) {
        .port_decl => {
            const d = full.decl(tree, it);
            const has_type = decl.typeWords(tree, d.main_token).storage != .none;
            for (d.items) |x| {
                if (!(try seen.getOrPut(a, name(tree, x))).found_existing) try order.append(a, tree.nodeMainToken(x));
                if (has_type) try typed.put(a, name(tree, x), {});
            }
        },
        .declarator => if (!(try seen.getOrPut(a, name(tree, it))).found_existing) try order.append(a, tree.nodeMainToken(it)),
        .var_decl => for (full.decl(tree, it).items) |x| try typed.put(a, name(tree, x), {}),
        else => {}, // else: parameters and statements type no formal
    };
    const fname = AstGen.identText(tree, stmt.functionName(tree, node));
    for (order.items) |t| if (!typed.contains(AstGen.identText(tree, t)))
        try ag.report(.E0225, t, "formal `{s}` of `{s}` has no data type declaration", .{ AstGen.identText(tree, t), fname });
}

/// A.4.2 E0238 and §6.6.2 E0230 over the module's hoisted names: a block
/// name clashes with any declaration of the module's name space, a named
/// `initial`/`always` block, a task, or a block of another construct (two
/// arms of one construct may share a name).
fn generates(ag: *AstGen, f: *const Facts) Error!void {
    for (f.gen_loops.items) |l| if (!f.genvars.contains(l.name)) try ag.report(.E0238, l.tok, "`{s}`", .{l.name});
    for (f.gen_blocks.items, 0..) |g, i| {
        const n = g.name;
        const clash = f.aliasparams.contains(n) or f.port_index.contains(n) or f.params.contains(n) or f.vars.contains(n) or
            f.nets.contains(n) or f.branches.contains(n) or f.functions.contains(n) or f.genvars.contains(n) or
            f.process_blocks.contains(n) or f.tasks.contains(n) or for (f.gen_blocks.items[0..i]) |h|
        {
            if (std.mem.eql(u8, h.name, n) and h.construct != g.construct) break true;
        } else false;
        if (clash) try ag.report(.E0230, g.tok, "`{s}`", .{n});
    }
}
