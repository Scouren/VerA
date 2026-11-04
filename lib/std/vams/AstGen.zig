//! Ast to Vir, one file at a time (Zig's `lib/std/zig/AstGen.zig`): a
//! parsed tree with no errors in, its untyped `Vir` out, with the per-file
//! checks' diagnostics in `Vir.diag`. Pure: the output depends on the tree
//! and the directive tables alone, so a caller may run files in parallel and
//! cache each by its text's hash. Each scope (module, generate block,
//! function, named block, paramset) is scanned for its declarations before
//! its items are lowered, so a name used before its declaration still
//! resolves; a name no scope declares stays a `str_ref` for Sema.
//! This file is the spine (`generate`), the table writers, string
//! interning, scopes, the directive stamp and diagnostics; each construct
//! area is a file of free functions in `AstGen/`.
//! Cites: VAMS-2023 §6.2, §10.2, A.1.2; IEEE 1364-2005 §12.4.3, §19.
//!
//! Contents:
//! - `pub const Options = struct`
//! - `pub const Scope = struct` (`lookup`, `declare`)
//! - `pub const Error`
//! - `pub fn generate(gpa: Allocator, tree: *const Ast, options: Options) Allocator.Error!Vir`
//! - `pub fn addInst(ag: *AstGen, tag: Inst.Tag, data: Inst.Data) Allocator.Error!Inst.Ref`
//! - `pub fn addPl(ag: *AstGen, tag: Inst.Tag, node: Ast.Node.Index, payload: anytype) Allocator.Error!Inst.Ref`
//! - `pub fn reserve(ag: *AstGen, tag: Inst.Tag, node: Ast.Node.Index) Allocator.Error!Inst.Index`
//! - `pub fn fill(ag: *AstGen, inst: Inst.Index, node: Ast.Node.Index, payload: anytype) Allocator.Error!void`
//! - `pub fn setPayload(ag: *AstGen, inst: Inst.Index, node: Ast.Node.Index, payload: anytype) Allocator.Error!void`
//! - `pub fn unit(ag: *AstGen, kind: Vir.Decl.Kind, tag: Inst.Tag, node: Ast.Node.Index, name: Vir.String) Allocator.Error!Inst.Index`
//! - `pub fn reserved(ag: *const AstGen, node: Ast.Node.Index) Inst.Index`
//! - `pub fn addExtra(ag: *AstGen, payload: anytype) Allocator.Error!u32`
//! - `pub fn addList(ag: *AstGen, comptime T: type, items: []const T) Allocator.Error!Vir.List(T)`
//! - `pub fn bodyFrom(ag: *AstGen, top: usize) Allocator.Error!Vir.Body`
//! - `pub fn refsFrom(ag: *AstGen, top: usize) Allocator.Error!Vir.List(Inst.Ref)`
//! - `pub fn string(ag: *AstGen, bytes: []const u8) Allocator.Error!Vir.String`
//! - `pub fn identString(ag: *AstGen, tok: Ast.TokenIndex) Allocator.Error!Vir.String`
//! - `pub fn identText(tree: *const Ast, tok: Ast.TokenIndex) []const u8`
//! - `pub fn isName(tag: Token.Tag) bool`
//! - `pub fn defaultsAt(ag: *AstGen, tok: Ast.TokenIndex) Allocator.Error!Vir.List(Inst.Default)`
//! - `pub fn stampAt(ag: *const AstGen, tok: Ast.TokenIndex) Inst.Module.Stamp`
//! - `pub fn report(ag: *AstGen, c: Diag.Code, tok: Ast.TokenIndex, comptime fmt: []const u8, args: anytype) Allocator.Error!void`
//! - `pub fn build(ag: *AstGen, c: Diag.Code, tok: Ast.TokenIndex) Diag.Wip.Builder`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Vir = @import("Vir.zig");
const Diag = @import("Diag.zig");
const events = @import("Preprocessor/events.zig");
const Token = @import("tokenizer.zig").Token;
const module = @import("AstGen/module.zig");
const design = @import("AstGen/design.zig");
const Inst = Vir.Inst;
const Node = Ast.Node;
const StringIndexContext = std.hash_map.StringIndexContext;
const StringIndexAdapter = std.hash_map.StringIndexAdapter;

