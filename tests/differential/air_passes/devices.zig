//! Hand-built device contributions as structured Air, the roots
//! `default_unknown_bound` was measured on (no Sema exists to lower the
//! fixture devices yet): a resistor, a capacitor's charge, a diode
//! `Is*(exp(V/(n*vt)) - 1)` with vt a constant and with vt `$vt` of
//! `$temperature`, an Ebers-Moll transistor, a MOSFET square law behind
//! its cutoff `?:`, a BSIM-like rational over a softplus `Vgsteff`, and a
//! `tanh` limiter. Each reads node voltages as probes and parameters with
//! the two-sided ranges a model card states.
//! Cites: VAMS-2023 §3.4.2, §4.3.1, §4.3.2, §4.4, §4.5.13, §9.15.
//!
//! Contents:
//! - `pub const Kind = enum`
//! - `pub const Device = struct` (`deinit`)
//! - `pub fn build(gpa: Allocator, ip: *InternPool, kind: Kind) !Device`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const Interval = Air.Interval;
const Float = Air.Float;
const Inst = Air.Inst;

/// The devices, one root each.
pub const Kind = enum { resistor, capacitor, diode, diode_vt, bjt, mosfet, bsim, limiter };

/// One device: its Air, its parameters' ranges, its root and its callees.
pub const Device = struct {
    air: Air,
    params: [params_max]Float.Param,
    root: Inst.Ref,
    calls: []const Air.CallFacts,

    pub fn deinit(d: *Device, gpa: Allocator) void {
        d.air.deinit(gpa);
        d.* = undefined;
    }
};

const params_max = 4;
/// kT/q at 300.15 K, in volts.
const vt_300: f64 = 0.025852;
/// Callee 0 is `$temperature`, callee 1 `$vt(T)`.
const calls = [_]Air.CallFacts{ .{ .range = .positive }, .{ .range = .vt } };

const B = struct {
    gpa: Allocator,
    ip: *InternPool,
    b: Air.Builder,
    main: std.ArrayList(Inst.Index) = .empty,

    fn add(s: *B, inst: Inst) !Inst.Ref {
        const i = try s.b.addInst(s.gpa, inst);
        try s.main.append(s.gpa, i);
        return .fromIndex(i);
    }
    fn arg(s: *B, k: u32) !Inst.Ref {
        return s.add(.{ .tag = .arg, .data = .{ .ty_index = .{ .ty = .real_type, .index = k } } });
    }
    fn probe(s: *B, k: u32) !Inst.Ref {
        return s.add(.{ .tag = .probe, .data = .{ .ty_index = .{ .ty = .real_type, .index = k } } });
    }
    fn un(s: *B, tag: Inst.Tag, a: Inst.Ref) !Inst.Ref {
        return s.add(.{ .tag = tag, .data = .{ .un_op = a } });
    }
    fn bin(s: *B, tag: Inst.Tag, a: Inst.Ref, b: Inst.Ref) !Inst.Ref {
        return s.add(.{ .tag = tag, .data = .{ .bin_op = .{ .lhs = a, .rhs = b } } });
    }
    fn real(s: *B, x: f64) !Inst.Ref {
        return .fromIntern(try s.ip.get(s.gpa, .{ .float = x }));
    }
    fn call(s: *B, callee: u32, a: ?Inst.Ref) !Inst.Ref {
        const n: u32 = @intFromBool(a != null);
        const payload = try s.b.addExtra(s.gpa, Air.Call{ .callee = callee, .args_len = n });
        if (a) |x| try s.b.extra.append(s.gpa, @backingInt(x));
        return s.add(.{ .tag = .call, .data = .{ .ty_pl = .{ .ty = .real_type, .payload = payload } } });
    }
    /// `V(a, b)`: the difference of two node voltages.
    fn v(s: *B, a: u32, b: u32) !Inst.Ref {
        return s.bin(.fsub, try s.probe(a), try s.probe(b));
    }
    /// `is * (exp(x / nvt) - 1)`.
    fn junction(s: *B, is: Inst.Ref, x: Inst.Ref, nvt: Inst.Ref) !Inst.Ref {
        return s.bin(.fmul, is, try s.bin(.fsub, try s.un(.exp, try s.bin(.fdiv, x, nvt)), try s.real(1)));
    }
};

