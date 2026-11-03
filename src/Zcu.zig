//! The Verilog-AMS compilation unit (Zig's `src/Zcu.zig`): what was
//! analysed, from where, and what failed. The files' `Vir` in (borrowed);
//! out, the tables Sema's elaboration writes: the design-unit namespace
//! (`modules`, `paramsets`), the elaborated instance tree (`instances`,
//! deduplicated by `Instance.Key` in `instance_map`, as Zig keys a generic
//! instance by its comptime arguments), the defparams that took effect and
//! the coded failures. Every value and name is an `InternPool` index.
//!
//! The data, by `data-oriented-design`'s six questions:
//! 1. In: one `Vir` per file. Out: one row per elaborated instance.
//! 2. Thousands of instances in a large design; a handful of files.
//! 3. Every handle is a `u32` (`File.Index`, `Instance.Index`,
//!    `Vir.Decl.Index`, `InternPool.Index`); 2^32 rows is far above any
//!    design (`instances_max`).
//! 4. Instances are appended in depth-first preorder and read by column
//!    (`items(.parent)` to render a path, `items(.module)` to analyse).
//! 5. One compilation: the tables live until `deinit`.
//! 6. Rows are written by one elaboration pass; per-instance analysis
//!    (`Instance.Key`) is the parallel unit (lib/TODO.md §3).
//! Cites: VAMS-2023 §6.2.2 (the instance tree), §6.3 (parameters), §6.4
//! (paramsets); IEEE 1364-2005 §12.4.3 (generate scope names), §13.2.1.1
//! (the last cell of a name).
//!
//! Contents:
//! - fields `gpa`, `intern_pool`, `files`, `modules`, `paramsets`, `disciplines`, `natures`, `instances`, `instance_map`, `ports`, `defparams`, `net_discipline`, `inserts`, `failed`
//! - `pub const File` (`File.Index`), `pub const Decl` (`none`), `pub const Instance` (`Index`, `Key`), `pub const Port`, `pub const Defparam`, `pub const NetKey`, `pub const Insert`, `pub const Failure`
//! - `pub const SystemParam` (`fromName`, `initial`, `allows`, `domain`), `pub const Hier`, `pub const PathFormatter`
//! - `pub const instances_max: u32`
//! - `pub fn init(gpa: Allocator) Allocator.Error!Zcu`
//! - `pub fn deinit(zcu: *Zcu) void`
//! - `pub fn addFile(zcu: *Zcu, path: []const u8, vir: Vir, builtins: u32) Allocator.Error!File.Index`
//! - `pub fn fileVir(zcu: *const Zcu, file: File.Index) *const Vir`
//! - `pub fn declRow(zcu: *const Zcu, d: Decl) Vir.Decl`
//! - `pub fn isBuiltin(zcu: *const Zcu, d: Decl) bool`
//! - `pub fn fmtPath(zcu: *const Zcu, i: Instance.Index) PathFormatter` (`PathFormatter.format`)
//! - `pub fn hasCode(zcu: *const Zcu, code: Diag.Code) bool`
//! - `pub fn answerData(zcu: *Zcu, bytes: ?[]const u8) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Vir = vams.Vir;
const Diag = vams.Diag;

