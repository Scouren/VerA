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
//! - `pub const Source = struct`, `pub const Options = struct`, `pub const Lowered = struct`, `pub const Port = struct`, `pub const Named = struct`, `pub const SegmentRef = struct`, `pub const Why = struct`, `pub const Spec = struct`, `pub const ProcSite = struct`
//! - `pub const Error`, `pub const Type = struct` (`real_type`), `pub const Name = struct` (`Kind`), `pub const Span = struct`
//! - `pub const Frame = struct` (`Genvar`), `pub const Proc = struct` (`Kind`), `pub const ScopeInfo = struct`
//! - `pub const Lower = struct` (`Implicit`, `Site`, `Disable`, `LateParam`, `Declared`, `refuse`, `refuseFmt`, `reject`, `rejectFmt`, `rejectOperand`, `rejectArg`, `rejectArgFmt`, `lookup`, `readsSignal`, `bind`, `rootFrame`, `virOf`, `fileOf`, `envAt`, `constOf`, `intOf`, `tyOf`, `payload`, `tag`, `srcOffset`)
//! - `pub const none: u32`
//! - `pub fn lower(arena: Allocator, zcu: *Zcu, options: Options, why: *Why) Error!Lowered`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const std_sim = @import("std_sim");
const InternPool = @import("intern_pool");
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const decl = @import("digital/decl.zig");
const decl_mod = @import("decl.zig");
const stmt = @import("digital/stmt.zig");
const nets = @import("digital/nets.zig");
const time0 = @import("digital/time0.zig");
const sub = @import("digital/sub.zig");
const vars = @import("digital/vars.zig");
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
    /// VAMS §7 the digital half of a mixed design (lib/sim/digital's
    /// `Link.mixed`): its analog blocks, analog functions and continuous or
    /// ground nets are the analog solver's, skipped, where a pure IEEE 1364
    /// design refuses them.
    mixed: bool = false,
};

/// The program, and per timing check (`Program.checks` order) the byte of
/// the preprocessed text its W1199 report is filed at. A mixed design's
/// also has `names`: its variables and nets by path (`Named`).
pub const Lowered = struct {
    program: Program,
    check_sites: []const u32 = &.{},
    names: []const Named = &.{},
    /// The root instance's ports, in its list of ports' order (`Port`).
    ports: []const Port = &.{},
    /// The source offset of the root module's `module` keyword, in
    /// `check_sites`' offset space.
    top_at: u32 = 0,
    /// The distinct (module, parameter values) pairs instantiated, in
    /// first-instance order (`Spec`).
    specs: []const Spec = &.{},
    /// Per `Program.scopes` row, the `specs` row of the instance whose
    /// module its code is in (a named or generate block's is its
    /// instance's), or `none` for a scope no frame binds in.
    scope_spec: []const u32 = &.{},
    /// Per `Program.slots` row, the name of the first declaration bound to
    /// it ("" for a cell no declaration names: a hold, a temporary), and
    /// that declaration's source offset (`none` for an implicit net or a
    /// cell), in `check_sites`' offset space.
    slot_names: []const []const u8 = &.{},
    slot_at: []const u32 = &.{},
    /// Per compiled process (an `initial`, an `always`, a §6.2.1
    /// declaration assignment, a continuous driver), its first pc and
    /// source offset (`none` for a driver Vir holds no position of).
    proc_sites: []const ProcSite = &.{},
    /// Per `Program.slots` row, the `Program.scopes` row of the frame its
    /// declaration (or implicit net) was bound in, `none` for a cell; and
    /// its declared `[msb:lsb]` as written (reversed or negative kept),
    /// `width - 1 : 0` without one.
    slot_scope: []const u32 = &.{},
    slot_msb: []const i64 = &.{},
    slot_lsb: []const i64 = &.{},
    /// Per `Program.scopes` row, the `Zcu.instances` row whose frame owns
    /// it, or `none`.
    scope_instance: []const u32 = &.{},
    /// Per `Zcu.instances` row, its ports (`top.ports`, its own slots) and
    /// its `specs` row.
    instance_ports: []const []const Port = &.{},
    instance_spec: []const u32 = &.{},
};

/// One module specialization: its name, its `Zcu` key (the module and its
/// folded parameters, an interned `aggregate`), its first instance (a
/// `Zcu.instances` row) and that instance's ports (`Port`, slots its own).
pub const Spec = struct {
    module: []const u8,
    key: Zcu.Instance.Key,
    instance: u32,
    ports: []const Port,
    /// No override reached the spec (no `#(...)`, defparam or paramset
    /// at some instance of it): its values are the module's defaults.
    defaults: bool,
};

