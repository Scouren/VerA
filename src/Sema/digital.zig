//! The digital half of Sema (docs/rewrite/dlower.md): an elaborated IEEE
//! 1364 design (`Zcu.instances`, `Config.roots = .all`) in, one
//! `std_sim.Program` out. Every process, continuous assignment, task and
//! function is lowered from Vir through `std_sim.Builder`: slots laid out
//! once per instance (`digital/decl.zig`), expressions typed by one §5.4/§5.5
//! sizer and bound to slots once (`digital/expr.zig`), statements to
//! instructions (`digital/stmt.zig`), §17 tasks with their formats parsed
//! once (`digital/task.zig`). The spine, one pass each: time scales, the
//! instance walk (scopes, names, slots, the processes each scope holds),
//! the drivers, the subroutine bodies, the processes in §11.4 order.
//! Constants fold through `Sema/eval.zig`, the one comptime evaluator.
//! Cites: IEEE 1364-2005 §9.9, §11.4, §12.4, §12.5, §19.8.
//!
//! Contents:
//! - `pub const Source = struct`, `pub const Options = struct`, `pub const Lowered = struct`
//! - `pub const Error`, `pub const Type = struct` (`real_type`), `pub const Name = struct` (`Kind`), `pub const Span = struct`
//! - `pub const Frame = struct` (`Genvar`), `pub const Proc = struct` (`Kind`), `pub const ScopeInfo = struct`
//! - `pub const Lower = struct` (`Implicit`, `Site`, `refuse`, `refuseFmt`, `lookup`, `bind`, `rootFrame`, `virOf`, `fileOf`, `envAt`, `constOf`, `intOf`, `tyOf`, `payload`, `tag`, `srcOffset`)
//! - `pub const none: u32`
//! - `pub fn lower(arena: Allocator, zcu: *Zcu, options: Options, why: *[]const u8) Error!Lowered`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const std_sim = @import("std_sim");
const InternPool = @import("intern_pool");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const decl = @import("digital/decl.zig");
const stmt = @import("digital/stmt.zig");
const nets = @import("digital/nets.zig");
const sub = @import("digital/sub.zig");
const gates = @import("digital/gates.zig");
const Program = std_sim.Program;
const Builder = std_sim.Builder;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// Where one `Zcu` file came from: its tree (token offsets) and the
/// preprocessor's output (source locations of `$finish` and timing checks).
pub const Source = struct {
    tree: *const vams.Ast,
    pp: *const vams.Preprocessor.Output,
};

/// What lowering reads besides the `Zcu`.
pub const Options = struct {
    /// One per `Zcu` file, in file order.
    sources: []const Source,
};

/// The program, and per timing check (`Program.checks` order) the byte of
/// the preprocessed text its W1199 report is filed at.
pub const Lowered = struct {
    program: Program,
    check_sites: []const u32 = &.{},
};

/// `Unsupported`: a construct the lowering does not express yet, named in
/// `Lower.why`.
pub const Error = error{Unsupported} || Allocator.Error;

/// The `none` of every u32 handle a `Program` row holds.
pub const none: u32 = std.math.maxInt(u32);

/// A §5.5 type: an integral width and signedness, or §4.8's `real`. A width
/// of 0 is §5.1.14's zero replication, legal only inside a concatenation.
pub const Type = struct {
    width: u32,
    signed: bool,
    real: bool = false,

    /// §4.8 `real`.
    pub const real_type: Type = .{ .width = 64, .signed = true, .real = true };
};

/// One unpacked dimension's declared bounds, low <= high.
pub const Span = struct { low: i64, high: i64 };

/// What a declaration is bound to in one frame: a slot (a variable, net,
/// parameter, genvar or named event, with its type, vector range and
/// unpacked dimensions), a subroutine (`slot` its `Program.subs` row) or a
/// scope (`slot` its `Program.scopes` row: a named block, a generate block,
/// an instance).
pub const Name = struct {
    kind: Kind,
    slot: u32 = 0,
    ty: Type = .{ .width = 1, .signed = false },
    /// The declared `[msb:lsb]`; `width - 1 : 0` without one.
    msb: i64 = 0,
    lsb: i64 = 0,
    /// §4.3: declared without a range, so no bit of it can be selected.
    scalar: bool = false,
    /// Unpacked dimensions, outermost first; empty for no array.
    dims: []const Span = &.{},
    /// Elements: the product of `dims`' sizes (1 for no array).
    count: u32 = 1,
    /// The `Program.nets` row, or `none` for a variable.
    net: u32 = none,

    pub const Kind = enum(u8) { variable, net, param, genvar, event, sub, scope };
};

