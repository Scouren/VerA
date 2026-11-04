//! The §8 mixed-signal runner: a `Bench`, its `Facts` and the design's
//! digital half (`Digital`: a `std_sim.Program` as `std_sim.serial` bytes and
//! its names) in, the runner's Zig source out. The runner embeds the
//! program, so it never elaborates (A.4 finding F12): each point loads it
//! afresh into a `std_sim.State` and `std_sim.mixed.run` steps the two
//! halves on one time line.
//! Cites: VAMS-2023 §7.3.1, §7.3.6.3, §7.3.6.5, §8.2, §8.4, §8.5; IEEE
//! 1364-2005 §19.8.
//!
//! Contents:
//! - `pub fn writeMixed(w: *Writer, title: []const u8, bench: *const Bench, facts: Facts, d: Digital, count: u32) RenderError!void`

const std = @import("std");
const assert = std.debug.assert;
const spec = @import("spec.zig");
const parts = @import("parts.zig");
const text = @import("text.zig");
const Bench = spec.Bench;
const Facts = spec.Facts;
const Digital = spec.Digital;
const RenderError = spec.RenderError;
const Writer = parts.Writer;

/// Writes the mixed-signal runner for `bench` over digital half `d` to
/// `w`. `count` is `pointCount(bench)`; each point is its own analysis,
/// with a fresh digital run and `State`.
pub fn writeMixed(w: *Writer, title: []const u8, bench: *const Bench, facts: Facts, d: Digital, count: u32) RenderError!void {
    assert(count != 0);
    assert(d.program.len != 0);
    try parts.head(w, title, bench, facts);
    try w.writeAll(text.mixed_body);
    if (bench.noise != null or bench.acstim != null or bench.qsites != null or bench.seeds != null or bench.meta != null or bench.limits.len != 0 or bench.acdyn.len != 0)
        try w.writeAll("comptime { @compileError(title ++ \": //! noise, //! acstim, //! qsite, //! seed, //! meta, //! limit and //! acdyn are not read by the mixed-signal runner\"); }\n");
    try w.print("const program_bytes = \"{f}\";\n", .{std.zig.fmtString(d.program)});
    try w.writeAll("const digital_names = [_]Name{");
    for (d.names) |n| try w.print(" .{{ .path = \"{f}\", .slot = {d}, .real = {} }},", .{ std.zig.fmtString(n.path), n.slot, n.real });
    try w.writeAll(" };\n");
    try parts.timeArrays(w, bench);
    // The adapter: `std_sim.mixed.run`'s `A`, with the waves set in `solveAt`.
    try w.writeAll(text.adapter_head);
    for (bench.waves, 0..) |wv, k|
        try w.print("        set(a.x, a.forced, \"{f}\", pwl(&wave_{d}, t));\n", .{ std.zig.fmtString(wv.name), k });
    try w.writeAll(text.adapter_tail);
    try mainOf(w, bench, facts, count);
}

// ---- private ----

/// Writes `main`: the card, the instance, the host bindings, then one
/// `runMixed` analysis per point.
fn mainOf(w: *Writer, bench: *const Bench, facts: Facts, count: u32) RenderError!void {
    assert(count != 0);
    assert(bench.times_s.len != 0);
    try w.writeAll(text.big_stack);
    try w.writeAll(
        \\pub fn main(init: std.process.Init.Minimal) void {
        \\    if (comptime big_stack) return bigStack(init);
        \\    @call(.never_inline, run, .{init});
        \\}
        \\fn run(init: std.process.Init.Minimal) void {
        \\    var model: D.Model = .{};
        \\
    );
    for (bench.params) |p| try parts.setCard(w, "    ", "model", p.name, p.value);
    try parts.deriveCard(w, "    ", "model", bench.temperature_k);
    try w.writeAll("    var inst: D.Instance = .{};\n");
    try w.print("    run_kind = .{t};\n    sim_state = .{{ .kind = run_kind }};\n", .{bench.analysis});
    try w.writeAll(
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = plusargs(init);
        \\    if (comptime @hasField(D.Instance, "cwd")) inst.cwd = cwdPath();
        \\    if (comptime @hasField(D.Instance, "analysis_name")) inst.analysis_name = analysis_name;
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model);
        \\    if (comptime @hasDecl(D, "setupInstance")) D.setupInstance(&model, &inst);
        \\    if (print_residual) std.debug.print("=== {s} ===\n", .{title});
        \\    var n: usize = 0;
        \\    var state: State = undefined;
        \\
    );
    const mdl = if (bench.psweeps.len == 0) "model" else "pm";
    for (0..count) |pi| {
        const n: u32 = @intCast(pi);
        try w.writeAll("    {\n");
        try parts.sweepPoint(w, bench, count, n);
        // §9.5.1.1, as in the fixed-grid runner: every point here is an analysis.
        if (n != 0)
            try w.writeAll("        if (contract.fileIo(D, &inst)) |f| if (f.new_analysis) |g| g(f.ctx);\n");
        try parts.swept(w, bench, count, n);
        try parts.pointUnknowns(w, bench, facts, .init(bench, count, n), mdl, true);
        try w.print("        runMixed(&{s}, &inst, &x, &forced, &state, &n);\n    }}\n", .{mdl});
    }
    try w.print("}}\n\nconst print_residual = {};\n", .{bench.print == .residual});
}
