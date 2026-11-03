//! System functions of the digital lowering: a `call_sys` in an
//! expression, in `Lower.frame`, -> its `Program.exprs` row in its §17
//! natural type (`sysType`), converted to the context (`sysCall`), or as a
//! real (`sysReal`).
//! Cites: IEEE 1364-2005 §17.7, §17.8, §17.9, §17.10, §17.11.
//!
//! Contents:
//! - `pub fn sysType(l: *Lower, i: Inst.Index) Error!Type`
//! - `pub fn sysCall(l: *Lower, i: Inst.Index, t: Ty, nat: Type) Error!u32`
//! - `pub fn sysReal(l: *Lower, i: Inst.Index) Error!u32`

const std = @import("std");
const assert = std.debug.assert;
const vams = @import("vams");
const std_sim = @import("std_sim");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const Lower = digital.Lower;
const Error = digital.Error;
const Type = digital.Type;
const Name = digital.Name;
const none = digital.none;
const Program = std_sim.Program;
const Ty = Program.Ty;
const Vir = vams.Vir;
const Inst = Vir.Inst;

/// §17 the system functions `ctx` lowers, by name.
const SysFn = enum { time, stime, realtime, signed, unsigned, clog2, rtoi, itor, realtobits, bitstoreal, random, test_plusargs, value_plusargs, ln, log10, exp, sqrt, floor, ceil, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, asinh, acosh, atanh, pow, atan2, hypot };

const sys_fns = std.StaticStringMap(SysFn).initComptime(.{
    .{ "$time", .time },                     .{ "$stime", .stime },       .{ "$realtime", .realtime },
    .{ "$signed", .signed },                 .{ "$unsigned", .unsigned }, .{ "$clog2", .clog2 },
    .{ "$rtoi", .rtoi },                     .{ "$itor", .itor },         .{ "$realtobits", .realtobits },
    .{ "$bitstoreal", .bitstoreal },         .{ "$random", .random },     .{ "$test$plusargs", .test_plusargs },
    .{ "$value$plusargs", .value_plusargs }, .{ "$ln", .ln },             .{ "$log10", .log10 },
    .{ "$exp", .exp },                       .{ "$sqrt", .sqrt },         .{ "$floor", .floor },
    .{ "$ceil", .ceil },                     .{ "$sin", .sin },           .{ "$cos", .cos },
    .{ "$tan", .tan },                       .{ "$asin", .asin },         .{ "$acos", .acos },
    .{ "$atan", .atan },                     .{ "$sinh", .sinh },         .{ "$cosh", .cosh },
    .{ "$tanh", .tanh },                     .{ "$asinh", .asinh },       .{ "$acosh", .acosh },
    .{ "$atanh", .atanh },                   .{ "$pow", .pow },           .{ "$atan2", .atan2 },
    .{ "$hypot", .hypot },
});

pub fn sysType(l: *Lower, i: Inst.Index) Error!Type {
    const vir = l.virOf(l.frame);
    const s = try sysOf(l, vir, i);
    for (s.args) |a| if (a == .none) return l.refuse("an omitted system function argument");
    return switch (s.f) {
        .time => .{ .width = 64, .signed = false },
        .stime => .{ .width = 32, .signed = false },
        .realtime, .itor, .bitstoreal => Type.real_type,
        .signed, .unsigned => blk: {
            if (s.args.len != 1) return l.refuse("$signed/$unsigned without one argument");
            const t = try expr.typeValue(l, s.args[0]);
            if (t.real) return l.refuse("$signed of a real");
            break :blk .{ .width = t.width, .signed = s.f == .signed };
        },
        .clog2, .rtoi, .random, .test_plusargs, .value_plusargs => .{ .width = 32, .signed = true },
        .realtobits => .{ .width = 64, .signed = false },
        else => Type.real_type, // else: §17.11.2 Table 17-17's math functions
    };
}

pub fn sysCall(l: *Lower, i: Inst.Index, t: Ty, nat: Type) Error!u32 {
    const vir = l.virOf(l.frame);
    const s = try sysOf(l, vir, i);
    const natural = try l.tyOf(nat);
    const scope = l.frames.items[l.frame].scope;
    const raw: u32 = switch (s.f) {
        .signed, .unsigned => return l.b.expr(.convert, t, try expr.self_(l, s.args[0], 0), if (s.f == .signed) 2 else 1),
        .rtoi => try l.b.expr(.rtoi, Ty.int(32, true), try expr.real(l, s.args[0]), 0),
        .realtobits => try l.b.expr(.realtobits, Ty.int(64, false), try expr.real(l, s.args[0]), 0),
        .time => try l.b.expr(.time, natural, scope, 0),
        .stime => try l.b.expr(.stime, natural, scope, 0),
        .clog2 => try l.b.expr(.clog2, Ty.int(32, true), try expr.self_(l, s.args[0], 0), 0),
        // §17.10: a run is given no plusargs, so no query matches.
        .test_plusargs, .value_plusargs => try l.b.int(natural, 0),
        .random => blk: {
            if (s.args.len != 0) return l.refuse("a seeded $random");
            const rnd = try l.b.extraOf(Program.Random{ .dist = .random, .seed = none, .place = none, .ty = .bit, .x = none, .y = none });
            break :blk try l.b.expr(.random, natural, rnd, 0);
        },
        else => return l.refuseFmt("the system function `{t}` in an integral context", .{s.f}), // else: the real ones reach `sysReal`
    };
    return l.b.expr(.convert, t, raw, 0);
}

pub fn sysReal(l: *Lower, i: Inst.Index) Error!u32 {
    const vir = l.virOf(l.frame);
    const s = try sysOf(l, vir, i);
    const rt = Ty.real_ty;
    const scope = l.frames.items[l.frame].scope;
    return switch (s.f) {
        .realtime => l.b.expr(.realtime, rt, scope, 0),
        .itor => if ((try expr.typeOf(l, s.args[0])).real) l.b.expr(.math1, rt, try expr.real(l, s.args[0]), @backingInt(Program.Math.itor)) else l.b.expr(.real_of_int, rt, try expr.self_(l, s.args[0], 0), 0),
        .bitstoreal => l.b.expr(.bitstoreal, rt, try expr.self_(l, s.args[0], 64), 0),
        inline .ln, .log10, .exp, .sqrt, .floor, .ceil, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => |m| blk: {
            if (s.args.len != 1) return l.refuse("a math function with the wrong argument count");
            break :blk l.b.expr(.math1, rt, try expr.real(l, s.args[0]), @backingInt(@field(Program.Math, @tagName(m))));
        },
        inline .pow, .atan2, .hypot => |m| blk: {
            if (s.args.len != 2) return l.refuse("a math function with the wrong argument count");
            const pair = try l.b.listOf(&.{ try expr.real(l, s.args[0]), try expr.real(l, s.args[1]) });
            break :blk l.b.expr(.math2, rt, pair.start, @backingInt(@field(Program.Math, @tagName(m))));
        },
        else => l.refuseFmt("the system function `{t}` in a real context", .{s.f}), // else: the integral ones reach `sysCall`
    };
}

// ---- private ----

fn sysOf(l: *Lower, vir: *const Vir, i: Inst.Index) Error!struct { f: SysFn, args: []const Inst.Ref } {
    const c = Lower.payload(vir, Inst.SysCall, i);
    const name = vir.string(c.name);
    const f = sys_fns.get(name) orelse return l.refuseFmt("the system function `{s}`", .{name});
    return .{ .f = f, .args = vir.list(Inst.Ref, c.args) };
}
