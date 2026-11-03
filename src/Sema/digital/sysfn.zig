//! System functions of the digital lowering: a `call_sys` in an
//! expression, in `Lower.frame`, -> its `Program.exprs` row in its §17
//! natural type (`sysType`), converted to the context (`sysCall`), or as a
//! real (`sysReal`). §17.2's file functions and scans write their outputs
//! through `Program.Place` rows.
//! Cites: IEEE 1364-2005 §17.2.1, §17.2.4, §17.2.5, §17.2.7, §17.7, §17.8,
//! §17.9, §17.10, §17.11.
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
const place = @import("place.zig");
const task = @import("task.zig");
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
const SysFn = enum { time, stime, realtime, signed, unsigned, clog2, rtoi, itor, realtobits, bitstoreal, random, test_plusargs, value_plusargs, ln, log10, exp, sqrt, floor, ceil, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, asinh, acosh, atanh, pow, atan2, hypot, fopen, fgets, ferror, fgetc, ungetc, ftell, rewind, fseek, feof, sscanf, fscanf, fread, dist_uniform, dist_normal, dist_exponential, dist_poisson, dist_chi_square, dist_t, dist_erlang, q_full };

const sys_fns = std.StaticStringMap(SysFn).initComptime(.{
    .{ "$time", .time },                         .{ "$stime", .stime },               .{ "$realtime", .realtime },
    .{ "$signed", .signed },                     .{ "$unsigned", .unsigned },         .{ "$clog2", .clog2 },
    .{ "$rtoi", .rtoi },                         .{ "$itor", .itor },                 .{ "$realtobits", .realtobits },
    .{ "$bitstoreal", .bitstoreal },             .{ "$random", .random },             .{ "$test$plusargs", .test_plusargs },
    .{ "$value$plusargs", .value_plusargs },     .{ "$ln", .ln },                     .{ "$log10", .log10 },
    .{ "$exp", .exp },                           .{ "$sqrt", .sqrt },                 .{ "$floor", .floor },
    .{ "$ceil", .ceil },                         .{ "$sin", .sin },                   .{ "$cos", .cos },
    .{ "$tan", .tan },                           .{ "$asin", .asin },                 .{ "$acos", .acos },
    .{ "$atan", .atan },                         .{ "$sinh", .sinh },                 .{ "$cosh", .cosh },
    .{ "$tanh", .tanh },                         .{ "$asinh", .asinh },               .{ "$acosh", .acosh },
    .{ "$atanh", .atanh },                       .{ "$pow", .pow },                   .{ "$atan2", .atan2 },
    .{ "$hypot", .hypot },                       .{ "$fopen", .fopen },               .{ "$fgets", .fgets },
    .{ "$ferror", .ferror },                     .{ "$fgetc", .fgetc },               .{ "$ungetc", .ungetc },
    .{ "$ftell", .ftell },                       .{ "$rewind", .rewind },             .{ "$fseek", .fseek },
    .{ "$feof", .feof },                         .{ "$sscanf", .sscanf },             .{ "$fscanf", .fscanf },
    .{ "$fread", .fread },                       .{ "$dist_uniform", .dist_uniform }, .{ "$dist_normal", .dist_normal },
    .{ "$dist_exponential", .dist_exponential }, .{ "$dist_poisson", .dist_poisson }, .{ "$dist_chi_square", .dist_chi_square },
    .{ "$dist_t", .dist_t },                     .{ "$dist_erlang", .dist_erlang },   .{ "$q_full", .q_full },
});

