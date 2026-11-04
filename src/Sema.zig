//! Elaboration, the cross-unit half of Zig's Sema for Verilog-AMS: every
//! file's `Vir` in a `Zcu` and a `Config` in; the `Zcu`'s namespace,
//! instance tree, defparams and failures out. One elaborator for analog
//! and digital designs. Nothing is cloned: an instance is a key (module,
//! folded parameters) and its module's Vir is re-read under that key, as
//! Zig instantiates a generic function (InternPool `GetFuncInstanceKey`).
//! The spine, one pass over a table each: the namespace (`namespace`),
//! the roots (`pickRoots`), the instance walk (`walk.zig`: overrides,
//! defparams, generate schemes, instance arrays, ports), then Annex F and
//! connect-module insertion over the finished table (`connect.zig`).
//! Cites: VAMS-2023 §6.2.2, §6.3, §6.4, §6.6, §7.6; IEEE 1364-2005 §12.1.1,
//! §12.8.1, §13.2.1.1.
//!
//! Contents:
//! - `pub const Config = struct` (`Roots`, `Override`)
//! - `pub fn elaborate(zcu: *Zcu, config: Config) Allocator.Error!void`
//! - `pub const Analysis = struct` (`deinit`)
//! - lowering's types: `pub const Ty`, `pub const Value`, `pub const Slot`, `pub const Bind`, `pub const Unit`, `pub const ContribKey`, `pub const Block` (`Loop`, `Label`, `restricted`, `child`)
//! - `pub fn analyze(zcu: *Zcu) Allocator.Error!?Analysis`
//! - `pub fn addInst(s: *Sema, b: *Block, inst: Air.Inst) Allocator.Error!Air.Inst.Ref`
//! - `pub fn fail(s: *Sema, code: Diag.Code, file: Zcu.File.Index, src: Vir.Inst.Ref, comptime fmt: []const u8, args: anytype) Allocator.Error!void`
//! - `pub fn bound(s: *Sema, cell: InternPool.String, path: []const u8) InternPool.String`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Air = @import("air");
const Zcu = @import("Zcu.zig");
const walk = @import("Sema/walk.zig");
const paramset = @import("Sema/paramset.zig");
const checks = @import("Sema/checks.zig");
const connect = @import("Sema/connect.zig");
const defparam = @import("Sema/defparam.zig");
const lower_decl = @import("Sema/decl.zig");
const Vir = vams.Vir;
const Diag = vams.Diag;
const Inst = Vir.Inst;

zcu: *Zcu,
gpa: Allocator,
/// Scratch that lives for one `elaborate`.
arena: Allocator,
config: Config,
/// IEEE 1364-2005 §13.3.1.6 the root configuration's `use` clauses:
/// instance paths and cell names to the cell each binds instead.
uses: std.StringHashMapUnmanaged(InternPool.String) = .empty,

