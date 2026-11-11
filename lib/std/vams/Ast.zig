//! The syntax tree of one preprocessed unit (Zig's `lib/std/zig/Ast.zig`):
//! text in (`parse`), one table of nodes out, purely syntactic. No strings
//! are stored: a name is a token (`tokenSlice`), a literal is decoded on
//! demand (`number_literal.zig`). Errors stay in the tree (`errors`); the
//! parser recovers at description, module item and statement boundaries.
//! Attribute instances (§2.9) are `attribute` nodes that no parent lists:
//! one prefixes the construct that starts at the token after its `*)`, or
//! is a suffix of the operator or call name at the token before its `(*`.
//! Cites: VAMS-2023 annex A, IEEE 1364-2005 annex A (the productions each
//! `Node.Tag` documents), §2.9, §10.6.
//!
//! Contents:
//! - fields `source`, `tokens`, `nodes`, `extra_data`, `errors`
//! - `pub const TokenIndex`, `pub const ByteOffset`, `pub const TokenList`, `pub const NodeList`
//! - `pub const OptionalTokenIndex = enum(u32)`, `OptionalTokenIndex.unwrap`, `OptionalTokenIndex.fromOptional`
//! - `pub const ExtraIndex = enum(u32)`
//! - `pub const KeywordSet`
//! - `pub const ParseOptions = struct`
//! - `pub const Node = struct`: `Node.Tag`, `Node.Data`, `Node.Index` (`toOptional`), `Node.OptionalIndex`, `Node.SubRange`, and the extra payloads `Module`, `Decl`, `NetDecl`, `ParamAssign`, `ValueRange`, `Branch`, `Instantiation`, `Instance`, `GateInstance`, `Function`, `Udp`, `Insertion`, `For`, `If`, `Timed`, `Indirect`, `MinTypMax`, `Ternary`, `Pair`, `Path`
//! - `pub const Error = struct` (`Error.Tag`, `Error.Site`)
//! - `pub const full`, `pub const parse_errors` (`report`, `code`)
//! - `pub fn parse(gpa: Allocator, source: [:0]const u8, options: ParseOptions) Allocator.Error!Ast`
//! - `pub fn deinit(tree: *Ast, gpa: Allocator) void`
//! - `pub fn tokenTag(tree: *const Ast, i: TokenIndex) Token.Tag`, `pub fn tokenStart(tree: *const Ast, i: TokenIndex) ByteOffset`
//! - `pub fn nodeTag(tree: *const Ast, n: Node.Index) Node.Tag`, `pub fn nodeMainToken(tree: *const Ast, n: Node.Index) TokenIndex`, `pub fn nodeData(tree: *const Ast, n: Node.Index) Node.Data`
//! - `pub fn tokenSlice(tree: *const Ast, i: TokenIndex) []const u8`
//! - `pub fn extraData(tree: *const Ast, index: ExtraIndex, comptime T: type) T`
//! - `pub fn extraDataSlice(tree: *const Ast, range: Node.SubRange, comptime T: type) []const T`
//! - `pub fn rootDecls(tree: *const Ast) []const Node.Index`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const Parse = @import("Parse.zig");
/// Views of nodes whose payload spans several `extra_data` lists (Ast/full.zig).
pub const full = @import("Ast/full.zig");
/// The parse errors as diagnostics (Ast/errors.zig): `parse_errors.report(tree, wip)`.
pub const parse_errors = @import("Ast/errors.zig");

/// Reference to externally-owned text, which must outlive the tree.
source: [:0]const u8,
tokens: TokenList.Slice,
nodes: NodeList.Slice,
extra_data: []u32,
errors: []const Error,

pub const TokenIndex = u32;
pub const ByteOffset = u32;
pub const TokenList = std.MultiArrayList(struct { tag: Token.Tag, start: ByteOffset });
pub const NodeList = std.MultiArrayList(Node);

/// A token index, or none.
pub const OptionalTokenIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oti: OptionalTokenIndex) ?TokenIndex {
        return if (oti == .none) null else @backingInt(oti);
    }

    pub fn fromOptional(oti: ?TokenIndex) OptionalTokenIndex {
        return if (oti) |ti| @fromBackingInt(ti) else .none;
    }
};

/// Index into `extra_data`.
pub const ExtraIndex = enum(u32) { _ };

/// The §10.6 reserved-keyword sets (Parse/keywords.zig).
pub const KeywordSet = Parse.KeywordSet;

