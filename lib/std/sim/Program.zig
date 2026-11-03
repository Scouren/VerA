//! One digital (IEEE 1364-2005) design as a fixed table: what a compiler
//! stage writes and `State`/`Interp` execute. No source, token or syntax
//! tree reaches it: every name is a slot, every expression a typed row,
//! every format parsed. Rows follow Zig's Air idiom: a tag, a fixed 8-byte
//! payload, and variable-length payloads in `extra`.
//! Cites: IEEE 1364-2005 §4.8, §5.5 (expression types), §9 (the statements
//! `insts` encode), §11.4 (the time-0 queue), §12.5 (`scopes`), §17.1
//! (`fmts`), §19.8 (`times`).
//!
//! Contents:
//! - `pub const Ty = packed struct(u32)`, `Ty.real_ty`, `Ty.bit`, `Ty.int(width, signed) Ty`
//! - `pub const Ref = enum(u32)`, `pub const Slot = struct`
//! - `pub const Inst = struct` (`Inst.Tag`, `Inst.Data`)
//! - `pub const Expr = struct` (`Expr.Tag`, `Expr.Data`)
//! - `pub const Edge = enum(u2)`, `pub const Term = struct`
//! - `pub const Place = struct` (`Place.Kind`)
//! - `pub const Piece = struct` (`Piece.Kind`), `pub const Show = struct`, `pub const Radix`
//! - `pub const Scope = struct`, `pub const Time = struct`, `pub const Block = struct`
//! - `pub const Start = struct`, `pub const Case = struct`, `pub const Arm = struct`
//! - `pub const List = struct`, `List.empty`
//! - `pub const Math = enum(u8)`, `pub const Elem = struct`, `pub const Select = struct` (`Select.Mode`)
//! - `pub const Piece.none_width`
//! - `pub const Repeat = struct`, `pub const Fork = struct`, `pub const Sample = struct` (`Sample.Mode`)
//! - `pub const Task = struct`, `pub const TimeFormat = struct`, `pub const Monitor = struct`
//! - `pub const Net = struct` (`Net.no_decay`), `pub const Driver = struct` (`Driver.Source`)
//! - `pub const Sub = struct`, `pub const Call = struct`, `pub const Arg = struct`, `pub const CopyOut = struct`
//! - `pub fn words(width: u32) u32`
//! - `pub fn list(p: *const Program, l: List) []const u32`
//! - `pub fn extraData(p: *const Program, comptime T: type, at: u32) T`
//! - `pub fn str(p: *const Program, s: List) []const u8`
//! - `pub fn constOf(p: *const Program, e: Ref) struct { v: []const u64, x: []const u64 }`
//! - `pub fn deinit(p: *Program, gpa: Allocator) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const time = @import("time.zig");
const net = @import("net.zig");
const Bit = @import("logic.zig").Bit;

/// An expression's or a slot's type (§5.5.1): a width and a signedness, or
/// §4.8's `real`, a double held as its 64 bits. 30 bits of width: 2^30 - 1
/// bits per value, past any design (a wider one is refused where it is
/// written).
pub const Ty = packed struct(u32) {
    width: u30,
    signed: bool,
    real: bool,

    /// §4.8 `real`: 64 bits, signed.
    pub const real_ty: Ty = .{ .width = 64, .signed = true, .real = true };
    /// A 1-bit unsigned result (a relation, a truth value).
    pub const bit: Ty = .{ .width = 1, .signed = false, .real = false };

    /// An integral type. Asserts `width` fits.
    pub fn int(width: u32, signed: bool) Ty {
        assert(width != 0);
        assert(width <= std.math.maxInt(u30));
        return .{ .width = @intCast(width), .signed = signed, .real = false };
    }
};

/// An `exprs` row, or `none` for an absent operand (§9.4.1's null argument).
pub const Ref = enum(u32) { none = std.math.maxInt(u32), _ };

/// A run of `extra`: `len` words from `start`.
pub const List = struct {
    start: u32,
    len: u32,

    /// No words.
    pub const empty: List = .{ .start = 0, .len = 0 };
};

/// One storage slot: a variable, an array element, a net, a named event, or
/// a cell a process parks a value in. Its `words(width)` words start at
/// `word` in both planes (`State.v`, `State.x`).
pub const Slot = struct {
    word: u32,
    ty: Ty,
};