// ---- analog lowering (`analyze`): each table's one writer is a file under `Sema/` ----
/// The body being written.
air: Air.Builder = .{},
/// The device tables beside it.
device: Air.Device = .{},
/// The main body's slots, placed ahead of its statements so every body
/// below may read them (decl.zig).
prologue: std.ArrayList(Air.Inst.Index) = .empty,
/// One per instance lowered, in `zcu.instances` order (decl.zig).
units: std.ArrayList(Unit) = .empty,
/// A net's flat name to its `device.nodes` row (decl.zig).
node_rows: std.AutoHashMapUnmanaged(InternPool.String, Air.Device.Node.Index) = .empty,
/// §5.4.2 a node pair to its flow unknown (contrib.zig).
flow_rows: std.AutoHashMapUnmanaged([2]Air.Device.Node.Index, Air.Device.Node.Index) = .empty,
/// §5.4.3 a port's row to its port flow unknown (contrib.zig).
port_rows: std.AutoHashMapUnmanaged(Air.Device.Node.Index, Air.Device.Node.Index) = .empty,
/// §5.6 a contribution target to its row (contrib.zig).
contrib_rows: std.AutoHashMapUnmanaged(ContribKey, Air.Device.Contribution.Index) = .empty,
/// Each `device.params` row's `arg` in the prologue, by row (decl.zig).
param_args: std.ArrayList(Value) = .empty,
/// How deep the expression being lowered nests (expr.zig).
expr_depth: u32 = 0,
/// Each node row's one `probe`, in the prologue (contrib.zig).
probes: std.AutoHashMapUnmanaged(Air.Device.Node.Index, Air.Inst.Ref) = .empty,
/// §3.6.2 every access function name and the quantity it reads under a
/// discipline that binds it; each discipline's two names (contrib.zig).
access_kind: std.StringHashMapUnmanaged(Air.Device.Access) = .empty,
disc_access: std.StringHashMapUnmanaged([2][]const u8) = .empty,
disciplines_loaded: bool = false,
/// Access names more than one discipline binds, to different quantities.
access_both: std.StringHashMapUnmanaged(void) = .empty,
/// §9.4.1 the unconditional prints, minted at the end (syscall.zig).
deferred: std.ArrayList(@import("Sema/syscall.zig").Deferred) = .empty,
/// The target of the `<+` whose right-hand side is being lowered (contrib.zig).
contrib_target: ?@import("Sema/contrib.zig").Target = null,
/// §4.5.2 operator unknowns minted so far, the `<k>` of `ddt$<k>` (op.zig).
op_states: u32 = 0,
/// The slots whose last assignment so far is a static value, and the
/// `load`s of them (op.zig's `isStatic`).
static_slots: std.AutoHashMapUnmanaged(Air.Inst.Index, void) = .empty,
static_loads: std.AutoHashMapUnmanaged(Air.Inst.Index, void) = .empty,
/// Assignments run at the main body's entry, after the prologue (op.zig).
entry: std.ArrayList(Air.Inst.Index) = .empty,
/// §5.3.2 every named block's local, by its flat name (`u1.blk.x`), for a
/// hierarchical read (control.zig).
block_locals: std.StringHashMapUnmanaged(Slot) = .empty,
/// The slot ordering §9.21 array-source snapshots (table.zig).
table_effect: ?Air.Inst.Index = null,
/// Each `device.limit_slots` row's `limit$old` seed, by row (kernel.zig).
limit_seeds: std.ArrayList(Air.Inst.Ref) = .empty,
/// The user functions being inlined, outermost first (func.zig).
inlining: std.ArrayList(Inst.Index) = .empty,
/// The contribution rows a reactive term was added to (contrib.zig).
react_written: std.AutoHashMapUnmanaged(Air.Device.Contribution.Index, void) = .empty,

/// What elaboration reads besides the files.
pub const Config = struct {
    roots: Roots = .all,
    /// §6.3 `--param name=value`: values for the roots' parameters.
    overrides: []const Override = &.{},

    /// Which uninstantiated modules elaborate. A device has one root
    /// (VAMS §6.2.2: the first such module); a simulation has every one
    /// (IEEE 1364-2005 §12.1.1).
    pub const Roots = enum { first, all };
    /// A root parameter's value given on the command line.
    pub const Override = struct { name: []const u8, value: InternPool.Index };
};

/// One analysed analog design: its body and its device tables. The caller
/// frees both with `deinit`.
pub const Analysis = struct {
    air: Air,
    device: Air.Device,

    pub fn deinit(a: *Analysis, gpa: Allocator) void {
        a.air.deinit(gpa);
        a.device.deinit(gpa);
        a.* = undefined;
    }
};

/// A §3.2 value type as lowering tracks it (the `Air` operand types plus
/// §2.7 strings, which only system tasks read).
pub const Ty = enum(u8) { real, integer, string };

/// A lowered expression: its operand and its type.
pub const Value = struct {
    ref: Air.Inst.Ref,
    ty: Ty,
};

/// A variable's slot: its `alloc` and its type.
pub const Slot = struct { alloc: Air.Inst.Index, ty: Ty };

