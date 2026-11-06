//! The device checks a bench states: the comptime tables made once before
//! the points (`noise_gens`, `ac_gens`, the charge sites, `seed`,
//! `decl_meta`, `u_abstol`) and the bias- and card-dependent ones at the
//! run's first point (`noisePsd`, `acStim`, `acDyn`, `limit`). Each prints
//! one `got=/want= ok=` line per row plus one for the count. A table these
//! lines name is published only to a host, so it is the one place its
//! clause is observable.
//! Cites: §2.9.2, §3.2.1, §3.4.3, §3.6.1.2, §3.6.3.1, §4.6.3, §4.6.4,
//! §4.6.4.1-.6, §5.6.1.2, §9.17.3; A.8.2.
//!
//! Contents:
//! - `pub fn noiseTopology(comptime rows: []const NoiseWant, model: *const D.Model) void`
//! - `pub fn acTopology(comptime rows: []const AcWant) void`, `pub fn qSites(comptime rows: []const []const u8) void`
//! - `pub fn seedCheck(comptime seeds: []const Binding, model: *const D.Model, inst: *D.Instance) void`
//! - `pub fn meta(comptime rows: []const []const u8) void`, `pub fn abstols(comptime rows: []const Binding) void`
//! - `pub fn noisePsd(comptime rows: []const NoiseWant, x: *const [n_u]f64, card: *const D.Model, inst: *D.Instance) void`
//! - `pub fn acStim(comptime rows: []const AcWant, x: *const [n_u]f64, card: *const D.Model, inst: *D.Instance) void`
//! - `pub fn acDyn(comptime rows: []const AcDynWant, x: *const [n_u]f64, card: *const D.Model, inst: *D.Instance) void`
//! - `pub fn limits(comptime cases: []const LimitCase, x: *const [n_u]f64, card: *const D.Model, inst: *D.Instance) void`

const std = @import("std");
const contract = @import("contract");
const hub = @import("../bench.zig");
const Dual = @import("batch.zig").Dual;
const Val = @import("batch.zig").Val;
const u_abstol = @import("solve.zig").u_abstol;
const u_names = @import("report.zig").u_names;
const spec = @import("spec.zig");
const D = hub.D;
const n_u = hub.n_u;
const NoiseWant = spec.NoiseWant;
const AcWant = spec.AcWant;
const AcDynWant = spec.AcDynWant;
const Binding = spec.Binding;
const LimitCase = spec.LimitCase;

/// §4.6.4: the `noise_gens` row count and each row's `kind(row,col)#source`
/// (`U`'s names are the spelling contract, as `//! bias` writes them; `#k`
/// is §4.6.4.6's correlation column), then the label and table fields of
/// the rows that state them. No table is the empty table.
pub fn noiseTopology(comptime rows: []const NoiseWant, model: *const D.Model) void {
    if (comptime @hasDecl(D, "noise_gens")) {
        std.debug.print("noise count got={d} want={d} ok={d}\n", .{ D.noise_gens.len, rows.len, @intFromBool(D.noise_gens.len == rows.len) });
        inline for (D.noise_gens, 0..) |g, i| {
            const got = comptime std.fmt.comptimePrint("{s}({s},{s})#{?d}", .{ @tagName(g.kind), u_names[g.row], u_names[g.col], g.source });
            const w_i: []const u8 = if (i < rows.len) rows[i].topo else "<none>";
            std.debug.print("noise[{d}] got={s} want={s} ok={d}\n", .{ i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)) });
        }
    } else std.debug.print("noise count got=0 want={d} ok={d}\n", .{ rows.len, @intFromBool(rows.len == 0) });
    if (comptime !@hasDecl(D, "noise_gens")) return;
    inline for (rows, 0..) |r, k| if (comptime D.noise_gens.len > k) {
        if (r.name) |nm| std.debug.print("noise[{d}].name got={s} want={s} ok={d}\n", .{ k, D.noise_gens[k].name, nm, @intFromBool(std.mem.eql(u8, D.noise_gens[k].name, nm)) });
        if (r.interp != null or r.points != null or r.psd != null) spectrum(r, k, model);
    };
}

