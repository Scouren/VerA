//! IEEE 1364-2005 §17.2.9 `$readmemb`/`$readmemh`: a memory file's bytes in,
//! words stored into an unpacked array's element slots out. A malformed or
//! unreadable file ends the load with a coded warning (`State.warn`,
//! W1150/W1156/W1157) and the run goes on; words already stored stay
//! (VD-134).
//! Cites: IEEE 1364-2005 §3.5.1, §17.2.9; docs/specification/Vague_Decisions.md
//! VD-040, VD-041, VD-134.
//!
//! Contents:
//! - `pub fn readMemory(s: *State, a: Allocator, at: u32) Error!void`
//! - `pub fn text(a: Allocator, v: Literal) Error!?[]const u8`
//! - `pub fn sideFile(io: std.Io, a: Allocator, file_name: []const u8, name: []const u8) !std.Io.File`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const Error = State.Error;
const Literal = logic.Literal;

/// Whitespace-separated words of a memory file, with `//` and `/* */`
/// comments skipped (a comment may abut a word).
const MemTokens = struct {
    in: *std.Io.Reader,
    token: std.ArrayList(u8) = .empty,

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0c';
    }

    fn peek(self: *MemTokens, k: usize) error{ReadFailed}!?u8 {
        assert(k <= 1);
        const ahead = self.in.peek(k + 1) catch |e| return switch (e) {
            error.EndOfStream => null,
            error.ReadFailed => error.ReadFailed,
        };
        return ahead[k];
    }

    fn comment(self: *MemTokens) error{ReadFailed}!?u8 {
        if (try self.peek(0) != '/') return null;
        const d = try self.peek(1) orelse return null;
        return if (d == '/' or d == '*') d else null;
    }

    fn next(self: *MemTokens, a: Allocator) error{ ReadFailed, OutOfMemory }!?[]const u8 {
        self.token.clearRetainingCapacity();
        while (try self.peek(0)) |c| {
            if (isSpace(c)) {
                self.in.toss(1);
                continue;
            }
            const kind = try self.comment() orelse break;
            self.in.toss(2);
            if (kind == '/') {
                while (try self.peek(0)) |d| : (self.in.toss(1)) if (d == '\n') break;
                continue;
            }
            // `/*` closes at the first `*/` after it: `/*/` does not.
            var star = false;
            while (try self.peek(0)) |d| {
                self.in.toss(1);
                if (star and d == '/') break;
                star = d == '*';
            }
        } else return null;
        const first = (try self.peek(0)).?;
        if (!std.ascii.isPrint(first)) {
            self.in.toss(1);
            try self.token.append(a, first);
            return self.token.items;
        }
        while (try self.peek(0)) |d| {
            if (isSpace(d) or !std.ascii.isPrint(d) or try self.comment() != null) break;
            try self.token.append(a, d);
            self.in.toss(1);
        }
        assert(self.token.items.len >= 1);
        return self.token.items;
    }
};

