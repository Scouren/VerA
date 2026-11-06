//! The §4.5 analog operators' kernels: the current S-valued input and the
//! operator's accepted state in, its value (with its analytic derivative)
//! out, plus the accepted-step bookkeeping. `idt`, `idtmod`, `slew`,
//! `last_crossing`, `cross` and `transition` (the state is the caller's
//! `Instance` fields), §5.10.3.3 timer deadlines (also the mixed
//! coordinator's, so both count from `start` rather than accumulating
//! periods), and the §4.5.7 `absdelay` history: a fixed ring of accepted
//! (t, v) samples whose storage is the caller's, read, pushed, thinned and
//! reverted here.
//! Cites: VAMS §4.5.4, §4.5.5, §4.5.7, §4.5.8, §4.5.9, §4.5.10, §4.5.15,
//! §5.10.3.1, §5.10.3.3.
//!
//! Contents:
//! - `pub const z_inf: f64`
//! - `pub fn zNextTimer(start: f64, period: f64, t: f64) ?f64`
//! - `pub fn zTimerPending(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) f64`
//! - `pub fn zTimerDue(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) bool`
//! - `pub fn zAbsdelay(comptime S: type, vin: S, ts: []const f64, vs: []const f64, head: u64, now: f64, dt: f64, td: f64) S`
//! - `pub fn zHistAt(ts: []const f64, vs: []const f64, head: u64, t: f64) f64`
//! - `pub fn zHistThin(comptime site: []const u8, ts: []f64, vs: []f64, head: *u64, now: f64, w: f64) void`
//! - `pub fn zhKept(n: usize) usize`
//! - `pub fn zHistRevert(ts: []f64, vs: []f64, head: u64, post: u64, t0: f64, v0: f64, t1: f64, v1: f64) void`
//! - `pub fn zHistPush(ts: []f64, vs: []f64, head: *u64, t: f64, v: f64) void`
//! - `pub fn zIdt(comptime S: type, v: S, acc: f64, dt: f64, ic: f64) S`
//! - `pub fn zIdtHold(comptime S: type, v: S, off: f64, ic: f64, assert_: f64) S`
//! - `pub fn zIdtAcc(v: f64, acc: f64, dt: f64, ic: f64) f64`
//! - `pub fn zIdtmod(comptime S: type, v: S, acc: f64, dt: f64, ic: f64, m: f64, o: f64) S`
//! - `pub fn zWrap(x: f64, modulus: f64, offset: f64) f64`
//! - `pub fn zSlew(comptime S: type, v: S, prev: f64, dt: f64, rise: f64, fall: f64) S`
//! - `pub fn zLastCross(comptime S: type, v: S, prev: f64, t: f64, dt: f64, t_last: f64, crossed: bool) S`
//! - `pub fn zCrossDir(dir: f64, prev: f64, in: f64) bool`
//! - `pub fn zCrossRetry(v0: f64, v1: f64, t: f64, dt: f64, ttol: f64, etol: f64) ?f64`
//! - `pub fn zTransFrac(target: f64, from: f64, t0: f64, t: f64, rise: f64, fall: f64) f64`
//! - `pub fn zTransition(comptime S: type, v: S, from: f64, to: f64, t0: f64, t: f64, dt: f64, rise: f64, fall: f64) S`
//! - `pub fn zTransStep(in: f64, from: *f64, to: *f64, t0: *f64, t: f64, dt: f64, td: f64, rise: f64, fall: f64) void`

const std = @import("std");

/// +inf, named once so an emitted timer site does no comptime work for it.
pub const z_inf: f64 = std.math.inf(f64);

/// A GPU target (`zSpec`'s test): `zHistThin` drops its host-only warning.
const zh_device = switch (@import("builtin").target.cpu.arch) {
    .nvptx64, .amdgcn => true,
    else => false,
};

