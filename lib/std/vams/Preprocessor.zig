//! IEEE 1364 §19 / VAMS §10 preprocessing with no I/O: an ordered list of
//! source units in, one preprocessed text out with its source map, its
//! directive events (`Directives`), its file table and its diagnostics.
//! The preprocessor never opens a file: when an `include needs one it stops
//! and returns a request naming one candidate path, and the caller answers
//! with the bytes or null ("not there", so the next candidate is asked).
//! Annex D and Table E.1 text is built in and never costs a request.
//!
//! ```zig
//! var pp: Preprocessor = .init(gpa, .{ .defines = &.{"X=1"} });
//! defer pp.deinit();
//! try pp.addUnit("top.va", top_text);
//! while (try pp.run()) |req| switch (req) {
//!     .file => |want| try pp.answer(read(want.path)),
//! };
//! const out = pp.output();
//! ```
//!
//! Cites: LRM §2.4, §10.1-§10.7, annex D, annex E.2; IEEE 1364-2005
//! §13.4.1, §19.1-§19.10, §28.
//!
//! Contents:
//! - fields `gpa`, `options`, `units`, `answers`, `want`, `arena`, `result`
//! - `pub const Options = struct`
//! - `pub const Request = union(enum)`
//! - `pub const Output = struct`, `Output.resolve(out: Output, offset: u32) Location`
//! - `pub const Location = struct`
//! - `pub const File = struct`, `File.Index`
//! - `pub const StripMark = struct`
//! - `pub const Mapping = struct`
//! - `pub const Diagnostic = struct`
//! - `pub const Directives`, `pub const events`, `pub const protect`
//! - `pub const max_text_bytes: u32`, `pub const nesting_max: u32`, `pub const files_max: u32`
//! - `pub const predefined_macros: [3][]const u8`
//! - `pub fn init(gpa: Allocator, options: Options) Preprocessor`
//! - `pub fn deinit(pp: *Preprocessor) void`
//! - `pub fn addUnit(pp: *Preprocessor, name: []const u8, text: []const u8) Allocator.Error!void`
//! - `pub fn run(pp: *Preprocessor) Allocator.Error!?Request`
//! - `pub fn answer(pp: *Preprocessor, bytes: ?[]const u8) Allocator.Error!void`
//! - `pub fn output(pp: *const Preprocessor) Output`
//! - `pub fn toSourceOffset(marks: []const StripMark, offset: u32) u32`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Pass = @import("Preprocessor/Pass.zig");
pub const events = @import("Preprocessor/events.zig");
pub const protect = @import("Preprocessor/protect.zig");
pub const Directives = events.Directives;

gpa: Allocator,
options: Options,
/// The units, in command-line order (IEEE 1364 §13.4.1); borrowed.
units: std.ArrayList(Unit) = .empty,
/// The caller's answers by candidate path, keys and table on `gpa`; the
/// bytes are borrowed. Kept across runs: the same path is never asked twice.
answers: std.StringHashMapUnmanaged(?[]const u8) = .empty,
/// The candidate the last `run` asked for, on `gpa`, until `answer`.
want: ?[]const u8 = null,
/// Owns everything a run builds; reset when the next run starts.
arena: std.heap.ArenaAllocator,
/// The finished run's output, on `arena`.
result: Output = .{},

/// What a run reads besides the units. Every slice is borrowed for the
/// preprocessor's life.
pub const Options = struct {
    /// Searched in order for `include, after the includer's directory and
    /// before the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// Command-line macros, each `NAME` or `NAME=TEXT` (a bare `NAME` is
    /// `1`, as iverilog's `-D`), defined after the prelude, before the units.
    defines: []const []const u8 = &.{},
    /// Prepend annex D.2 constants.vams, D.1 disciplines.vams and the Table
    /// E.1 primitives.
    std_defs: bool = true,
    /// With `std_defs` off, still prepend the Table E.1 primitives (E.2
    /// makes them built-ins, not part of annex D).
    spice_primitives: bool = false,
    /// Annex D serves only a source that `include`s it: a D.2 macro without
    /// `include "constants.vams"` is E0115, and the D.1/D.2 guards read as
    /// undefined until their file is included. `vera` sets it.
    require_std_includes: bool = false,
    /// The units are IEEE 1364 (`--std=1364-*`): each `define using IEEE
    /// 1800-2017 §22.5.1's `" `\`" `` forms warns W0151.
    std_1364: bool = false,
    /// IEEE 1364-2005 §28.2: the keys "supplied by the user"; none makes an
    /// envelope E0152.
    protect_keys: protect.Keys = .{},
    /// E0150's bound on the text; only tests lower it.
    text_limit: u32 = max_text_bytes,
};

