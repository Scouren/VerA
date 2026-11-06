//! The errors job (lib/TODO.md §3, Zig's `Compilation.getAllErrorsAlloc`):
//! every stage's diagnostics in, one `Diag` bundle out, each location moved
//! from the stage's own text (the preprocessed text, a Vir instruction, a
//! netlist file) to the original file the user wrote, then sorted in
//! source order by `Wip.toOwnedBundle`. The file table it indexes is
//! `sources`: the preprocessor's files, then the netlist's.
//!
//! Cites no LRM clause: the stages cite theirs.
//!
//! Contents:
//! - `pub fn bundle(comp: *Compilation) Allocator.Error!Diag`
//! - `pub fn sources(comp: *Compilation) Allocator.Error![]const Diag.Source`
//! - `pub fn relocate(out: vams.Preprocessor.Output, start: u32, end: u32) Diag.Loc`
//! - `pub fn instLoc(out: vams.Preprocessor.Output, u: *const Compilation.Unit, src: Inst.Ref) Diag.Loc`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const sema = @import("sema");
const Compilation = @import("../Compilation.zig");
const Diag = vams.Diag;
const Inst = vams.Vir.Inst;
const legacy = @import("legacy.zig");

/// Every diagnostic of `comp`, relocated and sorted; owned by the caller.
pub fn bundle(comp: *Compilation) Allocator.Error!Diag {
    var w: Diag.Wip = .init(comp.gpa);
    defer w.deinit();
    w.levels = comp.config.levels;
    const out = comp.pp.output();
    const pp_files: u32 = @intCast(out.files.len);
    for (out.diagnostics) |d| {
        const code = std.meta.stringToEnum(Diag.Code, d.code) orelse unreachable; // The preprocessor reports catalogue codes.
        const loc: Diag.Loc = if (d.file == .none) .none else .{ .file = @fromBackingInt(@backingInt(d.file)), .start = source(out, d.file, d.start), .end = source(out, d.file, d.end) };
        var b = w.build(.preprocess, code, loc);
        b.msg("{s}", .{d.message});
        for (d.notes) |n| b.note("{s}", .{n});
        if (d.label) |l| b.label(.{ .file = loc.file, .start = source(out, d.file, l.start), .end = source(out, d.file, l.end) }, "{s}", .{l.text});
        try b.emit();
    }
    if (comp.netlist) |*n| try n.output().report(&w, @fromBackingInt(pp_files));
    for (comp.units.items) |*u| {
        if (u.tree.errors.len != 0) {
            var pw: Diag.Wip = .init(comp.gpa);
            defer pw.deinit();
            try vams.Ast.parse_errors.report(&u.tree, &pw);
            var parsed = try pw.toOwnedBundle();
            defer parsed.deinit(comp.gpa);
            try copy(&w, parsed, out);
        }
        // On the IEEE 1364 route a code `legacy` rewords takes the old
        // engine's words, naming the unit text under its caret.
        try copyAs(&w, u.vir.diag, out, if (comp.config.digital()) u.text else null);
    }
    const zf = comp.zcu.failed.slice();
    const ip = &comp.zcu.intern_pool;
    // lib/sim/digital stopped at its first refusal: the 1364 route reports
    // elaboration's first error and every warning.
    var refused = false;
    for (zf.items(.code), zf.items(.file), zf.items(.src), zf.items(.message), zf.items(.rule), zf.items(.name), zf.items(.nums), zf.items(.part), zf.items(.note), zf.items(.help)) |code, file, src, message, rule, name, nums, part, note, help| {
        const u = &comp.units.items[@backingInt(file)];
        const is_error = @tagName(code)[0] == 'E';
        // The old `--emit-rtlil` parsed and never elaborated: no warning of elaboration's.
        if (comp.config.target == .rtlil and !is_error) continue;
        if (comp.config.digital() and is_error) {
            if (refused) continue;
            refused = true;
        }
        const loc = partLoc(out, u, src, part);
        if (rule != .none and comp.config.digital()) {
            try legacy.rule(&w, rule, loc, ip.stringToSlice(name), nums, try legacy.searchOrder(comp.arena(), &comp.zcu));
        } else {
            var b = w.build(.lower, code, loc);
            b.msg("{s}", .{ip.stringToSlice(message)});
            if (note != .empty) b.note("{s}", .{ip.stringToSlice(note)});
            if (help != .empty) b.help("{s}", .{ip.stringToSlice(help)});
            try b.emit();
        }
    }
    var own = try comp.wip.toOwnedBundle();
    defer own.deinit(comp.gpa);
    try copyAs(&w, own, null, null);
    return w.toOwnedBundle();
}