/// One instruction: a tag and 8 bytes. `pc` is the row index; a process is
/// a pc range ending in `.stop`.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Data = struct { a: u32 = 0, b: u32 = 0 };

    /// The meaning of `data.a`/`data.b` per tag.
    pub const Tag = enum(u8) {
        /// The end of a process or an out-of-line body.
        stop,
        /// §9.2 blocking assignment: `a` a `Place` in `extra`, `b` the value
        /// expression, already converted to the place's type.
        assign,
        /// §9.2.2 nonblocking assignment, landing in the NBA region.
        assign_nb,
        /// §6.2.1 a declaration assignment: slot `a` takes expression `b`.
        init_var,
        /// §9.7.1 `#d`: `a` the delay expression; resume at pc + 1.
        delay,
        /// §17 a system task: `a` a `Task` in `extra`.
        task,
        /// Continue at pc `a`.
        jump,
        /// §9.4: `a` the condition; true continues at pc + 1, else at `b`.
        branch,
        /// §9.9.2 an always body returning to pc `a`.
        restart,
        /// §9.5: `a` a `Case` in `extra`.
        case_select,
        /// §9.6: `a` the count expression, `b` a `Repeat` in `extra`.
        repeat_start,
        /// The end of a repeat body: counter `a`; while counts remain, pc `b`.
        repeat_next,
        /// §9.7 suspend on the event control `a` (a `List` of `Term` rows in
        /// `extra`, at `a`), resuming at pc + 1.
        wait_event,
        /// A.6.5 `wait`: `a` the condition, `b` the `List` of slots that
        /// re-test it (at `b` in `extra`).
        wait_level,
        /// §5.10.4 `-> e`: slot `a`.
        trigger,
        /// §6.1 driver `a` (a `drivers` row) evaluates, drives its net (at
        /// once or after its delay), and is armed on its operands.
        continuous,
        /// §9.8.2 `fork`: `a` a `Fork` in `extra`.
        fork,
        /// One fork arm done: join counter `a`, parent resumes at `b`.
        join_arm,
        /// §8.5.3.3 an intra-assignment timing control's first half: `a` a
        /// `Sample` in `extra`.
        sample,
        /// The parked value of hold `a` written to place `b` (`Place`).
        deposit,
        /// `deposit`, nonblocking.
        deposit_nb,
        /// A.6.5 `disable` of a named block: pc range [a, b).
        disable_block,
        /// §10.2.2 a task run to completion in place: `a` a `Call` in `extra`.
        call,
        /// §10.2.2 an inlined enable's copy-out: `a` a `CopyOut` in `extra`.
        copy_out,
        /// §10.3 `disable` of task `a` (a `subs` row): every activation ends.
        disable_task,
    };

    // One row per pc, read by every dispatch.
    comptime {
        assert(@sizeOf(Data) == 8);
    }
};

