//! §4.2.13 concatenation and replication of sized integers (the old
//! parser's `foldBitConcat`): a `concat` or `replicate` whose every operand
//! is a sized literal, or such a concatenation or replication, in; its value
//! as an integer constant out, each operand's bits in order, the leftmost
//! most significant. A replication's count folds (a real is rounded,
//! §4.2.1); a zero count contributes no bits, and a concatenation with no
//! bits at all is E0326. Wider than 64 bits, or an x or z bit, is not this
//! form (the caller refuses it).
//! Cites: VAMS-2023 §2.6.1, §4.2.1, §4.2.13.
//!
//! Contents:
//! - `pub fn fold(s: *Sema, b: *Block, i: Inst.Index, src: Inst.Ref) Allocator.Error!?Sema.Value`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;

/// The deepest nesting of concatenations followed.
const depth_max: u32 = 64;

/// A run of bits: `value`'s low `width` bits.
const Bits = struct { value: u64, width: u32 };

/// The integer `concat`/`replicate` `i` folds to, or null when it is not
/// all sized literals (poison after E0326).
pub fn fold(s: *Sema, b: *Block, i: Inst.Index, src: Inst.Ref) Allocator.Error!?Sema.Value {
    const r = (try bitsOf(s, b, i.toRef(), 0)) orelse return null;
    if (r.width == 0) {
        try s.fail(.E0326, b.unit.file, src, "every operand has zero width", .{});
        return expr.poison;
    }
    assert(r.width <= 64);
    // §4.2.13 a concatenation is unsigned: the bits as written.
    if (r.width == 64 and r.value > std.math.maxInt(i64)) return null;
    return .{ .ref = .fromIntern(try decl.intern(s, .{ .int = @intCast(r.value) })), .ty = .integer };
}

// ---- private ----

fn bitsOf(s: *Sema, b: *Block, r: Inst.Ref, depth: u32) Allocator.Error!?Bits {
    if (depth > depth_max) return null;
    const i = r.toIndex() orelse return null;
    const vir = b.unit.vir;
    switch (vir.instructions.items(.tag)[@backingInt(i)]) {
        .big_int => {
            const x = decl.payloadOf(vir, Inst.BigInt, i);
            if (x.size == 0 or x.size > 64) return null;
            const c = (try decl.foldRef(s, b.unit, r)) orelse return null;
            const v: u64 = @bitCast(c.asIntExact() orelse return null);
            return .{ .value = if (x.size == 64) v else v & ((@as(u64, 1) << @intCast(x.size)) - 1), .width = x.size };
        },
        .concat => {
            var acc: Bits = .{ .value = 0, .width = 0 };
            for (vir.list(Inst.Ref, decl.payloadOf(vir, Inst.Refs, i))) |el| {
                const part = (try bitsOf(s, b, el, depth + 1)) orelse return null;
                acc = join(acc, part) orelse return null;
            }
            return acc;
        },
        .replicate => {
            const x = decl.payloadOf(vir, Inst.Bin, i);
            const n = ((try decl.foldRef(s, b.unit, x.lhs)) orelse return null).asIntExact() orelse return null;
            if (n < 0) return null;
            const one = (try bitsOf(s, b, x.rhs, depth + 1)) orelse return null;
            var acc: Bits = .{ .value = 0, .width = 0 };
            for (0..@intCast(@min(n, 65))) |_| acc = join(acc, one) orelse return null;
            return acc;
        },
        else => return null, // else: no width the text fixes
    }
}

/// `hi` then `lo`, or null past 64 bits.
fn join(hi: Bits, lo: Bits) ?Bits {
    const width = hi.width + lo.width;
    if (width > 64) return null;
    if (lo.width == 64) return lo;
    return .{ .value = (hi.value << @intCast(lo.width)) | lo.value, .width = width };
}
