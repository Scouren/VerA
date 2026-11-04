//! `include: the line after an IEEE 1364-2005 §19.5 `include word in, the
//! named file scanned in place out, refusing the one repetition that makes
//! nesting infinite (E0125). The file comes from the caller: each candidate
//! path the search order names is looked up in the pass's answers, and the
//! first one not yet answered stops the pass with `error.NeedFile`. Search
//! order: an absolute path as written, the including file's directory, the
//! include dirs, then the built-in annex D files, which cost no request.
//! Cites: IEEE 1364-2005 §19.5 Syntax 19-6; LRM §10.7, annex D;
//! specification/Vague_Decisions.md VD-091, VD-093.
//!
//! Contents:
//! - `pub const builtin_includes: std.StaticStringMap([]const u8)`
//! - `pub fn handleInclude(pp: *Pass, rest: []const u8, at: usize, off: usize) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Pass = @import("Pass.zig");
const Error = Pass.Error;
const Span = Pass.Span;
const Rest = @import("scan.zig").Rest;
const Preprocessor = @import("../Preprocessor.zig");
const File = Preprocessor.File;

/// The built-in annex files, by basename. All are self-guarded, so an
/// `include after the prelude expands to nothing. `discipline.h` and
/// `constants.h` are the OVI Verilog-A 1.0 names of D.1 and D.2 (VD-093);
/// D.3 driver_access.vams is never preloaded.
pub const builtin_includes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "constants.vams", @embedFile("../constants.vams") },
    .{ "disciplines.vams", @embedFile("../disciplines.vams") },
    .{ "constants.h", @embedFile("../constants.vams") },
    .{ "discipline.h", @embedFile("../disciplines.vams") },
    .{ "driver_access.vams", @embedFile("../driver_access.vams") },
});

/// The bytes of an `include and the path they were opened by, which §10.7
/// makes `__FILE__`. A built-in file keeps the name written.
const Included = struct { text: []const u8, path: []const u8 };

/// Finds and scans the file an IEEE 1364 §19.5 `include names. `rest` is the
/// line after the word, starting at offset `off`; `at` is the '`'. Fails
/// with E0121-E0124 (the name), E0144 (text after it), E0125 (a cycle),
/// E0126 (not found) or E1013 (an answer past `max_text_bytes`), and with
/// `error.NeedFile` when a candidate is unanswered.
pub fn handleInclude(pp: *Pass, rest: []const u8, at: usize, off: usize) Error!void {
    assert(off > at);
    const depth = pp.includes.items.len;
    defer assert(pp.includes.items.len == depth);
    const sp = pp.spanAt(at, off);
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const open = r.peek() orelse return pp.fail(sp, "E0121", "", .{});
    // Syntax 19-6 has one form, `include "filename"; C's `<file>` is E0122.
    if (open != '"') return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), "E0122", "found `{c}`", .{open});
    r.i += 1;
    const start = r.i;
    r.i = std.mem.findScalarPos(u8, r.s, start, '"') orelse r.s.len;
    if (r.i >= r.s.len) return pp.fail(pp.spanAt(off + start - 1, off + r.i), "E0123", "", .{});
    const path = r.s[start..r.i];
    if (path.len == 0) return pp.fail(pp.spanAt(off + start - 1, off + r.i + 1), "E0124", "", .{});
    const name_span = pp.spanAt(off + start, off + r.i);
    // §19.5: "Only white space or a comment may appear on the same line".
    r.i += 1;
    r.skipSpace();
    if (r.i < r.s.len)
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), "E0144", "`{s}`", .{std.mem.trim(u8, r.s[r.i..], " \t\r\n")});

    const inc = (try findInclude(pp, path, name_span)) orelse {
        const dirs = if (includerDir(pp)) |d| try std.mem.concat(pp.arena, []const u8, &.{ &.{d}, pp.opts.include_dirs }) else pp.opts.include_dirs;
        const builtins = "then the built-in annex D headers (constants.vams, disciplines.vams)";
        const notes: []const []const u8 = if (dirs.len == 0) &.{builtins} else try pp.arena.dupe([]const u8, &.{ try pp.arena.print("searched, in order: {s}", .{try std.mem.join(pp.arena, ", ", dirs)}), builtins });
        return pp.failNoted(name_span, "E0126", "\"{s}\"", .{path}, notes);
    };

    // §19.5: "The number of nesting levels for include files shall be
    // finite". What makes nesting infinite is a file opened again inside
    // itself in the state it was first opened in: the control flow reads only
    // the macro table and the open conditionals. So only that repetition is
    // refused; a 64-bit hash of the macro table stands for the table.
    const opened: Pass.Open = .{
        .key = try std.fs.path.resolve(pp.arena, &.{inc.path}),
        .path = path,
        .macro_hash = pp.macro_hash,
        .conds = pp.conds.items.len,
    };
    for (pp.includes.items, 0..) |o, k| {
        if (o.macro_hash != opened.macro_hash or o.conds != opened.conds or !std.mem.eql(u8, o.key, opened.key)) continue;
        const chain = try pp.arena.alloc([]const u8, pp.includes.items.len - k);
        for (chain, pp.includes.items[k..]) |*c, i| c.* = i.path;
        const note = try pp.arena.print("include cycle: {s}", .{try pp.joinChain(chain, path)});
        return pp.failNoted(name_span, "E0125", "\"{s}\" includes itself with every macro as it was", .{path}, try pp.arena.dupe([]const u8, &.{note}));
    }
    try pp.includes.append(pp.arena, opened);
    defer _ = pp.includes.pop();
    // `Options.require_std_includes`: the source asked for annex D.
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "constants.vams") or std.mem.eql(u8, base, "constants.h")) pp.constants_included = true;
    if (std.mem.eql(u8, base, "disciplines.vams") or std.mem.eql(u8, base, "discipline.h")) pp.disciplines_included = true;
    // Registered under the opened path: `__FILE__` and every diagnostic
    // inside name the file that was read (§10.7).
    try pp.nested(name_span, Pass.runFile, .{ pp, inc.text, inc.path, File.Index.none });
    try pp.checkTextSize(name_span);
}