pub const ParseOptions = struct {
    /// The language parsed and the §10.6 default set: a 1364 set reserves no
    /// Verilog-AMS word, and a Verilog-AMS design element under one is an
    /// error (IEEE 1364-2005 annex A has no production for it). Under a
    /// Verilog-AMS set a null statement is no `analog_statement` (A.6.4).
    keywords: KeywordSet = .vams_2023,
    /// An IEEE 1364 design (a `.v`, the old digital route) under any
    /// language: statements are A.6's, as under a 1364 set.
    discrete: bool = false,
    /// Annex C's Verilog-A subset (`--sim=verilogA`): a digital or
    /// mixed-signal construct is `outside_verilog_a` (E0250), reported at its
    /// first token and then parsed anyway.
    verilog_a: bool = false,
};

/// One row of the node table, 13 bytes SoA: what it is, the token it is
/// named by, and two words whose reading the tag documents.
pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    /// Index into `nodes`. Node 0 is the root.
    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            const result: OptionalIndex = @fromBackingInt(@backingInt(i));
            assert(result != .none);
            return result;
        }
    };

    /// Index into `nodes`, or none.
    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @fromBackingInt(@backingInt(oi));
        }

        pub fn fromOptional(oi: ?Index) OptionalIndex {
            return if (oi) |i| i.toOptional() else .none;
        }
    };

    /// `extra_data[start..end]`, a list of node indices (`OptionalIndex`
    /// where the tag's doc says a slot may be empty).
    pub const SubRange = struct { start: ExtraIndex, end: ExtraIndex };

    /// Every tag's `main_token` and `data` reading. "List" means
    /// `extra_range` of `Index`; "slots" an `extra_range` of `OptionalIndex`.
    /// Names, keywords and operators the doc does not store are tokens at a
    /// fixed offset or found by scanning the tokens between children.
    pub const Tag = enum(u8) {
        /// `extra_range`: the descriptions, in source order.
        root,

        // ---- descriptions (A.1.2) ----
        /// `module|macromodule|connectmodule name ...`; name is main+1.
        /// `extra` -> `Module`.
        module_decl,
        /// A list_of_ports entry: `opt_node` port expression (none: a null
        /// port). main_token its first token.
        port,
        /// `.name ( [expr] )` header port; main_token the `.`, `opt_node`.
        named_port,
        /// `nature name [: parent[.potential|.flow]] [;] attrs endnature`;
        /// list of `nature_attr`.
        nature_decl,
        /// `name = expr ;`; main_token the name (identifier or attribute
        /// keyword); `node` value.
        nature_attr,
        /// `discipline name [;] items enddiscipline`; list of the three
        /// discipline item tags and `nature_attr`.
        discipline_decl,
        /// `potential|flow nature ;`; `token` the nature name.
        discipline_binding,
        /// `potential|flow . nature_attr`; `node` the `nature_attr`.
        discipline_override,
        /// `domain continuous|discrete ;`; `token` the domain word.
        discipline_domain,
        /// `paramset name module ; items endparamset`; list of declarations,
        /// `paramset_override` and statements.
        paramset_decl,
        /// `.name = expr ;` in a paramset; main_token the `.`; `node`.
        paramset_override,
        /// `connectrules name ; items endconnectrules`; list.
        connectrules_decl,
        /// `connect d {, d} resolveto d|exclude ;`; `token` the `resolveto`.
        connect_resolution,
        /// `connect module [merged|split] [#(...)] [overrides] ;`;
        /// `extra` -> `Insertion`.
        connect_insertion,
        /// `primitive name ( ports ) ; items endprimitive`; `extra` -> `Udp`.
        udp_decl,
        /// `initial port = value ;`; `node` the value.
        udp_initial,
        /// `table entries endtable`; list of `udp_entry`.
        udp_table,
        /// One table row, its symbols the tokens from main_token to the
        /// `;` in `token`.
        udp_entry,
        /// `config name ; design ... ; rules endconfig`; list of
        /// `config_design` and `config_rule`.
        config_decl,
        /// `design cells ;` or one config rule; `token` the `;`, the rest
        /// in the tokens between.
        config_design,
        config_rule,

        // ---- module items (A.1.4) ----
        /// `parameter|localparam|specparam [signed] [type] [range] assigns`;
        /// `extra` -> `Decl`, items `param_assign`.
        param_decl,
        /// `name {dim} = value {value_range}`; `extra` -> `ParamAssign`.
        param_assign,
        /// `from|exclude ...`; `extra` -> `ValueRange`.
        value_range,
        /// `( reject [, error] )`, a `PATHPULSE$` specparam's limits;
        /// `node_and_opt_node`.
        pulse_limits,
        /// A declared range or dimension `[ msb : lsb ]` (A.2.5); main_token
        /// the `[`; `node_and_node`.
        range,
        /// `aliasparam alias = target ;`: tokens main+1 and main+3.
        aliasparam_decl,
        /// `integer|real|string|realtime|time|reg ...`; `extra` -> `Decl`,
        /// items `declarator`.
        var_decl,
        /// A declared name (a dotted path for an out-of-context net):
        /// `extra_and_opt_node`: the dims `SubRange` and the initializer.
        declarator,
        /// `genvar names ;` and `event names ;`: list of `declarator`.
        genvar_decl,
        event_decl,
        /// A net declaration: main_token its discipline, net type, `ground`
        /// or `wreal`; `extra` -> `NetDecl`.
        net_decl,
        /// `input|output|inout ...`: `extra` -> `Decl`, items `declarator`.
        port_decl,
        /// `branch ( terms ) names ;`; `extra` -> `Branch`.
        branch_decl,
        /// `assign [strength] [delay] assigns ;`; `extra` -> `Decl` (range:
        /// the delay), items `net_assign`.
        continuous_assign,
        /// `defparam assigns ;`: list of `net_assign`.
        defparam,
        /// `lhs = rhs` in a list; main_token the `=`; `node_and_node`.
        net_assign,
        /// `module [#(params)] instances ;`; main_token the module name;
        /// `extra` -> `Instantiation`, params expressions or `named_param`,
        /// items `instance`.
        module_instantiation,
        /// `.name ( [value] )`; main_token the `.`; `opt_node`.
        named_param,
        /// `name [range] ( conns )`; main_token the name; `extra` ->
        /// `Instance`, conns slots of expressions and `named_port`.
        instance,
        /// A UDP, gate or switch instantiation: main_token the UDP name or
        /// gate keyword; `extra` -> `Decl` (range: the delay), items
        /// `gate_instance`.
        udp_instantiation,
        gate_instantiation,
        /// `[name [range]] ( terms )`; main_token its first token; `extra`
        /// -> `GateInstance`.
        gate_instance,
        /// `# value` or `#( values )`; list of up to three values.
        delay,
        /// `initial|always stmt`; `node`.
        initial,
        always,
        /// `analog stmt` / `analog initial stmt`; `node`.
        analog,
        analog_initial,
        /// `[analog] function ...` / `task ...`; main_token `analog`,
        /// `function` or `task`; `extra` -> `Function`.
        function_decl,
        task_decl,
        /// `generate items endgenerate`; list.
        generate_region,
        /// `for ( init ; cond ; step ) block`; `extra` -> `For`.
        generate_for,
        /// `if ( cond ) block [else block]`; `node_and_extra` -> `If`.
        generate_if,
        /// `case ( expr ) items endcase`; `node_and_extra` -> `SubRange`.
        generate_case,
        /// `begin [: name] items end`; list.
        generate_block,
        /// `specify items endspecify`; list.
        specify_block,
        /// `pulsestyle_*|showcancelled|noshowcancelled terms ;`; list.
        specify_terminals,
        /// `[if (c)|ifnone] ( in => out ) = delays ;`; `extra` -> `Path`.
        path_decl,
        /// `$check ( args ) ;`; slots.
        timing_check,
        /// `[posedge|negedge|edge [...]] term [&&& cond]`;
        /// `node_and_opt_node`; main_token the edge keyword or the term's
        /// first token.
        timing_event,

        // ---- statements (A.6) ----
        /// `begin|fork [: name] items end|join`; list of declarations and
        /// statements.
        block,
        /// `if ( c ) s [else s]`; `node_and_extra` -> `If`.
        if_stmt,
        /// `case|casex|casez ( e ) items endcase`; `node_and_extra` ->
        /// `SubRange` of `case_item`.
        case_stmt,
        /// `labels : body` or `default [:] body`; `extra_and_node`: the
        /// labels `SubRange`, the body.
        case_item,
        /// `for ( init ; cond ; step ) s`; `extra` -> `For`.
        for_stmt,
        /// `while|repeat|wait ( e ) s`; `node_and_node`.
        while_stmt,
        repeat_stmt,
        wait_stmt,
        /// `forever s`; `node`.
        forever_stmt,
        /// `# delay s`; `node_and_node`.
        delay_stmt,
        /// `@ event s`; `opt_node_and_node` (none: `@*`).
        event_stmt,
        /// `lhs = rhs ;` and `lhs <= rhs ;`; main_token the operator;
        /// `node_and_node`.
        assign,
        nonblocking_assign,
        /// The same with intra-assignment timing; `node_and_extra` -> `Timed`.
        assign_timed,
        nonblocking_assign_timed,
        /// `lhs <+ rhs ;`; `node_and_node`.
        contribution,
        /// `lhs : probe == eqn ;`; main_token the `:`; `node_and_extra` ->
        /// `Indirect`.
        indirect_contribution,
        /// `assign|force lhs = rhs ;` / `deassign|release lhs ;`;
        /// `node_and_opt_node`.
        procedural_continuous,
        /// A task or system task enable; `node` the name or call.
        task_enable,
        /// `-> event ;`; `node`.
        event_trigger,
        /// `disable path ;`; `node`.
        disable,
        /// `return [e] ;`; `opt_node`.
        return_stmt,
        break_stmt,
        continue_stmt,
        /// `;`.
        null_stmt,
        /// Intra-assignment timing: `# value` (`node`), `@ event`
        /// (`opt_node`), `repeat ( n ) @ event` (`node_and_opt_node`).
        delay_control,
        event_control,
        repeat_control,

        // ---- expressions (A.8) ----
        /// A name: an identifier, escaped, system or freed keyword token,
        /// `inf`, `potential`/`flow`, or a built-in function name.
        identifier,
        number_literal,
        string_literal,
        /// `( e )`; `node_and_token` (the `)`).
        grouped,
        /// `min : typ : max`; main_token the first `:`; `node_and_extra` ->
        /// `MinTypMax`.
        mintypmax,
        /// Operator token at main_token; `node`.
        unary,
        /// Operator token at main_token; `node_and_node`.
        binary,
        /// `c ? a : b`; `node_and_extra` -> `Ternary`.
        ternary,
        /// `lhs . name`; `node_and_token`.
        field_access,
        /// `lhs [ i ]`; `node_and_node`.
        index,
        /// `lhs [ msb : lsb ]`, `lhs [ base +: w ]`, `lhs [ base -: w ]`;
        /// `node_and_extra` -> `Pair`.
        range_select,
        indexed_select_up,
        indexed_select_down,
        /// `callee ( args )`; main_token the `(`; `node_and_extra` ->
        /// slots `SubRange`.
        call,
        /// `< net >` as a probe argument (§5.4.3); `node`.
        port_branch,
        /// `{ items }`; list.
        concat,
        /// `{ n { items } }`; `node_and_node` (count, `concat`).
        multi_concat,
        /// `'{ items }`; slots.
        assign_pattern,
        /// `'{ n { items } }`; `node_and_node` (count, `concat`).
        pattern_repl,
        /// `a or b`, `a , b` in an event expression; `node_and_node`.
        event_or,
        /// `posedge|negedge|driver_update e`; `node`.
        edge_event,
        /// `initial_step|final_step [( strings )]`: tokens.
        step_event,
        /// `.name` in a paramset statement (§6.4.3): `token` the name.
        paramset_output,
        /// `(* specs *)`; list of `attr_spec`.
        attribute,
        /// `name [= value]`; `opt_node`.
        attr_spec,
    };

    pub const Data = union {
        none: void,
        node: Index,
        opt_node: OptionalIndex,
        token: TokenIndex,
        extra: ExtraIndex,
        node_and_node: struct { Index, Index },
        node_and_opt_node: struct { Index, OptionalIndex },
        opt_node_and_node: struct { OptionalIndex, Index },
        node_and_extra: struct { Index, ExtraIndex },
        extra_and_node: struct { ExtraIndex, Index },
        extra_and_opt_node: struct { ExtraIndex, OptionalIndex },
        node_and_token: struct { Index, TokenIndex },
        extra_range: SubRange,
    };

    /// `module_decl`: the parameter header, the ports and the items.
    pub const Module = struct { params_start: ExtraIndex, params_end: ExtraIndex, ports_start: ExtraIndex, ports_end: ExtraIndex, items_start: ExtraIndex, items_end: ExtraIndex };
    /// A declaration with an optional range (or delay) and a list of items.
    pub const Decl = struct { range: OptionalIndex, items_start: ExtraIndex, items_end: ExtraIndex };
    pub const NetDecl = struct { range: OptionalIndex, delay: OptionalIndex, items_start: ExtraIndex, items_end: ExtraIndex };
    pub const ParamAssign = struct { dims_start: ExtraIndex, dims_end: ExtraIndex, value: Index, ranges_start: ExtraIndex, ranges_end: ExtraIndex };
    /// `lo` is `[`- or `(`-bracketed as the token after main_token says;
    /// `close` is the closing bracket, none for a bare `exclude` value.
    pub const ValueRange = struct { lo: Index, hi: OptionalIndex, close: OptionalTokenIndex };
    pub const Branch = struct { hi: Index, lo: OptionalIndex, items_start: ExtraIndex, items_end: ExtraIndex };
    pub const Instantiation = struct { params_start: ExtraIndex, params_end: ExtraIndex, items_start: ExtraIndex, items_end: ExtraIndex };
    pub const Instance = struct { range: OptionalIndex, conns_start: ExtraIndex, conns_end: ExtraIndex };
    pub const GateInstance = struct { range: OptionalIndex, terms_start: ExtraIndex, terms_end: ExtraIndex };
    /// `ports`: the header's `port_decl`s; `items`: declarations and the
    /// body statements, in order. `range`: a digital function's result range.
    pub const Function = struct { range: OptionalIndex, ports_start: ExtraIndex, ports_end: ExtraIndex, items_start: ExtraIndex, items_end: ExtraIndex };
    pub const Udp = struct { ports_start: ExtraIndex, ports_end: ExtraIndex, items_start: ExtraIndex, items_end: ExtraIndex };
    pub const Insertion = struct { params_start: ExtraIndex, params_end: ExtraIndex, overrides: OptionalTokenIndex };
    pub const For = struct { init: Index, cond: Index, step: Index, body: Index };
    pub const If = struct { then: Index, @"else": OptionalIndex };
    pub const Timed = struct { timing: Index, rhs: Index };
    pub const Indirect = struct { probe: Index, eqn: Index };
    pub const MinTypMax = struct { typ: Index, max: Index };
    pub const Ternary = struct { then: Index, @"else": Index };
    pub const Pair = struct { a: Index, b: Index };
    /// `arrow` is the `=>` or `*>`.
    pub const Path = struct { cond: OptionalIndex, inputs_start: ExtraIndex, inputs_end: ExtraIndex, outputs_start: ExtraIndex, outputs_end: ExtraIndex, data_source: OptionalIndex, delays_start: ExtraIndex, delays_end: ExtraIndex, arrow: TokenIndex };

    comptime {
        // A node row is 13 bytes SoA; a bare union carries a safety tag in
        // safe builds, so only the release layout is pinned (as Zig does).
        assert(@sizeOf(Tag) == 1);
        if (!std.debug.runtime_safety) assert(@sizeOf(Data) == 8);
    }
};