/// §4.6.3: the `ac_gens` source count, each branch and each stated
/// analysis name. No table is the empty table.
pub fn acTopology(comptime rows: []const AcWant) void {
    if (comptime !@hasDecl(D, "ac_gens"))
        return std.debug.print("acstim count got=0 want={d} ok={d}\n", .{ rows.len, @intFromBool(rows.len == 0) });
    std.debug.print("acstim count got={d} want={d} ok={d}\n", .{ D.ac_gens.len, rows.len, @intFromBool(D.ac_gens.len == rows.len) });
    inline for (D.ac_gens, 0..) |g, i| {
        const got = comptime std.fmt.comptimePrint("({s},{s})", .{ u_names[g.row], u_names[g.col] });
        const w_i: []const u8 = if (i < rows.len) rows[i].topo else "<none>";
        std.debug.print("acstim[{d}] got={s} want={s} ok={d}\n", .{ i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)) });
        if (i < rows.len) if (rows[i].name) |wn|
            std.debug.print("acstim[{d}].name got={s} want={s} ok={d}\n", .{ i, g.name, wn, @intFromBool(std.mem.eql(u8, g.name, wn)) });
    }
}

/// §5.6.1.2 the charge sites a host tapes one by one: which rows each
/// stamps (`q_stamps`) and whether `q_lte` checks it, as `//! qsite` writes a row.
pub fn qSites(comptime rows: []const []const u8) void {
    const nq = if (comptime @hasDecl(D, "q")) contract.nQ(D) else 0;
    std.debug.print("qsite count got={d} want={d} ok={d}\n", .{ nq, rows.len, @intFromBool(nq == rows.len) });
    if (comptime !@hasDecl(D, "q")) return;
    inline for (0..nq) |k| {
        const got = comptime blk: {
            @setEvalBranchQuota(1_000_000);
            var s: []const u8 = "";
            for (contract.qStamps(D)) |e| if (e.site == k) {
                s = s ++ if (e.sign == 1) @tagName(e.row) ++ "+ " else if (e.sign == -1) @tagName(e.row) ++ "- " else std.fmt.comptimePrint("{s}*{d} ", .{ @tagName(e.row), e.sign });
            };
            break :blk s ++ if (contract.qLte(D)[k]) "lte" else "nolte";
        };
        const w_k: []const u8 = if (k < rows.len) rows[k] else "<none>";
        std.debug.print("qsite[{d}] got={s} want={s} ok={d}\n", .{ k, got, w_k, @intFromBool(std.mem.eql(u8, got, w_k)) });
    }
}

/// §9.17.3 the cold start a host writes into its limited image, once after
/// `setup`: exactly the `seeds` lanes are non-null, with their values, and
/// each is in `limit_writes`.
pub fn seedCheck(comptime seeds: []const Binding, model: *const D.Model, inst: *D.Instance) void {
    const got: [n_u]?f64 = if (comptime @hasDecl(D, "seed")) D.seed(Val, model, inst, hub.sim_state) else @splat(null);
    var want: [n_u]?f64 = @splat(null);
    inline for (seeds) |s| want[hub.ix(s.name)] = s.value;
    const writes: u64 = if (comptime @hasDecl(D, "limit_writes")) D.limit_writes else 0;
    for (got, want, 0..) |g, w, i| {
        if (g == null and w == null) continue;
        const ok = g != null and w != null and hub.near(g.?, w.?);
        std.debug.print("seed[{s}] got={?d} want={?d} ok={d}\n", .{ u_names[i], g, w, @intFromBool(ok) });
        if (g != null) std.debug.print("seed[{s}] in limit_writes ok={d}\n", .{ u_names[i], @intFromBool(i < 64 and (writes >> @intCast(i)) & 1 != 0) });
    }
}

/// §2.9.2/§3.2.1/§3.4.3/§3.6.3.1: the `desc` and `units` a host shows,
/// each `decl_meta` row printed as `//! meta` writes it.
pub fn meta(comptime rows: []const []const u8) void {
    if (comptime !@hasDecl(D, "decl_meta"))
        return std.debug.print("meta count got=0 want={d} ok={d}\n", .{ rows.len, @intFromBool(rows.len == 0) });
    std.debug.print("meta count got={d} want={d} ok={d}\n", .{ D.decl_meta.len, rows.len, @intFromBool(D.decl_meta.len == rows.len) });
    inline for (D.decl_meta, 0..) |m, i| {
        const got = comptime row: {
            const dsc: []const u8 = if (m.desc) |v| " desc=\"" ++ v ++ "\"" else "";
            const uni: []const u8 = if (m.units) |v| " units=\"" ++ v ++ "\"" else "";
            break :row @tagName(m.kind) ++ " " ++ m.name ++ dsc ++ uni;
        };
        const w_i: []const u8 = if (i < rows.len) rows[i] else "<none>";
        std.debug.print("meta[{d}] got={s} want={s} ok={d}\n", .{ i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)) });
    }
}

