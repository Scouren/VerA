//! Every interned string, type and constant of a compilation behind one
//! `Index` (Zig's `src/InternPool.zig`, single-threaded): a `Key` in, its
//! deduplicated `Index` out, and back. Interning the same key twice gives the
//! same `Index`; indexes are handed out in insertion order, so equal input
//! gives equal indexes. A real constant is keyed by its exact bits, so `-0.0`
//! and `0.0` differ and every NaN payload stays its own constant. Nodes and
//! branches are per-instance rows, not keys (lib/TODO.md appendix A.3).
//! Cites: VAMS-2023 §2.7 (strings), §3.2 (`integer`, `real`), §3.2.2
//! (arrays), §3.6.2 (natures, disciplines, domains); IEEE 1364-2005 §4.2
//! (sized vectors).
//!
//! Contents:
//! - `pub const Index = enum(u32)`, with the well-known indexes `real_type`,
//!   `integer_type`, `string_type`, `undef`, `zero_real`, `one_real`,
//!   `neg_one_real`, `two_real`, `ten_real`, `inf_real`, `zero`, `one`, `neg_one`
//! - `pub const String = enum(u32)`
//! - `pub const Key = union(enum)` (`SimpleType`, `IntType`, `ArrayType`, `Nature`,
//!   `Discipline` (`Domain`), `Int` (`Storage`), `Aggregate`)
//! - `pub const items_max: u32`
//! - `pub fn init(gpa: Allocator) Allocator.Error!InternPool`
//! - `pub fn deinit(ip: *InternPool, gpa: Allocator) void`
//! - `pub fn get(ip: *InternPool, gpa: Allocator, key: Key) Allocator.Error!Index`
//! - `pub fn indexToKey(ip: *const InternPool, index: Index) Key`
//! - `pub fn typeOf(ip: *const InternPool, index: Index) Index`
//! - `pub fn getString(ip: *InternPool, gpa: Allocator, bytes: []const u8) Allocator.Error!String`
//! - `pub fn stringToSlice(ip: *const InternPool, s: String) [:0]const u8`
//! - `pub fn keyEql(a: Key, b: Key) bool`
//! - the private dedup adapters' `pub fn hash` and `pub fn eql` (the hash maps call them)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Wyhash = std.hash.Wyhash;
const ahm = std.array_hash_map;

/// One row per interned key; row `i` is `Index` `i`.
items: std.MultiArrayList(Item) = .empty,
/// The payloads that do not fit an item's `data` word, as `u32` words.
extra: std.ArrayList(u32) = .empty,
/// Every interned string as a little-endian `u32` length, the bytes and a
/// NUL; a `String` is the offset of its length. Offset 0 holds `""`.
string_bytes: std.ArrayList(u8) = .empty,
/// Key → item dedup: entry `i` is item `i`; the key is re-read from the item
/// (`Adapter`), so an entry costs its stored hash only.
map: ahm.Custom(void, void, ahm.AutoContext(void), true) = .empty,
/// Bytes → `String` dedup, read through `StringAdapter`.
string_table: ahm.Custom(String, void, ahm.AutoContext(String), true) = .empty,

/// An interned type or value. `none` is the absent one. The first indexes
/// are fixed at compile time (`init` interns them in this order); the
/// constants are the sentinels the old MIR kept (`src/ir/Mir.zig` `Value`).
pub const Index = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    /// §3.2 `real`.
    pub const real_type: Index = @fromBackingInt(0);
    /// §3.2 `integer`: 32-bit signed.
    pub const integer_type: Index = @fromBackingInt(1);
    /// §2.7 `string`.
    pub const string_type: Index = @fromBackingInt(2);
    /// An undefined real: the old MIR's `Value.undef`.
    pub const undef: Index = @fromBackingInt(3);
    /// The reals 0.0, 1.0, -1.0, 2.0, 10.0 and +inf.
    pub const zero_real: Index = @fromBackingInt(4);
    pub const one_real: Index = @fromBackingInt(5);
    pub const neg_one_real: Index = @fromBackingInt(6);
    pub const two_real: Index = @fromBackingInt(7);
    pub const ten_real: Index = @fromBackingInt(8);
    pub const inf_real: Index = @fromBackingInt(9);
    /// The integers 0, 1 and -1.
    pub const zero: Index = @fromBackingInt(10);
    pub const one: Index = @fromBackingInt(11);
    pub const neg_one: Index = @fromBackingInt(12);
};

