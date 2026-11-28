//! The device tables Sema writes beside the analysed `Air` body (the
//! per-instance half of the old `src/ir/Lowered.zig`): what codegen reads
//! that is not an instruction. The solver unknowns (`nodes`, ports first),
//! the named branches, the model card (`params`, one `arg` each), the
//! contributions with the slots that accumulate them, the §5.6.1.2 charge
//! sites, the §3.2.2 declared arrays, the §5.10 held slots, the §9.17.3 limit slots, the §4.6 noise
//! sources, the §9.17 kernel-control slots and the §9.4 display calls.
//! Every row is appended by Sema's lowering, which owns every write; a
//! later stage reads them through `*const Device`. Every name is an
//! `InternPool.String`; every slot is the `alloc` instruction in the `Air`
//! body that holds the value. The design is lowered flat (one body for the
//! instance tree), so each unknown, parameter, branch and contribution row
//! keeps the `Instance` it was declared in: codegen and VPI recover the
//! hierarchy from it, never by splitting a name.
//!
//! The data, by `data-oriented-design`'s six questions:
//! 1. In: Sema's lowering of one design. Out: these rows, read by codegen.
//! 2. One device per compilation; tens to thousands of rows per table.
//! 3. Every handle is a `u32` (`Node`, `Branch`, `Param`, `Contribution`);
//!    a table holds at most `rows_max` rows.
//! 4. Each table is read by column (codegen emits one array per column).
//! 5. As long as the `Air` it indexes; freed together.
//! 6. Rows are written in one lowering pass, in source order.
//! Cites: VAMS-2023 §1.3.1 (unknowns), §3.4 (parameters), §3.4.2 (ranges),
//! §3.12 (branches), §4.4, §5.4.2, §5.4.3, §5.6, §5.6.1.2, §5.6.1.3,
//! §5.6.7, §5.10, §9.4, §9.17.3.
//!
//! Contents:
//! - fields `nodes`, `num_ports`, `branches`, `params`, `ranges`, `contributions`, `charge_sites`, `arrays`, `held`, `limit_slots`, `flows`, `table_samples`, `noise`, `kernel`, `systf`, `displays`, `name`, `str_caps`
//! - `pub const Instance`, `pub const Node` (`Index`, `Kind`), `pub const Branch` (`Index`), `pub const Param` (`Index`, `Type`), `pub const Range`
//! - `pub const Access`, `pub const Contribution` (`Index`, `Kind`), `pub const ChargeSite`, `pub const Array`, `pub const Held`, `pub const Flow` (`Kind`), `pub const LimitSlot`, `pub const Noise` (`Kind`), `pub const Kernel`, `pub const Display`
//! - `pub const rows_max: u32`, `pub const str_row: u64`, `pub const str_row_max: u64`
//! - `pub fn deinit(d: *Device, gpa: Allocator) void`
//! - `pub fn paramRanges(d: *const Device, p: Param.Index) []const Range`
//! - `pub fn nodeName(d: *const Device, ip: *const InternPool, n: Node.Index) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const InternPool = @import("intern_pool");
const Air = @import("../Air.zig");
const String = InternPool.String;