/// Returns the first representable event time strictly after `t` on the grid
/// `start + k*period`, k >= 0. A non-positive or non-finite period has only
/// its `start` event. Null when no such time exists: a non-finite `start` or
/// `t`, a spent one-shot, or a grid whose next event overflows to infinity.
pub fn zNextTimer(start: f64, period: f64, t: f64) ?f64 {
    if (!std.math.isFinite(start) or !std.math.isFinite(t)) return null;
    const next: ?f64 = if (start > t) start else ztmGrid(start, period, t);
    if (next) |n| std.debug.assert(n > t);
    if (next) |n| std.debug.assert(!std.math.isNan(n));
    return next;
}

/// Returns the deadline after a control change, evaluated before the event
/// condition (§5.10.3.3). Unchanged controls keep `pending`, so a host that
/// steps just past the scheduled event still observes it. Changed controls
/// schedule afresh: now itself when now is on the new grid, never a past
/// one-shot (+inf).
pub fn zTimerPending(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) f64 {
    if (start == old_start and period == old_period) return pending;
    const r: f64 = if (start >= t)
        start
    else if (!(period > 0))
        z_inf
    else
        zNextTimer(start, period, std.math.nextAfter(f64, t, -z_inf)) orelse z_inf;
    // A rescheduled deadline is never in the past (NaN compares false).
    std.debug.assert(!(r < t));
    return r;
}

/// Returns whether the timer fires at `t`. Enable gates delivery, never the
/// absolute schedule's progress, so this reads the deadline only.
pub fn zTimerDue(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) bool {
    return t >= zTimerPending(start, period, t, old_start, old_period, pending);
}

/// Returns the delayed value as the residual sees it, Output(t) = Input(t - td)
/// (§4.5.7). A static analysis (`dt <= 0`) and an empty ring pass `vin`
/// through, derivative and all ("no state history prior to time t == 0",
/// §4.5.15). A lookback past the newest sample interpolates between it and
/// `vin`, which keeps the output continuous and carries the f·∂vin
/// derivative the td -> 0 limit needs; inside the history the value is a
/// constant (derivative 0), the companion model of a transport delay.
/// Asserts that `ts` and `vs` are one non-empty ring.
pub fn zAbsdelay(comptime S: type, vin: S, ts: []const f64, vs: []const f64, head: u64, now: f64, dt: f64, td: f64) S {
    std.debug.assert(ts.len == vs.len);
    std.debug.assert(ts.len > 0);
    if (dt <= 0.0) return vin;
    if (head == 0) return vin;
    const t = now - td;
    const newest: usize = @intCast((head + ts.len - 1) % ts.len);
    if (t > ts[newest]) {
        const span = now - ts[newest];
        if (span <= 0.0) return vin;
        // The f <= 1 clamp covers a run-time negative td, which lowering
        // rejects where it can fold.
        const f = @min((t - ts[newest]) / span, 1.0);
        return vin.scale(f).addC(vs[newest] * (1.0 - f));
    }
    return S.con(zHistAt(ts, vs, head, t));
}

/// Returns the ring's linear interpolation at `t`. `head` is the total count
/// of accepted samples, not a wrapped index: slot `head % n`. A `t` at or
/// before the oldest held sample reads that sample, which is Input(0) before
/// history began (§4.5.15's max(t - td, 0)) and the window's edge once a full
/// ring has forgotten older samples. Between samples the bracket is the
/// newest interval holding `t`. O(log n).
/// Asserts that `ts` and `vs` are one non-empty ring.
pub fn zHistAt(ts: []const f64, vs: []const f64, head: u64, t: f64) f64 {
    std.debug.assert(ts.len == vs.len);
    std.debug.assert(ts.len > 0);
    const n = ts.len;
    const oldest: usize = if (head > n) @intCast(head % n) else 0;
    if (t <= ts[oldest]) return vs[oldest];
    // Callers handle t > newest (`zAbsdelay`), so t <= ts[newest] here.
    const count: usize = @intCast(@min(head, n));
    if (count < 2) return vs[oldest]; // only a NaN t gets here
    // Binary search in age order (c = 0 the oldest live sample): `lo` ends
    // at the newest sample at or before t.
    var lo: usize = 0;
    var hi: usize = count;
    var probes: u32 = 0;
    while (hi - lo > 1) : (probes += 1) {
        std.debug.assert(probes < 64);
        const mid = lo + (hi - lo) / 2;
        if (ts[zhSlot(oldest + mid, n)] <= t) lo = mid else hi = mid;
    }
    const c = @min(lo + 1, count - 1);
    std.debug.assert(c >= 1);
    const older = zhSlot(oldest + c - 1, n);
    const newer = zhSlot(oldest + c, n);
    const span = ts[newer] - ts[older];
    if (span <= 0.0) return vs[newer];
    const f = (t - ts[older]) / span;
    return vs[older] + (vs[newer] - vs[older]) * f;
}

