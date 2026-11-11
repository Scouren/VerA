//! §9.7.3 the `$fatal`/`$error` status latch (research/codegen.md T1, the
//! w1-codegen "status latch" wrong number): a call in `Device.displays`
//! whose callee is one of the two -> `status_sites` (`contract.StatusSite`,
//! one per site, in source order) out, and, inline in `core`'s body, the
//! record that makes the first site an evaluation reaches win. `DeclGen`
//! reads `core`'s result back in `eval`/`q`: once `Instance.vera_status__`
//! is nonzero, both skip `core` and return zero rows, exactly as the old
//! device's `src/codegen/device/codegen/status.zig` does, except that file
//! reaches "first site wins" through an SSA `select` (the old pipeline has
//! no real control flow at this point) where this file's `record` writes a
//! real `if`, because `core`'s body already has one.
//! Cites: VAMS-2023 §9.7.3.
//!
//! Contents:
//! - `pub const arg_max: usize`
//! - `pub const Site = struct`
//! - `pub fn hasStatus(dg: *const DeclGen) bool`
//! - `pub fn plan(dg: *DeclGen) DeclGen.Error!void`
//! - `pub fn genCoreFields(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genDecls(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genReturn(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genInstanceFields(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn genSetupInstance(dg: *DeclGen, w: *std.Io.Writer) DeclGen.Error!void`
//! - `pub fn record(f: *Function, inst: Air.Inst.Index) DeclGen.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Air = @import("air");
const contract = @import("contract");
const SysFn = @import("vams").SysFn;
const DeclGen = @import("DeclGen.zig");
const Function = @import("Function.zig");
const say = @import("say.zig");
const Ref = Air.Inst.Ref;
const Error = DeclGen.Error;

/// `Instance.vera_status_args__`'s width: `contract.display_records`'s
/// `StatusSite`/`statusCode` four-argument shape.
pub const arg_max = 4;

/// One `$fatal`/`$error` call of `Device.displays`; this slice's index is
/// the site `contract.statusCode` packs.
pub const Site = struct {
    call: Air.Inst.Index,
    severity: contract.Severity,
    /// The C-style format over the call's numeric arguments (`say.format`'s
    /// rules: the same ones `contract.formatStatus` renders with).
    fmt: []const u8,
    file: []const u8,
    line: u32,
};

/// Whether the device reports any §9.7.3 status: without one, no `Instance`
/// fields, no `core` locals and no `eval`/`q` guard are worth emitting.
pub fn hasStatus(dg: *const DeclGen) bool {
    return dg.status_sites.len != 0;
}

/// Fills `dg.status_sites`: every `$fatal`/`$error` row of `Device.displays`,
/// in source order.
pub fn plan(dg: *DeclGen) Error!void {
    const d = dg.device;
    var sites: std.ArrayList(Site) = .empty;
    for (d.displays.items(.name), d.displays.items(.call), d.displays.items(.file), d.displays.items(.line)) |n, call, file, line| {
        const tag = SysFn.Tag.fromName(dg.ip.stringToSlice(n)) orelse continue;
        const severity: contract.Severity = switch (tag) {
            .@"$fatal" => .fatal,
            .@"$error" => .@"error",
            else => continue, // else: a plain display or file task, not status
        };
        var fmt: std.ArrayList(u8) = .empty;
        var vals: std.ArrayList(Ref) = .empty;
        _ = try say.format(dg, messageArgs(dg, callArgs(dg.air, call)), &fmt, &vals);
        try sites.append(dg.arena, .{ .call = call, .severity = severity, .fmt = fmt.items, .file = dg.ip.stringToSlice(file), .line = line });
    }
    dg.status_sites = sites.items;
}

/// `Core(S)`'s status fields: this evaluation's own first site (0 until
/// `record` sets it) and its arguments.
pub fn genCoreFields(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    if (!hasStatus(dg)) return;
    try dg.print(w, " st__: u32, sa__: [{d}]f64,", .{arg_max});
}

/// `core`'s status locals, before the body.
pub fn genDecls(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    if (!hasStatus(dg)) return;
    try dg.print(w, "\n    var st__: u32 = 0; var sa__: [{0d}]f64 = @splat(0.0); _ = &st__; _ = &sa__;", .{arg_max});
}

/// `core`'s `return` entries of the status locals.
pub fn genReturn(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    if (!hasStatus(dg)) return;
    try dg.print(w, " .st__ = st__, .sa__ = sa__,", .{});
}

/// The `Instance` fields a host polls after a solve (`contract.statusSite`,
/// `formatStatus`).
pub fn genInstanceFields(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    if (!hasStatus(dg)) return;
    try dg.print(w, "    vera_status__: u32 = 0,\n    vera_status_args__: [{d}]f64 = @splat(0.0),\n", .{arg_max});
}

