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
const kernels = @import("kernels");
const digital = @import("../digital.zig");
const expr = @import("expr.zig");
const place = @import("place.zig");
const task = @import("task.zig");
const drivers = @import("drivers.zig");
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
const SysFn = enum { time, stime, realtime, abstime, ln1p, expm1, signed, unsigned, clog2, rtoi, itor, realtobits, bitstoreal, random, test_plusargs, value_plusargs, ln, log10, exp, sqrt, floor, ceil, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, asinh, acosh, atanh, pow, atan2, hypot, fopen, fgets, ferror, fgetc, ungetc, ftell, rewind, fseek, feof, sscanf, fscanf, fread, dist_uniform, dist_normal, dist_exponential, dist_poisson, dist_chi_square, dist_t, dist_erlang, q_full, driver_count, receiver_count, driver_state, driver_strength, driver_delay, driver_next_state, driver_next_strength, driver_type };

const sys_fns = std.StaticStringMap(SysFn).initComptime(.{
    .{ "$time", .time },                                 .{ "$stime", .stime },                   .{ "$realtime", .realtime },
    .{ "$signed", .signed },                             .{ "$unsigned", .unsigned },             .{ "$clog2", .clog2 },
    .{ "$rtoi", .rtoi },                                 .{ "$itor", .itor },                     .{ "$realtobits", .realtobits },
    .{ "$bitstoreal", .bitstoreal },                     .{ "$random", .random },                 .{ "$test$plusargs", .test_plusargs },
    .{ "$value$plusargs", .value_plusargs },             .{ "$ln", .ln },                         .{ "$log10", .log10 },
    .{ "$exp", .exp },                                   .{ "$sqrt", .sqrt },                     .{ "$floor", .floor },
    .{ "$ceil", .ceil },                                 .{ "$sin", .sin },                       .{ "$cos", .cos },
    .{ "$tan", .tan },                                   .{ "$asin", .asin },                     .{ "$acos", .acos },
    .{ "$atan", .atan },                                 .{ "$sinh", .sinh },                     .{ "$cosh", .cosh },
    .{ "$tanh", .tanh },                                 .{ "$asinh", .asinh },                   .{ "$acosh", .acosh },
    .{ "$atanh", .atanh },                               .{ "$pow", .pow },                       .{ "$atan2", .atan2 },
    .{ "$hypot", .hypot },                               .{ "$fopen", .fopen },                   .{ "$fgets", .fgets },
    .{ "$ferror", .ferror },                             .{ "$fgetc", .fgetc },                   .{ "$ungetc", .ungetc },
    .{ "$ftell", .ftell },                               .{ "$rewind", .rewind },                 .{ "$fseek", .fseek },
    .{ "$feof", .feof },                                 .{ "$sscanf", .sscanf },                 .{ "$fscanf", .fscanf },
    .{ "$fread", .fread },                               .{ "$dist_uniform", .dist_uniform },     .{ "$dist_normal", .dist_normal },
    .{ "$dist_exponential", .dist_exponential },         .{ "$dist_poisson", .dist_poisson },     .{ "$dist_chi_square", .dist_chi_square },
    .{ "$dist_t", .dist_t },                             .{ "$dist_erlang", .dist_erlang },       .{ "$q_full", .q_full },
    // VAMS §9.10 Table 9-7 and §4.3.2 Table 4-15, in a digital process too.
    .{ "$abstime", .abstime },                           .{ "$ln1p", .ln1p },                     .{ "$expm1", .expm1 },
    // VAMS §9.22/§9.23 driver access, in a connect module (`drivers.zig`).
    .{ "$driver_count", .driver_count },                 .{ "$receiver_count", .receiver_count }, .{ "$driver_state", .driver_state },
    .{ "$driver_strength", .driver_strength },           .{ "$driver_delay", .driver_delay },     .{ "$driver_next_state", .driver_next_state },
    .{ "$driver_next_strength", .driver_next_strength }, .{ "$driver_type", .driver_type },
});