/// §1.3.1 one row per solver unknown, in the order the device's `U` enum
/// numbers them: the ports (§6.5) first, then the nets, then each flow and
/// operator unknown as lowering first needs it. Row `i` is the `probe`
/// index `i`.
nodes: std.MultiArrayList(Node) = .empty,
/// The port rows are `nodes[0..num_ports]`.
num_ports: u32 = 0,
/// §3.12 the named branches, in declaration order; `Branch.Index` 0 is the
/// node pair's one unnamed branch (§5.4.1), so row `i` is branch `i + 1`.
branches: std.MultiArrayList(Branch) = .empty,
/// §3.4 the model card: row `i` is the `arg` index `i`.
params: std.MultiArrayList(Param) = .empty,
/// §3.4.2 every parameter's value ranges, a run per parameter.
ranges: std.ArrayList(Range) = .empty,
/// §5.6 one row per (access, branch) target, in first-contribution order.
contributions: std.MultiArrayList(Contribution) = .empty,
/// §5.6.1.2 every `ddt` that charges a contribution, in source order.
charge_sites: std.MultiArrayList(ChargeSite) = .empty,
/// §3.2.2 every declared array of two or more elements, in declaration
/// order: codegen gives each one slot (DV1, research/codegen.md T40).
arrays: std.ArrayList(Array) = .empty,
/// §5.10 the variables that keep their value between evaluations.
held: std.MultiArrayList(Held) = .empty,
/// §9.17.3 one row per access function a user-function `$limit` limits.
limit_slots: std.MultiArrayList(LimitSlot) = .empty,
/// §5.4.2.1/§5.4.3 every flow unknown and what it measures, in minting order.
flows: std.MultiArrayList(Flow) = .empty,
/// §9.21.1 each array-source `$table_model` site's sample count (its
/// `site` operand is the row's ordinal plus one).
table_samples: std.ArrayList(u32) = .empty,
/// §4.6.4 every noise source call and §4.6.3 `ac_stim`, in source order.
noise: std.MultiArrayList(Noise) = .empty,
/// §9.17 the kernel-control slots the host reads after an accepted step.
kernel: Kernel = .{},
/// §12 every user system function or task call (a VPI systf), in source
/// order: its name and its `call` (whose callee is `user_callee`).
systf: std.MultiArrayList(Display) = .empty,
/// §9.4 the display and file tasks, in source order.
displays: std.MultiArrayList(Display) = .empty,
/// The top module's name: what §9.4.3's `%m` prints and `%l` names after
/// `work.` (`.empty` before Sema sets it).
name: String = .empty,
/// §3.3 per instruction, the most bytes the string it yields (a run-time
/// string's call site, a string slot) can hold, never below `str_row` for
/// a run-time one; 0 for a value that is no string. Sema's `string.caps`
/// writes it (the old `cg_strcap.cap`); codegen sizes each row and held
/// field by it. Empty when the body holds no string.
str_caps: []const u64 = &.{},

/// The `Zcu.Instance.Index` a row was declared in, by its backing integer
/// (`Air` sits below the `Zcu`); `none` for a row no instance declares.
pub const Instance = enum(u32) { none = std.math.maxInt(u32), _ };

/// One solver unknown.
pub const Node = struct {
    /// Its unique spelling (`p`, `bus[3]`, `flow(p,n)`, `flow(<p>)`).
    name: String,
    kind: Kind,
    /// The node a flow unknown's tolerance comes from (`.none` for a net).
    of: Index,
    /// §3.6.2 its discipline's name, `.empty` when undeclared.
    discipline: String,
    /// The instance that declared it (a flow or operator unknown: the one
    /// whose access or operator minted it).
    instance: Instance,

    /// A row of `nodes`; `ground` is the reference node, never a row.
    pub const Index = enum(u32) { ground = std.math.maxInt(u32) - 1, none = std.math.maxInt(u32), _ };
    /// §3.6 a net, §5.4.2 a branch's flow, §5.4.3 a port's flow, §4.5.2 an
    /// analog operator's own unknown.
    pub const Kind = enum(u8) { net, branch_flow, port_flow, op_state };
};

/// §3.12 a named branch: its name and its terminals.
pub const Branch = struct {
    name: String,
    hi: Node.Index,
    lo: Node.Index,
    instance: Instance,

    /// 0 is the unnamed branch of a node pair; `i + 1` is `branches` row `i`.
    pub const Index = enum(u32) { unnamed = 0, _ };
};