/// Keeps a full ring's window `w` (maxdelay, or td) before `updateState`
/// pushes the sample at `now`. A plain ring overwrites its oldest sample;
/// that is safe once the sample after it is at or before `now - w`, and then
/// this does nothing. Otherwise the ring is thinned: the older half keeps
/// every other sample (the oldest first), the newer half stays whole, the
/// ring is relaid oldest-first and `head` becomes its count, so the next
/// n/4 pushes overwrite nothing a lookback reads. The dropped samples stay
/// past the live ones until a push overwrites them, which is what lets
/// `zHistRevert` undo a thinning push. W1051 prints once per `site` on a
/// host; a GPU kernel has no stderr, so it thins silently.
/// Asserts that `ts` and `vs` are one ring.
pub fn zHistThin(comptime site: []const u8, ts: []f64, vs: []f64, head: *u64, now: f64, w: f64) void {
    std.debug.assert(ts.len == vs.len);
    const n = ts.len;
    // Below 8 samples a thinned ring would keep n - 1 and a revert could not
    // tell its push from a plain one; every device ring holds at least 1024.
    if (head.* < n or n < 8) return;
    const o: usize = @intCast(head.* % n);
    if (!(ts[(o + 1) % n] > now - w)) return;
    zhThin(ts, vs, o);
    head.* = zhKept(n);
    std.debug.assert(head.* < n);
    if (comptime zh_device) return;
    const Once = struct {
        const name = site;
        var warned = false;
    };
    if (Once.warned) return;
    Once.warned = true;
    var gap: f64 = 0.0;
    for (1..@as(usize, @intCast(head.*))) |i| gap = @max(gap, ts[i] - ts[i - 1]);
    std.debug.print("warning[W1051]: absdelay `{s}`: its {d}-sample history filled inside its {e} s window; " ++
        "older samples are now {e} s apart; see `vera --explain W1051`\n", .{ site, n, w, gap });
}

/// Returns how many samples a thinned ring of `n` keeps: every other one of
/// the older half `n / 2` (the first included), and all of the newer half.
pub fn zhKept(n: usize) usize {
    const k = (n / 2 + 1) / 2 + (n - n / 2);
    std.debug.assert(k <= n);
    std.debug.assert(k >= n / 2);
    return k;
}

/// Undoes the push since the last commit (`stateCtl(.revert)`). `head` is the
/// committed count, `post` the count the push left. A plain push overwrote
/// slot `head % n`, whose sample the commit kept in (`t0`, `v0`). A thinning
/// push (`post < head`) overwrote the ring's first dropped sample, kept in
/// (`t1`, `v1`); it goes back and the thinning is undone.
/// Asserts that `ts` and `vs` are one non-empty ring.
pub fn zHistRevert(ts: []f64, vs: []f64, head: u64, post: u64, t0: f64, v0: f64, t1: f64, v1: f64) void {
    std.debug.assert(ts.len == vs.len);
    std.debug.assert(ts.len > 0);
    const n = ts.len;
    const at: usize = @intCast(head % n);
    if (post >= head) {
        ts[at] = t0;
        vs[at] = v0;
        return;
    }
    // Only a thinning push lowers the count, and only a full ring thins.
    std.debug.assert(head >= n);
    const k = zhKept(n);
    ts[k] = t1;
    vs[k] = v1;
    zhUnthin(ts, vs, at);
}

