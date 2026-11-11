//! IEEE 1364-2005 §13.2 library map files with no I/O: map bytes in, a
//! `Reader`-driven `Output` out, every statement's refusal reported through
//! `Output.report`. No file is opened here: a `.file` `Request` names a
//! path, the caller answers with `Compilation.read` and
//! `Compilation.realPath`'s own results, and `include` nests through an
//! explicit stack (`frames`), never recursion, so a chain of map files is
//! bounded by memory, not the caller's stack.
//!
//! ```zig
//! var r: libmap.Reader = .init(comp.arena(), comp.config.libmaps);
//! while (try r.run()) |req| switch (req) {
//!     .file => |want| try r.answer(switch (try comp.read(want.path)) {
//!         .failed => |e| .{ .unreadable = e },
//!         .bytes => |b| switch (try comp.realPath(want.path)) {
//!             .failed => |e| .{ .unresolvable = e },
//!             .path => |real| .{ .file = .{ .bytes = b, .real = real } },
//!         },
//!     }),
//! };
//! const map = r.output();
//! if (map.refusal != null) return false; // errors.bundle reports it
//! ```
//!
//! Cites: §13.2.1, §13.2.1.1, §13.2.2, §13.2.3, §13.5.1, §13.7.1, A.1.1.
//!
//! Contents:
//! - `pub const Class`, `pub const Spec`, `pub const Library`, `pub const File`
//! - `pub const Refusal`, `pub const Placement`
//! - `pub const Request`, `pub const Answer`
//! - `pub const Output`: `libraryOf`, `order`, `declares`, `report`
//! - `pub const Reader`: `init`, `run`, `answer`, `output`
//! - `pub fn matches(pattern: []const u8, file: []const u8) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Diag = vams.Diag;
const testing = std.testing;

/// §13.2.1.1's resolution order, most specific first: a specification that
/// ends with an explicit filename, a wildcarded filename, or a directory.
/// `u8`-backed (not the tightest `u2`): this table is never dense enough to
/// pay for the packing, and the width must hold an array index
/// (`data-oriented-design`: narrowest width the stated range allows, no
/// narrower than its storage).
pub const Class = enum(u8) { file, wildcard, directory };

/// One `file_path_spec`, resolved against its map file's directory.
pub const Spec = struct {
    /// Absolute, `.` and `..` resolved; `?`, `*` and `...` still wildcards.
    /// A directory specification ends in `/*` (§13.2.1: "Identical to /*").
    pattern: []const u8,
    class: Class,
};

/// One §13.2.1 `library` declaration: its name and every file path
/// specification it lists, in order. A name declared twice is one
/// `Library` holding both declarations' specifications.
pub const Library = struct { name: []const u8, specs: []const Spec };

/// One map file the reader opened: the path it was asked for, and its text.
pub const File = struct { name: []const u8, text: []const u8 };

/// The one refusal a read may end in: an unreadable or unresolvable map
/// file, an `include` cycle, a Syntax 13-2 violation, or a file_path_spec
/// past the path-length cap. `file` is null only for a top-level map that
/// cannot be read (no file to point into).
pub const Refusal = struct { file: ?u32, start: u32, end: u32, message: []const u8 };

/// Where §13.2.1.1 places a source file.
pub const Placement = union(enum) {
    lib: []const u8,
    /// Two libraries whose best matching specifications tie: an error.
    ambiguous: [2][]const u8,
};

/// What a read needs before it can go on.
pub const Request = union(enum) {
    /// The bytes of `path`, resolved against the including file's
    /// directory (or the working directory, at the top level); valid
    /// until `answer`.
    file: struct { path: []const u8 },
};

/// The caller's answer to the last `Request`, from its own `read` and
/// `realPath`.
pub const Answer = union(enum) {
    file: struct { bytes: []const u8, real: []const u8 },
    unreadable: anyerror,
    unresolvable: anyerror,
};

/// Every library map file read, merged; built by `Reader.run`. Every slice
/// lives until the `Reader` does (its arena).
pub const Output = struct {
    /// In declaration order, map files in the order given.
    libraries: []const Library = &.{},
    /// A.1.1's `-incdir` lists, every library's, in declaration order, each
    /// resolved against its map file's directory.
    incdirs: []const []const u8 = &.{},
    /// The files a `Refusal` points into, in the order opened.
    files: []const File = &.{},
    refusal: ?Refusal = null,

    /// §13.2.1.1 the library `file` (absolute) maps into: the one whose
    /// specification matches it most specifically, else `work` (§13.2.1).
    /// A tie names the first two libraries, in declaration order, whose
    /// best specifications share the most specific class.
    /// O(libraries * specs).
    pub fn libraryOf(out: Output, file: []const u8) Placement {
        var best: ?Class = null;
        var lib: []const u8 = "work";
        var tie: ?[]const u8 = null;
        for (out.libraries) |l| {
            var got: ?Class = null;
            for (l.specs) |s| if (matches(s.pattern, file)) {
                if (got == null or @backingInt(s.class) < @backingInt(got.?)) got = s.class;
            };
            const c = got orelse continue;
            if (best == null or @backingInt(c) < @backingInt(best.?)) {
                best = c;
                lib = l.name;
                tie = null;
            } else if (c == best.? and tie == null) tie = l.name;
        }
        // A tie is only ever recorded against a best match.
        assert(best != null or tie == null);
        if (tie) |t| return .{ .ambiguous = .{ lib, t } };
        return .{ .lib = lib };
    }

    /// §13.5.1 the search order with no configuration: "the library
    /// declaration order in the library map file", then `work` when no map
    /// declares it. The slice is allocated in `arena`.
    pub fn order(out: Output, arena: Allocator) Allocator.Error![]const []const u8 {
        const work = out.declares("work") == null;
        const result = try arena.alloc([]const u8, out.libraries.len + @intFromBool(work));
        for (out.libraries, result[0..out.libraries.len]) |l, *o| o.* = l.name;
        if (work) result[out.libraries.len] = "work";
        assert(result.len >= out.libraries.len);
        return result;
    }

    /// The index of the library called `name` in `libraries`, or null.
    /// `name` may be anything (`-L ''` reaches here from argv); an empty
    /// one names no library, since every declared name is an identifier.
    pub fn declares(out: Output, name: []const u8) ?usize {
        for (out.libraries, 0..) |l, i| if (std.mem.eql(u8, l.name, name)) {
            assert(i < out.libraries.len);
            assert(name.len > 0);
            return i;
        };
        return null;
    }

    /// Reports the one refusal, if any, into `wip` as E0244 at its file
    /// (`files[i]` is the caller's file `first + i`), stage `parse`. Fails
    /// only for memory.
    pub fn report(out: Output, wip: *Diag.Wip, first: Diag.File) Allocator.Error!void {
        const r = out.refusal orelse return;
        const loc: Diag.Loc = if (r.file) |f| blk: {
            assert(f < out.files.len);
            break :blk .{ .file = @fromBackingInt(@backingInt(first) + f), .start = r.start, .end = r.end };
        } else .none;
        try wip.add(.parse, .E0244, loc, "{s}", .{r.message});
    }
};

