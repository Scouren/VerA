//! The one table of system functions and built-ins (Zig's
//! `lib/std/zig/BuiltinFn.zig`): a call's spelling in (`$strobe`, `ddt`,
//! `exp`), its `Tag` and the facts every stage switches on out, instead of
//! comparing strings: the value type, the source arity, the family (a §9.4
//! display, a §9.5 file task, a §4.5 analog operator, ...), the contexts it
//! may be called in (§7.2.2), and the §4.3 math function it is. `table` is
//! an `EnumArray`, so a new tag does not compile until its row exists. A
//! spelling no row names is a §2.8.3 user system function (`fromName` null).
//! Replaces the old `src/ir/callee.zig`, `callee_table.zig`,
//! `src/analog/math.zig`'s maps and `sysfunc_context.zig`'s name sets.
//! Cites: VAMS-2023 §4.3 (Tables 4-14, 4-15), §4.5 (Table 4-19), §4.5.13,
//! §4.5.14, §4.6, §4.6.3, §4.6.4, §5.10.3, §7.2.2, §9.4, §9.5, §9.7, §9.10,
//! §9.11, §9.12, §9.13, §9.14, §9.15, §9.17, §9.18, §9.19, §9.20, §9.21;
//! IEEE 1364-2005 §17.9, §17.10.2, §17.11.
//!
//! Contents:
//! - `pub const Tag = enum(u8)` (`fromName`)
//! - `pub const Ty`, `pub const Arity` (`exactly`, `admits`), `pub const Family`, `pub const Context`, `pub const Math`
//! - `pub const Info = struct`
//! - `pub const foreign: std.StaticStringMap(Context)`
//! - `pub const table: std.EnumArray(Tag, Info)`
//! - `pub fn get(tag: Tag) *const Info`

const std = @import("std");
const assert = std.debug.assert;

