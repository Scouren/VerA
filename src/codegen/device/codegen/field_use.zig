//! `Instance`'s field order (already rendered by `instance.zig`) -> one
//! `contract.FieldUse` entry per field, in declaration order (#134). Most
//! fields are decided the way `unit.scanSimReads` decides `sim_reads`: a
//! text scan of the whole, already-rendered device, safe because a mention
//! in a comment only over-reports (`fieldUse`'s contract is a superset,
//! `sim_state.zig`'s doc on `FieldUse`). That scan cannot tell `res`/`jac`/
//! `q`/`limit`/`state` apart once a field reaches the shared core, because
//! every residual, charge site, `limit` clamp and accepted-point update
//! that forwards into it reads the SAME rendered body — fine for `res`/`q`/
//! `limit`/`state`, whose bits a superset never costs a host anything but a
//! stamp that happens to be zero, but NOT for `jac`: a host that keys a
//! bypass on `res`/`jac` specifically loses the whole optimisation on a
//! charge-only field the text scan marks `jac` just because its `q` is true.
//!
//! §5.6.1.2 path latches (`pb__k`/`pq__k`), scalar §5.10 held variables and
//! `$limit$old` (`limiter_previous`) are decided instead by `field_taint.zig`
//! over the Mir SSA graph: per-output, product/quotient/chain-rule-correct
//! dataflow from the field's own read site(s) to `eval`'s residual, `q`'s
//! charge, `limit`'s result and `updateState`'s staged value — independent
//! of which declaration's rendered text happens to call which core slice.
//! `fieldBits` dispatches by field name; every field outside this scope
//! (array-backed or string-held state, every per-operator history field)
//! keeps the text scan, unchanged.
//!
//! `w_update`/`w_commit` are mechanical regardless: which entry point's
//! rendered text assigns the field, never a question of what the source
//! multiplies it by, so both stay the text scan for every field.
//!
//! Contents:
//! - `pub fn emit(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const Error = codegen.Error;
const field_taint = @import("field_taint.zig");

/// Which outputs a text occurrence of an `Instance` field can reach,
/// gathered per field before any of it is rendered as `contract.FieldUse`
/// bits.
const Use = struct {
    res: bool = false,
    jac: bool = false,
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
    const core_name = self.core.name;
    const eval_r = declRange(text, "\npub fn eval(");
    const q_r = declRange(text, "\npub fn q(");
    const evalq_r = declRange(text, "\npub fn evalQ(");
    const limit_r = declRange(text, "\npub fn limit(");
    const update_r = declRange(text, "\npub fn updateState(");
    const accept_r = declRange(text, "\npub fn acceptQ(");
    const ctl_r = declRange(text, "\npub fn stateCtl(");
    const commit_r = commitArm(text, ctl_r);

    // A bit's entry point(s) pull in a core-family range ONLY when their
    // rendered body actually calls that declaration: `limit` with no clamp
    // that reads the core never names it, and nor does a reject-only
    // `limit`, so unioning one in unconditionally would set every one of
    // `res`/`q`/`limit`/`state` together for ANY device with a core, whether
    // or not that entry point ever reaches it.
    const eval_extra = coreCallRanges(self, text, eval_r, core_name);
    const evalq_extra = coreCallRanges(self, text, evalq_r, core_name);
    const q_extra = coreCallRanges(self, text, q_r, core_name);
    const limit_extra = coreCallRanges(self, text, limit_r, core_name);
    const update_extra = coreCallRanges(self, text, update_r, core_name);
    const accept_extra = coreCallRanges(self, text, accept_r, core_name);

    const uses = try self.arena.alloc(Use, names.len);
    for (names, uses) |name, *u| {
        const res = anyUseAcross(text, eval_r, eval_extra.items(), name) or
            anyUseAcross(text, evalq_r, evalq_extra.items(), name);
        const q_use = anyUseAcross(text, q_r, q_extra.items(), name) or
            anyUseAcross(text, evalq_r, evalq_extra.items(), name);
        u.* = .{
            .res = res,
            .jac = res or q_use,
            .q = q_use,
            .limit = anyUseAcross(text, limit_r, limit_extra.items(), name),
            // `initState` is excluded: `FieldUse.state`'s doc is specifically
            // what `updateState`/`acceptQ` stage, not a seed from `Instance`
            // at analysis start (no bit names that).
            .state = anyUseAcross(text, update_r, update_extra.items(), name) or
                anyUseAcross(text, accept_r, accept_extra.items(), name),
            .w_update = anyWrite(text, update_r, name) or anyWrite(text, accept_r, name),
            .w_commit = anyWrite(text, commit_r, name),
        };
        // §5.6.1.2 path latches, scalar §5.10 held variables and
        // `limiter_previous`: replace the text scan's `res`/`jac`/`q`/
        // `limit`/`state` with the exact per-output dataflow answer
        // (`field_taint.zig`). `w_update`/`w_commit` stay the text scan.
        if (try fieldBits(self, name)) |b| {
            u.res = b.res;
            u.jac = b.jac;
            u.q = b.q;
            u.limit = b.limit;
            u.state = b.state;
        }
    }

    try self.w(
        "/// Which outputs each `Instance` field's read can reach, and which\n" ++
            "/// entry points write it (`contract.FieldUse`, #134): `res`/`jac`/`q`/\n" ++
            "/// `limit`/`state` are exact per-output dataflow over the Mir graph for a\n" ++
            "/// §5.6.1.2 path latch, a scalar §5.10 held variable and `limiter_previous`\n" ++
            "/// (`field_taint.zig`), and a text scan like `sim_reads` above for every\n" ++
            "/// other field; `w_update`/`w_commit` are always the text scan.\n" ++
            "pub const field_use = [{d}]contract.FieldUse{{\n",
        .{names.len},
    );
    for (uses) |u| try self.w(
        "    .{{ .res = {}, .jac = {}, .q = {}, .limit = {}, .state = {}, .w_update = {}, .w_commit = {} }},\n",
        .{ u.res, u.jac, u.q, u.limit, u.state, u.w_update, u.w_commit },
    );
    try self.w("}};\n\n", .{});
}

