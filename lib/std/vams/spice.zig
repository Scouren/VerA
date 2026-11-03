//! LRM annex E.2 with no I/O: a SPICE netlist's bytes in, Verilog-AMS
//! module text out for its `.MODEL` and `.SUBCKT` cards, so a source can
//! instantiate them, with the refusals, the `.MODEL`s of unsupported types
//! and the `.HDL` names. The reader never opens a file: when an `.INCLUDE`
//! or `.LIB` card names one it stops and returns a request with one path,
//! and the caller answers with the read's own result: bytes, or the error.
//!
//! ```zig
//! var n: spice.Netlist = .init(gpa, "top.sp", netlist);
//! defer n.deinit();
//! while (try n.run()) |req| switch (req) {
//!     .file => |want| try n.answer(read(want.path)),
//! };
//! const out = n.output();
//! try out.report(&wip, first_file); // E0928 / E0953, one per refusal
//! if (out.modules != 0) try pp.addUnit("spice_netlist.vams", out.text);
//! for (out.hdl) |path| try addSource(path);
//! ```
//!
//! E.1.2: "with which particular variant of SPICE it is compatible, is
//! solely determined by the authors of the simulator". VerA claims SPICE3
//! card syntax for `.MODEL` (card.zig's `model_types`), for `.SUBCKT` bodies
//! of R/C/L/V/I/E/F/G/H cards, of M/Q/J/D cards whose model is a Verilog-A
//! module or paramset (binned models included) and of X cards, and for
//! `.INCLUDE`, `.LIB` and HSPICE's `.HDL` anywhere (spice/Reader.zig); and
//! HSPICE's `PARAMS:` with `{expr}`/`'expr'` values over them (spice/expr.zig).
//! Inside a `.SUBCKT`, anything else is refused (E0928), and a card whose
//! model is a Table E.1 semiconductor with no behaviour is E0953: skipping
//! either would change the circuit. Cards outside a definition (`.tran`,
//! top-level devices) are not module definitions and contribute nothing.
//! Input is lower-cased at ingest (E.2.1), file names excepted.
//!
//! Cites: LRM annex E.1.2, E.2, E.2.1, E.2.2, E.3, E.4, Table E.1.
//!
//! Contents:
//! - `pub const Netlist = struct`: `init`, `deinit`, `run`, `answer`, `output`
//! - `pub const Request = union(enum)`
//! - `pub const Output = struct`: `report`
//! - `pub const File = struct`
//! - `pub const Refusal = struct`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Diag = @import("Diag.zig");
const Reader = @import("spice/Reader.zig");
const card = @import("spice/card.zig");
const emit = @import("spice/emit.zig");
const Card = card.Card;
const ModelCard = card.ModelCard;
const Tokens = card.Tokens;

