"""One device-shaped body, emitted twice from the same op list: scalar (what VerA emits
today: one chain of family calls per expression) and packed (k isomorphic chains as one chain
over vectors). Both write the same outputs, so a checksum over them must match bit for bit.

Shape: G groups of K=4 isomorphic chains. A chain is one of three compact-model fragments
(hyperbolic smoothing, softplus through exp and log, a rational mobility term), 8 to 11 family
operations deep, over per-chain parameters. A value is a primal plus N derivative lanes
(N=0: plain f64, as in parameter-only setup code; N=3: a three-unknown device row).

Lane flow, to keep the packed form realistic rather than ideal: a group's input is the previous
group's result lane for lane; every 4th group restarts from the unknowns (a gather of scalars);
every 5th group takes the previous lanes permuted (a shuffle). Parameters are contiguous by role
(a vector load) or scattered (a gather of four scalars), by --params.

Usage: pack_gen.py VARIANT G N OUT.zig [--params contiguous|scattered] [--flow mixed|aligned|unaligned] [--only smooth|softplus|mobility] [--outline] [--chunk GROUPS] [--no-main]
       VARIANT is scalar | packed
"""
import random
import sys

K = 4
TEMPLATES = {
    # (dst, op, args): args name temps, "x" (the chain input), "P<i>" (a per-chain parameter), or a float.
    "smooth": [
        ("t1", "mul", ("x", "x")),
        ("t2", "addP", ("t1", "P0")),
        ("t3", "sqrt", ("t2",)),
        ("t4", "add", ("x", "t3")),
        ("t5", "scale", ("t4", 0.5)),
        ("t6", "scaleP", ("t5", "P1")),
        ("t7", "scaleP", ("t5", "P2")),
        ("t8", "addC", ("t7", 1.0)),
        ("y", "div", ("t6", "t8")),
    ],
    "softplus": [
        ("t1", "subP", ("x", "P0")),
        ("t2", "scaleP", ("t1", "P1")),
        ("t3", "exp", ("t2",)),
        ("t4", "addC", ("t3", 1.0)),
        ("t5", "ln", ("t4",)),
        ("t6", "scaleP", ("t5", "P2")),
        ("t7", "mul", ("t6", "x")),
        ("t8", "scale", ("x", 0.1)),
        ("t9", "mul", ("t8", "t8")),
        ("t10", "addC", ("t9", 1.0)),
        ("y", "div", ("t7", "t10")),
    ],
    "mobility": [
        ("t1", "scaleP", ("x", "P0")),
        ("t2", "mul", ("x", "x")),
        ("t3", "scaleP", ("t2", "P1")),
        ("t4", "add", ("t1", "t3")),
        ("t5", "addC", ("t4", 1.0)),
        ("t6", "div", ("x", "t5")),
        ("t7", "scaleP", ("t6", "P2")),
        ("y", "add", ("t7", "t1")),
    ],
}
N_ROLES = 3


