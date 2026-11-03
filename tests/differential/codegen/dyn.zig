//! diff-codegen's host: a bundle of devices in (`devices`, a tuple of the
//! library root's, named by `names`: `o<k>` the old pipeline's, `n<k>` the new one's), one C
//! entry per device out, `cg_<decl>`, that sets a card by name, runs
//! `derive`/`setup` as a host does, and evaluates `eval` and `q` at one
//! point with every lane carried: the residual rows, their dense Jacobian,
//! the reactive rows (`contract.qRows`) and theirs.
//! Cites: VAMS-2023 §5.6, §5.6.1.2 (the rows and charges a host reads).
//!
//! Contents:
//! - `pub fn exportDevice(comptime B: type, comptime name: []const u8) void`

const std = @import("std");
const contract = @import("contract");

/// `link`'s hook: exports `Run(D).run` as `cg_<decl>` for every device `D`
/// of bundle `B`'s `devices`, named by its `names`. `name` is the library's, unused.
pub fn exportDevice(comptime B: type, comptime name: []const u8) void {
    _ = name;
    inline for (B.devices, B.names) |D, n| @export(&Run(D).run, .{ .name = "cg_" ++ n });
}

// ---- private ----

/// The entry of device `D`.
fn Run(comptime D: type) type {
    return struct {
        const n = contract.nU(D);
        const S = contract.RefFamily(f64, &std.simd.iota(u8, n), .{});
        const V = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{});

        /// Sets the card (`names[k]` = `vals[k]`), evaluates at `x` and time
        /// `t`, and writes `2n + 2n²` reals to `out`: the rows, their
        /// Jacobian (row-major), the reactive rows, theirs. Returns 0; -1
        /// when `n_x` is not |U|, -2 when `out` is short, -3 when a name is
        /// no field of `Model`.
        fn run(names: [*]const [*:0]const u8, vals: [*]const f64, n_params: u32, x: [*]const f64, n_x: u32, t: f64, out: [*]f64, out_len: u32) callconv(.c) i32 {
            if (n_x != n) return -1;
            if (out_len < 2 * n + 2 * n * n) return -2;
            var m: D.Model = .{};
            for (names[0..n_params], vals[0..n_params]) |nm, v| if (!set(&m, std.mem.span(nm), v)) return -3;
            if (@hasDecl(D, "derive")) D.derive(V, &m);
            if (@hasDecl(D, "setup")) D.setup(V, &m);
            var inst: D.Instance = .{};
            if (@hasDecl(D, "setupInstance")) D.setupInstance(&m, &inst);
            const sim: contract.SimState = .{ .t = t, .dt = 1e-9, .kind = .tran, .analog_initial = false, .iteration = 2 };
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
                        // else: a field the oracle does not draw (a string, a table)
                        else => return false,
                    }
                    return true;
                }
            }
            return false;
        }
    };
}