gpa: Allocator,
/// Scopes and per-construct scratch; freed when `generate` returns.
arena: Allocator,
tree: *const Ast,
options: Options,
instructions: std.MultiArrayList(Inst) = .empty,
extra: std.ArrayList(u32) = .empty,
string_bytes: std.ArrayList(u8) = .empty,
string_table: std.HashMapUnmanaged(u32, void, StringIndexContext, std.hash_map.default_max_load_percentage) = .empty,
/// The instructions of the bodies being built, innermost on top: a user
/// takes `top = scratch.items.len`, appends, and `bodyFrom(top)` moves the
/// run into `extra` (Zig's `GenZir.instructions`).
scratch: std.ArrayList(u32) = .empty,
/// Declaring nodes to the instruction their scope's scan reserved.
decl_insts: std.AutoHashMapUnmanaged(Node.Index, Inst.Index) = .empty,
/// Generate arms to the `gen_block` their scope's scan reserved.
block_insts: std.AutoHashMapUnmanaged(Node.Index, Inst.Index) = .empty,
decls: std.ArrayList(Vir.Decl) = .empty,
wip: Diag.Wip,
/// Lowering an analog block or analog function statement, where A.8.4's
/// `analog_primary` has no `( mintypmax )` (E0295).
analog: bool = false,
/// The current module has a parameter header (IEEE 1364-2005 §4.10.1).
header_params: bool = false,
/// The last `defaultsAt` answer, keyed by how many events preceded it.
defaults_seen: u32 = std.math.maxInt(u32),
defaults_list: Vir.List(Inst.Default) = .empty,
/// Every §2.9 `attribute` node, in source order, built on first use
/// (decl.zig's `prefixAttrs`).
attr_nodes: ?[]const Node.Index = null,

/// What `generate` reads besides the tree.
pub const Options = struct {
    /// The preprocessor's positional directive events for this tree's text
    /// (`Preprocessor.Output.directives`), stamped on declarations.
    directives: events.Directives = .{},
    /// An IEEE 1364 design (a `.v`): the old digital route, whose reports
    /// some rules keep.
    ieee1364: bool = false,
};

/// One name space (Zig's `Scope`): a module, generate block, function,
/// named block or paramset. `names` maps each name to its first
/// declaration; lookup walks out through `parent`.
pub const Scope = struct {
    parent: ?*const Scope,
    names: std.AutoHashMapUnmanaged(Vir.String, Inst.Index) = .empty,
    /// §12.4.3: generate constructs numbered so far in this scope.
    constructs: u32 = 0,
    /// §12.4.3: the `genblk<n>` name construct `n` was given, which every
    /// other arm of it shares (only one of them is ever instantiated).
    auto: ?struct { n: u32, name: Vir.String } = null,

    /// The declaration of `name` in this scope or an enclosing one.
    pub fn lookup(s: *const Scope, name: Vir.String) ?Inst.Index {
        var it: ?*const Scope = s;
        var depth: u32 = 0;
        while (it) |sc| : (it = sc.parent) {
            depth += 1;
            assert(depth <= max_scope_depth);
            if (sc.names.get(name)) |i| return i;
        }
        return null;
    }

    /// Declares `name` as `inst`; returns the earlier declaration in this
    /// scope (kept as the name's binding), or none.
    pub fn declare(s: *Scope, arena: Allocator, name: Vir.String, inst: Inst.Index) Allocator.Error!Inst.Ref {
        assert(name != .empty);
        const gop = try s.names.getOrPut(arena, name);
        if (gop.found_existing) return gop.value_ptr.toRef();
        gop.value_ptr.* = inst;
        return .none;
    }
};

pub const Error = Allocator.Error;

/// Scopes nest with the source's generate blocks, functions and named
/// blocks, which the parser bounds at its own depth cap.
const max_scope_depth = 20_000;

const AstGen = @This();