/// Reads the map files `pending` names, in order (§13.2.1: "If multiple map
/// files are specified, then they shall be read in the order in which they
/// are specified"), answering each `.file` request `run` raises. `run`
/// until it returns null, then `output`.
pub const Reader = struct {
    arena: Allocator,
    /// `config.libmaps` not started yet.
    pending: []const []const u8,
    /// The `include` stack, outermost first: an explicit stack in place of
    /// recursion (`compiler-construction` rule 7), so nesting is bounded by
    /// memory, not the native stack.
    frames: std.ArrayList(Frame) = .empty,
    /// Real paths of `frames`, parallel to it, for the cycle check.
    open: std.ArrayList([]const u8) = .empty,
    /// The path of the request `run` last returned, until `answer`.
    want: ?[]const u8 = null,
    /// The `include` (or `library`) statement that named `want`; null at
    /// the top level.
    want_at: ?Site = null,
    libs: std.ArrayList(LibBuf) = .empty,
    incdirs: std.ArrayList([]const u8) = .empty,
    files: std.ArrayList(File) = .empty,
    refusal: ?Refusal = null,
    /// `output()` is valid once this is true.
    done: bool = false,
    finished: Output = .{},

    /// A reader of `maps`, nothing read yet; `maps` is borrowed.
    pub fn init(arena: Allocator, maps: []const []const u8) Reader {
        return .{ .arena = arena, .pending = maps };
    }

    /// Reads on until the output is done (null) or a file is needed (a
    /// `Request`, answered with `answer` before the next call). Asserts no
    /// unanswered request.
    pub fn run(r: *Reader) Allocator.Error!?Request {
        assert(r.want == null);
        if (r.done) return null;
        while (true) {
            if (r.refusal != null) {
                try r.finish();
                r.done = true;
                return null;
            }
            if (r.frames.items.len == 0) {
                if (r.pending.len == 0) {
                    try r.finish();
                    r.done = true;
                    return null;
                }
                r.want = r.pending[0];
                r.want_at = null;
                r.pending = r.pending[1..];
                return .{ .file = .{ .path = r.want.? } };
            }
            if (try r.step()) |req| return req;
        }
    }

    /// Answers the last request with the read's own result. A `.file`
    /// whose real path is already open is the `include` cycle refusal
    /// (chain `a -> b -> a`); otherwise it is registered and pushed as the
    /// new top frame. Asserts a pending request; after, none.
    pub fn answer(r: *Reader, a: Answer) Allocator.Error!void {
        assert(r.want != null);
        const path = r.want.?;
        const at = r.want_at;
        r.want = null;
        r.want_at = null;
        switch (a) {
            .unreadable => |e| try r.fail(at, "cannot read library map `{s}`: {t}", .{ path, e }),
            .unresolvable => |e| try r.fail(at, "cannot resolve library map `{s}`: {t}", .{ path, e }),
            .file => |f| {
                for (r.open.items, 0..) |o, k| {
                    if (!std.mem.eql(u8, o, f.real)) continue;
                    var chain: std.ArrayList(u8) = .empty;
                    for (r.open.items[k..]) |c| try chain.print(r.arena, "{s} -> ", .{c});
                    try chain.appendSlice(r.arena, f.real);
                    return r.fail(at, "library map `include` cycle: {s}", .{chain.items});
                }
                if (r.files.items.len == vams.Preprocessor.files_max)
                    return r.fail(at, "cannot register library map `{s}`: past {d} source files", .{ path, vams.Preprocessor.files_max });
                const idx: u32 = @intCast(r.files.items.len);
                try r.files.append(r.arena, .{ .name = path, .text = f.bytes });
                try r.open.append(r.arena, f.real);
                const dir = try slashed(r.arena, std.fs.path.dirname(f.real) orelse "/");
                try r.frames.append(r.arena, .{ .file = idx, .pos = 0, .dir = dir });
                assert(r.frames.items.len <= vams.Preprocessor.files_max);
            },
        }
    }

    /// The finished read: empty, with no refusal, before `run` returns
    /// null the first time.
    pub fn output(r: *const Reader) Output {
        assert(r.done);
        return r.finished;
    }

    // ---- private ----

    /// Steps the top frame's tokens until it needs a file (returns a
    /// `Request`), ends (pops the frame and returns null), or is refused
    /// (`r.refusal` set, returns null). `include` is the only statement
    /// that suspends; `library` is handled inline, exactly as §13.2.1
    /// Syntax 13-2 describes it.
    fn step(r: *Reader) Allocator.Error!?Request {
        const top = &r.frames.items[r.frames.items.len - 1];
        var t: Tokens = .{ .text = r.files.items[top.file].text, .pos = top.pos };
        while (true) {
            const kw = t.next() orelse {
                top.pos = @intCast(t.pos);
                _ = r.frames.pop();
                _ = r.open.pop();
                return null;
            };
            const here: Site = .{ .file = top.file, .tok = kw };
            if (std.mem.eql(u8, kw.text, "include")) {
                const spec = t.next() orelse return r.failStep(here, "`include` names no file_path_spec", .{});
                if (isPunct(spec.text)) return r.failStep(.{ .file = top.file, .tok = spec }, "`include` names no file_path_spec", .{});
                const semi = t.next() orelse return r.failStep(.{ .file = top.file, .tok = spec }, "an `include` statement ends with `;`", .{});
                if (!std.mem.eql(u8, semi.text, ";")) return r.failStep(.{ .file = top.file, .tok = semi }, "found `{s}`: an `include` statement ends with `;`", .{semi.text});
                const text = unquote(spec.text);
                if (text.len == 0) return r.failStep(.{ .file = top.file, .tok = spec }, "`{s}` is an empty file_path_spec (Syntax 13-2)", .{spec.text});
                const resolved = (try resolvePathAlloc(r.arena, top.dir, text)) orelse
                    return r.failStep(.{ .file = top.file, .tok = spec }, "`{s}…` is longer than a path", .{preview(text)});
                top.pos = @intCast(t.pos);
                r.want = resolved;
                r.want_at = .{ .file = top.file, .tok = spec };
                return .{ .file = .{ .path = resolved } };
            } else if (std.mem.eql(u8, kw.text, "library")) {
                const name_tok = t.next() orelse return r.failStep(here, "`library` names no library", .{});
                if (!isIdentifier(name_tok.text)) return r.failStep(.{ .file = top.file, .tok = name_tok }, "`{s}` is not a library_identifier", .{name_tok.text});
                const lib = try r.libraryFor(name_tok.text);
                var prev = name_tok;
                while (true) {
                    const spec = t.next() orelse return r.failStep(.{ .file = top.file, .tok = prev }, "a library declaration ends with `;`", .{});
                    if (isPunct(spec.text) or std.mem.eql(u8, spec.text, "-incdir"))
                        return r.failStep(.{ .file = top.file, .tok = spec }, "`library {s}` needs a file_path_spec here (Syntax 13-2), found `{s}`", .{ name_tok.text, spec.text });
                    const text = unquote(spec.text);
                    if (text.len == 0) return r.failStep(.{ .file = top.file, .tok = spec }, "`{s}` is an empty file_path_spec (Syntax 13-2)", .{spec.text});
                    const resolved = (try resolveSpec(r.arena, top.dir, text)) orelse
                        return r.failStep(.{ .file = top.file, .tok = spec }, "`{s}…` is longer than a path", .{preview(text)});
                    try lib.specs.append(r.arena, resolved);
                    const sep = t.next() orelse return r.failStep(.{ .file = top.file, .tok = spec }, "a library declaration ends with `;`", .{});
                    if (std.mem.eql(u8, sep.text, ";")) break;
                    if (std.mem.eql(u8, sep.text, "-incdir")) {
                        var prev_tok = sep;
                        while (true) {
                            const d = t.next() orelse return r.failStep(.{ .file = top.file, .tok = prev_tok }, "a library declaration ends with `;`", .{});
                            if (isPunct(d.text)) return r.failStep(.{ .file = top.file, .tok = d }, "`-incdir` needs a file_path_spec here (Syntax 13-2), found `{s}`", .{d.text});
                            const dtext = unquote(d.text);
                            if (dtext.len == 0) return r.failStep(.{ .file = top.file, .tok = d }, "`{s}` is an empty file_path_spec (Syntax 13-2)", .{d.text});
                            const dresolved = (try resolvePathAlloc(r.arena, top.dir, dtext)) orelse
                                return r.failStep(.{ .file = top.file, .tok = d }, "`{s}…` is longer than a path", .{preview(dtext)});
                            try r.incdirs.append(r.arena, dresolved);
                            const nxt = t.next() orelse return r.failStep(.{ .file = top.file, .tok = d }, "a library declaration ends with `;`", .{});
                            if (std.mem.eql(u8, nxt.text, ";")) break;
                            if (!std.mem.eql(u8, nxt.text, ","))
                                return r.failStep(.{ .file = top.file, .tok = nxt }, "found `{s}`: -incdir file_path_specs are separated by `,` and end with `;`", .{nxt.text});
                            prev_tok = nxt;
                        }
                        break;
                    }
                    if (!std.mem.eql(u8, sep.text, ","))
                        return r.failStep(.{ .file = top.file, .tok = sep }, "found `{s}`: file_path_specs are separated by `,` and end with `;`", .{sep.text});
                    prev = sep;
                }
            } else {
                return r.failStep(here, "found `{s}`: a library map holds `library` and `include` statements only (IEEE 1364-2005 §13.2.2)", .{kw.text});
            }
        }
    }

    /// The library named `name`, appending a fresh one when none matches
    /// yet (a name declared twice holds both declarations' specs).
    fn libraryFor(r: *Reader, name: []const u8) Allocator.Error!*LibBuf {
        for (r.libs.items) |*b| if (std.mem.eql(u8, b.name, name)) return b;
        try r.libs.append(r.arena, .{ .name = name });
        return &r.libs.items[r.libs.items.len - 1];
    }

    /// Records the one refusal at `at` (null: no file to point into).
    /// Asserts at most one.
    fn fail(r: *Reader, at: ?Site, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        assert(r.refusal == null);
        const message = try std.fmt.allocPrint(r.arena, fmt, args);
        r.refusal = .{
            .file = if (at) |s| s.file else null,
            .start = if (at) |s| s.tok.start else 0,
            .end = if (at) |s| s.tok.start + @as(u32, @intCast(s.tok.text.len)) else 0,
            .message = message,
        };
    }

    /// `fail`, then the null `step`/`run` returns on a refusal.
    fn failStep(r: *Reader, at: Site, comptime fmt: []const u8, args: anytype) Allocator.Error!?Request {
        try r.fail(at, fmt, args);
        return null;
    }

    /// Materializes `libs` into `Output.libraries` (the one allocation
    /// `run` cannot avoid: a library declared twice must finish growing
    /// before its `specs` slice exists). Called once, as `run` finishes.
    fn finish(r: *Reader) Allocator.Error!void {
        const libs = try r.arena.alloc(Library, r.libs.items.len);
        for (r.libs.items, libs) |b, *o| o.* = .{ .name = b.name, .specs = b.specs.items };
        r.finished = .{ .libraries = libs, .incdirs = r.incdirs.items, .files = r.files.items, .refusal = r.refusal };
    }
};