/// §3.4 one model-card parameter.
pub const Param = struct {
    name: String,
    ty: Type,
    /// §3.4.5 a localparam: not on the card.
    local: bool,
    /// Its value under the declared defaults, or `.undef` when it does not fold.
    default: InternPool.Index,
    /// Its run of `ranges`.
    ranges_start: u32,
    ranges_len: u32,
    instance: Instance,
    /// Its default as an expression over earlier rows' `arg`s (its
    /// instructions in the body's prologue), for a host that moves a row
    /// it depends on; `.none` when the default reads no parameter.
    derive: Air.Inst.Ref,

    /// A `params` row: the `arg` index the body reads it by.
    pub const Index = enum(u32) { _ };
    /// §3.4.1 the declared type; `unspecified` takes its default's.
    pub const Type = enum(u8) { real, integer, string, unspecified };
};

/// §3.4.2 one `from` or `exclude` range; a bound is null when it does not
/// fold over literals (or is a string set's).
pub const Range = struct {
    exclude: bool,
    lo: ?f64,
    hi: ?f64,
    lo_closed: bool,
    hi_closed: bool,
    strings: bool,
};

/// §4.4 the access a contribution targets.
pub const Access = enum(u8) { potential, flow };

/// §5.6 one contribution target and the slots its `<+`s accumulate into.
pub const Contribution = struct {
    access: Access,
    kind: Kind,
    branch: Branch.Index,
    hi: Node.Index,
    lo: Node.Index,
    /// The `alloc`s of the resistive and reactive (§5.6.1.2) sums and the
    /// §5.6.1.3 retention flag (1 when a `<+` ran).
    resist: Air.Inst.Index,
    react: Air.Inst.Index,
    wrote: Air.Inst.Index,
    /// The instance whose `<+` opened the row (§5.4.1: whose branch it is).
    instance: Instance,
    /// §5.4.2 the unknown carrying the branch's current (a potential or
    /// indirect row's), `.none` when lowering minted none.
    flow: Node.Index,

    pub const Index = enum(u32) { _ };
    /// A `<+` or a §5.6.7 indirect assignment.
    pub const Kind = enum(u8) { direct, indirect };
};

/// §5.6.1.2 one `ddt` whose argument charges `contrib`, `sign` its sign in
/// the sum; `slot` holds the charge at the end of the body.
pub const ChargeSite = struct { contrib: Contribution.Index, sign: f64, slot: Air.Inst.Index };

/// §3.2.2 one declared array: `count` consecutive `alloc`s from `slot`, its
/// elements in declaration order (`Sema/decl.zig`'s `declareArray`). Read
/// whole (both fields at once), so a row, not two columns.
pub const Array = struct { slot: Air.Inst.Index, count: u32 };

/// §5.10 a variable kept between evaluations and its slot.
/// A §3.2.2 array is one row: `count` consecutive slots from `slot`, its
/// elements in declaration order (a scalar's `count` is 1). `init` is the
/// §3.2 declaration initializer the host seeds before the first evaluation
/// (`.undef` when there is none or it does not fold; the slot's zero then).
pub const Held = struct { name: String, slot: Air.Inst.Index, count: u32, init: InternPool.Index };

/// §5.4.2/§5.4.3 one flow unknown: a branch's (`hi`, `lo`) or a port's
/// (`hi` the port, `lo` ground).
pub const Flow = struct {
    unknown: Node.Index,
    hi: Node.Index,
    lo: Node.Index,
    kind: Kind,

    pub const Kind = enum(u8) { branch, port };
};

/// §9.17.3 one limited access function: `label` as the source spells it
/// (`V(g,s)`), its target, and `slot`, the value the last site returned this
/// evaluation (seeded at entry with the previous iterate's, a `limit$old`
/// call on the row's ordinal).
pub const LimitSlot = struct {
    label: String,
    access: Access,
    branch: Branch.Index,
    hi: Node.Index,
    lo: Node.Index,
    /// The source spelled the pair reversed (§1.3.1.2).
    neg: bool,
    slot: Air.Inst.Index,
};