/// One parse error, kept in the tree: what was wrong at `token`, and the
/// tag `expected_token` wanted.
pub const Error = struct {
    tag: Tag,
    token: TokenIndex,
    extra: union { none: void, expected_tag: Token.Tag } = .{ .none = {} },
    /// Which rule of `tag` refused, where its report names it
    /// (`parse_errors`); `.generic` otherwise.
    site: Site = .generic,
    /// What the site's report names beside `token`: a token (a timing
    /// check's name) or packed counts; the site's doc says which.
    arg: u32 = 0,

    /// The rules a coarse `Tag` covers whose reports differ.
    pub const Site = enum(u8) {
        generic,
        /// A.7.1: `pulsestyle_*` / `*showcancelled` list in parentheses.
        specify_list_parenthesized,
        /// §14.2.4.1 Table 14-1: an operator a state-dependent path's
        /// condition may not use.
        specify_condition_operator,
        /// A.7.1: a token that begins no specify item.
        specify_item,
        /// A.7.2: no `=>` or `*>` after the path's inputs.
        specify_path_arrow,
        /// Syntax 14-4: polarity before the arrow of an edge-sensitive path.
        specify_polarity_placement,
        /// Syntax 14-5: `ifnone` with an edge-sensitive path.
        specify_ifnone_edge,
        /// A.7.2: `=>` with a list; `arg` is sources << 16 | destinations.
        specify_parallel_list,
        /// A.7.4: a delay count other than 1, 2, 3, 6, 12; `arg` the count.
        specify_delay_count,
        /// A.7.5.1: a system name that is no timing check.
        specify_timing_check_name,
        /// §15.3.4: `$width`'s threshold or notifier left null.
        specify_width_null,
        /// A.7.5.3: `$period`/`$width` reference event without a control;
        /// `arg` the check's name token.
        specify_event_control,
        /// A.7.5.2: a notifier that is no variable name; `arg` the name token.
        specify_notifier,
        /// A.7.5.1: the argument count; `arg` is n | min << 8 | max << 16.
        specify_arity,
        /// A.7.5.3: an edge descriptor outside the table; `arg` the token
        /// after it.
        specify_edge_descriptor,
        /// A.2.1.2: `reg`/`integer`/`time` on a port that is no `output`.
        port_variable_type,
        /// A.2.6: an analog function formal's type; `arg` its direction token.
        port_analog_typed,
        /// A.2.6: a digital function formal that is no `input`.
        function_input_only,
        /// A.2.7: a task or function port list that opens with a name.
        tf_port_list_direction,
        /// A.1.3: a port declaration after a `list_of_ports` port.
        port_after_list,
        /// A.2.1.3: two net types in one declaration.
        net_two_types,
        /// §4.3.2: `scalared`/`vectored` with no range.
        net_advised_no_range,
        /// A.2.1.3: the range after the delay.
        net_range_after_delay,
        /// §3.6.3.2: initialized and plain names mixed; `arg` 1 when this
        /// name has the initializer.
        net_mixed_init,
        /// §4.4: a drive strength with no assignment.
        net_drive_no_init,
        /// A.2.1.3: a charge strength on a net that is no `trireg`.
        charge_strength_net,
        /// A.2.2.2: a charge strength word that is none.
        charge_strength_word,
        /// §6.1.4: a drive strength not one 0-side and one 1-side.
        strength_sides,
        /// §6.1.4: both drive strengths high impedance.
        strength_highz,
        /// A.3.2: a pull gate's single strength on the other side; `arg` 1
        /// for `pullup`.
        strength_single,
        /// A.3.1: a gate's terminal count; `arg` the gate keyword's token.
        gate_count,
        /// A.3.3: a gate output that is no net_lvalue.
        gate_output,
        /// A.4.1.1: a module instance with no name; `arg` its terminal count.
        instance_unnamed,
        /// A.4.1: ordered and named parameter assignments in one list.
        param_list_mixed,
        /// A.2.2.3: a delay's list not closed by `)` after its last value.
        delay_close,
        /// A.2.5: `from` with a bare value, which only `exclude` takes.
        value_range_bare_from,
        /// A.9.1: a keyword as an attribute name.
        attr_keyword_name,
        /// A.1.6: a parent nature access that is no `potential`/`flow`.
        nature_parent_access,
        /// A.1.7: a domain that is no `continuous`/`discrete`.
        discipline_domain,
        /// A.1.7: a token that begins no discipline_item.
        discipline_item,
        /// §7.8.3: a connect_mode that is no `merged`/`split`.
        connect_mode,
        /// §10.6: a Verilog-AMS construct under a 1364 language; `arg` the
        /// language (`KeywordSet`).
        vams_under_language,
        /// IEEE 1364-2005 §15.1: a timing check as a procedural statement.
        timing_check_in_procedure,
        /// A.1.5: a configuration whose first statement is no `design`.
        config_design_first,
        /// A.1.5: end of file before `endconfig`.
        config_no_endconfig,
        /// A.1.5: a token that begins no config_rule_statement.
        config_rule_start,
        /// IEEE 1364-2005 §13.3.1.2: a second default clause.
        config_two_defaults,
        /// §13.3.1.4: a library-qualified cell clause with a liblist.
        config_lib_liblist,
        /// A.1.5: a rule with no expansion clause; `arg` the rule's token.
        config_expansion,
        /// A.1.5: a use_clause's `:` not followed by `config`.
        config_use_suffix,
        /// A.5.1: a udp_body that opens with no `table`.
        udp_body,
        /// A.5.3: end of file before `endtable`.
        udp_no_endtable,
        /// A.5.3: an entry not closed by `;`.
        udp_entry_semicolon,
        /// A.5.3: an entry's colon count other than 1 or 2; `arg` the count.
        udp_colons,
        /// A.5.3: an entry whose body differs from the first entry's; `arg`
        /// 1 when this entry is sequential.
        udp_body_mixed,
        /// A.5.3: an edge in a combinational entry; `arg` the character.
        udp_comb_edge,
        /// §8.4: two input transitions in a sequential entry.
        udp_two_edges,
        /// A.5.3: an input that is no level or edge symbol; `arg` the character.
        udp_input_symbol,
        /// A.5.3: an edge_indicator that is no `( level level )`.
        udp_edge_shape,
        /// A.5.3: a current_state that is no level symbol; `arg` the character.
        udp_state_symbol,
        /// A.5.3: a current_state of other than one symbol; `arg` the count.
        udp_state_count,
        /// A.5.3: an output of other than one symbol; `arg` the count.
        udp_output_count,
        /// A.5.3: an output that is no output symbol; `arg` the character.
        udp_output_symbol,
    };

    pub const Tag = enum(u8) {
        /// `extra.expected_tag` was wanted at `token`.
        expected_token,
        expected_identifier,
        expected_expr,
        expected_statement,
        expected_module_item,
        expected_description,
        expected_strength,
        /// A §2.6.1 or §2.6.2 literal `number_literal` refuses.
        invalid_number,
        /// A §2.7 string with an escape above `\377`.
        invalid_string_escape,
        /// §10.6: an unknown or newer specifier; an unmatched `end_keywords.
        unknown_keyword_set,
        unmatched_end_keywords,
        /// §10.6 / IEEE 1364 §19: a directive only legal between design
        /// elements, inside one.
        directive_inside_design_element,
        /// A Verilog-AMS design element or module item under a 1364 set.
        vams_construct_under_1364,
        /// Annex C: a construct outside the Verilog-A subset, under
        /// `ParseOptions.verilog_a`.
        outside_verilog_a,
        /// A.1.1's library_text in source_text.
        library_text_in_source,
        /// IEEE 1364-2005 §14.1: a specify block outside a module.
        specify_outside_module,
        /// §6.2.2: module declarations do not nest.
        nested_module,
        /// Syntax 6-8: a generate_block is not a module item on its own.
        begin_at_module_scope,
        /// §2.9: an attribute instance inside an attribute value, or one
        /// that prefixes nothing.
        nested_attribute,
        attribute_prefixes_nothing,
        /// A.6.3: declarations need a named block.
        decl_in_unnamed_block,
        /// A.6.4: a null statement where an `analog_statement` is required
        /// (Verilog-AMS sets only).
        null_statement,
        /// IEEE 1364-2005 A.6.8: `forever` takes a statement.
        forever_needs_statement,
        /// A.8.5: an assignment target is never a literal.
        literal_assignment_target,
        /// A.6.5: `initial_step()` / `final_step()` with an empty list.
        empty_step_event_list,
        /// §2.6.2: a scale factor in a digital delay.
        scale_factor_in_delay,
        /// A.4.1 / A.1.3: an empty or mixed parameter list, or `localparam`
        /// in a module parameter header.
        invalid_parameter_list,
        /// A.2.1.3: a charge strength on a net other than `trireg`, a drive
        /// strength without an assignment, a mixed initializer list, a
        /// range after the delay, `vectored`/`scalared` without a range.
        invalid_net_declaration,
        /// A.2.1.2 / A.2.6 / A.2.7: a variable type on a non-output port, a
        /// typed analog function formal, a digital function non-input, a
        /// port list that opens with no direction.
        invalid_port_declaration,
        /// A.3: a gate's terminal count or an output that is no net_lvalue.
        invalid_gate_terminals,
        /// A.5: a UDP's ports, table shape or symbols.
        invalid_udp,
        /// A.7: a path, pulse or timing check shape.
        invalid_specify_item,
        /// A.1.5: a config rule that pairs a library cell with `liblist`.
        invalid_config_rule,
        /// A.1.9: a paramset without declarations, or a statement form it
        /// does not admit (§6.4.1).
        invalid_paramset,
        /// A.2.1.3: a delay value that is a sized or based number.
        invalid_delay_value,
        /// Syntax 6-8: a `parameter`, port declaration, specparam or
        /// specify block is no `module_or_generate_item`, and generate
        /// regions do not nest.
        not_a_generate_item,
        /// A.6.4: a digital statement form (`#`, `wait`, `forever`, `fork`,
        /// a procedural continuous or nonblocking assignment, a task enable,
        /// intra-assignment timing) in an analog statement.
        digital_statement_in_analog,
        /// A.8.2: a user function call with an empty argument, outside the
        /// discrete grammar.
        empty_argument,
        /// §4.7.1: an analog function with no formal argument, a named block
        /// or a `return` with no value; under Verilog-AMS a digital function
        /// with no formal argument too.
        invalid_function,
        /// §9.22: `driver_update` outside a connect module.
        driver_update_outside_connect_module,
        /// Deeper than `Parse.max_depth`.
        nesting_too_deep,
    };
};

