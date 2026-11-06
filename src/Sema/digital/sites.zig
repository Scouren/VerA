//! Where `--emit-rtlil` refuses a design (codegen/rtlil.zig's E1201 to
//! E1270): one pass over every file's Vir, module by module in source
//! order, writing a row per construct outside the RTLIL subset, with the
//! old front end's location for it (the old parser's `main_tok`) and the
//! phase of the old emitter's walk it is found in. The rules that pick the
//! reported row are the backend's; this file only reads what Sema has (the
//! Vir and the trees), and runs only for an `--emit-rtlil` target.
//! Old-front-end shapes kept here: a generate construct sits in the
//! module's analog list (E1202), innermost first; generate items join their
//! module's lists; a digital function is a task (E1206); `for`'s init is
//! not a statement of its own.
//! Cites: IEEE 1364-2005 §4.9.3 (memories), §9 (statements), §12.4
//! (generate), A.1.3 (ports).
//!
//! Contents:
//! - `pub const Phase = enum`, `pub const Kind = enum`, `pub const Row = struct`
//! - `pub const Sites = struct`, `pub const none`
//! - `pub fn collect(arena: Allocator, zcu: *const Zcu, trees: []const *const vams.Ast) Allocator.Error!Sites`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Zcu = @import("../../Zcu.zig");
const Ast = vams.Ast;
const Walk = @import("sites/Walk.zig");

/// The old emitter's walk, in order: the file (its UDPs), the module's
/// item lists, its parameters, ports, nets and variables, each `initial`
/// (flattened, then its statements), the continuous assigns, the net
/// initializers, the gates, the instances, and each `always` (its header,
/// its event terms, the regs it writes, its statements).
pub const Phase = enum(u8) { file, item, param, port, net, variable, initial_flat, initial_stmt, assign, net_init, gate, instance, always_head, always_event, always_mix, always_target, always_stmt };

/// One refusal, by the construct the old emitter names.
pub const Kind = enum(u8) {
    udp,
    analog,
    connect,
    genvar,
    defparam,
    task,
    analog_function,
    event,
    pull,
    switch_prim,
    branch,
    port_expr,
    port_select,
    port_wreal,
    net_wreal,
    net_array,
    var_array,
    var_real,
    var_string,
    range_value,
    range_offset,
    range_width,
    param_value,
    block_decls,
    fork,
    init_other,
    init_timed,
    init_target,
    unknown_name,
    init_value,
    real_literal,
    string_literal,
    hierarchical,
    call,
    other_expr,
    sys_call,
    clog2_value,
    replicate_count,
    select_range,
    select_width,
    select_base,
    select_of_expr,
    select_of_param,
    lvalue_no_base,
    lvalue_other,
    lvalue_param,
    lvalue_net,
    lvalue_nested,
    lvalue_indexed,
    lvalue_bit,
    timed_assign,
    proc_continuous,
    case_xz,
    loop,
    wait,
    trigger,
    disable,
    jump,
    contribution,
    no_event,
    not_event,
    mixed_edges,
    gate_array,
    duplicate,
    ordered_params,
    override_value,
    instance_array,
};

/// One refusal: its module (`Sites.modules` row; `none` for a file's UDP),
/// the walk's phase, the `initial`/`always` it is in (its ordinal among
/// the module's), its kind, its offset in the preprocessed text and the
/// name its message quotes ("" for none).
pub const Row = struct { module: u32, phase: Phase, group: u32, kind: Kind, at: u32, name: []const u8 };

/// The rows of a design, each module's in the old walk's order within a
/// phase; `modules` the module names in source order.
pub const Sites = struct {
    modules: []const []const u8,
    rows: std.MultiArrayList(Row),
};

/// No module: a row of the file.
pub const none: u32 = std.math.maxInt(u32);

/// The design's rows, files and modules in source order.
pub fn collect(arena: Allocator, zcu: *const Zcu, trees: []const *const Ast) Allocator.Error!Sites {
    assert(trees.len == zcu.files.len);
    var w: Walk = .{ .a = arena, .vir = undefined, .tree = undefined };
    var modules: std.ArrayList([]const u8) = .empty;
    for (0..zcu.files.len) |f| {
        w.vir = zcu.fileVir(@fromBackingInt(@intCast(f)));
        w.tree = trees[f];
        const builtin_end = zcu.files.items(.builtin_end)[f];
        try w.countParams(builtin_end);
        for (w.vir.decls(), 0..) |d, k| {
            if (k < builtin_end) continue;
            switch (d.kind) {
                .primitive => try w.row(.file, .udp, Walk.firstTok(w.tree, w.node(d.inst)), ""),
                .module, .macromodule, .connectmodule => {
                    w.module = @intCast(modules.items.len);
                    try modules.append(arena, w.vir.string(d.name));
                    try w.moduleRows(d.inst);
                },
                else => {}, // else: no digital design unit
            }
        }
    }
    assert(w.phase == .file or w.module != none);
    return .{ .modules = modules.items, .rows = w.rows };
}