/// The file table `bundle`'s locations index, in the arena.
pub fn sources(comp: *Compilation) Allocator.Error![]const Diag.Source {
    const a = comp.arena();
    const out = comp.pp.output();
    const net: []const vams.spice.File = if (comp.netlist) |*n| n.output().files else &.{};
    const list = try a.alloc(Diag.Source, out.files.len + net.len);
    for (list[0..out.files.len], out.files) |*s, f| s.* = .{ .name = f.name, .text = f.source, .line_starts = try Diag.lineStarts(a, f.source) };
    for (list[out.files.len..], net) |*s, f| s.* = .{ .name = f.name, .text = f.text, .line_starts = try Diag.lineStarts(a, f.text) };
    assert(list.len == out.files.len + net.len);
    return list;
}

/// A preprocessed-text range as a range of the original file its start
/// came from; an end in another file collapses to the start.
pub fn relocate(out: vams.Preprocessor.Output, start: u32, end: u32) Diag.Loc {
    if (out.source_map.len == 0) return .none;
    const s = out.resolve(@min(start, @as(u32, @intCast(out.text.len))));
    const e = out.resolve(@min(@max(start, end), @as(u32, @intCast(out.text.len))));
    const from = source(out, s.file, s.offset);
    const to = if (e.file == s.file) source(out, e.file, e.offset) else from;
    return .{ .file = @fromBackingInt(@backingInt(s.file)), .start = from, .end = @max(from, to) };
}

/// Where Vir instruction `src` of unit `u` was written, as the old
/// compiler located it: a statement `<+` at its target's first byte (no
/// width), a call at its callee's name, anything else at its main token.
pub fn instLoc(out: vams.Preprocessor.Output, u: *const Compilation.Unit, src: Inst.Ref) Diag.Loc {
    const span = sema.locate.inst(&u.tree, &u.vir, src) orelse return .none;
    const r = span.bytes(&u.tree);
    return relocate(out, r.start, r.end);
}

// ---- private ----

/// Where part `part` of instruction `src` was written (`sema.locate.part`).
fn partLoc(out: vams.Preprocessor.Output, u: *const Compilation.Unit, src: Inst.Ref, part: sema.Zcu.Part) Diag.Loc {
    const span = sema.locate.part(&u.tree, &u.vir, src, part) orelse return .none;
    const r = span.bytes(&u.tree);
    return relocate(out, r.start, r.end);
}

/// Every message of `d`, located in a unit's preprocessed text, into `w`.
fn copy(w: *Diag.Wip, d: Diag, out: vams.Preprocessor.Output) Allocator.Error!void {
    try copyAs(w, d, out, null);
}

/// Copies each message of `d` with its labels and notes; with `out`, every
/// location is a preprocessed-text range and moves to its original file.
fn copyAs(w: *Diag.Wip, d: Diag, out: ?vams.Preprocessor.Output, route: ?[]const u8) Allocator.Error!void {
    for (d.messages()) |i| {
        const m = d.message(i);
        if (route) |t| if (legacy.byCode(m.tag.code)) {
            try legacy.code(w, m.tag.code, move(out, m.loc), t[m.loc.start..m.loc.end]);
            continue;
        };
        var b = w.build(m.tag.stage, m.tag.code, move(out, m.loc));
        if (m.msg != .none) b.msg("{s}", .{d.string(m.msg)});
        if (m.point != .none) b.point("{s}", .{d.string(m.point)});
        for (d.labels(i)) |l| b.label(move(out, l.loc), "{s}", .{d.string(l.text)});
        for (d.notes(i)) |n| {
            if (n.replacement != .none) {
                b.suggest(.{ .loc = move(out, n.fix), .replacement = d.string(n.replacement) }, "{s}", .{d.string(n.text)});
            } else if (n.kind == .note) b.note("{s}", .{d.string(n.text)}) else b.help("{s}", .{d.string(n.text)});
        }
        try b.emit();
    }
}

fn move(out: ?vams.Preprocessor.Output, loc: Diag.Loc) Diag.Loc {
    const o = out orelse return loc;
    if (loc.isNone()) return loc;
    return relocate(o, loc.start, loc.end);
}

/// A stripped-text offset of `file` as an offset of its original bytes.
fn source(out: vams.Preprocessor.Output, file: vams.Preprocessor.File.Index, offset: u32) u32 {
    return vams.Preprocessor.toSourceOffset(out.files[@backingInt(file)].marks, offset);
}
