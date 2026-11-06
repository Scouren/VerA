//! Full views of nodes whose payload spans several `extra_data` lists (Zig's
//! `Ast.full`): one node in, its children as slices out, built on demand.
//! No LRM clause: the shapes are `Ast.Node`'s.
//!
//! Contents:
//! - `pub const ModuleDecl = struct`, `pub fn moduleDecl(tree: *const Ast, node: Node.Index) ModuleDecl`
//! - `pub const Decl = struct`, `pub fn decl(tree: *const Ast, node: Node.Index) Decl`
//! - `pub const Function = struct`, `pub fn function(tree: *const Ast, node: Node.Index) Function`
//! - `pub fn list(tree: *const Ast, node: Node.Index) []const Node.Index`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("../Ast.zig");
const Node = Ast.Node;

/// A `module_decl`: its keyword and name tokens, header parameter
/// declarations, ports and items.
pub const ModuleDecl = struct {
    main_token: Ast.TokenIndex,
    name: Ast.TokenIndex,
    params: []const Node.Index,
    ports: []const Node.Index,
    items: []const Node.Index,
};

/// A node whose payload is `Node.Decl`: its range (or delay) and items.
pub const Decl = struct {
    main_token: Ast.TokenIndex,
    range: Node.OptionalIndex,
    items: []const Node.Index,
};

/// A `function_decl` or `task_decl`.
pub const Function = struct {
    main_token: Ast.TokenIndex,
    range: Node.OptionalIndex,
    ports: []const Node.Index,
    items: []const Node.Index,
};

/// Asserts `node` is a `module_decl`.
pub fn moduleDecl(tree: *const Ast, node: Node.Index) ModuleDecl {
    assert(tree.nodeTag(node) == .module_decl);
    const m = tree.extraData(tree.nodeData(node).extra, Node.Module);
    const main = tree.nodeMainToken(node);
    return .{
        .main_token = main,
        .name = main + 1,
        .params = tree.extraDataSlice(.{ .start = m.params_start, .end = m.params_end }, Node.Index),
        .ports = tree.extraDataSlice(.{ .start = m.ports_start, .end = m.ports_end }, Node.Index),
        .items = tree.extraDataSlice(.{ .start = m.items_start, .end = m.items_end }, Node.Index),
    };
}

/// Asserts `node`'s payload is a `Node.Decl` (a parameter, variable, port,
/// continuous assignment, gate or UDP instantiation node).
pub fn decl(tree: *const Ast, node: Node.Index) Decl {
    switch (tree.nodeTag(node)) {
        .param_decl, .var_decl, .port_decl, .continuous_assign, .gate_instantiation, .udp_instantiation => {},
        else => unreachable,
    }
    const d = tree.extraData(tree.nodeData(node).extra, Node.Decl);
    return .{
        .main_token = tree.nodeMainToken(node),
        .range = d.range,
        .items = tree.extraDataSlice(.{ .start = d.items_start, .end = d.items_end }, Node.Index),
    };
}

/// Asserts `node` is a `function_decl` or `task_decl`.
pub fn function(tree: *const Ast, node: Node.Index) Function {
    assert(tree.nodeTag(node) == .function_decl or tree.nodeTag(node) == .task_decl);
    const f = tree.extraData(tree.nodeData(node).extra, Node.Function);
    return .{
        .main_token = tree.nodeMainToken(node),
        .range = f.range,
        .ports = tree.extraDataSlice(.{ .start = f.ports_start, .end = f.ports_end }, Node.Index),
        .items = tree.extraDataSlice(.{ .start = f.items_start, .end = f.items_end }, Node.Index),
    };
}

/// The `extra_range` list of a node whose data is one (a block, generate
/// region or block, specify block, design element body, ...).
pub fn list(tree: *const Ast, node: Node.Index) []const Node.Index {
    return tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
}