/// One expression row: a tag, its result type `ty` (the §5.5.2 context it
/// is evaluated in, already applied), and 8 bytes. Operands are rows.
pub const Expr = struct {
    tag: Tag,
    ty: Ty,
    data: Data,

    pub const Data = struct { a: u32 = 0, b: u32 = 0 };

    /// The meaning of `data.a`/`data.b` per tag. Each row's value is in its
    /// `ty`: an integral operand of another width is extended by its own
    /// signedness, or truncated, then retyped (`normalize`).
    pub const Tag = enum(u8) {
        /// A constant: `a` its v-plane word in `consts`, its x plane after.
        constant,
        /// A real constant: `a`/`b` the low and high halves of its bits.
        real_constant,
        /// Slot `a`'s value.
        slot,
        /// §3.9 an array element: `a` an `Elem` in `extra`; x when the index
        /// is x/z or outside the declared range.
        elem,
        /// §5.2.1 a bit- or part-select: `a` a `Select` in `extra`.
        select,
        /// `-a` (§5.1.5), in `ty`.
        neg,
        /// `~a`.
        not,
        /// `!a`: `a` a 1-bit truth row.
        lnot,
        /// §5.1.11 reductions of `a` (self-determined).
        red_and,
        red_nand,
        red_or,
        red_nor,
        red_xor,
        red_xnor,
        /// §5.1.9: the truth of `a` (integral or real) as one bit.
        truth,
        /// §5.1.5, §5.1.10: `a op b`, both in `ty`.
        add,
        sub,
        mul,
        div,
        mod,
        bit_and,
        bit_or,
        bit_xor,
        bit_xnor,
        /// §5.1.12 / §5.1.5: `a` in `ty`, `b` self-determined.
        shl,
        shr,
        ashl,
        ashr,
        pow,
        /// §5.1.7, §5.1.8: `a op b`, both in their common type, one bit.
        eq,
        neq,
        case_eq,
        case_neq,
        lt,
        le,
        gt,
        ge,
        /// §5.1.9 `&&`/`||` of two truth rows, short-circuit.
        land,
        lor,
        /// §5.1.13 `c ? x : y`: `a` the condition (self-determined), `b` a
        /// pair (`then`, `else`) in `extra`.
        cond,
        /// §5.1.14: `a` a `List` of parts, each self-determined, at `a`.
        concat,
        /// §5.1.14 `{n{x}}`: `a` the operand, `b` the count.
        replicate,
        /// §5.1.14 a zero replication's operand, evaluated for its effects
        /// and contributing no bits; only inside `concat`.
        discard,
        /// `a`'s value retyped and resized into `ty` (`$signed`,
        /// `$unsigned`, an assignment's conversion).
        convert,
        /// §4.8.2 `a` (real) rounded to an integer, then into `ty`.
        int_of_real,
        /// §4.8.2 `a` (integral) as a real.
        real_of_int,
        /// Real arithmetic over two real rows.
        real_neg,
        real_add,
        real_sub,
        real_mul,
        real_div,
        real_pow,
        /// §5.1.7 real relations, one bit: `a`, `b` real rows.
        real_eq,
        real_neq,
        real_lt,
        real_le,
        real_gt,
        real_ge,
        /// §5.1.13 a real conditional: `a` the condition truth row, `b` a
        /// pair in `extra`; an x condition is 0.0.
        real_cond,
        /// §17.7.1 `$time`/`$stime` in time row `a`'s units.
        time,
        stime,
        /// §17.7.2 `$realtime` in time row `a`'s units.
        realtime,
        /// §17.8 `$rtoi(a)`, `$realtobits(a)`, `$bitstoreal(a)`, `$itor(a)`.
        rtoi,
        realtobits,
        bitstoreal,
        /// §17.11.1 `$clog2(a)`.
        clog2,
        /// §17.11.2 real math of `a` (and `b`): which is `Math` `data.b`
        /// for one argument; two-argument rows use `a` a pair in `extra`.
        math1,
        math2,
        /// §10.4.1 a function call: `a` a `Call` in `extra`; its result
        /// (the result slot's value) in `ty`.
        call,
    };

    // One row per operator.
    comptime {
        assert(@sizeOf(Data) == 8);
    }
};

/// §17.11.2's real functions, `Expr.math1`/`math2`'s `b` and pair tag.
pub const Math = enum(u8) { ln, log10, exp, sqrt, floor, ceil, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, asinh, acosh, atanh, pow, atan2, hypot, ln1p, expm1 };

/// §5.10.1: a change toward 1 (posedge), away from 1 (negedge), or any.
pub const Edge = enum(u2) { any, posedge, negedge };

/// One term of an event control: slot `slot` changing with `edge`; with a
/// nonzero `width`, only bits [lo, lo + width) of it (a constant select).
pub const Term = struct {
    slot: u32,
    edge: Edge,
    lo: u32 = 0,
    width: u32 = 0,
};

/// An assignment's target, at its index in `extra`.
pub const Place = struct {
    kind: Kind,
    /// `.slot`: the slot. `.elem`: an `Elem`. `.select`: a `Select`.
    /// `.concat`: a `List` of places, most significant first, each with its
    /// width (`List` of pairs: place, width).
    a: u32,

    pub const Kind = enum(u32) { slot, elem, select, concat };
};

/// §3.9 an element reference: the array's first slot, how many slots it
/// has, and per dimension (outermost first) the index row and its declared
/// span, at `dims` in `extra` as triples (index, low, high) of i32 bits.
pub const Elem = struct {
    base: u32,
    count: u32,
    dims: List,
};

