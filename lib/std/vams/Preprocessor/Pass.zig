//! One preprocessing pass (`Pass`): the state a run of the units builds, the
//! macro table, the open conditionals and `include`s, the output text and
//! its source map, the directive events, the file table and the diagnostics,
//! and the helpers every handler shares. Also the per-file step, `runFile`:
//! one raw file in, its stripped text scanned into `out`, and the annex D/E
//! prelude runs. Everything lives on `arena`, which the `Preprocessor` resets
//! before the next pass, so a pass never frees.
//! Cites: LRM §2.4, §10.4, §10.5, §10.7, annex D, annex E.2; IEEE 1364-2005
//! §19.5, §19.7.
//!
//! Contents:
//! - `pub const Error = Allocator.Error || error{ PreprocessFailed, NeedFile }`
//! - `pub const Span = struct`, `Span.point(at: u32) Span`
//! - `pub const Macro = struct`
//! - `pub const Cond = struct`
//! - `pub const Open = struct`
//! - `pub fn putMacro(pp: *Pass, name: []const u8, m: Macro) Allocator.Error!void`
//! - `pub fn removeMacro(pp: *Pass, name: []const u8) void`
//! - `pub fn nested(pp: *Pass, span: Span, comptime f: anytype, args: anytype) Error!void`
//! - `pub fn checkTextSize(pp: *Pass, span: Span) Error!void`
//! - `pub fn actualStack(pp: *Pass) *std.ArrayList(u8)`
//! - `pub fn emitting(pp: *const Pass) bool`
//! - `pub fn mark(pp: *Pass, list: anytype, value: anytype) Allocator.Error!void`
//! - `pub fn putNewlines(pp: *Pass, span: []const u8) Error!void`
//! - `pub fn spanAt(pp: *const Pass, start: usize, end: usize) Span`
//! - `pub fn file(pp: *const Pass, id: File.Index) *const File`
//! - `pub fn physicalLine(pp: *const Pass, at: usize) u32`
//! - `pub fn currentLine(pp: *const Pass, at: usize) u64`
//! - `pub fn fail(pp: *Pass, span: Span, comptime code: []const u8, comptime fmt: []const u8, args: anytype) Error`
//! - `pub fn failCode(pp: *Pass, span: Span, code: []const u8, why: []const u8) Error`
//! - `pub fn warn(pp: *Pass, span: Span, comptime code: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void`
//! - `pub fn addFile(pp: *Pass, name: []const u8, text: []const u8) Error!File.Index`
//! - `pub fn resync(pp: *Pass, at: usize) Error!void`
//! - `pub fn runStdDefs(pp: *Pass) Error!void`
//! - `pub fn runSpicePrimitives(pp: *Pass) Error!void`
//! - `pub fn runFile(pp: *Pass, raw: []const u8, name: []const u8, existing: File.Index) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Preprocessor = @import("../Preprocessor.zig");
const Options = Preprocessor.Options;
const File = Preprocessor.File;
const Mapping = Preprocessor.Mapping;
const Diagnostic = Preprocessor.Diagnostic;
const max_text_bytes = Preprocessor.max_text_bytes;
const Events = @import("events.zig").Events;
const scan = @import("scan.zig");

/// Holds everything the pass builds; reset by the `Preprocessor` before the
/// next pass, so nothing here is freed one by one.
arena: Allocator,
opts: *const Options,
/// The caller's answers so far, by candidate path (`Preprocessor.answers`).
answers: *const std.StringHashMapUnmanaged(?[]const u8),
/// The candidate path an `include needs and `answers` lacks, set with
/// `error.NeedFile`.
want: []const u8 = "",

// ---- outputs, published as they stand ------------------------------------
out: std.ArrayList(u8) = .empty,
/// Provenance of the output: appended to only, so sorted by `out`.
maps: std.ArrayList(Mapping) = .empty,
events: Events = .{},
files: std.ArrayList(File) = .empty,
diags: std.ArrayList(Diagnostic) = .empty,
/// Where each unit after the first begins in `out`.
unit_starts: std.ArrayList(u32) = .empty,
/// An `include resolved to the built-in annex D.1 (VD-096).
annex_d_included: bool = false,
/// An `include named constants.vams (constants.h) / disciplines.vams
/// (discipline.h), from a directory or built in.
constants_included: bool = false,
disciplines_included: bool = false,
/// Running text VerA ships (the prelude), which reads annex D.2 whatever the
/// source includes.
in_std_defs: bool = false,