/// An interned byte string: an offset into the pool's string bytes; 0 is "".
pub const String = enum(u32) { empty = 0, _ };

/// What an `Index` stands for. A key that names another `Index` (`elem`,
/// `ty`, a nature) names one already interned.
pub const Key = union(enum) {
    simple_type: SimpleType,
    /// A declared-width integer (IEEE 1364-2005 §4.2), wider than 32 bits
    /// included. Distinct from `integer` even at 32 signed bits: a declared
    /// width is not the §3.2 type.
    int_type: IntType,
    array_type: ArrayType,
    nature: Nature,
    discipline: Discipline,
    /// An undefined value of the type it names.
    undef: Index,
    /// A `real` constant, keyed by its exact bits.
    float: f64,
    int: Int,
    /// A `string` constant.
    str: String,
    /// An array constant, or a tuple of values (`Zcu.Instance.params`).
    aggregate: Aggregate,

    /// The three §3.2/§2.7 types with no parameter.
    pub const SimpleType = enum(u8) { real, integer, string };
    /// `bits` wide, two's complement when `signed`; `bits` is at least 1.
    pub const IntType = struct { bits: u16, signed: bool };
    /// §3.2.2: `len` elements of `elem`, a type.
    pub const ArrayType = struct { len: u32, elem: Index };
    /// §3.6.2.1: `abstol` is a real constant; `ddt_nature` and `idt_nature`
    /// are natures; each may be `.none`, as `access` and `units` may be `.empty`.
    pub const Nature = struct {
        name: String,
        access: String,
        abstol: Index,
        units: String,
        ddt_nature: Index,
        idt_nature: Index,
    };
    /// §3.6.2.2: `potential` and `flow` are natures or `.none`; `domain` is
    /// as declared (`unspecified` when the source names none).
    pub const Discipline = struct {
        name: String,
        potential: Index,
        flow: Index,
        domain: Domain,

        pub const Domain = enum(u8) { unspecified, continuous, discrete };
    };
    /// An integer constant of type `ty` (`integer_type` or an `int_type`).
    /// A value that fits an `i64` is `small`; a wider one is `big`, its
    /// shortest two's-complement `u32` limbs, least significant first (at
    /// least three: two fit an `i64`).
    pub const Int = struct {
        ty: Index,
        storage: Storage,

        pub const Storage = union(enum) { small: i64, big: []const u32 };
    };
    /// `elems` are values; `ty` is their `array_type`, or `.none` for a
    /// tuple (a §6.3 instance's folded parameters, of mixed types). The
    /// slice `indexToKey` returns lives as `Int.big`'s does.
    pub const Aggregate = struct { ty: Index, elems: []const Index };
};

/// Most items one pool holds: `Air.Inst.Ref` keeps the high bit for
/// instruction indexes, so an `Index` stays below 2^31.
pub const items_max: u32 = 1 << 31;

/// How an item's `data` word is read.
const Tag = enum(u8) {
    /// `data` is a `Key.SimpleType`.
    simple_type,
    /// `data` is `bits | signed << 16`.
    int_type,
    /// `data` is the offset of a `Key.ArrayType` in `extra`.
    array_type,
    /// `data` is the offset of a `Key.Nature` in `extra`.
    nature,
    /// `data` is the offset of a `Key.Discipline` in `extra`.
    discipline,
    /// `data` is the type `Index`.
    undef,
    /// `data` is the offset of a `Bits64` in `extra`.
    float,
    /// `data` is the offset of an `IntSmall` in `extra`.
    int_small,
    /// `data` is the offset of an `IntBig` in `extra`, its limbs after it.
    int_big,
    /// `data` is the `String`.
    str,
    /// `data` is the offset of an `AggregateHead` in `extra`, its
    /// elements after it.
    aggregate,
};

const Item = struct { tag: Tag, data: u32 };

const Bits64 = struct { lo: u32, hi: u32 };
const IntSmall = struct { ty: Index, lo: u32, hi: u32 };
const IntBig = struct { ty: Index, len: u32 };
const AggregateHead = struct { ty: Index, len: u32 };