/// §4.6.4 one noise generator (one call is one generator, §4.6.4.6), or
/// §4.6.3's `ac_stim`: its kind, its `call` (the PSD operands are its
/// arguments, a table flattened `count, f0, p0, ...`), and its label (`.empty`
/// when none). Which contributions carry it, and by what factor, is read
/// off the body: the call's value reaches their sums.
pub const Noise = struct {
    kind: Kind,
    call: Air.Inst.Index,
    name: String,

    pub const Kind = enum(u8) { thermal, flicker, table, table_log, ac_stim };
};

/// §9.17 each running request's slot, null when the design makes none:
/// `$bound_step`'s smallest step and `$discontinuity`'s smallest degree
/// (+inf when no call ran), VerA's `$vera_reject_step` retry time (+inf),
/// and `$discontinuity(-1)`'s reject-the-iteration flag (0 or 1).
pub const Kernel = struct {
    bound_step: ?Air.Inst.Index = null,
    discontinuity: ?Air.Inst.Index = null,
    reject_step: ?Air.Inst.Index = null,
    reject_iteration: ?Air.Inst.Index = null,
};

/// §9.4 one display or file task: its name, its `call`, and where it is in
/// the source (W1 status latch, research/codegen.md T1): `codegen/zig/say.zig`
/// and `status.zig` cite it in their records and, for `$fatal`/`$error`,
/// in `contract.StatusSite`'s message. `""`/`0` when codegen runs with no
/// diagnostic bag to look the token up in.
pub const Display = struct { name: String, call: Air.Inst.Index, file: String, line: u32 };

/// The row every run-time string had before rows were sized, and what a
/// piece of run-time length counts (the old `cg_strcap.row`).
pub const str_row: u64 = 4096;
/// The largest row a device can address, 2^47 bytes (`cg_strcap.max_row`).
pub const str_row_max: u64 = 1 << 47;

/// The most rows any table holds: a handle is a `u32` below the sentinels.
pub const rows_max: u32 = std.math.maxInt(u32) - 2;

const Device = @This();

comptime {
    // Hot rows read by column: a handle per column, no padding words.
    assert(@sizeOf(Node.Index) == 4);
    assert(@sizeOf(Branch.Index) == 4);
    assert(@sizeOf(Array) == 8);
}

/// Frees every table.
pub fn deinit(d: *Device, gpa: Allocator) void {
    d.nodes.deinit(gpa);
    d.branches.deinit(gpa);
    d.params.deinit(gpa);
    d.ranges.deinit(gpa);
    d.contributions.deinit(gpa);
    d.charge_sites.deinit(gpa);
    d.arrays.deinit(gpa);
    d.held.deinit(gpa);
    d.limit_slots.deinit(gpa);
    d.noise.deinit(gpa);
    d.systf.deinit(gpa);
    d.flows.deinit(gpa);
    d.table_samples.deinit(gpa);
    d.displays.deinit(gpa);
    gpa.free(d.str_caps);
    d.* = undefined;
}

/// Parameter `p`'s §3.4.2 ranges, borrowed from `ranges`. Asserts the row exists.
pub fn paramRanges(d: *const Device, p: Param.Index) []const Range {
    const i: usize = @backingInt(p);
    assert(i < d.params.len);
    const start = d.params.items(.ranges_start)[i];
    const len = d.params.items(.ranges_len)[i];
    assert(start + len <= d.ranges.items.len);
    return d.ranges.items[start..][0..len];
}

/// Node `n`'s unique spelling (`p`, `bus[3]`, `flow(p,n)`, `idt$0`);
/// `"gnd"` for the ground reference node, which is no row. The one
/// spelling of ground: every message that names a node reads it here.
/// Asserts that `n` is ground or a row of `nodes`.
pub fn nodeName(d: *const Device, ip: *const InternPool, n: Node.Index) []const u8 {
    if (n == .ground) return "gnd";
    assert(@backingInt(n) < d.nodes.len);
    return ip.stringToSlice(d.nodes.items(.name)[@backingInt(n)]);
}