/// The exact `field_taint.Bits` for `name`, or null when `name` is outside
/// this pass's scope (`field_use.zig`'s doc): a §5.6.1.2 path latch
/// (`pb__k`/`pq__k`), a scalar §5.10 held variable, or `limiter_previous`
/// (every `$limit$old` slot, aggregated: one Instance field serves all of
/// them, so its bits are the union over every slot).
fn fieldBits(self: *Gen, name: []const u8) Error!?field_taint.Bits {
    if (pathLatchIndex(name, "pb__")) |k| {
        if (k >= self.core.prev_lo.len) return null; // defensive: never not found
        const leaves = try field_taint.pathLeaves(self, self.arena, false, k);
        const t = try field_taint.compute(self, self.arena, leaves);
        return field_taint.sinks(self, &t);
    }
    if (pathLatchIndex(name, "pq__")) |k| {
        if (k >= self.core.acc_lo.len) return null;
        const leaves = try field_taint.pathLeaves(self, self.arena, true, k);
        const t = try field_taint.compute(self, self.arena, leaves);
        return field_taint.sinks(self, &t);
    }
    for (self.lowered.held_vars.items, self.names.held_names) |h, hn| {
        if (h.array != .none or h.ty == .string) continue; // out of scope: keep the text scan
        if (!std.mem.eql(u8, hn, name)) continue;
        const leaves = [_]Mir.Value{h.seed};
        const t = try field_taint.compute(self, self.arena, &leaves);
        return field_taint.sinks(self, &t);
    }
    if (std.mem.eql(u8, name, "limiter_previous") and self.lowered.limit_slots.items.len != 0) {
        var leaves: std.ArrayList(Mir.Value) = .empty;
        for (self.lowered.limit_slots.items) |slot| try leaves.append(self.arena, slot.seed);
        const t = try field_taint.compute(self, self.arena, leaves.items);
        return field_taint.sinks(self, &t);
    }
    return null;
}

/// `name`'s numeric suffix past `prefix` (`"pb__0"`, prefix `"pb__"` -> `0`),
/// or null when `name` does not start with `prefix` or the rest is not a
/// plain decimal integer.
fn pathLatchIndex(name: []const u8, prefix: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return std.fmt.parseInt(u32, name[prefix.len..], 10) catch null;
}

/// A half-open byte range of `self.out.items`, or an empty one (`lo == hi`)
/// when the marker is absent — a device need not declare every entry point.
const Range = struct { lo: usize = 0, hi: usize = 0 };