gpa: Allocator,
intern_pool: InternPool,
files: std.MultiArrayList(File) = .empty,
/// IEEE 1364-2005 §13.2.1.1: a name's last module, macromodule,
/// connectmodule or UDP in file then source order.
modules: std.AutoArrayHashMapUnmanaged(InternPool.String, Decl) = .empty,
/// §6.4: every paramset in file then source order; several may share a
/// name (§6.4.2 chooses among them per instance).
paramsets: std.ArrayList(Decl) = .empty,
/// §3.6.2: each discipline and nature name's last declaration (the Annex D
/// prelude's come first, so a source's own wins).
disciplines: std.AutoArrayHashMapUnmanaged(InternPool.String, Decl) = .empty,
natures: std.AutoArrayHashMapUnmanaged(InternPool.String, Decl) = .empty,
/// The elaborated instance tree, depth-first preorder: each root, then its
/// descendants before the next root.
instances: std.MultiArrayList(Instance) = .empty,
/// The first instance of each key: the one a per-instance analysis runs on.
instance_map: std.AutoHashMapUnmanaged(Instance.Key, Instance.Index) = .empty,
/// §6.2.2 every instance's port bindings: a run per instance
/// (`Instance.ports`), one row per port of its module in declaration order.
ports: std.MultiArrayList(Port) = .empty,
/// §6.3.1: every defparam that set a parameter, by the instance and the
/// parameter's name, to the value it set.
defparams: std.AutoArrayHashMapUnmanaged(Defparam, InternPool.Index) = .empty,
/// Annex F: the discipline every port-connected net of every instance
/// resolved to (declared, or from the segments below it), by name.
net_discipline: std.AutoHashMapUnmanaged(NetKey, InternPool.String) = .empty,
/// §7.8.4 every port a connect module was inserted on: the bridge takes
/// the port's upper connection, the port the bridge's other port.
inserts: std.MultiArrayList(Insert) = .empty,
/// Every diagnostic elaboration raised, in the order raised.
failed: std.MultiArrayList(Failure) = .empty,
/// §9.21/§4.6.4.3 the data files the analysis asked for, by the name the
/// source writes, to the caller's answer: the bytes (borrowed until
/// `deinit`), or null for "not there". Keys on `gpa`.
data_files: std.StringHashMapUnmanaged(?[]const u8) = .empty,
/// The data file the last `Sema.analyze` stopped on, on `gpa`, until
/// `answerData`.
data_want: ?[]const u8 = null,

/// One source file's analysis: its path and its Vir, which the caller
/// owns and keeps alive as long as the `Zcu`.
pub const File = struct {
    path: []const u8,
    vir: Vir,
    /// Annex E: the declaration-table rows before this one that are modules
    /// are shipped (Table E.1's primitives, a SPICE netlist's
    /// subcircuits): they may be instantiated but are never a root, and a
    /// user paramset of the same name shadows one.
    builtin_end: u32,

    pub const Index = enum(u32) { _ };
};

/// A design unit: a row of one file's declaration table.
pub const Decl = extern struct {
    file: File.Index,
    index: Vir.Decl.Index,

    /// No unit.
    pub const none: Decl = .{ .file = @fromBackingInt(std.math.maxInt(u32)), .index = @fromBackingInt(std.math.maxInt(u32)) };
};

/// One elaborated instance (a row of `instances`): a module analysed with
/// one tuple of parameter values, as Zig instantiates a generic function
/// once per tuple of comptime arguments.
pub const Instance = struct {
    /// The module (or UDP) analysed; for a paramset instance, the module at
    /// the end of its chain.
    module: Decl,
    /// `.none` for a root.
    parent: Index,
    /// A root's module name; else the path below the parent, generate
    /// scopes and array index included (`g1.blk[2].u[0]`).
    name: InternPool.String,
    /// The module's parameters in declaration order, folded with every
    /// override, defparam and paramset statement applied: an `aggregate`
    /// with no type. An unfoldable value is `InternPool.Index.undef`.
    params: InternPool.Index,
    /// §6.4.2's selected paramset, or `Decl.none`.
    paramset: Decl,
    /// The `instance` instruction in the parent's file; none for a root.
    src: Vir.Inst.Ref,
    /// §9.18 Table 9-29: each hierarchical system parameter's value here,
    /// its specified value composed with the parent's.
    hier: Hier,
    /// Its rows of `ports`; empty for a root.
    ports: Vir.List(Port),

    pub const Index = enum(u32) { none = std.math.maxInt(u32), _ };

    /// What makes two instances one analysis.
    pub const Key = struct { module: Decl, params: InternPool.Index };
};

/// One §6.2.2 port binding: the port as the child's module declares it
/// (an `io` of an ANSI header, a `port` of another) and the connection the
/// instance gives it in the parent's file, none when it leaves the port
/// unconnected (a blank, or not mentioned).
pub const Port = struct { formal: Vir.Inst.Index, actual: Vir.Inst.Ref };

