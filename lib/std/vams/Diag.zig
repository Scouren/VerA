//! The diagnostics of one compilation: coded rows in (from every stage,
//! through `Wip`), one immutable bundle out, which renders as terminal text,
//! JSON Lines, or an LSP's rows. Zig's `std.zig.ErrorBundle` layout
//! (`string_bytes` + `extra`), with the columns VerA adds: a `Code` whose
//! first letter is its severity, a `Stage`, labels, notes and fix-its.
//!
//! A location is `Loc{ file, start, end }`: a byte range in the ORIGINAL
//! text of one file (comments and all), as the caller numbers its files.
//! The bundle holds no file table and no macro map; rendering takes the
//! caller's `Source` table, so this module imports nothing but std.
//!
//! `extra` holds, in order: one `Header`; each kept message as a `Message`
//! followed by its `Label`s and `Note`s; then `Header.len` `MessageIndex`
//! words at `Header.start`, in source order. Every record is an extern
//! struct of 4-byte words, so a read is a pointer cast. Both arrays empty
//! is the special encoding of "nothing reported".
//!
//! Cites no LRM clause: each code's catalogue row cites its own.
//!
//! Contents:
//! - catalogue: `Code`, `Info`, `info`, `Severity` (`word`), `severityOf`
//! - levels: `Level`, `Levels`
//! - rows: `Stage`, `File`, `Loc` (`none`, `isNone`), `String`,
//!   `MessageIndex`, `Header`, `Message` (`Tag`), `Label`, `Note` (`Kind`),
//!   `Fix`, `max_entries`, `max_children`
//! - the bundle: `string_bytes`, `extra`, `empty`, `deinit`, `header`,
//!   `count`, `failed`, `messages`, `message`, `labels`, `notes`, `string`
//! - building: `Wip`
//! - rendering: `Source`, `lineStarts`, `Palette`, `RenderOptions`,
//!   `render`, `renderJson`, `explain`
//! - suggestions: `editDistance`, `didYouMean`, `Nearest`, `name_len_max`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const code = @import("Diag/code.zig");
const render_file = @import("Diag/render.zig");
const suggest = @import("Diag/suggest.zig");
/// One `Level` per code, a byte each; see `Diag/Levels.zig`.
pub const Levels = @import("Diag/Levels.zig");
/// Builds a bundle one diagnostic at a time; see `Diag/Wip.zig`.
pub const Wip = @import("Diag/Wip.zig");

/// Every message string, NUL-terminated; byte 0 is a NUL so that
/// `String.none` names no string.
string_bytes: []const u8,
/// `Header`, then the messages with their children, then the index list.
extra: []const u32,

/// Every diagnosable condition; see `Diag/code.zig`.
pub const Code = code.Code;
/// A code's title, LRM clause and `--explain` text.
pub const Info = code.Info;
/// Returns a code's catalogue row with one indexed load.
pub const info = code.info;

/// What the user asked to do with a code: `--allow=`/`--warn=`/`--deny=`/
/// `--forbid=`.
pub const Level = Levels.Level;

/// One file as the renderer reads it; see `Diag/render.zig`.
pub const Source = render_file.Source;
/// Returns the line starts a `Source` carries.
pub const lineStarts = render_file.lineStarts;
/// SGR escapes, or none.
pub const Palette = render_file.Palette;
/// What `render` draws besides each diagnostic.
pub const RenderOptions = render_file.RenderOptions;
/// Writes a bundle as rustc-shaped terminal text.
pub const render = render_file.render;
/// Writes a bundle as JSON Lines.
pub const renderJson = render_file.renderJson;
/// Writes a code's `--explain` entry.
pub const explain = render_file.explain;

/// Returns an edit distance, or a value above `limit`.
pub const editDistance = suggest.editDistance;
/// Returns the nearest candidate name, if close enough.
pub const didYouMean = suggest.didYouMean;
/// The running minimum `didYouMean` computes.
pub const Nearest = suggest.Nearest;
/// Longest name `editDistance` measures.
pub const name_len_max = suggest.name_len_max;

