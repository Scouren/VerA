//! Vir as text (Zig's `src/print_zir.zig`): one `Vir` in, a dump out, for
//! debugging and goldens. The declaration table first, then each design
//! unit's instruction with its bodies nested and indented. Payloads print
//! generically from their field types, so a new payload prints with no
//! code here: `%n` an instruction, `"s"` a string, `{ ... }` a body,
//! `[ ... ]` a list, `.tag` an enum.
//! No LRM clause: the format is VerA's own.
//!
//! Contents:
//! - `pub fn render(vir: *const Vir, w: *std.Io.Writer) std.Io.Writer.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Vir = @import("../Vir.zig");
const Inst = Vir.Inst;
const Writer = std.Io.Writer;

const Printer = struct {
    vir: *const Vir,
    w: *Writer,

    fn inst(p: Printer, i: Inst.Index, indent: u32) Writer.Error!void {
        const vir = p.vir;
        assert(@backingInt(i) < vir.instructions.len);
        const tag = vir.instructions.items(.tag)[@backingInt(i)];
        const data = vir.instructions.items(.data)[@backingInt(i)];
        try p.w.print("%{d} = {t}(", .{ @backingInt(i), tag });
        switch (Inst.dataKind(tag)) {
            .pl_node => switch (tag) {
                // else: every tag; `dataKind` said this one has a payload.
                inline else => |t| if (Inst.Payload(t) != void) {
                    const T = Inst.Payload(t);
                    const v = vir.extraData(T, data.pl_node.payload_index);
                    if (@hasDecl(T, "Elem")) try p.value(T, v, indent) else try p.fields(T, v, indent);
                } else unreachable,
            },
            .un_node => try p.ref(data.un_node.operand),
            .str_tok => try p.str(data.str_tok.start),
            .decl_tok => try p.w.print("%{d}", .{@backingInt(data.decl_tok.decl)}),
            .int => try p.w.print("{d}", .{data.int}),
            .float => try p.w.print("{e}", .{data.float}),
            .str => try p.w.print("\"{f}\"", .{std.zig.fmtString(vir.string_bytes[@backingInt(data.str.start)..][0..data.str.len])}),
        }
        try p.w.writeByte(')');
    }

    fn value(p: Printer, comptime T: type, v: T, indent: u32) Writer.Error!void {
        if (T == Vir.String) return p.str(v);
        if (T == Inst.Ref) return p.ref(v);
        if (T == Inst.Index) return p.w.print("%{d}", .{@backingInt(v)});
        if (T == Vir.F64) return p.w.print("{e}", .{v.get()});
        if (T == Vir.Body) return p.body(v, indent);
        switch (@typeInfo(T)) {
            .@"struct" => {
                if (@hasDecl(T, "Elem")) return p.list(T.Elem, p.vir.list(T.Elem, v), indent);
                try p.w.writeAll(".{");
                try p.fields(T, v, indent);
                try p.w.writeByte('}');
            },
            .@"enum" => try p.w.print(".{t}", .{v}),
            .bool => try p.w.writeAll(if (v) "true" else "false"),
            .int => try p.w.print("{d}", .{v}),
            else => @compileError("no printer for " ++ @typeName(T)),
        }
    }

    /// `name=value, ...` over a struct's fields, padding skipped.
    fn fields(p: Printer, comptime T: type, v: T, indent: u32) Writer.Error!void {
        const s = @typeInfo(T).@"struct";
        var first = true;
        inline for (s.field_names, s.field_types) |name, F| {
            if (comptime std.mem.eql(u8, name, "_")) continue;
            if (!first) try p.w.writeAll(", ");
            first = false;
            try p.w.print("{s}=", .{name});
            try p.value(F, @field(v, name), indent);
        }
    }

    fn list(p: Printer, comptime T: type, items: []const T, indent: u32) Writer.Error!void {
        try p.w.writeByte('[');
        for (items, 0..) |item, k| {
            if (k != 0) try p.w.writeAll(", ");
            try p.value(T, item, indent);
        }
        try p.w.writeByte(']');
    }

    fn body(p: Printer, b: Vir.Body, indent: u32) Writer.Error!void {
        if (b.len == 0) return p.w.writeAll("{}");
        try p.w.writeAll("{\n");
        for (p.vir.body(b)) |i| {
            try p.w.splatByteAll(' ', 2 * (indent + 1));
            try p.inst(i, indent + 1);
            try p.w.writeByte('\n');
        }
        try p.w.splatByteAll(' ', 2 * indent);
        try p.w.writeByte('}');
    }

    fn ref(p: Printer, r: Inst.Ref) Writer.Error!void {
        const i = r.toIndex() orelse return p.w.writeAll("none");
        try p.w.print("%{d}", .{@backingInt(i)});
    }

    fn str(p: Printer, s: Vir.String) Writer.Error!void {
        try p.w.print("\"{f}\"", .{std.zig.fmtString(p.vir.string(s))});
    }
};

/// Writes the declaration table and every unit's instructions. Bodies nest
/// as deep as the source did; the parser bounds that depth.
pub fn render(vir: *const Vir, w: *Writer) Writer.Error!void {
    const p: Printer = .{ .vir = vir, .w = w };
    for (vir.decls()) |d| try w.print("{t} \"{f}\" %{d}\n", .{ d.kind, std.zig.fmtString(vir.string(d.name)), @backingInt(d.inst) });
    for (vir.decls()) |d| {
        try p.inst(d.inst, 0);
        try w.writeByte('\n');
    }
}

// ---- private ----