/// One §9.18 Table 9-29 hierarchical system parameter; the tag is its
/// spelling without the `$` (§6.3.6 names exactly these six).
pub const SystemParam = enum(u8) {
    angle,
    hflip,
    mfactor,
    vflip,
    xposition,
    yposition,

    /// The kind `spelling` (`$` included) names, or null.
    pub fn fromName(spelling: []const u8) ?SystemParam {
        if (spelling.len == 0 or spelling[0] != '$') return null;
        return std.meta.stringToEnum(SystemParam, spelling[1..]);
    }

    /// The value of an instance nothing sets: the identity of the kind's
    /// composition (0 for the sums, 1 for the products).
    pub fn initial(k: SystemParam) f64 {
        const v: f64 = switch (k) {
            .angle, .xposition, .yposition => 0.0,
            .hflip, .mfactor, .vflip => 1.0,
        };
        assert(k.allows(v));
        return v;
    }

    /// Whether `v` is in Table 9-29's domain for the kind; a NaN is in no
    /// constrained domain.
    pub fn allows(k: SystemParam, v: f64) bool {
        return switch (k) {
            .angle => v >= 0.0 and v < 360.0,
            .hflip, .vflip => v == 1.0 or v == -1.0,
            .mfactor => v > 0.0,
            .xposition, .yposition => true,
        };
    }

    /// The domain `allows` checks, worded for a diagnostic.
    pub fn domain(k: SystemParam) []const u8 {
        return switch (k) {
            .angle => "0 <= $angle < 360",
            .hflip => "$hflip = +1 or -1",
            .mfactor => "$mfactor > 0",
            .vflip => "$vflip = +1 or -1",
            .xposition, .yposition => "any value",
        };
    }
};

/// An instance's six hierarchical system parameter values (real
/// constants, or `undef` where a specified value does not fold).
pub const Hier = std.EnumArray(SystemParam, InternPool.Index);

/// A §6.3.1 defparam's target: an instance and one of its parameters.
pub const Defparam = struct { instance: Instance.Index, name: InternPool.String };

/// A net of an instance, by name.
pub const NetKey = struct { instance: Instance.Index, net: InternPool.String };

/// One §7.8.4 insertion: port `port` (a header port of the instance's
/// module) of `instance`, re-pointed at the connect-module instance
/// `bridge`, a child of `instance`'s parent. For a §7.8.5.1 primitive
/// terminal, `instance` is the one whose module holds the primitive,
/// `port` its `instance` instruction, `terminal` the terminal's position,
/// and the bridge `instance`'s child.
pub const Insert = struct { instance: Instance.Index, port: Vir.Inst.Index, bridge: Instance.Index, terminal: u32 = 0 };

/// One diagnostic: its code, the file and instruction it is about (none
/// when it is about the design as a whole) and its message.
pub const Failure = struct {
    code: Diag.Code,
    file: File.Index,
    src: Vir.Inst.Ref,
    message: InternPool.String,
};

/// `fmtPath`'s value; print it with `{f}`.
pub const PathFormatter = struct {
    zcu: *const Zcu,
    instance: Instance.Index,

    /// Writes the path, outermost name first.
    pub fn format(p: PathFormatter, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const parents = p.zcu.instances.items(.parent);
        const names = p.zcu.instances.items(.name);
        var depth: u32 = 0;
        var it = p.instance;
        while (it != .none) : (it = parents[@backingInt(it)]) depth += 1;
        assert(depth >= 1);
        // ponytail: one walk up per level, quadratic in depth; a stack of
        // indexes if paths ever print on a hot path.
        var level = depth;
        while (level > 0) : (level -= 1) {
            it = p.instance;
            for (1..level) |_| it = parents[@backingInt(it)];
            if (level != depth) try w.writeByte('.');
            try w.writeAll(p.zcu.intern_pool.stringToSlice(names[@backingInt(it)]));
        }
    }
};

/// The most instances one design elaborates to; past it the walk stops
/// with E0905 (a runaway recursive instantiation).
pub const instances_max: u32 = 1 << 24;

comptime {
    // A hot row, read by column: two unit handles, three indexes, one ref.
    assert(@sizeOf(Decl) == 8);
    assert(2 * @sizeOf(Decl) + 6 * 4 + @sizeOf(Hier) == @sizeOf(Instance));
    assert(@sizeOf(Port) == 8);
}

const Zcu = @This();