/// A binding frame: an instance's names, or a generate block's (an
/// iteration of a loop scheme each), or a subroutine's or named block's,
/// above `parent`. Lookups climb `parent` to the instance frame.
pub const Frame = struct {
    parent: u32,
    /// The instance whose module's Vir the frame's instructions are in.
    instance: Zcu.Instance.Index,
    /// The `Program.scopes` row the frame's code runs in.
    scope: u32,
    names: std.AutoHashMapUnmanaged(Inst.Index, u32) = .empty,
    /// §12.4 the genvars bound at this frame (an iteration's own and its
    /// enclosing ones), for constants folded later.
    genvars: []const Genvar = &.{},
    /// An automatic subroutine's frame, or a named block's inside one.
    automatic: bool = false,

    pub const Genvar = struct { decl: Inst.Index, value: i64 };
};

/// One process to compile: an `initial`/`always` body, or a §6.2.1
/// variable declaration assignment, in frame `frame`.
pub const Proc = struct {
    kind: Kind,
    /// The process instruction, or the `variable` whose `init` it runs.
    inst: Inst.Index,
    frame: u32,

    pub const Kind = enum(u8) { initial, always, init_var };
};

/// A `Program.scopes` row's lowering-side facts: the module whose Vir its
/// code reads, where it was declared (for §9.9's queue order), its
/// processes and its children.
pub const ScopeInfo = struct {
    /// The source offset of the construct that opened it (siblings are
    /// ordered by it).
    at: u32,
    /// The scope's own processes, in source order.
    procs: std.ArrayList(Proc) = .empty,
    /// An instance or generate block (queued, §9.9); not a named block,
    /// task or function.
    queued: bool,
};