const Ast = @This();

/// Tokenizes and parses `source`. The caller owns the tree and frees it
/// with `deinit(gpa)`; `source` must outlive it. Asserts the text fits
/// `u32` offsets.
pub fn parse(gpa: Allocator, source: [:0]const u8, options: ParseOptions) Allocator.Error!Ast {
    assert(source.len < std.math.maxInt(u32));
    var tokens: TokenList = .empty;
    defer tokens.deinit(gpa);
    // About 4 bytes of text per token, the old lexer's measure.
    try tokens.ensureTotalCapacity(gpa, source.len / 4 + 8);
    var tz: tokenizer.Tokenizer = .init(source);
    while (true) {
        const tok = tz.next();
        try tokens.append(gpa, .{ .tag = tok.tag, .start = @intCast(tok.loc.start) });
        if (tok.tag == .eof) break;
    }
    var slice = tokens.toOwnedSlice();
    errdefer slice.deinit(gpa);
    assert(slice.items(.tag)[slice.len - 1] == .eof);
    return Parse.run(gpa, source, slice, options);
}

/// Frees every table `parse` allocated with `gpa`; the tree is undefined after.
pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra_data);
    gpa.free(tree.errors);
    tree.* = undefined;
}

pub fn tokenTag(tree: *const Ast, i: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[i];
}

