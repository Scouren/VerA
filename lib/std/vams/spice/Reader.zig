//! Netlist files in, their physical lines out (lower-cased, comments
//! stripped), `.INCLUDE` and `.LIB` expanded in place as SPICE reads them and
//! HSPICE `.HDL` names recorded. Reads no file: a card naming one whose bytes
//! are not in `answers` stops `step`, which returns the path; the caller
//! answers and steps again, and the reader resumes at that card. The files
//! being read are an explicit frame stack, so nesting costs heap, not native
//! stack. A file that cannot be read, a missing entry or a cycle is a
//! refusal at the card.
//! Cites: LRM annex E.1.2, E.2; specification/Vague_Decisions.md VD-091.
//!
//! Contents:
//! - fields `arena`, `scratch`, `refusals`, `lines`, `files`, `hdl`, `frames`
//! - `pub fn start(r: *Reader, name: []const u8, text: []const u8) Allocator.Error!void`
//! - `pub fn step(r: *Reader, answers: *const Answers) Allocator.Error!?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const spice = @import("../spice.zig");
const card_ = @import("card.zig");
const Card = card_.Card;
const Refusals = card_.Refusals;
const File = spice.File;
const hasEntry = card_.hasEntry;
const unquote = card_.unquote;
const strip = card_.strip;

/// Owns `files` and `hdl`. The caller sets both allocators before each
/// `start` or `step`: they point into it.
arena: Allocator,
/// Owns `lines`, `frames` and the lowered copies; freed by the caller after
/// the read.
scratch: Allocator,
/// The read's refusals, in the order met, on their own `arena`.
refusals: Refusals,
/// Every physical line read, one `Card` each, in reading order.
lines: std.ArrayList(Card) = .empty,
/// Every file opened, in opening order; a file opened twice has two rows.
files: std.ArrayList(File) = .empty,
/// `.HDL` names, resolved, each once, in card order.
hdl: std.ArrayList([]const u8) = .empty,
/// The files being read now, outermost first. Reading one of them again
/// (the same path and `.LIB` entry) is a cycle.
frames: std.ArrayList(Frame) = .empty,

/// The caller's answers by path: bytes, or null for "cannot read".
pub const Answers = std.StringHashMapUnmanaged(?[]const u8);

const Reader = @This();

/// One file being read: from `pos` on, the lines of `files[file]`, or with
/// `entry` only those of its `.LIB entry` block.
const Frame = struct {
    file: u32,
    entry: ?[]const u8,
    /// `files[file].name` with `.` and `..` resolved: the cycle key.
    key: []const u8,
    /// Where the next line starts in `files[file].text`; past its end when
    /// the last line is read.
    pos: usize = 0,
    /// Inside a `.LIB name` block: true when it is the entry asked for.
    in_lib: ?bool = null,
    /// The open block's header, so an `.ENDL` that never comes is reported.
    header: Card = undefined,
    /// The `.LIB file entry` call that opened this frame, checked when it
    /// pops: an entry the file does not have is a refusal there.
    call: ?Call,
};

const Call = struct { at: Card, lines_before: usize };

/// Opens `name` (the netlist, `files[0]`) for `step`. A relative `.INCLUDE`
/// is looked for beside `name`, or in the working directory when `name`
/// starts with `<`. Asserts that nothing was read yet.
pub fn start(r: *Reader, name: []const u8, text: []const u8) Allocator.Error!void {
    assert(r.files.items.len == 0);
    assert(name.len != 0);
    try r.files.append(r.arena, .{ .name = name, .text = text });
    try r.push(0, null, null);
    assert(r.frames.items.len == 1);
}

/// Reads on until every frame is done (null) or a card names a file whose
/// bytes are not in `answers` (its path, on `scratch`).
/// Answered again, the same card is read again from its start.
pub fn step(r: *Reader, answers: *const Answers) Allocator.Error!?[]const u8 {
    // Each round reads a line, pushes a frame or pops one; each frame pops
    // once, so the loop ends with the input.
    while (r.frames.items.len != 0) {
        if (try r.advance(answers)) |want| return want;
    }
    assert(r.frames.items.len == 0);
    return null;
}

// ---- private ----

fn push(r: *Reader, file: u32, entry: ?[]const u8, call: ?Call) Allocator.Error!void {
    assert(file < r.files.items.len);
    const key = try std.fs.path.resolve(r.scratch, &.{r.files.items[file].name});
    try r.frames.append(r.scratch, .{ .file = file, .entry = entry, .key = key, .call = call });
}