// ---- scan state ------------------------------------------------------------
macros: std.StringHashMapUnmanaged(Macro) = .empty,
conds: std.ArrayList(Cond) = .empty,
/// §10.4 cycle guard: the names being expanded, outermost first, and the
/// same names as a set. A cycle is E0118; any finite chain is legal.
expanding: std.ArrayList([]const u8) = .empty,
expanding_set: std.StringHashMapUnmanaged(void) = .empty,
/// The `include stack, innermost last (E0125's cycle check).
includes: std.ArrayList(Open) = .empty,
/// Order-free hash of the macro table (each entry's hash, XORed).
macro_hash: u64 = 0,
/// Open `include and macro-expansion levels (`nested`).
depth: u32 = 0,
/// IEEE 1364 §19.7 `line remap for §10.7 `__LINE__`: a physical line L at
/// or past `line_from` reports `line_to + (L - line_from)`. Per file.
line_from: u32 = 0,
line_to: ?u32 = null,
/// The `line directive's file name, which replaces `__FILE__` (§10.7).
file_override: ?[]const u8 = null,
/// The file the current offsets belong to.
cur_file: File.Index = @fromBackingInt(@intCast(0)),
/// The outermost invocation's offset while a macro body is rescanned:
/// offsets inside a body index no file, so diagnostics report here.
expand_site: ?u32 = null,
/// `out` is the actuals stack (`actualStack`), not the output, so no
/// mapping may be recorded and no region directive may take effect.
in_actual: bool = false,
/// Pre-expanded actuals between `macro.expandArg` and their substitution.
actuals: std.ArrayList(u8) = .empty,
/// Where the actual being expanded begins in `out`; 0 outside one.
out_base: usize = 0,
/// Per `expanding` depth, the buffer a substituted body is built in.
bodies: std.ArrayList(std.ArrayList(u8)) = .empty,
/// `macro.macroArgs`'s bracket stack, reused by every call.
brackets: std.ArrayList(u8) = .empty,
/// Index in `maps` of the outermost expansion's row, valid while that
/// expansion set `expand_site` outside an actual.
expansion_map: u32 = 0,

/// Every way a step of the pass stops: memory ran out, a diagnostic ended
/// the pass (it is in `diags`), or an `include needs `want` answered.
pub const Error = Allocator.Error || error{ PreprocessFailed, NeedFile };

/// A file-local byte range `[start, end)`.
pub const Span = struct {
    start: u32,
    end: u32,

    /// Returns the zero-width span at `at`.
    pub fn point(at: u32) Span {
        return .{ .start = at, .end = at };
    }
};

/// One `define (§10.4), the value of `macros` under its name. Every slice
/// borrows the defining text, which lives on the arena as long as the table.
pub const Macro = struct {
    /// The formal names, in order; empty with `is_func == false` is
    /// object-like.
    params: []const []const u8 = &.{},
    /// A formal list was written, even an empty one.
    is_func: bool = false,
    /// The macro text, one logical line, continuations joined.
    body: []const u8,
    /// §10.5 predefined: survives `undef.
    predefined: bool = false,
    /// Defined by annex D.2 constants.vams: under `require_std_includes` a
    /// use needs `include "constants.vams"`.
    annex_d2: bool = false,
    /// Defined by annex D.1 disciplines.vams: under `require_std_includes`
    /// `ifdef reads it as undefined until the source includes the file.
    annex_d1: bool = false,

    // A few hundred rows per compilation: two slices and three flags.
    comptime {
        assert(@sizeOf(Macro) <= 40);
    }
};

