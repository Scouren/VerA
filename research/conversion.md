# Research: real to integer conversion past 32 bits (codegen T39)

Planner: read-only research against `refactor` at e6a1b342; no builds, no
runs. Every number below is read from a source file, a fixture, a list line
or a commit message, never measured. Sources: `docs/specification/VAMS-LRM-2023.pdf`
and `1364-2005.pdf` through `pdftotext -layout` (page numbers are the PDF's
printed ones), the suite under `tests/conformance/tests`, the old side
(`lib/frontend`, `src/analog`, `src/ir`, `src/codegen/device`, `lib/kernels`),
the new side (`src/Sema`, `src/Air`, `src/codegen/zig`, `lib/std/kernels`),
the digital runtime (`lib/sim/rt`), and `tests/conformance/external`
(OpenVAF-Reloaded, ngspice).

Owns: codegen T39 (on hold until this file's `Decision:` lines are filled),
`lower.rulings` line 19, the `integer_parameter_precision_*` lines of
`comp.xfail` (208, 211, 212) and `lower.xfail` (37, 38), and the fixture
`integer_conversion_saturates.va`.

---

## 0. The answer in one paragraph

Neither LRM says what a real becomes when its rounded value does not fit an
`integer`; neither contains the word "saturate". Both give the type modular
semantics everywhere else (§3.2 "2's complement results", IEEE §4.8
"twos-complement results", §5.6 "MSBs ... discarded", §12.2 "converted to the
type and size of the destination", §4.3.1 "not required to detect overflow"),
and VerA has already read those for the integral case three times (VD-049,
VD-130, `specparam_range_and_select` ruling): the low 32 bits, never
saturation. The suite's seven real-to-integer rows past 2^31 all pin the low
32 bits (`4294967297.0` is 1). The one fixture that pins saturation,
`integer_conversion_saturates.va`, says in its own header that saturation is
"VerA's defined answer" (a choice, not a reading), and its two run-time rows
assert that an `integer` variable holds a value above 2^31-1, which §3.2
forbids and which no 32-bit rule, the lead's included, can satisfy. The
lead's guess (wrap below 2^63, saturate past) is exactly the old side's
accidental composition of `asIntExact`'s i64 bound with `lossyCast`; the old
side's own `derive` path contradicts it (1e300 is 2147483647 as a default and
-1 once derived). Recommendation (Q1): one rule everywhere, **round to
nearest, ties away from zero, then the low 32 bits of that integer, two's
complement, at any magnitude** (for every double of magnitude 2^84 or more
that is 0); NaN and an infinity are E0368 in a constant and 0 at run time.
It costs rewriting three rows of one fixture and one ruling line; it removes
the i64 carrier from the language and makes the analog `fi_cast` agree with
the digital `ofRealTo` (`lib/sim/rt/logic/reals.zig:105`), which already
implements this rule with iverilog as its gold.

---

## 1. The LRM text

### 1.1 VAMS-2023

**§3.2 Integer and real data types (p. 24).** "An integer declaration declares
one or more variables of type integer. These variables can hold values
ranging from -2^31 to 2^31-1." "Arithmetic operations performed on integer
variables produce 2's complement results." "See 4.2.1.1 for a discussion of
real to integer conversion and 4.2.1.2 for a discussion of integer to real
conversion."

**§3.4.1 Type specification (p. 28).** "If the type of the parameter is
specified as integer or real, and the value assigned to the parameter
conflicts with the type of the parameter, the value is converted to the type
of the parameter (see 4.2.1.1)." The untyped case: "If the type of a
parameter is not specified, it is derived from the type of the final value
assigned to the parameter, after any value overrides have been applied, as in
IEEE Std 1364 Verilog."

**§4.2.1 Operators with real operands (p. 52).** "If a real expression is used
for the replication factor of a concatenation, the expression will first be
converted to an integer value using the rules described in 4.2.1.1".

**§4.2.1.1 Real to integer conversion (p. 52), in full.** "Real numbers are
converted to integers by rounding the real number to the nearest integer,
rather than by truncating it. Implicit conversion takes place when a real
number is assigned to an integer. If the fractional part of the real number
is exactly 0.5, it shall be rounded away from zero." Examples: "The real
numbers 35.7 and 35.5 both become 36 when converted to an integer and 35.2
becomes 35. Converting -1.5 to integer yields -2, converting 1.5 to integer
yields 2."

**§4.2.1.3 Arithmetic conversion (p. 52).** "If either operand is real, the
other operand is converted to real." (The other direction; never
real-to-integer.)

**§6.3.4 Parameter dependence (p. 141).** Only that "a modification of
gate_width or gate_length changes the value of gate_cap". Nothing on
conversion; the fixtures cite it for re-derivation, not for the value.

**§9.11 Conversion system functions (p. 237).** "Verilog AMS HDL extends the
conversion functions defined in IEEE Std 1364 Verilog so that $bitstoreal
and $realtobits, $rtoi and $itor can be used in the analog context." No text
of its own on overflow.

**§12.16 Table 12-4, NOTE.** "If the object has a real value, it shall be
converted to an integer using the rounding defined by the Verilog-AMS HDL
before being returned in a format other than vpiRealVal."

**Silent:** the whole of VAMS-2023 has no sentence for a rounded value
outside -2^31..2^31-1. The word "saturat" occurs once, in "saturation
current" (line 16015 of the text dump). The only modular statement is §3.2's,
and it is about "arithmetic operations".

### 1.2 IEEE 1364-2005

**§3.5.3 Conversion (p. 12)** and **§4.8.2 Conversion (p. 33)** are the same
sentence as VAMS §4.2.1.1 ("Real numbers shall be converted to integers by
rounding the real number to the nearest integer, rather than by truncating
it. Implicit conversion shall take place when a real number is assigned to an
integer. If the fractional part of the real number is exactly 0.5, it shall
be rounded away from zero."), followed in §4.8.2 by the other direction:
"Individual bits that are x or z in the net or the variable shall be treated
as zero upon conversion."

**§4.8 Integers, reals, times, and realtimes (p. 33).** "integer variables
shall be treated as signed regs with the least significant bit being zero.
Arithmetic operations performed on integer variables shall produce
twos-complement results." "Implementations may limit the maximum size of
integer variables, but it shall be at least 32 bits." (VAMS §3.2 fixes it at
32: "-2^31 to 2^31-1".)

**§4.3.1 (p. 24).** "Implementations are not required to detect overflow of
integer operations."

**§4.10.1 Module parameters (p. 37).** "The conversion rules between real
and integer values described in 4.8.2 apply to parameters as well."