/// A process's first pc (`Program.insts` row) and source offset.
pub const ProcSite = struct { pc: u32, at: u32 };

/// One port of the root instance as a device host drives it: its name,
/// direction, the `Program.slots` row behind it (`maxInt` when none: a
/// continuous port of a mixed design), its type and declared `[msb:lsb]`,
/// `scalar` when declared without a range, `integer` for an `integer` or
/// `time` variable.
pub const Port = struct {
    name: []const u8,
    /// 1-based, in the module's list of ports, null ports counted (A.1.3).
    position: u32,
    dir: enum { input, output, inout },
    slot: u32,
    ty: Program.Ty,
    msb: i64,
    lsb: i64,
    scalar: bool,
    integer: bool,
};

/// VAMS §7.3 one variable or net a mixed host reads (D2A) or writes (A2D):
/// its path below the root as Sema's discrete card rows spell it (`n`,
/// `u.clk`), its `Program.slots` row and type.
pub const Named = struct { path: []const u8, slot: u32, ty: Program.Ty };

/// VAMS §7.8.5.1 a bridged primitive terminal: its instance, its
/// instruction and (in an instance array) its lane's bit; `lane` is 0 for a
/// terminal one bridge serves.
pub const SegmentRef = struct { instance: u32, inst: Inst.Index, lane: u32 = 0 };

/// `Unsupported`: a construct the lowering does not express yet, named in
/// `Lower.why`. `Rejected`: a design IEEE 1364-2005 makes an error, which
/// the caller reports under `Why.code` (lib/sim/digital's code for it) at
/// `Why.at`.
pub const Error = error{ Unsupported, Rejected } || Allocator.Error;

