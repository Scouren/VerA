//! `Instance`'s field order (already rendered by `instance.zig`) plus a text
//! scan of the whole, already-rendered device -> `field_use`
//! (`contract.FieldUse`, #134), one entry per `Instance` field, in
//! declaration order. Called last, after every other declaration
//! (`eval`/`q`/`evalQ`/`limit`/`initState`/`updateState`/`acceptQ`/
//! `stateCtl`) is text in `self.out`; a text scan, like `unit.scanSimReads`,
//! so every renderer that spells a read or a write is covered and a mention
//! in a comment only over-reports — safe, since `fieldUse`'s contract is a
//! superset (`sim_state.zig`'s doc on `FieldUse`).
//!
//! `res`/`jac`/`q`/`limit` cannot be told apart from text alone once a field
//! reaches the shared core (every residual, charge site and `limit` clamp
//! that forwards into it reads the SAME rendered body), so a field read
//! there sets whichever of those four its own entry point(s) also reach
//! (`core` is unioned into all of them). `jac` is `res or q` (a derivative
//! lane of either, never scanned on its own): `sim_state.zig`'s doc on
//! `FieldUse` already says so. The only genuine separation this scan can
//! make is between what each entry point's OWN body (outside the shared
//! core) reads, e.g. a field a device's `q` wrapper accumulates after the
//! core call, which never shows up in `eval`'s `res`.
//!
//! Contents:
//! - `pub fn emit(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const Error = codegen.Error;

/// Which outputs a text occurrence of an `Instance` field can reach,
/// gathered per field before any of it is rendered as `contract.FieldUse`
/// bits.
const Use = struct {
    res: bool = false,
    q: bool = false,
    limit: bool = false,
    state: bool = false,
    w_update: bool = false,
    w_commit: bool = false,
};

/// Appends `field_use`, #134's per-`Instance`-field `contract.FieldUse`
/// array, in `Instance`'s declaration order. Called once, after every other
/// declaration (`file.emitFile`'s tail, beside `sim_reads`), so the scan
/// sees the whole rendered device.
pub fn emit(self: *Gen) Error!void {
    const names = try instanceFieldNames(self);
    const text = self.out.items;
    const core = coreRange(self, text);
    const eval_r = declRange(text, "\npub fn eval(");
    const q_r = declRange(text, "\npub fn q(");
    const evalq_r = declRange(text, "\npub fn evalQ(");
    const limit_r = declRange(text, "\npub fn limit(");
    const update_r = declRange(text, "\npub fn updateState(");
    const accept_r = declRange(text, "\npub fn acceptQ(");
    const ctl_r = declRange(text, "\npub fn stateCtl(");
    const commit_r = commitArm(text, ctl_r);

    // A bit's entry point(s) pull in the shared core's own range ONLY when
    // their rendered body actually calls it (the `core` alias, `file.zig`):
    // `limit` with no clamp that reads the core never names it, and nor does
    // a reject-only `limit`, so unioning `core` in unconditionally would set
    // every one of `res`/`q`/`limit` together for ANY device with a core,
    // whether or not that entry point ever reaches it.
    const core_in_eval = callsCore(text, eval_r) or callsCore(text, evalq_r);
    const core_in_q = callsCore(text, q_r) or callsCore(text, evalq_r);
    const core_in_limit = callsCore(text, limit_r);

    const uses = try self.arena.alloc(Use, names.len);
    for (names, uses) |name, *u| {
        const res = anyUse(text, eval_r, name) or anyUse(text, evalq_r, name) or (core_in_eval and anyUse(text, core, name));
        const q_use = anyUse(text, q_r, name) or anyUse(text, evalq_r, name) or (core_in_q and anyUse(text, core, name));
        u.* = .{
            .res = res,
            .q = q_use,
            .limit = anyUse(text, limit_r, name) or (core_in_limit and anyUse(text, core, name)),
            // `initState` is excluded: `FieldUse.state`'s doc is specifically
            // what `updateState`/`acceptQ` stage, not a seed from `Instance`
            // at analysis start (no bit names that).
            .state = anyUse(text, update_r, name) or anyUse(text, accept_r, name),
            .w_update = anyWrite(text, update_r, name) or anyWrite(text, accept_r, name),
            .w_commit = anyWrite(text, commit_r, name),
        };
    }

    try self.w(
        "/// Which outputs each `Instance` field's read can reach, and which\n" ++
            "/// entry points write it (`contract.FieldUse`, #134): a text scan, like\n" ++
            "/// `sim_reads` above, so a field forwarded into `eval`/`q`/`limit` ONLY\n" ++
            "/// through the shared core sets every one of those its own entry\n" ++
            "/// point(s) reach; `jac` follows `res`/`q` (`contract.FieldUse`'s doc).\n" ++
            "pub const field_use = [{d}]contract.FieldUse{{\n",
        .{names.len},
    );
    for (uses) |u| try self.w(
        "    .{{ .res = {}, .jac = {}, .q = {}, .limit = {}, .state = {}, .w_update = {}, .w_commit = {} }},\n",
        .{ u.res, u.res or u.q, u.q, u.limit, u.state, u.w_update, u.w_commit },
    );
    try self.w("}};\n\n", .{});
}