/// One `ifdef/`ifndef level.
pub const Cond = struct {
    /// Enclosing levels are all emitting.
    parent_active: bool,
    /// This level emits right now (implies `parent_active`).
    active: bool,
    /// Some arm was taken, so later `elsif/`else are dead.
    taken: bool,
    /// The `else was read: another `else or `elsif is E0106.
    seen_else: bool = false,
    /// The `ifdef that opened the level, for E0101.
    span: Span = .{ .start = 0, .end = 0 },
    file: File.Index = @fromBackingInt(@intCast(0)),

    comptime {
        assert(@sizeOf(Cond) == 16);
    }
};

/// One open `include: its path with `.` and `..` resolved (the cycle key),
/// the path as written, and the macro state and conditional depth at the
/// `include. Two opens on one stack agreeing on all three repeat forever.
pub const Open = struct { key: []const u8, path: []const u8, macro_hash: u64, conds: usize };

const Pass = @This();

const constants_vams = @embedFile("../constants.vams");
const disciplines_vams = @embedFile("../disciplines.vams");
const spice_primitives_vams = @embedFile("../spice_primitives.vams");

/// Defines (or redefines) `name`, keeping `macro_hash`. Asserts a name.
pub fn putMacro(pp: *Pass, name: []const u8, m: Macro) Allocator.Error!void {
    assert(name.len > 0);
    const gop = try pp.macros.getOrPut(pp.arena, name);
    if (gop.found_existing) pp.macro_hash ^= macroHash(name, gop.value_ptr.*);
    gop.value_ptr.* = m;
    pp.macro_hash ^= macroHash(name, m);
    assert(pp.macros.contains(name));
}

/// Removes `name` if defined, keeping `macro_hash`.
pub fn removeMacro(pp: *Pass, name: []const u8) void {
    const kv = pp.macros.fetchRemove(name) orelse return;
    pp.macro_hash ^= macroHash(kv.key, kv.value);
    assert(!pp.macros.contains(name));
}

/// Calls `f(args)` as one more level of `include, envelope or macro
/// nesting. Past `Preprocessor.nesting_max` levels it is E0119 at `span`
/// (lib/TODO.md §11.2: a fixed cap with its own code).
pub fn nested(pp: *Pass, span: Span, comptime f: anytype, args: anytype) Error!void {
    const depth = pp.depth;
    defer assert(pp.depth == depth);
    if (depth >= Preprocessor.nesting_max)
        return pp.fail(span, "E0119", "{d} levels deep", .{depth});
    pp.depth += 1;
    defer pp.depth -= 1;
    return @call(.auto, f, args);
}

/// E0150 when the text built so far (`out`, or the actual being expanded)
/// has passed `Options.text_limit`.
pub fn checkTextSize(pp: *Pass, span: Span) Error!void {
    assert(pp.opts.text_limit <= max_text_bytes);
    assert(pp.out_base <= pp.out.items.len);
    if (pp.out.items.len - pp.out_base > pp.opts.text_limit)
        return pp.fail(span, "E0150", "past {d} bytes", .{pp.opts.text_limit});
}

/// Returns the actuals stack: `out` inside an actual, else `actuals`.
pub fn actualStack(pp: *Pass) *std.ArrayList(u8) {
    if (pp.in_actual) assert(pp.actuals.items.len == 0);
    return if (pp.in_actual) &pp.out else &pp.actuals;
}

/// Returns whether every enclosing conditional arm is active.
pub fn emitting(pp: *const Pass) bool {
    const n = pp.conds.items.len;
    if (n == 0) return true;
    const top = pp.conds.items[n - 1];
    if (top.active) assert(top.parent_active);
    return top.active;
}

/// Appends an event to `list` at the current output length, where the
/// directive's region begins. Asserts that `out` is the output, not an
/// actual's buffer, and that events stay in text-stream order.
pub fn mark(pp: *Pass, list: anytype, value: anytype) Allocator.Error!void {
    assert(!pp.in_actual);
    const at: u32 = @intCast(pp.out.items.len);
    if (list.items.len != 0) assert(list.items[list.items.len - 1].at <= at);
    try list.append(pp.arena, .{ .at = at, .value = value });
}