/// One library being built: its name and the specs read for it so far.
const LibBuf = struct { name: []const u8, specs: std.ArrayList(Spec) = .empty };

/// One `include` nesting level: the file its text came from, how far its
/// tokens were read, and the directory relative specs resolve against.
const Frame = struct { file: u32, pos: u32, dir: []const u8 };

/// A refusal's location: the file it is in, and the token (null file: no
/// file to point into, a top-level map that could not be read).
const Site = struct { file: u32, tok: Token };

const Token = struct { text: []const u8, start: u32 };

/// How much of an overlong file_path_spec a refusal shows.
const path_preview: usize = 60;

/// Words of map text: a quoted string, `,`, `;`, or a run of anything else
/// up to whitespace, `,` or `;`. A comment starts only where a word could,
/// so the `/*` inside `lib/*.v` is part of the path.
const Tokens = struct {
    text: []const u8,
    pos: usize = 0,

    /// The next token, never empty, or null at the end. Asserts that the
    /// cursor is within the text and that a token advanced it.
    fn next(t: *Tokens) ?Token {
        const s = t.text;
        assert(t.pos <= s.len);
        while (t.pos < s.len) {
            if (std.ascii.isWhitespace(s[t.pos])) {
                t.pos += 1;
            } else if (std.mem.startsWith(u8, s[t.pos..], "//")) {
                t.pos = std.mem.findScalarPos(u8, s, t.pos, '\n') orelse s.len;
            } else if (std.mem.startsWith(u8, s[t.pos..], "/*")) {
                t.pos = if (std.mem.findPos(u8, s, t.pos + 2, "*/")) |e| e + 2 else s.len;
            } else break;
        }
        if (t.pos == s.len) return null;
        const start = t.pos;
        if (s[t.pos] == '"') {
            t.pos = if (std.mem.findScalarPos(u8, s, t.pos + 1, '"')) |e| e + 1 else s.len;
        } else if (isPunct(s[t.pos .. t.pos + 1])) {
            t.pos += 1;
        } else while (t.pos < s.len and !std.ascii.isWhitespace(s[t.pos]) and s[t.pos] != ',' and s[t.pos] != ';') t.pos += 1;
        // A word starts on a byte that is neither blank nor punctuation, so
        // each arm takes one byte at least.
        assert(t.pos > start);
        assert(t.pos <= s.len);
        return .{ .text = s[start..t.pos], .start = @intCast(start) };
    }
};