def family(n):
    """The scalar value D and the pack P, by lib/contract/family.zig's numerics table."""
    if n == 0:
        return '''
const KV = @Vector(K, f64);
const D = struct {
    v: f64,
    inline fn add(a: D, b: D) D { return .{ .v = a.v + b.v }; }
    inline fn mul(a: D, b: D) D { return .{ .v = a.v * b.v }; }
    inline fn div(a: D, b: D) D { return .{ .v = a.v / b.v }; }
    inline fn scale(a: D, c: f64) D { return .{ .v = a.v * c }; }
    inline fn addC(a: D, c: f64) D { return .{ .v = a.v + c }; }
    inline fn exp(a: D) D { return .{ .v = gm.exp(a.v) }; }
    inline fn ln(a: D) D { return .{ .v = gm.log(a.v) }; }
    inline fn sqrt(a: D) D { return .{ .v = @sqrt(a.v) }; }
};
const P = struct {
    v: KV,
    inline fn add(a: P, b: P) P { return .{ .v = a.v + b.v }; }
    inline fn mul(a: P, b: P) P { return .{ .v = a.v * b.v }; }
    inline fn div(a: P, b: P) P { return .{ .v = a.v / b.v }; }
    inline fn scale(a: P, c: KV) P { return .{ .v = a.v * c }; }
    inline fn addC(a: P, c: KV) P { return .{ .v = a.v + c }; }
    inline fn exp(a: P) P { return .{ .v = gm.exp(a.v) }; }
    inline fn ln(a: P) P { return .{ .v = gm.log(a.v) }; }
    inline fn sqrt(a: P) P { return .{ .v = @sqrt(a.v) }; }
    inline fn gather(xs: [K]D) P { return .{ .v = .{ xs[0].v, xs[1].v, xs[2].v, xs[3].v } }; }
    inline fn perm(a: P, comptime m: [K]i32) P { return .{ .v = @shuffle(f64, a.v, undefined, m) }; }
    inline fn lane(a: P, comptime i: usize) D { return .{ .v = a.v[i] }; }
};
inline fn seed(x: *const [N_U]f64, comptime u: usize) D { return .{ .v = x[u] }; }
inline fn put(out: [*]f64, jac: [*]f64, comptime i: usize, r: D) void { _ = jac; out[i] = r.v; }
inline fn putK(out: [*]f64, jac: [*]f64, comptime i: usize, r: P) void { _ = jac; out[i..][0..K].* = r.v; }
'''
    # N > 0. The pack holds one K-vector for the primal and one per unknown (fields d0..), so
    # every rule is the scalar rule at K lanes with no shuffle between a value and its derivative
    # lanes. Rules are struct literals: an `undefined` result filled field by field, or an array
    # of vectors, hands LLVM memory traffic instead of values.
    def each(fmt, sep=", "):
        return sep.join(fmt.format(u=u) for u in range(n))
    return """
const KV = @Vector(K, f64);
const DV = @Vector(N, f64);
inline fn sp(c: f64) DV { return @splat(c); }
const one: KV = @splat(1.0);
const D = struct {
    v: f64,
    d: DV,
    inline fn add(a: D, b: D) D { return .{ .v = a.v + b.v, .d = a.d + b.d }; }
    inline fn mul(a: D, b: D) D { return .{ .v = a.v * b.v, .d = @mulAdd(DV, b.d, sp(a.v), a.d * sp(b.v)) }; }
    inline fn div(a: D, b: D) D { const q = a.v / b.v; return .{ .v = q, .d = @mulAdd(DV, b.d, sp(-q), a.d) * sp(1.0 / b.v) }; }
    inline fn scale(a: D, c: f64) D { return .{ .v = a.v * c, .d = a.d * sp(c) }; }
    inline fn addC(a: D, c: f64) D { return .{ .v = a.v + c, .d = a.d }; }
    inline fn exp(a: D) D { const e = gm.exp(a.v); return .{ .v = e, .d = a.d * sp(e) }; }
    inline fn ln(a: D) D { return .{ .v = gm.log(a.v), .d = a.d * sp(1.0 / a.v) }; }
    inline fn sqrt(a: D) D { const r = @sqrt(a.v); return .{ .v = r, .d = a.d * sp(0.5 / r) }; }
};
const P = struct {
    v: KV,
    """ + each("d{u}: KV,", "\n    ") + """
    inline fn add(a: P, b: P) P { return .{ .v = a.v + b.v, """ + each(".d{u} = a.d{u} + b.d{u}") + """ }; }
    inline fn mul(a: P, b: P) P { return .{ .v = a.v * b.v, """ + each(".d{u} = @mulAdd(KV, b.d{u}, a.v, a.d{u} * b.v)") + """ }; }
    inline fn div(a: P, b: P) P { const q = a.v / b.v; const inv = one / b.v; return .{ .v = q, """ + each(".d{u} = @mulAdd(KV, b.d{u}, -q, a.d{u}) * inv") + """ }; }
    inline fn scale(a: P, c: KV) P { return .{ .v = a.v * c, """ + each(".d{u} = a.d{u} * c") + """ }; }
    inline fn addC(a: P, c: KV) P { return .{ .v = a.v + c, """ + each(".d{u} = a.d{u}") + """ }; }
    inline fn exp(a: P) P { const e = gm.exp(a.v); return .{ .v = e, """ + each(".d{u} = a.d{u} * e") + """ }; }
    inline fn ln(a: P) P { const inv = one / a.v; return .{ .v = gm.log(a.v), """ + each(".d{u} = a.d{u} * inv") + """ }; }
    inline fn sqrt(a: P) P { const q = @sqrt(a.v); const h = @as(KV, @splat(0.5)) / q; return .{ .v = q, """ + each(".d{u} = a.d{u} * h") + """ }; }
    inline fn gather(xs: [K]D) P { return .{ .v = .{ xs[0].v, xs[1].v, xs[2].v, xs[3].v }, """ + each(".d{u} = .{{ xs[0].d[{u}], xs[1].d[{u}], xs[2].d[{u}], xs[3].d[{u}] }}") + """ }; }
    inline fn perm(a: P, comptime m: [K]i32) P { return .{ .v = @shuffle(f64, a.v, undefined, m), """ + each(".d{u} = @shuffle(f64, a.d{u}, undefined, m)") + """ }; }
    inline fn lane(a: P, comptime i: usize) D { return .{ .v = a.v[i], .d = .{ """ + each("a.d{u}[i]") + """ } }; }
};
inline fn seed(x: *const [N_U]f64, comptime u: usize) D { var d: [N]f64 = @splat(0.0); d[u] = 1.0; return .{ .v = x[u], .d = d }; }
// Outputs are struct-of-arrays: the primal row, then one row per unknown.
inline fn put(out: [*]f64, jac: [*]f64, comptime i: usize, r: D) void { out[i] = r.v; inline for (0..N) |u| jac[u * N_OUT + i] = r.d[u]; }
inline fn putK(out: [*]f64, jac: [*]f64, comptime i: usize, r: P) void { out[i..][0..K].* = r.v; """ + each("jac[{u} * N_OUT + i ..][0..K].* = r.d{u};", " ") + """ }
"""


