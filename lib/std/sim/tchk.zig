//! IEEE 1364-2005 §15 timing checks at run time: a change of a slot a check
//! watches (`State.store` -> `changed`) in, the check judged at its
//! timecheck event out: §15.2's stability windows, §15.3.1-§15.3.3's skews
//! (or, timer-based, when the limit elapses: `expired`), §15.3.4's pulse
//! width, §15.3.5's period, §15.3.6's level window. A violation warns,
//! toggles the notifier (Table 15-13) and counts in `State.violations`.
//! The rows (`Program.Check`) are elaboration's; their run state is
//! `State.checks`.
//!
//! When a check is judged (docs/specification/Vague_Decisions.md VD-104): at
//! the event, in the order the step's events arrive; a reference and a data
//! event at one time are one pair, judged once whichever comes first.
//! Cites: IEEE 1364-2005 §15.1-§15.7, Tables 15-1 to 15-13.
//!
//! Contents:
//! - `pub const Stamp = struct`, `pub const Run = struct`
//! - `pub fn changed(s: *State, slot: u32, before: Bit, after: Bit) Error!void`
//! - `pub fn delivered(s: *State, code: u32, bit: u8) Error!void`
//! - `pub fn expired(s: *State, i: u32, gen: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Program = @import("Program.zig");
const State = @import("State.zig");
const eval = @import("eval.zig");
const logic = @import("logic.zig");
const Error = State.Error;
const Bit = logic.Bit;
const Check = Program.Check;

/// The times of one event's occurrences a check still reads.
pub const Stamp = struct {
    /// The latest occurrence.
    last: ?u64 = null,
    /// The latest occurrence at a time before `last`'s.
    before: ?u64 = null,
    /// An occurrence at `last` already reported a violation.
    reported: bool = false,

    fn note(st: *Stamp, now: u64) void {
        if (st.last) |l| assert(l <= now);
        if (!st.at(now)) {
            st.before = st.last;
            st.reported = false;
        }
        st.last = now;
    }

    fn at(st: Stamp, now: u64) bool {
        return if (st.last) |l| l == now else false;
    }

    fn earlier(st: Stamp, now: u64) ?u64 {
        return if (st.at(now)) st.before else st.last;
    }
};

/// One check's run state: its occurrences, a skew window's state and
/// timer generation, and its select events' bits when last seen.
pub const Run = struct {
    at: [2]Stamp = .{ .{}, .{} },
    active: bool = false,
    /// 0 the reference event, 1 the data event (`$fullskew` only).
    first: u1 = 0,
    gen: u32 = 0,
    v: [2]u64 = .{ 0, 0 },
    x: [2]u64 = .{ 0, 0 },
    /// The violations this check reported.
    count: u32 = 0,
    /// Its limits now: elaboration's, until §16 annotation changes them.
    lim: [2]u64 = .{ 0, 0 },
};

/// `State.store` changed `slot`, whose least significant bit went from
/// `before` to `after`: every check watching it judges the change.
pub fn changed(s: *State, slot: u32, before: Bit, after: Bit) Error!void {
    const p = s.p;
    if (slot + 1 >= p.check_start.len) return;
    for (p.check_codes[p.check_start[slot]..p.check_start[slot + 1]]) |code| {
        const i = code / 2;
        const k: usize = code % 2;
        const bit = transitionOf(s, i, k, before, after) orelse continue;
        // §15.5.1 a delayed signal: the check sees the change later.
        const delay = p.checks[i].delay[k];
        if (delay != 0) {
            _ = try s.enqueue(.{ .tchk_event = .{ .code = code, .bit = bit } }, delay, false);
            continue;
        }
        try judge(s, i, k, bit);
    }
}

/// §15.5.3: a delayed change reaches its check now.
pub fn delivered(s: *State, code: u32, bit: u8) Error!void {
    try judge(s, code / 2, code % 2, bit);
}

/// §15.3.2 a timer-based skew check's limit elapsed (unless a later window
/// or a data event retired generation `gen`), or §15.3.6's deferred data
/// event of a $nochange.
pub fn expired(s: *State, i: u32, gen: u32) Error!void {
    const c = current(s, i);
    const st = &s.checks[i];
    if (c.kind == .nochange) return noChange(s, i, s.scheduler.now);
    if (!st.active or st.gen != gen) return;
    sleep(st);
    try violation(s, i, st.at[0].last.?, s.scheduler.now);
}

// ---- private ----

/// Check `i` with its limits as they stand now.
fn current(s: *const State, i: u32) Check {
    var c = s.p.checks[i];
    c.lim = s.checks[i].lim;
    return c;
}

