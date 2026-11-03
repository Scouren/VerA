# intern_pool + air: InternPool, Air, the Air interpreter

Read `README.md` first. You own `src/InternPool.zig` (+ `src/InternPool/`),
`src/Type.zig` and `src/Value.zig` if you want them (views over the pool; add them
to `intern_pool`'s root), `src/Air.zig` (+ `src/Air/`), `tests/differential/air.zig`
and `tests/differential/air.xfail`. Keep `InternPool.Index` and `InternPool.String`
exactly as the scaffold declares them.

## InternPool (Zig: `src/InternPool.zig`, 13k lines; yours is far smaller)

Every string, type and constant of a compilation behind one `Index`, deduplicated:
interning the same key twice gives the same `Index`. Single-threaded for now (no
per-thread shards); keep `items: MultiArrayList{ tag, data: u32 }`, `extra: []u32`,
`string_bytes: []u8` and a dedup map with an adapted context, as Zig does.

- `Key = union(enum)`: `simple_type` (real, integer, string), `int_type { bits: u16, signed: bool }`
  (a §5.4 sized integer, wider than 32 bits included), `array_type { len, elem }`,
  `nature { name, access, abstol, units, ddt_nature, idt_nature }`,
  `discipline { name, potential, flow, domain }`, `float` (f64, by exact bits),
  `int { ty, value }` (small values inline, wide ones as limbs in `extra`), `str` (a `String`).
- Well-known indexes first, fixed at comptime (Zig: `Index` named values):
  the three simple types, then the constants the old MIR keeps as sentinels
  (`src/ir/Mir.zig` `Value`: undef, 0.0, 1.0, -1.0, 2.0, 10.0, inf, 0, 1, -1).
- `get(key) !Index`, `indexToKey(index) Key`, `getString(bytes) !String`,
  `stringToSlice(String) [:0]const u8`. Nodes and branches are NOT keys (they are
  per-instance rows; `lib/TODO.md` appendix A.3).
- Oracle: properties (round trip `indexToKey(get(k)) == k`; dedup; distinct keys
  give distinct indexes; NaN bit patterns stay distinct, `-0.0 != 0.0`), over
  random keys from a seeded PRNG.

## Air (Zig: `src/Air.zig`; structured, settled in `lib/TODO.md` §11.3)

- `instructions: MultiArrayList(Inst).Slice`, `extra: []const u32`;
  `Inst = struct { tag: Tag (u8), data: Data }`, `@sizeOf(Data) == 8` asserted
  (Z/Air.zig:1371). `Inst.Ref = enum(u32)`: an interned `InternPool.Index`, or an
  instruction index with the high bit set (Z/Air.zig:1234-1254). The instruction
  index IS its value: no separate value table, no result column.
- **Variables are slots** (`lib/TODO.md` §11.7): `alloc` (the slot's type),
  `load`, `assign` (no result); a loop carries and an if/else merges variables
  through slots.
- **Structured control flow, no CFG, no phis:** `block` (a body in `extra`, a
  result), `br` (leave a block with a value), `cond_br` (two bodies), `loop` (a
  body re-entered by `repeat`), `select` (a value-level if). Dominance is nesting.
  This replaces `src/ir/mir_blocks.zig` + the phi machinery and is what makes
  the later prove/ passes small (`lib/TODO.md` §6 "Step B").
- Tags: the old `src/ir/opcode.zig` `Opcode` set (93 opcodes: arithmetic,
  comparisons, logic, bitwise, shifts, the Table 4-14/4-15 math, casts,
  `opt_barrier`, `dstop`, `path_prev`/`path_acc`, `anew`/`fload`/`iload`/`store`),
  plus `arg` (a parameter), `probe` (a §4.4 read of an unknown), `call`
  (a system/user call: callee id + args in `extra`; use the old `src/ir/callee.zig`
  `Callee` enum's integer for now), and the control tags above.
- `tag_info: std.EnumArray(Inst.Tag, Info)`: port `opcode.zig`'s table (class,
  domain, int/bool result, relation, label) — without its `fold` column: folding is
  Sema's, and the interpreter below must not share it.
- `Air/print.zig`: a readable text dump of a body (Z/Air/print.zig), for
  debugging (`zig build` users will read it). `Air/Verify.zig`: well-formedness
  (every operand defined before use within its nesting, `br` targets an
  enclosing block, types consistent), Debug-only, panicking with the instruction.
- `Air/interp.zig`: a concrete interpreter over structured Air: args in, the
  result of a body out; loops bounded by a caller-given iteration cap. It
  implements each opcode itself with `std.math` and plain arithmetic, so it is
  an independent implementation (later the `falsify` oracle of the float pass
  and `codegen/verilog`'s evaluator).

## The oracle: `zig build diff-air`

`tests/differential/air.zig` (wired already; imports `air`, `intern_pool`, the
old `ir`, `kernels`). For every opcode the old `ir/opcode.zig` folds
(`opcode.fold`, which calls `kernels.fold`): build a one-instruction Air body,
run `Air/interp.zig` over a sweep of operands (the specials: ±0, ±inf, NaN, the
smallest subnormal, the largest double, integer limits, 0, ±1; then 10^5 seeded
random operands per opcode), and compare with the old fold bit for bit (NaN
compared as NaN). Then structured control: hand-built bodies whose results are
known (a loop summing 1..n, a nested `cond_br`, `select` vs `cond_br` giving the
same value: a metamorphic pair). `air.xfail` lists allowed differences per
opcode with a reason (for example an opcode the old fold leaves unfolded).

## Done when

`zig build test-intern_pool`, `zig build test-air`, `zig build diff-air` and
`zig build check` pass; `diff-air` reports opcodes and operands compared;
`tools/check_style.py` is clean on your files.