pub fn sysType(l: *Lower, i: Inst.Index) Error!Type {
    const vir = l.virOf(l.frame);
    const s = try sysOf(l, vir, i);
    // §17.2.4.4 `$fread(mem, fd, , count)` omits its start.
    for (s.args, 0..) |a, k| if (a == .none and !(s.f == .fread and k == 2)) return l.refuse("an omitted system function argument");
    return switch (s.f) {
        // §17.2.1 a descriptor is 32 bits, its MSB set for an `fd`.
        .fopen => .{ .width = 32, .signed = false },
        .fgets, .ferror, .fgetc, .ungetc, .ftell, .rewind, .fseek, .feof, .sscanf, .fscanf, .fread, .q_full => .{ .width = 32, .signed = true },
        .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => .{ .width = 32, .signed = true },
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
        .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => try l.b.expr(.random, natural, try random(l, s.f, s.args), 0),
        .fopen, .fgets, .ferror, .fgetc, .ungetc, .ftell, .rewind, .fseek, .feof => try l.b.expr(.file, natural, try fileCall(l, s.f, s.args), 0),
        .sscanf, .fscanf => blk: {
            if (s.args.len < 2) return l.refuse("a scan with no format");
            var outs: std.ArrayList(u32) = .empty;
            for (s.args[2..]) |o| {
                const tt = try place.targetType(l, o);
                try outs.appendSlice(l.a, &.{ try place.place(l, o), @bitCast(try l.tyOf(tt)), tt.width });
            }
            var path: std.ArrayList(u8) = .empty;
            try task.scopePath(l, scope, &path, 0);
            const c = try l.b.extraOf(Program.ScanCall{ .src = try expr.self_(l, s.args[0], 0), .format = try expr.self_(l, s.args[1], 0), .outs = try l.b.listOf(outs.items), .module = try l.b.string(path.items), .scope = scope });
            break :blk try l.b.expr(.scan, natural, c, @intFromBool(s.f == .fscanf));
        },
        .fread => try l.b.expr(.fread, natural, try fread(l, s.args), 0),
        .q_full => try l.b.expr(.q_full, natural, try task.queueCall(l, .initialize, s.args, &.{ false, true, false, false }), 0),
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

/// §17.9 a `$random` or `$dist_*` call: its seed (an inout variable written
/// back; none for a seedless `$random`) and its two parameters.
fn random(l: *Lower, f: SysFn, args: []const Inst.Ref) Error!u32 {
    const dist: Program.Dist = switch (f) {
        .random => .random,
        .dist_uniform => .uniform,
        .dist_normal => .normal,
        .dist_exponential => .exponential,
        .dist_poisson => .poisson,
        .dist_chi_square => .chi_square,
        .dist_t => .t,
        else => .erlang, // else: the last distribution
    };
    if (args.len > 3) return l.refuse("a $dist_ call with more than three arguments");
    const seeded = args.len != 0;
    return l.b.extraOf(Program.Random{
        .dist = dist,
        .seed = if (seeded) try expr.self_(l, args[0], 0) else none,
        .place = if (seeded) try place.place(l, args[0]) else none,
        .ty = if (seeded) try l.tyOf(try place.targetType(l, args[0])) else .bit,
        .x = if (args.len > 1) try expr.self_(l, args[1], 0) else none,
        .y = if (args.len > 2) try expr.self_(l, args[2], 0) else none,
    });
}

/// §17.2 a file function's `Program.FileCall`: `$fgets` and `$ferror` write
/// a string to a place, the rest take their arguments in order.
fn fileCall(l: *Lower, f: SysFn, args: []const Inst.Ref) Error!u32 {
    var c: Program.FileCall = .{ .op = std.meta.stringToEnum(Program.FileOp, @tagName(f)).?, .x = none, .y = none, .z = none, .place = none, .ty = .bit };
    switch (f) {
        .fgets => {
            if (args.len != 2) return l.refuse("$fgets without two arguments");
            c.place = try place.place(l, args[0]);
            c.ty = try l.tyOf(try place.targetType(l, args[0]));
            c.x = try expr.self_(l, args[1], 0);
        },
        .ferror => {
            if (args.len != 2) return l.refuse("$ferror without two arguments");
            c.x = try expr.self_(l, args[0], 0);
            c.place = try place.place(l, args[1]);
            c.ty = try l.tyOf(try place.targetType(l, args[1]));
        },
        else => for (args, 0..) |a, k| { // else: the rest take their arguments in order
            const row = try expr.self_(l, a, 0);
            switch (k) {
                0 => c.x = row,
                1 => c.y = row,
                2 => c.z = row,
                else => return l.refuse("a file function with more than three arguments"),
            }
        },
    }
    return l.b.extraOf(c);
}

/// §17.2.4.4 `$fread` into a variable, or into a one-dimensional memory from
/// its optional start for its optional count.
fn fread(l: *Lower, args: []const Inst.Ref) Error!u32 {
    if (args.len < 2 or args.len > 4) return l.refuse("$fread with other than two to four arguments");
    var fr: Program.Fread = .{ .fd = try expr.self_(l, args[1], 0), .place = none, .ty = .bit, .prior = none, .base = none, .low = 0, .high = 0, .start = none, .count = none };
    const n = try expr.nameOf(l, args[0]);
    if (n != null and n.?.dims.len != 0) {
        const m = n.?;
        if (m.dims.len != 1) return l.refuse("§17.2.4.4 $fread into a memory of more than one dimension");
        fr.base = m.slot;
        fr.low = m.dims[0].low;
        fr.high = m.dims[0].high;
        if (args.len > 2 and args[2] != .none) fr.start = try expr.self_(l, args[2], 0);
        if (args.len > 3) fr.count = try expr.self_(l, args[3], 0);
    } else {
        const tt = try place.targetType(l, args[0]);
        fr.place = try place.place(l, args[0]);
        fr.ty = try l.tyOf(tt);
        fr.prior = try expr.self_(l, args[0], tt.width);
    }
    return l.b.extraOf(fr);
}

fn sysOf(l: *Lower, vir: *const Vir, i: Inst.Index) Error!struct { f: SysFn, args: []const Inst.Ref } {
    const c = Lower.payload(vir, Inst.SysCall, i);
    const name = vir.string(c.name);
    const f = sys_fns.get(name) orelse return l.refuseFmt("the system function `{s}`", .{name});
    return .{ .f = f, .args = vir.list(Inst.Ref, c.args) };
}