pub fn sysType(l: *Lower, i: Inst.Index) Error!Type {
    const vir = l.virOf(l.frame);
    const s = try sysOf(l, vir, i);
    // §17.2.4.4 `$fread(mem, fd, , count)` omits its start.
    try argumentForms(l, i, s.f, s.args);
    for (s.args, 0..) |a, k| if (a == .none and !(s.f == .fread and k == 2)) return l.refuse("an omitted system function argument");
    return switch (s.f) {
        // §17.2.1 a descriptor is 32 bits, its MSB set for an `fd`.
        .fopen => .{ .width = 32, .signed = false },
        .fgets, .ferror, .fgetc, .ungetc, .ftell, .rewind, .fseek, .feof, .sscanf, .fscanf, .fread, .q_full => .{ .width = 32, .signed = true },
        .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => .{ .width = 32, .signed = true },
        .time => .{ .width = 64, .signed = false },
        .stime => .{ .width = 32, .signed = false },
        .realtime, .abstime, .itor, .bitstoreal => Type.real_type,
        .signed, .unsigned => blk: {
            if (s.args.len != 1) return l.refuse("$signed/$unsigned without one argument");
            const t = try expr.typeValue(l, s.args[0]);
            if (t.real) return l.refuse("$signed of a real");
            break :blk .{ .width = t.width, .signed = s.f == .signed };
        },
        .clog2, .rtoi, .random, .test_plusargs, .value_plusargs => .{ .width = 32, .signed = true },
        .realtobits => .{ .width = 64, .signed = false },
        .driver_count, .receiver_count, .driver_strength, .driver_next_strength, .driver_type => .{ .width = 32, .signed = true },
        .driver_state, .driver_next_state => .{ .width = 1, .signed = false },
        else => Type.real_type, // else: §17.11.2 Table 17-17's math functions, `$driver_delay`
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
        // §9.22.1/§9.22.2 fixed at elaboration: the drivers and receivers.
        .driver_count => try l.b.int(natural, drivers.count(l, (try drivers.check(l, i, .count, s.args)).net)),
        .receiver_count => try l.b.int(natural, drivers.receiverCount(l, (try drivers.check(l, i, .receiver_count, s.args)).net)),
        .driver_state, .driver_strength, .driver_next_state, .driver_next_strength, .driver_type => return l.refuse("a §9.22 driver state function"),
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
        .abstime => l.b.expr(.abstime, rt, 0, 0),
        .itor => if ((try expr.typeOf(l, s.args[0])).real) l.b.expr(.math1, rt, try expr.real(l, s.args[0]), @backingInt(Program.Math.itor)) else l.b.expr(.real_of_int, rt, try expr.self_(l, s.args[0], 0), 0),
        .bitstoreal => l.b.expr(.bitstoreal, rt, try expr.self_(l, s.args[0], 64), 0),
        inline .ln, .log10, .exp, .ln1p, .expm1, .sqrt, .floor, .ceil, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => |m| blk: {
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

/// §17's argument forms lib/sim/digital checks before any process runs.
fn argumentForms(l: *Lower, i: Inst.Index, f: SysFn, args: []const Inst.Ref) Error!void {
    const at = i.toRef();
    const one = args.len == 1 and args[0] != .none;
    switch (f) {
        // §17.6.4 `$q_full(q_id, status)`.
        .q_full => if (args.len != 2 or args[0] == .none or args[1] == .none) return l.reject(l.frame, at, "$q_full takes (q_id, status)"),
        .time, .stime => if (args.len != 0) return l.reject(l.frame, at, "$time and $stime take no arguments"),
        .realtime, .abstime => if (args.len != 0) return l.reject(l.frame, at, "$realtime and $abstime take no arguments"),
        .rtoi, .itor, .realtobits, .bitstoreal => if (!one) return l.reject(l.frame, at, "a §17.8 conversion takes exactly one argument"),
        .clog2 => {
            if (!one) return l.reject(l.frame, at, "$clog2 takes exactly one argument");
            if ((try expr.typeValue(l, args[0])).real) return l.rejectArg(l.frame, i, 0, "§17.11.1: $clog2 takes an integer or vector argument, not a real");
        },
        .test_plusargs, .value_plusargs => {
            const want: usize = if (f == .test_plusargs) 1 else 2;
            if (args.len != want or args[0] == .none) return l.reject(l.frame, at, "$test$plusargs takes (string) and $value$plusargs (format, variable)");
            // §17.10.1 "either a string or a nonreal variable".
            if ((try expr.typeValue(l, args[0])).real) return l.rejectArg(l.frame, i, 0, "§17.10: the plusarg string is a string or a nonreal variable");
            // §17.10.2: "%d %o %h %b %e %f %g %s" (either case, a leading 0 allowed) are "the only valid ones".
            if (f == .value_plusargs) if (literal(l, args[0])) |text| {
                var k: usize = 0;
                while (std.mem.findScalarPos(u8, text, k, '%')) |pct| {
                    k = pct + 1;
                    while (k < text.len and text[k] == '0') k += 1;
                    if (k == text.len or std.mem.findScalar(u8, "dohbefgsDOHBEFGS", text[k]) == null)
                        return l.rejectArgFmt(l.frame, i, 0, "§17.10.2: a $value$plusargs format is one of %d %o %h %b %e %f %g %s, not `%{s}`", .{text[@min(k, text.len)..@min(k + 1, text.len)]});
                }
            };
        },
        // §17.2.1 "The type is a character string ... of one of the forms in Table 17-7".
        .fopen => if (args.len == 2) if (literal(l, args[1])) |ty| if (!kernels.fopen_types.has(ty))
            return l.rejectArg(l.frame, i, 1, "§17.2.1: an $fopen type is one of Table 17-7's r, w, a, r+, w+, a+ (with b)"),
        .driver_count, .receiver_count, .driver_state, .driver_strength, .driver_delay, .driver_next_state, .driver_next_strength, .driver_type => _ = try drivers.check(l, i, switch (f) {
            .driver_count => .count,
            .receiver_count => .receiver_count,
            .driver_state => .state,
            .driver_strength => .strength,
            .driver_delay => .delay,
            .driver_next_state => .next_state,
            .driver_next_strength => .next_strength,
            else => .type, // else: `$driver_type`, the last
        }, args),
        else => {}, // else: checked where lowered
    }
}

/// The text of string literal `r`, or null when `r` is no literal.
fn literal(l: *Lower, r: Inst.Ref) ?[]const u8 {
    const vir = l.virOf(l.frame);
    const i = r.toIndex() orelse return null;
    if (Lower.tag(vir, i) != .str) return null;
    const sd = vir.instructions.items(.data)[@backingInt(i)].str;
    return vir.string_bytes[@backingInt(sd.start)..][0..sd.len];
}

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