/// How a kept diagnostic affects the compilation: an `err` fails it. The
/// code's first letter (`severityOf`), unless `--deny` promotes a warning.
pub const Severity = enum(u1) {
    err,
    warning,

    /// Returns the rendered word, also the JSON `level`.
    pub fn word(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
        };
    }
};

/// Which stage reported a diagnostic: the JSON `stage`. `run` is raised
/// while a design runs, after it compiled, so the "could not compile"
/// summary does not count it.
pub const Stage = enum(u3) { preprocess, parse, lower, proof, codegen, run };

/// A file as the caller numbers them: an index into the `Source` table
/// `render` takes.
pub const File = enum(u32) {
    /// The top-level compilation unit.
    root = 0,
    /// No file: with it, `Loc.none`.
    none = std.math.maxInt(u32),
    _,
};

/// A byte range in one file's original text. `end == start` is one caret,
/// or an insertion in a `Fix`. An inverted range is tolerated, not
/// asserted: rendering must survive a bad one from any stage.
pub const Loc = extern struct {
    file: File,
    start: u32,
    end: u32,

    /// No location: no `-->` line, no snippet, a JSON `null`. It sorts
    /// before every located diagnostic.
    pub const none: Loc = .{ .file = .none, .start = 0, .end = 0 };

    /// Returns true for `none`, the only location in no file.
    pub fn isNone(self: Loc) bool {
        return self.file == .none;
    }
};

/// A NUL-terminated string in `string_bytes`.
pub const String = enum(u32) { none = 0, _ };

/// The offset of a `Message` in `extra`.
pub const MessageIndex = enum(u32) { _ };

/// `extra[0..]`: the counts a renderer's trailer and summary print.
pub const Header = extern struct {
    /// Kept messages: the `MessageIndex` words at `start`.
    len: u32,
    start: u32,
    /// Dropped because `max_entries` were kept.
    suppressed: u32,
    /// Dropped because a kept row had the same code, file and start.
    deduped: u32,
    /// Collected as errors, kept or suppressed; a denied warning counts.
    err_count: u32,
    /// Collected as warnings, kept or suppressed.
    warn_count: u32,
    /// The `Stage.run` errors among `err_count`.
    run_err_count: u32,
};

/// One kept diagnostic. Trailing: `tag.labels_len` `Label`s, then
/// `tag.notes_len` `Note`s.
pub const Message = extern struct {
    tag: Tag,
    /// The primary location, where the caret goes.
    loc: Loc,
    /// The headline after `Info.title`; none when the title stands alone.
    msg: String,
    /// Short text beside the primary caret; usually none.
    point: String,

    /// One word of everything a message has of fixed width.
    pub const Tag = packed struct(u32) {
        code: Code,
        severity: Severity,
        stage: Stage,
        labels_len: u3,
        notes_len: u3,
        reserved: u6 = 0,
    };
};

/// A secondary location with its own text, drawn with `-` under it.
pub const Label = extern struct {
    loc: Loc,
    text: String,
};

/// A `= note:` or `= help:` line, with a machine-applicable rewrite when
/// `replacement` is not `.none` (an empty replacement is a deletion and is
/// still a string, so "no fix" stays distinguishable).
pub const Note = extern struct {
    kind: Kind,
    text: String,
    /// What the fix replaces; an empty range inserts.
    fix: Loc,
    replacement: String,

    /// The rendered word, also the JSON `kind`.
    pub const Kind = enum(u32) { note, help };
};

/// A rewrite as a stage hands it to `Wip.Builder.suggest`.
pub const Fix = struct {
    loc: Loc,
    replacement: []const u8,
};

/// Most diagnostics one bundle keeps: a cascade past it would bury the
/// first, real error. The rest are counted in `Header.suppressed`.
pub const max_entries: u32 = 64;

/// Most labels, and most notes, on one diagnostic; later ones are dropped.
pub const max_children: u3 = 4;