/// §5.2.1 a select of a vector held in a slot (`elem == none`: slot `slot`)
/// or in an array element (`elem` an `Elem` index into `extra`).
pub const Select = struct {
    slot: u32,
    elem: u32,
    /// The vector's declared `[msb:lsb]`.
    msb: i32,
    lsb: i32,
    /// How the selected position is computed: `const_part` reads `first`,
    /// `bit` the index row `index`, `up`/`down` the base row `index`.
    mode: Mode,
    index: u32,
    /// The bit count selected, and for `const_part` the position of its
    /// least significant bit in storage.
    count: u32,
    first: i32,

    pub const Mode = enum(u32) { const_part, bit, up, down };
};

/// A display argument piece (`fmts`): what one display call prints.
pub const Piece = struct {
    kind: Kind,
    /// The conversion character (`b`, `d`, `t`, `s`, ...), for `.spec`.
    conv: u8 = 0,
    flags: u8 = 0,
    /// The field width, `none_width` when absent.
    width: u32 = none_width,
    precision: i32 = -1,
    /// `.text`, `.lib`: the first byte in `string_bytes` (`width` bytes).
    /// `.spec`, `.bare`, `.bare_real`: the argument row. `.scope`: the pc
    /// whose named blocks `%m` names.
    a: u32 = 0,

    pub const none_width = std.math.maxInt(u32);

    pub const Kind = enum(u8) {
        /// Literal text.
        text,
        /// A conversion of argument `a`.
        spec,
        /// An argument with no format, in the task's radix.
        bare,
        /// A bare real argument (`%#g`, or `$realtime`'s `%.Nf`: `precision`).
        bare_real,
        /// §9.4.1's null argument: one space.
        space,
        /// §17.1.1.6 `%m`: the scope's path, then the named blocks around pc
        /// `a`.
        scope,
        /// §13.6 `%l`: text `a` (the `List` in `string_bytes`).
        lib,
    };
};

/// §9.4.1 the default radix of a display task (`Piece.bare`).
pub const Radix = enum(u8) { binary = 2, octal = 8, decimal = 10, hex = 16 };

/// One display call: its pieces (`List` of `Piece` indices in `pieces`),
/// the radix of its bare arguments, whether it ends a line, and the scope it
/// runs in (for `%m`, `%t`).
pub const Show = struct {
    pieces: List,
    radix: Radix,
    newline: bool,
    scope: u32,
};

/// An instance or a named scope (§12.5): its parent (itself at a root), its
/// name in `string_bytes`, a generate loop index, and its time row.
pub const Scope = struct {
    parent: u32,
    name: List,
    index: ?i32,
    time: u32,
};

/// §19.8 one module's time scale and unit (`time.zig`).
pub const Time = struct {
    scale: time.Scale,
    unit_exp: i32,
};

/// §5.3.2 a named sequential block: its scope, name, pc range and nesting
/// depth (which orders two blocks with one range), for `%m`.
pub const Block = struct {
    scope: u32,
    name: List,
    start: u32,
    end: u32,
    depth: u32,
};

/// One process started at time 0, in §11.4 dispatch order.
pub const Start = struct { pc: u32 };

/// §9.5 a case statement at its index in `extra`: the kind, the scrutinee,
/// the arms (a `List` of `Arm` indices) and the fallback pc.
pub const Case = struct {
    kind: Kind,
    scrutinee: u32,
    arms: List,
    fallback: u32,

    pub const Kind = enum(u32) { normal, casez, casex };
};

/// One case arm: its labels (a `List` of rows) and its pc.
pub const Arm = struct { labels: List, target: u32 };

/// §9.6 the counter cell and the pc past the body.
pub const Repeat = struct { counter: u32, end: u32 };

/// §9.8.2: the arm pcs (a `List`), the join counter, the pc after.
pub const Fork = struct { arms: List, join: u32, end: u32 };

/// §8.5.3.3 `lhs = #d rhs` / `lhs = @(e) rhs` (and `<=`): the right-hand
/// side `value` parked in hold `hold`, then by `mode`: only parked (the
/// next instruction deposits), a nonblocking write to `place` now or after
/// delay row `timing`, or the process suspends for delay row `timing` or on
/// the event control `terms`.
pub const Sample = struct {
    hold: u32,
    value: u32,
    mode: Mode,
    place: u32,
    timing: u32,
    terms: List,

    pub const Mode = enum(u32) { park, nba, nba_delay, delay, event };
};

