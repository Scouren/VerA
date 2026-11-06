//! `sites.collect` over a hand-written design with one of each item kind
//! the old `--emit-rtlil` refuses. Oracle: the old emitter's rules read
//! by hand (src/codegen/digital/rtlil_module.zig `design`, `module`,
//! `declare`; rtlil_proc.zig `initial`): each row's kind, phase and the
//! byte of the token the old parser's `main_tok` names, found in the
//! source text by its spelling.
//! Cites: IEEE 1364-2005 §4.9.3, §7.6, §8, §9.2, §10.
//!
//! Contents: tests only.

const std = @import("std");
const vams = @import("vams");
const Zcu = @import("../../Zcu.zig");
const Sema = @import("../../Sema.zig");
const sites = @import("sites.zig");

test "sites: a UDP, an event, a task, a switch, a memory, a real and an initial each at the old main_tok" {
    const src =
        \\module m(a);
        \\  input a;
        \\  event ev;
        \\  task t; begin end endtask
        \\  wire x, y;
        \\  tran sw(x, y);
        \\  reg [3:0] mem [0:1];
        \\  real r;
        \\  reg q;
        \\  initial begin q = 1'b0; q = a; $display(q); end
        \\endmodule
        \\primitive p(o, i); output o; input i; table 0 : 1 ; 1 : 0 ; endtable endprimitive
        \\
    ;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var pp: vams.Preprocessor = .init(a, .{ .std_defs = false });
    try pp.addUnit("m.v", src);
    while (try pp.run()) |_| return error.UnexpectedInclude;
    const out = pp.output();
    const text = try a.dupeSentinel(u8, out.text, 0);
    var tree = try vams.Ast.parse(a, text, .{});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    const vir = try vams.AstGen.generate(a, &tree, .{ .directives = out.directives });
    var zcu: Zcu = try .init(a);
    _ = try zcu.addFile("m.v", vir, 0);
    try Sema.elaborate(&zcu, .{ .roots = .all });
    const s = try sites.collect(a, &zcu, &.{&tree});

    const Want = struct { kind: sites.Kind, phase: sites.Phase, at: usize };
    const off = struct {
        fn of(t: []const u8, needle: []const u8) usize {
            return std.mem.find(u8, t, needle).?;
        }
    }.of;
    const want = [_]Want{
        // E1201 the `primitive` keyword, a row of the file.
        .{ .kind = .udp, .phase = .file, .at = off(text, "primitive") },
        // E1206 the `task` keyword; E1208 the event's name; E1210 the switch's instance name.
        .{ .kind = .task, .phase = .item, .at = off(text, "task") },
        .{ .kind = .event, .phase = .item, .at = off(text, "ev;") },
        .{ .kind = .switch_prim, .phase = .item, .at = off(text, "sw(") },
        // E1217 and E1218 at the declared name.
        .{ .kind = .var_array, .phase = .variable, .at = off(text, "mem ") },
        .{ .kind = .var_real, .phase = .variable, .at = off(text, "r;") },
        // E1254 `q = a` reads a variable; E1251 `$display` is no assignment.
        .{ .kind = .init_value, .phase = .initial_stmt, .at = off(text, "q = a") },
        .{ .kind = .init_other, .phase = .initial_stmt, .at = off(text, "$display") },
    };
    const kinds = s.rows.items(.kind);
    try std.testing.expectEqual(want.len, s.rows.len);
    for (want) |w| {
        const k = for (kinds, 0..) |k, i| {
            if (k == w.kind) break i;
        } else return error.TestExpectedRow;
        try std.testing.expectEqual(w.phase, s.rows.items(.phase)[k]);
        try std.testing.expectEqual(w.at, s.rows.items(.at)[k]);
    }
    try std.testing.expectEqualStrings("mem", s.rows.items(.name)[
        for (kinds, 0..) |k, i| {
            if (k == .var_array) break i;
        } else unreachable
    ]);
}