**§5.6 Assignments and truncation (p. 66).** "If the width of the right-hand
expression is larger than the width of the left-hand side in an assignment,
the MSBs of the right-hand expression will always be discarded to match the
size of the left-hand side. Implementations are not required to warn or
report any errors related to assignment size mismatch or truncation.
Truncating the sign bit of a signed expression may change the sign of the
result."

**§12.2 Overriding module parameter values (p. 167).** "A parameter with a
type specification, but with no range specification, shall be of the type
specified. An override value shall be converted to the type of the
parameter." And: "When a typed and/or ranged parameter is overridden, the new
value is converted to the type and size of the destination and assigned to
that parameter."

**§17.8 Conversion functions (p. 310).** Prototype `integer $rtoi(real_val)`;
"$rtoi Converts real values to integers by truncating the real value (for
example, 123.45 becomes 123)."

**Silent:** no sentence for a real whose rounded value exceeds the integer
type; "saturat" does not occur in the text. What the standard does say about
putting a too-wide value into a narrower integer object is §5.6 (discard the
MSBs) and §12.2 (convert to the type and size of the destination).

### 1.3 What the two texts settle, and what they leave

Settled: the rounding (nearest, ties away from zero) in every context the
fixtures name: assignment, parameter default, override (§12.2, §4.10.1),
replication factor (§4.2.1), VPI (§12.16). Settled: the type is 32 bits,
signed, two's complement, with overflow undetected. Left open: the one
sentence "a real whose rounded value is outside the type gives ...". Any rule
VerA picks there is VerA's. The reading with the least new law is that the
rounded value is an integer, and storing an integer into a 32-bit object
keeps its low 32 bits (§5.6, §12.2, VD-049, VD-130): that needs no sentence
the texts lack. Saturation needs one.

---

## 2. The suite

Every fixture whose rows pin a real or integral value past 2^31 landing in an
`integer`, from `command grep` over `tests/conformance/tests` for `rtoi`,
`wrap`, `saturat`, `overflow`, `2147483647/8`, `4294967297`, `1e300`. Column
"old/new": the lists' current verdicts.

