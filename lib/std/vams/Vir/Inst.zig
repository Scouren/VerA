//! One Vir instruction (Zig's `Zir.Inst`): a tag and 8 bytes of `Data`,
//! and every payload a `pl_node` tag points at in `extra`. Declarations,
//! module items, statements and expressions share one table; which kind a
//! tag is, and how its `Data` reads, is `dataKind` and `Payload`, one
//! exhaustive switch each, so a new tag fails to compile until both name it.
//! Cites: VAMS-2023 annex A (A.1 design units, A.2 declarations, A.4
//! instances and generates, A.6 statements, A.7 specify, A.8 expressions);
//! IEEE 1364-2005 annex A, §19 (the directive stamp).
//!
//! Contents:
//! - fields `tag`, `data`
//! - `pub const Index` (`toRef`), `pub const Ref` (`toIndex`), `pub const Tag`, `pub const Data`, `pub const DataKind`
//! - `pub fn dataKind(tag: Tag) DataKind`, `pub fn Payload(comptime tag: Tag) type`
//! - payloads: `Module` (`Stamp`), `Default`, `Port`, `Io`, `Net`, `Variable`, `Param`, `ValueRange`,
//!   `Aliasparam`, `Name`, `Branch`, `Instance`, `Arg`, `Assign`, `Process`, `Function`,
//!   `GenFor`, `GenIf`, `GenCase`, `Arm`, `GenBlock`, `Specify`, `Exprs`, `Path`, `TimingCheck`,
//!   `TimingEvent`, `PulseStyle`, `Override`, `Block`, `CondBr`, `Case`, `Loop`, `Repeat`, `Wait`,
//!   `Delay`, `EventWait`, `Bin`, `Timed`, `Triple`, `Field`, `Call`, `SysCall`, `Refs`, `BigInt`,
//!   `StepEvent`, `Nature`, `Attr`, `Discipline`, `DisciplineItem`, `Paramset`, `Primitive`,
//!   `ConnectRules`, `ConnectResolve`, `ConnectInsert`, `Config`
//! - flag enums: `Direction`, `NetKind`, `Storage`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Vir = @import("../Vir.zig");
const events = @import("../Preprocessor/events.zig");
const String = Vir.String;
const Body = Vir.Body;
const List = Vir.List;
const F64 = Vir.F64;

tag: Tag,
data: Data,

/// An instruction's row in `instructions`.
pub const Index = enum(u32) {
    _,

    pub fn toRef(i: Index) Ref {
        const r: Ref = @fromBackingInt(@backingInt(i));
        assert(r != .none);
        return r;
    }
};

/// An instruction, or none (an omitted argument, an absent operand).
pub const Ref = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn toIndex(r: Ref) ?Index {
        return if (r == .none) null else @fromBackingInt(@backingInt(r));
    }
};