/// What a run needs before it can go on.
pub const Request = union(enum) {
    /// The bytes of `path`, a candidate of the `include search order;
    /// `path` is valid until `answer`.
    file: struct { path: []const u8 },
};

/// What a finished run publishes. Every slice is valid until the next
/// `run` or `deinit`.
pub const Output = struct {
    /// The preprocessed bytes, the tokenizer's input. Partial when `failed`.
    text: []const u8 = "",
    /// Every file the run read, by `File.Index`: the first unit is 0.
    files: []const File = &.{},
    /// Provenance of `text`, sorted by `Mapping.out`.
    source_map: []const Mapping = &.{},
    /// The positional directive events.
    directives: Directives = .{},
    /// In emission order; the first error ends the run.
    diagnostics: []const Diagnostic = &.{},
    /// An error ended the run.
    failed: bool = false,
    /// Where each unit after the first begins in `text`.
    unit_starts: []const u32 = &.{},
    /// An `include resolved to the built-in annex D.1, so its natures join
    /// §3.13.2's uniqueness rule (VD-096).
    annex_d_included: bool = false,
    /// A unit included `disciplines.vams` (or `discipline.h`).
    disciplines_included: bool = false,

    /// Returns the file and stripped-text offset that `offset` of `text`
    /// came from: a byte of a macro expansion resolves to the use.
    pub fn resolve(out: Output, offset: u32) Location {
        assert(out.source_map.len > 0);
        assert(offset <= out.text.len);
        const lo = std.sort.partitionPoint(Mapping, out.source_map, offset, mappedAtOrBefore) -| 1;
        const m = out.source_map[lo];
        if (m.kind == .expansion) return .{ .file = m.file, .offset = m.offset };
        return .{ .file = m.file, .offset = m.offset +| (offset -| m.out) };
    }
};

/// A place in a file's stripped text (`File.text`).
pub const Location = struct { file: File.Index, offset: u32 };

/// One file a run read: a unit, an `include, a built-in, a decrypted
/// envelope.
pub const File = struct {
    /// The name `__FILE__` reads: the unit's name, the path an `include was
    /// opened by, the annex file's name.
    name: []const u8,
    /// The bytes as read.
    source: []const u8,
    /// `source` with comments stripped: the text every offset indexes.
    text: []const u8,
    /// `text` to `source` offsets (`toSourceOffset`).
    marks: []const StripMark = &.{},

    /// A row of `Output.files`.
    pub const Index = enum(u32) { none = std.math.maxInt(u32), _ };
};

/// One point where comment stripping made the text shorter: from `out` to
/// the next mark the two texts advance in lockstep. Sorted by `out`.
pub const StripMark = struct {
    out: u32,
    src: u32,

    comptime {
        assert(@sizeOf(StripMark) == 8);
    }
};

/// From `out` in the output to the next row, the text came from `file` at
/// `offset`: byte for byte (`verbatim`), or as the expansion of the macro
/// use there (`expansion`).
pub const Mapping = struct {
    out: u32,
    offset: u32,
    file: File.Index,
    kind: enum(u8) { verbatim, expansion },

    comptime {
        assert(@sizeOf(Mapping) == 16);
    }
};

/// One diagnostic, until the `Diag` module exists. `start..end` index the
/// stripped text of `file` (`.none` for E0154, which has no file).
pub const Diagnostic = struct {
    /// The catalogue code (lib/diag/codes/): `E` errors, `W` warnings.
    code: []const u8,
    file: File.Index,
    start: u32,
    end: u32,
    message: []const u8,
};