/// One row of a `runTable` fixture: a map path answered with `real`/`bytes`
/// (`bytes` null: unreadable).
const TableEntry = struct { path: []const u8, real: []const u8, bytes: ?[]const u8 };

/// §13.2.1: a library declaration, then an include. A test fixture for
/// `runTable`.
const test_map =
    \\// §13.2.1: a library declaration, then an include.
    \\library rtl rtl/*.v, "q/x.v" -incdir inc, "inc 2";
    \\include sub/more.map;
    \\
;

/// Reports whether `file` matches `pattern`, both absolute. §13.2.1's
/// wildcards: `?` one character, `*` any run within one name, `...` any
/// number of directories. `pattern` is `/`-separated (`resolveSpec`);
/// `file` is a host path, split on the host's separators. Each name is
/// matched in time linear in the product of its pattern and name lengths.
pub fn matches(pattern: []const u8, file: []const u8) bool {
    var f = file;
    while (f.len != 0 and std.fs.path.isSep(f[0])) f = f[1..];
    return segments(std.mem.trimStart(u8, pattern, "/"), f);
}

// ---- private ----

/// How much of an overlong file_path_spec a refusal shows, as `preview`'s
/// result: the first `path_preview` bytes.
fn preview(text: []const u8) []const u8 {
    return text[0..@min(text.len, path_preview)];
}

fn isPunct(w: []const u8) bool {
    return std.mem.eql(u8, w, ",") or std.mem.eql(u8, w, ";");
}

/// §2.8: a library_identifier (`vams.tokenizer.isIdentChar`'s class),
/// starting with a letter or `_`.
fn isIdentifier(w: []const u8) bool {
    if (w.len == 0 or !(std.ascii.isAlphabetic(w[0]) or w[0] == '_')) return false;
    for (w) |c| if (!vams.tokenizer.isIdentChar(c)) return false;
    return true;
}

fn unquote(w: []const u8) []const u8 {
    const out = if (w.len >= 2 and w[0] == '"' and w[w.len - 1] == '"') w[1 .. w.len - 1] else w;
    assert(out.len <= w.len);
    return out;
}

/// `dir` and `raw` joined and resolved (`.`/`..` collapsed); null when the
/// result is past the path-length cap (lib/TODO.md §11.2: a fixed cap with
/// its own error, so `segments`' later per-`/` recursion is bounded on
/// input the user controls, not just on `include` nesting).
fn resolvePathAlloc(arena: Allocator, dir: []const u8, raw: []const u8) Allocator.Error!?[]const u8 {
    const resolved = try std.fs.path.resolveAllocPosix(arena, &.{ dir, raw });
    if (resolved.len > std.Io.Dir.max_path_bytes) return null;
    return resolved;
}

/// Returns `raw`, a `file_path_spec`, resolved against `dir` (absolute,
/// `/`-separated) and classed for §13.2.1.1. §13.2.1 "Paths that do not
/// begin with / are relative to the directory in which the current lib.map
/// file is located"; "Paths that end in / shall include all files in the
/// specified directory. Identical to /*." Null when `resolvePathAlloc` is.
fn resolveSpec(arena: Allocator, dir: []const u8, raw: []const u8) Allocator.Error!?Spec {
    assert(raw.len > 0);
    assert(dir.len > 0);
    const resolved = (try resolvePathAlloc(arena, dir, raw)) orelse return null;
    const base = std.fs.path.basenamePosix(raw);
    const class: Class = if (std.mem.endsWith(u8, raw, "/"))
        .directory
    else if (std.mem.findAny(u8, base, "*?") != null or std.mem.eql(u8, base, "..."))
        .wildcard
    else
        .file;
    return .{ .pattern = if (class == .directory) try std.mem.concat(arena, u8, &.{ resolved, "/*" }) else resolved, .class = class };
}

/// `path` with the host's separator written `/`, the one §13.2.1 paths use,
/// so a Windows map directory resolves against a spec like a POSIX one.
fn slashed(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.sep == '/') return path;
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    assert(std.mem.findScalar(u8, out, std.fs.path.sep) == null);
    return out;
}

fn nextSep(f: []const u8) ?usize {
    for (f, 0..) |c, i| if (std.fs.path.isSep(c)) {
        assert(i < f.len);
        return i;
    };
    return null;
}

fn segments(p: []const u8, f: []const u8) bool {
    if (p.len == 0) return f.len == 0;
    const p_end = std.mem.findScalar(u8, p, '/') orelse p.len;
    const p_rest = if (p_end == p.len) "" else p[p_end + 1 ..];
    if (std.mem.eql(u8, p[0..p_end], "...")) {
        var rest = f;
        // Each pass drops one directory of `f`.
        for (0..f.len + 1) |_| {
            if (segments(p_rest, rest)) return true;
            const slash = nextSep(rest) orelse return false;
            rest = rest[slash + 1 ..];
        }
        unreachable;
    }
    if (f.len == 0) return false;
    const f_end = nextSep(f) orelse f.len;
    return glob(p[0..p_end], f[0..f_end]) and segments(p_rest, if (f_end == f.len) "" else f[f_end + 1 ..]);
}

fn glob(p: []const u8, s: []const u8) bool {
    // Greedy, with one way back: the last `*` and how much of `s` it has
    // taken. A later `*` makes every earlier one's choice final, so a
    // failure only ever grows the last star's run: O(len(p) * len(s)),
    // where trying every split among the stars was exponential in them.
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var taken: usize = 0;
    // Each pass moves `si`, or moves `pi` past a `*`, or retries a star one
    // byte further: (len(p) + 1) * (len(s) + 1) passes bound it.
    var passes: usize = 0;
    while (si < s.len) : (passes += 1) {
        assert(passes <= (p.len + 1) * (s.len + 1));
        if (pi < p.len and p[pi] != '*' and (p[pi] == '?' or p[pi] == s[si])) {
            pi += 1;
            si += 1;
        } else if (pi < p.len and p[pi] == '*') {
            star = pi;
            pi += 1;
            taken = si;
        } else if (star) |at| {
            pi = at + 1;
            taken += 1;
            si = taken;
        } else return false;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    assert(pi <= p.len);
    return pi == p.len;
}

/// Independent oracle for `glob`: the textbook dynamic program, `dp[i][j]`
/// true when the first `i` pattern characters match the first `j` of `s`.
fn testGlobOracle(p: []const u8, s: []const u8) bool {
    var dp: [8][8]bool = @splat(@splat(false));
    dp[0][0] = true;
    for (1..p.len + 1) |i| {
        dp[i][0] = p[i - 1] == '*' and dp[i - 1][0];
        for (1..s.len + 1) |j| {
            if (p[i - 1] == '*') {
                dp[i][j] = dp[i - 1][j] or dp[i][j - 1];
            } else {
                dp[i][j] = dp[i - 1][j - 1] and (p[i - 1] == '?' or p[i - 1] == s[j - 1]);
            }
        }
    }
    return dp[p.len][s.len];
}

/// Runs `r` to completion against `table` (`path` -> `real`/`bytes`, or
/// `null` bytes for an unreadable path), answering every request from it.
fn runTable(r: *Reader, table: []const TableEntry) !void {
    while (try r.run()) |req| switch (req) {
        .file => |want| {
            const e = for (table) |t| {
                if (std.mem.eql(u8, t.path, want.path)) break t;
            } else null;
            try r.answer(if (e) |t|
                (if (t.bytes) |b| Answer{ .file = .{ .bytes = b, .real = t.real } } else Answer{ .unreadable = error.FileNotFound })
            else
                .{ .unreadable = error.FileNotFound });
        },
    };
}

fn chainTest(a: Allocator, n: usize) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var table: std.ArrayList(TableEntry) = .empty;
    for (0..n) |k| try names.append(a, try std.fmt.allocPrint(a, "/chain/m{d}.map", .{k}));
    for (0..n) |k| {
        const body = if (k + 1 == n) try std.fmt.allocPrint(a, "library deep{d} x.v;\n", .{k}) else try std.fmt.allocPrint(a, "include m{d}.map;\n", .{k + 1});
        try table.append(a, .{ .path = names.items[k], .real = names.items[k], .bytes = body });
    }
    var r: Reader = .init(a, names.items[0..1]);
    try runTable(&r, table.items);
    const out = r.output();
    try testing.expect(out.refusal == null);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "deep{d}", .{n - 1}), out.libraries[0].name);
}

fn refusalOf(a: Allocator, text: []const u8) ![]const u8 {
    var r: Reader = .init(a, &.{"/bad.map"});
    try runTable(&r, &.{.{ .path = "/bad.map", .real = "/bad.map", .bytes = text }});
    const out = r.output();
    try testing.expect(out.refusal != null);
    return out.refusal.?.message;
}

/// `pattern`'s class, written fresh (not calling `resolveSpec`): the rule
/// is the same (a trailing `/` is a directory; a wildcard character or
/// `...` in the last segment is a wildcard; else a file), independent of
/// the production classifier so a bug in one does not hide in the other.
fn randomClass(pattern: []const u8) Class {
    if (std.mem.endsWith(u8, pattern, "/")) return .directory;
    const last = if (std.mem.findScalarLast(u8, pattern, '/')) |i| pattern[i + 1 ..] else pattern;
    if (std.mem.findAny(u8, last, "*?") != null or std.mem.eql(u8, last, "...")) return .wildcard;
    return .file;
}

/// Independent reference for `Output.libraryOf`: a two-pass computation
/// (every library's own minimum class, then the global minimum, then the
/// first two libraries reaching it) in place of `libraryOf`'s one-pass
/// streaming compare, so the two implementations do not share a mistake.
fn bruteForceLibraryOf(libs: []const Library, file: []const u8) Placement {
    var mins: [5]?Class = @splat(null);
    for (libs, 0..) |l, i| {
        var m: ?Class = null;
        for (l.specs) |s| {
            if (!matches(s.pattern, file)) continue;
            if (m == null or @backingInt(s.class) < @backingInt(m.?)) m = s.class;
        }
        mins[i] = m;
    }
    var best: ?Class = null;
    for (mins[0..libs.len]) |m| {
        const c = m orelse continue;
        if (best == null or @backingInt(c) < @backingInt(best.?)) best = c;
    }
    const b = best orelse return .{ .lib = "work" };
    var first: ?[]const u8 = null;
    var second: ?[]const u8 = null;
    for (libs, 0..) |l, i| {
        if (mins[i] == null or mins[i].? != b) continue;
        if (first == null) {
            first = l.name;
        } else if (second == null) {
            second = l.name;
        }
    }
    if (second) |t| return .{ .ambiguous = .{ first.?, t } };
    return .{ .lib = first.? };
}

fn placementEql(a: Placement, b: Placement) bool {
    return switch (a) {
        .lib => |x| b == .lib and std.mem.eql(u8, x, b.lib),
        .ambiguous => |x| b == .ambiguous and std.mem.eql(u8, x[0], b.ambiguous[0]) and std.mem.eql(u8, x[1], b.ambiguous[1]),
    };
}

test "§13.7.2 file path specification examples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = [_][]const u8{ "/proj/lib1/rtl/a.v", "/proj/lib2/gates/a.v", "/proj/lib1/rtl/b.v", "/proj/lib2/gates/b.v" };
    const cases = [_]struct { dir: []const u8, spec: []const u8, want: [4]bool }{
        .{ .dir = "/proj", .spec = "/proj/lib*/*/a.v", .want = .{ true, true, false, false } },
        .{ .dir = "/proj", .spec = ".../a.v", .want = .{ true, true, false, false } },
        .{ .dir = "/proj", .spec = "/proj/.../b.v", .want = .{ false, false, true, true } },
        .{ .dir = "/proj", .spec = ".../rtl/*.v", .want = .{ true, false, true, false } },
        .{ .dir = "/proj/lib1", .spec = "../lib2/gates/*.v", .want = .{ false, true, false, true } },
        .{ .dir = "/proj/lib1", .spec = "./rtl/?.v", .want = .{ true, false, true, false } },
        .{ .dir = "/proj/lib1", .spec = "./rtl/", .want = .{ true, false, true, false } },
    };
    for (cases) |c| {
        const s = (try resolveSpec(a, c.dir, c.spec)).?;
        for (files, c.want) |f, w| try testing.expectEqual(w, matches(s.pattern, f));
    }
    // §13.2.1: "The paths ./*.v and *.v are identical".
    try testing.expectEqualStrings((try resolveSpec(a, "/d", "./*.v")).?.pattern, (try resolveSpec(a, "/d", "*.v")).?.pattern);
}