/// The lowering's state: the `Zcu` it reads, the builder it writes, and the
/// tables that bind names (frames) and order processes (scopes).
pub const Lower = struct {
    zcu: *Zcu,
    a: Allocator,
    b: *Builder,
    options: Options,
    why: []const u8 = "",
    names: std.ArrayList(Name) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    scopes: std.ArrayList(ScopeInfo) = .empty,
    /// Per instance, its frame, and where its parent instantiates it
    /// (`site.frame` `none` for a root).
    instance_frame: []u32 = &.{},
    sites: []Site = &.{},
    /// Per instance, its `eval.Env` (its module's parameters as folded).
    envs: []eval.Env = &.{},
    /// The roots' scopes, in order.
    roots: std.ArrayList(u32) = .empty,
    /// Per `times` row, the module time it was given from.
    module_times: std.AutoHashMapUnmanaged(Zcu.Decl, Program.Time) = .empty,
    /// The frame and scope code is compiled in now.
    frame: u32 = 0,
    /// Repeat and fork-join counters handed out so far.
    repeats: u32 = 0,
    joins: u32 = 0,
    /// §8.5.3.3 the hold cells handed out so far, one per intra-assignment
    /// timing control.
    holds: u32 = 0,
    /// The nets, their drivers (compiled after the walk), per slot its
    /// net, and each driver's `.continuous` pc.
    nets: std.ArrayList(nets.NetRow) = .empty,
    wires: std.ArrayList(nets.Wire) = .empty,
    slot_net: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    driver_pcs: std.ArrayList(u32) = .empty,
    /// §7.6 the pass switches.
    trans: std.ArrayList(gates.TranRow) = .empty,
    /// §8 the UDP tables (`Program.udps`), one per primitive instantiated.
    udps: std.ArrayList([]const std_sim.net.UdpRow) = .empty,
    udp_tables: std.AutoHashMapUnmanaged(Zcu.Decl, u32) = .empty,
    /// §10 the tasks and functions, in declaration order (`Program.subs`).
    subs: std.ArrayList(sub.Row) = .empty,
    /// §4.5 the implicit nets, by their instance frame and name.
    implicit: std.AutoHashMapUnmanaged(Implicit, u32) = .empty,

    /// A child instance's `instance` instruction and the parent frame it is in.
    pub const Site = struct { frame: u32, inst: Inst.Index };

    /// An implicit net's key: the instance frame it is declared in and its
    /// name (a `Vir.String` of that instance's file).
    pub const Implicit = struct { frame: u32, name: Vir.String };

    /// Records `why` and fails.
    pub fn refuse(l: *Lower, comptime why: []const u8) error{Unsupported} {
        l.why = why;
        return error.Unsupported;
    }

    /// `refuse` with a formatted reason.
    pub fn refuseFmt(l: *Lower, comptime f: []const u8, args: anytype) Error {
        l.why = try std.fmt.allocPrint(l.a, f, args);
        return error.Unsupported;
    }

    /// The `names` row declaration `d` is bound to from frame `from`, or
    /// null when no enclosing frame binds it.
    pub fn lookup(l: *const Lower, from: u32, d: Inst.Index) ?u32 {
        var f = from;
        var steps: u32 = 0;
        while (f != none) : (f = l.frames.items[f].parent) {
            steps += 1;
            assert(steps <= l.frames.items.len);
            if (l.frames.items[f].names.get(d)) |n| return n;
        }
        return null;
    }

    /// Binds declaration `d` to a new `names` row in frame `f`.
    pub fn bind(l: *Lower, f: u32, d: Inst.Index, n: Name) Error!u32 {
        assert(f < l.frames.items.len);
        const at: u32 = @intCast(l.names.items.len);
        try l.names.append(l.a, n);
        try l.frames.items[f].names.put(l.a, d, at);
        return at;
    }

    /// The instance frame at the end of frame `f`'s chain.
    pub fn rootFrame(l: *const Lower, f: u32) u32 {
        var at = f;
        var steps: u32 = 0;
        while (l.frames.items[at].parent != none) : (at = l.frames.items[at].parent) {
            steps += 1;
            assert(steps <= l.frames.items.len);
        }
        return at;
    }

    /// The Vir of frame `f`'s instance.
    pub fn virOf(l: *const Lower, f: u32) *const Vir {
        const i = l.frames.items[f].instance;
        const d = l.zcu.instances.items(.module)[@backingInt(i)];
        return l.zcu.fileVir(d.file);
    }

    /// The file of frame `f`'s instance.
    pub fn fileOf(l: *const Lower, f: u32) Zcu.File.Index {
        return l.zcu.instances.items(.module)[@backingInt(l.frames.items[f].instance)].file;
    }

    /// The comptime evaluator of frame `f`'s instance, its genvars set to
    /// the frame's.
    pub fn envAt(l: *Lower, f: u32) Error!*eval.Env {
        const env = &l.envs[@backingInt(l.frames.items[f].instance)];
        env.genvars.clearRetainingCapacity();
        for (l.frames.items[f].genvars) |g| try env.genvars.put(env.gpa, g.decl, g.value);
        return env;
    }

    /// The folded value of `r` in frame `f`, or null when it has none at
    /// elaboration.
    pub fn constOf(l: *Lower, f: u32, r: Inst.Ref) Error!?eval.Const {
        const env = try l.envAt(f);
        return env.ref(r);
    }

    /// The folded integer `r` is in frame `f`, refused when it has none.
    pub fn intOf(l: *Lower, f: u32, r: Inst.Ref) Error!i64 {
        const c = (try l.constOf(f, r)) orelse return l.refuse("a constant expression Sema/eval.zig does not fold (an x/z bit, past 64 bits, a select or a call)");
        return switch (c) {
            .int => |v| v,
            .real => |v| if (std.math.isFinite(v)) @intFromFloat(@round(v)) else l.refuse("a non-finite real where an integer constant is required"),
            .str => l.refuse("a string where an integer constant is required"),
        };
    }

    /// A §5.5 type as a `Program.Ty`, refused past 2^30 bits.
    pub fn tyOf(l: *Lower, ty: Type) Error!Program.Ty {
        if (ty.real) return Program.Ty.real_ty;
        if (ty.width == 0 or ty.width > std.math.maxInt(u30)) return l.refuse("a width past 2^30 bits");
        return Program.Ty.int(ty.width, ty.signed);
    }

    /// The payload of `pl_node` instruction `i` of `vir`.
    pub fn payload(vir: *const Vir, comptime T: type, i: Inst.Index) T {
        assert(Inst.dataKind(vir.instructions.items(.tag)[@backingInt(i)]) == .pl_node);
        return vir.extraData(T, vir.instructions.items(.data)[@backingInt(i)].pl_node.payload_index);
    }

    /// The tag of instruction `i` of `vir`.
    pub fn tag(vir: *const Vir, i: Inst.Index) Inst.Tag {
        return vir.instructions.items(.tag)[@backingInt(i)];
    }

    /// The offset in the preprocessed text where instruction `i` (of the
    /// file of frame `f`) starts: its node's or token's first byte.
    pub fn srcOffset(l: *const Lower, f: u32, i: Inst.Index) u32 {
        const vir = l.virOf(f);
        const tree = l.options.sources[@backingInt(l.fileOf(f))].tree;
        const data = vir.instructions.items(.data)[@backingInt(i)];
        const tok: vams.Ast.TokenIndex = switch (Inst.dataKind(tag(vir, i))) {
            .pl_node => tree.nodeMainToken(data.pl_node.src_node),
            .un_node => tree.nodeMainToken(data.un_node.src_node),
            .decl_tok => data.decl_tok.src_tok,
            .str_tok => data.str_tok.src_tok,
            .int, .float, .str => return 0,
        };
        return tree.tokenStart(tok);
    }
};

