//! `vera-next`'s command line as typed (Zig's `main.zig` locals): one
//! field per flag of the old `src/cli/Cli.zig`, filled by `args.parse`,
//! settled by `args.resolve`, then turned into one `Compilation.Config`
//! (`args.config`). Every slice borrows from the argv iterator; the lists
//! are owned and freed by `deinit`. A later flag of the same kind
//! overwrites an earlier one except where a field says otherwise.
//!
//! Cites: LRM 3.4 (`overrides`), annex C (`sim`), IEEE 1364-2005 §13.2,
//! §13.7.1, §15.5.4, §28 (the `.v` fields).
//!
//! Contents:
//! - fields, one per flag (see `cli/usage.zig`)
//! - `pub const Color`, `pub const Schedule`, `pub const Logic`
//! - `pub fn deinit(o: *Options, gpa: Allocator) void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Config = @import("comp").Config;

levels: vams.Diag.Levels = .empty,
include_dirs: std.ArrayList([]const u8) = .empty,
defines: std.ArrayList([]const u8) = .empty,
overrides: std.ArrayList(Config.Override) = .empty,
/// The inputs; `paths[0]` is the one compiled.
paths: std.ArrayList([]const u8) = .empty,
libmaps: std.ArrayList([]const u8) = .empty,
search: std.ArrayList([]const u8) = .empty,
emit_zig: bool = false,
json: bool = false,
color: Color = .auto,
unknown_bound: ?f64 = null,
discipline_resolution: @FieldType(Config, "discipline_resolution") = .basic,
std_defs: bool = true,
language: vams.Ast.KeywordSet = .vams_2023,
sim: Config.Sim = .verilog_ams,
/// `--sim=` and `--std=` as typed, for `resolve`'s conflict.
sim_flag: ?[]const u8 = null,
std_flag: ?[]const u8 = null,
out_path: ?[]const u8 = null,
expect_module: ?[]const u8 = null,
emit_verilog: bool = false,
emit_rtlil: bool = false,
digital_pins: ?[]const u8 = null,
power_pins: bool = false,
vdd: f64 = 1.8,
check: bool = false,
validate_contract: bool = false,
emit_so: bool = false,
emit_osdi: bool = false,
/// `--emit-zig` typed, as opposed to implied by `-o`.
emit_zig_typed: bool = false,
run_exe: bool = false,
display: Config.Display = .record,
jac_f32: bool = false,
jac_f32_host: bool = false,
lint_flag: bool = false,
elab: bool = false,
lsp: bool = false,
display_flag: ?Config.Display = null,
/// The last flag that implies codegen.
codegen_flag: ?[]const u8 = null,
/// `--emit-exe` or `--run`, whichever was typed last.
exe_flag: ?[]const u8 = null,
contract_path: ?[]const u8 = null,
dyn_path: ?[]const u8 = null,
work_dir: ?[]const u8 = null,
zig_exe: []const u8 = "zig",
debug_info: bool = false,
/// Null: Debug for a testbench, ReleaseFast otherwise.
optimize: ?std.lang.Optimize = null,
/// `--zig-backend=`: null is `auto`.
zig_backend: ?enum { llvm, self_hosted } = null,
jobs: ?u32 = null,
spice_path: ?[]const u8 = null,
protect_keys: ?[]const u8 = null,
schedule: Schedule = .static,
event_budget: u64 = 10_000_000,
logic: Logic = .auto,
logic_flag: ?[]const u8 = null,
negative_timing: bool = false,

/// `--color=`.
pub const Color = enum { auto, always, never };
/// `--schedule=`: the native executable's process order.
pub const Schedule = enum { static, fifo };
/// `--state=` / `--two-state`.
pub const Logic = enum { auto, two, four };

const Options = @This();

/// Frees the lists; `gpa` is the one `parse` was given.
pub fn deinit(o: *Options, gpa: Allocator) void {
    o.include_dirs.deinit(gpa);
    o.defines.deinit(gpa);
    o.overrides.deinit(gpa);
    o.paths.deinit(gpa);
    o.libmaps.deinit(gpa);
    o.search.deinit(gpa);
    o.* = undefined;
}
