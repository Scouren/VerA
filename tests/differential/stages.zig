//! The stage-ownership table of the differential oracles
//! (docs/rewrite/README.md rule 3): every `vams.Diag.Code` in, the stage of
//! the new pipeline that owns raising it out, so a per-stage oracle compares
//! only the codes its stage owns (`settle.zig`) and the end-to-end oracle
//! demands the rest. A code's owner is the stage by which
//! every case of it has been raised: the stage of the new pipeline that
//! raises it (the latest, when several do); for a code no new stage raises
//! yet, the stage that inherits the old code that raised it (lib/frontend's
//! preprocessor -> `preprocess`, its lexer and parser -> `parse`, src/elab
//! and lib/sim/digital's elaborator -> `elab`, src/analog, src/ir and the
//! digital lowering -> `sema`, src/prove -> `proof`, src/codegen ->
//! `codegen`, the digital executor, the kernels and VPI -> `run`); a retired
//! code keeps its class's stage. An earlier stage may raise some cases of a
//! later stage's code early (AstGen's E0373 on a local read, before Sema's
//! on a hierarchical one), so a per-stage oracle compares the codes its own
//! stages own both ways and holds a later stage's to "the new side raised
//! it only where the old side did". The end-to-end oracle demands every
//! code.
//!
//! A `Split` refines one code under one LRM clause (a fixture's `//! lrm`
//! header) when a rule of that code belongs to another stage than its other
//! rules: E0207 is the parser's unexpected token, but under §4.4 (a probe's
//! net count, judged by a nature's `access` that may be in another file) it
//! is Sema's.
//!
//! The table is exhaustive by construction: a code in no list, or in two,
//! fails the build, and so does a `Split` that names its code's own owner.
//!
//! Cites: VAMS-2023 §4.4, §6.4.1 (the two splits).
//!
//! Contents:
//! - `pub const Owner = enum(u3)`
//! - `pub const Split = struct { code, clause, owner }`, `pub const splits`
//! - `pub const elab_codes`: the spellings of the codes elaboration owns
//! - `pub fn owner(c: Code) Owner`
//! - `pub fn ownerUnder(c: Code, clauses: []const []const u8) Owner`

const std = @import("std");
const assert = std.debug.assert;
const Code = @import("vams").Diag.Code;

/// The stages of the new pipeline, in the order they run: a stage's oracle
/// compares the codes a stage at or before it owns.
pub const Owner = enum(u3) { preprocess, parse, astgen, elab, sema, proof, codegen, run };

/// One code whose rule under `clause` (a `//! lrm` clause, `"4.4"`) is
/// raised by `owner` instead of by the code's own owner.
pub const Split = struct { code: Code, clause: []const u8, owner: Owner };

/// Every split, in code order.
pub const splits = [_]Split{
    // §4.4 "a list of one or two nets": which call is a probe comes from a
    // nature's `access`, which the old parser knew and the new one does not.
    .{ .code = .E0207, .clause = "4.4", .owner = .sema },
    // §6.4.1 "Hierarchical out-of-module references to non-local parameters
    // are disallowed": the reference is resolved by expression analysis.
    .{ .code = .E0907, .clause = "6.4.1", .owner = .sema },
};

/// The spellings of the codes elaboration owns, in catalogue order:
/// diff-elab compares them both ways and diff-lower leaves them out.
pub const elab_codes = blk: {
    @setEvalBranchQuota(100 * @typeInfo(Code).@"enum".field_names.len);
    var n: usize = 0;
    for (std.enums.values(Code)) |c| n += @intFromBool(table.get(c) == .elab);
    var out: [n][]const u8 = undefined;
    var k: usize = 0;
    for (std.enums.values(Code)) |c| if (table.get(c) == .elab) {
        out[k] = @tagName(c);
        k += 1;
    };
    const final = out;
    break :blk final;
};

