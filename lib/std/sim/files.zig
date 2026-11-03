//! IEEE 1364-2005 §17.2 file input and output: descriptors and a file
//! operation's arguments in, its result and its effect on the run's
//! descriptor table (`State.files`, kernels' `ZfTable`) out; a display's
//! text routed to the channels a descriptor names (bit 0 / fd 1 is the
//! transcript itself).
//! Cites: IEEE 1364-2005 §17.2.1, §17.2.2, §17.2.4.1, §17.2.4.2, §17.2.5,
//! §17.2.6, §17.2.7; VAMS §9.5.1 Table 9-24.
//!
//! Contents:
//! - `pub fn call(s: *State, a: Allocator, at: u32) Error!i64`
//! - `pub fn fshow(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn fclose(s: *State, a: Allocator, row: u32) Error!void`
//! - `pub fn closeAll(s: *State) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const kernels = @import("kernels");
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const display = @import("display.zig");
const calls = @import("calls.zig");
const readmem = @import("readmem.zig");
const Error = State.Error;

/// Runs the file function at `at` (a `Program.FileCall`) and returns its
/// §17.2 result: a descriptor, a character, a count, a position or a code.
pub fn call(s: *State, a: Allocator, at: u32) Error!i64 {
    const p = s.p;
    const c = p.extraData(Program.FileCall, at);
    const none = @backingInt(Program.Ref.none);
    const io = s.io orelse return switch (c.op) {
        .fopen, .fgets, .ferror => 0,
        else => -1, // else: EOF, the error answer of the rest
    };
    const t = &s.files;
    const eof: i64 = -1;
    switch (c.op) {
        .fopen => {
            const name = (try readmem.text(a, try eval.eval(s, a, c.x))) orelse return 0;
            const mcd = c.y == none;
            const ty = if (mcd) "w" else (try readmem.text(a, try eval.eval(s, a, c.y))) orelse return 0;
            if (!kernels.fopen_types.has(ty)) return 0;
            // A file read is looked for beside the source first.
            if (ty[0] == 'r') if (std.Io.Dir.path.dirname(p.str(p.file_name))) |dir| {
                const d = t.open(s.arena, io, try std.Io.Dir.path.join(a, &.{ dir, name }), ty, mcd);
                if (d != 0) return d;
            };
            return t.open(s.arena, io, name, ty, mcd);
        },
        .fgets => {
            const d = try descriptor(s, a, c.x) orelse return 0;
            const room = c.ty.width / 8;
            var line: std.ArrayList(u8) = .empty;
            while (line.items.len < room) {
                const ch = t.getc(io, d);
                if (ch < 0) break;
                try line.append(a, @intCast(ch));
                if (ch == '\n') break;
            }
            if (line.items.len != 0) try assignText(s, a, c.place, c.ty, line.items);
            return @intCast(line.items.len);
        },
        .ferror => {
            const code = t.err((try descriptor(s, a, c.x)) orelse 0);
            try assignText(s, a, c.place, c.ty, kernels.file_kernels.zFErrorStr(code, 0));
            return code;
        },
        .fgetc => return t.getc(io, (try descriptor(s, a, c.x)) orelse return eof),
        .ungetc => {
            const ch = (try eval.eval(s, a, c.x)).asInt() orelse return eof;
            return t.ungetc(ch, (try descriptor(s, a, c.y)) orelse return eof);
        },
        .ftell => return t.tell((try descriptor(s, a, c.x)) orelse return eof),
        .rewind => return t.seek(io, (try descriptor(s, a, c.x)) orelse return eof, 0, 0),
        .fseek => {
            const d = (try descriptor(s, a, c.x)) orelse return eof;
            const offset = (try eval.eval(s, a, c.y)).asInt() orelse return eof;
            const whence = (try eval.eval(s, a, c.z)).asInt() orelse return eof;
            if (whence < 0 or whence > 2) return eof;
            return t.seek(io, d, offset, whence);
        },
        .feof => return t.eof((try descriptor(s, a, c.x)) orelse return eof),
    }
}

/// §17.2.2 `$fdisplay`/`$fwrite` (`Program.FShow` at `at`): the show's text
/// to every channel its descriptor names.
pub fn fshow(s: *State, a: Allocator, at: u32) Error!void {
    const f = s.p.extraData(Program.FShow, at);
    const d = (try descriptor(s, a, f.fd)) orelse return;
    var buf: std.Io.Writer.Allocating = .init(a);
    const saved = s.out;
    s.out = &buf.writer;
    defer s.out = saved;
    try display.show(s, a, f.show, 0);
    s.out = saved;
    if (try channels(s, d, buf.written()))
        try s.warn("no file this descriptor names is open for writing: the output is not written", .{});
}

/// §17.2.7 `$fclose` of the descriptor row `row`.
pub fn fclose(s: *State, a: Allocator, row: u32) Error!void {
    const d = (try descriptor(s, a, row)) orelse return;
    const io = s.io orelse return;
    _ = s.files.close(io, d);
}

/// Closes every channel the run opened: the run is over.
pub fn closeAll(s: *State) void {
    const io = s.io orelse return;
    s.files.freeAll(s.arena, io);
}

// ---- private ----

/// A descriptor argument's low 32 bits; null when x or z.
fn descriptor(s: *State, a: Allocator, row: u32) Error!?i64 {
    const v = (try eval.eval(s, a, row)).asInt() orelse return null;
    return v & 0xffff_ffff;
}

/// Writes `bytes` to every channel `d` names: the transcript for an mcd's
/// bit 0 or fd 1, stderr for fd 2, the table for the rest. Whether a file
/// write found nothing open.
fn channels(s: *State, d: i64, bytes: []const u8) Error!bool {
    const fd = d & (@as(i64, 1) << 31) != 0;
    const ch = d & 0x7fff_ffff;
    if ((fd and ch == 1) or (!fd and d & 1 != 0)) try s.out.writeAll(bytes);
    if (fd and ch == 2) if (s.io) |i| std.Io.File.stderr().writeStreamingAll(i, bytes) catch {};
    const rest = if (fd) (if (ch > 2) d else 0) else d & ~@as(i64, 1);
    if (rest == 0 or bytes.len == 0) return false;
    const io = s.io orelse return false;
    return s.files.put(io, rest, bytes) == 0;
}

/// A §3.6 string assigned to a place of type `ty`.
fn assignText(s: *State, a: Allocator, place: u32, ty: Program.Ty, text: []const u8) Error!void {
    const v = try logic.stringLiteral(a, text);
    try eval.put(s, a, place, try calls.convertValue(a, v, false, ty), false, null);
}