const InternPool = @This();

/// Hashes and compares a `Key` against the item an entry stands for.
const Adapter = struct {
    ip: *const InternPool,

    pub fn hash(_: Adapter, key: Key) u32 {
        return hashKey(key);
    }
    pub fn eql(ctx: Adapter, a: Key, _: void, b_index: usize) bool {
        return keyEql(a, ctx.ip.indexToKey(@fromBackingInt(@intCast(b_index))));
    }
};

/// Hashes and compares bytes against an interned `String`.
const StringAdapter = struct {
    bytes: []const u8,

    pub fn hash(_: StringAdapter, s: []const u8) u32 {
        return @truncate(Wyhash.hash(0, s));
    }
    pub fn eql(ctx: StringAdapter, a: []const u8, b: String, _: usize) bool {
        const at = @backingInt(b);
        const len = std.mem.readInt(u32, ctx.bytes[at..][0..4], .little);
        return std.mem.eql(u8, a, ctx.bytes[at + 4 ..][0..len]);
    }
};

/// The keys of the well-known indexes, in `Index` order.
const well_known = [_]Key{
    .{ .simple_type = .real },
    .{ .simple_type = .integer },
    .{ .simple_type = .string },
    .{ .undef = .real_type },
    .{ .float = 0.0 },
    .{ .float = 1.0 },
    .{ .float = -1.0 },
    .{ .float = 2.0 },
    .{ .float = 10.0 },
    .{ .float = std.math.inf(f64) },
    .{ .int = .{ .ty = .integer_type, .storage = .{ .small = 0 } } },
    .{ .int = .{ .ty = .integer_type, .storage = .{ .small = 1 } } },
    .{ .int = .{ .ty = .integer_type, .storage = .{ .small = -1 } } },
};

comptime {
    assert(@sizeOf(Tag) == 1);
    assert(@backingInt(Index.neg_one) == well_known.len - 1);
}

/// Returns a pool holding `""` and the well-known indexes. The caller frees
/// it with `deinit`, using the same `gpa`.
pub fn init(gpa: Allocator) Allocator.Error!InternPool {
    var ip: InternPool = .{};
    errdefer ip.deinit(gpa);
    try ip.string_bytes.appendSlice(gpa, &.{ 0, 0, 0, 0, 0 });
    for (well_known, 0..) |key, i| {
        const index = try ip.get(gpa, key);
        assert(@backingInt(index) == i);
    }
    assert(ip.items.len == well_known.len);
    return ip;
}

/// Frees every table; every `Key.Int.big` and string slice handed out dies.
pub fn deinit(ip: *InternPool, gpa: Allocator) void {
    ip.items.deinit(gpa);
    ip.extra.deinit(gpa);
    ip.string_bytes.deinit(gpa);
    ip.map.deinit(gpa);
    ip.string_table.deinit(gpa);
    ip.* = undefined;
}