test "§13.7.3 resolving multiple path specifications" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = "/proj/tb";
    const out: Output = .{ .libraries = &.{
        .{ .name = "lib1", .specs = &.{(try resolveSpec(a, dir, "/proj/lib1/foo*.v")).?} },
        .{ .name = "lib2", .specs = &.{(try resolveSpec(a, dir, "/proj/lib1/foo.v")).?} },
        .{ .name = "lib3", .specs = &.{(try resolveSpec(a, dir, "../lib1/")).?} },
        .{ .name = "lib4", .specs = &.{(try resolveSpec(a, dir, "/proj/lib1/*ver.v")).?} },
    } };
    try testing.expectEqualStrings("lib1", out.libraryOf("/proj/lib1/foobar.v").lib);
    try testing.expectEqualStrings("lib2", out.libraryOf("/proj/lib1/foo.v").lib);
    try testing.expectEqualStrings("lib3", out.libraryOf("/proj/lib1/bar.v").lib);
    try testing.expectEqualStrings("lib4", out.libraryOf("/proj/lib1/barver.v").lib);
    const tie = out.libraryOf("/proj/lib1/foover.v").ambiguous;
    try testing.expectEqualStrings("lib1", tie[0]);
    try testing.expectEqualStrings("lib4", tie[1]);
    // §13.2.1: "Any file ... that does not match any library's
    // file_path_spec shall by default be compiled into a library named work."
    try testing.expectEqualStrings("work", out.libraryOf("/proj/tb/top.v").lib);
    // A directory specification is not recursive.
    try testing.expectEqualStrings("work", out.libraryOf("/proj/lib1/sub/bar.v").lib);
}

