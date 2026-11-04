//! The jobs before the design exists: the command line's files read, the
//! annex E.2 netlist read, the units preprocessed in command-line order
//! (serial, VAMS §10's macro state carries across them), each text parsed
//! and AstGen'd (one job per text, on a worker), then the elaboration into
//! `Zcu`. Every request a stage raises (`include, `.INCLUDE`/`.LIB`/`.HDL`)
//! is answered by `Compilation.read`. Each job returns whether its
//! successors may run; what stopped it is in the diagnostics or
//! `Compilation.outputs`.
//!
//! Cites: VAMS-2023 §10 (`include, `define), annex E.2 (the netlist);
//! IEEE 1364-2005 §13.4.1 (the units' order), §28 (`--protect-keys`).
//!
//! Contents:
//! - `pub fn readInputs(comp: *Compilation) !bool`
//! - `pub fn spice(comp: *Compilation) !bool`
//! - `pub fn preprocess(comp: *Compilation) !bool`
//! - `pub fn astgen(comp: *Compilation, unit: u32, failed: *std.atomic.Value(bool), oom: *std.atomic.Value(bool)) void`
//! - `pub fn semaTop(comp: *Compilation) !bool`
//! - `pub fn notBuilt(comp: *Compilation, b: Compilation.Backend, what: []const u8) !void`
//! - `pub const requests_max: u32`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const sema = @import("sema");
const InternPool = @import("intern_pool");
const bench = @import("codegen").bench;
const Compilation = @import("../Compilation.zig");
const Zcu = sema.Zcu;

/// Most file requests one reader raises before the compilation gives up
/// on it: each answer is a distinct path, so past this the input names
/// more files than any design (the preprocessor's own `files_max`).
pub const requests_max: u32 = vams.Preprocessor.files_max;

/// The SPICE netlist unit's name, as `__FILE__` and a diagnostic print it.
const netlist_unit = "spice_netlist.vams";

/// Reads every input and the `--protect-keys` file. A source that cannot
/// be read is the old driver's line and status: 2 for the compiled one,
/// 1 for a `.v` library unit after it.
pub fn readInputs(comp: *Compilation) !bool {
    const c = comp.config;
    assert(c.paths.len != 0);
    if (c.libmaps.len != 0 or c.search.len != 0) {
        try notBuilt(comp, .libmap, "--libmap and -L (IEEE 1364-2005 §13.2 library maps)");
        return false;
    }
    for (c.paths, 0..) |p, k| switch (try comp.read(p)) {
        .bytes => {},
        .failed => |e| {
            try readFailed(comp, p, e);
            comp.outputs.status = if (k == 0) 2 else 1;
            return false;
        },
    };
    if (c.protect_keys) |p| {
        const text = switch (try comp.read(p)) {
            .bytes => |b| b,
            .failed => |e| {
                try readFailed(comp, p, e);
                comp.outputs.status = 1;
                return false;
            },
        };
        comp.pp.options.protect_keys = vams.Preprocessor.protect.parseKeys(comp.arena(), text) catch |e| {
            try comp.outputs.err.print(comp.arena(), "error: --protect-keys {s}: not a key file ({t})\n", .{ p, e });
            comp.outputs.status = 1;
            return false;
        };
    }
    // The testbench's `//!` directives, read up front as the old spine
    // does: a malformed one refuses before anything is analysed.
    if ((c.target == .exe or c.target == .run) and !c.digital()) {
        comp.bench = bench.Spec.parse(comp.arena(), (try comp.read(c.paths[0])).bytes, null) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try comp.outputs.err.print(comp.arena(), "error: {s}: `//!` directive: {t}\n", .{ c.paths[0], e });
            comp.outputs.status = 2;
            return false;
        };
    }
    // E.1.1: without `--spice`, a testbench's own `//! spice` cards are the
    // netlist, read beside the source (the old spine's `harness.spice`).
    if (c.spice_path == null and (c.target == .exe or c.target == .run) and !c.digital()) {
        const cards = try spiceCards(comp.arena(), (try comp.read(c.paths[0])).bytes);
        if (cards.len != 0) comp.netlist = .init(comp.gpa, c.paths[0], cards);
    }
    return true;
}