/// Returns the index of `key`, interning it on first sight. Invalidates the
/// slices earlier `indexToKey` calls returned (`Key.Int.big`). Asserts that
/// every `Index` and `String` the key names exists, that an `int` is in its
/// canonical form (`Key.Int`), and that the pool holds fewer than
/// `items_max` items.
pub fn get(ip: *InternPool, gpa: Allocator, key: Key) Allocator.Error!Index {
    ip.assertKey(key);
    const gop = try ip.map.getOrPutAdapted(gpa, key, Adapter{ .ip = ip });
    if (gop.found_existing) return @fromBackingInt(@intCast(gop.index));
    errdefer ip.map.swapRemoveAt(gop.index);
    assert(gop.index == ip.items.len);
    assert(ip.items.len < items_max);
    const item: Item = switch (key) {
        .simple_type => |s| .{ .tag = .simple_type, .data = @backingInt(s) },
        .int_type => |t| .{ .tag = .int_type, .data = t.bits | @as(u32, @intFromBool(t.signed)) << 16 },
        .array_type => |a| .{ .tag = .array_type, .data = try ip.addExtra(gpa, a) },
        .nature => |n| .{ .tag = .nature, .data = try ip.addExtra(gpa, n) },
        .discipline => |d| .{ .tag = .discipline, .data = try ip.addExtra(gpa, d) },
        .undef => |ty| .{ .tag = .undef, .data = @backingInt(ty) },
        .float => |f| .{ .tag = .float, .data = try ip.addExtra(gpa, split(@bitCast(f))) },
        .int => |int| switch (int.storage) {
            .small => |v| blk: {
                const w = split(@bitCast(v));
                break :blk .{ .tag = .int_small, .data = try ip.addExtra(gpa, IntSmall{ .ty = int.ty, .lo = w.lo, .hi = w.hi }) };
            },
            .big => |limbs| blk: {
                try ip.extra.ensureUnusedCapacity(gpa, 2 + limbs.len);
                const at = try ip.addExtra(gpa, IntBig{ .ty = int.ty, .len = @intCast(limbs.len) });
                ip.extra.appendSliceAssumeCapacity(limbs);
                break :blk .{ .tag = .int_big, .data = at };
            },
        },
        .str => |s| .{ .tag = .str, .data = @backingInt(s) },
        .aggregate => |a| blk: {
            try ip.extra.ensureUnusedCapacity(gpa, 2 + a.elems.len);
            const at = try ip.addExtra(gpa, AggregateHead{ .ty = a.ty, .len = @intCast(a.elems.len) });
            ip.extra.appendSliceAssumeCapacity(@ptrCast(a.elems));
            break :blk .{ .tag = .aggregate, .data = at };
        },
    };
    try ip.items.append(gpa, item);
    const index: Index = @fromBackingInt(@intCast(gop.index));
    assert(keyEql(ip.indexToKey(index), key));
    return index;
}

/// Returns the key `index` was interned from. A `Key.Int.big` slice points
/// into the pool and lives until the next `get` or `deinit`. Asserts that
/// `index` exists.
pub fn indexToKey(ip: *const InternPool, index: Index) Key {
    assert(index != .none);
    assert(@backingInt(index) < ip.items.len);
    const item = ip.items.get(@backingInt(index));
    return switch (item.tag) {
        .simple_type => .{ .simple_type = @fromBackingInt(@as(u8, @intCast(item.data))) },
        .int_type => .{ .int_type = .{ .bits = @truncate(item.data), .signed = item.data >> 16 != 0 } },
        .array_type => .{ .array_type = ip.extraData(Key.ArrayType, item.data) },
        .nature => .{ .nature = ip.extraData(Key.Nature, item.data) },
        .discipline => .{ .discipline = ip.extraData(Key.Discipline, item.data) },
        .undef => .{ .undef = @fromBackingInt(item.data) },
        .float => .{ .float = @bitCast(join(ip.extraData(Bits64, item.data))) },
        .int_small => blk: {
            const s = ip.extraData(IntSmall, item.data);
            break :blk .{ .int = .{ .ty = s.ty, .storage = .{ .small = @bitCast(join(.{ .lo = s.lo, .hi = s.hi })) } } };
        },
        .int_big => blk: {
            const b = ip.extraData(IntBig, item.data);
            const limbs = ip.extra.items[item.data + 2 ..][0..b.len];
            break :blk .{ .int = .{ .ty = b.ty, .storage = .{ .big = limbs } } };
        },
        .str => .{ .str = @fromBackingInt(item.data) },
        .aggregate => blk: {
            const h = ip.extraData(AggregateHead, item.data);
            const elems: []const Index = @ptrCast(ip.extra.items[item.data + 2 ..][0..h.len]);
            break :blk .{ .aggregate = .{ .ty = h.ty, .elems = elems } };
        },
    };
}

/// Returns the type of the value `index`: `real_type` for a float,
/// `string_type` for a string, the named type for an int, undef or array.
/// Asserts that `index` is a value, not a type, nature, discipline or tuple.
pub fn typeOf(ip: *const InternPool, index: Index) Index {
    const ty: Index = switch (ip.indexToKey(index)) {
        .float => .real_type,
        .str => .string_type,
        .int => |int| int.ty,
        .undef => |t| t,
        .aggregate => |a| a.ty,
        .simple_type, .int_type, .array_type, .nature, .discipline => unreachable, // a type has no type here
    };
    assert(isType(ip, ty));
    return ty;
}

