# sema: digital lowering (Vir -> Program)

Read `README.md` first, then `docs/rewrite/sim.md` (the runtime and its `Program`),
`lib/TODO.md` §8 and Appendix map 6 (A.6: `lib/sim/digital`'s compiler half: bind,
compile, compile_stmt, compile_holds, constness, declared, expr_types, name_search,
system_functions, tchk_build, wait_lists, elab_* ; and `src/codegen/digital`'s
scheduling analyses). You own `src/Sema/digital.zig` + `src/Sema/digital/`,
`tests/differential/dlower.zig`, `tests/differential/dlower.xfail`, and the
`diff-dlower` row in `build/rewrite.zig`. `sema` gains `std_sim` among its imports
(`build/common.zig`: move `sema`'s row below `std_sim` if needed).

## What it is

The digital half of Sema: for an elaborated IEEE 1364 design (`Zcu.instances`
from the merged elaboration; `Config.roots = .all`), every process, continuous
assignment, gate, UDP instance, task, function, specify path and timing check is
lowered from Vir into one `std_sim.Program` through `std_sim.Builder`: slots laid
out, expressions typed and sized by §5.4/§5.5 once (one sizer), names bound to slots
once (no lookup at run time), constants folded by the merged `Sema/eval.zig` (no
second folder), formats parsed once into `fmts`, wait lists and fan-out built. This
replaces the old runtime's compiler (10.3k lines in `lib/sim/digital`) and the
`tests/differential/sim/bridge.zig` stand-in, which already writes every row a real
`Program` needs: read it as the map of what to produce.

Another agent (rw-lower) is writing Sema's ANALOG lowering in `src/Sema/{decl,expr,
control,contrib,syscall,discrete}.zig` right now: stay in `src/Sema/digital*`; edit
`src/Sema.zig` / `src/Zcu.zig` only additively and minimally; share `eval.zig`.

## The oracle: `zig build diff-dlower`

For the 815 fixtures `diff-sim` runs: the old runtime's transcript (as `diff-sim`
captures it: stdout, completion, written files) against `std_sim` running the
`Program` the new Sema writes from source (`vams` Preprocessor + Parse + AstGen +
elaboration + digital lowering). Byte-equal. `dlower.xfail` lists fixtures by path
with a reason. A second check: for each fixture, the new Sema's Program and the
bridge's Program run identical transcripts (the bridge is the intermediate oracle;
delete the bridge only when the first check is green on all 815).

## Done when

`zig build test-sema`, `diff-dlower`, `diff-sim`, `check`, `test-unit` pass; the
report names fixtures compared and every `dlower.xfail` line, and the line count
against map 6's ~5.2k compiler-side target.