/// What a declaration of an analysed module stands for in one instance.
pub const Bind = union(enum) {
    /// A scalar net or port: its node row (or `ground`).
    node: Air.Device.Node.Index,
    /// A §3.6.3 vector net: `len` rows from `first` in `Unit.vec_rows`,
    /// declaration order (msb first).
    vector: struct { first: u32, len: u32, msb: i64, lsb: i64 },
    /// A §3.4 parameter: its card row.
    param: Air.Device.Param.Index,
    /// A §3.2 variable.
    slot: Slot,
    /// A §3.12 named branch.
    branch: Air.Device.Branch.Index,
    /// A §3.12.1 port branch (`branch (<p>) pb;`): its port's node.
    port: Air.Device.Node.Index,
    /// A §6.6.1 genvar's current value, or another name with one constant.
    constant: InternPool.Index,
    /// A §3.2.2 array: one slot per element, row-major (the last
    /// subscript fastest), and each dimension's `[msb, lsb]`.
    array: struct { slots: []const Air.Inst.Index, dims: []const [2]i64, ty: Ty },
};

/// One instance being lowered: its module's file and Vir, the flat-name
/// prefix the old flattener gave its declarations (`u1.`), and what each
/// of its declarations binds to.
pub const Unit = struct {
    instance: Zcu.Instance.Index,
    file: Zcu.File.Index,
    vir: *const Vir,
    module: Inst.Module,
    /// "" for the root; else the instance path below it and a `.`.
    prefix: []const u8,
    /// Keyed by a declaration's first instruction (its `prev` chain's root).
    binds: std.AutoHashMapUnmanaged(Inst.Index, Bind) = .empty,
    /// The rows of every vector net (`Bind.vector`).
    vec_rows: std.ArrayList(Air.Device.Node.Index) = .empty,
    /// §5.10 the held variables, by declaration (held.zig).
    held: std.AutoHashMapUnmanaged(Inst.Index, @import("Sema/held.zig").Why) = .empty,
    /// §7.3.1 the digital-owned values the analog blocks read, each a card
    /// row (discrete.zig).
    discrete: std.ArrayList(Inst.Index) = .empty,
    /// Its analog blocks are lowered (decl.zig).
    lowered: bool = false,
    /// The variables whose value an `analog initial` or `@(...)` body
    /// leaves for a later evaluation's read (held.zig).
    carried: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty,
};

/// §5.6 what makes two contributions one row.
pub const ContribKey = struct {
    access: Air.Device.Access,
    branch: Air.Device.Branch.Index,
    hi: Air.Device.Node.Index,
    lo: Air.Device.Node.Index,
};

/// The context one body is lowered in (Zig's `Sema.Block`): the
/// instructions it collects, the instance it reads, and what the statements
/// around it restrict. A child is made for each nested body and dropped
/// when it closes, so nothing is restored by hand.
pub const Block = struct {
    parent: ?*Block,
    unit: *Unit,
    /// The body's instructions, in order.
    insts: std.ArrayList(Air.Inst.Index) = .empty,
    /// The innermost `loop` around this body (control.zig).
    loop: ?Loop = null,
    /// How many runtime conditions enclose this body (§5.8.1).
    conditional: u32 = 0,
    /// How many of them change during the analysis (not static, §5.8.1).
    runtime: u32 = 0,
    /// Inside an `analog initial` block (§5.2.1).
    analog_initial: bool = false,
    /// A `break` or `continue` ended the body: nothing more is appended.
    dead: bool = false,
    /// Inside an `@(...)` body (§5.10).
    in_event: bool = false,
    /// The enclosing named blocks' names, each with a `.` (§5.3.2).
    path: []const u8 = "",
    /// Inside an inlined function: the `block` a `return` leaves (func.zig).
    function: ?Air.Inst.Index = null,
    /// The innermost enclosing named block (control.zig).
    label: ?*const Label = null,

    /// A loop's targets: the `block` a `break` leaves and the one a
    /// `continue` leaves (the step follows it).
    pub const Loop = struct { exit: Air.Inst.Index, cont: Air.Inst.Index };
    /// A §5.3.2 named block: its name, the `block` a `disable` leaves, and
    /// whether one does.
    pub const Label = struct { name: []const u8, exit: Air.Inst.Index, up: ?*const Label, disabled: *bool };

    /// The context §4.7.1 and §5.2.1 restrict (an analog function, an
    /// analog initial block), or null.
    pub fn restricted(b: *const Block) ?[]const u8 {
        if (b.function != null) return "an analog function";
        if (b.analog_initial) return "an analog initial block";
        return null;
    }

    /// A child of `parent`: the same instance and restrictions, no instructions.
    pub fn child(parent: *Block) Block {
        return .{ .parent = parent, .unit = parent.unit, .loop = parent.loop, .conditional = parent.conditional, .runtime = parent.runtime, .analog_initial = parent.analog_initial, .in_event = parent.in_event, .path = parent.path, .function = parent.function, .label = parent.label };
    }
};