/// Annex E.2: reads the netlist (`--spice`'s file, or the `//! spice`
/// cards), answering its `.INCLUDE`/`.LIB` requests. A refusal stops the
/// compilation (reported by `errors`).
pub fn spice(comp: *Compilation) !bool {
    if (comp.netlist == null) {
        const path = comp.config.spice_path.?;
        const text = switch (try comp.read(path)) {
            .bytes => |b| b,
            .failed => |e| {
                try readFailed(comp, path, e);
                comp.outputs.status = 2;
                return false;
            },
        };
        comp.netlist = .init(comp.gpa, path, text);
    }
    const n = &comp.netlist.?;
    var asked: u32 = 0;
    while (try n.run()) |req| : (asked += 1) {
        if (asked == requests_max) return error.OutOfMemory;
        switch (req) {
            .file => |want| try n.answer(switch (try comp.read(want.path)) {
                .bytes => |b| b,
                .failed => |e| e,
            }),
        }
    }
    return n.output().refusals.len == 0;
}

/// Preprocesses the units in command-line order: the netlist's modules
/// first (they are built in), then each input, then each `.HDL` source.
/// Answers every `include request; an error ends it.
pub fn preprocess(comp: *Compilation) !bool {
    const pp = &comp.pp;
    if (comp.netlist) |*n| {
        const out = n.output();
        if (out.modules != 0) try pp.addUnit(netlist_unit, out.text);
    }
    for (comp.config.paths) |p| try pp.addUnit(p, (try comp.read(p)).bytes);
    if (comp.netlist) |*n| for (n.output().hdl) |p| switch (try comp.read(p)) {
        .bytes => |b| try pp.addUnit(p, b),
        .failed => |e| {
            try readFailed(comp, p, e);
            comp.outputs.status = 2;
            return false;
        },
    };
    var asked: u32 = 0;
    while (try pp.run()) |req| : (asked += 1) {
        if (asked == requests_max) return error.OutOfMemory;
        switch (req) {
            .file => |want| try pp.answer(switch (try comp.read(want.path)) {
                .bytes => |b| b,
                .failed => null,
            }),
        }
    }
    const out = pp.output();
    if (out.failed) return false;
    // ponytail: one unit per compilation. The preprocessor writes one text
    // whose directive events are positions in it; a unit per input waits
    // for `Directives` per unit (docs/rewrite/comp.md, "decisions").
    try comp.units.append(comp.gpa, .{ .text = try comp.arena().dupeSentinel(u8, out.text, 0), .tree = undefined, .vir = undefined, .builtins = 0 });
    assert(comp.units.items.len == 1);
    return true;
}

/// Parse and AstGen of `units[unit]`, on a worker: a parse error sets
/// `failed` (the tree's errors are reported), running out of memory `oom`.
pub fn astgen(comp: *Compilation, unit: u32, failed: *std.atomic.Value(bool), oom: *std.atomic.Value(bool)) void {
    astgenUnit(comp, unit) catch {
        oom.store(true, .monotonic);
        return;
    } orelse failed.store(true, .monotonic);
}

/// Elaborates the units: a device has one root (VAMS §6.2.2), a `.v`
/// simulation every uninstantiated module (IEEE 1364-2005 §12.1.1).
/// Stops on an AstGen or elaboration error.
pub fn semaTop(comp: *Compilation) !bool {
    for (comp.units.items) |*u| {
        if (u.vir.diag.failed()) return false;
        _ = try comp.zcu.addFile(comp.config.paths[0], u.vir, u.builtins);
    }
    const overrides = try comp.arena().alloc(sema.Sema.Config.Override, comp.config.overrides.len);
    const ip = &comp.zcu.intern_pool;
    for (overrides, comp.config.overrides) |*o, typed| o.* = .{
        .name = typed.name,
        .value = if (std.math.isNan(typed.value))
            try ip.get(comp.gpa, .{ .str = try ip.getString(comp.gpa, typed.text) })
        else
            try ip.get(comp.gpa, .{ .float = typed.value }),
    };
    try sema.Sema.elaborate(&comp.zcu, .{ .roots = if (comp.config.digital()) .all else .first, .overrides = overrides });
    for (comp.zcu.failed.items(.code)) |code| if (severity(comp, code) == .err) return false;
    return comp.zcu.instances.len != 0;
}