/// Transition bits 0..5 (01, 0x, 10, 1x, x0, x1), z read as x; 0 for none.
fn transition(from: Bit, to: Bit) u8 {
    const f: Bit = if (from == .z) .x else from;
    const t: Bit = if (to == .z) .x else to;
    if (f == t) return 0;
    return switch (f) {
        .zero => if (t == .one) 1 << 0 else 1 << 1,
        .one => if (t == .zero) 1 << 2 else 1 << 3,
        .x, .z => if (t == .zero) 1 << 4 else 1 << 5,
    };
}

/// The transitions `mask` names, each turned around (01 <-> 10, ...).
fn opposite(mask: u8) u8 {
    const swap = [6]u3{ 2, 4, 0, 5, 1, 3 };
    var out: u8 = 0;
    for (swap, 0..) |to, from| {
        if (mask & (@as(u8, 1) << @intCast(from)) != 0) out |= @as(u8, 1) << to;
    }
    return out;
}

/// The transition a change of the slot made of event `k`'s bits, read on
/// their least significant bit; null when it left them alone (§15.7).
fn transitionOf(s: *State, i: u32, k: usize, before: Bit, after: Bit) ?u8 {
    const ev = s.p.checks[i].ev[k];
    if (ev.width == 0) return transition(before, after);
    const st = &s.checks[i];
    const now = s.termBits(ev.slot, ev.lo, ev.width);
    if (now[0] == st.v[k] and now[1] == st.x[k]) return null;
    const b = logic.planeBit(st.v[k], st.x[k]);
    st.v[k] = now[0];
    st.x[k] = now[1];
    return transition(b, logic.planeBit(now[0], now[1]));
}

fn matches(mask: u8, bit: u8) bool {
    return mask == 0 or (mask & bit) != 0;
}

/// §15.6: whether condition `c` lets its event be detected now: a
/// deterministic comparison is not enabled by x, a nondeterministic one is.
fn enabled(s: *State, c: Program.Cond) Error!bool {
    if (c.op == .none) return true;
    var tmp: std.heap.ArenaAllocator = .init(s.arena);
    defer tmp.deinit();
    const v = (try eval.eval(s, tmp.allocator(), c.signal)).bit(0);
    const known = v == .zero or v == .one;
    return switch (c.op) {
        .none => unreachable, // returned above
        .plain => v == .one,
        .invert => v == .zero,
        .case_eq => known and v == c.want,
        .case_neq => known and v != c.want,
        .eq => !known or v == c.want,
        .neq => !known or v != c.want,
    };
}

/// Check `i`'s event `k` occurred if its edges name `bit` and its
/// condition holds: judge the check.
fn judge(s: *State, i: u32, k: usize, bit: u8) Error!void {
    const c = current(s, i);
    const st = &s.checks[i];
    const now = s.scheduler.now;
    switch (c.kind) {
        // §15.3.4 "threshold < timecheck - timestamp < limit".
        .width => {
            if (matches(c.ev[1].mask, bit) and try enabled(s, c.ev[1].cond)) if (st.at[0].last) |ts| {
                st.at[0].last = null;
                const w = now - ts;
                if (c.lim[1] < w and w < c.lim[0]) try violation(s, i, ts, now);
            };
            if (matches(c.ev[0].mask, bit) and try enabled(s, c.ev[0].cond)) st.at[0].last = now;
        },
        // §15.3.5 "timecheck - timestamp < limit".
        .period => {
            if (!matches(c.ev[0].mask, bit) or !try enabled(s, c.ev[0].cond)) return;
            if (st.at[0].last) |ts| if (now - ts < c.lim[0]) try violation(s, i, ts, now);
            st.at[0].last = now;
        },
        .setup, .hold, .setuphold, .removal, .recovery, .recrem => {
            if (!matches(c.ev[k].mask, bit) or !try enabled(s, c.ev[k].cond)) return;
            if (k == 0) try reference(s, i, now) else try data(s, i, now);
        },
        .skew, .timeskew, .fullskew => {
            if (!matches(c.ev[k].mask, bit)) return;
            // §15.3.2: a reference event with its condition false sleeps.
            if (!try enabled(s, c.ev[k].cond)) {
                if (k == st.first) sleep(st);
                return;
            }
            try skew(s, i, k, now);
        },
        .nochange => if (k == 0) {
            if (matches(opposite(c.ev[0].mask), bit) and st.at[0].last != null and st.at[0].before == null) st.at[0].before = now;
            if (!matches(c.ev[0].mask, bit) or !try enabled(s, c.ev[0].cond)) return;
            st.at[0] = .{ .last = now };
            if (st.at[1].last) |d| try noChange(s, i, d);
        } else {
            if (!matches(c.ev[1].mask, bit) or !try enabled(s, c.ev[1].cond)) return;
            st.at[1].note(now);
            // A zero end offset: judge after the active events (VD-104).
            if (c.lim[1] == 0 and st.at[0].last != null and st.at[0].before == null)
                _ = try s.enqueue(.{ .tchk_expiry = .{ .check = i, .gen = st.gen } }, 0, false)
            else
                try noChange(s, i, now);
        },
    }
}