pub fn tokenStart(tree: *const Ast, i: TokenIndex) ByteOffset {
    return tree.tokens.items(.start)[i];
}

pub fn nodeTag(tree: *const Ast, n: Node.Index) Node.Tag {
    return tree.nodes.items(.tag)[@backingInt(n)];
}

pub fn nodeMainToken(tree: *const Ast, n: Node.Index) TokenIndex {
    return tree.nodes.items(.main_token)[@backingInt(n)];
}

pub fn nodeData(tree: *const Ast, n: Node.Index) Node.Data {
    return tree.nodes.items(.data)[@backingInt(n)];
}

/// Returns token `i`'s source text, the spelling for a fixed one and one
/// re-lex from its start otherwise. An escaped identifier keeps its `\`.
pub fn tokenSlice(tree: *const Ast, i: TokenIndex) []const u8 {
    const tag = tree.tokenTag(i);
    if (tag.lexeme()) |l| return l;
    var tz: tokenizer.Tokenizer = .{ .buffer = tree.source, .index = tree.tokenStart(i) };
    const tok = tz.next();
    assert(tok.tag == tag);
    return tree.source[tok.loc.start..tok.loc.end];
}

/// Reads the payload struct `T` (every field a `u32`-backed index) at `index`.
pub fn extraData(tree: *const Ast, index: ExtraIndex, comptime T: type) T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, F, i| {
        const word = tree.extra_data[@backingInt(index) + i];
        @field(result, name) = if (F == TokenIndex) word else @fromBackingInt(word);
    }
    return result;
}

/// The list `range` names, as `T` (`Node.Index` or `Node.OptionalIndex`).
pub fn extraDataSlice(tree: *const Ast, range: Node.SubRange, comptime T: type) []const T {
    return @ptrCast(tree.extra_data[@backingInt(range.start)..@backingInt(range.end)]);
}

/// The root's descriptions, in source order.
pub fn rootDecls(tree: *const Ast) []const Node.Index {
    assert(tree.nodeTag(.root) == .root);
    return tree.extraDataSlice(tree.nodeData(.root).extra_range, Node.Index);
}

test {
    _ = Parse;
    _ = full;
    _ = @import("Ast/test.zig");
}