MAIN = '''
fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    const p = try gpa.alloc(f64, N_P);
    for (p) |*e| e.* = 0.5 + r.float(f64);
    const out = try gpa.alloc(f64, N_OUT);
    const jac = try gpa.alloc(f64, N_OUT * @max(N, 1));
    var xs: [64][N_U]f64 = undefined;
    for (&xs) |*x| for (x) |*e| { e.* = 0.2 + 0.7 * r.float(f64); };
    var h: u64 = 0xcbf29ce484222325;
    for (xs[0..8]) |*x| {
        @call(.never_inline, eval, .{ p.ptr, x, out.ptr, jac.ptr });
        for (out) |e| h = (h ^ @as(u64, @bitCast(e))) *% 0x100000001b3;
        if (N > 0) for (jac) |e| { h = (h ^ @as(u64, @bitCast(e))) *% 0x100000001b3; };
    }
    const reps: usize = @max(4, 20_000_000 / (N_OUT * (N + 1) * 12));
    var best: u64 = std.math.maxInt(u64);
    for (0..7) |_| {
        const t0 = now();
        for (0..reps) |i| @call(.never_inline, eval, .{ p.ptr, &xs[i & 63], out.ptr, jac.ptr });
        best = @min(best, now() - t0);
        std.mem.doNotOptimizeAway(out[N_OUT - 1]);
    }
    std.debug.print("{d:.1}\\t{x}\\n", .{ @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(reps)), h });
}
'''