/// A reference event at `now`: the window before it (setup, removal) with
/// the latest earlier data event, and a simultaneous pair whose data event
/// came first.
fn reference(s: *State, i: u32, now: u64) Error!void {
    const c = current(s, i);
    const st = &s.checks[i];
    if (try enabled(s, c.stamp_cond)) st.at[0].note(now);
    if (!try enabled(s, c.check_cond)) return;
    if (c.lim[0] > 0) if (st.at[1].earlier(now)) |d| if (d +| c.lim[0] > now) try violation(s, i, d, now);
    if (simultaneous(c) and st.at[1].at(now) and !st.at[1].reported) {
        st.at[1].reported = true;
        try violation(s, i, now, now);
    }
}

/// A data event at `now`: the window after the latest reference event.
fn data(s: *State, i: u32, now: u64) Error!void {
    const c = current(s, i);
    const st = &s.checks[i];
    if (try enabled(s, c.stamp_cond)) st.at[1].note(now);
    if (!try enabled(s, c.check_cond)) return;
    const ts = st.at[0].last orelse return;
    const hit = if (ts == now) simultaneous(c) else now < ts +| c.lim[1];
    if (hit and !st.at[1].reported) {
        st.at[1].reported = true;
        try violation(s, i, ts, now);
    }
}

/// Whether a reference and a data event at one time violate.
fn simultaneous(c: Check) bool {
    return switch (c.kind) {
        .setup, .removal => false,
        .hold, .recovery, .setuphold, .recrem => c.lim[0] > 0 or c.lim[1] > 0,
        .width, .period, .skew, .timeskew, .fullskew, .nochange => unreachable, // judged by `judge` itself
    };
}

/// §15.3.1-§15.3.3 event `k` of skew check `i` at `now`: a timestamp
/// event opens a window, a timecheck event violates past the limit.
fn skew(s: *State, i: u32, k: usize, now: u64) Error!void {
    const c = current(s, i);
    const st = &s.checks[i];
    if (st.active and k != st.first) {
        const ts = st.at[0].last.?;
        if (now - ts > c.lim[st.first]) {
            if (!c.remain_active) sleep(st);
            try violation(s, i, ts, now);
        } else if (!c.event_based) sleep(st);
        return;
    }
    if (k == 1 and c.kind != .fullskew) return;
    sleep(st);
    st.active = true;
    st.first = @intCast(k);
    st.at[0].last = now;
    if (!c.event_based) _ = try s.enqueue(.{ .tchk_expiry = .{ .check = i, .gen = st.gen } }, c.lim[k], false);
}

fn sleep(st: *Run) void {
    st.active = false;
    st.gen +%= 1;
}

/// §15.3.6 data event at `d` against $nochange `i`'s latest level.
fn noChange(s: *State, i: u32, d: u64) Error!void {
    const c = current(s, i);
    const st = &s.checks[i];
    const lead = st.at[0].last orelse return;
    const start: i64 = @bitCast(c.lim[0]);
    const after = @as(i64, @intCast(lead)) - start < @as(i64, @intCast(d));
    const before = if (st.at[0].before) |trail| d < trail + c.lim[1] else true;
    if (after and before and !st.at[1].reported) {
        st.at[1].reported = true;
        try violation(s, i, lead, d);
    }
}

/// Check `i` violated between `stamp` and `check`: counted, warned, and its
/// notifier toggled (Table 15-13: 0 -> 1, 1 -> 0, z stays, x -> 1).
fn violation(s: *State, i: u32, stamp: u64, check: u64) Error!void {
    const c = current(s, i);
    s.violations += 1;
    s.checks[i].count +|= 1;
    try s.warn("timing check {d} violated: timestamp event at {d}, timecheck event at {d}", .{ i, stamp, check });
    const at = c.notifier;
    if (at == std.math.maxInt(u32)) return;
    var tmp: std.heap.ArenaAllocator = .init(s.arena);
    defer tmp.deinit();
    const cur = try eval.read(s, tmp.allocator(), at);
    const n = cur.values().len;
    for (0..n) |w| {
        const v = cur.values()[w];
        const u = cur.unknowns()[w];
        cur.values()[w] = (v ^ ~u) & logic.wordMask(cur.width, w);
        cur.unknowns()[w] = u & ~v;
    }
    try s.store(at, cur);
}