/// Returns the `String` of `bytes`, interning them on first sight; `""` is
/// `.empty`. Bytes may hold NUL. Invalidates every slice `stringToSlice`
/// returned. Asserts that `bytes` is shorter than 4 GiB.
pub fn getString(ip: *InternPool, gpa: Allocator, bytes: []const u8) Allocator.Error!String {
    assert(bytes.len < std.math.maxInt(u32));
    if (bytes.len == 0) return .empty;
    const adapter: StringAdapter = .{ .bytes = ip.string_bytes.items };
    const gop = try ip.string_table.getOrPutAdapted(gpa, bytes, adapter);
    if (gop.found_existing) return gop.key_ptr.*;
    errdefer ip.string_table.swapRemoveAt(gop.index);
    const at: u32 = @intCast(ip.string_bytes.items.len);
    try ip.string_bytes.ensureUnusedCapacity(gpa, 4 + bytes.len + 1);
    ip.string_bytes.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(bytes.len))));
    ip.string_bytes.appendSliceAssumeCapacity(bytes);
    ip.string_bytes.appendAssumeCapacity(0);
    gop.key_ptr.* = @fromBackingInt(at);
    assert(std.mem.eql(u8, ip.stringToSlice(gop.key_ptr.*), bytes));
    return gop.key_ptr.*;
}

/// Returns the bytes of `s`, NUL-terminated; they live until the next
/// `getString` or `deinit`. Asserts that `s` was returned by this pool.
pub fn stringToSlice(ip: *const InternPool, s: String) [:0]const u8 {
    const at = @backingInt(s);
    assert(at + 5 <= ip.string_bytes.items.len);
    const len = std.mem.readInt(u32, ip.string_bytes.items[at..][0..4], .little);
    assert(ip.string_bytes.items[at + 4 + len] == 0);
    return ip.string_bytes.items[at + 4 ..][0..len :0];
}

/// Returns whether two keys name the same thing: a float by its bits, a big
/// integer limb by limb, everything else field by field. The pool's dedup
/// relation.
pub fn keyEql(a: Key, b: Key) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .float => |f| @as(u64, @bitCast(f)) == @as(u64, @bitCast(b.float)),
        .int => |x| x.ty == b.int.ty and switch (x.storage) {
            .small => |v| b.int.storage == .small and b.int.storage.small == v,
            .big => |l| b.int.storage == .big and std.mem.eql(u32, l, b.int.storage.big),
        },
        .aggregate => |x| x.ty == b.aggregate.ty and std.mem.eql(Index, x.elems, b.aggregate.elems),
        inline .simple_type, .int_type, .array_type, .nature, .discipline, .undef, .str => |v, tag| std.meta.eql(v, @field(b, @tagName(tag))),
    };
}

// ---- private ----

fn hashKey(key: Key) u32 {
    var h = Wyhash.init(@backingInt(std.meta.activeTag(key)));
    switch (key) {
        .float => |f| std.hash.autoHash(&h, @as(u64, @bitCast(f))),
        .int => |int| {
            std.hash.autoHash(&h, int.ty);
            switch (int.storage) {
                .small => |v| std.hash.autoHash(&h, v),
                .big => |limbs| h.update(std.mem.sliceAsBytes(limbs)),
            }
        },
        .aggregate => |a| {
            std.hash.autoHash(&h, a.ty);
            h.update(std.mem.sliceAsBytes(a.elems));
        },
        inline .simple_type, .int_type, .array_type, .nature, .discipline, .undef, .str => |v| std.hash.autoHash(&h, v),
    }
    return @truncate(h.final());
}

