//! The builder: one diagnostic's parts in (headline, caret text, labels,
//! notes, fix-its) from any stage, a `Diag` bundle out once the compilation
//! is done. The lint level, the dedupe key and the cap decide at `emit`
//! what is kept; `toOwnedBundle` sorts the kept rows into source order.
//! Zig's `ErrorBundle.Wip` (lib/std/zig/ErrorBundle.zig:356), with lib/diag's
//! per-diagnostic `Builder`.
//!
//! Cites no LRM clause: the stage that reports a diagnostic cites it.
//!
//! Contents:
//! - fields `gpa`, `levels`, `string_bytes`, `extra`, `roots`, the counters
//! - `pub fn init(gpa: Allocator) Wip`, `pub fn deinit(wip: *Wip) void`
//! - `pub fn build(wip: *Wip, stage: Stage, c: Code, loc: Loc) Builder`
//! - `pub fn add(wip: *Wip, stage: Stage, c: Code, loc: Loc, comptime fmt: []const u8, args: anytype) Allocator.Error!void`
//! - `pub fn enabled(wip: *const Wip, c: Code) bool`, `pub fn failed(wip: *const Wip) bool`
//! - `pub fn toOwnedBundle(wip: *Wip) Allocator.Error!Diag`
//! - `pub const Builder = struct`, `State`, with `msg`, `point`, `label`,
//!   `note`, `help`, `suggest`, `suggestHere`, `emit`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Diag = @import("../Diag.zig");
const Code = Diag.Code;
const Loc = Diag.Loc;
const Stage = Diag.Stage;
const String = Diag.String;
const Severity = Diag.Severity;
const MessageIndex = Diag.MessageIndex;
const max_children = Diag.max_children;
const max_entries = Diag.max_entries;

/// Owns every table below and the bundle `toOwnedBundle` returns.
gpa: Allocator,
/// The lint levels; the caller copies its own in (`wip.levels = lint`).
levels: Diag.Levels = .empty,
/// `Diag.string_bytes` as it grows; empty until the first part interns.
string_bytes: std.ArrayList(u8) = .empty,
/// `Diag.extra` as it grows: the header slot, then the messages.
extra: std.ArrayList(u32) = .empty,
/// Every kept message, in emission order; at most `max_entries`.
roots: std.ArrayList(MessageIndex) = .empty,
/// `Diag.Header`'s counters, as `emit` moves them.
suppressed: u32 = 0,
deduped: u32 = 0,
err_count: u32 = 0,
warn_count: u32 = 0,
run_err_count: u32 = 0,