/// What an instruction is. Groups: design units (the declaration table's
/// targets), module items, statements, expressions. "Declares" means the
/// payload opens with `name` and `prev` (the first declaration of the
/// same name in the same scope, or none) and `decl_ref`s may point at it.
pub const Tag = enum(u8) {
    // ---- design units (pl_node; the `Decl` table points here) ----
    /// `Module`: module, macromodule or connectmodule.
    module,
    /// `Nature`.
    nature,
    /// `Discipline`.
    discipline,
    /// `Paramset`; its body holds `param`, `variable`, `aliasparam`,
    /// `ps_override` and statements.
    paramset,
    /// `Primitive`: a UDP.
    primitive,
    /// `ConnectRules`; its body holds `connect_resolve` and `connect_insert`.
    connectrules,
    /// `Config`.
    config,

    // ---- module items (pl_node) ----
    /// `Port`: one non-ANSI header port (A.1.3 `port`); declares nothing.
    port,
    /// `Io`: a port or formal direction declaration; declares.
    io,
    /// `Net`; declares.
    net,
    /// `Variable` (`reg`, `integer`, `real`, ...); declares.
    variable,
    /// `Param` (parameter, localparam, specparam); declares.
    param,
    /// `Aliasparam`; declares.
    aliasparam,
    /// `Name`; declares.
    genvar,
    event,
    /// `Branch`; declares.
    branch,
    /// `Instance`: a module, UDP or gate instance; declares (an unnamed
    /// gate's name is empty and enters no scope).
    instance,
    /// `Assign`: one continuous assignment.
    assign,
    /// `Assign` (no strength, no delay): one defparam assignment.
    defparam,
    /// `Process`.
    analog,
    analog_initial,
    initial,
    always,
    /// `Function`; declares. A task is `Function` with `flags.task`.
    function,
    /// `GenFor`, `GenIf`, `GenCase`: generate constructs, not unrolled.
    gen_for,
    gen_if,
    gen_case,
    /// `GenBlock`: a generate scope, named or `genblk<n>`; declares.
    gen_block,
    /// `Specify`.
    specify,
    /// `Path`, `TimingCheck`, `PulseStyle`: specify items.
    path,
    timing_check,
    pulse_style,
    /// `TimingEvent`: a timing check's controlled event argument.
    timing_event,
    /// `Override`: a paramset's `.name = expr ;`.
    ps_override,
    /// `ConnectResolve`, `ConnectInsert`: connectrules items.
    connect_resolve,
    connect_insert,

    // ---- statements ----
    /// `Block` (pl_node): begin/fork, its locals then its statements.
    block,
    /// `CondBr`: `if`.
    condbr,
    /// `Case`.
    case,
    /// `Loop`: `for` (its init is the statement before), `while`, `forever`.
    loop,
    /// `Repeat`, `Wait`, `Delay` (`# d s`), `EventWait` (`@ e s`).
    repeat,
    wait,
    delay,
    event_wait,
    /// `Bin` {lhs, rhs}: `=`, `<=`, `<+`, `assign`/`force` (procedural).
    store,
    store_nb,
    contrib,
    proc_assign,
    force,
    /// `Timed` {lhs, rhs, timing}: intra-assignment timing.
    store_timed,
    store_nb_timed,
    /// `Triple` {lhs, probe, eqn}: `lhs : probe == eqn ;`.
    contrib_indirect,
    /// un_node: `deassign`, `release`, `->`, `disable`, `return` (operand
    /// may be none), `break`, `continue` (operand none).
    deassign,
    release,
    trigger,
    disable,
    ret,
    brk,
    cont,
    /// un_node: intra-assignment `# value` and `@ event` (none: `@*`);
    /// `Bin` {count, event}: `repeat (n) @ event`.
    delay_ctl,
    event_ctl,
    repeat_ctl,

    // ---- expressions ----
    /// decl_tok: a name resolved to its declaring instruction.
    decl_ref,
    /// str_tok: a name the file cannot resolve, for Sema.
    str_ref,
    /// int: an unsized decimal that fits `u64`.
    int,
    /// `BigInt`: a sized or based integer, or one wider than `u64`.
    big_int,
    /// float: a real literal (§2.6.2, scale factor applied), or `inf`.
    real,
    /// str: a string literal's bytes (§2.7, escapes decoded).
    str,
    /// un_node: unary operators.
    pos,
    neg,
    not,
    bit_not,
    red_and,
    red_nand,
    red_or,
    red_nor,
    red_xor,
    red_xnor,
    /// `Bin`: binary operators (operands evaluated in order).
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    shl,
    shr,
    ashl,
    ashr,
    lt,
    gt,
    lte,
    gte,
    eq,
    neq,
    case_eq,
    case_neq,
    bit_and,
    bit_or,
    bit_xor,
    bit_xnor,
    bool_and,
    bool_or,
    /// `Triple` {cond, then, else}, {min, typ, max}.
    ternary,
    mintypmax,
    /// `Field`: `operand . name` (hierarchical, branch, nature attribute).
    field,
    /// `Bin` {operand, index}; `Triple` {operand, msb|base, lsb|width}.
    elem,
    slice,
    slice_up,
    slice_down,
    /// `Call`: a user function or task, the callee a `decl_ref` or `str_ref`.
    call,
    /// `SysCall`: a `$` system function or task, or an A.8.2 built-in
    /// (`ddt`, `exp`, `potential`, ...), by name.
    call_sys,
    /// un_node: `< net >` (§5.4.3).
    port_branch,
    /// `Refs`: `{ a, b }` and `'{ a, , b }` (a hole is none).
    concat,
    pattern,
    /// `Bin` {count, concat}.
    replicate,
    pattern_repl,
    /// `Bin`: `a or b`, `a , b` in an event expression.
    event_or,
    /// un_node: event edges.
    posedge,
    negedge,
    driver_update,
    /// `StepEvent`.
    step_event,
    /// str_tok: §6.4.3 `.name` in a paramset statement.
    paramset_output,
    /// `Bin` {msb, lsb}: a declared range or dimension.
    range,
    /// `Bin` {reject, error (may be none)}: §14.6.1 `PATHPULSE$` limits.
    pulse_limits,
};