/// Asserts `get`'s preconditions on `key`.
fn assertKey(ip: *const InternPool, key: Key) void {
    switch (key) {
        .simple_type, .float => {},
        .int_type => |t| assert(t.bits >= 1),
        .array_type => |a| assert(isType(ip, a.elem)),
        .nature => |n| {
            for ([_]String{ n.name, n.access, n.units }) |s| ip.assertString(s);
            if (n.abstol != .none) assert(ip.indexToKey(n.abstol) == .float);
            for ([_]Index{ n.ddt_nature, n.idt_nature }) |d| if (d != .none) assert(ip.indexToKey(d) == .nature);
        },
        .discipline => |d| {
            ip.assertString(d.name);
            for ([_]Index{ d.potential, d.flow }) |n| if (n != .none) assert(ip.indexToKey(n) == .nature);
        },
        .undef => |ty| assert(isType(ip, ty)),
        .int => |int| {
            const k = ip.indexToKey(int.ty);
            assert(k == .int_type or (k == .simple_type and k.simple_type == .integer));
            if (int.storage == .big) {
                const l = int.storage.big;
                assert(l.len >= 3);
                // Shortest: the top limb is not the sign extension of the one below.
                const ext: u32 = if (l[l.len - 2] >> 31 != 0) std.math.maxInt(u32) else 0;
                assert(l[l.len - 1] != ext);
            }
        },
        .str => |s| ip.assertString(s),
        .aggregate => |a| {
            if (a.ty != .none) {
                const t = ip.indexToKey(a.ty);
                assert(t == .array_type);
                assert(t.array_type.len == a.elems.len);
            }
            for (a.elems) |e| assert(!isType(ip, e));
            for (a.elems) |e| assert(@backingInt(e) < ip.items.len);
        },
    }
}

fn assertString(ip: *const InternPool, s: String) void {
    assert(@backingInt(s) + 5 <= ip.string_bytes.items.len);
}

fn isType(ip: *const InternPool, index: Index) bool {
    if (index == .none or @backingInt(index) >= ip.items.len) return false;
    return switch (ip.items.items(.tag)[@backingInt(index)]) {
        .simple_type, .int_type, .array_type => true,
        .nature, .discipline, .undef, .float, .int_small, .int_big, .str, .aggregate => false,
    };
}

fn addExtra(ip: *InternPool, gpa: Allocator, v: anytype) Allocator.Error!u32 {
    const info = @typeInfo(@TypeOf(v)).@"struct";
    const at: u32 = @intCast(ip.extra.items.len);
    try ip.extra.ensureUnusedCapacity(gpa, info.field_names.len);
    inline for (info.field_names) |name| ip.extra.appendAssumeCapacity(toWord(@field(v, name)));
    assert(ip.extra.items.len == at + info.field_names.len);
    return at;
}

fn extraData(ip: *const InternPool, comptime T: type, at: u32) T {
    const info = @typeInfo(T).@"struct";
    assert(at + info.field_names.len <= ip.extra.items.len);
    var r: T = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, F, i| {
        const w = ip.extra.items[at + i];
        @field(r, name) = switch (@typeInfo(F)) {
            .int => w,
            .@"enum" => @fromBackingInt(@intCast(w)),
            else => @compileError("extra field " ++ name),
        };
    }
    return r;
}

fn toWord(x: anytype) u32 {
    return switch (@typeInfo(@TypeOf(x))) {
        .int => x,
        .@"enum" => @backingInt(x),
        else => @compileError("extra field type " ++ @typeName(@TypeOf(x))),
    };
}

fn split(x: u64) Bits64 {
    return .{ .lo = @truncate(x), .hi = @truncate(x >> 32) };
}

fn join(b: Bits64) u64 {
    return @as(u64, b.hi) << 32 | b.lo;
}

/// The tests' own key equality: floats by bits through a `u64` compare,
/// big integers limb by limb, the rest through `std.meta.eql`.
fn modelEql(a: Key, b: Key) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    if (a == .float) return std.mem.eql(u8, std.mem.asBytes(&a.float), std.mem.asBytes(&b.float));
    if (a == .int and a.int.storage == .big) {
        if (b.int.storage != .big) return false;
        return a.int.ty == b.int.ty and std.mem.eql(u32, a.int.storage.big, b.int.storage.big);
    }
    return std.meta.eql(a, b);
}