/// A half-open byte range of `self.out.items`, or an empty one (`lo == hi`)
/// when the marker is absent — a device need not declare every entry point.
const Range = struct { lo: usize = 0, hi: usize = 0 };

/// `self.files`' entry for `self.core.name` (`file.recordUnitFile`, from
/// `unit.emitCoreDecl`), or an empty range when the device has no shared
/// core (every residual computes inline).
fn coreRange(self: *const Gen, text: []const u8) Range {
    if (self.core.name.len == 0) return .{};
    const lo = self.files.items(.lo);
    const hi = self.files.items(.hi);
    for (self.files.items(.name), 0..) |name, i| {
        if (std.mem.eql(u8, name, self.core.name)) {
            assert(hi[i] <= text.len);
            return .{ .lo = lo[i], .hi = hi[i] };
        }
    }
    return .{};
}

/// The byte range from `marker` (a top-level declaration's own leading
/// newline and keyword, e.g. `"\npub fn eval("`) to the next top-level
/// declaration at column 0 (`"\npub "`, `"\nconst "`, `"\ncomptime "` or
/// `"\ntest "`), or the text's end. Every declaration this scan looks for is
/// column-0 Zig this compiler renders itself, so the boundary is exact
/// without parsing a single one of them: a doc comment's `///` line cannot
/// match a marker, and nothing this compiler emits is indented less than its
/// own top-level declarations.
fn declRange(text: []const u8, marker: []const u8) Range {
    const lo = std.mem.find(u8, text, marker) orelse return .{};
    var hi = text.len;
    for ([_][]const u8{ "\npub ", "\nconst ", "\ncomptime ", "\ntest " }) |next| {
        if (std.mem.findPos(u8, text, lo + 1, next)) |p| hi = @min(hi, p);
    }
    assert(hi > lo);
    return .{ .lo = lo, .hi = hi };
}

/// Whether `text[range.lo..range.hi]` calls the shared core: the bare word
/// `core`, boundary-checked both sides (the local alias `file.zig` writes,
/// `"const core = {s};"`, so every caller spells it this one way regardless
/// of the core's own mangled name).
fn callsCore(text: []const u8, range: Range) bool {
    if (range.lo == range.hi) return false;
    const ident = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_';
        }
    }.f;
    const hay = text[0..range.hi];
    var i = range.lo;
    var iterations: usize = 0;
    while (std.mem.findPos(u8, hay, i, "core")) |k| : (iterations += 1) {
        assert(iterations <= hay.len);
        i = k + "core".len;
        if (k > 0 and ident(hay[k - 1])) continue;
        if (i < hay.len and ident(hay[i])) continue;
        return true;
    }
    return false;
}

/// `ctl`'s `.commit` arm (`state_ctl.emitStateCtl`'s `"if (op == .commit) {"`
/// up to the next `"} else {"`), or an empty range when `ctl` itself is
/// empty (no `stateCtl`) or the arm's own marker is not found (defensive:
/// every emitted `stateCtl` has one).
fn commitArm(text: []const u8, ctl: Range) Range {
    if (ctl.lo == ctl.hi) return .{};
    const marker = "if (op == .commit) {";
    const lo = std.mem.findPos(u8, text, ctl.lo, marker) orelse return .{};
    if (lo >= ctl.hi) return .{};
    const hi = std.mem.findPos(u8, text, lo, "} else {") orelse ctl.hi;
    return .{ .lo = lo, .hi = @min(hi, ctl.hi) };
}

/// Whether `field` occurs in `text[range.lo..range.hi]` as a dot-accessed
/// field (`.field`, any receiver) or as the exact quoted string a reflected
/// read passes (`"field"`, `kernels.zInst`'s `@field(inst, f)` pattern:
/// `$mfactor` and a path latch read `Instance` this way, never as
/// `inst.<field>` text). Boundary-checked both sides so a field whose name
/// is another's prefix (`pb__0` inside `pb__01`) cannot match.
fn anyUse(text: []const u8, range: Range, field: []const u8) bool {
    if (range.lo == range.hi) return false;
    return findOccurrence(text, range, field, .read) != null;
}

/// Whether `field` is directly assigned (`inst.field = …` or `+=`, the
/// in-place accumulate path latches use) inside `text[range.lo..range.hi]`.
/// `inst` is this scan's only receiver, unlike `anyUse`'s any-receiver dot
/// access: a write worth a `w_update`/`w_commit` bit is always to the
/// `Instance` parameter, never to a local copy.
fn anyWrite(text: []const u8, range: Range, field: []const u8) bool {
    if (range.lo == range.hi) return false;
    return findOccurrence(text, range, field, .write) != null;
}

const Kind = enum { read, write };