/// How a tag's `Data` reads.
pub const DataKind = enum { pl_node, un_node, str_tok, decl_tok, int, float, str };

/// Every instruction's 8 bytes; `Tag` decides the field (`dataKind`).
pub const Data = union {
    /// `payload_index` is the `extra` index of `Payload(tag)`.
    pl_node: struct { src_node: Ast.Node.Index, payload_index: u32 },
    un_node: struct { src_node: Ast.Node.Index, operand: Ref },
    str_tok: struct { start: String, src_tok: Ast.TokenIndex },
    decl_tok: struct { decl: Index, src_tok: Ast.TokenIndex },
    int: u64,
    float: f64,
    /// A string literal: `len` bytes at `start`, which may hold a NUL.
    str: struct { start: String, len: u32 },

    comptime {
        if (!std.debug.runtime_safety) assert(@sizeOf(Data) == 8);
    }
};

comptime {
    assert(@sizeOf(Tag) == 1);
}

/// §6.5.2.2 a port's direction; `none` for a header name not yet given one.
pub const Direction = enum(u2) { none, input, output, inout };

/// A.2.2.1 net types and the VAMS ones (§3.7 `wreal`, §3.6.4 `ground`);
/// `none` for a net declared by its discipline alone.
pub const NetKind = enum(u5) { none, wire, tri, tri0, tri1, wand, triand, wor, trior, trireg, uwire, supply0, supply1, wreal, ground };

/// A.2.1.3 variable types; `none` where no type keyword was written.
pub const Storage = enum(u3) { none, reg, integer, real, realtime, time, string };

/// A design unit (§6.2): `params` the header's `param`s, `ports` its
/// `port`s (non-ANSI) or `io`s (ANSI) in order, `body` its items.
pub const Module = extern struct {
    name: String,
    flags: packed struct(u32) { kind: enum(u2) { module, macromodule, connectmodule }, ansi: bool, _: u29 = 0 },
    stamp: Stamp,
    params: Body,
    ports: Body,
    body: Body,

    /// The IEEE 1364 §19 directives in force at the `module` keyword.
    pub const Stamp = extern struct {
        flags: packed struct(u32) { nettype: events.NetType, drive: events.Drive, celldefine: bool, has_timescale: bool, has_transition: bool, _: u13 = 0 },
        unit: F64,
        precision: F64,
        /// §10.3 `default_transition, seconds.
        transition: F64,
    };
};

/// One §10.2 `default_discipline in force at a declaration.
pub const Default = extern struct {
    flags: packed struct(u32) { qualifier: events.Qualifier, qualified: bool, _: u23 = 0 },
    discipline: String,
};

/// A non-ANSI header port: its external name (empty for a null port or a
/// concatenation) and its port expression (empty for a null port).
pub const Port = extern struct { name: String, value: Body };

/// A port or formal direction declaration: `range` and `dims` bodies of
/// `range` instructions, `defaults` the `default_discipline`s in force.
pub const Io = extern struct {
    name: String,
    prev: Ref,
    flags: packed struct(u32) { dir: Direction, net: NetKind, storage: Storage, signed: bool, header: bool, _: u20 = 0 },
    discipline: String,
    range: Body,
    dims: Body,
    init: Body,
    defaults: List(Default),
};