/// §17 one system task call (`Inst.task`).
pub const Task = struct {
    kind: Kind,
    /// `.show`, `.strobe`: a `Show` index in `shows`. `.monitor`: a
    /// `Monitor` in `extra`. `.timeformat`: a `TimeFormat` in `extra`, or
    /// `none`.
    /// `.finish`: the verbosity row (or `none`), `b` the location text.
    a: u32,
    b: List = .empty,

    pub const Kind = enum(u32) { show, strobe, monitor, monitor_on, monitor_off, finish, stop, timeformat };
};

/// §17.3.2 `$timeformat`'s four arguments, or none for the reset.
pub const TimeFormat = struct { units: u32, precision: u32, suffix: List, width: u32, scope: u32 };

/// §17.1.3 a `$monitor` call: its show row, the argument rows it compares
/// (each self-determined), the slots its arguments read, and those of them
/// whose change reports without a comparison (`loose`).
pub const Monitor = struct { show: u32, compared: List, slots: List, loose: List };

/// §10 one task or function: its body's entry pc, its storage (slots
/// [first, first + count), set aside per activation when `automatic`), its
/// ports' slots (a `List`), a function's result slot, and the pc ranges of
/// its inlined copies (pairs, a `List`) a §10.3 disable stops.
pub const Sub = struct {
    entry: u32,
    function: bool,
    automatic: bool,
    first: u32,
    count: u32,
    result: u32,
    ports: List,
    ranges: List,
};

/// A call of `subs` row `sub`: per port, an `Arg` (4 words) in `args`.
pub const Call = struct { sub: u32, args: List };

/// One argument of a `Call`: the row its input value is (in the port's
/// type; `none` for an output), the `Place` its output lands in (`none`
/// for an input), and that place's type.
pub const Arg = struct { in: u32, place: u32, ty: Ty, pad: u32 = 0 };

/// §10.2.2 an inlined enable's copy-out: slot `slot` converted to `ty` and
/// written to `place`.
pub const CopyOut = struct { place: u32, slot: u32, ty: Ty };

/// §7.9 one net: its type, its slot, its drivers (a `List` of `drivers`
/// indices in `extra`), A.2.1.3's `delay3` on the resolved value, and a
/// `trireg`'s charge strength and §3.8 decay time (`no_decay`: holds forever).
pub const Net = struct {
    kind: net.NetKind,
    charge: net.Strength,
    slot: u32,
    drivers: List,
    delay: net.Delay,
    decay: u64,

    pub const no_decay = std.math.maxInt(u64);
};

/// §6.1/§7 one driver of a net: what it asserts (`source`), at A.2.2.2's
/// strengths, after its A.6.1 delay (`delay`, or the rows `delay_rows` read
/// when it schedules, `none` when constant). Its value is `width` bits, its
/// time-0 value at `init` words in `driver_init` (v then x).
/// ponytail: a tagged union per row, one row per driver; a table per source
/// kind if a gate-level netlist's millions of drivers make it matter.
pub const Driver = struct {
    net: u32,
    scope: u32,
    s0: net.Strength,
    s1: net.Strength,
    delay: net.Delay,
    delay_rows: [3]u32,
    width: u32,
    init: u32,
    init_or_z: bool,
    source: Source,

    pub const Source = union(enum) {
        /// A.6.1 an expression row, in the net's type; with `slice`, read
        /// `total` bits wide and bits [lo, lo + width) asserted.
        expr: struct { value: u32, slice: bool, lo: u32, total: u32 },
        /// §6.5.7.1 a port window: `width` bits from `src_lo` of slot `src`
        /// onto `dst_lo`, `ext` more bits copied from bit `sign_at` (or 0).
        bridge: struct { src: u32, src_lo: u32, dst_lo: u32, width: u32, ext: u32, sign_at: ?u32 },
        /// A.3.1 a gate: input rows (`List`), the input bit `lane` of a
        /// vector terminal, and the output bit it drives.
        gate: struct { kind: net.GateKind, ins: List, lane: ?u32, out_bit: ?u32 },
        /// §8 a UDP instance: table `udp`, input rows, its time-0 state
        /// and inputs (`prev`, a run of `udp_bits`).
        udp: struct { udp: u32, ins: List, sequential: bool, lane: ?u32, out_bit: ?u32, state: Bit, started: bool, prev: List },
        /// §19.9 a pull of an unconnected input.
        pull: Bit,
    };
};