/// `self.files`' entry for exactly `name` (`file.recordUnitFile`, from
/// `unit.emitCoreDecl`, called once for the base core and once per
/// backward-slice declaration `unit.emitSlice` renders), or an empty range
/// when nothing by that name was recorded.
fn fileRange(self: *const Gen, text: []const u8, name: []const u8) Range {
    if (name.len == 0) return .{};
    const lo = self.files.items(.lo);
    const hi = self.files.items(.hi);
    for (self.files.items(.name), 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) {
            assert(hi[i] <= text.len);
            return .{ .lo = lo[i], .hi = hi[i] };
        }
    }
    return .{};
}

/// Every backward-slice suffix a core-family declaration's real name can
/// carry (`unit.sliceCore`'s callers): `limit`'s clamp arguments
/// (`cg_limit_args.coreName`) and `updateState`'s accepted-point reads
/// (`state.zig`'s `self.core = self.state_core`) are the two this scan's
/// entry points can reach; `__iter` (`advanceIteration`) and
/// `__noise`/`__opvars` (`noise`/`opVars`, no `FieldUse` bit of their own)
/// are listed too, at no cost, since none of them occurs inside a range
/// this scan looks at and the match is a plain substring search either way.
const slice_suffixes = [_][]const u8{ "__limit", "__state", "__iter", "__noise", "__opvars" };

/// Whether `text[range.lo..range.hi]` names `ident` as a whole identifier,
/// boundary-checked on both sides (not part of a longer name).
fn callsIdent(text: []const u8, range: Range, ident: []const u8) bool {
    if (range.lo == range.hi or ident.len == 0) return false;
    const is_ident = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_';
        }
    }.f;
    const hay = text[0..range.hi];
    var i = range.lo;
    var iterations: usize = 0;
    while (std.mem.findPos(u8, hay, i, ident)) |k| : (iterations += 1) {
        assert(iterations <= hay.len);
        i = k + ident.len;
        if (k > 0 and is_ident(hay[k - 1])) continue;
        if (i < hay.len and is_ident(hay[i])) continue;
        return true;
    }
    return false;
}

/// Up to one range per core-family declaration (`CoreRanges.items`'s own
/// length, `<= 1 + slice_suffixes.len`): a fixed-capacity array needs no
/// allocator.
const CoreRanges = struct {
    buf: [1 + slice_suffixes.len]Range = undefined,
    len: usize = 0,

    fn push(self: *CoreRanges, r: Range) void {
        if (r.lo == r.hi) return;
        assert(self.len < self.buf.len);
        self.buf[self.len] = r;
        self.len += 1;
    }

    fn items(self: *const CoreRanges) []const Range {
        return self.buf[0..self.len];
    }
};

