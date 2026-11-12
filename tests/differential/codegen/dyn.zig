//! diff-codegen's host: a bundle of devices in (`devices`, a tuple of the
//! library root's, named by `names`: `o<k>` the old pipeline's, `n<k>` the new one's), one C
//! entry per device out, `cg_<decl>`, that sets a card by name, runs
//! `derive`/`setup` as a host does, and evaluates `eval` and `q` at one
//! point with every lane carried: the residual rows, their dense Jacobian,
//! the reactive rows (`contract.qRows`) and theirs; then what a host reads
//! beside them: the breakpoints and step bound after the accept, the noise
//! PSDs and AC phasors per branch. Each device is also held to itself: a
//! rejected step's `stateCtl(.revert)` must give back the point's rows,
//! and every lane must be its row's central-difference slope, except a row
//! the bundle's `fd_skip` names (research/codegen.md T0d): one `u64` row
//! mask per device, computed off its fixture's `Air` (`sides.zig`'s
//! `fdSkipMask`) for a row that reaches an op VerA's Jacobian defines by
//! rule, never by the fixture's name. A device that calls a §12.32 systf
//! gets a fixed linear `SystfHost` (`stub_systf`).
//! Cites: VAMS-2023 §5.6, §5.6.1.2 (the rows and charges a host reads),
//! §4.6.3, §4.6.4, §9.17.2, §12.32.
//!
//! Contents:
//! - `pub const vera_validate_contract`
//! - `pub fn exportDevice(comptime B: type, comptime name: []const u8) void`

const std = @import("std");
const contract = @import("contract");
/// The family's transcendentals: Gompute's, the rewrite's (`RefOptions.math`).
const math = @import("std_kernels").math;

/// Every device of the bundle is held to `contract.validate` (link's shim
/// reads this from the dyn).
pub const vera_validate_contract = true;

/// The noise analysis' sample frequencies [Hz]: a flicker corner below,
/// near and above the usual 1 kHz.
const noise_freqs = [_]f64{ 1, 1e3, 1e6 };
/// A central difference's bound, relative to the larger slope: its
/// truncation error at `h` = cbrt(eps) is ~eps^(2/3)·f'''/f' (1e-5 for
/// exp(x/vt) at vt = 26 mV); a dropped or flipped term is order 1.
const fd_rel = 1e-3;
/// How many rounding errors of each row value the difference may carry.
const fd_round = 16;

/// §12.32 the host of every `systf_calls` entry: a fixed linear function,
/// value k + Σ j·args[j−1] and partial j on argument j, so both sides of a
/// fixture see one application and a finite difference can check the lanes.
var stub_ctx: u8 = 0;
const stub_systf: contract.SystfHost = .{ .ctx = &stub_ctx, .call = stubCall };

/// `link`'s hook: exports `Run(D, skip).run` as `cg_<decl>` for every device
/// `D` of bundle `B`'s `devices`, named by its `names`, with the matching
/// row-skip mask of `B.fd_skip` (research/codegen.md T0d; all zero, every
/// row checked, when `B` declares none). `name` is the library's, unused.
pub fn exportDevice(comptime B: type, comptime name: []const u8) void {
    _ = name;
    @export(&pinMath, .{ .name = "cg_pin_math" });
    const skips: [B.devices.len]u64 = if (@hasDecl(B, "fd_skip")) B.fd_skip else @splat(0);
    inline for (B.devices, B.names, skips) |D, n, skip| {
        @export(&Run(D, skip).run, .{ .name = "cg_" ++ n });
        @export(&Run(D, skip).unknowns, .{ .name = "cg_" ++ n ++ "_nu" });
        @export(&Run(D, skip).site, .{ .name = "cg_" ++ n ++ "_site" });
    }
}

// ---- private ----