/// A system function or built-in; `@tagName` is its spelling.
pub const Tag = enum(u8) {
    // §4.5 analog operators (Table 4-19), §4.5.13 limexp, §4.5.14 ddx.
    ddt,
    idt,
    idtmod,
    absdelay,
    transition,
    slew,
    last_crossing,
    laplace_zd,
    laplace_zp,
    laplace_nd,
    laplace_np,
    zi_zd,
    zi_zp,
    zi_nd,
    zi_np,
    limexp,
    ddx,
    // §5.10.3 monitored events.
    cross,
    above,
    timer,
    initial_step,
    final_step,
    // §4.6 analysis-dependent functions, §4.6.3 ac_stim, §4.6.4 noise.
    analysis,
    ac_stim,
    white_noise,
    flicker_noise,
    noise_table,
    noise_table_log,
    // §5.5.1 the generic access functions.
    potential,
    flow,
    // §4.3.1 Table 4-14 and §4.3.2 Table 4-15.
    sqrt,
    exp,
    expm1,
    ln,
    ln1p,
    log,
    pow,
    hypot,
    floor,
    ceil,
    abs,
    min,
    max,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    atan2,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    // §9.10/§9.15/§9.18/§9.19/§9.20 environment, simulator and module queries.
    @"$temperature",
    @"$vt",
    @"$mfactor",
    @"$abstime",
    @"$realtime",
    @"$simparam",
    @"$simparam$str",
    @"$param_given",
    @"$port_connected",
    @"$analog_node_alias",
    @"$analog_port_alias",
    @"$test$plusargs",
    @"$value$plusargs",
    @"$xposition",
    @"$yposition",
    @"$angle",
    @"$hflip",
    @"$vflip",
    // §9.11 conversions, §9.14 $clog2.
    @"$rtoi",
    @"$itor",
    @"$realtobits",
    @"$bitstoreal",
    @"$clog2",
    // IEEE 1364-2005 §17.11 the `$` spellings of Tables 4-14/4-15.
    @"$sqrt",
    @"$exp",
    @"$expm1",
    @"$ln",
    @"$ln1p",
    @"$log",
    @"$log10",
    @"$floor",
    @"$ceil",
    @"$sin",
    @"$cos",
    @"$tan",
    @"$asin",
    @"$acos",
    @"$atan",
    @"$sinh",
    @"$cosh",
    @"$tanh",
    @"$asinh",
    @"$acosh",
    @"$atanh",
    @"$pow",
    @"$hypot",
    @"$atan2",
    // §9.4 display, §9.7 simulation control and severity.
    @"$display",
    @"$displayb",
    @"$displayo",
    @"$displayh",
    @"$write",
    @"$writeb",
    @"$writeo",
    @"$writeh",
    @"$strobe",
    @"$strobeb",
    @"$strobeo",
    @"$strobeh",
    @"$monitor",
    @"$monitoron",
    @"$monitoroff",
    @"$debug",
    @"$fatal",
    @"$error",
    @"$warning",
    @"$info",
    @"$finish",
    @"$stop",
    // §9.5 files.
    @"$fopen",
    @"$fclose",
    @"$fflush",
    @"$fdisplay",
    @"$fwrite",
    @"$fstrobe",
    @"$fmonitor",
    @"$fdebug",
    @"$fgets",
    @"$fscanf",
    @"$ftell",
    @"$fseek",
    @"$rewind",
    @"$ferror",
    @"$feof",
    // §9.5.3/§9.5.4.2 strings.
    @"$sformat",
    @"$swrite",
    @"$sscanf",
    // §9.13 random numbers (IEEE 1364-2005 §17.9).
    @"$random",
    @"$arandom",
    @"$dist_uniform",
    @"$dist_normal",
    @"$dist_exponential",
    @"$dist_poisson",
    @"$dist_chi_square",
    @"$dist_t",
    @"$dist_erlang",
    @"$rdist_uniform",
    @"$rdist_normal",
    @"$rdist_exponential",
    @"$rdist_poisson",
    @"$rdist_chi_square",
    @"$rdist_t",
    @"$rdist_erlang",
    // §9.17 limiting and step control, §9.21 table model, VerA's reject task.
    @"$bound_step",
    @"$discontinuity",
    @"$limit",
    @"$table_model",
    @"$vera_reject_step",
    // VerA-synthetic, never a source spelling: §4.5.4 `idt`'s static-point
    // flag and its held form.
    @"op$static",
    @"idt$hold",

    /// The tag `spelling` names, or null for a user system function.
    pub fn fromName(spelling: []const u8) ?Tag {
        const t = std.meta.stringToEnum(Tag, spelling) orelse return null;
        assert(std.mem.eql(u8, @tagName(t), spelling));
        return t;
    }
};

/// A call's value type; `none` for a task.
pub const Ty = enum(u8) { real, int, str, none };

/// How many arguments the source may pass; `max` at its type's ceiling is
/// "no upper bound" (a display's open list).
pub const Arity = struct {
    min: u8 = 0,
    max: u8 = std.math.maxInt(u8),

    /// Exactly `n`. Asserts `n` is below the ceiling.
    pub fn exactly(n: u8) Arity {
        assert(n < std.math.maxInt(u8));
        return .{ .min = n, .max = n };
    }

    /// Whether `n` arguments are admitted.
    pub fn admits(a: Arity, n: usize) bool {
        assert(a.min <= a.max);
        return n >= a.min and (a.max == std.math.maxInt(u8) or n <= a.max);
    }
};

/// What a call does, for the code that routes it.
pub const Family = enum(u8) {
    /// A §4.3 math function: `Info.math` names it.
    math,
    /// A §4.5 analog operator or §4.6.4 noise source: owns per-instance state.
    analog_op,
    /// A §5.10.3 monitored event.
    event,
    /// A query of the simulator, the environment or the module.
    query,
    /// A §9.11/§9.14 conversion.
    convert,
    /// A §9.4 display or §9.7 severity task.
    display,
    /// A §9.7 simulation control task.
    simctl,
    /// A §9.5 file task that writes, or a §9.5 file function.
    file_out,
    file_func,
    /// A §9.5.3/§9.5.4.2 string task.
    string,
    /// A §9.13 random number.
    random,
    /// §9.17 step control and limiting, §9.21 table model.
    kernel,
};