/// Records the accepted sample (`t`, `v`) in slot `head % n`, overwriting
/// the oldest once the ring is full, and counts it in `head`, which as a
/// u64 of accepted steps never wraps.
/// Asserts that `ts` and `vs` are one non-empty ring.
pub fn zHistPush(ts: []f64, vs: []f64, head: *u64, t: f64, v: f64) void {
    std.debug.assert(ts.len == vs.len);
    std.debug.assert(ts.len > 0);
    const at: usize = @intCast(head.* % ts.len);
    ts[at] = t;
    vs[at] = v;
    head.* += 1;
}

/// §4.5.4 `idt`: the accepted integral plus this step's rectangle. A static
/// analysis returns the initial condition, the DC value §4.5.4 gives it.
pub fn zIdt(comptime S: type, v: S, acc: f64, dt: f64, ic: f64) S {
    if (dt <= 0.0) return S.con(ic);
    return v.scale(dt).addC(acc);
}

/// §4.5.4 `idt` with an assert argument: "idt() returns the initial
/// conditions ... whenever assert is nonzero".
pub fn zIdtHold(comptime S: type, v: S, off: f64, ic: f64, assert_: f64) S {
    if (assert_ != 0.0) return S.con(ic);
    return v.addC(-off);
}

/// `zIdt` on the accepted solution, where no derivative is wanted.
pub fn zIdtAcc(v: f64, acc: f64, dt: f64, ic: f64) f64 {
    if (dt <= 0.0) return ic;
    return acc + v * dt;
}

/// §4.5.5 `idtmod`: `zIdt` wrapped into [o, o + m). The wrap subtracts a
/// piecewise-constant multiple of the modulus, so the wrapped integral's
/// derivative is the raw one's.
pub fn zIdtmod(comptime S: type, v: S, acc: f64, dt: f64, ic: f64, m: f64, o: f64) S {
    const raw = zIdt(S, v, acc, dt, ic);
    if (!(m > 0.0)) return raw;
    return raw.addC(-m * @floor((raw.val() - o) / m));
}

/// §4.5.5 the `idtmod` wrap of an accepted value.
pub fn zWrap(x: f64, modulus: f64, offset: f64) f64 {
    if (!(modulus > 0.0)) return x;
    return x - modulus * @floor((x - offset) / modulus);
}

/// §4.5.9 `slew`: the input, clamped to the rates `rise` and `fall` allow
/// from the previous accepted output. A static analysis passes it through.
pub fn zSlew(comptime S: type, v: S, prev: f64, dt: f64, rise: f64, fall: f64) S {
    if (dt <= 0.0) return v;
    return v.minC(prev + rise * dt).maxC(prev - fall * dt);
}

/// §4.5.10 `last_crossing` at the point being evaluated: where the input
/// `crossed` since the last accepted point, `Gen.lastCrossTime`'s
/// interpolation in the same operation order (so the latch reads the same
/// bits), whose zero moves with `v` and so carries `v`'s derivative;
/// otherwise the latched `t_last`, a constant.
pub fn zLastCross(comptime S: type, v: S, prev: f64, t: f64, dt: f64, t_last: f64, crossed: bool) S {
    if (!crossed) return S.con(t_last);
    return S.con(prev).div(S.con(prev).sub(v)).scale(dt).addC(t - dt);
}

/// §5.10.3.1/§4.5.10 the crossing test for a direction that is a parameter
/// (so codegen cannot pick the comparison at emit time): +1 rising only, -1
/// falling only, 0 either, any other value disables `cross()`. The exact
/// decode `Gen.crossTest` applies to a folded direction, so overriding the
/// parameter to its default's value changes nothing.
pub fn zCrossDir(dir: f64, prev: f64, in: f64) bool {
    if (dir == 1.0) return prev <= 0.0 and in > 0.0;
    if (dir == -1.0) return prev >= 0.0 and in < 0.0;
    if (dir != 0.0) return false;
    return (prev <= 0.0 and in > 0.0) or (prev >= 0.0 and in < 0.0);
}

