//! §5.8.3 `case`, and §7.3.2's `casez`/`casex` over a two-state subject
//! (the old `analog/control.zig`'s case and `expr_case.zig`): the subject
//! once, then each arm's labels in order as nested `if`s, `default` the
//! final else. A `casez`/`casex` label's `z`/`?` bits (and `x` under
//! `casex`) are don't-cares; an `x` under `casez` never matches.
//! Cites: VAMS-2023 §5.8.3, §7.3.2; IEEE 1364-2005 §9.5.1.
//!
//! Contents:
//! - `pub fn lower(s: *Sema, b: *Block, x: Inst.Case) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const vams = @import("vams");
const Air = @import("air");
const Sema = @import("../Sema.zig");
const decl = @import("decl.zig");
const expr = @import("expr.zig");
const op = @import("op.zig");
const control = @import("control.zig");
const Vir = vams.Vir;
const Inst = Vir.Inst;
const Block = Sema.Block;

const Kind = @FieldType(@FieldType(Inst.Case, "flags"), "kind");

/// §5.8.3 `case`: the subject once, then each arm's labels in order, the
/// first equal one's statements run; `default` when none is.
pub fn lower(s: *Sema, b: *Block, x: Inst.Case) Allocator.Error!void {
    const vir = b.unit.vir;
    const subject = try expr.lower(s, b, x.operand);
    const arms = vir.list(Inst.Arm, x.arms);
    var default: ?Inst.Arm = null;
    for (arms) |a| if (a.flags.default) {
        // §5.8.3 "use of multiple default statements in one case statement
        // shall be illegal".
        if (default != null) try s.fail(.E0427, b.unit.file, .none, "", .{});
        default = a;
    };
    try caseFrom(s, b, subject, arms, default, 0, x.flags.kind);
}

// ---- private ----

/// The arms from `k` on, as nested `if`s.
fn caseFrom(s: *Sema, b: *Block, subject: Sema.Value, arms: []const Inst.Arm, default: ?Inst.Arm, k: usize, kind: Kind) Allocator.Error!void {
    var at = k;
    while (at < arms.len and arms[at].flags.default) at += 1;
    if (at == arms.len) {
        if (default) |d| try control.body(s, b, d.body);
        return;
    }
    const arm = arms[at];
    var hit: ?Air.Inst.Ref = null;
    for (b.unit.vir.list(Inst.Ref, arm.values)) |label| {
        // §7.3.2 a `casez`/`casex` label's don't-care bits.
        if (kind != .case and subject.ty == .integer) if (wild(b.unit.vir, label, kind)) |w| {
            const masked = try expr.binOp(s, b, .bitand, subject.ref, .fromIntern(try decl.intern(s, .{ .int = w.care })));
            const eq = if (w.never) Air.Inst.Ref.fromIntern(.zero) else try expr.binOp(s, b, .ieq, masked, .fromIntern(try decl.intern(s, .{ .int = w.value })));
            hit = if (hit) |h| try expr.binOp(s, b, .logor, h, eq) else eq;
            continue;
        };
        const l = try expr.lower(s, b, label);
        const real = subject.ty == .real or l.ty == .real;
        const ty: Sema.Ty = if (real) .real else .integer;
        const eq = try expr.binOp(s, b, if (real) .feq else .ieq, try expr.coerce(s, b, subject, ty), try expr.coerce(s, b, l, ty));
        hit = if (hit) |h| try expr.binOp(s, b, .logor, h, eq) else eq;
    }
    const rt: u32 = @intFromBool(!op.isStatic(s, hit orelse .fromIntern(.zero), 0));
    var then_b = b.child();
    then_b.conditional += 1;
    then_b.runtime += rt;
    try control.body(s, &then_b, arm.body);
    var else_b = b.child();
    else_b.conditional += 1;
    else_b.runtime += rt;
    try caseFrom(s, &else_b, subject, arms, default, at + 1, kind);
    try control.ifElse(s, b, hit orelse .fromIntern(.zero), &then_b, &else_b);
}

/// A based literal label with x, z or `?` digits under `casez`/`casex`
/// (IEEE 1364-2005 §9.5.1): the bits a two-state subject must equal, the
/// mask of those that count (`z`/`?` are don't-cares, and `x` too under
/// `casex`), and whether an `x` under `casez` makes the arm unmatchable.
/// Null for any other label.
fn wild(vir: *const Vir, label: Inst.Ref, kind: Kind) ?struct { value: i64, care: i64, never: bool } {
    const i = label.toIndex() orelse return null;
    if (vir.instructions.items(.tag)[@backingInt(i)] != .big_int) return null;
    const x = decl.payloadOf(vir, Inst.BigInt, i);
    const per: u6 = switch (x.flags.radix) {
        2 => 1,
        8 => 3,
        16 => 4,
        else => return null, // else: a decimal x or z is the whole value, not bits
    };
    const digits = vir.string(x.digits);
    if (std.mem.findAny(u8, digits, "xz?") == null) return null;
    var value: u64 = 0;
    var care: u64 = 0;
    var never = false;
    for (digits) |ch| {
        value <<= per;
        care <<= per;
        const ones: u64 = (@as(u64, 1) << per) - 1;
        switch (ch) {
            'z', '?' => {},
            'x' => if (kind == .casez) {
                never = true;
            },
            else => {
                value |= std.fmt.charToDigit(ch, x.flags.radix) catch return null;
                care |= ones;
            },
        }
    }
    const size: u32 = if (x.size == 0) 32 else x.size;
    if (size < 64) {
        value &= (@as(u64, 1) << @intCast(size)) - 1;
        care &= (@as(u64, 1) << @intCast(size)) - 1;
    }
    // Above the label's size its zero extension counts, up to the 32-bit
    // integer the subject is (§3.2).
    if (size < 32) care |= ((@as(u64, 1) << 32) - 1) & ~((@as(u64, 1) << @intCast(size)) - 1);
    if (size >= 64 or digits.len * per > 64) return null;
    return .{ .value = @bitCast(value), .care = @bitCast(care), .never = never };
}