const Sema = @This();

/// Elaborates every file of `zcu` into its namespace and instance tree.
/// Diagnostics go to `zcu.failed`; only running out of memory fails.
/// Asserts that nothing was elaborated before.
pub fn elaborate(zcu: *Zcu, config: Config) Allocator.Error!void {
    assert(zcu.instances.len == 0);
    assert(zcu.modules.count() == 0);
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var s: Sema = .{ .zcu = zcu, .gpa = zcu.gpa, .arena = arena_state.allocator(), .config = config };
    try namespace(&s);
    try checks.run(&s);
    const roots = try pickRoots(&s);
    const waiting = try walk.run(&s, roots);
    try connect.run(&s, waiting);
    try defparam.reportUnused(&s, waiting);
    assert(zcu.instances.len >= roots.len);
}

/// Lowers the elaborated design under `zcu.instances[0]` (its first root
/// and every instance below it) into one `Air` body and its device tables
/// (docs/rewrite/lower.md). Diagnostics go to `zcu.failed`; null when one
/// of them is an error, or when the design reads a data file not answered
/// yet: `zcu.data_want` names it, and after `zcu.answerData` this runs
/// again (each pass from the start, its diagnostics dropped). Asserts that
/// `zcu` was elaborated and no request is pending.
pub fn analyze(zcu: *Zcu) Allocator.Error!?Analysis {
    assert(zcu.instances.len != 0);
    assert(zcu.data_want == null);
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var s: Sema = .{ .zcu = zcu, .gpa = zcu.gpa, .arena = arena_state.allocator(), .config = .{}, .air = try Air.Builder.init(zcu.gpa) };
    defer s.air.deinit(zcu.gpa);
    errdefer s.device.deinit(zcu.gpa);
    const failed_before = zcu.failed.len;
    const main = try lower_decl.run(&s);
    if (zcu.data_want != null) {
        zcu.failed.shrinkRetainingCapacity(failed_before);
        s.device.deinit(zcu.gpa);
        return null;
    }
    for (zcu.failed.items(.code)[failed_before..]) |c| if (@tagName(c)[0] == 'E') {
        s.device.deinit(zcu.gpa);
        return null;
    };
    const air = try s.air.finish(zcu.gpa, main);
    assert(air.mainBody().len == main.len);
    return .{ .air = air, .device = s.device };
}

/// Appends `inst` to `b`'s body and returns it as an operand.
pub fn addInst(s: *Sema, b: *Block, inst: Air.Inst) Allocator.Error!Air.Inst.Ref {
    const i = try s.air.addInst(s.gpa, inst);
    try b.insts.append(s.arena, i);
    assert(b.insts.items[b.insts.items.len - 1] == i);
    return .fromIndex(i);
}

/// Appends a diagnostic to `zcu.failed`.
pub fn fail(s: *Sema, code: Diag.Code, file: Zcu.File.Index, src: Inst.Ref, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    assert(@backingInt(file) < s.zcu.files.len);
    const text = try std.fmt.allocPrint(s.arena, fmt, args);
    const message = try s.zcu.intern_pool.getString(s.gpa, text);
    const before = s.zcu.failed.len;
    try s.zcu.failed.append(s.gpa, .{ .code = code, .file = file, .src = src, .message = message });
    assert(s.zcu.failed.len == before + 1);
}