/// Accumulates one diagnostic's parts, then commits them with `emit`, the
/// only fallible call: an allocation failure in a part is latched and
/// reported there. Text is interned as it is built, so a builder borrows
/// its `Wip` and must not outlive it. Labels past `max_children` are
/// dropped, and so are notes, helps and suggestions, which share slots.
pub const Builder = struct {
    // ponytail: no rollback. A builder `build` knows is dropped interns
    // nothing; one that `emit` dedupes, or that meets the cap after
    // `build`, leaves its strings in the pool. A mark-and-truncate in
    // `emit`, guarded against interleaved builders, if that waste shows up.
    wip: *Wip,
    stage: Stage,
    code: Code,
    loc: Loc,
    message: String = .none,
    point_text: String = .none,
    state: State,
    // SAFETY: only the first `label_count`/`note_count` rows are read.
    label_rows: [max_children]Diag.Label = undefined,
    label_count: u3 = 0,
    note_rows: [max_children]Diag.Note = undefined,
    note_count: u3 = 0,
    /// False for a row copied from a bundle already deduped under another
    /// key (a stage's own text, before its locations moved to the files):
    /// two rows that land on one place stay two, as the old bag kept them.
    dedupe: bool = true,

    /// Whether the parts still format.
    pub const State = enum(u8) {
        /// Parts are interned as they come.
        open,
        /// `build` knew `emit` would drop it: every part is skipped.
        dropped,
        /// A part could not grow the pool: `emit` returns `OutOfMemory`.
        out_of_memory,
    };

    /// Sets the headline printed after `Info.title`.
    pub fn msg(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.message = self.text(fmt, args) orelse return;
    }

    /// Sets the short text beside the primary caret. Use it when the caret
    /// must say something the headline does not; otherwise leave it unset.
    pub fn point(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.point_text = self.text(fmt, args) orelse return;
    }

    /// Adds a secondary location with its own text; dropped past
    /// `max_children`.
    pub fn label(self: *Builder, loc: Loc, comptime fmt: []const u8, args: anytype) void {
        assert(self.label_count <= max_children);
        if (self.label_count == max_children) return;
        const t = self.text(fmt, args) orelse return;
        self.label_rows[self.label_count] = .{ .loc = loc, .text = t };
        self.label_count += 1;
    }

    /// Adds a `= note:` line: context, not an instruction.
    pub fn note(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.note, null, fmt, args);
    }

    /// Adds a `= help:` line: what the user should change.
    pub fn help(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.help, null, fmt, args);
    }

    /// Adds a help line with a machine-applicable rewrite; the renderer
    /// shows the patched line under it.
    pub fn suggest(self: *Builder, fix: Diag.Fix, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.help, fix, fmt, args);
    }

    /// Adds a help line that rewrites the primary location: the
    /// did-you-mean of every "unknown name" diagnostic.
    pub fn suggestHere(self: *Builder, replacement: []const u8) void {
        self.suggest(.{ .loc = self.loc, .replacement = replacement }, "did you mean `{s}`?", .{replacement});
    }

    /// Commits the diagnostic. An allowed code is dropped uncounted; a
    /// duplicate (same code, file and start as a kept row) counts in
    /// `deduped`; anything else counts in `err_count` or `warn_count`, and
    /// is kept unless `max_entries` are, when it counts in `suppressed`.
    /// Returns `OutOfMemory` if a part failed or the tables cannot grow;
    /// nothing is kept and nothing counted then.
    pub fn emit(self: *Builder) Allocator.Error!void {
        if (self.state == .out_of_memory) return error.OutOfMemory;
        const wip = self.wip;
        assert(wip.roots.items.len <= max_entries);

        const severity: Severity = switch (wip.levels.get(self.code)) {
            .allow => return,
            .warn => Diag.severityOf(self.code),
            // `--deny=W0650` promotes the warning to a hard error.
            .deny, .forbid => .err,
        };

        // ponytail: a linear scan, bounded by `max_entries`.
        if (self.dedupe) for (wip.roots.items) |i| {
            const m = wip.bundle().message(i);
            if (m.tag.code == self.code and m.loc.file == self.loc.file and m.loc.start == self.loc.start) {
                wip.deduped += 1;
                return;
            }
        };

        // Room first, so the counters and the rows move together or not
        // at all.
        const full = wip.roots.items.len == max_entries;
        if (!full) {
            const n = words(Diag.Message) + @as(u32, self.label_count) * words(Diag.Label) +
                @as(u32, self.note_count) * words(Diag.Note);
            try wip.reserveHeader();
            try wip.extra.ensureUnusedCapacity(wip.gpa, n);
            try wip.roots.ensureTotalCapacity(wip.gpa, max_entries);
        }

        // Counted before the cap: an error the cap drops still fails the
        // compilation and still counts in the summary.
        switch (severity) {
            .err => {
                wip.err_count += 1;
                if (self.stage == .run) wip.run_err_count += 1;
            },
            .warning => wip.warn_count += 1,
        }
        if (full) {
            wip.suppressed += 1;
            return;
        }
        self.commit(severity);
    }

    // ---- private ----

    /// Interns one formatted part, or returns null when the diagnostic is
    /// dropped or the pool cannot grow (latching `out_of_memory`).
    fn text(self: *Builder, comptime fmt: []const u8, args: anytype) ?String {
        if (self.state != .open) return null;
        const s = self.wip.printString(fmt, args) catch {
            self.state = .out_of_memory;
            return null;
        };
        assert(s != .none);
        return s;
    }

    fn pushNote(self: *Builder, kind: Diag.Note.Kind, fix: ?Diag.Fix, comptime fmt: []const u8, args: anytype) void {
        assert(self.note_count <= max_children);
        if (self.note_count == max_children) return;
        const t = self.text(fmt, args) orelse return;
        // Interned, never `.none`, even when empty: `.none` says "no fix".
        const replacement: String = if (fix) |f| self.text("{s}", .{f.replacement}) orelse return else .none;
        self.note_rows[self.note_count] = .{
            .kind = kind,
            .text = t,
            .fix = if (fix) |f| f.loc else .none,
            .replacement = replacement,
        };
        self.note_count += 1;
    }

    /// Appends the message and its children into the room `emit` reserved.
    fn commit(self: *const Builder, severity: Severity) void {
        const wip = self.wip;
        const roots_before = wip.roots.items.len;
        const at: MessageIndex = @fromBackingInt(@as(u32, @intCast(wip.extra.items.len)));
        appendRecord(wip, Diag.Message{
            .tag = .{
                .code = self.code,
                .severity = severity,
                .stage = self.stage,
                .labels_len = self.label_count,
                .notes_len = self.note_count,
            },
            .loc = self.loc,
            .msg = self.message,
            .point = self.point_text,
        });
        for (self.label_rows[0..self.label_count]) |l| appendRecord(wip, l);
        for (self.note_rows[0..self.note_count]) |n| appendRecord(wip, n);
        wip.roots.appendAssumeCapacity(at);
        assert(wip.roots.items.len == roots_before + 1);
        assert(wip.bundle().message(at).tag.code == self.code);
    }
};