/// One load's walk over the file's words and `@` addresses (§17.2.9):
/// lowest to highest by default, or start to finish when both are given.
const MemLoad = struct {
    it: MemTokens,
    radix: Program.Radix,
    width: u32,
    low: i64,
    high: i64,
    at: i64,
    last: i64,
    down: bool,
    bounded: bool,
    range_low: i64,
    range_high: i64,
    words: u128 = 0,
    addressed: bool = false,
    exhausted: bool = false,
    outside: ?i64 = null,

    const Word = struct { index: u32, value: Literal };
    const Failure = error{ BadAddress, AddressOutOfRange, BadWord, ReadFailed } || Allocator.Error;

    fn init(in: *std.Io.Reader, radix: Program.Radix, width: u32, low: i64, high: i64, given: u2, start: ?i64, finish: ?i64) MemLoad {
        assert(low <= high);
        const at = if (given >= 1) start orelse low else low;
        const last = if (given == 2) finish orelse high else high;
        return .{
            .it = .{ .in = in },
            .radix = radix,
            .width = width,
            .low = low,
            .high = high,
            .at = at,
            .last = last,
            .down = given == 2 and last < at,
            .bounded = given >= 1,
            .range_low = @min(at, last),
            .range_high = @max(at, last),
        };
    }

    fn next(self: *MemLoad, a: Allocator) Failure!?Word {
        while (try self.it.next(a)) |token| {
            if (token[0] == '@') {
                self.addressed = true;
                self.at = std.fmt.parseInt(i64, std.mem.trimEnd(u8, token[1..], "_"), 16) catch return error.BadAddress;
                if (self.bounded and (self.at < self.range_low or self.at > self.range_high)) return error.AddressOutOfRange;
                if (!self.bounded and self.outside == null and (self.at < self.low or self.at > self.high)) self.outside = self.at;
                self.exhausted = false;
                continue;
            }
            self.words += 1;
            if (self.exhausted) {
                validate(token, self.radix) catch return error.BadWord;
                continue;
            }
            const at = self.at;
            if (self.down) {
                if (self.at <= self.last) self.exhausted = true else self.at -= 1;
            } else {
                if (self.at >= self.last) self.exhausted = true else self.at += 1;
            }
            if (at < self.low or at > self.high) continue;
            const value = word(a, token, self.radix, self.width) catch |e|
                return if (e == error.BadDigit) error.BadWord else error.OutOfMemory;
            return .{ .index = @intCast(at - self.low), .value = value };
        }
        return null;
    }

    /// The file's word count differs from the load range's, with no
    /// address: what W1150 (`mismatch_text`) warns with.
    fn mismatch(self: *const MemLoad) ?struct { found: u128, expected: u128 } {
        const expected: u128 = @intCast(@as(i128, self.range_high) - self.range_low + 1);
        if (self.addressed or self.words == expected) return null;
        return .{ .found = self.words, .expected = expected };
    }

    /// §17.2.9: `BadAddress`, an `@` address that is not hex; `BadWord`, a
    /// word that is not a number in the task's radix; `ReadFailed`, the
    /// file could not be read to its end (`AddressOutOfRange` is reported
    /// through `out_of_range_text` instead; `OutOfMemory` the caller
    /// returns directly).
    fn message(e: Failure) []const u8 {
        return switch (e) {
            error.BadAddress => "the memory file has a malformed `@` address",
            error.AddressOutOfRange => "memory file address is outside the requested load range",
            error.BadWord => "the memory file has a malformed data word",
            error.ReadFailed => "the memory file cannot be read to its end",
            error.OutOfMemory => "out of memory",
        };
    }

    /// The W1150 text; the arguments are `found` then `expected`.
    const mismatch_text = "memory file data word count does not match load range: found {d}, expected {d}";

    /// The W1156 text; the arguments are `outside`, then `low` and `high`.
    const outside_text = "memory file address @{x} is outside the memory's declared range [{d}:{d}]; its words are skipped";

    /// The W1157 text, after `next` failed with `AddressOutOfRange`; the
    /// arguments are the address (`at`), then `range_low` and `range_high`.
    /// §17.2.9: "an error message is issued, and the load operation is
    /// terminated": the load, not the run.
    const out_of_range_text = "§17.2.9: memory file address @{x} is outside the load range [{d}:{d}] the task gives (the words before it stay loaded)";
};

/// The tail of every W1157 message.
const load_ended = "; the $readmem load is terminated, the simulation goes on";

/// §17.2.9 gives an address no x or z digit, so a bound that evaluates to
/// one names no address.
const unknown_bound = "a $readmem start or finish address evaluates to x or z";

/// A file name held in a variable with an x or z bit names no file.
const not_a_name = "the $readmem file name has an x or z bit, so it names no file";

/// A start or finish address outside the memory's declared range: no word
/// is loaded. The arguments are which bound, its value, then the memory's
/// low and high.
const outside_memory = "the $readmem {s} address {d} is outside the memory's range [{d}:{d}]";

/// A memory file that cannot be opened; the argument is its name, as
/// `std.zig.fmtString` escapes a non-printing character in it.
const cannot_read = "the memory file \"{f}\" cannot be read";

const Digit = struct { digit: u32 = 0, fill: ?logic.Bit = null };

/// W1157: the load stops, the run goes on.
fn loadEnded(s: *State, comptime why: []const u8, args: anytype) Error!void {
    try s.warn(.W1157, why ++ load_ended, args);
}