/// The cell an instance of `cell` at absolute path `path` binds under the
/// root configuration (§13.3.1.6: an `instance` clause first, then a
/// `cell` clause), else `cell`.
pub fn bound(s: *Sema, cell: InternPool.String, path: []const u8) InternPool.String {
    assert(cell != .empty);
    assert(path.len != 0);
    if (s.uses.count() == 0) return cell;
    if (s.uses.get(path)) |c| return c;
    return s.uses.get(s.zcu.intern_pool.stringToSlice(cell)) orelse cell;
}

// ---- private ----

/// IEEE 1364-2005 §13.3.1.1: the root configuration (the one no other
/// names in a `use ...:config` clause) names the top-level cells in its
/// `design` statement (`lib.cell` or `cell`); appends them to `roots` and
/// records its `instance`/`cell ... use` clauses in `s.uses`. Returns
/// whether the design has a configuration naming any cell.
/// ponytail: one level of configuration (a `:config` use binds that
/// configuration's first design cell, not its rules); `liblist` clauses and
/// the library map (§13.2) bind nothing.
fn configRoots(s: *Sema, roots: *std.ArrayList(Zcu.Decl)) Allocator.Error!bool {
    assert(roots.items.len == 0);
    const zcu = s.zcu;
    var configs: std.ArrayList(struct { vir: *const Vir, c: Inst.Config }) = .empty;
    for (0..zcu.files.len) |f| {
        const vir = zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.decls()) |d| if (d.kind == .config)
            try configs.append(s.arena, .{ .vir = vir, .c = vir.extraData(Inst.Config, vir.instructions.items(.data)[@backingInt(d.inst)].pl_node.payload_index) });
    }
    const root = for (configs.items) |cfg| {
        const name = cfg.vir.string(cfg.c.name);
        const named = named: {
            for (configs.items) |other| for (other.vir.list(Vir.String, other.c.rules)) |r| {
                const w = try ruleWords(s, other.vir.string(r));
                if (w.len == 4 and std.mem.eql(u8, w[2], "use") and std.mem.endsWith(u8, w[3], ":config") and std.mem.eql(u8, cellOf(w[3]), name)) break :named true;
            };
            break :named false;
        };
        if (!named) break cfg;
    } else return false;
    for (root.vir.list(Vir.String, root.c.design)) |cell| {
        const m = zcu.modules.get(try zcu.intern_pool.getString(s.gpa, cellOf(root.vir.string(cell)))) orelse continue;
        try roots.append(s.arena, m);
    }
    for (root.vir.list(Vir.String, root.c.rules)) |r| {
        const w = try ruleWords(s, root.vir.string(r));
        if (w.len != 4 or !std.mem.eql(u8, w[2], "use")) continue;
        if (!std.mem.eql(u8, w[0], "instance") and !std.mem.eql(u8, w[0], "cell")) continue;
        var target = cellOf(w[3]);
        if (std.mem.endsWith(u8, w[3], ":config")) for (configs.items) |cfg| {
            if (!std.mem.eql(u8, cfg.vir.string(cfg.c.name), target)) continue;
            const design = cfg.vir.list(Vir.String, cfg.c.design);
            if (design.len != 0) target = cellOf(cfg.vir.string(design[0]));
        };
        const key = if (std.mem.eql(u8, w[0], "cell")) cellOf(w[1]) else w[1];
        try s.uses.put(s.arena, key, try zcu.intern_pool.getString(s.gpa, target));
    }
    return roots.items.len != 0;
}

/// A rule's words: its tokens (AstGen joins them with spaces) with `.` and
/// `:` glued to their neighbours, so `top . u use work . gate` is `top.u`,
/// `use`, `work.gate`.
fn ruleWords(s: *Sema, text: []const u8) Allocator.Error![]const []const u8 {
    assert(text.len != 0);
    var words: std.ArrayList([]const u8) = .empty;
    var glue = false;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |t| {
        const sticky = std.mem.eql(u8, t, ".") or std.mem.eql(u8, t, ":");
        if ((sticky or glue) and words.items.len != 0) {
            words.items[words.items.len - 1] = try std.mem.concat(s.arena, u8, &.{ words.items[words.items.len - 1], t });
        } else try words.append(s.arena, t);
        glue = sticky;
    }
    return words.items;
}