/// Reads the top frame's lines until it pushes a frame or pops (null), or a
/// card needs a file (its path).
fn advance(r: *Reader, answers: *const Answers) Allocator.Error!?[]const u8 {
    const depth = r.frames.items.len;
    assert(depth != 0);
    const f = &r.frames.items[depth - 1];
    const fi = f.file;
    const text = r.files.items[fi].text;
    while (f.pos <= text.len) {
        const line_start = f.pos;
        const end = std.mem.findScalarPos(u8, text, f.pos, '\n') orelse text.len;
        f.pos = end + 1;
        const line = strip(text[line_start..end]);
        if (line.len == 0) continue;
        const at: Card = .{ .text = line, .file = fi, .at = @intCast(line.ptr - text.ptr), .len = @intCast(line.len) };
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const kw = try std.ascii.allocLowerString(r.scratch, it.next().?);
        const arg = unquote(it.next() orelse "");
        const arg2 = unquote(it.next() orelse "");
        if (std.mem.eql(u8, kw, ".lib") and arg2.len == 0) {
            // A library entry's header, not a call.
            if (f.in_lib == null) {
                f.in_lib = if (f.entry) |e| std.ascii.eqlIgnoreCase(e, arg) else false;
                f.header = at;
            }
            continue;
        }
        if (std.mem.eql(u8, kw, ".endl")) {
            const done = f.in_lib orelse false;
            f.in_lib = null;
            if (done) {
                try r.pop();
                return null;
            }
            continue;
        }
        if (f.entry != null and !(f.in_lib orelse false)) continue;
        if (f.in_lib == false) continue;
        const include = std.mem.eql(u8, kw, ".include") or std.mem.eql(u8, kw, ".inc");
        if (include or std.mem.eql(u8, kw, ".lib")) {
            if (arg.len == 0) {
                try r.refusals.add(at, "`{s}` names no file", .{kw});
                continue;
            }
            const full = try r.resolve(fi, arg);
            const got = answers.get(full) orelse {
                // Asked for; this card is read again once it is answered.
                f.pos = line_start;
                return full;
            };
            const bytes = got orelse {
                try r.refusals.add(at, "`{s}`: cannot read \"{s}\" (FileNotFound)", .{ kw, full });
                continue;
            };
            try r.files.append(r.arena, .{ .name = try r.arena.dupe(u8, full), .text = bytes });
            const sub: u32 = @intCast(r.files.items.len - 1);
            const sub_entry: ?[]const u8 = if (include) null else arg2;
            if (try r.cycle(sub, sub_entry)) |chain| {
                try r.refusals.add(at, "`{s}` cycle: {s}", .{ kw, chain });
                continue;
            }
            // `f` dies with the push; this frame resumes after the card.
            try r.push(sub, sub_entry, if (include) null else .{ .at = at, .lines_before = r.lines.items.len });
            return null;
        }
        if (std.mem.eql(u8, kw, ".hdl")) {
            if (arg.len == 0) {
                try r.refusals.add(at, "`.hdl` names no file", .{});
                continue;
            }
            const full = try r.resolve(fi, arg);
            for (r.hdl.items) |h| {
                if (std.mem.eql(u8, h, full)) break;
            } else try r.hdl.append(r.arena, try r.arena.dupe(u8, full));
            continue;
        }
        var lowered = at;
        lowered.text = try std.ascii.allocLowerString(r.scratch, line);
        try r.lines.append(r.scratch, lowered);
    }
    if (f.in_lib != null) try r.refusals.add(f.header, "`.lib` entry has no `.endl`; the cards after it are not read", .{});
    try r.pop();
    return null;
}

/// Closes the top frame; a `.LIB file entry` call that read no line from a
/// file with no such entry is refused at the call.
fn pop(r: *Reader) Allocator.Error!void {
    const n = r.frames.items.len;
    const f = r.frames.pop().?;
    assert(r.frames.items.len == n - 1);
    const call = f.call orelse return;
    assert(f.entry != null);
    const file = r.files.items[f.file];
    if (r.lines.items.len == call.lines_before and !hasEntry(file.text, f.entry.?))
        try r.refusals.add(call.at, "`{s}` has no `.lib {s}` entry", .{ file.name, f.entry.? });
}

/// Returns the chain `a -> b -> a` when reading file `fi` (`entry` of it)
/// now would repeat a read still open, else null.
fn cycle(r: *Reader, fi: u32, entry: ?[]const u8) Allocator.Error!?[]const u8 {
    assert(fi < r.files.items.len);
    const key = try std.fs.path.resolve(r.scratch, &.{r.files.items[fi].name});
    for (r.frames.items, 0..) |o, k| {
        const same_entry = if (o.entry) |a| (if (entry) |b| std.ascii.eqlIgnoreCase(a, b) else false) else entry == null;
        if (!same_entry or !std.mem.eql(u8, o.key, key)) continue;
        var chain: std.ArrayList(u8) = .empty;
        for (r.frames.items[k..]) |c| try chain.print(r.scratch, "{s} -> ", .{c.key});
        try chain.appendSlice(r.scratch, key);
        return chain.items;
    }
    return null;
}

/// Returns `name` beside the file `fi` was opened by, or as written when
/// absolute, on `scratch`.
fn resolve(r: *Reader, fi: u32, name: []const u8) Allocator.Error![]const u8 {
    assert(fi < r.files.items.len);
    assert(r.files.items[0].name.len != 0);
    if (std.fs.path.isAbsolute(name)) return r.scratch.dupe(u8, name);
    const dir = std.fs.path.dirname(r.files.items[fi].name) orelse ".";
    const base = if (fi == 0 and r.files.items[0].name[0] == '<') "." else dir;
    return std.fs.path.join(r.scratch, &.{ base, name });
}
