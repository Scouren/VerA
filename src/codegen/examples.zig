//! Hand-built devices for the shapes Sema does not lower yet but codegen
//! must spell, as `Air` + `Air.Device` (the test support this module
//! exports, as `Lower.Harness` was the old one's). `stack` is ESPice's
//! bsource.va pattern (lib/TODO.md §11.10): a §3.2.2 scratch array used as a
//! stack whose pointer moves at run time, so no pass can prove an element
//! written before it is read. Its oracle is `Air.interp` over the same body
//! (diff-codegen's scratch test) and the device text (src/codegen/test.zig).
//! Cites: VAMS-2023 §3.2.2 (an unwritten element reads 0), §5.6.
//!
//! Contents:
//! - `pub const Example = struct` (`deinit`)
//! - `pub const stack_len: u32`
//! - `pub fn stack(gpa: Allocator, ip: *InternPool) Allocator.Error!Example`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const Inst = Air.Inst;
const Ref = Inst.Ref;

/// One hand-built device; free with `deinit`.
pub const Example = struct {
    air: Air,
    device: Air.Device,

    /// Frees both.
    pub fn deinit(e: *Example, gpa: Allocator) void {
        e.air.deinit(gpa);
        e.device.deinit(gpa);
        e.* = undefined;
    }
};

/// The stack's elements: bsource.va's `st[0:15]`.
pub const stack_len: u32 = 16;