/// Returns an empty unit. The caller frees it with `deinit`.
pub fn init(gpa: Allocator) Allocator.Error!Zcu {
    assert(@sizeOf(Instance) != 0);
    return .{ .gpa = gpa, .intern_pool = try .init(gpa) };
}

/// Frees every table; the files' Vir stay the caller's.
pub fn deinit(zcu: *Zcu) void {
    assert(zcu.instance_map.count() <= zcu.instances.len);
    const gpa = zcu.gpa;
    zcu.intern_pool.deinit(gpa);
    zcu.files.deinit(gpa);
    zcu.modules.deinit(gpa);
    zcu.paramsets.deinit(gpa);
    zcu.disciplines.deinit(gpa);
    zcu.natures.deinit(gpa);
    zcu.instances.deinit(gpa);
    zcu.instance_map.deinit(gpa);
    zcu.ports.deinit(gpa);
    zcu.defparams.deinit(gpa);
    zcu.net_discipline.deinit(gpa);
    zcu.inserts.deinit(gpa);
    zcu.failed.deinit(gpa);
    var it = zcu.data_files.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    zcu.data_files.deinit(gpa);
    if (zcu.data_want) |w| gpa.free(w);
    zcu.* = undefined;
}

/// Answers `data_want` with the file's bytes (borrowed until `deinit`), or
/// null for "not there"; `Sema.analyze` then runs again. Asserts a pending
/// request.
pub fn answerData(zcu: *Zcu, bytes: ?[]const u8) Allocator.Error!void {
    const name = zcu.data_want.?;
    try zcu.data_files.putNoClobber(zcu.gpa, name, bytes);
    zcu.data_want = null;
    assert(zcu.data_files.contains(name));
}

/// Adds a file whose first `builtins` modules are shipped; `vir` is
/// borrowed and must outlive the unit. Asserts that the file has at least
/// `builtins` modules.
pub fn addFile(zcu: *Zcu, path: []const u8, vir: Vir, builtins: u32) Allocator.Error!File.Index {
    var modules: u32 = 0;
    var end: u32 = 0;
    for (vir.decls(), 0..) |d, k| {
        if (modules == builtins) break;
        if (d.kind != .module) continue;
        modules += 1;
        end = @intCast(k + 1);
    }
    assert(modules == builtins);
    const index: File.Index = @fromBackingInt(@intCast(zcu.files.len));
    try zcu.files.append(zcu.gpa, .{ .path = path, .vir = vir, .builtin_end = end });
    assert(@backingInt(index) + 1 == zcu.files.len);
    return index;
}

/// The Vir of `file`. Asserts that the file exists.
pub fn fileVir(zcu: *const Zcu, file: File.Index) *const Vir {
    assert(zcu.files.items(.vir).len == zcu.files.len);
    assert(@backingInt(file) < zcu.files.len);
    return &zcu.files.items(.vir)[@backingInt(file)];
}

/// The declaration-table row `d` names. Asserts that it exists.
pub fn declRow(zcu: *const Zcu, d: Decl) Vir.Decl {
    const rows = zcu.fileVir(d.file).decls();
    assert(@backingInt(d.index) < rows.len);
    return rows[@backingInt(d.index)];
}

/// Whether `d` is a shipped module (`File.builtin_end`).
pub fn isBuiltin(zcu: *const Zcu, d: Decl) bool {
    assert(@backingInt(d.file) < zcu.files.len);
    return @backingInt(d.index) < zcu.files.items(.builtin_end)[@backingInt(d.file)] and zcu.declRow(d).kind == .module;
}

/// Renders an instance's hierarchical name, its root's module name first
/// (`top.u1.g.u2`), on demand: no instance stores its path.
pub fn fmtPath(zcu: *const Zcu, i: Instance.Index) PathFormatter {
    assert(@backingInt(i) < zcu.instances.len);
    return .{ .zcu = zcu, .instance = i };
}

/// Whether elaboration raised `code`.
pub fn hasCode(zcu: *const Zcu, code: Diag.Code) bool {
    assert(zcu.failed.len == zcu.failed.items(.code).len);
    return std.mem.findScalar(Diag.Code, zcu.failed.items(.code), code) != null;
}