const lists = [_]struct { Owner, []const Code }{
    .{ .preprocess, &.{
        .E0101, .E0102, .E0103, .E0104, .E0105, .E0106, .E0107, .E0108, .E0109, .E0110, .E0111, .E0112, .E0113, .E0114,
        .E0115, .E0116, .E0117, .E0118, .E0119, .E0120, .E0121, .E0122, .E0123, .E0124, .E0125, .E0126, .E0127, .E0128,
        .E0129, .E0134, .E0137, .E0138, .E0139, .E0140, .E0141, .E0142, .E0143, .E0144, .E0145, .E0146, .E0147, .E0150,
        .W0151, .E0152, .E0153, .E0154, .E1013, .E0953, .E0928,
    } },
    .{ .parse, &.{
        .E0131, .E0132, .E0133, .E0135, .E0136, .E0148, .W0149, .E0201, .E0202, .E0203, .E0204, .E0205, .E0207, .E0208,
        .E0209, .E0210, .E0211, .E0212, .E0213, .E0214, .E0215, .E0217, .E0219, .E0220, .E0221, .E0224, .E0226, .E0227,
        .E0228, .E0229, .E0231, .E0232, .E0233, .E0234, .E0236, .E0240, .E0242, .E0244, .E0246, .E0249, .E0250, .E0254,
        .E0255, .E0256, .E0257, .E0258, .E0296, .E0297, .E0289, .E0290, .E0291, .E0292, .E0293, .W0253, .W0259, .E1019,
        .E1104,
    } },
    .{ .astgen, &.{
        .E0206, .E0218, .E0225, .E0230, .E0238, .E0245, .E0248, .E0295, .E0376, .E1100, .E0918,
    } },
    .{ .elab, &.{
        .E0239, .E0243, .E0247, .E0347, .E0355, .E0358, .E0371, .E0375, .E0902, .E0903, .E0904, .E0905, .E0906, .E0907,
        .E0908, .E0909, .E0911, .E0913, .E0914, .E0915, .E0916, .E0917, .E1001, .W1152, .W1160, .W1161, .W0950, .W0951,
        .E0952, .E0919, .E0920, .E0921, .E0922, .E0923, .E0927, .E0929, .E0930, .E0982, .E0890,
    } },
    .{ .sema, &.{
        .E0130, .E0216, .E0223, .E0235, .E0237, .E0241, .W0250, .W0252, .E0301, .E0302, .E0303, .E0304, .E0305, .E0306,
        .E0307, .E0308, .E0309, .E0310, .E0311, .E0312, .E0313, .E0314, .E0315, .E0316, .E0317, .E0318, .E0319, .E0320,
        .E0321, .E0322, .E0323, .E0324, .E0325, .E0326, .E0327, .E0328, .E0329, .E0330, .E0331, .E0332, .E0333, .E0334,
        .E0335, .E0336, .E0337, .E0338, .E0339, .E0340, .E0341, .E0342, .E0343, .E0344, .E0345, .E0346, .E0348, .E0349,
        .E0350, .E0351, .E0352, .E0353, .E0354, .E0356, .E0357, .E0359, .E0360, .E0361, .E0362, .E0363, .E0364, .E0365,
        .E0366, .E0367, .E0368, .E0369, .E0370, .E0372, .E0373, .E0374, .E0378, .E0401, .E0402, .E0403, .E0404, .E0405,
        .E0406, .E0407, .E0408, .E0409, .E0410, .E0411, .E0412, .E0413, .E0414, .E0415, .E0416, .E0417, .E0418, .E0419,
        .E0420, .E0421, .E0422, .E0423, .E0424, .E0425, .E0426, .E0427, .E0428, .E0429, .E0430, .E0431, .E0432, .E0433,
        .E0434, .E0435, .E0436, .E0437, .E0438, .E0439, .E0440, .E0477, .E0501, .E0502, .E0503, .E0504, .E0505, .E0506,
        .E0507, .E0508, .E0509, .E0510, .E0511, .E0512, .E0513, .E0514, .E0516, .E0517, .E0518, .E0519, .E0521, .E0522,
        .E0523, .E0524, .E0525, .E0526, .E0528, .E0529, .E0530, .E0532, .E0533, .E0534, .E0535, .E0536, .E0537, .E0538,
        .E0539, .E0572, .E0573, .E0574, .E0701, .E0702, .E0703, .E0704, .E0705, .E0706, .E0707, .E0708, .E0801, .E0802,
        .E0803, .E0804, .E0805, .E0806, .E0807, .E0808, .E0809, .E0810, .E0811, .E0812, .E0813, .E0814, .E0815, .E0816,
        .E0817, .E0818, .E0819, .E0901, .E0910, .E0912, .E1014, .E1015, .E1016, .E1021, .E1022, .E1101, .E1149, .W1162,
        .E0820, .E0821, .E0822, .E0824, .E0924, .E0925, .E0926, .E0960, .E0997, .E0998, .E0482, .E0483, .E0484, .E0485,
        .E0486, .E0887, .E0888, .E0889, .E0891, .E0892, .E0893, .E0894, .E0823, .E0828, .E0829,
    } },
    .{ .proof, &.{
        .E0601, .E0602, .E0603, .E0604, .E0605, .E0606, .E0607, .E0608, .E0609, .W0650, .W0651, .W0652, .W0653,
    } },
    .{ .codegen, &.{
        .E0222, .E0515, .E0520, .E0527, .E0531, .E0540, .W0750, .W0850, .W0852, .E1002, .E1003, .E1004, .E1010, .E1012,
        .E1017, .E1018, .E1020, .E1103, .W1155, .E1200, .E1201, .E1202, .E1203, .E1204, .E1205, .E1206, .E1207, .E1208,
        .E1209, .E1210, .E1211, .E1212, .E1213, .E1214, .E1215, .E1216, .E1217, .E1218, .E1219, .E1220, .E1221, .E1222,
        .E1223, .E1224, .E1225, .E1226, .E1227, .E1228, .E1229, .E1230, .E1231, .E1232, .E1233, .E1234, .E1235, .E1236,
        .E1237, .E1238, .E1239, .E1240, .E1241, .E1242, .E1243, .E1244, .E1245, .E1246, .E1247, .E1248, .E1249, .E1250,
        .E1251, .E1252, .E1253, .E1254, .E1255, .E1256, .E1257, .E1258, .E1259, .E1260, .E1261, .E1262, .E1263, .E1264,
        .E1265, .E1266, .E1267, .E1268, .E1269, .E1270, .E1271, .E1272, .E1273, .E1274, .E1275, .E1276, .E1277, .E1278,
        .W1050, .W0853, .W0854, .E1099, .W1098,
    } },
    .{ .run, &.{
        .W0251, .E0377, .E1011, .E1102, .W1105, .E1147, .E1148, .W1150, .W1151, .W1153, .W1154, .W1156, .W1157, .W1199,
        .W1051, .E0825, .E0826, .E0827,
    } },
};