slots: std.MultiArrayList(Slot) = .empty,
/// Every slot's value at time 0, `words(width)` words per slot per plane.
init_v: []const u64 = &.{},
init_x: []const u64 = &.{},
insts: std.MultiArrayList(Inst) = .empty,
/// The scope each instruction runs in, one per `insts` row.
inst_scope: []const u32 = &.{},
exprs: std.MultiArrayList(Expr) = .empty,
/// Variable-length payloads; every struct above is stored here by its
/// fields as u32 words (`extraData`).
extra: []const u32 = &.{},
/// Constant planes: per constant, its v words then its x words.
consts: []const u64 = &.{},
string_bytes: []const u8 = &.{},
scopes: []const Scope = &.{},
times: []const Time = &.{},
/// §17.3.2's default `units_number`, the finest precision's exponent.
finest: i32 = 0,
blocks: []const Block = &.{},
pieces: []const Piece = &.{},
shows: []const Show = &.{},
starts: []const Start = &.{},
/// §6.1 per slot, the continuous drivers' pcs that read it:
/// `fan[fan_start[slot]..fan_start[slot + 1]]`.
fan_start: []const u32 = &.{},
fan: []const u32 = &.{},
subs: []const Sub = &.{},
nets: []const Net = &.{},
drivers: []const Driver = &.{},
/// Every driver's time-0 value, `words(width)` words per plane, v then x.
driver_init: []const u64 = &.{},
/// §8 the UDP tables, one per primitive.
udps: []const []const net.UdpRow = &.{},
/// §8 the input values each sequential UDP instance last saw, at time 0
/// (`Driver.Source.udp.prev` names its run).
udp_bits: []const Bit = &.{},
/// Cells: repeat counters and fork join counters, by index.
counters: u32 = 0,
/// §8.5.3.3 hold cells, one per intra-assignment timing control.
holds: u32 = 0,

const Program = @This();

/// Plane words a `width`-bit value takes.
pub fn words(width: u32) u32 {
    assert(width != 0);
    return (width + 63) / 64;
}

/// The words `l` names in `extra`.
pub fn list(p: *const Program, l: List) []const u32 {
    assert(l.start + l.len <= p.extra.len);
    return p.extra[l.start..][0..l.len];
}

/// The `T` stored at `at` in `extra`, field by field, each field one u32
/// (an enum's or a `List`'s words as they are declared).
pub fn extraData(p: *const Program, comptime T: type, at: u32) T {
    var out: T = undefined;
    var i: u32 = at;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        switch (F) {
            u32 => @field(out, name) = p.extra[i],
            i32 => @field(out, name) = @bitCast(p.extra[i]),
            Ty => @field(out, name) = @bitCast(p.extra[i]),
            List => {
                @field(out, name) = .{ .start = p.extra[i], .len = p.extra[i + 1] };
                i += 1;
            },
            else => @field(out, name) = @fromBackingInt(@intCast(p.extra[i])), // else: every other field is a u32-backed enum
        }
        i += 1;
    }
    assert(i <= p.extra.len);
    return out;
}

/// The bytes `s` names in `string_bytes`.
pub fn str(p: *const Program, s: List) []const u8 {
    assert(s.start + s.len <= p.string_bytes.len);
    return p.string_bytes[s.start..][0..s.len];
}

/// A `.constant` row's planes, each `words(ty.width)` long.
pub fn constOf(p: *const Program, e: Ref) struct { v: []const u64, x: []const u64 } {
    const row = p.exprs.get(@backingInt(e));
    assert(row.tag == .constant);
    const n = words(row.ty.width);
    return .{ .v = p.consts[row.data.a..][0..n], .x = p.consts[row.data.a + n ..][0..n] };
}

/// Frees what `gpa` allocated for every table; a Program built in an arena
/// needs no `deinit`.
pub fn deinit(p: *Program, gpa: Allocator) void {
    p.slots.deinit(gpa);
    p.insts.deinit(gpa);
    p.exprs.deinit(gpa);
    p.* = undefined;
}