/// Nothing reported: no allocation.
pub const empty: Diag = .{ .string_bytes = &.{}, .extra = &.{} };

comptime {
    for (.{ Header, Message, Label, Note }) |T| {
        assert(@alignOf(T) == @alignOf(u32));
        assert(@sizeOf(T) % @sizeOf(u32) == 0);
    }
    assert(@sizeOf(Message) == 24);
    assert(@sizeOf(Label) == 16);
    assert(@sizeOf(Note) == 24);
    assert(max_children <= std.math.maxInt(@FieldType(Message.Tag, "labels_len")));
}

const Diag = @This();

/// Returns the severity the code's first letter carries (`W` a warning,
/// `E` an error), so a code cannot change severity without changing name.
pub fn severityOf(c: Code) Severity {
    const name = @tagName(c);
    assert(name.len == 5);
    assert(name[0] == 'E' or name[0] == 'W');
    return if (name[0] == 'W') .warning else .err;
}

/// Frees a bundle `Wip.toOwnedBundle` returned, with the same `gpa`.
pub fn deinit(d: *Diag, gpa: Allocator) void {
    gpa.free(d.string_bytes);
    gpa.free(d.extra);
    d.* = undefined;
}

/// Returns the counts; all zero for `empty`.
pub fn header(d: Diag) Header {
    if (d.extra.len == 0) return std.mem.zeroes(Header);
    const h = d.record(Header, 0).*;
    assert(h.start + h.len == d.extra.len);
    assert(h.len <= max_entries);
    return h;
}

/// Returns how many diagnostics were kept, at most `max_entries`.
pub fn count(d: Diag) u32 {
    return d.header().len;
}

/// Returns true when anything at `deny` or `forbid` was collected, kept or
/// not: what decides that the compilation failed.
pub fn failed(d: Diag) bool {
    const h = d.header();
    assert(h.run_err_count <= h.err_count);
    return h.err_count != 0;
}

/// Returns the kept messages in source order: the files in caller order
/// with no location first, then start, end and code; equal keys keep their
/// emission order.
pub fn messages(d: Diag) []const MessageIndex {
    const h = d.header();
    return @ptrCast(d.extra[h.start..][0..h.len]);
}

/// Returns the message at `i`, which `messages` gave.
pub fn message(d: Diag, i: MessageIndex) Message {
    return d.record(Message, @backingInt(i)).*;
}

/// Returns `i`'s labels, borrowed from the bundle.
pub fn labels(d: Diag, i: MessageIndex) []const Label {
    const m = d.message(i);
    const start = @backingInt(i) + words(Message);
    return @ptrCast(d.extra[start..][0 .. @as(u32, m.tag.labels_len) * words(Label)]);
}

/// Returns `i`'s notes and help lines, borrowed from the bundle.
pub fn notes(d: Diag, i: MessageIndex) []const Note {
    const m = d.message(i);
    const start = @backingInt(i) + words(Message) + @as(u32, m.tag.labels_len) * words(Label);
    return @ptrCast(d.extra[start..][0 .. @as(u32, m.tag.notes_len) * words(Note)]);
}

/// Returns the bytes of `s`, borrowed from the bundle; `.none` is "".
pub fn string(d: Diag, s: String) [:0]const u8 {
    if (s == .none) return "";
    const start: usize = @backingInt(s);
    assert(d.string_bytes[start - 1] == 0);
    const end = std.mem.findScalarPos(u8, d.string_bytes, start, 0).?;
    return d.string_bytes[start..end :0];
}

// ---- private ----

/// The words `T` takes in `extra`.
fn words(comptime T: type) u32 {
    return @sizeOf(T) / @sizeOf(u32);
}

fn record(d: Diag, comptime T: type, at: u32) *const T {
    assert(at + words(T) <= d.extra.len);
    return @ptrCast(d.extra[at..][0..words(T)]);
}

test {
    _ = code;
    _ = render_file;
    _ = suggest;
    _ = Levels;
    _ = Wip;
    _ = @import("Diag/tests.zig");
}