| # | fixture (`tests/conformance/tests/`) | row | context | expects | `//! lrm` | old/new |
|---|---|---|---|---|---|---|
| A1 | `verilog-a/ch03_data_types/integer_parameter_precision_derive.va:23,33` | `parameter integer realwide = 4294967297.0` | parameter default, real | **1** ("rounds and wraps32") | 3.4.1, 6.3.4:1000 | old 1; new 2147483647 (`comp.xfail:208`) |
| A2 | same `:24,34` | `parameter realwidecopy = realwide` | untyped copy of an integer | 1 ("keeps32") | | same line |
| A3 | same `:22,39` | `words[0:2] = '{64'h4142434445464748, word, 4294967297.0}` | array-parameter element, real | `words[2]` = **1**; `words[0]` = 1162233672 (low 32 of the integral) | 3.4.4 | same line |
| A4 | same `:25-26,35-36` | `positive_tie = 3.5`, `negative_tie = -3.5` | parameter, tie | 4, -4 | 4.2.1.1 | agree |
| A5 | same `:19-21,43-45` | `localparam integer root = sqrt(realbase)`, `power = pow(realbase, 2.0)`, `converted = realbase` (card `realbase = 9.0`) | localparam, real, card-derived | 3, 81, 9 | 6.3.4 | agree |
| B1 | `.../integer_parameter_precision_real_dependents.va:7,18` | `parameter integer a = 4294967297.0` | parameter default | **1** ("wraps before use") | 3.4.1 | `comp.xfail:211` (new: exit 1) |
| B2 | same `:10,21-22` | `aa[1:0] = '{4294967297.0, 4294967299.0}` | array element | `aa[1]` = 1, `aa[0]` = 3 | 3.4.4 | `lower.xfail:38` (new listed at 4294967297, a pre-T10 number) |
| B3 | same `:13-14,25` | `parameter integer negative = 4294967295.0`, `negative_quotient = negative / 2` | parameter; then integer division | -1, so 0 | 3.4.1 | same |
| C1 | `.../integer_parameter_precision_real_dependents_host.va:8-9,19` | card `source = 4294967303.0` (real); `parameter integer a = source` | §6.3.4 row derived at run time from a real | **7** | 6.3.4:1000 | `comp.xfail:212` (new: exit 1) |
| C2 | same `:12,22-23` | `aa[1:0] = '{source, source+2.0}` | derived array elements | 7, 9 | 3.4.4 | `lower.xfail:37`; also needs codegen T38 |
| C3 | same `:15,26` | `parameter real product = a * 1073741824` | integer arithmetic, then to real | -1073741824 (7·2^30 wraps) | 3.2 | same |
| D | `.../integer_param_low32.va` + `tests/host/integer_param_host.zig` | card `word = 4294967297` (integral) into `parameter integer word` | host card, integral | 1; the host test adds 4294967295 → -1 | 3.4.1 | agree |
| E | `.../integer_parameter_precision.va:17-18,28-29` | `parameter integer narrowed = 64'hf123456789abcdef`; `localparam integer typedcopy = highbits` | integral literal, typed copy | -1985229329 ("truncates32") | 3.4.1 | `comp.xfail:205` is the untyped `base` row (`lower.xfail:39`), not these |
| F | `.../integer_parameter_precision_override.va:12,19` | `parameter integer narrowed = code`, `#(.code(64'h4142434445464748))` | instance override, integral | 1162233672 ("narrows32") | 6.3.3 | `comp.xfail:210` is the untyped `code` row (`lower.xfail:36`) |
| G1 | `.../integer_conversion_saturates.va:28,32` | `parameter integer big = 1e300` | parameter default, real past 2^63 | **2147483647** ("saturates at the 32-bit ceiling") | 3.4.1, 4.2.1.1 | agree; `lower.rulings:19` |
| G2 | same `:33-36` | `i_pos = 1.0e300 * V(p, n)`; `i_neg = -1.0e300 * V(p, n)` | run-time store into an `integer` variable | `i_pos > 2147483647` = **1**, `i_neg < -2147483647` = 1 | 4.2.1.1 | agree (both saturate at the i64 slot) |
| H | `verilog-a/ch06_hierarchy/nonfinite_real_to_integer_rejected.va` | `parameter integer overflowed = 1.0 / 0.0` | parameter default, infinity | `reject-only E0368` | 4.2.1.1, 3.2 | agree |
| I | `verilog-a/ch09_system_tasks/rng_paramset_nonfinite_integer_rejected.va` | paramset `.r = $dist_erlang(7, 4097, 3, "global")` into `parameter integer r` | §9.13.2 integer result, non-finite | `reject-only E0816` "cannot be represented" | 9.13.3 | agree |
| J | `verilog-a/ch04_expressions/rtoi_truncates_toward_zero.va:141-146`, `ch09/conversion_truncation_signed.va`, `annex_c/analog_context_system_functions.va:50-51`, `verilog-ams/ch09/ieee_1364_system_functions_in_both_contexts.va:42`, `ch09/conversion_constant_expressions.va:9` | `$rtoi(1.5)` = 1, `$rtoi(-1.5)` = -1, `$rtoi(2.75)` = 2, ... | `$rtoi`, in range | truncation | 9.11, IEEE 17.8 | agree; **none past 2^31** |
| J' | `lib/sim/digital/compile.zig:673` (digital runtime test, VD-130) | `$rtoi((33'b1<<32)+1.0)` = 1; `$rtoi(1.0/0.0)` = x | digital `$rtoi` past 32 bits | low 32 bits; x for non-finite (iverilog gold) | IEEE 17.8 | not a suite fixture |
| K | `verilog-a/ch04_expressions/nonfinite_array_subscript_rejected.va` | `a[1.0/0.0]` constant subscript | subscript | E0310; header: "`a[1e300]` panics identically" | 3.2, 4.2.1.1 | agree |
| L | `verilog-ams/ch11_vpi/get_value_formats.c:56-62` | vpiIntVal of a 64-bit `reg` | VPI, integral | low 32 bits; "A tool that saturated would give 0x7FFFFFFF" (VD-049) | 12.16 | agree |
| N | `ch03/integer_overflow_wrap.va`, `integer_negate_and_abs_wrap_in_a_constant.va`, `ch04/integer_power_is_integer.va:71`, `ch03/integer_parameter_precision_host.va:21-22` | `hi + 1`, `2 ** 31`, `word * word` | integer arithmetic | two's-complement wrap at 32 | 3.2 | agree |
| O | `verilog-ams/annex_a_syntax/specparam_range_and_select.va` (`lower.rulings:13`) | `specparam [3:0] = 21` | ranged specparam | 5, the low 4 bits | IEEE 4.10.3 | ruled |
| P | codegen W7 `string_literal_to_integral` | `integer code = "hello"` | string literal into an integer | low 32 bits (§3.3) | 3.3 | codegen T-list |
| R | `verilog-a/ch06_hierarchy/paramset_outer_defparam_wide_card.va:22-23,38-39` | card `wide = 4294967296` into an **untyped** parameter | untyped | 4294967296.0, no narrowing | 3.4.1 (IEEE 12.2 first bullet) | agree |

Reading the table:

- Seven rows put a real in 2^31..2^63 into an `integer` (A1, A2, A3, B1, B2,
  B3, C1, C2): every one expects the low 32 bits. Eight more do the same with
  an integral value (A3, D, E, F, L, N, O, P): low bits, never a ceiling, and
  L says so against saturation by name.
- Exactly one fixture, G, pins saturation, and only at 1e300 (past 2^63): G1
  for a parameter, G2 for a run-time store. Its header: "The LRM fixes the
  ROUNDING and stays silent on a value no integer width can hold ... VerA's
  defined answer is saturation". It cites §3.4.1 and §4.2.1.1, neither of
  which has the sentence.
- G2 asserts `i_pos > 2147483647` for a variable declared `integer`. §3.2
  gives that type the range -2^31..2^31-1; the comparison is against the
  largest value the type holds, so the row can only pass when the variable
  holds a value outside its type (the i64 slot saturated to 2^63-1, which is
  what both devices do today). Commit a9eb351d (2026-08-12) deleted the same
  assertion from G1 with exactly this argument ("asserted `big > 2147483647`
  for a parameter declared `integer`, which no 32-bit integer satisfies: it
  pinned the defect") and left G2 in place.
- History: 9e8f6984 (2026-01-13) "define real->int overflow" introduced
  saturation and G; the "wraps32" rows of A are in 69e5f376 (2026-01-23),
  ten days later. The two claims have coexisted since, satisfied by the old
  side only because its fold wraps below 2^63 and its codegen saturates above.

---

## 3. The old compiler's rule (the oracle, never edited)

| context | site | round | 2^31..2^63 | past 2^63 | NaN / ±inf |
|---|---|---|---|---|---|
| parameter or localparam default, fold | `lib/frontend/constfold.zig:163-178` `parameterValue`: `.integer` ← real is `asIntExact` (`lib/kernels/fold.zig:92-105`: `@round`, null for non-finite or `|v| >= 2^63`) then `wrap32` (`:197-202`); null keeps the **real** in the row | nearest, ties away | **low 32 bits** (A, B) | the row stays `1e300` real (the `-param big integer = 1e300` of `lower.rulings:19`) | E0368 at `src/analog/param.zig:189-192` |
| the Model field's default, codegen | `src/codegen/device/codegen/model.zig:266-274` `paramDefault`: folded `.int` → `wrap32`; folded `.real` (only the leftovers above) → `std.math.lossyCast(i32, @round(v))`; an unfolded default `:296-302` → `lossyCast(i64, …)` ("§4.2.1.1 fixes no overflow rule. Upgrade path: a lowering-time diagnostic") | | low 32 | **saturate i32** (G1 = 2147483647) | |
| `--param` card (old driver) | `lib/frontend/constfold.zig:182-187` `parameterCardValue` → `parameterValue` | | low 32 | real kept | |
| host card (ABI i64 carrier) | `docs/host/device.md:49-50`; `model.zig:202-211` `derive` does `model.x = @as(i32, @truncate(model.x))` for every non-local explicit integer (a9eb351d) | n/a | low 32 (D) | low 32 | n/a |
| §6.3.4 derived integer row, run time | `model.zig:242-245`: `model.x = @as(i32, @truncate(e))` with `e` = `std.math.lossyCast(i64, @round(…))` (`host_expr.zig:181`, `:190-192`) | nearest | low 32 (C1 = 7) | `wrap32(maxInt(i64))` = **-1** (disagrees with the default's 2147483647) | NaN → 0; inf → -1 / 0 |
| run-time store into an `integer` variable, array element, function value or argument | `src/analog/coerce.zig:65-76` `toInt` → `fi_cast`; `render_op.zig:227-235` → `zRoundI` = `std.math.lossyCast(i64, @round(a.val()))` (`kernel_text/math.zig:46-49`); the slot is i64 and nothing narrows it; only arithmetic wraps (`render_op.zig:553` `intBin32`) | nearest | **kept whole** (4294967297 stays 4294967297) | **saturate i64** (G2) | NaN → 0, ±inf → ±2^63 |
| MIR constant fold of `fi_cast` | `src/ir/opcode.zig:425-440`: `lossyCast(i64, @round)`; `wrapped` wraps only a wrapping op's result (tests `:556-557`: NaN → 0, inf → maxInt(i64)) | nearest | kept whole | saturate i64 | NaN 0, inf 2^63-1 |
| `$rtoi` | fold `src/analog/constfold.zig:86-92`: `@trunc`, declined outside i32 or non-finite ("a run-time question"); run time `src/codegen/device/codegen/call.zig:518-525`: `lossyCast(i64, @trunc(…))` | toward zero | kept whole | saturate i64 | NaN 0 |
| `$dist_*` into an integer, paramset | `src/elab/paramset_dist.zig:108-120`: E0816 when non-finite or outside i32; else `@intFromFloat(@round(v))` | nearest | **E0816** | E0816 | E0816 |
| subscript | `src/analog/assign.zig:156` `toInt` (`fi_cast`), then the run-time range check | nearest | out of range → the §5.7 default (`invalid_index_read_value.va`) | same | NaN → index 0 |

So the old side has three rules at once: low 32 bits (fold, card, derive
below 2^63), saturate i32 (a default past 2^63), saturate i64 (every run-time
store, derive past 2^63 after the wrap). The lead's guess is row 1 composed
with row 2, the old side's parameter-default behaviour, which is why it fits
A, B, C, D and G1: those fixtures were written against it.

---

## 4. The new compiler's rule

| context | site | round | 2^31..2^63 | past 2^63 | NaN / ±inf |
|---|---|---|---|---|---|
| parameter reference or default, fold | `src/Sema/eval.zig:418-433` `Env.coerce`: `.integer` → `wrap32(toInteger(c))`; `toInteger` `:456-472`: `@round`, `>= 2147483648.0` → `maxInt(i32)`, `<= -2147483649.0` → `minInt(i32)`; non-finite → null; `.int` → `wrap32` | nearest | **saturate i32** (A1 = 2147483647) | saturate i32 (G1) | null → E0368 at `src/Sema/param.zig:88-95` `checkType` |
| array-parameter element | `src/Sema/param.zig:216-227` `asType`: `eval.toInteger(c) orelse 0` | nearest | saturate i32 | saturate i32 | **0, silently** (H has no array twin) |
| block- or function-scoped parameter | `src/Sema/variable.zig:144-156` `localParam`: `.integer, .time => asIntExact() orelse return` | nearest | **kept whole**, no wrap | **no binding** (the read refuses) | no binding |
| Air constant fold of `fi_cast`, and a real operand of an integer op | `src/Sema/fold.zig:130` `.to_int`, `:155-162` `as`: `lossyCast(i64, @round)` | nearest | kept whole | saturate i64 | NaN 0, inf ±2^63 |
| interpreter (diff-lower values, derive folds) | `src/Air/interp.zig:501-508` `roundToInt`: saturate i64, NaN 0 | nearest | kept whole | saturate i64 | NaN 0 |
| interval (the W0650 judge) | `src/Air/Interval.zig:426` `.fi_cast => .{ .lo = roundInt(x.lo), .hi = roundInt(x.hi) }`; `:665-669` through `interp` | | the interval is kept whole (correct only while the store does not wrap) | | |
| run-time store (variable, element, function value and argument, return) | `src/Sema/expr.zig:71-80` `coerce` → `fi_cast`; `src/codegen/zig/Function.zig:615-619` → `M.zRoundI`; `lib/std/kernels/math.zig:220-223`: `lossyCast(i64, @round(a.val()))`; the batch family's hook `lib/std/sim/bench/batch.zig:96-100` `decideI` is the same cast per lane | nearest | kept whole | saturate i64 (G2) | NaN 0, ±inf ±2^63 |
| host card | `src/codegen/zig/DeclGen.zig:320-330` `genDerive`: `model.x = @as(i32, @truncate(model.x))` for every row whose folded default is `.int` | n/a | low 32 (D) | low 32 | n/a |
| §6.3.4 derived integer row, run time | `DeclGen.zig:331-336`: `model.x = <valueOf(der)>`, the tree's `fi_cast` → `zRoundI`; **no narrowing after it** (the old `model.zig:243` has one) | nearest | **kept whole** (C1 would read 4294967303, not 7, once the file builds) | saturate i64 | NaN 0 |
| a slot's initializer from a folded real | `src/codegen/zig/state.zig:205`: `@intFromFloat(@round(x))`, unguarded | nearest | kept whole | **UB / panic** | panic |
| `$rtoi` | fold `src/Sema/eval_fn.zig:42-52`: `@trunc`, declined outside i32 or non-finite; run time `src/codegen/zig/calls.zig:155-160`: `lossyCast(i64, @trunc(…))` | toward zero | kept whole | saturate i64 | NaN 0 |
| `$dist_*` into an integer | `src/Sema/dist.zig:133-139`: E0816 outside i32 or non-finite | nearest | E0816 | E0816 | E0816 |
| `time` storage | `eval.zig:433` `.time => toInteger(c)` | nearest | **saturate i32** for a 64-bit type (IEEE §4.8) | | null |
| 1364 constant evaluator (digital) | `src/Sema/eval_1364.zig:137-140` `ctx`: `asIntExact() orelse @intFromFloat(@round(c.asReal()))`, so the `orelse` arm runs exactly when the cast is illegal; `:556-559` `int` declines past 9.2e18; `src/Sema/digital.zig:593`: `isFinite` guard only | nearest | low 64, then `fit` | **panic** at `:139`, `:593` | panic at `:139` |
| digital runtime store into a `to`-bit integral | `lib/sim/rt/logic/reals.zig:96-134` `ofReal` (64 bits: x past 2^63), `ofRealTo(r, to)`: `@round`, then **mod 2^to at any magnitude** (an f64 past 2^63 is its 53-bit significand shifted; the words are built from `frexp`), x for non-finite; `:139-141` `rtoi`: `ofRealTo(@trunc(r), 32)` (VD-130, iverilog gold) | nearest | low `to` bits | low `to` bits | x |

So the new side has, for a parameter, the opposite rule of A/B/C's seven
rows (saturate where they wrap), and for a run-time store the old side's i64
rule; the derive path lost the old narrowing; two sites crash past 2^63; and
the digital runtime already has the uniform rule this plan recommends.

---

## 5. Other tools

**OpenVAF-Reloaded** (`tests/conformance/external/OpenVAF-Reloaded/openvaf/`).
Integers are `i32` throughout (MIR `iconst`/`i32`, OSDI `PARA_TY_INT`,
`osdi/src/metadata.rs:130`). Three conversions, three answers:
- constant folding, `mir_opt/src/const_eval.rs:89`: `FIcast => iconst(val.round() as i32)`. Rust's float-to-int `as` saturates and maps NaN to 0 (Rust reference, numeric cast semantics, since 1.45): 4294967297.0 → 2147483647.
- the MIR interpreter, `mir_interpret/src/lib.rs:146`: `FIcast => (args(0).f64() as i32)` with no `.round()` (truncation, saturating).
- compiled code, `mir_llvm/src/builder.rs:913`: `FIcast => llvm.lround.i32.f64`. LLVM LangRef, `llvm.lround.*`, Semantics: the libm `lround` value "without setting errno. If the rounded value is too large to fit the return type, the return value is a non-deterministic value (equivalent to freeze poison)" (LangRef text, not in this repo). On x86-64/glibc this lowers to the `lround` libcall (`long`, 64 bits) truncated to i32: 4294967297.0 → **1** (wrap); past 2^63 glibc returns `LONG_MIN`, so 0.
- `$rtoi` is a separate opcode `FItrunc` (`hir_lower/src/expr.rs:549`, `builder.rs:745-747` `FPToSI`): C semantics, UB past i32.
So OpenVAF wraps in the only path a simulation runs, and no OpenVAF path can produce 2^63-1 in an `integer` (G2's rows are false there).

**ngspice** (`tests/conformance/external/ngspice/src/`). An OSDI integer
parameter is a C `int` (`osdi/osdiparam.c:35-36`). A card value becomes one
at `spicelib/parser/inpgval.c:29-31`: `temp.iValue = (int) floor(0.5 + tmp)`:
rounded half **up** (not away from zero: -3.5 gives -3), then the C cast.

**C** (the behaviour "rounding" implies for a C-compiled model; C11 text,
not in this repo). 6.3.1.4p1: a float-to-integer conversion truncates, and
"If the value of the integral part cannot be represented by the integer type,
the behavior is undefined." 7.12.9.7p3 (`lround`): "If the rounded value is
outside the range of the return type, the numeric result is unspecified and a
domain error or range error may occur." No C path saturates; on x86-64 the
`cvttsd2si` instruction gives 0x80000000 for every out-of-range or NaN input.

**iverilog**, through VD-130 (`docs/specification/Vague_Decisions.md:1465-1473`):
`$rtoi` keeps "the low 32 bits of a larger truncated value, x only for an
infinity or a NaN"; gold `itor_rtoi`. VD-049 (`:659-665`): vpiIntVal of a
wider object is "the low 32 bits, two's complement ... IEEE 5.6, where
truncation of the high bits happens without a diagnostic"; option (c)
"saturate" was considered and rejected. VD-124 (`:167`): every analog integer
expression is 32 bits "by one rule".

**gnucap-modelgen-verilog, VA-Models, Xyce_Regression**: no real-to-integer
conversion site found (`VA-Models` has no `parameter integer` with a real
default). No evidence either way.

---

## 6. Does one rule satisfy every fixture?

Three candidate rules, graded against §2:

| rule | A1-A3, B, C1, C2 (real, 2^31..2^63 → low 32) | D, E, F, L, N, O, P (integral → low 32) | G1 (1e300 → 2147483647) | G2 (`i_pos > 2147483647` = 1) | H, I, K (non-finite refused) |
|---|---|---|---|---|---|
| **S** saturate at ±2^31 everywhere (T10's `toInteger`) | **fails** 7 rows (gives 2147483647) | fails D, E, F (and VD-049/130 reject it) | passes | fails (no 32-bit value exceeds 2^31-1) | passes |
| **L** the lead's: wrap when the rounded value fits i64, saturate at ±2^31 past it | passes | passes | passes | **fails**: 2147483647 > 2147483647 is 0; passes only if a store keeps the i64 carrier and saturates there, which is a fourth rule and §3.2-breaking | passes |
| **W** low 32 bits of the rounded integer at any magnitude (two's complement; `ofRealTo(r, 32)`) | passes | passes | **fails**: 1e300 is a multiple of 2^32, so 0 | fails (same as L) | passes |

- No rule passes G2 while honouring §3.2. G2 must change under every rule,
  including the lead's. Its pair of rows pins the i64 slot, which the
  fixture's own text calls "the defect of reading the raw 64-bit carrier"
  for G1.
- L passes every remaining row as written, because L *is* the old side's
  parameter-default behaviour (§3). It is not an LRM reading: 2^63 is the
  fold's carrier, not a language constant; the answer is discontinuous at it
  (the largest double below 2^63, 2^63-2048, wraps to -2048; 2^63+2048
  saturates to 2147483647); the old side's own derive path gives -1 there;
  and no other tool has the composition.
- W is one rule, the digital runtime's already (`ofRealTo`), OpenVAF's
  compiled rule below 2^63, VD-049's and VD-130's rule for integral values,
  and §5.6/§12.2's rule for a value wider than its destination. It costs G1
  (one row) and `lower.rulings:19` (one line, same shape, new number).
- Which does the LRM support? Neither rule has a sentence. W follows from
  sentences the texts do have (the type is modular, a wider value is
  truncated into it); L and S need one they lack. The honest statement for
  the ruling and the fixture: "the LRM is silent past the type's range;
  VerA's defined answer is §3.2's low 32 bits".

Conflicts, then: only G against everything else, and G2 against §3.2 itself.

---

## 7. The recommended rule

`convert(r)` for a real `r` whose destination is a VerA `integer` (32 bits,
§3.2; VD-124's "one rule" for every analog integer expression):

| case | value | why |
|---|---|---|
| in range, fractional | nearest integer, 0.5 away from zero: 3.5 → 4, -3.5 → -4, 35.5 → 36 | §4.2.1.1, IEEE §4.8.2 |
| 2^31 ≤ \|round(r)\| < 2^63 | the low 32 bits, two's complement: 4294967297.0 → 1, 4294967295.0 → -1, 2147483648.0 → -2147483648 | §3.2 two's complement; IEEE §5.6, §12.2; VD-049, VD-130; fixtures A, B, C |
| \|round(r)\| ≥ 2^63 | the same, `round(r) mod 2^32` computed in f64 (exact: `@rem(n, 4294967296.0)`): 2^63+2048 → 2048, -(2^63+2048) → -2048, every \|r\| ≥ 2^84 → 0 (its significand is above bit 32), so 1e300 → 0 | one rule; `lib/sim/rt/logic/reals.zig:105-134` is the reference implementation |
| NaN, ±inf, in a constant (parameter, localparam, array element, subscript) | a diagnostic: E0368 (parameter), E0310 (subscript), E0816 (`$dist_*`), as today; **also** for an array-parameter element (today silently 0) and a block-scoped parameter (today silently unbound) | §4.2.1.1 "nearest integer": none exists; H, I, K |
| NaN, ±inf, at run time | 0 | the analog context has no x (VD-116, `Vague_Decisions.md:1332`: what IEEE gives x "give 0"); `ofRealTo` gives x, `$itor(inf)` is 0 (VD-130); today NaN is 0 and ±inf is ±2^63, which no `integer` holds |
| ties | away from zero (`@round`) | §4.2.1.1; A4 |

Contexts, all the same `convert`:

| context | note |
|---|---|
| parameter default, localparam (module, block, function), instance override, defparam, paramset statement | fold through `convert`; the card's integral i64 keeps `wrap32` (D) |
| array-parameter element | same; non-finite → E0368 on the element (new) |
| §6.3.4 derived row at run time | the derive tree's `fi_cast` is `convert`; and the row is narrowed after the store as the old `model.zig:243` does, so an integral copy (`narrowed = code`, F) narrows too |
| variable, array element, function return and argument, output argument | the store's `fi_cast` is `convert`; the i64 slot then always holds a 32-bit value, which is what §3.2 says it holds |
| subscript, repeat count, replication factor, shift count | `fi_cast` too (they already pass through 32-bit integer arithmetic on the new side: `src/Sema/array.zig:95-97` subtracts the bound with `isub`, which wraps), so only ≥ 2^63 changes: `a[1e300]` becomes index 0 instead of -1 (Q3) |
| `$rtoi` | truncate toward zero, then the low 32 bits (its result type is `integer`, IEEE §17.8; VD-130 in the digital context; §9.11 extends the same function to the analog context): `$rtoi(4294967297.0)` = 1, folded or not; NaN/inf → 0 (digital: x) (Q4) |
| `$dist_*` integer results | unchanged: E0816 for non-finite and for a finite value outside i32 (a constant that overflows is refused, which is stricter than wrapping and already pinned by I) (Q5) |
| digital context (a `reg`, `integer` or `time` assigned a real; `$rtoi`) | unchanged: `ofRealTo`, `ofReal`, `rtoi` already implement W; the 1364 constant evaluator's two crash sites get the same rule (task C7) |
| `time` | 64 bits (IEEE §4.8): `asIntExact`, not `toInteger` (`eval.zig:433`), (Q6) |
| VPI vpiIntVal | unchanged (VD-049) |
| ports | not a conversion: a discrete port read in the analog context is an integer already (§7.3.1); a real driven into a digital `integer` goes through a connect module's digital assignment, `ofRealTo` |

The helper (one function, `lib/std/kernels/fold.zig` beside `wrap32`, used
by every site in §8; shape only, the implementer writes it):

```zig
/// §4.2.1.1 then §3.2: `r` rounded to nearest (ties away from zero) and
/// reduced to its low 32 bits, two's complement, at any magnitude. Null for
/// a NaN or an infinity, which round to no integer.
pub fn realToInt32(r: f64) ?i32 {
    const n = @round(r);
    if (!std.math.isFinite(n)) return null;
    // Every integer-valued double below 2^63 fits i64; past it the residue
    // mod 2^32 is exact in f64 (`@rem` of two integers is exact).
    if (n >= -0x1p63 and n < 0x1p63) return @truncate(@as(i64, @intFromFloat(n)));
    return @truncate(@as(i64, @intFromFloat(@rem(n, 4294967296.0))));
}
```

The hot path is the first branch (two compares, one `cvttsd2si`, one
truncation): no more than today's `lossyCast`. The second branch is cold;
it is what makes the rule total. Oracles for the helper itself, in
`lib/std/kernels/fold.zig`'s tests and `tests/unit/kernel_tests.zig`:

1. **Reference implementation** (independent code path): for every finite
   `r` in a table and a seeded sweep, `realToInt32(r)` equals
   `lib/sim/rt/logic/reals.zig` `ofRealTo(r, 32)` read as i32 (that one is
   built from `frexp` and word shifts, never `@rem`).
2. **Certificate**: `@rem(@round(r) - @as(f64, @floatFromInt(realToInt32(r).?)), 4294967296.0) == 0`
   for every finite `r` (both terms are integers; `@rem` is exact).
3. **Metamorphic**: `realToInt32(r) == realToInt32(r + k * 4294967296.0)`
   whenever both sums are exact in f64.
4. The table: 0.5 → 1, -0.5 → -1, 3.5 → 4, -3.5 → -4, 2147483647.0 →
   2147483647, 2147483648.0 → -2147483648, 4294967297.0 → 1, 4294967295.0 →
   -1, 4294967303.0 → 7, 9223372036854773760.0 (2^63-2048) → -2048,
   9223372036854777856.0 (2^63+2048) → 2048, -9223372036854777856.0 →
   -2048, 1e300 → 0, -1e300 → 0, NaN → null, ±inf → null.

---

## 8. The sites that change, with each one's oracle

Red first: every oracle below is red on `refactor` today except where marked
"green today (regression guard)". Old side untouched. One implementer for
C1-C4 (the files are T39's: `src/Sema/eval.zig`, `param.zig`, `variable.zig`,
`fold.zig`, `src/Air/interp.zig`, `Interval.zig`, `src/codegen/zig/*`,
`lib/std/kernels/*`); C5 is the lead with the fixture batch; C6 and C7 are
small separate tasks.

**C1. The helper.** `lib/std/kernels/fold.zig`: `realToInt32` (§7) and its
four oracles. Also `realTruncInt32` for `$rtoi` (`@trunc` instead of `@round`,
same tail) if Q4 is accepted. Green: `test-kernels`.

**C2. Sema fold.**
- `src/Sema/eval.zig:461-472` `toInteger`: `realToInt32` (as `?i64`); keep
  `.int => wrap32` in `coerce` `:432`; `:433` `.time` → `asIntExact` (Q6).
- `src/Sema/param.zig:216-227` `asType`: `realToInt32`; a null element →
  E0368 on the element (new row for H's array twin, Q7).
- `src/Sema/variable.zig:152`: `.integer => realToInt32`, `.time => asIntExact`;
  a null → E0368 (today: no binding).
- `src/Sema/fold.zig:130` `.to_int` and `:159` `as`: `realToInt32`.
- `src/Sema/param_test.zig:89-98` ("saturates at the 32-bit ceiling"): flip
  to the §7 table (1e300 → 0, -1e300 → 0) and add rows 4294967297.0 → 1,
  2^63+2048 → 2048; it is red before C2.
Oracles: A1-A3, B1-B3 CHECKIs through diff-comp (`comp.xfail:208`, `:211`
go; `:211`'s exit 1 may have a second cause, T38); diff-lower (`lower.xfail:37-38`
go); H stays E0368 (green today, regression guard); `tools/build-slot.sh … diff-comp -Dcomp-filter='integer_parameter_precision|integer_conversion|nonfinite_real_to_integer'`.

**C3. Air.**
- `src/Air/interp.zig:501-508` `roundToInt`: `realToInt32(x) orelse 0`.
- `src/Air/Interval.zig:426`: `.fi_cast` gives `[roundInt(lo), roundInt(hi)]`
  only while the operand interval lies inside `i32_range` (both bounds after
  rounding); otherwise `i32_range`, exactly as `wrap32` at `:659-663` does
  for the arithmetic ops. `:665-669` `roundInt` follows the interpreter.
- `src/Air/Float/Walk.zig:309` reads `Interval.integer(.fi_cast, …)`: no
  edit, verify.
Oracles: `interp.zig`'s own tests (add the §7 table); diff-float / W0650 over
the corpus unchanged (`air_passes.xfail` and `float.xfail` by name; a widened
integer interval is still finite, so no verdict should move; if one does, it
is listed and plan-airpasses is told).

**C4. Codegen and the runtime.**
- `lib/std/kernels/math.zig:220-223` `zRoundI`: `realToInt32(a.val()) orelse 0`
  widened to i64; `lib/std/sim/bench/batch.zig:96-100` `decideI`: the same
  per lane (the family hook must agree with the scalar, or the bench's
  batched device answers differently from the one-point device).
- `src/codegen/zig/DeclGen.zig:331-336` `genDerive`: after `model.x = …` of
  a derived row whose `ty == .integer`, `model.x = @as(i32, @truncate(model.x))`
  (the old `model.zig:243`), so an integral copy narrows too (F).
- `src/codegen/zig/state.zig:205`: `realToInt32(x) orelse 0` (today UB past 2^63).
- `src/codegen/zig/calls.zig:155-160` `$rtoi`: Q4.
- `tests/codegen_probe.zig`: an `expect:` line for the `fi_cast` kernel
  (`tools/asm_probe.py`): EQUIVALENT to today's `lossyCast` on the hot path
  (two compares and a `cvttsd2si`, the `@rem` only in the cold branch).
Oracles: C1-C3 CHECKIs (`comp.xfail:212`; C2's `aa` rows also need T38);
`tests/host/integer_param_host.zig` (green today, regression guard);
diff-codegen bit for bit on A, B, C, D (`tools/build-slot.sh … diff-codegen -Dcodegen-filter='integer_parameter_precision|integer_param_low32|integer_conversion'`);
`bench-fast` unchanged for a device with no `fi_cast`.

**C5. The fixture and the lists (lead; the submodule is pushed by the user,
`research/README.md` "Waiting on the user").**
- `tests/conformance/tests/verilog-a/ch03_data_types/integer_conversion_saturates.va`,
  under W: rename to `integer_conversion_low32.va` (name lists compare names:
  `lower.rulings:19` is the only list line naming it); header rewritten to
  §1.3's statement; rows: `parameter integer big = 1e300` → 0 ("every double
  of magnitude 2^84 or more is a multiple of 2^32"); `parameter integer
  high = 9223372036854777856.0` → 2048 (a value past the i64 carrier whose
  low 32 bits are not zero, so a saturating or i64-wrapping compiler fails
  it); `i_pos = 9223372036854777856.0 * V(p, n)` → `i_pos == 2048`;
  `i_neg = -9223372036854777856.0 * V(p, n)` → `i_neg == -2048`; keep the
  `* V(p, n)` so the run-time cast stays out of every fold.
  Under L: only G2 changes (`i_pos == 2147483647`, `i_neg == -2147483648`),
  and the name stays.
- Both sides fail the rewritten run-time rows (the old device saturates at
  i64), and under W the old side fails `big` and `high` too: one
  `comp.rulings` line ("§3.2/§4.2.1.1: the old side stores a value no
  `integer` holds; VerA's defined answer past the type's range is its low 32
  bits") and one `tools/vera.xfail` line until the switch-over (the
  conformance step runs the old `vera`).
- `lower.rulings:19`: §9.
- `comp.xfail:208, 211, 212` and `lower.xfail:37, 38` are deleted by the
  rebaseline after C2-C4, by name, not by count.

**C6. `$rtoi` past 32 bits (Q4).** `src/Sema/eval_fn.zig:49-51`: fold every
finite argument through `realTruncInt32` (today declined outside i32);
`src/codegen/zig/calls.zig:155-160`: the same kernel. New fixture
`verilog-a/ch09_system_tasks/rtoi_past_32_bits.va`, the analog twin of
`lib/sim/digital/compile.zig:673`: `$rtoi(4294967297.0)` = 1 in a localparam
and over `V(p, n)` at run time; `//! lrm 9.11`; cites VD-130. Red on both
sides (both give 4294967297 at run time; the old fold declines), so a
`comp.rulings` line (IEEE §17.8's prototype `integer $rtoi(real_val)`; VD-130).

**C7. The 1364 evaluator's crashes (plan-dlower's files; a one-line task
each).** `src/Sema/eval_1364.zig:139`: when `asIntExact` is null, the value is
`ofReal`'s x (past 2^63 or non-finite), so `fit(unknown 64-bit, t)`, never
`@intFromFloat`; `src/Sema/digital.zig:593`: `realToInt32(v) orelse refuse`.
Oracle: a `.v` fixture `localparam integer p = 1e300; initial $display("%0d", p);`
with iverilog as gold (x or 0 per its output; verified by the conformance
run, not guessed here); today the compiler panics, which is the red.

Order: C1 → C2 → C3 → C4 in one worktree (they share `realToInt32` and the
same fixtures' CHECKs); C5 after the gate is green with the lists rebaselined;
C6, C7 any time after C1.

---

## 9. `lower.rulings` line 19

Today: `integer_conversion_saturates.va | 4.2.1.1 | new | -param big integer = 1e300; +param big integer = 2147483647 | … VerA's defined answer is saturation (T10 I3/I4's eval.toInteger) …`.

Under W it does not hold as written: the new side's value becomes 0 and the
reason names a rule that no longer exists. It is rewritten, same shape:
`verilog-a/ch03_data_types/integer_conversion_low32.va | 3.2 | new | -param big integer = 1e300; -param high integer = 9.223372036854778e18; +param big integer = 0; +param high integer = 2048 | §4.2.1.1 rounds and §3.2 makes the type 32-bit two's complement ("2's complement results"; IEEE 1364-2005 §5.6 discards the MSBs of a wider value): the LRM is silent past the type's range, and VerA's defined answer is the rounded value's low 32 bits (lib/std/kernels/fold.zig realToInt32), never the old side's unrounded, unconverted real in an integer row` (the exact old-side spelling of `high` is read from the run, as the current line's was).

Under L it holds as written (the new value stays 2147483647), and only its
reason should drop "(T10 I3/I4's `eval.toInteger`)" for the new helper's
name. Either way the ruling still settles something (the old row is an
unconverted real), so it passes `settle.Rulings`'s "settles nothing" check.

---

## 10. Departures and risks

- **From Zig.** Zig's `@intFromFloat` is illegal behaviour out of range and
  `std.math.lossyCast` saturates; neither is a language rule here. The
  precedent for a modular conversion in this tree is the digital runtime's
  `ofRealTo`, not Zig.
- **Risk: a model that relied on i64 saturation.** None in the suite besides
  G2; `VA-Models` has no real default on an `integer` parameter. A compact
  model that stores `1e10` in an `integer` gets 1410065408 under W (and under
  L) where ngspice's own card path gives C's unspecified value: no tool agrees
  with any other past 2^31, so the only promise VerA can make is one rule,
  stated.
- **Risk: `a[1e300]`.** Q3.
- **Risk: W0650 verdicts.** C3 widens an integer interval to `i32_range`
  where it used to be a wrong narrow interval; an integer interval is finite
  either way, so no finiteness proof should move. Listed by name if one does.
- **Cost of W over L.** One fixture rewritten and renamed, one ruling line
  rewritten, one `comp.rulings` line and one `tools/vera.xfail` line until
  the switch-over. Cost of L over W: a language-visible 2^63 seam, G2's
  §3.2-breaking rows still needing a rewrite, and `derive`, `fi_cast`,
  `Interval` and the digital runtime each needing their own copy of the seam.

---

## Open questions

**Q1. Which rule: W (low 32 bits at any magnitude), L (wrap below 2^63,
saturate at ±2^31 past it), or S (saturate everywhere)?**
S fails seven fixture rows and VD-049/VD-130 and is out. L fits every row
but G2 because it is the old side's parameter-default accident (§3, §6), has
no text, and is discontinuous at an implementation constant. W is one rule,
has §3.2/§5.6/§12.2 and three VerA decisions behind it, matches the digital
runtime and OpenVAF's compiled code, and costs one fixture and one ruling
line.
Recommendation: W.
Decision: W (user, 2026-11-11): round to nearest, ties away, then the low 32 bits two's complement at any magnitude, in every fold, parameter, derive and run-time site.

**Q2. The non-finite run-time value: 0 (W, this plan), or keep `lossyCast`'s
±2^63 for an infinity (then wrapped to -1 / 0 by any later arithmetic)?**
Recommendation: 0, for both NaN and ±inf: it is the analog context's "x reads
as 0" (VD-116, `Vague_Decisions.md:1332`), VD-130's `$itor(inf)` = 0, and what
OpenVAF's compiled `lround` gives on x86-64/glibc; a constant stays a
diagnostic (E0368/E0310/E0816).
Decision: 0 for NaN and ±inf at run time; a constant stays a diagnostic (E0368/E0310/E0816).

**Q3. A subscript, count or replication factor past 2^63: `fi_cast` as W
(then `a[1e300]` is index 0, an aliasing read) or keep i64 saturation for
those uses only (then `a[1e300]` is out of range and reads the §5.7 default)?**
On the new side the subscript already passes through 32-bit `isub`/`imul`
(`src/Sema/array.zig:95-97`), so 2^31..2^63 wraps today; only ≥ 2^63 is at
stake, and `nonfinite_array_subscript_rejected.va` pins the constant case as
E0310 under either answer. Keeping two `fi_cast` flavours is a seam with one
client.
Recommendation: W everywhere; note the `a[1e300]` consequence in the helper's
doc comment. If the lead wants the range check to catch it, the cheaper fix
is in the index arithmetic (compute the offset in i64 and range-check before
narrowing), not a second conversion.
Decision: W everywhere, with the `a[1e300]` consequence in the helper's doc comment; no second conversion flavour.

**Q4. `$rtoi` past 32 bits in the analog context: VD-130's low 32 bits (C6),
or leave both sides' i64 saturation (no fixture distinguishes them today)?**
IEEE §17.8's prototype returns `integer`; §9.11 says the analog `$rtoi` is
the IEEE function; VD-130 already decided the digital one with iverilog's
gold. Leaving it is a second rule for one function.
Recommendation: C6, with its fixture and `comp.rulings` line.
Decision: C6: analog `$rtoi` takes VD-130's low 32 bits, with its fixture and comp.rulings line.

**Q5. `$dist_*` into an integer: keep E0816 for a finite result outside
i32 (`src/Sema/dist.zig:135`, a refusal where W would wrap)?**
It is a constant that provably overflows; refusing is a diagnostic the LRM
permits and I pins the non-finite half. Wrapping it would make
`$dist_uniform(seed, 0, 3000000000)` fold to a negative number silently.
Recommendation: keep.
Decision: Keep E0816.

**Q6. `time` (`eval.zig:433`): 64 bits through `asIntExact` (declines past
i64) instead of `toInteger`'s 32-bit saturation?**
IEEE §4.8: "at least 64 bits". No analog fixture has a `time` parameter; the
digital side has its own evaluator.
Recommendation: yes, one line in C2.
Decision: Yes: `time` goes through `asIntExact` (64 bits), one line in C2.

**Q7. Add a `W`-class warning for a *constant* real whose rounded value does
not fit `integer` (A1's `4294967297.0` would warn "keeps its low 32 bits,
1")?**
The main bug class is a wrong number with no crash, and every such constant
is one the author did not mean. The old side's `model.zig:300-301` named
this upgrade path. Cost: a new code under plan-diagcodes' keys; fixtures A,
B, C would carry the warning (their harness verdict is the CHECK transcript,
so a warning on stderr needs checking against the conform harness's
clean-stderr rule before it lands).
Recommendation: yes, after C5, as a diagcodes task (`warn-` key under
§4.2.1.1), not inside T39.
Decision: Yes, after C5, as a diagcodes task (`warn-` key under §4.2.1.1), checked against the conform harness's clean-stderr rule first; not inside T39.

**Q8. Fixture name under W: keep `integer_conversion_saturates.va` (its
only list line is `lower.rulings:19`) or rename to
`integer_conversion_low32.va`?**
A fixture named "saturates" asserting the low 32 bits is a trap for the next
reader; the rename touches one ruling line and the new `comp.rulings` and
`tools/vera.xfail` lines, all written in C5 anyway.
Recommendation: rename.
Decision: Rename to `integer_conversion_low32.va` (user approved with Q1); the suite change goes with the other pending submodule changes for the user's push.