test "Tokens: words, quoted strings, `,` and `;`, and comments only where a word could start" {
    var t: Tokens = .{ .text = "library lib1 \"a b.v\",lib/*.v; // tail\n/* block */ include x;" };
    for ([_][]const u8{ "library", "lib1", "\"a b.v\"", ",", "lib/*.v", ";", "include", "x", ";" }) |w|
        try testing.expectEqualStrings(w, t.next().?.text);
    try testing.expect(t.next() == null);
    // An unterminated string or comment runs to the end of the text.
    var q: Tokens = .{ .text = "\"open" };
    try testing.expectEqualStrings("\"open", q.next().?.text);
    try testing.expect(q.next() == null);
    var c: Tokens = .{ .text = "a /* open" };
    try testing.expectEqualStrings("a", c.next().?.text);
    try testing.expect(c.next() == null);
    // `start` is the byte the diagnostic points at.
    var s: Tokens = .{ .text = "  ab ;" };
    try testing.expectEqual(@as(u32, 2), s.next().?.start);
    try testing.expectEqual(@as(u32, 5), s.next().?.start);
}

test "isIdentifier is a simple identifier; unquote strips one pair of quotes" {
    for ([_][]const u8{ "lib1", "_a$", "A_b9" }) |w| try testing.expect(isIdentifier(w));
    for ([_][]const u8{ "", "1a", "$a", "a-b", "\"a\"" }) |w| try testing.expect(!isIdentifier(w));
    try testing.expectEqualStrings("a b", unquote("\"a b\""));
    try testing.expectEqualStrings("\"a", unquote("\"a"));
    try testing.expectEqualStrings("", unquote("\"\""));
    try testing.expectEqualStrings("a", unquote("a"));
}