fn findOccurrence(text: []const u8, range: Range, field: []const u8, kind: Kind) ?usize {
    assert(field.len != 0);
    assert(range.hi <= text.len);
    const ident = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_';
        }
    }.f;
    const hay = text[0..range.hi];
    var i = range.lo;
    var iterations: usize = 0;
    while (std.mem.findPos(u8, hay, i, field)) |k| : (iterations += 1) {
        assert(iterations <= hay.len); // bounded: `i` moves past each match
        assert(k >= range.lo); // `findPos` never returns a match before `i`
        i = k + field.len;
        if (i < hay.len and ident(hay[i])) continue; // a longer identifier
        switch (kind) {
            .read => {
                if (k > 0 and hay[k - 1] == '.') return k;
                if (k > 0 and i < hay.len and hay[k - 1] == '"' and hay[i] == '"') return k;
            },
            .write => {
                if (k < "inst.".len or !std.mem.eql(u8, hay[k - "inst.".len .. k], "inst.")) continue;
                var e = i;
                while (e < hay.len and hay[e] == ' ') e += 1;
                if (e + 1 < hay.len and hay[e] == '+' and hay[e + 1] == '=') return k; // +=
                if (e >= hay.len or hay[e] != '=') continue;
                const prev_is_cmp = e > 0 and (hay[e - 1] == '!' or hay[e - 1] == '=');
                const next_is_eq = e + 1 < hay.len and hay[e + 1] == '=';
                if (!prev_is_cmp and !next_is_eq) return k; // plain `=`, not `==`/`!=`
            },
        }
    }
    return null;
}

/// `Instance`'s field names, in declaration order (`instance.zig`'s own
/// field order IS the ABI `field_use` indexes). A token scan of the already
/// -rendered struct, bracket-depth tracked so a field whose default is an
/// array or struct literal (nested braces) is not mistaken for one, and
/// stopping the instant depth goes negative: that is `Instance`'s own
/// closing brace, never guessed from a following declaration's spelling.
fn instanceFieldNames(self: *Gen) Error![]const []const u8 {
    const marker = "\npub const Instance = struct {";
    const at = std.mem.find(u8, self.out.items, marker) orelse return &.{};
    const body_start = at + marker.len;
    try self.out.append(self.gpa, 0);
    defer _ = self.out.pop();
    const src = self.out.items[body_start .. self.out.items.len - 1 :0];
    var names: std.ArrayList([]const u8) = .empty;
    var depth: i32 = 0;
    var t: std.zig.Tokenizer = .init(src);
    var iterations: usize = 0;
    while (true) : (iterations += 1) {
        assert(iterations <= src.len); // bounded: every token consumes >= 1 byte
        const tok = t.next();
        switch (tok.tag) {
            .eof => return names.toOwnedSlice(self.arena),
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => depth -= 1,
            .l_brace => depth += 1,
            .r_brace => {
                depth -= 1;
                if (depth < 0) return names.toOwnedSlice(self.arena); // Instance's own close
            },
            .identifier => {
                if (depth == 0) {
                    var ahead = t; // Tokenizer is a plain {buffer, index}: a cheap lookahead copy.
                    if (ahead.next().tag == .colon) {
                        try names.append(self.arena, try self.arena.dupe(u8, src[tok.loc.start..tok.loc.end]));
                    }
                }
            },
            else => {},
        }
    }
}

test "field_use: a $prev path latch is res/jac, w_commit only — never w_update (#134)" {
    // Same fixture as `unit.zig`'s "a $prev-only model still gets latch
    // staging and commit": `pb__0` is read through the shared core
    // (`zInst(S, inst, "pb__0")`, so `res`/`jac`) and staged, never written
    // to `Instance`, by `updateState` (`state.wb__0 = ...`, so `w_update`
    // false); only `stateCtl(.commit)` writes `inst.pb__0` (`w_commit`).
    // `q`/`limit` stay false: this model has neither.
    const Harness = @import("harness.zig").Harness;
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module avg(p, n);
        \\  inout p, n; electrical p, n;
        \\  real g;
        \\  analog begin
        \\    g = 1.0 + 0.1 * V(p, n);
        \\    I(p, n) <+ 0.5 * (g + $prev(g)) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(
        u8,
        s,
        "    .{ .res = true, .jac = true, .q = false, .limit = false, .state = false, .w_update = false, .w_commit = true },\n};\n",
    ) != null);
}

test "field_use: an idt offset is res/jac/q, state and w_update — never w_commit (#134)" {
    // Same fixture as `tests/unit/codegen_tests.zig`'s "an assert-form idt's
    // offset is committed and reverted by stateCtl": the integral offset is
    // an ordinary `.history` field, written straight to `Instance` by
    // `updateState` (`w_update`) off its OWN previous value (`state`, this
    // scan's doc on why `initState` does not count); `stateCtl(.commit)`
    // only backs it up into `State` (`state.<f> = inst.<f>`, never the other
    // way), so `w_commit` is false — only `.revert` writes `Instance` back.
    const Harness = @import("harness.zig").Harness;
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(a, n);
        \\  inout a, n; electrical a, n;
        \\  analog I(a, n) <+ 1e-3 * idt(1e9, 7.0, V(a, n));
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(
        u8,
        s,
        "    .{ .res = true, .jac = true, .q = true, .limit = false, .state = true, .w_update = true, .w_commit = false },\n};\n",
    ) != null);
}