/// The `Program.ReadMem` at `at` in `extra`, run: the file beside the
/// design's source first, else from the working directory.
pub fn readMemory(s: *State, a: Allocator, at: u32) Error!void {
    const p = s.p;
    const rm = p.extraData(Program.ReadMem, at);
    const none = @backingInt(Program.Ref.none);
    const name = if (rm.name_row == none) p.str(rm.name) else (try text(a, try eval.eval(s, a, rm.name_row))) orelse
        return loadEnded(s, not_a_name, .{});
    const io = s.io orelse return loadEnded(s, cannot_read, .{std.zig.fmtString(name)});
    const file = sideFile(io, a, p.str(p.file_name), name) catch return loadEnded(s, cannot_read, .{std.zig.fmtString(name)});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var in = file.reader(io, &buf);
    const low: i64 = rm.low;
    const high: i64 = rm.high;
    const start: ?i64 = if (rm.start == none) null else (try eval.eval(s, a, rm.start)).asInt() orelse return loadEnded(s, unknown_bound, .{});
    const finish: ?i64 = if (rm.finish == none) null else (try eval.eval(s, a, rm.finish)).asInt() orelse return loadEnded(s, unknown_bound, .{});
    for ([_]?i64{ start, finish }, [_][]const u8{ "start", "finish" }) |bound, which| if (bound) |b| if (b < low or b > high)
        return loadEnded(s, outside_memory, .{ which, b, low, high });
    const given: u2 = @as(u2, @intFromBool(start != null)) + @intFromBool(finish != null);
    const width = p.slots.items(.ty)[rm.base].width;
    var load: MemLoad = .init(&in.interface, rm.radix, width, low, high, given, start, finish);
    while (load.next(a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AddressOutOfRange => return loadEnded(s, MemLoad.out_of_range_text, .{ load.at, load.range_low, load.range_high }),
        else => |f| return loadEnded(s, "{s}", .{MemLoad.message(f)}),
    }) |w| {
        assert(w.index <= high - low);
        try s.store(rm.base + w.index, w.value);
    }
    if (load.mismatch()) |m| try s.warn(.W1150, MemLoad.mismatch_text, .{ m.found, m.expected });
    if (load.outside) |o| try s.warn(.W1156, MemLoad.outside_text, .{ o, low, high });
}

/// A value read as a §3.6 string: its bytes, leading zero bytes dropped;
/// null with an x or z bit.
pub fn text(a: Allocator, v: Literal) Error!?[]const u8 {
    if (v.hasUnknown()) return null;
    var out: std.ArrayList(u8) = .empty;
    var n = (v.width + 7) / 8;
    while (n != 0) {
        n -= 1;
        const c: u8 = @truncate(v.values()[n / 8] >> @intCast(n % 8 * 8));
        if (c == 0 and out.items.len == 0) continue;
        try out.append(a, c);
    }
    return out.items;
}

/// The memory file beside the design's source, else from the working
/// directory.
pub fn sideFile(io: std.Io, a: Allocator, file_name: []const u8, name: []const u8) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    if (std.Io.Dir.path.dirname(file_name)) |dir| {
        const joined = try std.Io.Dir.path.join(a, &.{ dir, name });
        if (cwd.openFile(io, joined, .{})) |file| return file else |_| {}
    }
    return cwd.openFile(io, name, .{});
}

// ---- private ----

fn word(a: Allocator, token: []const u8, radix: Program.Radix, width: u32) !Literal {
    try validate(token, radix);
    const per: u32 = if (radix == .binary) 1 else 4;
    const value = try logic.filled(a, width, false, .zero);
    var bit: u32 = 0;
    var i = token.len;
    while (i != 0 and bit < width) {
        i -= 1;
        const c = std.ascii.toLower(token[i]);
        if (c == '_') continue;
        const decoded = try digitOf(c, radix);
        var k: u32 = 0;
        while (k < per and bit < width) : ({
            k += 1;
            bit += 1;
        }) logic.setBit(value, bit, decoded.fill orelse @fromBackingInt(@intCast(@as(u2, @intCast((decoded.digit >> @intCast(k)) & 1)))));
    }
    return value;
}

fn digitOf(character: u8, radix: Program.Radix) !Digit {
    const c = std.ascii.toLower(character);
    switch (c) {
        'x' => return .{ .fill = .x },
        'z', '?' => return .{ .fill = .z },
        else => {},
    }
    const digit: u32 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => return error.BadDigit,
    };
    if (digit >= @backingInt(radix)) return error.BadDigit;
    return .{ .digit = digit };
}

fn validate(token: []const u8, radix: Program.Radix) !void {
    if (token.len == 0 or token[0] == '_') return error.BadDigit;
    for (token) |c| {
        if (c == '_') continue;
        _ = try digitOf(c, radix);
    }
}

test "a memory word: separators skipped, high digits truncated, a bad digit refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?i64, 17), (try word(a, "aB_11", .hex, 8)).asInt());
    try std.testing.expectEqual(@as(?i64, 17), (try word(a, "10_00010001", .binary, 8)).asInt());
    for ([_][]const u8{ "8'h11", "g11", "_1" }) |t| try std.testing.expectError(error.BadDigit, word(a, t, .hex, 8));
    try std.testing.expect((try word(a, "x", .hex, 4)).hasUnknown());
}