/// Emits only the newlines in `span`, so dropped text keeps the line count.
pub fn putNewlines(pp: *Pass, span: []const u8) Error!void {
    try pp.out.appendNTimes(pp.arena, '\n', std.mem.countScalar(u8, span, '\n'));
}

/// Returns a file-local span for `[start, end)` of the text being scanned,
/// or the invocation site inside a macro body. Asserts `start <= end`.
pub fn spanAt(pp: *const Pass, start: usize, end: usize) Span {
    assert(start <= end);
    if (pp.expand_site) |s| return .point(s);
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// Returns the row of a registered file. Asserts that `id` is one.
pub fn file(pp: *const Pass, id: File.Index) *const File {
    assert(id != .none);
    assert(@backingInt(id) < pp.files.items.len);
    return &pp.files.items[@backingInt(id)];
}

/// Returns the physical 1-based line of `at` in the current file, or of the
/// invocation site inside a macro body. O(offset): counts newlines.
pub fn physicalLine(pp: *const Pass, at: usize) u32 {
    const off = pp.expand_site orelse @as(u32, @intCast(at));
    const text = pp.file(pp.cur_file).text;
    const line: u32 = @intCast(1 + std.mem.countScalar(u8, text[0..@min(off, text.len)], '\n'));
    assert(line >= 1);
    return line;
}

/// Returns §10.7 `__LINE__` at `at`: the physical line, remapped by an IEEE
/// 1364 §19.7 `line when one is in force.
pub fn currentLine(pp: *const Pass, at: usize) u64 {
    const phys = pp.physicalLine(at);
    const to = pp.line_to orelse return phys;
    // Saturating: an operand smaller than the offset it corrects gives no line 0.
    return if (phys >= pp.line_from) @as(u64, to) + (phys - pp.line_from) else to;
}

/// Appends error `code` at `span` of the current file and returns
/// `error.PreprocessFailed`: the first error ends the pass.
pub fn fail(pp: *Pass, span: Span, comptime code: []const u8, comptime fmt: []const u8, args: anytype) Error {
    comptime assert(code[0] == 'E');
    try pp.report(span, code, fmt, args);
    return error.PreprocessFailed;
}

/// `fail` for an error code chosen at run time (a §28 envelope's verdict).
/// Asserts that `code` is an error code.
pub fn failCode(pp: *Pass, span: Span, code: []const u8, why: []const u8) Error {
    assert(code[0] == 'E');
    try pp.report(span, code, "{s}", .{why});
    return error.PreprocessFailed;
}

/// Appends warning `code` at `span` of the current file; the pass goes on.
pub fn warn(pp: *Pass, span: Span, comptime code: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    comptime assert(code[0] == 'W');
    try pp.report(span, code, fmt, args);
}

/// Registers `name` and `text` in the file table and returns its index. The
/// table holds `Preprocessor.files_max` files and an include tree is input,
/// so one past it is E0154.
pub fn addFile(pp: *Pass, name: []const u8, text: []const u8) Error!File.Index {
    const n = pp.files.items.len;
    if (n == Preprocessor.files_max) {
        pp.cur_file = .none;
        return pp.fail(.point(0), "E0154", "`{s}` would be file {d}", .{ name, n + 1 });
    }
    try pp.files.append(pp.arena, .{ .name = name, .source = text, .text = text });
    assert(pp.files.items.len == n + 1);
    return @fromBackingInt(@intCast(n));
}

/// Records that the output continues from `at` in the current file. Called
/// after every directive, which may collapse to its newlines.
pub fn resync(pp: *Pass, at: usize) Error!void {
    // A macro body has no file offset; an actual's buffer is not the output.
    assert(at <= std.math.maxInt(u32));
    if (pp.expand_site != null or pp.in_actual) return;
    try pp.maps.append(pp.arena, .{ .out = @intCast(pp.out.items.len), .offset = @intCast(at), .file = pp.cur_file, .kind = .verbatim });
}

/// Preprocesses annex D.2, D.1 and Table E.1 into the pass, marking each
/// macro with the annex file it came from.
pub fn runStdDefs(pp: *Pass) Error!void {
    // D.2 first: disciplines.vams reads `*_ABSTOL overrides.
    pp.in_std_defs = true;
    defer pp.in_std_defs = false;
    try pp.runFile(constants_vams, "constants.vams", .none);
    var it = pp.macros.valueIterator();
    while (it.next()) |m| m.annex_d2 = !m.predefined;
    try pp.runFile(disciplines_vams, "disciplines.vams", .none);
    var d1 = pp.macros.valueIterator();
    while (d1.next()) |m| m.annex_d1 = !m.predefined and !m.annex_d2;
    // Annex E after D.1: its ports are `electrical`, its rows read `M_TWO_PI.
    try pp.runFile(spice_primitives_vams, "spice_primitives.vams", .none);
}

/// Table E.1 alone: its rows read annex D.2's `M_TWO_PI, defined for this
/// file only, so no annex D macro reaches the source.
pub fn runSpicePrimitives(pp: *Pass) Error!void {
    pp.in_std_defs = true;
    defer pp.in_std_defs = false;
    try pp.putMacro("M_TWO_PI", .{ .body = "6.28318530717958647693" });
    defer pp.removeMacro("M_TWO_PI");
    try pp.runFile(spice_primitives_vams, "spice_primitives.vams", .none);
}

/// Registers `raw` (or reuses `existing`), strips its comments and scans
/// it. Saves and restores the file context, so an error after an `include
/// names the right file. Fails as the pass does.
pub fn runFile(pp: *Pass, raw: []const u8, name: []const u8, existing: File.Index) Error!void {
    assert(raw.len <= max_text_bytes);
    const maps_before = pp.maps.items.len;
    const saved_id = pp.cur_file;
    defer pp.cur_file = saved_id;
    // An `include a macro expansion reached opens a real file with offsets
    // of its own: until it ends, spans stop reporting the invocation site.
    const saved_site = pp.expand_site;
    const saved_map = pp.expansion_map;
    pp.expand_site = null;
    defer {
        pp.expand_site = saved_site;
        pp.expansion_map = saved_map;
    }
    // §10.7: at the end of an included file `__FILE__ and `__LINE__ "revert
    // to the values they had before the `include".
    const saved_from = pp.line_from;
    const saved_to = pp.line_to;
    const saved_override = pp.file_override;
    pp.line_from = 0;
    pp.line_to = null;
    pp.file_override = null;
    defer {
        pp.line_from = saved_from;
        pp.line_to = saved_to;
        pp.file_override = saved_override;
    }

    const id = if (existing != .none) existing else try pp.addFile(name, raw);
    pp.cur_file = id;
    if (pp.out.items.len - pp.out_base + raw.len > pp.opts.text_limit)
        return pp.fail(.point(0), "E0150", "past {d} bytes", .{pp.opts.text_limit});
    // Every later offset indexes the stripped text.
    const s = try scan.stripComments(pp, raw);
    pp.files.items[@backingInt(id)].text = s.text;
    pp.files.items[@backingInt(id)].marks = s.marks;

    if (!pp.in_actual) try pp.maps.append(pp.arena, .{ .out = @intCast(pp.out.items.len), .offset = 0, .file = id, .kind = .verbatim });
    try scan.scan(pp, s.text);
    // Back inside the expansion that reached the `include.
    if (saved_site != null and !pp.in_actual) {
        var m = pp.maps.items[saved_map];
        m.out = @intCast(pp.out.items.len);
        try pp.maps.append(pp.arena, m);
    }
    assert(pp.maps.items.len >= maps_before);
}

// ---- private ----

fn report(pp: *Pass, span: Span, code: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    assert(code.len == 5);
    assert(span.start <= span.end);
    try pp.diags.append(pp.arena, .{
        .code = code,
        .file = pp.cur_file,
        .start = span.start,
        .end = span.end,
        .message = try pp.arena.print(fmt, args),
    });
}

fn macroHash(name: []const u8, m: Macro) u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(name);
    h.update(&.{ 0, @intFromBool(m.is_func), @intFromBool(m.predefined) });
    for (m.params) |p| {
        h.update(p);
        h.update(&.{0});
    }
    h.update(&.{1});
    h.update(m.body);
    return h.final();
}