/// The contexts a call may stand in (§7.2.2, §9.2, §9.22); `connect` is a
/// connect module's digital context only.
pub const Context = enum(u8) { both, analog, digital, connect };

/// §4.3 the math functions a call computes, one per Table 4-14/4-15 row.
pub const Math = enum(u8) { sqrt, exp, expm1, ln, ln1p, log10, pow, hypot, floor, ceil, abs, min, max, sin, cos, tan, asin, acos, atan, atan2, sinh, cosh, tanh, asinh, acosh, atanh };

/// One row of `table`.
pub const Info = struct {
    ty: Ty,
    args: Arity = .{},
    family: Family,
    context: Context = .both,
    /// The §4.3 function a `math` row computes.
    math: ?Math = null,
};

/// The calls of the other contexts no row names, by spelling: §9.2 Tables
/// 9-19/9-20's digital-only tasks and functions (an analog call is E0806)
/// and §9.22's driver access functions, a connect module's only (E0818).
/// Nothing lowers them, so they have no `Tag`.
pub const foreign = std.StaticStringMap(Context).initComptime(pairs(.digital, &.{
    "$monitorb",         "$monitorh",         "$monitoro",        "$fdisplayb",
    "$fdisplayh",        "$fdisplayo",        "$fwriteb",         "$fwriteh",
    "$fwriteo",          "$fstrobeb",         "$fstrobeh",        "$fstrobeo",
    "$fmonitorb",        "$fmonitorh",        "$fmonitoro",       "$swriteb",
    "$swriteh",          "$swriteo",          "$fgetc",           "$ungetc",
    "$fread",            "$readmemb",         "$readmemh",        "$sdf_annotate",
    "$printtimescale",   "$timeformat",       "$async$and$array", "$async$and$plane",
    "$async$nand$array", "$async$nand$plane", "$async$or$array",  "$async$or$plane",
    "$async$nor$array",  "$async$nor$plane",  "$sync$and$array",  "$sync$and$plane",
    "$sync$nand$array",  "$sync$nand$plane",  "$sync$or$array",   "$sync$or$plane",
    "$sync$nor$array",   "$sync$nor$plane",   "$q_initialize",    "$q_remove",
    "$q_exam",           "$q_add",            "$q_full",          "$time",
    "$stime",            "$signed",           "$unsigned",
}) ++ pairs(.connect, &.{
    "$driver_count", "$receiver_count",    "$driver_state",         "$driver_strength",
    "$driver_delay", "$driver_next_state", "$driver_next_strength", "$driver_type",
}));