/// Lowers `tree` into a Vir the caller frees with `deinit(gpa)`. Asserts
/// the tree parsed without errors: a failed parse is reported from
/// `tree.errors` and never generated. Recursion follows the tree's
/// nesting, which `Parse.max_depth` caps; run it on a large stack.
pub fn generate(gpa: Allocator, tree: *const Ast, options: Options) Allocator.Error!Vir {
    assert(tree.errors.len == 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var ag: AstGen = .{ .gpa = gpa, .arena = arena_state.allocator(), .tree = tree, .options = options, .wip = .init(gpa) };
    defer ag.deinit();
    try ag.string_bytes.append(gpa, 0);
    try ag.extra.appendNTimes(gpa, 0, Vir.reserved_extra);
    for (tree.rootDecls()) |d| switch (tree.nodeTag(d)) {
        .module_decl => try module.lowerModule(&ag, d),
        .nature_decl => try design.lowerNature(&ag, d),
        .discipline_decl => try design.lowerDiscipline(&ag, d),
        .paramset_decl => try design.lowerParamset(&ag, d),
        .udp_decl => try design.lowerPrimitive(&ag, d),
        .connectrules_decl => try design.lowerConnectRules(&ag, d),
        .config_decl => try design.lowerConfig(&ag, d),
        else => unreachable, // else: A.1.2 descriptions are the only root items
    };
    assert(ag.scratch.items.len == 0);
    const table = try ag.addList(Vir.Decl, ag.decls.items);
    ag.extra.items[@backingInt(Vir.ExtraIndex.decls)] = table.start;
    ag.extra.items[@backingInt(Vir.ExtraIndex.decls) + 1] = table.len;

    var diag = try ag.wip.toOwnedBundle();
    errdefer diag.deinit(gpa);
    const extra = try ag.extra.toOwnedSlice(gpa);
    errdefer gpa.free(extra);
    const bytes = try ag.string_bytes.toOwnedSlice(gpa);
    const vir: Vir = .{ .instructions = ag.instructions.toOwnedSlice(), .extra = extra, .string_bytes = bytes, .diag = diag };
    assert(vir.decls().len == table.len);
    return vir;
}

/// Appends an instruction to the current body.
pub fn addInst(ag: *AstGen, tag: Inst.Tag, data: Inst.Data) Allocator.Error!Inst.Ref {
    const i: u32 = @intCast(ag.instructions.len);
    try ag.instructions.append(ag.gpa, .{ .tag = tag, .data = data });
    try ag.scratch.append(ag.gpa, i);
    return @fromBackingInt(i);
}

/// Appends a `pl_node` instruction with `payload` to the current body.
pub fn addPl(ag: *AstGen, tag: Inst.Tag, node: Node.Index, payload: anytype) Allocator.Error!Inst.Ref {
    assert(payloadIs(tag, @TypeOf(payload)));
    const index = try ag.addExtra(payload);
    return ag.addInst(tag, .{ .pl_node = .{ .src_node = node, .payload_index = index } });
}

/// Reserves a declaring instruction for `node` in no body yet (a scope
/// scan); `fill` writes it and places it in the current body.
pub fn reserve(ag: *AstGen, tag: Inst.Tag, node: Node.Index) Allocator.Error!Inst.Index {
    assert(Inst.dataKind(tag) == .pl_node);
    const i: u32 = @intCast(ag.instructions.len);
    try ag.instructions.append(ag.gpa, .{ .tag = tag, .data = .{ .pl_node = .{ .src_node = node, .payload_index = 0 } } });
    return @fromBackingInt(i);
}

/// Writes the payload of a reserved instruction and appends it to the
/// current body. Asserts it was reserved with `payload`'s tag and not yet filled.
pub fn fill(ag: *AstGen, inst: Inst.Index, node: Node.Index, payload: anytype) Allocator.Error!void {
    try ag.setPayload(inst, node, payload);
    try ag.scratch.append(ag.gpa, @backingInt(inst));
}

/// Writes the payload of a reserved instruction that sits in no body (a
/// design unit, which the declaration table lists).
pub fn setPayload(ag: *AstGen, inst: Inst.Index, node: Node.Index, payload: anytype) Allocator.Error!void {
    const i = @backingInt(inst);
    const tag = ag.instructions.items(.tag)[i];
    assert(ag.instructions.items(.data)[i].pl_node.payload_index == 0);
    assert(payloadIs(tag, @TypeOf(payload)));
    const index = try ag.addExtra(payload);
    ag.instructions.items(.data)[i] = .{ .pl_node = .{ .src_node = node, .payload_index = index } };
}

/// Reserves a design unit's instruction and lists it in the declaration table.
pub fn unit(ag: *AstGen, kind: Vir.Decl.Kind, tag: Inst.Tag, node: Node.Index, name: Vir.String) Allocator.Error!Inst.Index {
    const inst = try ag.reserve(tag, node);
    try ag.decls.append(ag.gpa, .{ .kind = kind, .name = name, .inst = inst });
    return inst;
}

/// The instruction a scan reserved for declaring node `node`.
pub fn reserved(ag: *const AstGen, node: Node.Index) Inst.Index {
    return ag.decl_insts.get(node).?;
}

/// Appends `payload` (an `extern struct` of 4-byte words) to `extra`.
pub fn addExtra(ag: *AstGen, payload: anytype) Allocator.Error!u32 {
    const T = @TypeOf(payload);
    comptime assert(@sizeOf(T) % 4 == 0);
    const index: u32 = @intCast(ag.extra.items.len);
    const words: *const [@sizeOf(T) / 4]u32 = @ptrCast(&payload);
    try ag.extra.appendSlice(ag.gpa, words);
    assert(index >= Vir.reserved_extra);
    return index;
}

/// Appends `items` to `extra` as a list.
pub fn addList(ag: *AstGen, comptime T: type, items: []const T) Allocator.Error!Vir.List(T) {
    if (items.len == 0) return .empty;
    const start: u32 = @intCast(ag.extra.items.len);
    try ag.extra.appendSlice(ag.gpa, @ptrCast(items));
    return .{ .start = start, .len = @intCast(items.len) };
}

/// Moves the instructions above `top` from the scratch stack into a body.
pub fn bodyFrom(ag: *AstGen, top: usize) Allocator.Error!Vir.Body {
    assert(top <= ag.scratch.items.len);
    const b = try ag.addList(Inst.Index, @ptrCast(ag.scratch.items[top..]));
    ag.scratch.shrinkRetainingCapacity(top);
    return b;
}

/// Moves the refs above `top` from the scratch stack into a list (the
/// caller pushed result refs there, not instructions).
pub fn refsFrom(ag: *AstGen, top: usize) Allocator.Error!Vir.List(Inst.Ref) {
    assert(top <= ag.scratch.items.len);
    const l = try ag.addList(Inst.Ref, @ptrCast(ag.scratch.items[top..]));
    ag.scratch.shrinkRetainingCapacity(top);
    return l;
}

/// Interns `bytes`, which hold no NUL.
pub fn string(ag: *AstGen, bytes: []const u8) Allocator.Error!Vir.String {
    if (bytes.len == 0) return .empty;
    assert(std.mem.findScalar(u8, bytes, 0) == null);
    const gop = try ag.string_table.getOrPutContextAdapted(ag.gpa, bytes, StringIndexAdapter{ .bytes = &ag.string_bytes }, StringIndexContext{ .bytes = &ag.string_bytes });
    if (gop.found_existing) return @fromBackingInt(gop.key_ptr.*);
    const at: u32 = @intCast(ag.string_bytes.items.len);
    try ag.string_bytes.ensureUnusedCapacity(ag.gpa, bytes.len + 1);
    ag.string_bytes.appendSliceAssumeCapacity(bytes);
    ag.string_bytes.appendAssumeCapacity(0);
    gop.key_ptr.* = at;
    return @fromBackingInt(at);
}

/// Interns the §2.8 name token `tok` spells (an escaped one without `\`).
pub fn identString(ag: *AstGen, tok: Ast.TokenIndex) Allocator.Error!Vir.String {
    return ag.string(identText(ag.tree, tok));
}

/// The name token `tok` spells: §2.8 makes `\a ` and `a` one name.
pub fn identText(tree: *const Ast, tok: Ast.TokenIndex) []const u8 {
    const text = tree.tokenSlice(tok);
    assert(text.len != 0);
    return if (tree.tokenTag(tok) == .escaped_identifier) text[1..] else text;
}

/// Whether `tag` is a plain or escaped identifier.
pub fn isName(tag: Token.Tag) bool {
    return tag == .identifier or tag == .escaped_identifier;
}

/// The §10.2 `default_discipline`s in force at token `tok`: the newest
/// per qualifier, an empty discipline withdrawing all. Shared between
/// declarations that see the same events.
pub fn defaultsAt(ag: *AstGen, tok: Ast.TokenIndex) Allocator.Error!Vir.List(Inst.Default) {
    const table = ag.options.directives.disciplines;
    const at = ag.tree.tokenStart(tok);
    const seen: u32 = @intCast(std.sort.partitionPoint(events.DefaultDiscipline, table, at, struct {
        fn before(offset: u32, e: events.DefaultDiscipline) bool {
            return e.at <= offset;
        }
    }.before));
    if (seen == ag.defaults_seen) return ag.defaults_list;
    // One slot per qualifier, and the unqualified one last.
    var slots: [@typeInfo(events.Qualifier).@"enum".field_names.len + 1]?[]const u8 = @splat(null);
    for (table[0..seen]) |e| {
        if (e.discipline.len == 0) {
            slots = @splat(null);
            continue;
        }
        slots[if (e.qualifier) |q| @backingInt(q) else slots.len - 1] = e.discipline;
    }
    var rows: [slots.len]Inst.Default = undefined;
    var n: usize = 0;
    for (slots, 0..) |s, k| if (s) |d| {
        const qualified = k != slots.len - 1;
        rows[n] = .{ .flags = .{ .qualifier = if (qualified) @fromBackingInt(@intCast(k)) else .integer, .qualified = qualified }, .discipline = try ag.string(d) };
        n += 1;
    };
    ag.defaults_seen = seen;
    ag.defaults_list = try ag.addList(Inst.Default, rows[0..n]);
    return ag.defaults_list;
}

/// The IEEE 1364 §19 directives in force at token `tok`.
pub fn stampAt(ag: *const AstGen, tok: Ast.TokenIndex) Inst.Module.Stamp {
    const d = ag.options.directives;
    const at = ag.tree.tokenStart(tok);
    const ts = lastBefore(?events.Timescale, d.timescales, at) orelse null;
    const tr = lastBefore(?f64, d.transitions, at) orelse null;
    return .{
        .flags = .{
            .nettype = lastBefore(events.NetType, d.nettypes, at) orelse .default,
            .drive = lastBefore(events.Drive, d.drives, at) orelse .default,
            .celldefine = lastBefore(bool, d.cells, at) orelse false,
            .has_timescale = ts != null,
            .has_transition = tr != null,
        },
        .unit = .init(if (ts) |t| t.unit else 0),
        .precision = .init(if (ts) |t| t.precision else 0),
        .transition = .init(tr orelse 0),
    };
}

/// Reports `c` at token `tok` (a byte range of the tree's source, which the
/// caller maps to a file through `Preprocessor.Output.resolve`).
pub fn report(ag: *AstGen, c: Diag.Code, tok: Ast.TokenIndex, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    var b = ag.build(c, tok);
    b.msg(fmt, args);
    try b.emit();
}

/// `report`'s row at token `tok`, for a caller that adds notes or help
/// before it emits.
pub fn build(ag: *AstGen, c: Diag.Code, tok: Ast.TokenIndex) Diag.Wip.Builder {
    const start = ag.tree.tokenStart(tok);
    const loc: Diag.Loc = .{ .file = .root, .start = start, .end = start + @as(u32, @intCast(ag.tree.tokenSlice(tok).len)) };
    // The stage the old compiler reported the code from: E02xx and E1100 in
    // the parse, the elaborator's in lowering.
    const stage: Diag.Stage = if (@tagName(c)[2] == '2' or c == .E1100) .parse else .lower;
    return ag.wip.build(stage, c, loc);
}

// ---- private ----

fn deinit(ag: *AstGen) void {
    const gpa = ag.gpa;
    ag.instructions.deinit(gpa);
    ag.extra.deinit(gpa);
    ag.string_bytes.deinit(gpa);
    ag.string_table.deinit(gpa);
    ag.scratch.deinit(gpa);
    ag.decl_insts.deinit(gpa);
    ag.block_insts.deinit(gpa);
    ag.decls.deinit(gpa);
    ag.wip.deinit();
}

/// Whether `tag`'s payload type is `T`.
fn payloadIs(tag: Inst.Tag, comptime T: type) bool {
    return switch (tag) {
        // else: every tag, compared at its own payload type.
        inline else => |t| Inst.Payload(t) == T,
    };
}

/// The value of the last event in `table` at or before `at`.
fn lastBefore(comptime T: type, table: []const events.Region(T), at: u32) ?T {
    const n = std.sort.partitionPoint(events.Region(T), table, at, struct {
        fn before(offset: u32, e: events.Region(T)) bool {
            return e.at <= offset;
        }
    }.before);
    return if (n == 0) null else table[n - 1].value;
}

test {
    _ = module;
    _ = design;
    _ = @import("AstGen/test.zig");
}
