//! The `.v` backends over `std_sim.Program` (docs/rewrite/digital.md),
//! reading the Program and nothing else. `writeExe` is `--emit-exe`'s:
//! the executable's root, which embeds the Program (`std_sim.serial`) and
//! runs it through `std_sim.exe` (the interpreter `vera --run` runs), so
//! the binary prints what `--run` prints. `writeDevice` is the contract
//! device's (`--emit-zig`, `--check`, `--emit-so` of a `.v`): the Program
//! behind `std_sim.Device`, one pin per port bit. Renamed `digital` at the
//! switch-over, when the old `codegen/digital` goes.
//! Cites: IEEE 1364-2005 §7.6, §15, §17, §17.2.9, §17.2.10; VAMS §7.8
//! (connect modules at a digital port).
//!
//! Contents:
//! - `pub const Port = struct`
//! - `pub fn deviceRefusal(program: *const std_sim.Program, ports: []const Port) ?[]const u8`
//! - `pub fn writeDevice(w: *std.Io.Writer, arena: Allocator, program: *const std_sim.Program, ports: []const Port) (Allocator.Error || std.Io.Writer.Error)!void`
//! - `pub fn writeExe(w: *std.Io.Writer, arena: Allocator, program: *const std_sim.Program, sources: []const std_sim.exe.Source, sites: []const Diag.Loc, budget: u64) (Allocator.Error || std.Io.Writer.Error)!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const std_sim = @import("std_sim");
const Diag = @import("vams").Diag;
const contract = @import("contract");

/// One port of the top module, in port-list order, as the device reads it.
pub const Port = struct {
    name: []const u8,
    dir: enum { input, output, inout },
    /// The `Program.slots` row; `no_slot` when nothing stands behind it.
    slot: u32,
    ty: std_sim.Program.Ty,
    msb: i64,
    lsb: i64,
    /// Declared without a range: one pin named as the port.
    scalar: bool,
    /// An `integer` or `time` variable.
    integer: bool,

    pub const no_slot = std.math.maxInt(u32);
};

/// Why `program` with top ports `ports` is no contract device (E1103's
/// text), or null. The old device's refusals that hold for a device over
/// the interpreter, in its order: a §7.6 pass switch, a file the run
/// would read (§17.2.9, §17.2.10), §15 timing checks (a device has nowhere
/// to report W1199), then the ports.
pub fn deviceRefusal(program: *const std_sim.Program, ports: []const Port) ?[]const u8 {
    const P = std_sim.Program;
    if (program.trans.len != 0) return "a §7.6 pass switch";
    for (program.insts.items(.tag), program.insts.items(.data)) |tag, d| {
        if (tag != .task) continue;
        switch (program.extraData(P.Task, d.a).kind) {
            .readmem => return "§17.2.9 $readmemb/$readmemh: a device reads no file",
            .sdf => return "§17.2.10 $sdf_annotate, which the interpreter (`vera --run`) applies",
            // else: every other task runs inside the device.
            else => {},
        }
    }
    if (program.checks.len != 0) return "IEEE 1364-2005 §15 timing checks";
    var pins: u64 = 0;
    for (ports) |p| {
        if (p.dir == .inout) return "an inout port: the analog side would drive a §7.9 resolved net";
        if (p.slot == Port.no_slot) return "a port with no net or variable behind it";
        if (p.ty.real) return "a real port";
        if (p.integer) return "an integer or time port";
        pins += @abs(p.msb - p.lsb) + 1;
        // Not a VerA cap: a contract mask is one integer with a bit per pin
        // (`contract.MaskOf`), and Zig's widest integer is u65535.
        if (pins > std.math.maxInt(u16)) return "more than 65535 pins (a contract mask is one u65535)";
    }
    return null;
}