/// §5.10.3.1 "the event shall occur after the threshold crossing, and while
/// the signal remains in the box defined by actual crossing and expr_tol and
/// time_tol": for a crossing found in the step ending at `t`, null when `t`
/// is inside that box, else a time inside it just past the crossing (the
/// zero of the line through (`t - dt`, `v0`) and (`t`, `v1`), as
/// `Gen.lastCrossTime` has it). A zero tolerance is the tool's (VD-066: the
/// grid), so it does not bound the box.
pub fn zCrossRetry(v0: f64, v1: f64, t: f64, dt: f64, ttol: f64, etol: f64) ?f64 {
    const tc = (t - dt) + v0 / (v0 - v1) * dt;
    const late = (ttol > 0.0 and t - tc > ttol) or (etol > 0.0 and @abs(v1) > etol);
    if (!late) return null;
    var d = if (ttol > 0.0) ttol else t - tc;
    if (etol > 0.0) d = @min(d, etol * dt / @abs(v1 - v0));
    return tc + d / 2.0;
}

/// §4.5.8 the fraction of the current excursion the ramp has traversed:
/// "transition() forces all positive transitions of expr to occur over
/// rise_time and all negative transitions to occur in fall_time", piecewise
/// linear, so (t - t0)/tt clamped into [0, 1] with tt picked by the
/// excursion's direction. A zero transition time is §4.5.8's degenerate
/// case, left to the simulator: an instantaneous edge, fraction 1.
pub fn zTransFrac(target: f64, from: f64, t0: f64, t: f64, rise: f64, fall: f64) f64 {
    const tt = if (target >= from) rise else fall;
    if (!(tt > 0.0)) return 1.0;
    const f = @min(@max((t - t0) / tt, 0.0), 1.0);
    std.debug.assert(f >= 0.0);
    std.debug.assert(f <= 1.0);
    return f;
}

/// §4.5.8 `transition`. A static analysis passes the input through ("In DC
/// analysis, transition() passes the value of the expr directly to its
/// output"). In a transient the output is a function of the input's past
/// alone: the excursion in flight was armed by the accepted step that saw
/// the input change, so it ramps from `from` to `to`, never to the current
/// input (which would arm every ramp one accepted step early).
pub fn zTransition(comptime S: type, v: S, from: f64, to: f64, t0: f64, t: f64, dt: f64, rise: f64, fall: f64) S {
    if (dt <= 0.0) return v;
    return S.con(from + (to - from) * zTransFrac(to, from, t0, t, rise, fall));
}

/// §4.5.8 accepted-step bookkeeping: "a transition is created when the input
/// expression changes, and at this point it uses the value of td,
/// rise_time, fall_time and time_tol to determine the new pending transition
/// operator". `to` is the armed destination and so the last accepted input,
/// which makes `in != to` that sentence's test. An unchanged input leaves the
/// excursion alone: re-arming the origin every step would shrink the
/// remaining distance by a constant factor, an exponential wearing a ramp's
/// coefficients. On return `to` holds `in`.
pub fn zTransStep(in: f64, from: *f64, to: *f64, t0: *f64, t: f64, dt: f64, td: f64, rise: f64, fall: f64) void {
    defer std.debug.assert(to.* == in or in != in);
    if (dt <= 0.0) { // the DC point: the output is the input
        from.* = in;
        to.* = in;
        t0.* = t;
        return;
    }
    if (in == to.*) return;
    // "td models transport delay": the ramp begins td after the change, from
    // where the old trajectory will be at t + td.
    const te = t + td;
    const f = zTransFrac(to.*, from.*, t0.*, te, rise, fall);
    const vi = from.* + (to.* - from.*) * f;
    // §4.5.8's four interruption paragraphs (Figures 4-7 to 4-12): a change
    // inside the active region is "not ... a new transition, but rather a
    // readjustment" whose slope uses "either the original transition's
    // origin or destination as the new origin". The reference is the
    // destination when the new direction opposes the original and the origin
    // when it agrees:
    //   rising,  v3 < vi -> opposes -> (v3-v2)/tf3    rising,  v3 > vi -> (v3-v1)/tr3
    //   falling, v3 > vi -> opposes -> (v3-v2)/tr3    falling, v3 < vi -> (v3-v1)/tf3
    // "applied from the point of interruption (ti,vi)", spelled as the
    // shifted origin (t4,v4): v4 the reference level, t4 where the slope line
    // through (te,vi) reaches it; zTransFrac then finds the arrival t3.
    // Outside the active region it is a new transition from where the
    // output is.
    if (f < 1.0 and in != vi) {
        const tt3 = if (in > vi) rise else fall;
        const vref = if ((in > vi) != (to.* > from.*)) to.* else from.*;
        const slope = if (tt3 > 0.0) (in - vref) / tt3 else 0.0;
        if (slope != 0.0) {
            from.* = vref;
            to.* = in;
            t0.* = te + (vref - vi) / slope;
            return;
        }
    }
    from.* = vi;
    to.* = in;
    t0.* = te;
}