/// One netlist's read: the netlist borrowed, the answers and every output on
/// `gpa`. `run` until it returns null, answering each request; then
/// `output`.
pub const Netlist = struct {
    gpa: Allocator,
    /// The file the netlist was read from, or "": `.INCLUDE`/`.LIB`/`.HDL`
    /// names then resolve against the working directory.
    path: []const u8,
    text: []const u8,
    /// The caller's answers by path, keys on `gpa`, bytes borrowed. The same
    /// path is never asked twice.
    answers: Reader.Answers = .empty,
    /// The path the last `run` asked for, on `gpa`, until `answer`.
    want: ?[]const u8 = null,
    /// Owns the output.
    arena: std.heap.ArenaAllocator,
    /// Owns the read's working state; reset once the output is built.
    scratch: std.heap.ArenaAllocator,
    reader: Reader,
    state: enum(u8) { fresh, reading, done } = .fresh,
    result: Output = .{},

    /// Returns a reader of `text`, read from `path` ("" for none). Both are
    /// borrowed until `deinit`. Allocates nothing.
    pub fn init(gpa: Allocator, path: []const u8, text: []const u8) Netlist {
        assert(text.len <= std.math.maxInt(u32));
        return .{
            .gpa = gpa,
            .path = path,
            .text = text,
            .arena = .init(gpa),
            .scratch = .init(gpa),
            .reader = .{ .arena = undefined, .scratch = undefined, .refusals = .{ .arena = undefined } },
        };
    }

    /// Frees everything; every slice `run` and `output` returned dies with it.
    pub fn deinit(n: *Netlist) void {
        var it = n.answers.keyIterator();
        while (it.next()) |k| n.gpa.free(k.*);
        n.answers.deinit(n.gpa);
        if (n.want) |w| n.gpa.free(w);
        n.scratch.deinit();
        n.arena.deinit();
        n.* = undefined;
    }

    /// Reads on until the output is done (null) or a file is needed (a
    /// request, answered with `answer` before the next call). A read
    /// resumes where the request stopped it. Refusals are in `output`, not
    /// an error. Asserts no unanswered request.
    pub fn run(n: *Netlist) Allocator.Error!?Request {
        assert(n.want == null);
        if (n.state == .done) return null;
        if (n.text.len == 0) {
            // Nothing to read: no file, no module (E.2 asks for none).
            n.state = .done;
            return null;
        }
        // The arenas live in `n`, which may have moved since the last call.
        n.reader.arena = n.arena.allocator();
        n.reader.scratch = n.scratch.allocator();
        n.reader.refusals.arena = n.reader.arena;
        if (n.state == .fresh) {
            try n.reader.start(if (n.path.len == 0) "<spice netlist>" else n.path, n.text);
            n.state = .reading;
        }
        if (try n.reader.step(&n.answers)) |path| {
            assert(!n.answers.contains(path));
            n.want = try n.gpa.dupe(u8, path);
            return .{ .file = .{ .path = n.want.? } };
        }
        n.result = try synthesize(n.arena.allocator(), n.scratch.allocator(), &n.reader);
        n.state = .done;
        _ = n.scratch.reset(.free_all);
        return null;
    }

    /// Answers the last request with the read's own result: the file's
    /// bytes, or the error that stopped it, which the refusal at the card
    /// names (`cannot read "x" (IsDir)`). Bytes are borrowed until `deinit`.
    /// Asserts a pending request and at most `maxInt(u32)` bytes, the
    /// offsets a refusal can address.
    pub fn answer(n: *Netlist, read: anyerror![]const u8) Allocator.Error!void {
        const path = n.want.?;
        const a: Reader.Answer = if (read) |b| .{ .bytes = b } else |e| .{ .failed = @errorName(e) };
        if (a == .bytes) assert(a.bytes.len <= std.math.maxInt(u32));
        try n.answers.putNoClobber(n.gpa, path, a);
        n.want = null;
        assert(n.answers.contains(path));
    }

    /// Returns the finished read's output; empty before `run` returned null.
    pub fn output(n: *const Netlist) Output {
        if (n.state != .done) assert(n.result.files.len == 0);
        return n.result;
    }
};

/// What a read needs before it can go on.
pub const Request = union(enum) {
    /// The bytes of `path`, resolved beside the file whose card names it;
    /// valid until `answer`.
    file: struct { path: []const u8 },
};

/// What a finished read publishes. Every slice lives until `deinit`.
pub const Output = struct {
    /// Verilog-AMS module text for every `.MODEL` and `.SUBCKT` read; empty
    /// when `modules` is 0.
    text: []const u8 = "",
    /// The modules `text` declares (`Ast.SourceFile.netlist_modules`).
    modules: u32 = 0,
    /// Cards inside a definition this reader does not claim, in the order
    /// met; the caller reports each (`report`) and stops.
    refusals: []const Refusal = &.{},
    /// `.MODEL` cards whose type is a primitive VerA does not support
    /// (E.1.2 bullet 2), as `name type`, lower-cased: an instance naming one
    /// is refused with E0952 rather than as an unknown module.
    unsupported: []const []const u8 = &.{},
    /// The files a `Refusal` points into: the netlist first, then each file
    /// an `.INCLUDE` or `.LIB` card opened, a row per opening.
    files: []const File = &.{},
    /// HSPICE `.HDL "file"`: Verilog-A sources the netlist names, resolved
    /// beside the naming file, each once, in card order. They belong to the
    /// design like files given together on a command line.
    hdl: []const []const u8 = &.{},

    /// Reports every refusal into `wip` as its code (E0928, E0953) at the
    /// card, stage `preprocess`; `files[i]` is the caller's file
    /// `first + i`. Fails only for memory.
    pub fn report(out: Output, wip: *Diag.Wip, first: Diag.File) Allocator.Error!void {
        assert(first != .none);
        for (out.refusals) |r| {
            assert(r.file < out.files.len);
            const file: Diag.File = @fromBackingInt(@backingInt(first) + r.file);
            try wip.add(.preprocess, r.code, .{ .file = file, .start = r.at, .end = r.at + r.len }, "{s}", .{r.message});
        }
    }
};

