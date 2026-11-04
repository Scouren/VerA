//! The §18 value change dump rows (VCD and extended VCD) and the §16 SDF
//! annotation rows of a `Program`, re-exported there: what the dump and
//! annotate tasks read, apart from the rows every process runs.
//! Cites: IEEE 1364-2005 §16, §17.2.10, §18.1, §18.3, §18.4.
//!
//! Contents:
//! - `pub const Vcd = struct` (`Vcd.VcdScope`, `Vcd.Var`), `pub const DumpCall = struct`, `pub const DumpOp = enum(u32)`
//! - `pub const EvcdPort = struct`, `pub const PortDir = enum(u8)`, `pub const DumpPorts = struct`, `pub const PortsCall = struct`, `pub const PortsOp = enum(u32)`
//! - `pub const SdfScope = struct`, `pub const SdfCall = struct`

const List = @import("Program.zig").List;

/// §18.1 what a `$dumpvars` can select: per scope its `$scope` line,
/// parent, whether it is lexical and whether it is written as a scope of
/// its own (`child`); its variables `vars[var_start[s]..var_start[s + 1]]`,
/// each with the `$var` text around its code.
pub const Vcd = struct {
    scopes: []const VcdScope = &.{},
    var_start: []const u32 = &.{},
    vars: []const Var = &.{},

    pub const VcdScope = struct { line: List, parent: u32, lexical: bool, child: bool };
    pub const Var = struct { slot: u32, width: u32, real: bool, event: bool, head: List, tail: List };
};

/// §18.1 one dump task call: which, its argument row (`$dumpfile`'s name,
/// `$dumpvars`' levels, `$dumplimit`'s size; `none` when absent), the
/// `$dumpfile` call's text for §18.2.3.8's `$version`, and `$dumpvars`'
/// targets (pairs: 0 and a scope, or 1 and a slot).
pub const DumpCall = struct { op: DumpOp, arg: u32, call: List, targets: List };

/// §18.1's tasks.
pub const DumpOp = enum(u32) { file, vars, off, on, all, limit, flush };

/// §18.3 one dumped port: its slot, the net it is (`none` for a variable),
/// its direction, and its net's drivers inside the dumped instance (its
/// output side) and outside it (its input side), as `drivers` indices.
pub const EvcdPort = struct { slot: u32, net: u32, dir: PortDir, inside: List, outside: List };

/// A §18.4 port's direction.
pub const PortDir = enum(u8) { input, output, inout };

/// §18.3.1 one `$dumpports` call: its file name row (`none`: the default
/// "dumpports.vcd"), the call's text, the header's scope and `$var port`
/// lines, and its ports (a `List` of `evcd_ports` rows).
pub const DumpPorts = struct { name_row: u32, call: List, header: List, ports: List };

/// §18.3 one port dump task: which, its `DumpPorts` (for `.ports`), the
/// file name row it names (`none`: every file) and `$dumpportslimit`'s size.
pub const PortsCall = struct { op: PortsOp, ports: u32, name: u32, size: u32 };

/// §18.3's tasks.
pub const PortsOp = enum(u32) { ports, off, on, all, limit, flush };

/// §16 what an annotation matches per scope: its module's name, whether it
/// is lexical, and its ports and specparams as triples (name start, name
/// length, slot; `none` for an unbound port) in `extra`.
pub const SdfScope = struct { module: List, lexical: bool, ports: List, specparams: List };

/// §17.2.10 one `$sdf_annotate` call: the file name row, the annotation
/// scope, and the mtm_spec row (`none`: TYPICAL).
pub const SdfCall = struct { name: u32, scope: u32, mtm: u32 };