def build(groups, seed_, flow, only):
    """The body as data: per group its template and where its input comes from.

    flow mixed (default): lane for lane from the previous group; every 4th group restarts from
    the unknowns, every 5th takes the previous lanes permuted. aligned: restarts every 16th group
    only. unaligned: every lane comes from a different earlier group, so the packed form pays
    K extracts and a gather per group and never chains.
    """
    rnd = random.Random(seed_)
    names = [only] if only else list(TEMPLATES)
    plan = []
    for g in range(groups):
        if flow == "unaligned" and g >= K:
            src = ("cross", [(g - 1 - j, rnd.randrange(K)) for j in range(K)])
        elif g % (16 if flow == "aligned" else 4) == 0 or (flow == "unaligned" and g < K):
            src = ("unknowns", None)
        elif flow == "mixed" and g % 5 == 0:
            src = ("perm", rnd.sample(range(K), K))
        else:
            src = ("prev", None)
        plan.append({"tpl": names[g % len(names)], "src": src})
    return plan


def emit(variant, groups, n, params, flow="mixed", only=None, main=True, outline=False, chunk=0):
    plan = build(groups, 1, flow, only)
    rnd = random.Random(2)
    n_p = groups * N_ROLES * K
    slots = list(range(n_p))
    if params == "scattered":
        rnd.shuffle(slots)
    def slot(g, role, lane):
        return slots[(g * N_ROLES + role) * K + lane]
    o = []
    w = o.append
    w("// GENERATED by gen_pack.py: %s, G=%d, N=%d, params %s." % (variant, groups, n, params))
    w('const std = @import("std");')
    w('const gm = @import("gm");')
    w("const K = %d;\nconst N = %d;\nconst N_U = 3;\nconst N_OUT = %d;\nconst N_P = %d;" % (K, n, groups * K, n_p))
    fam = family(n)
    if outline:
        # Only the pack's rules change: the scalar rules already call one out-of-line routine.
        head, pack = fam.split("const P = struct {")
        pack = pack.replace("gm.exp(a.v)", "expK(a.v)").replace("gm.log(a.v)", "logK(a.v)")
        fam = head + "noinline fn expK(x: KV) KV { return gm.exp(x); }\nnoinline fn logK(x: KV) KV { return gm.log(x); }\nconst P = struct {" + pack
    w(fam)
    assert_chunk = not chunk or flow != "unaligned"
    assert assert_chunk, "--chunk carries one group across a boundary; unaligned flow reaches further back"
    carry_t = "[K]D" if variant == "scalar" else "P"
    sig = "(noalias p: [*]const f64, noalias x: *const [N_U]f64, noalias out: [*]f64, noalias jac: [*]f64"
    if not chunk:
        w("export fn eval" + sig + ") void {")
        w("    @setEvalBranchQuota(1_000_000_000);")
    for g, grp in enumerate(plan):
        if chunk and g % chunk == 0:
            if g:
                w("    carry.* = %s;" % (".{ %s }" % ", ".join("g%d_%d_y" % (g - 1, l) for l in range(K)) if variant == "scalar" else "g%d_y" % (g - 1)))
                w("}")
            w("noinline fn chunk%d" % (g // chunk) + sig + ", noalias carry: *%s) void {" % carry_t)
            w("    @setEvalBranchQuota(1_000_000_000);")
            w("    _ = .{ p, x, out, jac };")
            if g and plan[g]["src"][0] != "unknowns":
                if variant == "scalar":
                    for l in range(K):
                        w("    const g%d_%d_y = carry[%d];" % (g - 1, l, l))
                else:
                    w("    const g%d_y = carry.*;" % (g - 1))
        ops = TEMPLATES[grp["tpl"]]
        kind, perm = grp["src"]
        if variant == "scalar":
            for lane in range(K):
                pre = "g%d_%d_" % (g, lane)
                if kind == "unknowns":
                    xin = "seed(x, %d)" % ((g + lane) % 3)
                elif kind == "perm":
                    xin = "g%d_%d_y" % (g - 1, perm[lane])
                elif kind == "cross":
                    xin = "g%d_%d_y" % perm[lane]
                else:
                    xin = "g%d_%d_y" % (g - 1, lane)
                w("    const %sx = %s;" % (pre, xin))
                for dst, op, args in ops:
                    a = pre + args[0]
                    if op in ("add", "mul", "div"):
                        e = "%s.%s(%s)" % (a, op, pre + args[1])
                    elif op in ("exp", "ln", "sqrt"):
                        e = "%s.%s()" % (a, op)
                    elif op in ("scale", "addC"):
                        e = "%s.%s(%r)" % (a, op, args[1])
                    else:
                        role = int(args[1][1:])
                        pv = "p[%d]" % slot(g, role, lane)
                        e = {"scaleP": "%s.scale(%s)", "addP": "%s.addC(%s)", "subP": "%s.addC(-%s)"}[op] % (a, pv)
                    w("    const %s%s = %s;" % (pre, dst, e))
                w("    put(out, jac, %d, %sy);" % (g * K + lane, pre))
        else:
            pre = "g%d_" % g
            if kind == "unknowns":
                xin = "P.gather(.{ %s })" % ", ".join("seed(x, %d)" % ((g + lane) % 3) for lane in range(K))
            elif kind == "perm":
                xin = "g%d_y.perm(.{ %s })" % (g - 1, ", ".join(str(i) for i in perm))
            elif kind == "cross":
                xin = "P.gather(.{ %s })" % ", ".join("g%d_y.lane(%d)" % gl for gl in perm)
            else:
                xin = "g%d_y" % (g - 1)
            w("    const %sx = %s;" % (pre, xin))
            used = sorted({int(a[1][1:]) for _, op, a in ops if op in ("scaleP", "addP", "subP")})
            for role in used:
                idx = [slot(g, role, lane) for lane in range(K)]
                if idx == list(range(idx[0], idx[0] + K)):
                    w("    const %sP%d: KV = p[%d..][0..K].*;" % (pre, role, idx[0]))
                else:
                    w("    const %sP%d: KV = .{ %s };" % (pre, role, ", ".join("p[%d]" % i for i in idx)))
            for dst, op, args in ops:
                a = pre + args[0]
                if op in ("add", "mul", "div"):
                    e = "%s.%s(%s)" % (a, op, pre + args[1])
                elif op in ("exp", "ln", "sqrt"):
                    e = "%s.%s()" % (a, op)
                elif op in ("scale", "addC"):
                    e = "%s.%s(@splat(%r))" % (a, op, args[1])
                else:
                    pv = pre + args[1]
                    e = {"scaleP": "%s.scale(%s)", "addP": "%s.addC(%s)", "subP": "%s.addC(-%s)"}[op] % (a, pv)
                w("    const %s%s = %s;" % (pre, dst, e))
            w("    putK(out, jac, %d, %sy);" % (g * K, pre))
    if chunk:
        g = len(plan)
        w("    carry.* = %s;" % (".{ %s }" % ", ".join("g%d_%d_y" % (g - 1, l) for l in range(K)) if variant == "scalar" else "g%d_y" % (g - 1)))
        w("}")
        w("export fn eval" + sig + ") void {")
        w("    var carry: %s = undefined;" % carry_t)
        for c in range((len(plan) + chunk - 1) // chunk):
            w("    chunk%d(p, x, out, jac, &carry);" % c)
    w("}")
    if main:
        w(MAIN)
    return "\n".join(o) + "\n"


if __name__ == "__main__":
    variant, groups, n, path = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    opt = lambda name, default: sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default
    open(path, "w").write(emit(variant, groups, n, opt("--params", "contiguous"), opt("--flow", "mixed"), opt("--only", None), "--no-main" not in sys.argv, "--outline" in sys.argv, int(opt("--chunk", "0"))))