// ---- private ----

/// The grid event after `t` once `start <= t`, both finite.
fn ztmGrid(start: f64, period: f64, t: f64) ?f64 {
    std.debug.assert(start <= t);
    std.debug.assert(std.math.isFinite(t));
    if (!(period > 0.0) or !std.math.isFinite(period)) return null;
    var n = @floor((t - start) / period) + 1.0;
    // Repair a division rounded to either side of a firing count.
    if (n > 1.0 and start + (n - 1.0) * period > t) n -= 1.0;
    if (start + n * period <= t) n += 1.0;
    const next = start + n * period;
    if (std.math.isFinite(next) and next > t) return next;
    // A tiny period can vanish in the addition or overflow the count; then
    // consecutive f64 times span an event, and the first time past `t` is
    // it. A finite count with an infinite event is finite-time exhaustion.
    if (next <= t or !std.math.isFinite(n)) {
        const future = std.math.nextAfter(f64, t, z_inf);
        if (std.math.isFinite(future)) return future;
    }
    return null;
}

/// Ring slot of age-order position `i` past the oldest, for `i < 2n`: a
/// subtraction, where `%` is a division per probe of `zHistAt`'s search.
fn zhSlot(i: usize, n: usize) usize {
    std.debug.assert(i < 2 * n);
    const s = i - n * @intFromBool(i >= n);
    std.debug.assert(s < n);
    return s;
}

/// The thinning permutation of a full ring whose oldest sample is at slot
/// `o`: oldest-first, then the older half's even samples, the newer half
/// and the older half's odd samples. In place, by rotations: a bottom-up
/// merge moves each block's odd samples past the next block's even ones.
fn zhThin(ts: []f64, vs: []f64, o: usize) void {
    const n = ts.len;
    std.debug.assert(n >= 8);
    std.debug.assert(o < n);
    const h = n / 2;
    zhRot(ts, vs, 0, n, o);
    var b: usize = 2;
    while (b < h) : (b *= 2) {
        var s: usize = 0;
        while (s + b < h) : (s += 2 * b) {
            const r = @min(b, h - s - b);
            zhRot(ts, vs, s + b / 2, b / 2 + (r + 1) / 2, b / 2);
        }
    }
    zhRot(ts, vs, (h + 1) / 2, n - (h + 1) / 2, h / 2);
}

/// `zhThin` undone: the same rotations, reversed, in reverse order.
fn zhUnthin(ts: []f64, vs: []f64, o: usize) void {
    const n = ts.len;
    std.debug.assert(n >= 8);
    std.debug.assert(o < n);
    const h = n / 2;
    const ce = (h + 1) / 2;
    zhRot(ts, vs, ce, n - ce, (n - ce) - h / 2);
    var b: usize = 2;
    while (b * 2 < h) b *= 2;
    while (b >= 2) : (b /= 2) {
        if (b >= h) continue;
        var s: usize = 0;
        while (s + b < h) : (s += 2 * b) {
            const r = @min(b, h - s - b);
            zhRot(ts, vs, s + b / 2, b / 2 + (r + 1) / 2, (r + 1) / 2);
        }
    }
    zhRot(ts, vs, 0, n, (n - o) % n);
}

/// Rotates `ts[a..][0..len]` and `vs` alike left by `by`.
fn zhRot(ts: []f64, vs: []f64, a: usize, len: usize, by: usize) void {
    std.debug.assert(a + len <= ts.len);
    std.debug.assert(by <= len);
    std.mem.rotate(f64, ts[a..][0..len], by);
    std.mem.rotate(f64, vs[a..][0..len], by);
}