/// Writes the contract device root of `program`: `std_sim.Device` over
/// the Program (`std_sim.serial` bytes) with one pin per bit of `ports`,
/// in declaration order and a vector's bits from its left index to its
/// right. `U` is an `enum(u8)` up to 256 pins and as wide as the pin count
/// needs past them. Asserts `deviceRefusal` is null.
pub fn writeDevice(w: *std.Io.Writer, arena: Allocator, program: *const std_sim.Program, ports: []const Port) (Allocator.Error || std.Io.Writer.Error)!void {
    assert(deviceRefusal(program, ports) == null);
    var bytes: std.Io.Writer.Allocating = .init(arena);
    std_sim.serial.save(program, &bytes.writer) catch return error.OutOfMemory;
    var names: std.Io.Writer.Allocating = .init(arena);
    var pins: std.Io.Writer.Allocating = .init(arena);
    var n: u32 = 0;
    for (ports) |p| {
        var i = p.msb;
        // Bounded by the port's width (`deviceRefusal`: at most 65535 pins).
        while (true) : (i = if (p.msb >= p.lsb) i - 1 else i + 1) {
            const name = if (p.scalar) p.name else try arena.print("{s}[{d}]", .{ p.name, i });
            try names.writer.print(" {f},", .{std.zig.fmtId(name)});
            try pins.writer.print("\n    .{{ .out = {}, .slot = {d}, .bit = {d} }},", .{ p.dir == .output, p.slot, @abs(i - p.lsb) });
            n += 1;
            if (i == p.lsb) break;
        }
    }
    assert(n <= std.math.maxInt(u16));
    // No pins: Zig refuses an empty exhaustive `enum(u8)`.
    const members = if (n == 0) " _," else names.written();
    const tag_bits = @max(8, std.math.log2_int_ceil(u32, @max(n, 1)));
    try w.print(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\// A `.v` design's top module as a contract device: the Program `std_sim.Device` runs.
        \\
        \\const std_sim = @import("std_sim");
        \\/// The VerA release that generated this device (`contract.vera_version`).
        \\pub const vera_version = "{s}";
        \\pub const U = enum(u{d}) {{{s} }};
        \\pub const num_ports: usize = {d};
        \\const Dev = std_sim.Device(.{{ .U = U, .units = {d}, .program = "{f}", .pins = &.{{{s}
        \\}} }});
        \\pub const Model = Dev.Model;
        \\pub const Instance = Dev.Instance;
        \\pub const State = Dev.State;
        \\pub const state_class = Dev.state_class;
        \\pub const deriv_reads = Dev.deriv_reads;
        \\pub const ddx_reads = Dev.ddx_reads;
        \\pub const jac_pattern = Dev.jac_pattern;
        \\pub const eval = Dev.eval;
        \\pub const initState = Dev.initState;
        \\pub const updateState = Dev.updateState;
        \\pub const stateCtl = Dev.stateCtl;
        \\pub const pendingBreakpoint = Dev.pendingBreakpoint;
        \\
        \\comptime {{
        \\    @import("contract").validate(@This());
        \\}}
        \\
    , .{ contract.vera_version, tag_bits, members, n, program.finest, std.zig.fmtString(bytes.written()), pins.written() });
}

/// Writes the executable's root for `program` to `w`: `vera_digital` (the
/// Program as `std_sim.serial` bytes; `sources`, the files a diagnostic
/// points into; `sites`, each timing check's W1199 location; the event
/// `budget`) and `std_sim.exe.main`. Asserts one site per timing check.
pub fn writeExe(w: *std.Io.Writer, arena: Allocator, program: *const std_sim.Program, sources: []const std_sim.exe.Source, sites: []const Diag.Loc, budget: u64) (Allocator.Error || std.Io.Writer.Error)!void {
    assert(sites.len == program.checks.len);
    var bytes: std.Io.Writer.Allocating = .init(arena);
    std_sim.serial.save(program, &bytes.writer) catch return error.OutOfMemory;
    assert(bytes.written().len != 0);
    try w.writeAll(
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\// A `.v` design's executable: the Program `std_sim.exe` runs.
        \\
        \\const exe = @import("std_sim").exe;
        \\pub const main = exe.main;
        \\pub const vera_digital: exe.Config = .{
        \\
    );
    try w.print("    .program = \"{f}\",\n    .sources = &.{{\n", .{std.zig.fmtString(bytes.written())});
    for (sources) |s| try w.print("        .{{ .name = \"{f}\", .text = \"{f}\" }},\n", .{ std.zig.fmtString(s.name), std.zig.fmtString(s.text) });
    try w.writeAll("    },\n    .sites = &.{\n");
    for (sites) |l| try w.print("        .{{ .file = @enumFromInt({d}), .start = {d}, .end = {d} }},\n", .{ @backingInt(l.file), l.start, l.end });
    try w.print("    }},\n    .budget = {d},\n}};\n", .{budget});
}

test writeExe {
    // Oracle: the text parses as Zig and names every row it was given
    // (the build and the run are `diff-digital`'s).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: std_sim.Builder = .init(a);
    _ = try b.slot(.bit, &.{0}, &.{1});
    const p = b.finish();
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeExe(&aw.writer, a, &p, &.{.{ .name = "a \"b\".v", .text = "module m;\nendmodule\n" }}, &.{}, 7);
    const text = try a.dupeSentinel(u8, aw.written(), 0);
    var tree = try std.zig.Ast.parse(a, text, .{});
    defer tree.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expect(std.mem.find(u8, text, ".budget = 7,") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"a \\\"b\\\".v\"") != null);
}
