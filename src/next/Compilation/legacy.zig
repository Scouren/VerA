//! The IEEE 1364 route's reports in the old driver's words: a refusal the
//! rewrite raises under its own catalogue code (an elaboration `Zcu.Rule`,
//! or an AstGen code) in, the code and text lib/sim/digital printed for it
//! out: E1100 "digital source execution failed: ..." for most, the same
//! code reworded for the rest. One table; every site keeps its code and
//! its logic. The suite's `//! reject E1100` fixtures hold it, unedited.
//! Cites: IEEE 1364-2005 §8.6, §12.2, §12.2.1, §12.2.2.2, §12.3.3,
//! §12.3.6, §13.2.1.1, §13.5.1.
//!
//! Contents:
//! - `pub fn rule(w: *Diag.Wip, r: Zcu.Rule, loc: Diag.Loc, name: []const u8, nums: [2]u32, order: []const u8) Allocator.Error!void`
//! - `pub fn byCode(c: Diag.Code) bool`
//! - `pub fn code(w: *Diag.Wip, c: Diag.Code, loc: Diag.Loc, text: []const u8) Allocator.Error!void`
//! - `pub fn searchOrder(arena: Allocator, zcu: *const Zcu) Allocator.Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const sema = @import("sema");
const Diag = vams.Diag;
const Zcu = sema.Zcu;

/// Reports the refusal `r` names, quoting `name` and `nums` (and for an
/// unbound cell the search order `order`), at the start of `loc`, as
/// lib/sim/digital placed its reports.
pub fn rule(w: *Diag.Wip, r: Zcu.Rule, loc: Diag.Loc, name: []const u8, nums: [2]u32, order: []const u8) Allocator.Error!void {
    assert(r != .none);
    var at = loc;
    at.end = at.start;
    var b = w.build(.lower, r.code(), at);
    switch (r) {
        .none => unreachable, // asserted above
        .port_count => b.msg("more port connections than the module has ports", .{}),
        .port_mixed => b.msg("§12.3.6: an instance mixes ordered and named port connections", .{}),
        .port_unknown => b.msg("the instantiated module has no such port", .{}),
        .port_twice => b.msg("§12.3.6: port `{s}` is connected twice", .{name}),
        .param_twice => b.msg("§12.2.2.2: parameter `{s}` is assigned twice", .{name}),
        .param_unknown => b.msg("§12.2.2.2: the module has no such parameter: `{s}`", .{name}),
        .param_local => b.msg("§12.2: `{s}` is a local parameter, which a parameter value assignment cannot override", .{name}),
        .udp_delay => b.msg("§8.6: a UDP instance takes at most two delays", .{}),
        .cell_unbound => b.msg("undeclared module in instantiation: no library of the search order ({s}) holds cell `{s}`", .{ order, name }),
        .defparam_unknown => b.msg("§12.2.1: this defparam names `{s}`, which is no parameter of its module", .{name}),
        .cell_again => b.msg("`{s}` is defined again; this later definition is the cell", .{name}),
        .config => b.msg("{s}", .{name}),
        .defparam_nothing => b.msg("§12.2.1: this defparam's hierarchical name `{s}` names nothing in the design", .{name}),
        .defparam_early => b.msg("§12.8.2: this defparam's hierarchical name was resolved before the hierarchy was complete and would resolve differently once it is", .{}),
        .defparam_outside => b.msg("§12.2.1: a defparam inside `{s}` cannot change a parameter outside the generate block instance or array element it is in", .{name}),
        .param_extra => b.msg("§12.2.2.1: {d} more parameter value(s) than the module has parameters ({d}); the extra ones are ignored", .{ nums[0], nums[1] }),
    }
    try b.emit();
}

/// Whether AstGen's code `c` takes the old words on the 1364 route.
pub fn byCode(c: Diag.Code) bool {
    return c == .E0376;
}

/// Reports AstGen's `c` (`byCode`) at `loc`, quoting `text`, the source
/// under its caret.
pub fn code(w: *Diag.Wip, c: Diag.Code, loc: Diag.Loc, text: []const u8) Allocator.Error!void {
    assert(byCode(c));
    var at = loc;
    at.end = at.start;
    var b = w.build(.lower, .E1100, at);
    b.msg("§12.3.3: port `{s}` has no direction declaration", .{text});
    try b.emit();
}

/// §13.5.1's default search order, as lib/sim/digital named it: the
/// libraries in order, one space apart (`work` when none is mapped).
pub fn searchOrder(arena: Allocator, zcu: *const Zcu) Allocator.Error![]const u8 {
    if (zcu.lib_order.len == 0) return "work";
    var out: std.ArrayList(u8) = .empty;
    for (zcu.lib_order, 0..) |l, k| {
        if (k != 0) try out.append(arena, ' ');
        try out.appendSlice(arena, zcu.intern_pool.stringToSlice(l));
    }
    assert(out.items.len != 0);
    return out.items;
}