const Wip = @This();

/// Returns an empty builder. Allocates nothing: a compilation that reports
/// nothing costs no memory.
pub fn init(gpa: Allocator) Wip {
    const wip: Wip = .{ .gpa = gpa };
    assert(wip.roots.items.len == 0);
    assert(wip.extra.items.len == 0);
    return wip;
}

/// Frees everything not yet handed out by `toOwnedBundle`.
pub fn deinit(wip: *Wip) void {
    wip.string_bytes.deinit(wip.gpa);
    wip.extra.deinit(wip.gpa);
    wip.roots.deinit(wip.gpa);
    wip.* = undefined;
}

/// Starts one diagnostic; nothing is kept until `Builder.emit`. A code at
/// `allow`, or a full `Wip`, gets a builder that formats nothing.
pub fn build(wip: *Wip, stage: Stage, c: Code, loc: Loc) Builder {
    assert(wip.roots.items.len <= max_entries);
    const dropped = wip.levels.get(c) == .allow or wip.roots.items.len == max_entries;
    return .{ .wip = wip, .stage = stage, .code = c, .loc = loc, .state = if (dropped) .dropped else .open };
}

/// Reports one diagnostic with a headline and nothing else, in one call.
/// Fails as `Builder.emit` does.
pub fn add(wip: *Wip, stage: Stage, c: Code, loc: Loc, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    var b = wip.build(stage, c, loc);
    b.msg(fmt, args);
    return b.emit();
}

/// Returns true when a diagnostic with code `c` would be collected at all,
/// so a stage can skip building an expensive message for an allowed lint.
pub fn enabled(wip: *const Wip, c: Code) bool {
    const on = wip.levels.get(c) != .allow;
    if (!on) assert(Diag.severityOf(c) == .warning); // An error cannot be allowed.
    return on;
}

/// Returns true when anything at `deny` or `forbid` was collected, kept or
/// not.
pub fn failed(wip: *const Wip) bool {
    assert(wip.run_err_count <= wip.err_count);
    return wip.err_count != 0;
}