/// Why `lower` failed: the construct or the error, and for `Rejected` the
/// source offset (as a token start of `Options.sources`' trees) it is at
/// and its code (E1100, lib/sim/digital's catch-all, unless a rule has one).
pub const Why = struct { text: []const u8 = "", at: u32 = none, code: vams.Diag.Code = .E1100 };

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
    /// `reject`'s source offset.
    why_at: u32 = none,
    /// `reject`'s code: set before a `reject` whose rule has its own.
    why_code: vams.Diag.Code = .E1100,
    /// What a `nets.sink` lvalue is driven by, for lib/sim/digital's
    /// message when it is no net: set by a gate's or a port's caller.
    sink_use: enum { assign, gate, port } = .assign,
    /// VAMS §7.3.5 a mixed design's analog events (`Program.monitors`).
    monitors: std.ArrayList(Program.A2d) = .empty,
    /// VAMS §7.8 each bridge's segment net, by its `Zcu.instances` row,
    /// and the bridge each bridged primitive terminal (its instruction in
    /// its instance's module) reads and drives instead of its net.
    segment_of: std.AutoHashMapUnmanaged(u32, Name) = .empty,
    segment_refs: std.AutoHashMapUnmanaged(SegmentRef, u32) = .empty,
    /// The bridged terminals whose array lanes take bridges of their own,
    /// read only lane by lane (`gate_lane`), and the lane being compiled
    /// (`none` outside a gate's inputs).
    lane_split: std.AutoHashMapUnmanaged(SegmentRef, void) = .empty,
    /// VAMS §7.9 a segment a connect module drives: its receivers' net, by
    /// its drivers' net (`domain.segregate`).
    receivers: std.AutoHashMapUnmanaged(u32, Name) = .empty,
    /// VAMS §9.22.5 the nets `driver_update` terms watch (`Program.
    /// driver_updates`), and each one's row by its net.
    driver_updates: std.ArrayList(Program.DriverUpdate) = .empty,
    update_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    gate_lane: u32 = none,
    names: std.ArrayList(Name) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    scopes: std.ArrayList(ScopeInfo) = .empty,
    /// Per instance, its frame, and where its parent instantiates it
    /// (`site.frame` `none` for a root).
    instance_frame: []u32 = &.{},
    sites: []Site = &.{},
    /// §12.2.1 the frame each `defparam` of each instance is written in
    /// (a generate block's, for one inside it).
    defparam_frames: std.AutoHashMapUnmanaged(struct { instance: u32, inst: Inst.Index }, u32) = .empty,
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
    /// Parameters `Sema/eval.zig` does not fold: each slot and the row of
    /// its value, evaluated at the end (`vars.finishParams`).
    late_params: std.ArrayList(LateParam) = .empty,
    /// §9.7.2 the processes keeping an expression term's hidden slot,
    /// queued at time 0 before every other.
    term_starts: std.ArrayList(u32) = .empty,
    /// A.6.5 each named block's pc range, by the frame it is compiled in and
    /// its name (`blockKey`), and the disables waiting for every block.
    block_ranges: std.StringHashMapUnmanaged([2]u32) = .empty,
    /// §12.5 each named block's frame, by the frame around it and its
    /// `block` instruction, made once (a process's at the walk).
    block_frames: std.AutoHashMapUnmanaged(struct { outer: u32, inst: Inst.Index }, u32) = .empty,
    disables: std.ArrayList(Disable) = .empty,
    /// §15 the timing checks, and per check the byte its W1199 report is
    /// filed at.
    checks: std.ArrayList(Program.Check) = .empty,
    check_sites: std.ArrayList(u32) = .empty,
    /// §18.1 a dump task was lowered: the catalog is written at the end.
    dumps: bool = false,
    /// §17.2.10 an `$sdf_annotate` was lowered: the scope table is written
    /// at the end.
    sdf: bool = false,
    /// A function body is being compiled (§10.4.4: its fork runs in order).
    in_function: bool = false,
    /// §10.2.1 every slot of an automatic subroutine's storage (each
    /// activation copy's too).
    auto_slots: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// An automatic subroutine's activation storage is being laid out: its
    /// named blocks' items join it (`sub.zig`'s `storage`).
    laying_out: bool = false,
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
    /// Every declaration bound to slots, in bind order (`Lowered.slot_names`).
    declared: std.ArrayList(Declared) = .empty,
    proc_sites: std.ArrayList(ProcSite) = .empty,
    /// Where lib/sim/digital bound each declaration of a frame (its first,
    /// `redecl.bindOrder`): a use before it in compiled code is an error.
    bound_at: std.AutoHashMapUnmanaged(struct { frame: u32, decl: Inst.Index }, u32) = .empty,
    /// Processes and drivers are being compiled (lib/sim/digital's pass
    /// two), where a name is visible only from its binding on.
    compiling: bool = false,

    /// Declaration `decl` of frame `frame`, bound to `count` slots from `slot`.
    pub const Declared = struct { frame: u32, decl: Inst.Index, slot: u32, count: u32, msb: i64, lsb: i64 };

    /// A.6.5 a `disable` at pc `pc` of the name `name`, written in frame `frame`.
    pub const Disable = struct { pc: u32, frame: u32, name: []const u8, inst: Inst.Index };

    /// A parameter `Sema/eval.zig` does not fold: its slot and type, its
    /// final value expression and the frame it is written in, and once
    /// compiled (after every subroutine is declared) the value's row.
    pub const LateParam = struct { slot: u32, ty: Type, frame: u32, value: Inst.Ref, row: u32 = none };

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

    /// `reject` at operand `r` of bracketed form `i` (a select, a
    /// concatenation) of frame `f`: at `r` when Vir holds its position, else
    /// at the first token of the form's operand `k`, counting the top-level
    /// `,` and `:` after its opening bracket (a literal has no position in
    /// Vir; lib/sim/digital reports at its token, an empty one at the token
    /// after it).
    pub fn rejectOperand(l: *Lower, f: u32, r: Inst.Ref, i: Inst.Index, k: u32, comptime msg: []const u8) error{Rejected} {
        if (r.toIndex()) |ri| if (l.srcOffset(f, ri) != 0) return l.reject(f, r, msg);
        l.why = msg;
        l.why_at = l.srcOffset(f, i);
        const vir = l.virOf(f);
        if (Inst.dataKind(tag(vir, i)) != .pl_node) return error.Rejected;
        const tree = l.options.sources[@backingInt(l.fileOf(f))].tree;
        const end: vams.Ast.TokenIndex = @intCast(tree.tokens.len);
        var t = tree.nodeMainToken(vir.instructions.items(.data)[@backingInt(i)].pl_node.src_node);
        while (t < end and tree.tokenTag(t) != .l_bracket and tree.tokenTag(t) != .l_brace and tree.tokenTag(t) != .l_paren) t += 1;
        var depth: u32 = 0;
        var seen: u32 = 0;
        t += 1;
        while (t < end) : (t += 1) {
            const tt = tree.tokenTag(t);
            const separator = tt == .comma or tt == .colon;
            const closer = tt == .r_bracket or tt == .r_brace or tt == .r_paren;
            // An empty slot is reported at the token that ends it.
            if (depth == 0 and seen == k) {
                l.why_at = tree.tokenStart(t);
                return error.Rejected;
            }
            if (closer) {
                if (depth == 0) break;
                depth -= 1;
            } else if (tt == .l_bracket or tt == .l_brace or tt == .l_paren) {
                depth += 1;
            } else if (separator and depth == 0) seen += 1;
        }
        return error.Rejected;
    }

    /// `rejectArg` with a formatted message.
    pub fn rejectArgFmt(l: *Lower, f: u32, call: Inst.Index, k: usize, comptime fmt: []const u8, args: anytype) Error {
        l.rejectArg(f, call, k, "") catch {};
        l.why = try std.fmt.allocPrint(l.a, fmt, args);
        return error.Rejected;
    }

    /// Records error `msg` at expression `r` of frame `f` and fails
    /// (`Rejected`): the message lib/sim/digital gives the same design.
    /// A call is at its name (its node's main token is its `(`), as
    /// lib/sim/digital reports it.
    pub fn reject(l: *Lower, f: u32, r: Inst.Ref, comptime msg: []const u8) error{Rejected} {
        l.why = msg;
        l.why_at = 0;
        const i = r.toIndex() orelse return error.Rejected;
        l.why_at = l.srcOffset(f, i);
        const vir = l.virOf(f);
        if (Inst.dataKind(tag(vir, i)) != .pl_node) return error.Rejected;
        const tree = l.options.sources[@backingInt(l.fileOf(f))].tree;
        const n = vir.instructions.items(.data)[@backingInt(i)].pl_node.src_node;
        if (tree.nodeTag(n) == .call) l.why_at = tree.tokenStart(tree.nodeMainToken(tree.nodeData(n).node_and_extra[0]));
        return error.Rejected;
    }

    /// `reject` with a formatted message.
    pub fn rejectFmt(l: *Lower, f: u32, r: Inst.Ref, comptime fmt: []const u8, args: anytype) Error {
        const msg = try std.fmt.allocPrint(l.a, fmt, args);
        l.reject(f, r, "") catch {};
        l.why = msg;
        return error.Rejected;
    }

    /// `reject` at argument `k` of call `call` (frame `f`), found in the
    /// tree: a literal argument has no position of its own in Vir.
    pub fn rejectArg(l: *Lower, f: u32, call: Inst.Index, k: usize, comptime msg: []const u8) error{Rejected} {
        l.why = msg;
        l.why_at = l.srcOffset(f, call);
        const vir = l.virOf(f);
        if (Inst.dataKind(tag(vir, call)) != .pl_node) return error.Rejected;
        const tree = l.options.sources[@backingInt(l.fileOf(f))].tree;
        const n = vir.instructions.items(.data)[@backingInt(call)].pl_node.src_node;
        if (tree.nodeTag(n) != .call) return error.Rejected;
        const slots = tree.extraDataSlice(tree.extraData(tree.nodeData(n).node_and_extra[1], vams.Ast.Node.SubRange), vams.Ast.Node.OptionalIndex);
        if (k < slots.len) if (slots[k].unwrap()) |arg| {
            l.why_at = tree.tokenStart(tree.nodeMainToken(arg));
        };
        return error.Rejected;
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
        if (n.kind != .sub and n.kind != .scope) try l.declared.append(l.a, .{ .frame = f, .decl = d, .slot = n.slot, .count = n.count, .msb = n.msb, .lsb = n.lsb });
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

    /// Whether expression `r` of frame `f` reads a variable, a net or a
    /// named event: no constant expression (§5.2: "a constant expression
    /// … shall consist of constant numbers and parameters").
    pub fn readsSignal(l: *Lower, f: u32, r: Inst.Ref) Error!bool {
        const vir = l.virOf(f);
        var stack: std.ArrayList(Inst.Index) = .empty;
        var ops: std.AutoHashMapUnmanaged(Inst.Index, void) = .empty;
        try stack.append(l.a, r.toIndex() orelse return false);
        var steps: usize = 0;
        while (stack.pop()) |i| : (steps += 1) {
            assert(steps <= vir.instructions.len * 4);
            if (tag(vir, i) == .decl_ref) {
                const d = decl_mod.canonical(vir, vir.instructions.items(.data)[@backingInt(i)].decl_tok.decl);
                // Not bound yet (a port whose own range names it): by its form.
                const at = l.lookup(f, d) orelse switch (tag(vir, d)) {
                    .variable, .net, .io, .event => return true,
                    else => continue, // else: a parameter, a genvar, a subroutine
                };
                switch (l.names.items[at].kind) {
                    .variable, .net, .event => return true,
                    .param, .genvar, .sub, .scope => {},
                }
                continue;
            }
            ops.clearRetainingCapacity();
            try @import("control.zig").operands(l.a, vir, i, &ops);
            var it = ops.keyIterator();
            while (it.next()) |o| try stack.append(l.a, o.*);
        }
        return false;
    }

    /// The folded value of `r` in frame `f`, or null when it has none at
    /// elaboration.
    pub fn constOf(l: *Lower, f: u32, r: Inst.Ref) Error!?eval.Const {
        const env = try l.envAt(f);
        return env.ref(r);
    }

    /// The folded integer `r` is in frame `f`, refused when it has none.
    pub fn intOf(l: *Lower, f: u32, r: Inst.Ref) Error!i64 {
        // The IEEE 1364 mode first: §5.5's widths (a 64-bit parameter's
        // arithmetic), x/z bits, selects, constant functions.
        if (try eval.v1364.int(try l.envAt(f), r)) |v| return v;
        const c = (try l.constOf(f, r)) orelse return if (try l.readsSignal(f, r))
            l.reject(f, r, "a constant expression is required here")
        else
            l.refuse("a constant expression Sema/eval.zig does not fold (an x/z bit, past 64 bits, a select or a call)");
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
/// `Unsupported` or `Rejected`, `why` says what. Asserts `zcu` is
/// elaborated (`Config.roots = .all`) and has one `Source` per file.
pub fn lower(arena: Allocator, zcu: *Zcu, options: Options, why: *Why) Error!Lowered {
    assert(options.sources.len == zcu.files.len);
    var b: Builder = .init(arena);
    var l: Lower = .{ .zcu = zcu, .a = arena, .b = &b, .options = options };
    spine(&l) catch |e| {
        why.* = .{ .text = l.why, .at = l.why_at, .code = l.why_code };
        return e;
    };
    var program = b.finish();
    program.monitors = l.monitors.items;
    program.driver_updates = l.driver_updates.items;
    vars.finishParams(&l, &program) catch |e| {
        why.* = .{ .text = l.why, .at = l.why_at, .code = l.why_code };
        return e;
    };
    time0.finish(&l, &program) catch |e| {
        why.* = .{ .text = l.why, .at = l.why_at, .code = l.why_code };
        return e;
    };
    assert(program.inst_scope.len == program.insts.len);
    const named = if (options.mixed) @import("digital/domain.zig").names(&l) catch |e| {
        why.* = .{ .text = l.why, .at = l.why_at, .code = l.why_code };
        return e;
    } else &.{};
    const top = @import("digital/top.zig");
    const root_ports = top.ports(&l, 0) catch |e| {
        why.* = .{ .text = l.why, .at = l.why_at, .code = l.why_code };
        return e;
    };
    const specs = top.specs(&l) catch |e| {
        why.* = .{ .text = l.why, .at = l.why_at, .code = l.why_code };
        return e;
    };
    const slots = try top.slotNames(&l, program.slots.items(.ty));
    return .{
        .program = program,
        .check_sites = l.check_sites.items,
        .names = named,
        .ports = root_ports,
        .top_at = top.topAt(&l),
        .specs = specs.rows,
        .scope_spec = specs.of_scope,
        .slot_names = slots.names,
        .slot_at = slots.at,
        .proc_sites = l.proc_sites.items,
        .slot_scope = slots.scope,
        .slot_msb = slots.msb,
        .slot_lsb = slots.lsb,
        .scope_instance = specs.scope_instance,
        .instance_ports = specs.instance_ports,
        .instance_spec = specs.of_instance,
    };
}

// ---- private ----

fn spine(l: *Lower) Error!void {
    try gates.checkUdps(l);
    if (l.zcu.instances.len == 0) {
        l.why = "digital execution found no top-level module";
        l.why_at = moduleAt(l, firstModule(l) orelse return error.Rejected);
        return error.Rejected;
    }
    // §17.2.1/§17.2.9 a relative data file is looked for beside the design.
    const pp = l.options.sources[0].pp;
    if (pp.files.len != 0) l.b.p.file_name = try l.b.string(pp.files[0].name);
    try timeScales(l);
    try decl.declare(l);
    if (l.options.mixed) try @import("digital/drivers.zig").segregate(l);
    try stmt.compileAll(l);
}

/// IEEE 1364-2005 §19.8: each module's `timescale (the last before it, or
/// none); some modules with one and some without is an error. The design's
/// tick is the finest precision of all of them, `s` when none is given. A
/// mixed design's modules before its first `timescale take that one, as
/// lib/sim/digital's `mixedTimescales` moves it to the text's start: the
/// shipped prelude's modules come ahead of every directive the source wrote.
fn timeScales(l: *Lower) Error!void {
    const zcu = l.zcu;
    const first = if (l.options.mixed) firstTimescale(l) else null;
    var finest: i32 = 0;
    var set: u32 = 0;
    var total: u32 = 0;
    var ahead = true;
    for (0..zcu.files.len) |f| {
        const vir = zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.decls()) |d| {
            if (d.kind != .module and d.kind != .macromodule and d.kind != .connectmodule) continue;
            const m = Lower.payload(vir, Inst.Module, d.inst);
            total += 1;
            const stamp = stampOf(m, first, &ahead) orelse continue;
            set += 1;
            const p = try quantum(l, stamp.precision.get());
            finest = @min(finest, @backingInt(p));
        }
    }
    if (set != 0 and set != total) {
        l.why = "§19.8: it shall be an error if some modules have a `timescale specified and others do not";
        l.why_at = moduleAt(l, zcu.instances.items(.module)[0]);
        return error.Rejected;
    }
    l.b.p.finest = finest;
    const global: std_sim.time.Quantum = @fromBackingInt(@intCast(finest));
    ahead = true;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| {
            if (d.kind != .module and d.kind != .macromodule and d.kind != .connectmodule and d.kind != .primitive) continue;
            var unit: std_sim.time.Quantum = .s;
            var precision: std_sim.time.Quantum = .s;
            if (d.kind != .primitive) if (stampOf(Lower.payload(vir, Inst.Module, d.inst), first, &ahead)) |stamp| {
                unit = try quantum(l, stamp.unit.get());
                precision = try quantum(l, stamp.precision.get());
            };
            const scale = std_sim.time.Scale.init(unit, precision, global) catch return l.refuse("an invalid timescale");
            try l.module_times.put(l.a, .{ .file = file, .index = @fromBackingInt(@intCast(k)) }, .{ .scale = scale, .unit_exp = @backingInt(unit) });
        }
    }
}