/// One netlist file: the name it was opened by, and its text.
pub const File = struct { name: []const u8, text: []const u8 };

/// One card the reader refuses: `files[file].text[at..][0..len]`, the
/// card's first physical line.
pub const Refusal = struct {
    /// E0928 unless the card is readable and its model is not (E0953).
    code: Diag.Code,
    file: u32,
    at: u32,
    len: u32,
    message: []const u8,
};

/// The text every synthesized netlist starts with. It names the old
/// reader because diff-spice holds the text byte-equal to it; it is
/// reworded when the old one is deleted.
const preamble =
    \\// Annex E.2 — synthesized from the `//! spice` cards of this compilation;
    \\// see `spice_cards.synthesize` for what of a netlist is read and what is not.
    \\
    \\
;

// ---- private ----

/// The read's lines in, the output out on `arena`: `+` continuations joined
/// into cards, every `.MODEL` collected (a body card may name a model
/// declared after it, or in another file), then each card emitted in order.
fn synthesize(arena: Allocator, scratch: Allocator, r: *const Reader) Allocator.Error!Output {
    assert(r.frames.items.len == 0);
    const cards = try joinCards(scratch, r.lines.items);
    var refusals = r.refusals;

    var models: std.ArrayList(ModelCard) = .empty;
    for (cards) |c| {
        var it: Tokens = .{ .text = c.text };
        if (!std.mem.eql(u8, it.next() orelse continue, ".model")) continue;
        const name = it.next() orelse continue;
        const type_ = it.next() orelse continue;
        for (models.items) |m| {
            if (std.mem.eql(u8, m.name, name)) break;
        } else try models.append(scratch, .{ .name = name, .type_ = type_, .card = c });
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(scratch, preamble);
    var count: u32 = 0;
    // ponytail: `seen` and `models` are linear scans, O(cards * models); a
    // hash map keyed by name if a netlist ever holds thousands of models.
    var seen: std.ArrayList([]const u8) = .empty;
    var unsupported: std.ArrayList([]const u8) = .empty;
    // Index-based: a `.SUBCKT` header owns the cards up to its `.ENDS`,
    // consumed with it whether or not anything is emitted, so a repeated
    // `.SUBCKT`'s cards are not read a second time at top level.
    var i: usize = 0;
    while (i < cards.len) {
        const body = card.subcktBody(cards[i..]);
        if (try emit.emitCard(scratch, &out, cards[i], body, models.items, &seen, &refusals, &unsupported)) count += 1;
        i += 1 + body.len;
    }
    // A body is a slice of the cards after its header, so no step overshoots.
    assert(i == cards.len);

    const kept = try arena.alloc([]const u8, unsupported.items.len);
    for (unsupported.items, kept) |u, *k| k.* = try arena.dupe(u8, u);
    var done: Output = .{ .refusals = refusals.list.items, .unsupported = kept, .files = r.files.items, .hdl = r.hdl.items };
    if (count == 0) return done;
    done.text = try arena.dupe(u8, out.items);
    done.modules = count;
    assert(done.text.len > preamble.len);
    return done;
}

/// The physical lines joined into logical cards on `scratch`: a `+` line
/// continues the card above (one with nothing above is dropped), and each
/// card's `=` is tightened. A card keeps its first line's place.
fn joinCards(scratch: Allocator, lines: []const Card) Allocator.Error![]const Card {
    var cards: std.ArrayList(Card) = .empty;
    var logical: std.ArrayList(u8) = .empty;
    var first: Card = undefined;
    for (lines) |line| {
        assert(line.text.len != 0); // the reader keeps no blank line
        if (line.text[0] == '+') {
            if (logical.items.len != 0) {
                try logical.append(scratch, ' ');
                try logical.appendSlice(scratch, std.mem.trim(u8, line.text[1..], " \t"));
            }
            continue;
        }
        if (logical.items.len != 0) {
            first.text = try card.tightEquals(scratch, logical.items);
            try cards.append(scratch, first);
        }
        logical.clearRetainingCapacity();
        try logical.appendSlice(scratch, line.text);
        first = line;
    }
    if (logical.items.len != 0) {
        first.text = try card.tightEquals(scratch, logical.items);
        try cards.append(scratch, first);
    }
    assert(cards.items.len <= lines.len);
    return cards.items;
}

test {
    _ = @import("spice/tests.zig");
    _ = card;
    _ = emit;
    _ = @import("spice/expr.zig");
    _ = @import("spice/model.zig");
    _ = Reader;
}