/// The core-family declarations `range` actually calls, each by its OWN
/// recorded range: the base core's, when `range` names the bare `core`
/// alias (`eval`/`q`/`evalQ`, `unit.emitUnits`'s `"const core = {s};"`) or
/// the real core name with no suffix (`updateState`'s `self.core =
/// self.state_core` before its own call); one backward slice's own
/// (smaller) range per suffix `range` names it by.
fn coreCallRanges(self: *const Gen, text: []const u8, range: Range, core_name: []const u8) CoreRanges {
    var out: CoreRanges = .{};
    if (range.lo == range.hi or core_name.len == 0) return out;
    if (callsIdent(text, range, "core") or callsIdent(text, range, core_name)) {
        out.push(fileRange(self, text, core_name));
    }
    var buf: [256]u8 = undefined;
    for (slice_suffixes) |suf| {
        const full = std.fmt.bufPrint(&buf, "{s}{s}", .{ core_name, suf }) catch continue; // never a real unit name this long
        if (callsIdent(text, range, full)) out.push(fileRange(self, text, full));
    }
    return out;
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

/// `anyUse` over `own`, or over any of `extra` (the core-family
/// declarations `own`'s entry point calls, `coreCallRanges`).
fn anyUseAcross(text: []const u8, own: Range, extra: []const Range, field: []const u8) bool {
    if (anyUse(text, own, field)) return true;
    for (extra) |r| if (anyUse(text, r, field)) return true;
    return false;
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

test "field_use: a charge-only latch added beside an x-dependent term, times a constant, is q/w_commit ONLY — never jac (#134 correction)" {
    // The coordinator's own counter-example to a per-core-union scan: `pq +
    // (t(x) - pb) * r`, `r` a model constant (no unknown-dependence). `pb`
    // (`$prev(g)`) reaches `q` (it is inside the `ddt`), but its mixed
    // partial wrt any unknown is zero — `(t(x) - pb)` keeps `pb`'s own
    // derivative lane at zero (a leaf's is always zero) and ADDING it next
    // to `t(x)` introduces no cross term (`fsub` is linear), so multiplying
    // the sum by the CONSTANT `1.0` cannot manufacture one either (`fmul`'s
    // cross term needs the OTHER operand to already have a nonzero ordinary
    // derivative, and a literal never does). A per-core-union scan (or the
    // coarse `valTaint(pb) and derivActive(whole product)` shortcut) would
    // wrongly set `jac` here because the WHOLE product does vary with `x`
    // (through `t(x)`) — exactly the bug #134's correction is about: `jac`
    // must be `pb`'s OWN cross term, never inherited from its neighbours'.
    const Harness = @import("harness.zig").Harness;
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module charge_latch(p, n);
        \\  inout p, n; electrical p, n;
        \\  real g;
        \\  analog begin
        \\    g = V(p, n);
        \\    I(p, n) <+ ddt((V(p, n) * V(p, n) - $prev(g)) * 1.0);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(
        u8,
        s,
        "    .{ .res = false, .jac = false, .q = true, .limit = false, .state = false, .w_update = false, .w_commit = true },\n};\n",
    ) != null);
}

test "field_use: a latch multiplied by an x-dependent factor gets jac (#134 correction, the mos2 shape)" {
    // The coordinator's other named shape: a latch (`$prev(g)`) multiplied
    // by something that already varies with an unknown (`V(p, n)` itself)
    // DOES earn `jac`: `fmul`'s cross term `val(pb) and active(V(p,n))`
    // fires directly, unlike the `charge_latch` test above where the latch
    // is only ever added beside an x-dependent term and then scaled by a
    // constant.
    const Harness = @import("harness.zig").Harness;
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module mos2_latch(p, n);
        \\  inout p, n; electrical p, n;
        \\  real g;
        \\  analog begin
        \\    g = V(p, n);
        \\    I(p, n) <+ ddt(V(p, n) * $prev(g));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(
        u8,
        s,
        "    .{ .res = false, .jac = true, .q = true, .limit = false, .state = false, .w_update = false, .w_commit = true },\n};\n",
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

test "field_use: an idt offset reaches limit ONLY through core__limit, the real-name slice (#134)" {
    // Regression for a confirmed under-report: `limit` never calls the bare
    // `core` alias — only `eval`/`q`/`evalQ` do. When a clamp's algorithm
    // argument is not a leaf/param/setup-root (here `vcrit`, computed from
    // the idt offset), `limit` instead calls `<core>__limit`
    // (`cg_limit_args.coreName`), the core's OWN real (mangled) name plus
    // the literal suffix `"__limit"` — never the `core` alias at all. Before
    // `coreCallRanges` (this scan used to be `callsCore`, a bare-word search
    // for `core` alone): that call is invisible to a boundary-checked search
    // for the word `core`, because the character right after the match in
    // `m__common__core__limit` is `_`, part of a longer identifier — so the
    // idt offset's `limit` bit came back false although `core__limit`
    // plainly reads it. `V(a,n)` probes one internal node and one port
    // (`plan/limit.zig` declines a probe of two ports outright).
    const Harness = @import("harness.zig").Harness;
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n; electrical p, n, a;
        \\  real s, vcrit, limited;
        \\  analog begin
        \\    s = 1e-3 * idt(1e9, 7.0, V(p, n));
        \\    vcrit = 0.025 * (1.0 + s);
        \\    limited = $limit(V(a,n), "pnjlim", 0.025, vcrit);
        \\    I(p,a) <+ V(p,a) / 100.0;
        \\    I(a, n) <+ s + limited * 1e-6;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, s, "core__limit") != null);
    try std.testing.expect(std.mem.find(
        u8,
        s,
        "    .{ .res = true, .jac = true, .q = true, .limit = true, .state = true, .w_update = true, .w_commit = false },\n};\n",
    ) != null);
}