// ---- private ----

/// Returns the `include file for `path` by the search order in the header,
/// or null when every candidate was answered "not there" and no built-in has
/// its basename. `error.NeedFile` names the first unanswered candidate.
fn findInclude(pp: *Pass, path: []const u8, span: Span) Error!?Included {
    assert(path.len > 0);
    // §19.5: a full path name is opened as written; `join` skips the "" base.
    if (std.fs.path.isAbsolute(path)) return (try candidate(pp, "", path, span)) orelse builtin(pp, path);
    if (includerDir(pp)) |dir| if (try candidate(pp, dir, path, span)) |inc| return inc;
    for (pp.opts.include_dirs) |base| if (try candidate(pp, base, path, span)) |inc| return inc;
    return builtin(pp, path);
}

/// The directory of the file the `include sits in: the path it was opened
/// by, "." for a bare name, null for a unit named `<...>` or "".
fn includerDir(pp: *const Pass) ?[]const u8 {
    const name = pp.file(pp.cur_file).name;
    if (name.len == 0 or name[0] == '<') return null;
    const dir = std.fs.path.dirname(name) orelse ".";
    assert(dir.len > 0);
    return dir;
}

fn candidate(pp: *Pass, base: []const u8, path: []const u8, span: Span) Error!?Included {
    assert(path.len > 0);
    const full = try std.fs.path.join(pp.arena, &.{ base, path });
    const answered = pp.answers.get(full) orelse {
        pp.want = full;
        return error.NeedFile;
    };
    const bytes = answered orelse return null; // not there: the next candidate
    if (bytes.len > Preprocessor.max_text_bytes)
        return pp.fail(span, "E1013", "\"{s}\" is larger than {d} bytes", .{ full, Preprocessor.max_text_bytes });
    return .{ .text = bytes, .path = full };
}

fn builtin(pp: *Pass, path: []const u8) ?Included {
    assert(path.len > 0);
    const name = std.fs.path.basename(path);
    const text = builtin_includes.get(name) orelse return null;
    if (std.mem.eql(u8, name, "disciplines.vams") or std.mem.eql(u8, name, "discipline.h")) pp.annex_d_included = true;
    return .{ .text = text, .path = path };
}