/// The longest text a later stage can address: offsets are u32. A file or
/// expansion past it is E1013 / E0150.
pub const max_text_bytes: u32 = std.math.maxInt(u32);

/// `include, envelope and macro-expansion levels before E0119 (lib/TODO.md
/// §11.2: a fixed cap with its own code). Each level costs native stack, so
/// the cap keeps the deepest input inside an 8 MiB stack in Debug.
pub const nesting_max: u32 = 1024;

/// Files one run registers before E0154: the old `diag.files_max`.
pub const files_max: u32 = std.math.maxInt(u16);

/// LRM §10.5. Defined for every run; `undef on these has no effect.
pub const predefined_macros = [_][]const u8{
    "__VAMS_ENABLE__",
    "__VAMS_COMPACT_MODELING__",
    // §10.5's simulator macro; the spelling avoids the reserved `__VAMS_`.
    "__VERA__",
};

const Preprocessor = @This();

/// One source unit, borrowed.
const Unit = struct { name: []const u8, text: []const u8 };

/// Returns a preprocessor with no units. `options` is borrowed for its life.
pub fn init(gpa: Allocator, options: Options) Preprocessor {
    assert(options.text_limit <= max_text_bytes);
    return .{ .gpa = gpa, .options = options, .arena = .init(gpa) };
}

/// Frees everything; every slice `run` and `output` returned dies with it.
pub fn deinit(pp: *Preprocessor) void {
    var it = pp.answers.keyIterator();
    while (it.next()) |k| pp.gpa.free(k.*);
    pp.answers.deinit(pp.gpa);
    if (pp.want) |w| pp.gpa.free(w);
    pp.units.deinit(pp.gpa);
    pp.arena.deinit();
    pp.* = undefined;
}

/// Appends a unit, after those already added (IEEE 1364 §13.4.1: one text
/// stream). The first unit's name is what `__FILE__` reads in it and its
/// directory is searched first for its `include`s; a name starting with `<`
/// has none. Both slices are borrowed until `deinit`. Asserts that no run
/// started.
pub fn addUnit(pp: *Preprocessor, name: []const u8, text: []const u8) Allocator.Error!void {
    assert(pp.want == null);
    assert(pp.result.text.len == 0);
    assert(text.len <= max_text_bytes);
    try pp.units.append(pp.gpa, .{ .name = name, .text = text });
}

/// Runs the units until the output is done (null) or a file is needed (a
/// request, answered with `answer` before the next call). Diagnostics are
/// in `output`, not an error. Asserts at least one unit and no unanswered
/// request.
///
/// Each call preprocesses from the start, reusing every answer so far, so
/// a run of n requests costs n + 1 passes.
/// ponytail: a restart per request, O(requests * text); resuming would need
/// the recursive scan as an explicit frame stack.
pub fn run(pp: *Preprocessor) Allocator.Error!?Request {
    assert(pp.units.items.len > 0);
    assert(pp.want == null);
    _ = pp.arena.reset(.retain_capacity);
    var pass: Pass = .{ .arena = pp.arena.allocator(), .opts = &pp.options, .answers = &pp.answers };
    const failed = if (runUnits(&pass, pp.units.items)) |_| false else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PreprocessFailed => true,
        error.NeedFile => {
            assert(!pp.answers.contains(pass.want));
            pp.want = try pp.gpa.dupe(u8, pass.want);
            return .{ .file = .{ .path = pp.want.? } };
        },
    };
    if (failed) assert(pass.diags.items.len > 0);
    pp.result = publish(&pass, failed);
    return null;
}

/// Answers the last request: the file's bytes, or null for "not there".
/// `bytes` is borrowed until `deinit`. Asserts a pending request.
pub fn answer(pp: *Preprocessor, bytes: ?[]const u8) Allocator.Error!void {
    const path = pp.want.?;
    try pp.answers.putNoClobber(pp.gpa, path, bytes);
    pp.want = null;
    assert(pp.answers.contains(path));
}