/// Per-tag facts, total over `Tag`.
pub const table = std.EnumArray(Tag, Info).init(.{
    .ddt = op(.{ .min = 1, .max = 2 }),
    .idt = op(.{ .min = 1, .max = 4 }),
    .idtmod = op(.{ .min = 1, .max = 5 }),
    .absdelay = op(.{ .min = 2, .max = 3 }),
    .transition = op(.{ .min = 1, .max = 5 }),
    .slew = op(.{ .min = 1, .max = 3 }),
    .last_crossing = op(.{ .min = 1, .max = 2 }),
    .laplace_zd = op(.{ .min = 3, .max = 4 }),
    .laplace_zp = op(.{ .min = 3, .max = 4 }),
    .laplace_nd = op(.{ .min = 3, .max = 4 }),
    .laplace_np = op(.{ .min = 3, .max = 4 }),
    .zi_zd = op(.{ .min = 4, .max = 6 }),
    .zi_zp = op(.{ .min = 4, .max = 6 }),
    .zi_nd = op(.{ .min = 4, .max = 6 }),
    .zi_np = op(.{ .min = 4, .max = 6 }),
    .limexp = .{ .ty = .real, .args = .exactly(1), .family = .analog_op, .context = .analog },
    .ddx = .{ .ty = .real, .args = .exactly(2), .family = .analog_op, .context = .analog },
    .cross = .{ .ty = .int, .args = .{ .max = 5 }, .family = .event, .context = .analog },
    .above = .{ .ty = .int, .args = .{ .max = 4 }, .family = .event, .context = .analog },
    .timer = .{ .ty = .int, .args = .{ .min = 1, .max = 4 }, .family = .event, .context = .analog },
    .initial_step = .{ .ty = .int, .family = .event, .context = .analog },
    .final_step = .{ .ty = .int, .family = .event, .context = .analog },
    .analysis = .{ .ty = .int, .args = .{ .min = 1 }, .family = .query, .context = .analog },
    .ac_stim = op(.{ .max = 3 }),
    .white_noise = op(.{ .min = 1, .max = 2 }),
    .flicker_noise = op(.{ .min = 2, .max = 3 }),
    .noise_table = op(.{ .min = 1, .max = 2 }),
    .noise_table_log = op(.{ .min = 1, .max = 2 }),
    .potential = .{ .ty = .real, .args = .{ .min = 1, .max = 2 }, .family = .query, .context = .analog },
    .flow = .{ .ty = .real, .args = .{ .min = 1, .max = 2 }, .family = .query, .context = .analog },
    .sqrt = math1(.sqrt),
    .exp = math1(.exp),
    .expm1 = math1(.expm1),
    .ln = math1(.ln),
    .ln1p = math1(.ln1p),
    .log = math1(.log10),
    .pow = math2(.pow),
    .hypot = math2(.hypot),
    .floor = math1(.floor),
    .ceil = math1(.ceil),
    .abs = math1(.abs),
    .min = math2(.min),
    .max = math2(.max),
    .sin = math1(.sin),
    .cos = math1(.cos),
    .tan = math1(.tan),
    .asin = math1(.asin),
    .acos = math1(.acos),
    .atan = math1(.atan),
    .atan2 = math2(.atan2),
    .sinh = math1(.sinh),
    .cosh = math1(.cosh),
    .tanh = math1(.tanh),
    .asinh = math1(.asinh),
    .acosh = math1(.acosh),
    .atanh = math1(.atanh),
    .@"$temperature" = query(.real, .exactly(0)),
    .@"$vt" = query(.real, .{ .max = 1 }),
    .@"$mfactor" = query(.real, .exactly(0)),
    .@"$abstime" = query(.real, .exactly(0)),
    .@"$realtime" = .{ .ty = .real, .args = .{ .max = 1 }, .family = .query, .context = .digital },
    .@"$simparam" = query(.real, .{ .min = 1, .max = 2 }),
    .@"$simparam$str" = query(.str, .{ .min = 1, .max = 2 }),
    .@"$param_given" = query(.int, .exactly(1)),
    .@"$port_connected" = query(.int, .exactly(1)),
    .@"$analog_node_alias" = query(.int, .exactly(2)),
    .@"$analog_port_alias" = query(.int, .exactly(2)),
    .@"$test$plusargs" = query(.int, .exactly(1)),
    .@"$value$plusargs" = query(.int, .exactly(2)),
    .@"$xposition" = query(.real, .exactly(0)),
    .@"$yposition" = query(.real, .exactly(0)),
    .@"$angle" = query(.real, .exactly(0)),
    .@"$hflip" = query(.real, .exactly(0)),
    .@"$vflip" = query(.real, .exactly(0)),
    .@"$rtoi" = convert(.int),
    .@"$itor" = convert(.real),
    .@"$realtobits" = convert(.int),
    .@"$bitstoreal" = convert(.real),
    .@"$clog2" = convert(.int),
    .@"$sqrt" = math1(.sqrt),
    .@"$exp" = math1(.exp),
    .@"$expm1" = math1(.expm1),
    .@"$ln" = math1(.ln),
    .@"$ln1p" = math1(.ln1p),
    .@"$log" = math1(.log10),
    .@"$log10" = math1(.log10),
    .@"$floor" = math1(.floor),
    .@"$ceil" = math1(.ceil),
    .@"$sin" = math1(.sin),
    .@"$cos" = math1(.cos),
    .@"$tan" = math1(.tan),
    .@"$asin" = math1(.asin),
    .@"$acos" = math1(.acos),
    .@"$atan" = math1(.atan),
    .@"$sinh" = math1(.sinh),
    .@"$cosh" = math1(.cosh),
    .@"$tanh" = math1(.tanh),
    .@"$asinh" = math1(.asinh),
    .@"$acosh" = math1(.acosh),
    .@"$atanh" = math1(.atanh),
    .@"$pow" = math2(.pow),
    .@"$hypot" = math2(.hypot),
    .@"$atan2" = math2(.atan2),
    .@"$display" = display,
    .@"$displayb" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$displayo" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$displayh" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$write" = display,
    .@"$writeb" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$writeo" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$writeh" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$strobe" = display,
    .@"$strobeb" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$strobeo" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$strobeh" = .{ .ty = .none, .family = .display, .context = .digital },
    .@"$monitor" = display,
    .@"$monitoron" = .{ .ty = .none, .args = .exactly(0), .family = .display, .context = .digital },
    .@"$monitoroff" = .{ .ty = .none, .args = .exactly(0), .family = .display, .context = .digital },
    .@"$debug" = display,
    .@"$fatal" = display,
    .@"$error" = display,
    .@"$warning" = display,
    .@"$info" = display,
    .@"$finish" = .{ .ty = .none, .args = .{ .max = 1 }, .family = .simctl },
    .@"$stop" = .{ .ty = .none, .args = .{ .max = 1 }, .family = .simctl },
    .@"$fopen" = .{ .ty = .int, .args = .{ .min = 1, .max = 2 }, .family = .file_func },
    .@"$fclose" = .{ .ty = .none, .args = .exactly(1), .family = .file_out },
    .@"$fflush" = .{ .ty = .none, .args = .{ .max = 1 }, .family = .file_out },
    .@"$fdisplay" = file_out,
    .@"$fwrite" = file_out,
    .@"$fstrobe" = file_out,
    .@"$fmonitor" = file_out,
    .@"$fdebug" = file_out,
    .@"$fgets" = .{ .ty = .int, .args = .exactly(2), .family = .file_func },
    .@"$fscanf" = .{ .ty = .int, .args = .{ .min = 2 }, .family = .file_func },
    .@"$ftell" = .{ .ty = .int, .args = .exactly(1), .family = .file_func },
    .@"$fseek" = .{ .ty = .int, .args = .exactly(3), .family = .file_func },
    .@"$rewind" = .{ .ty = .int, .args = .exactly(1), .family = .file_func },
    .@"$ferror" = .{ .ty = .int, .args = .exactly(2), .family = .file_func },
    .@"$feof" = .{ .ty = .int, .args = .exactly(1), .family = .file_func },
    .@"$sformat" = .{ .ty = .none, .args = .{ .min = 2 }, .family = .string },
    .@"$swrite" = .{ .ty = .none, .args = .{ .min = 1 }, .family = .string },
    .@"$sscanf" = .{ .ty = .int, .args = .{ .min = 2 }, .family = .string },
    .@"$random" = random(.int, .{ .max = 2 }),
    .@"$arandom" = random(.int, .{ .max = 3 }),
    .@"$dist_uniform" = random(.int, .{ .min = 3, .max = 4 }),
    .@"$dist_normal" = random(.int, .{ .min = 3, .max = 4 }),
    .@"$dist_exponential" = random(.int, .{ .min = 2, .max = 3 }),
    .@"$dist_poisson" = random(.int, .{ .min = 2, .max = 3 }),
    .@"$dist_chi_square" = random(.int, .{ .min = 2, .max = 3 }),
    .@"$dist_t" = random(.int, .{ .min = 2, .max = 3 }),
    .@"$dist_erlang" = random(.int, .{ .min = 3, .max = 4 }),
    .@"$rdist_uniform" = random(.real, .{ .min = 3, .max = 4 }),
    .@"$rdist_normal" = random(.real, .{ .min = 3, .max = 4 }),
    .@"$rdist_exponential" = random(.real, .{ .min = 2, .max = 3 }),
    .@"$rdist_poisson" = random(.real, .{ .min = 2, .max = 3 }),
    .@"$rdist_chi_square" = random(.real, .{ .min = 2, .max = 3 }),
    .@"$rdist_t" = random(.real, .{ .min = 2, .max = 3 }),
    .@"$rdist_erlang" = random(.real, .{ .min = 3, .max = 4 }),
    .@"$bound_step" = .{ .ty = .none, .args = .exactly(1), .family = .kernel, .context = .analog },
    .@"$discontinuity" = .{ .ty = .none, .args = .{ .max = 1 }, .family = .kernel, .context = .analog },
    .@"$limit" = .{ .ty = .real, .args = .{ .min = 1 }, .family = .kernel, .context = .analog },
    .@"$table_model" = .{ .ty = .real, .args = .{ .min = 2 }, .family = .kernel, .context = .analog },
    .@"$vera_reject_step" = .{ .ty = .none, .args = .exactly(1), .family = .kernel, .context = .analog },
    .@"op$static" = .{ .ty = .int, .args = .exactly(0), .family = .query, .context = .analog },
    .@"idt$hold" = .{ .ty = .real, .args = .exactly(3), .family = .analog_op, .context = .analog },
});