/// `lists` as one row per code; a code in no list or in two fails the build.
const table: std.enums.EnumArray(Code, Owner) = blk: {
    @setEvalBranchQuota(100 * @typeInfo(Code).@"enum".field_names.len);
    var seen: std.enums.EnumArray(Code, ?Owner) = .initFill(null);
    for (lists) |l| for (l[1]) |c| {
        if (seen.get(c)) |o| @compileError(@tagName(c) ++ " is owned by both ." ++ @tagName(o) ++ " and ." ++ @tagName(l[0]));
        seen.set(c, l[0]);
    };
    var t: std.enums.EnumArray(Code, Owner) = undefined;
    for (std.enums.values(Code)) |c| t.set(c, seen.get(c) orelse @compileError(@tagName(c) ++ " has no owning stage"));
    for (splits) |s| if (s.owner == t.get(s.code)) @compileError(@tagName(s.code) ++ "'s split names its own owner");
    break :blk t;
};

/// Returns the stage that owns `c`, with one indexed load.
pub fn owner(c: Code) Owner {
    return table.get(c);
}

/// Returns the stage that owns `c` in a fixture citing `clauses`: a split's
/// owner when one names `c` and one of `clauses`, else `owner(c)`.
pub fn ownerUnder(c: Code, clauses: []const []const u8) Owner {
    for (splits) |s| {
        if (s.code != c) continue;
        for (clauses) |clause| if (std.mem.eql(u8, clause, s.clause)) return s.owner;
    }
    return owner(c);
}

// ---- private ----

comptime {
    assert(@sizeOf(Owner) == 1);
}

test "a split moves its code under its clause only" {
    try std.testing.expectEqual(Owner.parse, owner(.E0207));
    try std.testing.expectEqual(Owner.parse, ownerUnder(.E0207, &.{ "4.2", "A.1.2" }));
    try std.testing.expectEqual(Owner.sema, ownerUnder(.E0207, &.{ "4.4:1", "4.4" }));
    try std.testing.expectEqual(Owner.astgen, ownerUnder(.E0376, &.{"4.4"}));
}
