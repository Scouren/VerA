//! The comptime evaluator's system-call folds (`eval.zig`'s `Env.sysCall`,
//! moved here beside `eval_1364_fn.zig`'s precedent): a `call_sys`
//! instruction's folded arguments in, its §4.3/§9.11/§9.18/§17.11.1 result
//! out, or null for any call no table folds.
//! Cites: VAMS-2023 §4.2.1.1, §4.3 (Tables 4-14, 4-15), §9.11, §9.14, §9.18;
//! IEEE 1364-2005 §17.11.1.
//!
//! Contents:
//! - `pub fn sysCall(env: *Env, call: Inst.SysCall) Allocator.Error!?Const`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const fold = @import("std_kernels").fold;
const Zcu = @import("../Zcu.zig");
const eval = @import("eval.zig");
const sign = @import("sign.zig");
const Env = eval.Env;
const Const = eval.Const;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// §4.3's functions and IEEE 1364-2005 §17.11's `$clog2` and math
/// functions; any other call has no constant value.
pub fn sysCall(env: *Env, call: Inst.SysCall) Allocator.Error!?Const {
    std.debug.assert(call.name != .empty);
    const raw = env.vir.string(call.name);
    const name = if (raw.len != 0 and raw[0] == '$') raw[1..] else raw;
    const args = env.vir.list(Inst.Ref, call.args);
    if (args.len == 0) if (Zcu.SystemParam.fromName(raw)) |k| return env.toConst(env.hier.get(k));
    var vals: [fold.MathFn.arity_max]Const = undefined;
    if (args.len == 0 or args.len > vals.len) return null;
    for (args, vals[0..args.len]) |a, *v| v.* = (try env.ref(a)) orelse return null;
    if (std.mem.eql(u8, name, "clog2")) {
        if (args.len != 1) return null;
        // D1-G: the argument's own IEEE 1364-2005 §5.4.1 self-determined
        // width, not a flat 32 bits (`clog2_unsigned_width.va`'s
        // `4'hf + 4'h1`, self-determined at 4 bits, discards the carry).
        const width = sign.clog2Width(env.vir, args[0]) orelse 32;
        return .{ .int = fold.clog2(vals[0].asIntExact() orelse return null, width) };
    }
    // §4.2.1.1 / §9.11: `$rtoi` truncates toward zero into §3.2's
    // 32-bit integer (null outside it, or for NaN: a run-time question);
    // `$itor` is the integer's real.
    const rtoi = std.mem.eql(u8, raw, "$rtoi");
    if (rtoi or std.mem.eql(u8, raw, "$itor")) {
        if (args.len != 1 or vals[0] == .str) return null;
        if (!rtoi) return .{ .real = @floatFromInt(vals[0].asIntExact() orelse return null) };
        const t = @trunc(vals[0].asReal());
        if (!(t >= -2147483648.0 and t <= 2147483647.0)) return null;
        return .{ .int = @intFromFloat(t) };
    }
    const f = fold.MathFn.fromName(if (std.mem.eql(u8, name, "log10")) "log" else name) orelse return null;
    return fold.math(f, vals[0..args.len]);
}