/// Returns the bundle, its messages in source order (see `Diag.messages`),
/// owned by the caller (`Diag.deinit(gpa)`), and leaves the `Wip` empty
/// with its levels kept. Returns `Diag.empty` when nothing was kept. On
/// `OutOfMemory` the `Wip` keeps every row, and a later call can retry.
pub fn toOwnedBundle(wip: *Wip) Allocator.Error!Diag {
    const gpa = wip.gpa;
    const levels = wip.levels;
    if (wip.roots.items.len == 0) {
        assert(wip.err_count == 0);
        assert(wip.warn_count == 0);
        wip.deinit();
        wip.* = .{ .gpa = gpa, .levels = levels };
        return .empty;
    }
    const len: u32 = @intCast(wip.roots.items.len);
    try wip.extra.ensureUnusedCapacity(gpa, len);
    std.mem.sort(MessageIndex, wip.roots.items, wip.bundle(), sourceOrder);
    const header: Diag.Header = .{
        .len = len,
        .start = @intCast(wip.extra.items.len),
        .suppressed = wip.suppressed,
        .deduped = wip.deduped,
        .err_count = wip.err_count,
        .warn_count = wip.warn_count,
        .run_err_count = wip.run_err_count,
    };
    @memcpy(wip.extra.items[0..words(Diag.Header)], @as(*const [words(Diag.Header)]u32, @ptrCast(&header)));
    wip.extra.appendSliceAssumeCapacity(@ptrCast(wip.roots.items));
    errdefer wip.extra.shrinkRetainingCapacity(header.start);
    try wip.string_bytes.shrinkToLen(gpa);
    try wip.extra.shrinkToLen(gpa);
    errdefer comptime unreachable;
    const d: Diag = .{ .string_bytes = wip.string_bytes.toOwnedSliceAssert(), .extra = wip.extra.toOwnedSliceAssert() };
    wip.roots.deinit(gpa);
    wip.* = .{ .gpa = gpa, .levels = levels };
    assert(d.count() == len);
    return d;
}

// ---- private ----

/// The bundle as it stands, for reading back committed messages.
fn bundle(wip: *const Wip) Diag {
    return .{ .string_bytes = wip.string_bytes.items, .extra = wip.extra.items };
}

/// Formats one NUL-terminated string into the pool; the first one also
/// writes the sentinel NUL.
fn printString(wip: *Wip, comptime fmt: []const u8, args: anytype) Allocator.Error!String {
    if (wip.string_bytes.items.len == 0) try wip.string_bytes.append(wip.gpa, 0);
    const start = wip.string_bytes.items.len;
    assert(start < std.math.maxInt(u32));
    errdefer wip.string_bytes.shrinkRetainingCapacity(start);
    try wip.string_bytes.print(wip.gpa, fmt, args);
    try wip.string_bytes.append(wip.gpa, 0);
    assert(wip.string_bytes.items[start - 1] == 0);
    return @fromBackingInt(@as(u32, @intCast(start)));
}

/// Writes the header slot before the first message; its words are filled
/// by `toOwnedBundle`.
fn reserveHeader(wip: *Wip) Allocator.Error!void {
    if (wip.extra.items.len != 0) return;
    try wip.extra.appendNTimes(wip.gpa, 0, words(Diag.Header));
    assert(wip.extra.items.len == words(Diag.Header));
}

fn appendRecord(wip: *Wip, value: anytype) void {
    const T = @TypeOf(value);
    wip.extra.appendSliceAssumeCapacity(@as(*const [words(T)]u32, @ptrCast(&value)));
}

fn words(comptime T: type) u32 {
    return @sizeOf(T) / @sizeOf(u32);
}

/// `toOwnedBundle`'s key: no location first, then file, start, end, code.
fn sourceOrder(d: Diag, a: MessageIndex, b: MessageIndex) bool {
    const x = d.message(a);
    const y = d.message(b);
    if (x.loc.isNone() != y.loc.isNone()) return x.loc.isNone();
    if (x.loc.file != y.loc.file) return @backingInt(x.loc.file) < @backingInt(y.loc.file);
    if (x.loc.start != y.loc.start) return x.loc.start < y.loc.start;
    if (x.loc.end != y.loc.end) return x.loc.end < y.loc.end;
    return @backingInt(x.tag.code) < @backingInt(y.tag.code);
}