/// Writes the "not built" refusal for `b` and sets `not_built_status`: the fixture
/// needs a backend `vera-next` does not have yet.
pub fn notBuilt(comp: *Compilation, b: Compilation.Backend, what: []const u8) !void {
    assert(comp.outputs.not_built == null);
    try comp.outputs.err.print(comp.arena(), "error: {s}: {s} is not built in vera-next yet (backend `{t}`)\n", .{ comp.config.paths[0], what, b });
    comp.outputs.not_built = b;
    comp.outputs.status = Compilation.not_built_status;
}

// ---- private ----

fn astgenUnit(comp: *Compilation, unit: u32) Allocator.Error!?void {
    const gpa = comp.gpa;
    const u = &comp.units.items[unit];
    u.tree = try vams.Ast.parse(gpa, u.text, .{ .keywords = comp.config.language });
    u.vir = .{ .instructions = .empty, .extra = &.{}, .string_bytes = &.{}, .diag = .empty };
    if (u.tree.errors.len != 0) return null;
    u.vir = try vams.AstGen.generate(gpa, &u.tree, .{ .directives = comp.pp.output().directives, .language = comp.config.language });
    u.builtins = builtinModules(comp, u);
}

/// The leading modules of `u` that come from shipped text: Table E.1's
/// primitives and the netlist's subcircuits (annex E.2).
fn builtinModules(comp: *const Compilation, u: *const Compilation.Unit) u32 {
    const out = comp.pp.output();
    var n: u32 = 0;
    for (u.vir.decls()) |d| {
        if (d.kind != .module) continue;
        const data = u.vir.instructions.items(.data)[@backingInt(d.inst)];
        const at = u.tree.tokenStart(u.tree.nodeMainToken(data.pl_node.src_node));
        const name = out.files[@backingInt(out.resolve(at).file)].name;
        if (!std.mem.eql(u8, name, "spice_primitives.vams") and !std.mem.eql(u8, name, netlist_unit)) break;
        n += 1;
    }
    return n;
}

/// The `//! spice CARD` lines of `source`, each card verbatim (a leading
/// `+` continuation kept), joined with `\n` in source order.
fn spiceCards(arena: Allocator, source: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const rest = std.mem.trimStart(u8, std.mem.cutPrefix(u8, line, "//!") orelse continue, " \t");
        const card = std.mem.cutPrefix(u8, rest, "spice") orelse continue;
        if (card.len == 0 or (card[0] != ' ' and card[0] != '\t')) continue;
        if (out.items.len != 0) try out.append(arena, '\n');
        try out.appendSlice(arena, std.mem.trim(u8, card, " \t"));
    }
    return out.items;
}

fn severity(comp: *const Compilation, code: vams.Diag.Code) vams.Diag.Severity {
    return switch (comp.config.levels.get(code)) {
        .allow, .warn => vams.Diag.severityOf(code),
        .deny, .forbid => .err,
    };
}

/// The old driver's line for a file that cannot be read.
fn readFailed(comp: *Compilation, path: []const u8, e: anyerror) !void {
    const w = &comp.outputs.err;
    if (e == error.StreamTooLong)
        try w.print(comp.arena(), "error[E1013]: `{s}` is larger than {d} bytes; see `vera --explain E1013`\n", .{ path, vams.Preprocessor.max_text_bytes })
    else
        try w.print(comp.arena(), "error: cannot read `{s}`: {t}\n", .{ path, e });
}