test "resolveSpec classes a specification by its last name and resolves it against the map's directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, []const u8, Class };
    for ([_]Case{
        .{ "a.v", "/m/a.v", .file },
        .{ "rtl/*.v", "/m/rtl/*.v", .wildcard },
        .{ "a?.v", "/m/a?.v", .wildcard },
        // §13.2.1.1 classes by the file name: `...` in a directory does not
        // make an explicit file name a wildcard.
        .{ ".../a.v", "/m/.../a.v", .file },
        .{ "rtl/...", "/m/rtl/...", .wildcard },
        .{ "rtl/", "/m/rtl/*", .directory },
        .{ "/abs/x.v", "/abs/x.v", .file },
        .{ "../up/x.v", "/up/x.v", .file },
    }) |c| {
        const s = (try resolveSpec(a, "/m", c[0])).?;
        try testing.expectEqualStrings(c[1], s.pattern);
        try testing.expectEqual(c[2], s.class);
    }
}

test "matches: `?` is one character, `*` stays inside one name, `...` spans any number of directories" {
    const Case = struct { []const u8, []const u8, bool };
    for ([_]Case{
        .{ "/p/a?.v", "/p/ab.v", true },
        .{ "/p/a?.v", "/p/a.v", false },
        .{ "/p/a?.v", "/p/abc.v", false },
        .{ "/p/*.v", "/p/x/y.v", false },
        .{ "/p/*.v", "/p/.v", true },
        .{ "/p/*", "/p/x", true },
        .{ "/p/.../x.v", "/p/x.v", true },
        .{ "/p/.../x.v", "/p/a/b/c/x.v", true },
        .{ "/p/.../x.v", "/q/x.v", false },
        // `...` names directories: a pattern ending in it holds no file.
        .{ "/p/...", "/p/x.v", false },
        .{ "/p/a.v", "/p/a.v", true },
        .{ "/p/a.v", "/p", false },
    }) |c| try testing.expectEqual(c[2], matches(c[0], c[1]));
}

test "glob agrees with a dynamic-programming oracle on every short pattern and name" {
    // Exhaustive: patterns of up to 4 characters over `a b * ?` against
    // names of up to 5 over `a b`.
    const alphabet = "ab*?";
    var pbuf: [4]u8 = undefined;
    var sbuf: [5]u8 = undefined;
    for (0..5) |plen| {
        for (0..std.math.pow(usize, 4, plen)) |pi| {
            var x = pi;
            for (pbuf[0..plen]) |*ch| {
                ch.* = alphabet[x % 4];
                x /= 4;
            }
            for (0..6) |slen| {
                for (0..@as(usize, 1) << @intCast(slen)) |si| {
                    for (sbuf[0..slen], 0..) |*ch, k| ch.* = if ((si >> @intCast(k)) & 1 == 0) 'a' else 'b';
                    try testing.expectEqual(testGlobOracle(pbuf[0..plen], sbuf[0..slen]), glob(pbuf[0..plen], sbuf[0..slen]));
                }
            }
        }
    }
}

test "glob stays fast on a pattern of many stars against a long name" {
    // A matcher that backtracks over every split of the name among the stars
    // tries about C(60, 14) of them here before answering.
    const pattern = "*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b";
    var name: [60]u8 = @splat('a');
    try testing.expect(!glob(pattern, &name));
    name[59] = 'b';
    try testing.expect(glob(pattern, &name));
}

test "libraryOf: a better class ends a tie, and a tie names the first two libraries" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out: Output = .{ .libraries = &.{
        .{ .name = "w1", .specs = &.{(try resolveSpec(a, "/p", "*.v")).?} },
        .{ .name = "w2", .specs = &.{(try resolveSpec(a, "/p", "?.v")).?} },
        .{ .name = "w3", .specs = &.{(try resolveSpec(a, "/p", "x*")).?} },
        .{ .name = "d", .specs = &.{(try resolveSpec(a, "/p", "./")).?} },
        .{ .name = "f", .specs = &.{ (try resolveSpec(a, "/p", "y.v")).?, (try resolveSpec(a, "/p", "*.v")).? } },
    } };
    // x.v: three libraries tie on a wildcard (the directory is less specific).
    const tie = out.libraryOf("/p/x.v").ambiguous;
    try testing.expectEqualStrings("w1", tie[0]);
    try testing.expectEqualStrings("w2", tie[1]);
    // y.v: `f`'s explicit file name beats the wildcards that tied before it.
    try testing.expectEqualStrings("f", out.libraryOf("/p/y.v").lib);
    // z.txt: only the directory specification matches.
    try testing.expectEqualStrings("d", out.libraryOf("/p/z.txt").lib);
}

test "§13.5.1 order is declaration order, with `work` last unless a map declares it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { Output, []const []const u8 };
    for ([_]Case{
        .{ .{}, &.{"work"} },
        .{ .{ .libraries = &.{ .{ .name = "b", .specs = &.{} }, .{ .name = "a", .specs = &.{} } } }, &.{ "b", "a", "work" } },
        .{ .{ .libraries = &.{ .{ .name = "x", .specs = &.{} }, .{ .name = "work", .specs = &.{} } } }, &.{ "x", "work" } },
    }) |c| {
        const got = try c[0].order(a);
        try testing.expectEqual(c[1].len, got.len);
        for (c[1], got) |want, name| try testing.expectEqualStrings(want, name);
    }
    const out: Output = .{ .libraries = &.{ .{ .name = "x", .specs = &.{} }, .{ .name = "y", .specs = &.{} } } };
    try testing.expectEqual(@as(?usize, 1), out.declares("y"));
    try testing.expectEqual(@as(?usize, null), out.declares("work"));
    // `-L ''` reaches here from argv: no library is called that.
    try testing.expectEqual(@as(?usize, null), out.declares(""));
}