/// A random key over small value spaces, so keys repeat and dedup is
/// exercised; `limbs` backs a big integer's slice.
fn randomKey(ip: *InternPool, gpa: Allocator, rnd: std.Random, limbs: *[6]u32) !Key {
    const names = [_][]const u8{ "electrical", "V", "I", "", "a\x00b", "thermal" };
    const name = try ip.getString(gpa, names[rnd.uintLessThan(usize, names.len)]);
    const any: Index = @fromBackingInt(rnd.uintLessThan(u32, @intCast(ip.items.len)));
    return switch (rnd.uintLessThan(u8, 10)) {
        0 => .{ .simple_type = rnd.enumValue(Key.SimpleType) },
        1 => .{ .int_type = .{ .bits = rnd.intRangeAtMost(u16, 1, 70), .signed = rnd.boolean() } },
        2 => .{ .array_type = .{ .len = rnd.uintLessThan(u32, 4), .elem = @fromBackingInt(rnd.uintLessThan(u32, 3)) } },
        3 => .{ .nature = .{
            .name = name,
            .access = name,
            .abstol = if (rnd.boolean()) .none else .ten_real,
            .units = .empty,
            .ddt_nature = if (ip.indexToKey(any) == .nature) any else .none,
            .idt_nature = .none,
        } },
        4 => .{ .discipline = .{
            .name = name,
            .potential = if (ip.indexToKey(any) == .nature) any else .none,
            .flow = .none,
            .domain = rnd.enumValue(Key.Discipline.Domain),
        } },
        5 => .{ .undef = if (rnd.boolean()) .real_type else .integer_type },
        6 => .{
            .float = switch (rnd.uintLessThan(u8, 4)) {
                0 => @floatFromInt(rnd.intRangeAtMost(i8, -3, 3)),
                1 => -0.0,
                2 => @bitCast(@as(u64, 0x7ff0_0000_0000_0000) | rnd.intRangeAtMost(u64, 1, 4)), // NaN payloads
                else => @bitCast(rnd.int(u64)),
            },
        },
        7 => .{ .int = .{ .ty = .integer_type, .storage = .{ .small = rnd.intRangeAtMost(i64, -4, 4) } } },
        8 => blk: {
            const len = rnd.intRangeAtMost(usize, 3, 6);
            for (limbs[0..len]) |*l| l.* = rnd.uintLessThan(u32, 3);
            limbs[len - 1] = 2 + rnd.uintLessThan(u32, 2); // never 0 or all ones: shortest
            break :blk .{ .int = .{ .ty = .integer_type, .storage = .{ .big = limbs[0..len] } } };
        },
        else => .{ .str = name },
    };
}

test "the well-known indexes are their keys" {
    var ip = try init(std.testing.allocator);
    defer ip.deinit(std.testing.allocator);
    try std.testing.expectEqual(Index.real_type, try ip.get(std.testing.allocator, .{ .simple_type = .real }));
    try std.testing.expectEqual(Index.neg_one_real, try ip.get(std.testing.allocator, .{ .float = -1.0 }));
    try std.testing.expectEqual(Index.inf_real, try ip.get(std.testing.allocator, .{ .float = std.math.inf(f64) }));
    try std.testing.expectEqual(Index.one, try ip.get(std.testing.allocator, .{ .int = .{ .ty = .integer_type, .storage = .{ .small = 1 } } }));
    try std.testing.expectEqual(Index.integer_type, ip.typeOf(.neg_one));
    try std.testing.expectEqual(Index.real_type, ip.typeOf(.undef));
    try std.testing.expectEqualStrings("", ip.stringToSlice(.empty));
}

test "property: round trip, dedup and distinctness over seeded random keys" {
    // Oracle: a model list of (key, index) compared by `modelEql`, written
    // apart from `keyEql`: a key seen before must map to its first index,
    // a new one to the next index, and every index must give its key back.
    const gpa = std.testing.allocator;
    var ip = try init(gpa);
    defer ip.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0x1e_ee_e5_3e);
    const rnd = prng.random();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var model: std.ArrayList(struct { key: Key, index: Index }) = .empty;
    defer model.deinit(gpa);
    for (well_known, 0..) |key, i| try model.append(gpa, .{ .key = key, .index = @fromBackingInt(@intCast(i)) });
    var limbs: [6]u32 = undefined;
    var nan_payloads: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer nan_payloads.deinit(gpa);
    for (0..3000) |_| {
        const key = try randomKey(&ip, gpa, rnd, &limbs);
        const index = try ip.get(gpa, key);
        const seen = for (model.items) |m| {
            if (modelEql(m.key, key)) break m.index;
        } else null;
        if (seen) |s| {
            try std.testing.expectEqual(s, index);
        } else {
            try std.testing.expectEqual(ip.items.len - 1, @backingInt(index));
            for (model.items) |m| try std.testing.expect(m.index != index);
            var kept = key;
            if (key == .int and key.int.storage == .big) kept.int.storage.big = try arena.allocator().dupe(u32, key.int.storage.big);
            try model.append(gpa, .{ .key = kept, .index = index });
            if (key == .float and std.math.isNan(key.float)) try nan_payloads.put(gpa, @bitCast(key.float), {});
        }
        try std.testing.expect(modelEql(ip.indexToKey(index), key));
    }
    // Every index still gives its key back after all the growth.
    for (model.items) |m| try std.testing.expect(modelEql(ip.indexToKey(m.index), m.key));
    // The sweep reached the cases the properties are about.
    try std.testing.expect(nan_payloads.count() >= 2);
    try std.testing.expect(ip.map.count() == ip.items.len);
}