/// `status_sites`: the table `contract.formatStatus` reads by the code
/// `Instance.vera_status__` latches.
pub fn genEntries(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    if (!hasStatus(dg)) return;
    try dg.print(w, "\n/// §9.7.3 every `$fatal`/`$error` call, in source order: the first one\n/// an evaluation reaches latches `Instance.vera_status__`.\npub const status_sites = [_]contract.StatusSite{{\n", .{});
    for (dg.status_sites) |s| try dg.print(w, "    .{{ .severity = .{s}, .fmt = \"{f}\", .file = \"{f}\", .line = {d} }},\n", .{
        if (s.severity == .fatal) "fatal" else "@\"error\"",
        std.zig.fmtString(s.fmt),
        std.zig.fmtString(s.file),
        s.line,
    });
    try dg.print(w, "}};\n", .{});
}

/// `setupInstance`: the old device's precedent (`src/codegen/device/
/// codegen/setup.zig`'s `emitSetupInstance`) for the same reason it names
/// a card write invalidates: a host that reuses one `Instance` across a
/// card sweep (`contract.host`'s `calls_setup`) must drop a status latched
/// under the previous card, same as `initState` at the start of an
/// analysis. Without it the latch is sticky forever past the first call
/// that ever set it, one card's `$fatal` masking every later point's real
/// rows for the life of the instance.
pub fn genSetupInstance(dg: *DeclGen, w: *std.Io.Writer) Error!void {
    if (!hasStatus(dg)) return;
    try dg.print(w, "\npub fn setupInstance(_: *const Model, inst: *Instance) void {{\n    inst.vera_status__ = 0;\n    inst.vera_status_args__ = @splat(0.0);\n}}\n", .{});
}

/// Writes `$fatal`/`$error` call `inst`'s record: in `core`, the latch
/// (§9.7.3 the first one reached wins; later ones in the same evaluation
/// change nothing, `st__ == 0` guards the write); in `say`, a discard,
/// since `Liveness.effect` (over both passes alike) keeps the arguments'
/// defining instructions materialized there too, though `say` never prints
/// or latches them (`say.records` excludes `$fatal`/`$error`).
pub fn record(f: *Function, inst: Air.Inst.Index) Error!void {
    const k = for (f.dg.status_sites, 0..) |s, j| {
        if (s.call == inst) break j;
    } else return; // not a status site: a plain display or file task
    var fmt: std.ArrayList(u8) = .empty;
    var vals: std.ArrayList(Ref) = .empty;
    _ = try say.format(f.dg, messageArgs(f.dg, callArgs(f.dg.air, inst)), &fmt, &vals);
    if (f.phase == .say) {
        if (vals.items.len == 0) return;
        try f.line();
        try f.print("_ = .{{", .{});
        for (vals.items, 0..) |v, i| {
            try f.print("{s}", .{if (i == 0) " " else ", "});
            if (f.isIntRef(v)) try f.int(v) else try f.real(v);
        }
        try f.print(" }};", .{});
        return;
    }
    try f.line();
    try f.print("if (st__ == 0) {{ st__ = {d}; sa__ = .{{", .{contract.statusCode(f.dg.status_sites[k].severity, k)});
    for (0..arg_max) |i| {
        try f.print("{s}", .{if (i == 0) " " else ", "});
        if (i >= vals.items.len) {
            try f.print("0.0", .{});
            continue;
        }
        const v = vals.items[i];
        if (f.isIntRef(v)) {
            try f.print("@as(f64, @floatFromInt(", .{});
            try f.int(v);
            try f.print("))", .{});
        } else {
            try f.print("(", .{});
            try f.real(v);
            try f.print(").val()", .{});
        }
    }
    try f.print(" }}; }}", .{});
}

// ---- private ----

/// Call `inst`'s argument refs, in source order.
fn callArgs(air: *const Air, inst: Air.Inst.Index) []const Ref {
    const x = air.extraData(Air.Call, air.instructions.items(.data)[@backingInt(inst)].ty_pl.payload);
    return @ptrCast(air.extra[x.end..][0..x.data.args_len]);
}

/// `args` from its first string-literal operand on (the old `lowerStatus`):
/// `$fatal`'s leading `finish_number` sits before any message and is not
/// part of it; with no string literal at all, the message is "" and there
/// are no status arguments (the empty slice past `args.len`, same as old's
/// `args[args.len..]`).
fn messageArgs(dg: *DeclGen, args: []const Ref) []const Ref {
    for (args, 0..) |a, i| if (say.strConst(dg, a) != null) return args[i..];
    return args[args.len..];
}