test "§13.2.2 Reader reads library and include statements, and a library declared twice holds both" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var r: Reader = .init(a, &.{"/root/lib.map"});
    try runTable(&r, &.{
        .{ .path = "/root/lib.map", .real = "/root/lib.map", .bytes = test_map },
        .{ .path = "/root/sub/more.map", .real = "/root/sub/more.map", .bytes = "library rtl gates/;\nlibrary gl *.vg;\n" },
    });
    const out = r.output();
    try testing.expect(out.refusal == null);
    try testing.expectEqual(@as(usize, 2), out.libraries.len);
    const rtl = out.libraries[0];
    try testing.expectEqualStrings("rtl", rtl.name);
    try testing.expectEqual(@as(usize, 3), rtl.specs.len);
    try testing.expect(std.mem.endsWith(u8, rtl.specs[0].pattern, "/rtl/*.v") and rtl.specs[0].class == .wildcard);
    try testing.expect(std.mem.endsWith(u8, rtl.specs[1].pattern, "/q/x.v") and rtl.specs[1].class == .file);
    // An included map's relative paths are relative to that map.
    try testing.expect(std.mem.endsWith(u8, rtl.specs[2].pattern, "/sub/gates/*") and rtl.specs[2].class == .directory);
    try testing.expectEqualStrings("gl", out.libraries[1].name);
    try testing.expectEqual(@as(usize, 2), out.incdirs.len);
    try testing.expect(std.mem.endsWith(u8, out.incdirs[0], "/inc"));
    try testing.expect(std.mem.endsWith(u8, out.incdirs[1], "/inc 2"));
}

test "§13.2.2 include nesting has no depth bound: a stack runs 40 deep, past the old 32, and 10,000 deep" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try chainTest(arena_state.allocator(), 40);
    try chainTest(arena_state.allocator(), 10_000);
}

test "§13.2.2 Syntax 13-2: every malformed statement is E0244 naming what it found" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "config c;", "a library map holds `library` and `include` statements only" },
        .{ "library 1x a.v;", "`1x` is not a library_identifier" },
        .{ "library", "`library` names no library" },
        .{ "library lib a.v", "a library declaration ends with `;`" },
        .{ "library lib ;", "needs a file_path_spec here (Syntax 13-2), found `;`" },
        .{ "library lib a.v b.v;", "found `b.v`: file_path_specs are separated by `,`" },
        // A.1.1: the `-incdir` list follows at least one file_path_spec.
        .{ "library lib -incdir x;", "needs a file_path_spec here (Syntax 13-2), found `-incdir`" },
        .{ "library lib a.v, -incdir x;", "needs a file_path_spec here (Syntax 13-2), found `-incdir`" },
        .{ "library lib a.v -incdir ;", "`-incdir` needs a file_path_spec here" },
        .{ "library lib a.v -incdir x y;", "found `y`: -incdir file_path_specs are separated by `,`" },
        .{ "library lib a.v -incdir x", "a library declaration ends with `;`" },
        .{ "include ;", "`include` names no file_path_spec" },
        .{ "include", "`include` names no file_path_spec" },
        .{ "include x.map", "an `include` statement ends with `;`" },
        .{ "include x.map y;", "found `y`: an `include` statement ends with `;`" },
        .{ "include missing.map;", "cannot read library map" },
        // Syntax 13-2 has no empty file_path_spec, in any of its three places.
        .{ "library lib \"\";", "`\"\"` is an empty file_path_spec" },
        .{ "library lib a.v -incdir \"\";", "`\"\"` is an empty file_path_spec" },
        .{ "include \"\";", "`\"\"` is an empty file_path_spec" },
        // A map that includes itself would never end: a named cycle.
        .{ "include bad.map;", "library map `include` cycle:" },
    }) |c| {
        const msg = try refusalOf(a, c[0]);
        if (std.mem.find(u8, msg, c[1]) == null) {
            std.debug.print("`{s}`: got \"{s}\", want \"{s}\"\n", .{ c[0], msg, c[1] });
            return error.TestUnexpectedResult;
        }
    }
    // A top-level map that cannot be read has no file to point into.
    var r: Reader = .init(a, &.{"/nonexistent-vera-dir/x.map"});
    const req = (try r.run()).?;
    try r.answer(.{ .unreadable = error.FileNotFound });
    try testing.expect(req == .file);
    try testing.expect((try r.run()) == null);
    const out = r.output();
    try testing.expect(out.refusal != null);
    try testing.expectEqual(@as(?u32, null), out.refusal.?.file);
    try testing.expect(std.mem.find(u8, out.refusal.?.message, "cannot read library map") != null);
}

test "a file_path_spec past the path-length cap is refused, not an unbounded recursion" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var long: std.ArrayList(u8) = .empty;
    for (0..std.Io.Dir.max_path_bytes) |_| try long.appendSlice(a, "a/");
    try long.appendSlice(a, "x.v");
    const text = try std.fmt.allocPrint(a, "library lib {s};\n", .{long.items});
    const msg = try refusalOf(a, text);
    try testing.expect(std.mem.find(u8, msg, "is longer than a path") != null);
}

test "libraryOf agrees with a brute-force reference" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x11b_fa5_5eed);
    const rnd = prng.random();
    const segs = [_][]const u8{ "a", "b", "*", "?", "..." };
    for (0..10_000) |_| {
        const n_libs = 1 + rnd.uintLessThan(usize, 5);
        var libs: [5]Library = undefined;
        for (0..n_libs) |i| {
            const n_specs = 1 + rnd.uintLessThan(usize, 3);
            var specs: std.ArrayList(Spec) = .empty;
            for (0..n_specs) |_| {
                var buf: std.ArrayList(u8) = .empty;
                const depth = 1 + rnd.uintLessThan(usize, 3);
                for (0..depth) |j| {
                    if (j != 0) try buf.append(a, '/');
                    try buf.appendSlice(a, segs[rnd.uintLessThan(usize, segs.len)]);
                }
                if (rnd.boolean()) try buf.append(a, '/');
                const pattern = buf.items;
                try specs.append(a, .{ .pattern = pattern, .class = randomClass(pattern) });
            }
            libs[i] = .{ .name = try std.fmt.allocPrint(a, "lib{d}", .{i}), .specs = specs.items };
        }
        var fbuf: std.ArrayList(u8) = .empty;
        const fdepth = 1 + rnd.uintLessThan(usize, 4);
        for (0..fdepth) |j| {
            if (j != 0) try fbuf.append(a, '/');
            try fbuf.appendSlice(a, if (rnd.boolean()) "a" else "b");
        }
        const out: Output = .{ .libraries = libs[0..n_libs] };
        const got = out.libraryOf(fbuf.items);
        const want = bruteForceLibraryOf(libs[0..n_libs], fbuf.items);
        try testing.expect(placementEql(got, want));
    }
}
