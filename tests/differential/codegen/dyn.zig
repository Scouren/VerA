//! diff-codegen's host: a bundle of devices in (`devices`, a tuple of the
//! library root's, named by `names`: `o<k>` the old pipeline's, `n<k>` the new one's), one C
//! entry per device out, `cg_<decl>`, that sets a card by name, runs
//! `derive`/`setup` as a host does, and evaluates `eval` and `q` at one
//! point with every lane carried: the residual rows, their dense Jacobian,
//! the reactive rows (`contract.qRows`) and theirs.
//! Cites: VAMS-2023 §5.6, §5.6.1.2 (the rows and charges a host reads).
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

/// `link`'s hook: exports `Run(D).run` as `cg_<decl>` for every device `D`
/// of bundle `B`'s `devices`, named by its `names`. `name` is the library's, unused.
pub fn exportDevice(comptime B: type, comptime name: []const u8) void {
    _ = name;
    @export(&pinMath, .{ .name = "cg_pin_math" });
    inline for (B.devices, B.names) |D, n| {
        @export(&Run(D).run, .{ .name = "cg_" ++ n });
        @export(&Run(D).unknowns, .{ .name = "cg_" ++ n ++ "_nu" });
        @export(&Run(D).site, .{ .name = "cg_" ++ n ++ "_site" });
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

/// The entry of device `D`.
fn Run(comptime D: type) type {
    return struct {
        const n = contract.nU(D);
        const S = contract.RefFamily(f64, &std.simd.iota(u8, n), .{ .math = math });
        const V = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{ .math = math });

        /// |U|.
        fn unknowns() callconv(.c) u32 {
            return n;
        }

        /// §9.4 `say_sites[i]`'s format and its length in `len`, or null
        /// past the last site.
        fn site(i: u32, len: *usize) callconv(.c) ?[*]const u8 {
            const sites: []const contract.SaySite = if (@hasDecl(D, "say_sites")) &D.say_sites else &.{};
            if (i >= sites.len) return null;
            len.* = sites[i].fmt.len;
            return sites[i].fmt.ptr;
        }

        /// The instance and state a transient carries from one step to the next.
        var inst: D.Instance = .{};
        var state: if (@hasDecl(D, "State")) D.State else void = undefined;
        /// Whether this process ran a step: the oracle's child that
        /// resumes past a point where every side stopped starts there.
        var started = false;

        /// Step `step` of a transient: sets the card (`names[k]` =
        /// `vals[k]`), evaluates at `x` and time `t`, writes `2n + 2n²`
        /// reals to `out` (the rows, their Jacobian row-major, the reactive
        /// rows, theirs), then accepts the point (`updateState`, `stateCtl
        /// .commit`), as a host does. Step 0 starts a fresh instance
        /// (`initState`) in `analog initial` (§5.2.1), and so does a
        /// process's first step. Returns 0; -1 when
        /// `n_x` is not |U|, -2 when `out` is short, -3 when a name is no
        /// field of `Model`, -4 when the display records pass `say_cap`.
        /// `say_buf[0..say_len]` holds the point's §9.4 records (`D.say`).
        fn run(names: [*]const [*:0]const u8, vals: [*]const f64, n_params: u32, x: [*]const f64, n_x: u32, t: f64, step: u32, out: [*]f64, out_len: u32, say_buf: [*]f64, say_cap: u32, say_len: *u32) callconv(.c) i32 {
            if (n_x != n) return -1;
            if (out_len < 2 * n + 2 * n * n) return -2;
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
                if (@hasDecl(D, "initState")) state = D.initState(&m, &inst);
            }
            if (@hasDecl(D, "setupInstance")) D.setupInstance(&m, &inst);
            const sim: contract.SimState = .{ .t = t, .dt = 1e-9, .kind = .tran, .analog_initial = step == 0, .initial_step = step == 0, .iteration = 2 };
            const xv: [n]f64 = x[0..n].*;
            const r = D.eval(S, &xv, &m, &inst, sim);
            inline for (0..n) |i| {
                out[i] = r[i].val();
                const row = contract.denseRow(n, r[i]);
                @memcpy(out[n + i * n ..][0..n], &row);
            }
            const qo = out[n + n * n ..];
            if (@hasDecl(D, "q") and contract.nQ(D) != 0) {
                const qr = contract.qRows(D, S, D.q(S, &xv, &m, &inst, sim));
                inline for (0..n) |i| {
                    qo[i] = qr[i].val();
                    const row = contract.denseRow(n, qr[i]);
                    @memcpy(qo[n + i * n ..][0..n], &row);
                }
            } else @memset(qo[0 .. n + n * n], 0);
            // The columns outside `deriv_reads` carry no lane: a host adds
            // their constant partials from `jac_const`, as here.
            inline for (comptime contract.jacConst(D)) |e| if (contract.jacConstApplies(D, e, &m, false)) {
                const at = @as(usize, @backingInt(e.row)) * n + @backingInt(e.col);
                out[n + at] += e.g;
                qo[n + at] += e.c;
            };
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
            return 0;
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