test "property: -0.0 and 0.0, and two NaN payloads, are distinct constants" {
    const gpa = std.testing.allocator;
    var ip = try init(gpa);
    defer ip.deinit(gpa);
    try std.testing.expect(try ip.get(gpa, .{ .float = -0.0 }) != Index.zero_real);
    const qnan: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_0001));
    const qnan2: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_0002));
    const a = try ip.get(gpa, .{ .float = qnan });
    try std.testing.expect(a != try ip.get(gpa, .{ .float = qnan2 }));
    try std.testing.expectEqual(a, try ip.get(gpa, .{ .float = qnan }));
}

test "strings: dedup, NUL inside, and the empty string" {
    const gpa = std.testing.allocator;
    var ip = try init(gpa);
    defer ip.deinit(gpa);
    const a = try ip.getString(gpa, "electrical");
    const b = try ip.getString(gpa, "a\x00b");
    try std.testing.expectEqual(a, try ip.getString(gpa, "electrical"));
    try std.testing.expect(a != b);
    try std.testing.expectEqual(String.empty, try ip.getString(gpa, ""));
    try std.testing.expectEqualStrings("a\x00b", ip.stringToSlice(b));
    try std.testing.expectEqualStrings("electrical", ip.stringToSlice(a));
}

test "aggregates: a tuple and an array dedup by type and elements, in order" {
    // Oracle: the elements as written; order and type are part of the key.
    const gpa = std.testing.allocator;
    var ip = try init(gpa);
    defer ip.deinit(gpa);
    const tuple = try ip.get(gpa, .{ .aggregate = .{ .ty = .none, .elems = &.{ .one, .two_real } } });
    try std.testing.expectEqual(tuple, try ip.get(gpa, .{ .aggregate = .{ .ty = .none, .elems = &.{ .one, .two_real } } }));
    try std.testing.expect(tuple != try ip.get(gpa, .{ .aggregate = .{ .ty = .none, .elems = &.{ .two_real, .one } } }));
    const arr_ty = try ip.get(gpa, .{ .array_type = .{ .len = 2, .elem = .real_type } });
    const arr = try ip.get(gpa, .{ .aggregate = .{ .ty = arr_ty, .elems = &.{ .one_real, .two_real } } });
    try std.testing.expect(arr != try ip.get(gpa, .{ .aggregate = .{ .ty = .none, .elems = &.{ .one_real, .two_real } } }));
    try std.testing.expectEqual(arr_ty, ip.typeOf(arr));
    const k = ip.indexToKey(tuple).aggregate;
    try std.testing.expectEqual(Index.none, k.ty);
    try std.testing.expectEqualSlices(Index, &.{ .one, .two_real }, k.elems);
    const empty = try ip.get(gpa, .{ .aggregate = .{ .ty = .none, .elems = &.{} } });
    try std.testing.expectEqual(@as(usize, 0), ip.indexToKey(empty).aggregate.elems.len);
}

test "get: allocation failure leaves the pool consistent" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var ip = try init(gpa);
            defer ip.deinit(gpa);
            const s = try ip.getString(gpa, "V");
            const n = try ip.get(gpa, .{ .nature = .{ .name = s, .access = s, .abstol = .one_real, .units = .empty, .ddt_nature = .none, .idt_nature = .none } });
            _ = try ip.get(gpa, .{ .int = .{ .ty = .integer_type, .storage = .{ .big = &.{ 1, 2, 3 } } } });
            try std.testing.expectEqual(n, try ip.get(gpa, ip.indexToKey(n)));
        }
    }.run, .{});
}