/// Returns the last finished run's output; empty before one finished.
pub fn output(pp: *const Preprocessor) Output {
    if (pp.result.text.len != 0) assert(pp.want == null);
    return pp.result;
}

/// Returns the offset in `File.source` of `offset` in `File.text`, through
/// the file's strip marks. O(log marks).
pub fn toSourceOffset(marks: []const StripMark, offset: u32) u32 {
    if (marks.len == 0 or offset < marks[0].out) return offset;
    const lo = std.sort.partitionPoint(StripMark, marks, offset, markAtOrBefore) - 1;
    assert(marks[lo].out <= offset);
    assert(marks[lo].src >= marks[lo].out);
    return marks[lo].src +| (offset - marks[lo].out);
}

// ---- private ----

/// The spine: the first unit registered (so it is file 0), the §10.5
/// macros, the prelude, the command-line macros, every unit in order, and
/// E0101 for a conditional left open at the end of the stream.
fn runUnits(pp: *Pass, units: []const Unit) Pass.Error!void {
    assert(units.len > 0);
    const root = try pp.addFile(units[0].name, units[0].text);
    for (predefined_macros) |name| try pp.putMacro(name, .{ .body = "1", .predefined = true });
    if (pp.opts.std_defs) try pp.runStdDefs() else if (pp.opts.spice_primitives) try pp.runSpicePrimitives();
    for (pp.opts.defines) |d| {
        const eq = std.mem.findScalar(u8, d, '=');
        try pp.putMacro(d[0 .. eq orelse d.len], .{ .body = if (eq) |i| d[i + 1 ..] else "1" });
    }
    try pp.out.ensureUnusedCapacity(pp.arena, units[0].text.len);
    try pp.runFile(units[0].text, units[0].name, root);
    for (units[1..]) |u| {
        // A unit need not end in a newline, and its last word must not join
        // the next unit's first.
        try pp.out.append(pp.arena, '\n');
        try pp.unit_starts.append(pp.arena, @intCast(pp.out.items.len));
        try pp.runFile(u.text, u.name, .none);
    }
    if (pp.conds.items.len != 0) {
        // E0101 points at the end of the file the open `ifdef is in.
        const top = pp.conds.items[pp.conds.items.len - 1];
        pp.cur_file = top.file;
        pp.expand_site = null;
        const len: u32 = @intCast(pp.file(top.file).text.len);
        return pp.fail(.point(len), "E0101", "`ifdef at offset {d} is never closed", .{top.span.start});
    }
    assert(pp.expanding.items.len == 0);
}

/// The pass's tables as the `Output`, by name for the event lists.
fn publish(pp: *const Pass, failed: bool) Output {
    var directives: Directives = .{};
    inline for (@typeInfo(Directives).@"struct".field_names) |name| {
        @field(directives, name) = @field(pp.events, name).items;
    }
    return .{
        .text = pp.out.items,
        .files = pp.files.items,
        .source_map = pp.maps.items,
        .directives = directives,
        .diagnostics = pp.diags.items,
        .failed = failed,
        .unit_starts = pp.unit_starts.items,
        .annex_d_included = pp.annex_d_included,
        .disciplines_included = pp.disciplines_included,
    };
}

fn mappedAtOrBefore(offset: u32, m: Mapping) bool {
    return m.out <= offset;
}

fn markAtOrBefore(offset: u32, m: StripMark) bool {
    return m.out <= offset;
}

test {
    _ = @import("Preprocessor/tests.zig");
    _ = @import("Preprocessor/scan.zig");
    _ = @import("Preprocessor/handlers.zig");
    _ = protect;
}

test "a `define expands where it is used" {
    // Oracle: §10.4's own example shape, worked by hand.
    var pp: Preprocessor = .init(std.testing.allocator, .{ .std_defs = false });
    defer pp.deinit();
    try pp.addUnit("<source>", "`define W 8\nwire [`W-1:0] x;\n");
    try std.testing.expectEqual(@as(?Request, null), try pp.run());
    try std.testing.expectEqualStrings("\nwire [8-1:0] x;\n", pp.output().text);
}