/// A net: `strength` the A.2.2.2 words as written ("strong0,pull1"),
/// `delay` up to three values.
pub const Net = extern struct {
    name: String,
    prev: Ref,
    flags: packed struct(u32) { net: NetKind, signed: bool, vectored: bool, scalared: bool, _: u24 = 0 },
    discipline: String,
    strength: String,
    range: Body,
    dims: Body,
    delay: Exprs,
    init: Body,
    defaults: List(Default),
};

/// A variable; `discipline` a `reg`'s optional one.
pub const Variable = extern struct {
    name: String,
    prev: Ref,
    flags: packed struct(u32) { storage: Storage, signed: bool, _: u28 = 0 },
    discipline: String,
    range: Body,
    dims: Body,
    init: Body,
};

/// A parameter; `local` is a localparam or, by IEEE 1364-2005 §4.10.1, a
/// body parameter of a module with a parameter header.
pub const Param = extern struct {
    name: String,
    prev: Ref,
    flags: packed struct(u32) { kind: enum(u2) { parameter, localparam, specparam }, storage: Storage, signed: bool, local: bool, _: u25 = 0 },
    range: Body,
    dims: Body,
    value: Body,
    ranges: List(ValueRange),
};

/// §3.4.2 `from`/`exclude`: `lo` alone for a bare value or a string set
/// (`set`), else the bracketed interval.
pub const ValueRange = extern struct {
    flags: packed struct(u32) { exclude: bool, lo_closed: bool, hi_closed: bool, interval: bool, set: bool, _: u27 = 0 },
    lo: Body,
    hi: Body,
};

/// §3.4.6 `aliasparam name = target`: `original` the target in this scope.
pub const Aliasparam = extern struct { name: String, prev: Ref, target: String, original: Ref };

/// A genvar or event.
pub const Name = extern struct { name: String, prev: Ref, dims: Body };

/// §3.12 `branch (hi, lo) name [range]`.
pub const Branch = extern struct { name: String, prev: Ref, range: Body, hi: Body, lo: Body };

/// A module, UDP or gate instance of `target` (a module, UDP or the gate
/// keyword). `defaults` are the §10.2 `default_discipline`s in force at a
/// gate or UDP instance (§3.9: a digital primitive's terminals take one);
/// empty for a module instance.
pub const Instance = extern struct {
    name: String,
    prev: Ref,
    target: String,
    flags: packed struct(u32) { kind: enum(u2) { module, udp, gate }, _: u30 = 0 },
    strength: String,
    delay: Exprs,
    range: Body,
    params: List(Arg),
    conns: List(Arg),
    defaults: List(Default),
};

/// A parameter value or connection: named (`.name(value)`) or ordered
/// (empty `name`); an empty `value` is unconnected.
pub const Arg = extern struct { name: String, value: Body };

/// A continuous assignment or defparam.
pub const Assign = extern struct { strength: String, delay: Exprs, lhs: Body, rhs: Body };

/// `analog`, `initial`, `always`, `specify`: one body.
pub const Process = extern struct { body: Body };

/// A function or task: `formals` its `io`s in formal order, `body` its
/// declarations and statements.
pub const Function = extern struct {
    name: String,
    prev: Ref,
    flags: packed struct(u32) { analog: bool, task: bool, automatic: bool, storage: Storage, signed: bool, _: u25 = 0 },
    range: Body,
    formals: Body,
    body: Body,
};

/// `for (init; cond; step) block`: `init` and `step` are `store` bodies.
pub const GenFor = extern struct { init: Body, cond: Body, step: Body, body: Body };

/// `if (cond) then else`, each arm a body of one `gen_block` or empty.
pub const GenIf = extern struct { cond: Body, then: Body, @"else": Body };

/// `case (operand) arms endcase`.
pub const GenCase = extern struct { operand: Body, arms: List(Arm) };

/// A case arm: `labels` computes `values` (none for `default`).
pub const Arm = extern struct { flags: packed struct(u32) { default: bool, _: u31 = 0 }, labels: Body, values: List(Ref), body: Body };

/// A generate scope, `named` when the source names it.
pub const GenBlock = extern struct { name: String, prev: Ref, flags: packed struct(u32) { named: bool, _: u31 = 0 }, body: Body };