/// Two contributions over a 16-element real stack, every evaluation:
///
///     st = fresh; sp = 0;
///     for (k = 0; k < 3; k = k + 1) { st[sp] = k == 0 ? V(p) : k == 1 ? V(n) : V(p) * V(n); sp = sp + 1; }
///     I(p, n) <+ st[sp - 1] + st[sp - 2];
///     I(m) <+ st[5] + st[20] + st[-1];
///
/// `st[5]` is read before any write (0), `st[20]` and `st[-1]` lie outside
/// the array (0), and every store's index is a run-time integer.
pub fn stack(gpa: Allocator, ip: *InternPool) Allocator.Error!Example {
    var b = try Air.Builder.init(gpa);
    errdefer b.deinit(gpa);
    const arr = try ip.get(gpa, .{ .array_type = .{ .len = stack_len, .elem = .real_type } });
    const B = struct {
        b: *Air.Builder,
        gpa: Allocator,
        ip: *InternPool,
        fn inst(s: @This(), tag: Inst.Tag, data: Inst.Data) !Inst.Index {
            return s.b.addInst(s.gpa, .{ .tag = tag, .data = data });
        }
        fn bin(s: @This(), tag: Inst.Tag, l: Ref, r: Ref) !Inst.Index {
            return s.b.addBinOp(s.gpa, tag, l, r);
        }
        fn int(s: @This(), v: i64) !Ref {
            return .fromIntern(try s.ip.get(s.gpa, .{ .int = .{ .ty = .integer_type, .storage = .{ .small = v } } }));
        }
    };
    const t: B = .{ .b = &b, .gpa = gpa, .ip = ip };
    const vp = try t.inst(.probe, .{ .ty_index = .{ .ty = .real_type, .index = 0 } });
    const vn = try t.inst(.probe, .{ .ty_index = .{ .ty = .real_type, .index = 1 } });
    const st = try t.inst(.alloc, .{ .ty = arr });
    const sp = try t.inst(.alloc, .{ .ty = .integer_type });
    const k = try t.inst(.alloc, .{ .ty = .integer_type });
    const resist = try t.inst(.alloc, .{ .ty = .real_type });
    const react = try t.inst(.alloc, .{ .ty = .real_type });
    const wrote = try t.inst(.alloc, .{ .ty = .integer_type });
    const resist2 = try t.inst(.alloc, .{ .ty = .real_type });
    const react2 = try t.inst(.alloc, .{ .ty = .real_type });
    const wrote2 = try t.inst(.alloc, .{ .ty = .integer_type });
    const fresh = try t.inst(.anew, .{ .ty_pl = .{ .ty = arr, .payload = 0 } });
    const reset = try t.bin(.assign, .fromIndex(st), .fromIndex(fresh));
    const sp0 = try t.bin(.assign, .fromIndex(sp), .fromIntern(.zero));
    const k0 = try t.bin(.assign, .fromIndex(k), .fromIntern(.zero));

    // for (k = 0; k < 3; k = k + 1) { st[sp] = ...; sp = sp + 1; }
    const out = try t.inst(.block, undefined);
    const lp = try t.inst(.loop, undefined);
    const kv = try b.addUnOp(gpa, .load, .fromIndex(k));
    const go = try t.bin(.ilt, .fromIndex(kv), try t.int(3));
    const is0 = try t.bin(.ieq, .fromIndex(kv), .fromIntern(.zero));
    const is1 = try t.bin(.ieq, .fromIndex(kv), .fromIntern(.one));
    const prod = try t.bin(.fmul, .fromIndex(vp), .fromIndex(vn));
    const pick1 = try t.inst(.select, .{ .pl_op = .{ .operand = .fromIndex(is1), .payload = try b.addExtra(gpa, Air.Bin{ .lhs = .fromIndex(vn), .rhs = .fromIndex(prod) }) } });
    const pick0 = try t.inst(.select, .{ .pl_op = .{ .operand = .fromIndex(is0), .payload = try b.addExtra(gpa, Air.Bin{ .lhs = .fromIndex(vp), .rhs = .fromIndex(pick1) }) } });
    const spv = try b.addUnOp(gpa, .load, .fromIndex(sp));
    const ver = try b.addUnOp(gpa, .load, .fromIndex(st));
    const put = try t.inst(.store, .{ .pl_op = .{ .operand = .fromIndex(ver), .payload = try b.addExtra(gpa, Air.Bin{ .lhs = .fromIndex(spv), .rhs = .fromIndex(pick0) }) } });
    const keep = try t.bin(.assign, .fromIndex(st), .fromIndex(put));
    const sp1 = try t.bin(.iadd, .fromIndex(spv), .fromIntern(.one));
    const set_sp = try t.bin(.assign, .fromIndex(sp), .fromIndex(sp1));
    const k1 = try t.bin(.iadd, .fromIndex(kv), .fromIntern(.one));
    const set_k = try t.bin(.assign, .fromIndex(k), .fromIndex(k1));
    const again = try t.inst(.repeat, .{ .repeat = .{ .loop_inst = lp } });
    const leave = try t.inst(.br, .{ .br = .{ .block_inst = out, .operand = .none } });
    const step = try b.addCondBr(gpa, .fromIndex(go), &.{ is0, is1, prod, pick1, pick0, spv, ver, put, keep, sp1, set_sp, k1, set_k, again }, &.{leave});
    try b.setBody(gpa, lp, .none, &.{ kv, go, step });
    try b.setBody(gpa, out, .none, &.{lp});

    // I(p, n) <+ st[sp - 1] + st[sp - 2]; I(m) <+ st[5] + st[20] + st[-1];
    const top = try b.addUnOp(gpa, .load, .fromIndex(st));
    const spe = try b.addUnOp(gpa, .load, .fromIndex(sp));
    const at1 = try t.bin(.isub, .fromIndex(spe), .fromIntern(.one));
    const at2 = try t.bin(.isub, .fromIndex(spe), try t.int(2));
    const a = try t.bin(.fload, .fromIndex(top), .fromIndex(at1));
    const c = try t.bin(.fload, .fromIndex(top), .fromIndex(at2));
    const unwritten = try t.bin(.fload, .fromIndex(top), try t.int(5));
    const past = try t.bin(.fload, .fromIndex(top), try t.int(20));
    const before = try t.bin(.fload, .fromIndex(top), .fromIntern(.neg_one));
    const s1 = try t.bin(.fadd, .fromIndex(a), .fromIndex(c));
    const r0 = try b.addUnOp(gpa, .load, .fromIndex(resist));
    const r1 = try t.bin(.fadd, .fromIndex(r0), .fromIndex(s1));
    const set_r = try t.bin(.assign, .fromIndex(resist), .fromIndex(r1));
    const set_w = try t.bin(.assign, .fromIndex(wrote), .fromIntern(.one));
    // The zero reads alone, on their own row, so a non-zero shows whole.
    const z1 = try t.bin(.fadd, .fromIndex(unwritten), .fromIndex(past));
    const z2 = try t.bin(.fadd, .fromIndex(z1), .fromIndex(before));
    const q0 = try b.addUnOp(gpa, .load, .fromIndex(resist2));
    const q1 = try t.bin(.fadd, .fromIndex(q0), .fromIndex(z2));
    const set_q = try t.bin(.assign, .fromIndex(resist2), .fromIndex(q1));
    const set_w2 = try t.bin(.assign, .fromIndex(wrote2), .fromIntern(.one));
    const ret = try b.addUnOp(gpa, .ret, .fromIntern(.zero_real));
    var air = try b.finish(gpa, &.{ vp, vn, st, sp, k, resist, react, wrote, resist2, react2, wrote2, fresh, reset, sp0, k0, out, top, spe, at1, at2, a, c, unwritten, past, before, s1, r0, r1, set_r, set_w, z1, z2, q0, q1, set_q, set_w2, ret });
    errdefer air.deinit(gpa);

    var d: Air.Device = .{ .num_ports = 3 };
    errdefer d.deinit(gpa);
    for ([_][]const u8{ "p", "n", "m" }) |name| try d.nodes.append(gpa, .{ .name = try ip.getString(gpa, name), .kind = .net, .of = .none, .discipline = .empty });
    try d.contributions.append(gpa, .{ .access = .flow, .kind = .direct, .branch = .unnamed, .hi = @fromBackingInt(0), .lo = @fromBackingInt(1), .resist = resist, .react = react, .wrote = wrote });
    try d.contributions.append(gpa, .{ .access = .flow, .kind = .direct, .branch = .unnamed, .hi = @fromBackingInt(2), .lo = .ground, .resist = resist2, .react = react2, .wrote = wrote2 });
    assert(d.nodes.len == 3);
    return .{ .air = air, .device = d };
}