/// Lowers every instance of `zcu` into one `Program` in `arena`. On
/// `Unsupported`, `why` names the construct. Asserts `zcu` is elaborated
/// (`Config.roots = .all`) and has one `Source` per file.
pub fn lower(arena: Allocator, zcu: *Zcu, options: Options, why: *[]const u8) Error!Lowered {
    assert(options.sources.len == zcu.files.len);
    var b: Builder = .init(arena);
    var l: Lower = .{ .zcu = zcu, .a = arena, .b = &b, .options = options };
    spine(&l) catch |e| {
        why.* = l.why;
        return e;
    };
    var program = b.finish();
    nets.finish(&l, &program) catch |e| {
        why.* = l.why;
        return e;
    };
    assert(program.inst_scope.len == program.insts.len);
    return .{ .program = program };
}

// ---- private ----

fn spine(l: *Lower) Error!void {
    if (l.zcu.instances.len == 0) return l.refuse("a design with no instance");
    // §17.2.1/§17.2.9 a relative data file is looked for beside the design.
    const pp = l.options.sources[0].pp;
    if (pp.files.len != 0) l.b.p.file_name = try l.b.string(pp.files[0].name);
    try timeScales(l);
    try decl.declare(l);
    try stmt.compileAll(l);
}

/// IEEE 1364-2005 §19.8: each module's `timescale (the last before it, or
/// none); some modules with one and some without is an error. The design's
/// tick is the finest precision of all of them, `s` when none is given.
fn timeScales(l: *Lower) Error!void {
    const zcu = l.zcu;
    var finest: i32 = 0;
    var set: u32 = 0;
    var total: u32 = 0;
    for (0..zcu.files.len) |f| {
        const vir = zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.decls()) |d| {
            if (d.kind != .module and d.kind != .macromodule and d.kind != .connectmodule) continue;
            const m = Lower.payload(vir, Inst.Module, d.inst);
            total += 1;
            if (!m.stamp.flags.has_timescale) continue;
            set += 1;
            const p = try quantum(l, m.stamp.precision.get());
            finest = @min(finest, @backingInt(p));
        }
    }
    if (set != 0 and set != total) return l.refuse("§19.8 some modules with a `timescale and some without");
    l.b.p.finest = finest;
    const global: std_sim.time.Quantum = @fromBackingInt(@intCast(finest));
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| {
            if (d.kind != .module and d.kind != .macromodule and d.kind != .connectmodule and d.kind != .primitive) continue;
            var unit: std_sim.time.Quantum = .s;
            var precision: std_sim.time.Quantum = .s;
            if (d.kind != .primitive) {
                const m = Lower.payload(vir, Inst.Module, d.inst);
                if (m.stamp.flags.has_timescale) {
                    unit = try quantum(l, m.stamp.unit.get());
                    precision = try quantum(l, m.stamp.precision.get());
                }
            }
            const scale = std_sim.time.Scale.init(unit, precision, global) catch return l.refuse("an invalid timescale");
            try l.module_times.put(l.a, .{ .file = file, .index = @fromBackingInt(@intCast(k)) }, .{ .scale = scale, .unit_exp = @backingInt(unit) });
        }
    }
}

fn quantum(l: *Lower, seconds: f64) Error!std_sim.time.Quantum {
    return std_sim.time.Quantum.fromSeconds(seconds) catch l.refuse("an unsupported time unit");
}
