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
//! - `pub fn fail(s: *Sema, code: Diag.Code, file: Zcu.File.Index, src: Vir.Inst.Ref, comptime fmt: []const u8, args: anytype) Allocator.Error!void`
//! - `pub fn bound(s: *Sema, cell: InternPool.String, path: []const u8) InternPool.String`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Zcu = @import("Zcu.zig");
const walk = @import("Sema/walk.zig");
const paramset = @import("Sema/paramset.zig");
const checks = @import("Sema/checks.zig");
const connect = @import("Sema/connect.zig");
const defparam = @import("Sema/defparam.zig");
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
    try checks.run(&s);
    const roots = try pickRoots(&s);
    const waiting = try walk.run(&s, roots);
    try connect.run(&s, waiting);
    try defparam.reportUnused(&s, waiting);
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

/// The cell an instance of `cell` at absolute path `path` binds under the
/// root configuration (§13.3.1.6: an `instance` clause first, then a
/// `cell` clause), else `cell`.
pub fn bound(s: *Sema, cell: InternPool.String, path: []const u8) InternPool.String {
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
    const end = std.mem.findScalar(u8, text, ':') orelse text.len;
    const dot = std.mem.findScalarLast(u8, text[0..end], '.');
    return if (dot) |d| text[d + 1 .. end] else text[0..end];
}

/// Fills `modules` (the last unit of each name wins, IEEE 1364-2005
/// §13.2.1.1; W1152 for a user module defined again), `paramsets` (all, in
/// order), `disciplines` and `natures`, in file then source order.
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