/// Expressions computed by `body` whose results are `values`.
pub const Exprs = extern struct { body: Body, values: List(Ref) };

/// A.7.2 module path.
pub const Path = extern struct {
    flags: packed struct(u32) {
        full: bool,
        ifnone: bool,
        edge: enum(u2) { none, posedge, negedge },
        polarity: enum(u2) { none, positive, negative },
        data_polarity: enum(u2) { none, positive, negative },
        _: u24 = 0,
    },
    cond: Body,
    inputs: Exprs,
    outputs: Exprs,
    data: Body,
    delays: Exprs,
};

/// A.7.5 `$check ( args )`; an omitted argument is a none value.
pub const TimingCheck = extern struct { name: String, args: Exprs };

/// A controlled timing-check event: `edges` the `edge [...]` descriptors
/// as written; `cond` the `&&&` condition or none.
pub const TimingEvent = extern struct { flags: packed struct(u32) { edge: enum(u2) { none, posedge, negedge, edge }, _: u30 = 0 }, edges: String, term: Ref, cond: Ref };

/// `pulsestyle_*`/`showcancelled`/`noshowcancelled` outputs.
pub const PulseStyle = extern struct { keyword: String, terms: Exprs };

/// §6.4.1 `.name = value ;`.
pub const Override = extern struct { name: String, value: Body };

/// A named or unnamed `begin`/`fork` block.
pub const Block = extern struct { name: String, flags: packed struct(u32) { fork: bool, _: u31 = 0 }, body: Body };

pub const CondBr = extern struct { cond: Ref, then: Body, @"else": Body };
pub const Case = extern struct { flags: packed struct(u32) { kind: enum(u2) { case, casex, casez }, _: u30 = 0 }, operand: Ref, arms: List(Arm) };
/// An empty `cond` loops forever.
pub const Loop = extern struct { cond: Body, step: Body, body: Body };
pub const Repeat = extern struct { count: Ref, body: Body };
pub const Wait = extern struct { cond: Body, body: Body };
pub const Delay = extern struct { value: Ref, body: Body };
/// `event` none is `@*`.
pub const EventWait = extern struct { event: Ref, body: Body };
pub const Bin = extern struct { lhs: Ref, rhs: Ref };
pub const Timed = extern struct { lhs: Ref, rhs: Ref, timing: Ref };
pub const Triple = extern struct { a: Ref, b: Ref, c: Ref };
pub const Field = extern struct { operand: Ref, name: String };
pub const Call = extern struct { callee: Ref, args: List(Ref) };
pub const SysCall = extern struct { name: String, args: List(Ref) };
pub const Refs = List(Ref);

/// A §2.6.1 integer: `size` 0 when unsized, `digits` lowercased with `_`
/// and white space dropped (x, z and ? kept).
pub const BigInt = extern struct { size: u32, flags: packed struct(u32) { signed: bool, radix: u8, _: u23 = 0 }, digits: String };

/// `initial_step`/`final_step` with their analysis names.
pub const StepEvent = extern struct { flags: packed struct(u32) { final: bool, _: u31 = 0 }, analyses: List(String) };

/// `nature name [: parent[.potential|.flow]] attrs endnature`.
pub const Nature = extern struct { name: String, parent: String, flags: packed struct(u32) { parent_kind: enum(u2) { none, potential, flow }, _: u30 = 0 }, attrs: List(Attr) };
pub const Attr = extern struct { name: String, value: Body };

/// `discipline name items enddiscipline`.
pub const Discipline = extern struct { name: String, items: List(DisciplineItem) };

/// A binding (`name` the nature), a domain (`name` the word), an override
/// (`name` the attribute) or an attribute of the discipline itself.
pub const DisciplineItem = extern struct { kind: enum(u32) { potential, flow, domain, potential_attr, flow_attr, attr }, name: String, value: Body };

pub const Paramset = extern struct { name: String, module: String, body: Body };

/// A UDP: `ports` its header names, `body` its `io`s, `init` an `initial`
/// `store`, `rows` each table entry's symbols without white space.
pub const Primitive = extern struct { name: String, flags: packed struct(u32) { sequential: bool, _: u31 = 0 }, ports: List(String), body: Body, init: Body, rows: List(String) };