/// `lib.cell[:config]`'s cell.
fn cellOf(text: []const u8) []const u8 {
    assert(text.len != 0);
    defer assert(text.len != 0);
    const end = std.mem.findScalar(u8, text, ':') orelse text.len;
    const dot = std.mem.findScalarLast(u8, text[0..end], '.');
    return if (dot) |d| text[d + 1 .. end] else text[0..end];
}

/// Fills `modules` (the last unit of each name wins, IEEE 1364-2005
/// §13.2.1.1; W1152 for a user module defined again), `paramsets` (all, in
/// order), `disciplines` and `natures`, in file then source order.
fn namespace(s: *Sema) Allocator.Error!void {
    assert(s.zcu.modules.count() == 0);
    const zcu = s.zcu;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| {
            const decl: Zcu.Decl = .{ .file = file, .index = @fromBackingInt(@intCast(k)) };
            switch (d.kind) {
                .module, .macromodule, .connectmodule, .primitive => {
                    const name = try zcu.intern_pool.getString(s.gpa, vir.string(d.name));
                    const gop = try zcu.modules.getOrPut(s.gpa, name);
                    if (gop.found_existing and !zcu.isBuiltin(gop.value_ptr.*) and !zcu.isBuiltin(decl))
                        try s.fail(.W1152, file, d.inst.toRef(), "`{s}` is defined again; this later definition is the module", .{vir.string(d.name)});
                    gop.value_ptr.* = decl;
                },
                .paramset => try zcu.paramsets.append(s.gpa, decl),
                .discipline => try zcu.disciplines.put(s.gpa, try zcu.intern_pool.getString(s.gpa, vir.string(d.name)), decl),
                .nature => try zcu.natures.put(s.gpa, try zcu.intern_pool.getString(s.gpa, vir.string(d.name)), decl),
                .connectrules, .config => {},
            }
        }
    }
}

/// §6.2.2/IEEE 1364-2005 §12.1.1 the roots: each user module that no
/// instance names (an instance of a paramset names its chain's module), in
/// file then source order, the last of its name. Under `.first`, only the
/// first, or when every module is instantiated the first module, so E0905
/// names the cycle. A connect module is placed by §7.6 insertion, never a
/// root.
fn pickRoots(s: *Sema) Allocator.Error![]const Zcu.Decl {
    assert(s.zcu.instances.len == 0);
    const zcu = s.zcu;
    var named: std.AutoHashMapUnmanaged(InternPool.String, void) = .empty;
    for (0..zcu.files.len) |f| {
        const vir = zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.instructions.items(.tag), vir.instructions.items(.data)) |tag, data| {
            if (tag != .instance) continue;
            const inst = vir.extraData(Inst.Instance, data.pl_node.payload_index);
            const target = try zcu.intern_pool.getString(s.gpa, vir.string(inst.target));
            try named.put(s.arena, target, {});
            try paramset.chainEnds(s, target, &named);
        }
    }
    var roots: std.ArrayList(Zcu.Decl) = .empty;
    if (s.config.roots == .all) if (try configRoots(s, &roots)) return roots.items;
    var first: ?Zcu.Decl = null;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| {
            if (d.kind != .module and d.kind != .macromodule) continue;
            if (zcu.isBuiltin(.{ .file = file, .index = @fromBackingInt(@intCast(k)) })) continue;
            const name = try zcu.intern_pool.getString(s.gpa, vir.string(d.name));
            const last = zcu.modules.get(name).?;
            if (first == null) first = last;
            if (named.contains(name)) continue;
            const seen = for (roots.items) |r| {
                if (std.meta.eql(r, last)) break true;
            } else false;
            if (!seen) try roots.append(s.arena, last);
        }
    }
    if (roots.items.len == 0 and s.config.roots == .first) if (first) |m| try roots.append(s.arena, m);
    if (s.config.roots == .first and roots.items.len > 1) roots.shrinkRetainingCapacity(1);
    return roots.items;
}