/// Pins which libm both sides' libraries call. A shared library whose code
/// needs any compiler_rt helper (an `i128` division, a stack probe) links
/// compiler_rt's archive member, and with it compiler_rt's musl-ported
/// `cos`, `sincos` and `exp`, which then bind every math call in the
/// library; one that needs none binds glibc's libm. The two differ in the
/// last bit (cos.va at point 82: glibc correctly rounded, musl 1 ulp off),
/// so a batch's old library and new library computed different `cos`
/// values from the same source. This `__divti3` makes every library pull
/// compiler_rt, so both sides call one `cos`.
fn pinMath(a: *const i128, b: *const i128) callconv(.c) i128 {
    return @divTrunc(a.*, b.*);
}

fn stubCall(_: *anyopaque, k: usize, args: []const f64, partials: []f64) f64 {
    var v: f64 = @floatFromInt(k);
    for (args, partials, 1..) |a, *p, j| {
        p.* = @floatFromInt(j);
        v += p.* * a;
    }
    return v;
}

/// The entry of device `D`; `fd_skip`'s bit `r` (research/codegen.md T0d)
/// skips `checkJacobian`'s check of row `r` entirely: a central difference
/// is no oracle for a row that reaches `ddx`, `vera_nodiff`, an
/// `integer`<->`real` cast, `$realtobits`/`$bitstoreal` or `%`/`fmod`,
/// whose Jacobian VerA defines by rule rather than as that limit. Every
/// other row is still checked, so a planted fault on a smooth row still
/// goes red.
fn Run(comptime D: type, comptime fd_skip: u64) type {
    return struct {
        const n = contract.nU(D);
        const S = contract.RefFamily(f64, &std.simd.iota(u8, n), .{ .math = math });
        const V = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{ .math = math });
        /// The rows, their Jacobian, the reactive rows and theirs.
        const len = 2 * n + 2 * n * n;
        /// The reals past `len`: 3 breakpoint values, the noise PSD per
        /// (row, col) at each of `noise_freqs`, and the AC stimuli's real
        /// and imaginary parts per (row, col).
        const extras = 3 + (noise_freqs.len + 2) * n * n;
        /// `eval` writes `Instance` (§9.7.3 status, table samples), so a
        /// second evaluation at one point is not the first's twin.
        const mutable = @hasDecl(D, "mutable_eval") and D.mutable_eval;
        /// `slopes`' answer: per row, a central difference and its rounding.
        const Slopes = struct { fd: [2 * n]f64, round: [2 * n]f64 };

        /// |U|.
        fn unknowns() callconv(.c) u32 {
            return n;
        }

        /// §9.4 `say_sites[i]`'s format and its length in `fmt_len`, or
        /// null past the last site.
        fn site(i: u32, fmt_len: *usize) callconv(.c) ?[*]const u8 {
            const sites: []const contract.SaySite = if (@hasDecl(D, "say_sites")) &D.say_sites else &.{};
            if (i >= sites.len) return null;
            fmt_len.* = sites[i].fmt.len;
            return sites[i].fmt.ptr;
        }

        /// The instance and state a transient carries from one step to the next.
        var inst: D.Instance = .{};
        var state: if (@hasDecl(D, "State")) D.State else void = undefined;
        /// Whether this process ran a step: the oracle's child that
        /// resumes past a point where every side stopped starts there.
        var started = false;

        /// Step `step` of a transient: sets the card (`names[k]` =
        /// `vals[k]`), evaluates at `x` and time `t`, writes `len + extras`
        /// reals to `out` (`rowsAt`'s, then the breakpoints after the
        /// accept and `smallSignal`'s), then accepts the point
        /// (`updateState`, `stateCtl .commit`), as a host does. Step 0
        /// starts a fresh instance (`initState`) in `analog initial`
        /// (§5.2.1), and so does a process's first step; a fresh instance
        /// gets `stub_systf` as its §12.32 host. Returns 0; -1 when `n_x` is
        /// not |U|, -2 when `out` is short, -3 when a name is no field of
        /// `Model`, -4 when the display records pass `say_cap`, -5 when a
        /// rejected step moved the rows (`checkRevert`) and -6 when a lane
        /// is not its row's slope (`checkJacobian`), the why in `out[0..5]`.
        /// `say_buf[0..say_len]` holds the point's §9.4 records (`D.say`).
        fn run(names: [*]const [*:0]const u8, vals: [*]const f64, n_params: u32, x: [*]const f64, n_x: u32, t: f64, step: u32, out: [*]f64, out_len: u32, say_buf: [*]f64, say_cap: u32, say_len: *u32) callconv(.c) i32 {
            if (n_x != n) return -1;
            if (out_len < len + extras) return -2;
            var m: D.Model = .{};
            // A host names every card entry it writes (§9.19, `setGiven`).
            for (names[0..n_params], vals[0..n_params]) |nm, v| {
                if (!set(&m, std.mem.span(nm), v)) return -3;
                if (@hasDecl(D.Model, "setGiven")) D.Model.setGiven(&m, std.mem.span(nm));
            }
            if (@hasDecl(D, "derive")) D.derive(V, &m);
            if (@hasDecl(D, "setup")) D.setup(V, &m);
            if (step == 0 or !started) {
                started = true;
                inst = .{};
                if (@hasField(D.Instance, "systf")) inst.systf = &stub_systf;
                if (@hasDecl(D, "initState")) state = D.initState(&m, &inst);
            }
            if (@hasDecl(D, "setupInstance")) D.setupInstance(&m, &inst);
            const sim: contract.SimState = .{ .t = t, .dt = 1e-9, .kind = .tran, .analog_initial = step == 0, .initial_step = step == 0, .iteration = 2 };
            const xv: [n]f64 = x[0..n].*;
            const r = rowsAt(&xv, &m, &inst, sim);
            out[0..len].* = r;
            if (!mutable) {
                // Every 7th point is first rejected, as a host's retry.
                if (step % 7 == 6 and !checkRevert(&r, &xv, &m, sim, out)) return -5;
                if (!checkJacobian(&r, &xv, &m, sim, out)) return -6;
            }
            const e = out[len..][0..extras];
            smallSignal(e[3..], &xv, &m, sim);
            // §9.4.6 the display records at the accepted point, before
            // its state moves (as the runner's `sayPoint`).
            say_len.* = 0;
            if (@hasDecl(D, "say")) {
                var s: contract.Say = .{ .buf = say_buf[0..say_cap] };
                D.say(S, &xv, &m, &inst, sim, &s);
                if (s.lost != 0) return -4;
                say_len.* = @intCast(s.len);
            }
            if (@hasDecl(D, "updateState")) {
                _ = D.updateState(V, &m, &inst, xv, &state, sim);
                if (@hasDecl(D, "stateCtl")) _ = D.stateCtl(&m, &inst, &state, .commit);
            }
            // §9.17.2 what a host reads after the accepted step: the next
            // breakpoints and the step bound, +inf for none.
            const inf = std.math.inf(f64);
            e[0] = if (@hasDecl(D, "nextBreakpoint")) D.nextBreakpoint(&m, t) orelse inf else inf;
            e[1] = if (@hasDecl(D, "pendingBreakpoint")) D.pendingBreakpoint(&inst, t) orelse inf else inf;
            e[2] = if (@hasField(D.Instance, "bound_step")) inst.bound_step else inf;
            return 0;
        }

        /// `len` reals at `xv`: the rows, their Jacobian row-major with
        /// `jac_const` added (a host adds the constant partials of the
        /// columns outside `deriv_reads`), the reactive rows and theirs.
        fn rowsAt(xv: *const [n]f64, m: *const D.Model, in: *D.Instance, sim: contract.SimState) [len]f64 {
            var o: [len]f64 = undefined;
            const r = D.eval(S, xv, m, in, sim);
            inline for (0..n) |i| {
                o[i] = r[i].val();
                o[n + i * n ..][0..n].* = contract.denseRow(n, r[i]);
            }
            const qo = o[n + n * n ..];
            if (@hasDecl(D, "q") and contract.nQ(D) != 0) {
                const qr = contract.qRows(D, S, D.q(S, xv, m, in, sim));
                inline for (0..n) |i| {
                    qo[i] = qr[i].val();
                    qo[n + i * n ..][0..n].* = contract.denseRow(n, qr[i]);
                }
            } else @memset(qo[0 .. n + n * n], 0);
            inline for (comptime contract.jacConst(D)) |c| if (contract.jacConstApplies(D, c, m, false)) {
                const at = @as(usize, @backingInt(c.row)) * n + @backingInt(c.col);
                o[n + at] += c.g;
                qo[n + at] += c.c;
            };
            return o;
        }

        /// Whether a rejected step leaves the point's rows as they were:
        /// `updateState` on a copy, `stateCtl(.revert)`, then `rowsAt`
        /// again must give `r` bit for bit (the contract's revert:
        /// "working := accepted, for every field `updateState` advances").
        /// On a miss `out[0..3]` is the value's index and the two values.
        fn checkRevert(r: *const [len]f64, xv: *const [n]f64, m: *const D.Model, sim: contract.SimState, out: [*]f64) bool {
            if (!@hasDecl(D, "updateState") or !@hasDecl(D, "stateCtl")) return true;
            var c = inst;
            var s = state;
            _ = D.updateState(V, m, &c, xv.*, &s, sim);
            _ = D.stateCtl(m, &c, &s, .revert);
            const b = rowsAt(xv, m, &c, sim);
            for (r, &b, 0..) |va, vb, i| {
                if (@as(u64, @bitCast(va)) == @as(u64, @bitCast(vb)) or (va != va and vb != vb)) continue;
                out[0..3].* = .{ @floatFromInt(i), va, vb };
                return false;
            }
            return true;
        }

        /// Whether every derivative lane is its row's slope, by a central
        /// difference (spice-engine §5) at `h` = cbrt(eps)·max(1, |x_j|)
        /// and again at h/2, extrapolated (Richardson): within `fd_rel` of the largest of the two and
        /// of the row's lanes, plus `fd_round` rounding errors of the rows
        /// the difference subtracts. Where the two differences disagree
        /// with each other the row is not smooth at this scale (a jump, a
        /// pole): no slope to check. A non-finite value passes too, and so
        /// does a row `fd_skip` names (research/codegen.md T0d): a central
        /// difference is no oracle for a row whose declared Jacobian is a
        /// VerA rule, not that limit. On a miss `out[0..5]` is the row
        /// (from `n` on, reactive row k − n), the column, the lane, the
        /// difference and `h`.
        fn checkJacobian(r: *const [len]f64, xv: *const [n]f64, m: *const D.Model, sim: contract.SimState, out: [*]f64) bool {
            for (0..n) |j| {
                const h = std.math.cbrt(std.math.floatEps(f64)) * @max(1.0, @abs(xv[j]));
                const a = slopes(xv, m, sim, j, h);
                const b = slopes(xv, m, sim, j, h / 2);
                for (0..2 * n) |k| {
                    if ((fd_skip >> @intCast(k % n)) & 1 != 0) continue;
                    // Row k's lanes: resistive, then reactive.
                    const lanes = if (k < n) r[n + k * n ..][0..n] else r[2 * n + n * n + (k - n) * n ..][0..n];
                    const d = lanes[j];
                    // Richardson: the h² truncation term cancels.
                    const fd = (4 * b.fd[k] - a.fd[k]) / 3;
                    if (!std.math.isFinite(fd) or !std.math.isFinite(d)) continue;
                    var big = @max(@abs(d), @abs(fd));
                    for (lanes) |l| big = @max(big, @abs(l));
                    const tol = fd_rel * big + 2 * @max(a.round[k], b.round[k]);
                    if (@abs(a.fd[k] - b.fd[k]) > tol) continue;
                    if (@abs(fd - d) <= tol) continue;
                    out[0..5].* = .{ @floatFromInt(k), @floatFromInt(j), d, fd, h };
                    return false;
                }
            }
            return true;
        }

        /// Per row (resistive, then reactive), the central difference of
        /// its value along unknown `j` at step `h`, and the rounding it may
        /// carry (`fd_round` ulps of each value it subtracts, over 2h).
        fn slopes(xv: *const [n]f64, m: *const D.Model, sim: contract.SimState, j: usize, h: f64) Slopes {
            var xp = xv.*;
            var xm = xv.*;
            xp[j] += h;
            xm[j] -= h;
            const rp = rowsAt(&xp, m, &inst, sim);
            const rm = rowsAt(&xm, m, &inst, sim);
            var o: Slopes = undefined;
            for (0..2 * n) |k| {
                const v = if (k < n) k else n + n * n + (k - n);
                o.fd[k] = (rp[v] - rm[v]) / (2 * h);
                o.round[k] = fd_round * std.math.floatEps(f64) * (@abs(rp[v]) + @abs(rm[v])) / h;
            }
            return o;
        }

        /// §4.6.3/§4.6.4 what a small-signal host reads at the point,
        /// binned by branch (row, col): the noise PSD at each of
        /// `noise_freqs` (coeff²·(white + flicker/f^ef), or the table at
        /// f), then the AC stimuli's real and imaginary parts.
        // ponytail: correlation (`corr_with`, shared `source`) is not
        // compared; add it with the first fixture whose generators correlate.
        fn smallSignal(e: []f64, xv: *const [n]f64, m: *const D.Model, sim: contract.SimState) void {
            @memset(e, 0);
            if (@hasDecl(D, "noisePsd")) {
                var sn = sim;
                sn.kind = .noise;
                const psd = D.noisePsd(V, xv.*, m, &inst, sn);
                for (D.noise_gens, psd) |g, p| for (noise_freqs, 0..) |f, fi| {
                    // `noise_tables` is `[_]contract.NoiseTable{...}`: a
                    // device with no table-kind generator emits it at
                    // length 0, and `D.noise_tables[k]` (`noiseTable`'s
                    // own body) is a compile error on a `[0]T` regardless
                    // of `g.table`'s runtime value, so the length (not
                    // just the decl) must be comptime-false first.
                    const table: ?f64 = if (comptime @hasDecl(D, "noise_tables") and D.noise_tables.len != 0) if (g.table) |k| contract.noiseTableAt(contract.noiseTable(D, m, k), f) else null else null;
                    const shape = table orelse p.white + p.flicker / std.math.pow(f64, f, p.ef);
                    e[(fi * n + g.row) * n + g.col] += p.coeff * p.coeff * shape;
                };
            }
            if (@hasDecl(D, "acStim")) {
                var sa = sim;
                sa.kind = .ac;
                const ac = e[noise_freqs.len * n * n ..];
                for (D.ac_gens, D.acStim(V, xv.*, m, &inst, sa)) |g, p| {
                    ac[@as(usize, g.row) * n + g.col] += p.mag * @cos(p.phase);
                    ac[n * n + @as(usize, g.row) * n + g.col] += p.mag * @sin(p.phase);
                }
            }
        }

        /// Writes `v` to `Model` field `name` when it is a number.
        fn set(m: *D.Model, name: []const u8, v: f64) bool {
            @setEvalBranchQuota(100_000);
            const info = @typeInfo(D.Model).@"struct";
            inline for (info.field_names, info.field_types) |f, T| {
                if (std.mem.eql(u8, f, name)) {
                    switch (@typeInfo(T)) {
                        .float => @field(m, f) = @floatCast(v),
                        .int => @field(m, f) = std.math.lossyCast(T, v),
                        else => return false, // else: a field the oracle does not draw (a string, a table)
                    }
                    return true;
                }
            }
            return false;
        }
    };
}