/// §3.6.1.2 the tolerance the device publishes per named unknown
/// (`u_abstol`); a name the device lacks prints `got=none`.
pub fn abstols(comptime rows: []const Binding) void {
    inline for (rows) |r| {
        if (comptime hub.uIndex(r.name)) |u| {
            const g = u_abstol[u];
            std.debug.print("abstol[" ++ r.name ++ "] got={e} want={e} ok={d}\n", .{ g, r.value, @intFromBool(hub.near(g, r.value)) });
        } else std.debug.print("abstol[" ++ r.name ++ "] got=none want={e} ok=0\n", .{r.value});
    }
}

/// §4.6.4.1/.2 `white`, `flicker` (each scaled by §4.6.4.6's `coeff²`) and
/// `ef`, and the §4.6.4.6 correlations, from `noisePsd` at the point.
pub fn noisePsd(comptime rows: []const NoiseWant, x: *const [n_u]f64, card: *const D.Model, inst: *D.Instance) void {
    const any = comptime for (rows) |r| {
        if (r.needsPoint()) break true;
    } else false;
    if (comptime !any or !@hasDecl(D, "noisePsd")) return;
    const psd = D.noisePsd(Dual, x.*, card, inst, hub.sim_state);
    inline for (rows, 0..) |r, k| if (comptime r.needsPoint() and D.noise_gens.len > k) {
        const terms = .{ .{ "white", r.white, true }, .{ "flicker", r.flicker, true }, .{ "ef", r.ef, false } };
        inline for (terms) |f| if (f[1]) |want| {
            const v = @field(psd[k], f[0]);
            const got = if (f[2]) v * psd[k].coeff * psd[k].coeff else v;
            std.debug.print("noise[{d}]." ++ f[0] ++ " got={d} want={d} ok={d}\n", .{ k, got, want, @intFromBool(close(got, want, r.rtol)) });
        };
        // §4.6.4.6 ρ from what a host is handed: one shared `source` is one
        // generator (the sign of the coefficients' product), a `corr_with`
        // link a partial ρ, anything else independent.
        inline for (r.corrs) |c| {
            if (comptime D.noise_gens.len > c.with) {
                const j = c.with;
                const sgn = (psd[k].coeff * psd[j].coeff) / (@abs(psd[k].coeff) * @abs(psd[j].coeff));
                const linked = if (psd[k].corr_with) |o| o == j else false;
                const back = if (psd[j].corr_with) |o| o == k else false;
                const rho: f64 = if (k == j) 1.0 else if (D.noise_gens[k].source != null and D.noise_gens[k].source == D.noise_gens[j].source) sgn else if (linked) psd[k].corr * sgn else if (back) psd[j].corr * sgn else 0.0;
                std.debug.print("noise[{d}].corr[{d}] got={d} want={d} ok={d}\n", .{ k, j, rho, @as(f64, c.rho), @intFromBool(close(rho, c.rho, r.rtol)) });
            } else std.debug.print("noise[{d}].corr[{d}] got=none want={d} ok=0\n", .{ k, c.with, @as(f64, c.rho) });
        }
    };
}

/// §4.6.3 `mag` and `phase` from `acStim` at the point (A.8.2 makes both
/// `analog_expression`s, so they may depend on bias).
pub fn acStim(comptime rows: []const AcWant, x: *const [n_u]f64, card: *const D.Model, inst: *D.Instance) void {
    const any = comptime for (rows) |r| {
        if (r.needsPoint()) break true;
    } else false;
    if (comptime !any or !@hasDecl(D, "acStim")) return;
    const stim = D.acStim(Val, x.*, card, inst, hub.sim_state);
    inline for (rows, 0..) |r, k| if (comptime r.needsPoint() and D.ac_gens.len > k) {
        inline for (.{ .{ "mag", r.mag }, .{ "phase", r.phase } }) |f| if (f[1]) |want| {
            const got = @field(stim[k], f[0]);
            std.debug.print("acstim[{d}]." ++ f[0] ++ " got={d} want={d} ok={d}\n", .{ k, got, want, @intFromBool(close(got, want, r.rtol)) });
        };
    };
}

