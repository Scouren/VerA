//! IEEE 1364-2005 §13 binding under a library map: each design unit's
//! library (`Zcu.decl_lib`), the search order (`Zcu.lib_order`) and the
//! root configuration's rules in; each library's cells under `lib.cell`
//! keys of `Zcu.modules` (a plain name the search order's first), the
//! configured roots, and the cell each instance binds out, with the
//! context (§13.3.1.5's inherited library list) its own children bind
//! under. lib/sim/digital's `bind.zig` is the behaviour spec.
//! Cites: IEEE 1364-2005 §13.2.1.1, §13.2.3, §13.3.1.1 to §13.3.1.6,
//! §13.3.2, §13.5.1.
//!
//! Contents:
//! - `pub const ConfigRef = struct`, `pub const Ctx = struct`
//! - `pub fn index(s: *Sema) Allocator.Error!void`
//! - `pub fn roots(s: *Sema, configs: []const ConfigRef, root: u32, out: *std.ArrayList(Zcu.Decl)) Allocator.Error!void`
//! - `pub fn rootTarget(s: *Sema, d: Zcu.Decl, name: InternPool.String) Allocator.Error!InternPool.String`
//! - `pub fn bind(s: *Sema, parent: Zcu.Instance.Index, name: InternPool.String, target: InternPool.String) Allocator.Error!InternPool.String`
//! - `pub fn rootConfig(s: *Sema, configs: []const ConfigRef) Allocator.Error!?u32`
//! - `pub fn ruleWords(s: *Sema, text: []const u8) Allocator.Error![]const []const u8`
//! - `pub fn cellOf(text: []const u8) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const InternPool = @import("intern_pool");
const Sema = @import("../Sema.zig");
const Zcu = @import("../Zcu.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// A configuration: its Vir, its payload and its declaration.
pub const ConfigRef = struct { vir: *const Vir, c: Inst.Config, decl: Zcu.Decl };

/// What an instance's children bind under: the configuration whose rules
/// apply (`null`: the search order), the instance's §13.3.1.3 name from
/// that configuration's top cell, and §13.3.1.5's library list inherited
/// downward (null or empty: the parent cell's library).
pub const Ctx = struct {
    cfg: ?u32 = null,
    path: []const u8 = "",
    liblist: ?[]const []const u8 = null,
};

/// §13.2.1.1 "the LAST cell encountered shall be written to the library":
/// each module's `lib.cell` key; then each plain name to the first library
/// of the §13.5.1 search order that holds it.
pub fn index(s: *Sema) Allocator.Error!void {
    const zcu = s.zcu;
    assert(zcu.decl_lib.count() != 0);
    var names: std.AutoArrayHashMapUnmanaged(InternPool.String, void) = .empty;
    for (0..zcu.files.len) |f| {
        const file: Zcu.File.Index = @fromBackingInt(@intCast(f));
        const vir = zcu.fileVir(file);
        for (vir.decls(), 0..) |d, k| switch (d.kind) {
            .module, .macromodule, .connectmodule, .primitive => {
                const decl: Zcu.Decl = .{ .file = file, .index = @fromBackingInt(@intCast(k)) };
                try zcu.modules.put(s.gpa, try key(s, zcu.libraryOf(decl), vir.string(d.name)), decl);
                try names.put(s.arena, try zcu.intern_pool.getString(s.gpa, vir.string(d.name)), {});
            },
            else => {}, // else: no cell of a library
        };
    }
    for (names.keys()) |n| for (zcu.lib_order) |lib| {
        if (zcu.modules.get(try key(s, zcu.intern_pool.stringToSlice(lib), zcu.intern_pool.stringToSlice(n)))) |d| {
            try zcu.modules.put(s.gpa, n, d);
            break;
        }
    };
    assert(zcu.modules.count() >= names.count());
}

/// §13.3.1.1 the root configuration `configs[root]`'s design cells (`lib.cell`,
/// or the configuration's own library when it names none), appended to
/// `out`, each with its context: the configuration and its default list.
pub fn roots(s: *Sema, configs: []const ConfigRef, root: u32, out: *std.ArrayList(Zcu.Decl)) Allocator.Error!void {
    assert(root < configs.len);
    s.lib_configs = configs;
    const cfg = configs[root];
    for (cfg.vir.list(Vir.String, cfg.c.design)) |cell| {
        const d = (try designCell(s, cfg, cfg.vir.string(cell))) orelse continue;
        const name = cellOf(cfg.vir.string(cell));
        try s.lib_ctx.put(s.arena, name, .{ .cfg = root, .path = name, .liblist = try defaultList(s, cfg) });
        try out.append(s.arena, d);
    }
    assert(s.lib_configs.len == configs.len);
}

/// The key a root instance of `d` (named `name`) binds by: its library's
/// `lib.cell` under a library map, else `name`.
pub fn rootTarget(s: *Sema, d: Zcu.Decl, name: InternPool.String) Allocator.Error!InternPool.String {
    assert(name != .empty);
    const zcu = s.zcu;
    if (zcu.decl_lib.count() == 0) return name;
    return key(s, zcu.libraryOf(d), zcu.intern_pool.stringToSlice(name));
}

/// §13.3 the key of the module child `name` of `parent` (an instance of
/// cell `target`) binds to, and the context its own children bind under.
/// A cell no library of its list holds keeps `target` (elaboration reports
/// the undeclared module).
pub fn bind(s: *Sema, parent: Zcu.Instance.Index, name: InternPool.String, target: InternPool.String) Allocator.Error!InternPool.String {
    const zcu = s.zcu;
    assert(zcu.decl_lib.count() != 0);
    const ip = &zcu.intern_pool;
    const at = try std.fmt.allocPrint(s.arena, "{f}", .{zcu.fmtPath(parent)});
    const child_at = try std.fmt.allocPrint(s.arena, "{s}.{s}", .{ at, ip.stringToSlice(name) });
    const up = s.lib_ctx.get(at) orelse Ctx{};
    const cell = ip.stringToSlice(target);
    const ci = up.cfg orelse {
        var order: std.ArrayList([]const u8) = .empty;
        for (zcu.lib_order) |l| try order.append(s.arena, ip.stringToSlice(l));
        return (try search(s, order.items, cell)) orelse target;
    };
    const cfg = s.lib_configs[ci];
    const parent_lib = zcu.libraryOf(zcu.instances.items(.module)[@backingInt(parent)]);
    const path = try std.fmt.allocPrint(s.arena, "{s}.{s}", .{ up.path, ip.stringToSlice(name) });
    // §13.3.1.2 an instance clause names one instance, a cell clause every
    // instance of a cell, the default clause the rest.
    const rule = (try instanceRule(s, cfg, path)) orelse (try cellRule(s, cfg, cell, up.liblist, parent_lib));
    const w = rule orelse {
        try s.lib_ctx.put(s.arena, child_at, .{ .cfg = ci, .path = path, .liblist = up.liblist });
        return (try search(s, try listOr(s, up.liblist, parent_lib), cell)) orelse target;
    };
    if (std.mem.eql(u8, w[2], "liblist")) {
        const list = w[3..];
        try s.lib_ctx.put(s.arena, child_at, .{ .cfg = ci, .path = path, .liblist = list });
        return (try search(s, try listOr(s, list, parent_lib), cell)) orelse target;
    }
    // §13.3.1.6 "If the library name is omitted, the library shall be
    // inherited from the parent cell."
    if (w.len < 4) return target;
    const use = w[3];
    const sub_config = std.mem.endsWith(u8, use, ":config");
    const lib = libOf(use) orelse parent_lib;
    const ucell = cellOf(use);
    if (sub_config or zcu.modules.get(try key(s, lib, ucell)) == null) if (subConfig(s, lib, ucell)) |sub| {
        const sc = s.lib_configs[sub];
        const design = sc.vir.list(Vir.String, sc.c.design);
        if (design.len != 1) return target;
        const top = cellOf(sc.vir.string(design[0]));
        try s.lib_ctx.put(s.arena, child_at, .{ .cfg = sub, .path = top, .liblist = try defaultList(s, sc) });
        const d = (try designCell(s, sc, sc.vir.string(design[0]))) orelse return target;
        return key(s, zcu.libraryOf(d), top);
    };
    // §13.3.1.6 "The use clause has no effect on the current value of the
    // library list."
    try s.lib_ctx.put(s.arena, child_at, .{ .cfg = ci, .path = path, .liblist = up.liblist });
    return key(s, lib, ucell);
}

/// IEEE 1364-2005 §13.4.4 the root configuration, the one no `use
/// ...:config` clause names: its index in `configs`, or null after E0243
/// for none or two. Then §13.3.2 E0243 for an instance clause that names an
/// instance inside a hierarchy another config specifies.
/// ponytail: §13.3.2 is judged on each config's own rules, statically.
pub fn rootConfig(s: *Sema, configs: []const ConfigRef) Allocator.Error!?u32 {
    assert(configs.len != 0);
    var root: ?u32 = null;
    for (configs, 0..) |cfg, k| {
        if (try referenced(s, configs, cfg.vir.string(cfg.c.name))) continue;
        if (root) |r| {
            const why = try std.fmt.allocPrint(s.arena, "configurations `{s}` and `{s}` are both unreferenced, so neither is the design's (IEEE 1364-2005 §13.4.4)", .{ configs[r].vir.string(configs[r].c.name), cfg.vir.string(cfg.c.name) });
            try s.failRule(.{ .rule = .config, .name = why }, .E0243, cfg.decl.file, cfg.vir.decls()[@backingInt(cfg.decl.index)].inst.toRef(), "{s}", .{why});
            return null;
        }
        root = @intCast(k);
    }
    if (root == null) {
        const why = "every configuration is named by another's `use` clause, so none is the design's (IEEE 1364-2005 §13.4.4)";
        try s.failRule(.{ .rule = .config, .name = why }, .E0243, configs[0].decl.file, configs[0].vir.decls()[@backingInt(configs[0].decl.index)].inst.toRef(), "{s}", .{why});
        return null;
    }
    for (configs) |cfg| {
        const rules = cfg.vir.list(Vir.String, cfg.c.rules);
        for (rules) |r| {
            const w = try ruleWords(s, cfg.vir.string(r));
            if (w.len != 4 or !std.mem.eql(u8, w[0], "instance") or !std.mem.eql(u8, w[2], "use") or !std.mem.endsWith(u8, w[3], ":config")) continue;
            for (rules, 0..) |o, k| {
                const ow = try ruleWords(s, cfg.vir.string(o));
                if (ow.len < 2 or !std.mem.eql(u8, ow[0], "instance")) continue;
                const p = ow[1];
                if (p.len <= w[1].len or !std.mem.startsWith(u8, p, w[1]) or p[w[1].len] != '.') continue;
                const why = try std.fmt.allocPrint(s.arena, "instance clause `{s}` names an instance inside `{s}`, whose hierarchy another config (`{s}`) specifies (IEEE 1364-2005 §13.3.2)", .{ p, w[1], cellOf(w[3]) });
                try s.failRule(.{ .rule = .config, .name = why, .part = .{ .rule = @intCast(k) } }, .E0243, cfg.decl.file, cfg.vir.decls()[@backingInt(cfg.decl.index)].inst.toRef(), "{s}", .{why});
                return null;
            }
        }
    }
    return root;
}

/// A rule's words: its tokens (AstGen joins them with spaces) with `.` and
/// `:` glued to their neighbours, so `top . u use work . gate` is `top.u`,
/// `use`, `work.gate`.
pub fn ruleWords(s: *Sema, text: []const u8) Allocator.Error![]const []const u8 {
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
pub fn cellOf(text: []const u8) []const u8 {
    assert(text.len != 0);
    defer assert(text.len != 0);
    const end = std.mem.findScalar(u8, text, ':') orelse text.len;
    const dot = std.mem.findScalarLast(u8, text[0..end], '.');
    return if (dot) |d| text[d + 1 .. end] else text[0..end];
}

// ---- private ----

/// Whether a `use ...:config` clause of any of `configs` names `name`.
fn referenced(s: *Sema, configs: []const ConfigRef, name: []const u8) Allocator.Error!bool {
    for (configs) |other| for (other.vir.list(Vir.String, other.c.rules)) |r| {
        const w = try ruleWords(s, other.vir.string(r));
        if (w.len == 4 and std.mem.eql(u8, w[2], "use") and std.mem.endsWith(u8, w[3], ":config") and std.mem.eql(u8, cellOf(w[3]), name)) return true;
    };
    return false;
}

/// The `Zcu.modules` key of cell `cell` in library `lib`.
// ponytail: `lib.cell` cannot be a simple identifier; an escaped one
// spelling it would share the key.
fn key(s: *Sema, lib: []const u8, cell: []const u8) Allocator.Error!InternPool.String {
    assert(lib.len != 0 and cell.len != 0);
    return s.zcu.intern_pool.getString(s.gpa, try std.fmt.allocPrint(s.arena, "{s}.{s}", .{ lib, cell }));
}

/// `lib.cell[:config]`'s library, or null.
fn libOf(text: []const u8) ?[]const u8 {
    const end = std.mem.findScalar(u8, text, ':') orelse text.len;
    const dot = std.mem.findScalarLast(u8, text[0..end], '.') orelse return null;
    return text[0..dot];
}

/// §13.3.1.5 "the specified library list is searched in the specified
/// order": the key of the first library's `cell`, or null.
fn search(s: *Sema, list: []const []const u8, cell: []const u8) Allocator.Error!?InternPool.String {
    for (list) |lib| {
        const k = try key(s, lib, cell);
        if (s.zcu.modules.contains(k)) return k;
    }
    return null;
}

/// §13.3.1.5 "If no library list clause is selected or if the selected
/// library list is empty, then the library list contains the single name
/// that is the library in which the cell containing the unbound instance is
/// found (i.e., the parent cell's library)."
fn listOr(s: *Sema, list: ?[]const []const u8, parent_lib: []const u8) Allocator.Error![]const []const u8 {
    if (list) |l| if (l.len != 0) return l;
    return s.arena.dupe([]const u8, &.{parent_lib});
}

/// §13.3.1.1 a config's design cell: "If the library identifier is omitted,
/// then the library that contains the config shall be used".
fn designCell(s: *Sema, cfg: ConfigRef, text: []const u8) Allocator.Error!?Zcu.Decl {
    const lib = libOf(text) orelse s.zcu.libraryOf(cfg.decl);
    return s.zcu.modules.get(try key(s, lib, cellOf(text)));
}

/// The `default liblist` clause's libraries, or null.
fn defaultList(s: *Sema, cfg: ConfigRef) Allocator.Error!?[]const []const u8 {
    for (cfg.vir.list(Vir.String, cfg.c.rules)) |r| {
        const w = try ruleWords(s, cfg.vir.string(r));
        if (w.len >= 2 and std.mem.eql(u8, w[0], "default") and std.mem.eql(u8, w[1], "liblist")) return w[2..];
    }
    return null;
}

/// The `instance <path> ...` rule of `cfg` naming `path`, as words.
fn instanceRule(s: *Sema, cfg: ConfigRef, path: []const u8) Allocator.Error!?[]const []const u8 {
    for (cfg.vir.list(Vir.String, cfg.c.rules)) |r| {
        const w = try ruleWords(s, cfg.vir.string(r));
        if (w.len >= 3 and std.mem.eql(u8, w[0], "instance") and std.mem.eql(u8, w[1], path)) return w;
    }
    return null;
}

/// The `cell [lib.]<cell> ...` rule of `cfg` selecting `cell` (§13.3.1.4:
/// with a library, only when the cell would bind from it), as words.
fn cellRule(s: *Sema, cfg: ConfigRef, cell: []const u8, liblist: ?[]const []const u8, parent_lib: []const u8) Allocator.Error!?[]const []const u8 {
    for (cfg.vir.list(Vir.String, cfg.c.rules)) |r| {
        const w = try ruleWords(s, cfg.vir.string(r));
        if (w.len < 3 or !std.mem.eql(u8, w[0], "cell") or !std.mem.eql(u8, cellOf(w[1]), cell)) continue;
        if (libOf(w[1])) |lib| {
            const k = (try search(s, try listOr(s, liblist, parent_lib), cell)) orelse continue;
            if (k != try key(s, lib, cell)) continue;
        }
        return w;
    }
    return null;
}

/// The configuration named `name` in library `lib`, or null.
fn subConfig(s: *Sema, lib: []const u8, name: []const u8) ?u32 {
    for (s.lib_configs, 0..) |c, k| {
        if (std.mem.eql(u8, c.vir.string(c.c.name), name) and std.mem.eql(u8, s.zcu.libraryOf(c.decl), lib)) return @intCast(k);
    }
    return null;
}