pub const ConnectRules = extern struct { name: String, body: Body };
/// `connect d {, d} resolveto r|exclude ;`.
pub const ConnectResolve = extern struct { flags: packed struct(u32) { exclude: bool, _: u31 = 0 }, disciplines: List(String), result: String };
/// `connect module [merged|split] [#(params)] [[dir] a, [dir] b] ;`.
pub const ConnectInsert = extern struct {
    module: String,
    flags: packed struct(u32) { merged: bool, split: bool, a_dir: Direction, b_dir: Direction, _: u26 = 0 },
    params: List(Arg),
    a: String,
    b: String,
};

/// IEEE 1364-2005 §13.3: `design` cells and the rules, as written.
pub const Config = extern struct { name: String, design: List(String), rules: List(String) };

/// Returns how `tag`'s `Data` reads.
pub fn dataKind(tag: Tag) DataKind {
    return switch (tag) {
        .deassign, .release, .trigger, .disable, .ret, .brk, .cont, .delay_ctl, .event_ctl, .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .port_branch, .posedge, .negedge, .driver_update => .un_node,
        .str_ref, .paramset_output => .str_tok,
        .decl_ref => .decl_tok,
        .int => .int,
        .real => .float,
        .str => .str,
        inline else => |t| if (Payload(t) == void) unreachable else .pl_node,
    };
}

/// The payload a `pl_node` tag's `payload_index` points at; `void` for the
/// tags whose `Data` holds everything.
pub fn Payload(comptime tag: Tag) type {
    return switch (tag) {
        .module => Module,
        .nature => Nature,
        .discipline => Discipline,
        .paramset => Paramset,
        .primitive => Primitive,
        .connectrules => ConnectRules,
        .config => Config,
        .port => Port,
        .io => Io,
        .net => Net,
        .variable => Variable,
        .param => Param,
        .aliasparam => Aliasparam,
        .genvar, .event => Name,
        .branch => Branch,
        .instance => Instance,
        .assign, .defparam => Assign,
        .analog, .analog_initial, .initial, .always, .specify => Process,
        .function => Function,
        .gen_for => GenFor,
        .gen_if => GenIf,
        .gen_case => GenCase,
        .gen_block => GenBlock,
        .path => Path,
        .timing_check => TimingCheck,
        .pulse_style => PulseStyle,
        .timing_event => TimingEvent,
        .ps_override => Override,
        .connect_resolve => ConnectResolve,
        .connect_insert => ConnectInsert,
        .block => Block,
        .condbr => CondBr,
        .case => Case,
        .loop => Loop,
        .repeat => Repeat,
        .wait => Wait,
        .delay => Delay,
        .event_wait => EventWait,
        .store, .store_nb, .contrib, .proc_assign, .force, .repeat_ctl, .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ashl, .ashr, .lt, .gt, .lte, .gte, .eq, .neq, .case_eq, .case_neq, .bit_and, .bit_or, .bit_xor, .bit_xnor, .bool_and, .bool_or, .elem, .replicate, .pattern_repl, .event_or, .range, .pulse_limits => Bin,
        .store_timed, .store_nb_timed => Timed,
        .contrib_indirect, .ternary, .mintypmax, .slice, .slice_up, .slice_down => Triple,
        .field => Field,
        .call => Call,
        .call_sys => SysCall,
        .concat, .pattern => Refs,
        .big_int => BigInt,
        .step_event => StepEvent,
        .deassign, .release, .trigger, .disable, .ret, .brk, .cont, .delay_ctl, .event_ctl, .decl_ref, .str_ref, .int, .real, .str, .pos, .neg, .not, .bit_not, .red_and, .red_nand, .red_or, .red_nor, .red_xor, .red_xnor, .port_branch, .posedge, .negedge, .driver_update, .paramset_output => void,
    };
}

comptime {
    for (.{ Module, Io, Net, Variable, Param, Instance, Function, Path, Bin, Triple }) |T| assert(@sizeOf(T) % 4 == 0);
    assert(@sizeOf(Bin) == 8);
}
