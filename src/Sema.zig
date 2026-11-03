//! Elaboration, the cross-unit half of Zig's Sema for Verilog-AMS: every
//! file's `Vir` in a `Zcu` and a `Config` in; the `Zcu`'s namespace,
//! instance tree, defparams and failures out. One elaborator for analog
//! and digital designs. Nothing is cloned: an instance is a key (module,
//! folded parameters) and its module's Vir is re-read under that key, as
//! Zig instantiates a generic function (InternPool `GetFuncInstanceKey`).
//! The spine, one pass over a table each: the namespace (`namespace`),
//! the roots (`pickRoots`), the instance walk (`walk.zig`: overrides,
//! defparams, generate schemes, instance arrays).
//! Cites: VAMS-2023 §6.2.2, §6.3, §6.4, §6.6, §7.6; IEEE 1364-2005 §12.1.1,
//! §12.8.1, §13.2.1.1.
//!
//! Contents:
//! - `pub const Config = struct` (`Roots`, `Override`)
//! - `pub fn elaborate(zcu: *Zcu, config: Config) Allocator.Error!void`
//! - `pub fn fail(s: *Sema, code: Diag.Code, file: Zcu.File.Index, src: Vir.Inst.Ref, comptime fmt: []const u8, args: anytype) Allocator.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Zcu = @import("Zcu.zig");
const walk = @import("Sema/walk.zig");
const paramset = @import("Sema/paramset.zig");
const Vir = vams.Vir;
const Diag = vams.Diag;
const Inst = Vir.Inst;

zcu: *Zcu,
gpa: Allocator,
/// Scratch that lives for one `elaborate`.
arena: Allocator,
config: Config,

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
    const roots = try pickRoots(&s);
    try walk.run(&s, roots);
    assert(zcu.instances.len >= roots.len);
}

/// Appends a diagnostic to `zcu.failed`.
pub fn fail(s: *Sema, code: Diag.Code, file: Zcu.File.Index, src: Inst.Ref, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const text = try std.fmt.allocPrint(s.arena, fmt, args);
    const message = try s.zcu.intern_pool.getString(s.gpa, text);
    const before = s.zcu.failed.len;
    try s.zcu.failed.append(s.gpa, .{ .code = code, .file = file, .src = src, .message = message });
    assert(s.zcu.failed.len == before + 1);
}

// ---- private ----

/// IEEE 1364-2005 §13.3.1.1: a configuration's `design` statement names
/// the top-level cells (`lib.cell` or `cell`). Appends them to `roots` and
/// returns true when the design has a configuration naming any.
/// ponytail: the first configuration's cells; its `cell`/`instance` rules
/// and the library map (§13.2) do not bind yet.
fn configRoots(s: *Sema, roots: *std.ArrayList(Zcu.Decl)) Allocator.Error!bool {
    const zcu = s.zcu;
    for (0..zcu.files.len) |f| {
        const vir = zcu.fileVir(@fromBackingInt(@intCast(f)));
        for (vir.decls()) |d| {
            if (d.kind != .config) continue;
            const c = vir.extraData(Inst.Config, vir.instructions.items(.data)[@backingInt(d.inst)].pl_node.payload_index);
            for (vir.list(Vir.String, c.design)) |cell| {
                const text = vir.string(cell);
                const bare = if (std.mem.findScalarLast(u8, text, '.')) |dot| text[dot + 1 ..] else text;
                const m = zcu.modules.get(try zcu.intern_pool.getString(s.gpa, bare)) orelse continue;
                try roots.append(s.arena, m);
            }
            return roots.items.len != 0;
        }
    }
    return false;
}

/// Fills `modules` (the last unit of each name wins, IEEE 1364-2005
/// §13.2.1.1) and `paramsets` (all, in order), in file then source order.
fn namespace(s: *Sema) Allocator.Error!void {
    const zcu = s.zcu;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| {
            const decl: Zcu.Decl = .{ .file = file, .index = @fromBackingInt(@intCast(k)) };
            switch (d.kind) {
                .module, .macromodule, .connectmodule, .primitive => {
                    const name = try zcu.intern_pool.getString(s.gpa, vir.string(d.name));
                    try zcu.modules.put(s.gpa, name, decl);
                },
                .paramset => try zcu.paramsets.append(s.gpa, decl),
                .nature, .discipline, .connectrules, .config => {},
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