/// `acDyn`'s term at each named slot and frequency, at the point.
pub fn acDyn(comptime rows: []const AcDynWant, x: *const [n_u]f64, card: *const D.Model, inst: *D.Instance) void {
    inline for (rows) |r| {
        const ad = hub.acDynAt(hub.ix(r.row), hub.ix(r.col), 2.0 * std.math.pi * r.f_hz, x, card, inst);
        // The frequency as the directive's literal: `{d}`, or `{e}` past 2^53.
        const f = comptime if (@abs(r.f_hz) >= 0x1p53) std.fmt.comptimePrint("{e}", .{r.f_hz}) else std.fmt.comptimePrint("{d}", .{r.f_hz});
        const head = "acdyn[(" ++ r.row ++ "," ++ r.col ++ ") f=" ++ f ++ "]";
        std.debug.print(head ++ ".re got={e} want={e} ok={d}\n", .{ ad.re, r.re, @intFromBool(@abs(ad.re - r.re) <= r.tol) });
        std.debug.print(head ++ ".im got={e} want={e} ok={d}\n", .{ ad.im, r.im, @intFromBool(@abs(ad.im - r.im) <= r.tol) });
    }
}

/// §9.17.3 the `limit` cases at the first point, after the solve: `old` is
/// `x` but for the case's lanes, and the result holds each wanted lane
/// (`converged` is the verdict).
pub fn limits(comptime cases: []const LimitCase, x: *const [n_u]f64, card: *const D.Model, inst: *D.Instance) void {
    inline for (cases, 0..) |c, k| {
        var old = x.*;
        inline for (c.old) |o| old[hub.ix(o.name)] = o.value;
        if (comptime !@hasDecl(D, "limit")) {
            std.debug.print("limit[{d}] got=none want=limit ok=0\n", .{k});
        } else {
            const r = D.limit(Val, card, inst, x.*, old, hub.sim_state);
            inline for (c.want) |w| if (comptime std.mem.eql(u8, w.name, "converged")) {
                std.debug.print("limit[{d}].converged got={d} want={d} ok={d}\n", .{ k, @intFromBool(r.converged), @intFromBool(w.value != 0), @intFromBool(r.converged == (w.value != 0)) });
            } else {
                const got = r.x[hub.ix(w.name)];
                std.debug.print("limit[{d}]." ++ w.name ++ " got={d} want={d} ok={d}\n", .{ k, got, w.value, @intFromBool(hub.near(got, w.value)) });
            };
        }
    }
}

// ---- private ----

/// The relative compare of the noise and AC numbers.
fn close(g: f64, w: f64, rt: f64) bool {
    return @abs(g - w) <= rt * @max(@abs(g), @abs(w));
}

/// Row `k`'s §4.6.4.3/.4 table checks: `interp`, `points` and `psd`, from
/// the table as a host reads it (`contract.noiseTable`). Only a `.table`
/// row has a spectrum; on another row they FAIL with a reason.
fn spectrum(comptime r: NoiseWant, comptime k: usize, model: *const D.Model) void {
    const ti = D.noise_gens[k].table orelse return std.debug.print("noise[{d}].table got=none want=a table ok=0\n", .{k});
    const tbl = contract.noiseTable(D, model, ti);
    if (r.interp) |ip| std.debug.print("noise[{d}].interp got={s} want={s} ok={d}\n", .{ k, @tagName(tbl.interp), @tagName(ip), @intFromBool(std.mem.eql(u8, @tagName(tbl.interp), @tagName(ip))) });
    if (r.points) |want_pts| {
        const got_pts = tbl.points;
        var ok = got_pts.len == want_pts.len;
        if (ok) for (got_pts, want_pts) |g, wp| {
            if (!close(g[0], wp[0], r.rtol) or !close(g[1], wp[1], r.rtol)) {
                ok = false;
                break;
            }
        };
        std.debug.print("noise[{d}].points got={any} want={any} ok={d}\n", .{ k, got_pts, want_pts[0..want_pts.len].*, @intFromBool(ok) });
    }
    if (r.psd) |want_psd| {
        var got_psd: [want_psd.len]f64 = undefined;
        var ok = true;
        for (want_psd, &got_psd) |fw, *g| {
            g.* = contract.noiseTableAt(tbl, fw[0]);
            if (!close(g.*, fw[1], r.rtol)) ok = false;
        }
        std.debug.print("noise[{d}].psd got={any} want={any} ok={d}\n", .{ k, got_psd, want_psd[0..want_psd.len].*, @intFromBool(ok) });
    }
}