/// Returns device `kind` built in a fresh `Air` (the caller frees it) over
/// `ip`.
pub fn build(gpa: Allocator, ip: *InternPool, kind: Kind) !Device {
    var s: B = .{ .gpa = gpa, .ip = ip, .b = try .init(gpa) };
    defer s.b.deinit(gpa);
    defer s.main.deinit(gpa);
    var d: Device = .{ .air = undefined, .params = @splat(.{}), .root = undefined, .calls = &calls };
    d.root = switch (kind) {
        .resistor => blk: {
            d.params[0].ranges = &.{.{ .kind = .from, .lo = 1e-3, .hi = 1e12 }};
            break :blk try s.bin(.fdiv, try s.v(0, 1), try s.arg(0));
        },
        .capacitor => blk: {
            d.params[0].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 1 }};
            break :blk try s.bin(.fmul, try s.arg(0), try s.v(0, 1));
        },
        .diode, .diode_vt => blk: {
            d.params[0].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 1, .lo_inclusive = false }};
            d.params[1].ranges = &.{.{ .kind = .from, .lo = 0.5, .hi = 10 }};
            const vt = if (kind == .diode) try s.real(vt_300) else try s.call(1, try s.call(0, null));
            break :blk try s.junction(try s.arg(0), try s.v(0, 1), try s.bin(.fmul, try s.arg(1), vt));
        },
        .bjt => blk: {
            d.params[0].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 1, .lo_inclusive = false }};
            const is = try s.arg(0);
            const vt = try s.real(vt_300);
            const be = try s.junction(is, try s.v(0, 2), vt);
            break :blk try s.bin(.fsub, be, try s.junction(is, try s.v(1, 2), vt));
        },
        .mosfet => blk: {
            // id = vov > 0 ? kp/2 * wl * vov^2 * (1 + lambda*vds) : 0
            d.params[0].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 1, .lo_inclusive = false }};
            d.params[1].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 1e4, .lo_inclusive = false }};
            d.params[2].ranges = &.{.{ .kind = .from, .lo = -5, .hi = 5 }};
            d.params[3].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 1 }};
            const vov = try s.bin(.fsub, try s.v(0, 2), try s.arg(2));
            const k = try s.bin(.fmul, try s.bin(.fmul, try s.arg(0), try s.real(0.5)), try s.arg(1));
            const clm = try s.bin(.fadd, try s.real(1), try s.bin(.fmul, try s.arg(3), try s.v(1, 2)));
            const on = try s.bin(.fmul, try s.bin(.fmul, k, try s.bin(.fmul, vov, vov)), clm);
            const sel = try s.b.addExtra(gpa, Air.Bin{ .lhs = on, .rhs = try s.real(0) });
            break :blk try s.add(.{ .tag = .select, .data = .{ .pl_op = .{ .operand = try s.bin(.fgt, vov, try s.real(0)), .payload = sel } } });
        },
        .bsim => blk: {
            // vgsteff = 2 n vt ln1p(exp((vgs - vth) / (2 n vt)));
            // id = mu * vgsteff * vds / (1 + theta * vgsteff)
            d.params[0].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 1, .lo_inclusive = false }};
            d.params[1].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 10 }};
            d.params[2].ranges = &.{.{ .kind = .from, .lo = 1, .hi = 3 }};
            d.params[3].ranges = &.{.{ .kind = .from, .lo = -5, .hi = 5 }};
            const nvt2 = try s.bin(.fmul, try s.arg(2), try s.real(2 * vt_300));
            const x = try s.bin(.fdiv, try s.bin(.fsub, try s.v(0, 2), try s.arg(3)), nvt2);
            const eff = try s.bin(.fmul, nvt2, try s.un(.ln1p, try s.un(.exp, x)));
            const num = try s.bin(.fmul, try s.bin(.fmul, try s.arg(0), eff), try s.v(1, 2));
            break :blk try s.bin(.fdiv, num, try s.bin(.fadd, try s.real(1), try s.bin(.fmul, try s.arg(1), eff)));
        },
        .limiter => blk: {
            // gm * vs * tanh(V / vs)
            d.params[0].ranges = &.{.{ .kind = .from, .lo = 0, .hi = 1 }};
            d.params[1].ranges = &.{.{ .kind = .from, .lo = 1e-3, .hi = 10 }};
            const vs = try s.arg(1);
            const t = try s.un(.tanh, try s.bin(.fdiv, try s.v(0, 1), vs));
            break :blk try s.bin(.fmul, try s.bin(.fmul, try s.arg(0), vs), t);
        },
    };
    _ = try s.add(.{ .tag = .ret, .data = .{ .un_op = d.root } });
    d.air = try s.b.finish(gpa, s.main.items);
    assert(d.air.mainBody().len == s.main.items.len);
    return d;
}