const display: Info = .{ .ty = .none, .family = .display };
const file_out: Info = .{ .ty = .none, .args = .{ .min = 1 }, .family = .file_out };

/// Returns `tag`'s row.
pub fn get(tag: Tag) *const Info {
    const info = table.getPtrConst(tag);
    assert(info.args.min <= info.args.max);
    return info;
}

// ---- private ----

fn pairs(comptime c: Context, comptime names: []const []const u8) [names.len]struct { []const u8, Context } {
    var out: [names.len]struct { []const u8, Context } = undefined;
    for (names, &out) |n, *o| o.* = .{ n, c };
    return out;
}
fn op(args: Arity) Info {
    return .{ .ty = .real, .args = args, .family = .analog_op, .context = .analog };
}
fn math1(m: Math) Info {
    return .{ .ty = .real, .args = .exactly(1), .family = .math, .math = m };
}
fn math2(m: Math) Info {
    return .{ .ty = .real, .args = .exactly(2), .family = .math, .math = m };
}
fn query(ty: Ty, args: Arity) Info {
    return .{ .ty = ty, .args = args, .family = .query };
}
fn convert(ty: Ty) Info {
    return .{ .ty = ty, .args = .exactly(1), .family = .convert };
}
fn random(ty: Ty, args: Arity) Info {
    return .{ .ty = ty, .args = args, .family = .random };
}

// Every row agrees with its family: a math row names its function, and
// only a math row does; an arity's bounds are ordered.
comptime {
    @setEvalBranchQuota(20_000);
    assert(@sizeOf(Tag) == 1);
    for (std.enums.values(Tag)) |t| {
        const info = table.get(t);
        assert(info.args.min <= info.args.max);
        assert((info.family == .math) == (info.math != null));
    }
}

test "fromName: a listed spelling is its tag, any other is a user system function" {
    try std.testing.expectEqual(Tag.@"$strobe", Tag.fromName("$strobe").?);
    try std.testing.expectEqual(Tag.ddt, Tag.fromName("ddt").?);
    try std.testing.expectEqual(@as(?Tag, null), Tag.fromName("$my_systf"));
    // §4.3.1: `log` is the base-10 logarithm, and `$log10` its 1364 spelling.
    try std.testing.expectEqual(Math.log10, get(.log).math.?);
    try std.testing.expectEqual(Math.log10, get(.@"$log10").math.?);
    try std.testing.expect(get(.@"$strobe").args.admits(7));
    try std.testing.expect(!get(.sqrt).args.admits(2));
}