/// The first module any file declares.
fn firstModule(l: *const Lower) ?Zcu.Decl {
    for (0..l.zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        for (l.zcu.fileVir(file).decls(), 0..) |d, k| if (d.kind == .module or d.kind == .macromodule)
            return .{ .file = file, .index = @fromBackingInt(@intCast(k)) };
    }
    return null;
}

/// The source offset of module `d`'s declaration (its main token), where
/// lib/sim/digital reports a whole-design error.
fn moduleAt(l: *const Lower, d: Zcu.Decl) u32 {
    const vir = l.zcu.fileVir(d.file);
    const tree = l.options.sources[@backingInt(d.file)].tree;
    const n = vir.instructions.items(.data)[@backingInt(l.zcu.declRow(d).inst)].pl_node.src_node;
    return tree.tokenStart(tree.nodeMainToken(n));
}

/// The stamp of a mixed design's first module with a `timescale.
fn firstTimescale(l: *Lower) ?Inst.Module.Stamp {
    assert(l.options.mixed);
    for (0..l.zcu.files.len) |f| {
        const vir = l.zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.decls()) |d| {
            if (d.kind != .module and d.kind != .macromodule and d.kind != .connectmodule) continue;
            const m = Lower.payload(vir, Inst.Module, d.inst);
            if (m.stamp.flags.has_timescale) return m.stamp;
        }
    }
    return null;
}

/// Module `m`'s `timescale: its own, else `first` (a mixed design's) while
/// no module before it had one (`ahead`, cleared at the first that does),
/// else none.
fn stampOf(m: Inst.Module, first: ?Inst.Module.Stamp, ahead: *bool) ?Inst.Module.Stamp {
    if (m.stamp.flags.has_timescale) {
        ahead.* = false;
        return m.stamp;
    }
    return if (ahead.*) first else null;
}

fn quantum(l: *Lower, seconds: f64) Error!std_sim.time.Quantum {
    return std_sim.time.Quantum.fromSeconds(seconds) catch l.refuse("an unsupported time unit");
}
