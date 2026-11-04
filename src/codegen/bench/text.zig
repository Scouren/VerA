//! The runner's fixed Zig text, embedded from `text/*.zig.txt`: the Newton
//! solver, the differential gates run at every point, the `@Vector(NL, f64)`
//! batch family, the VPI library's exports and the mixed-signal adapter.
//! Nothing here runs in the compiler; every byte is a testbench's source.
//! The pieces are fragments (they reference `D`, `title`, `times`, ...), so
//! they are text files, not Zig files: only a whole rendered runner parses.
//! Cites: §1, §2.8.3, §3.4.1, §3.6.1.2, §4.2.1.1, §4.3.1, §4.5, §4.5.2,
//! §5.3.1, §5.6.1.2, §5.10.5, §7.3, §8.4, §8.5.3.6, §9.4, §12.
//!
//! Contents:
//! - `pub const head: []const u8`: the imports and `n_u`
//! - `pub const body: []const u8`: host answers, the solver and the gates
//! - `pub const big_stack: []const u8`: `main`'s big-stack thread
//! - `pub const mixed_body: []const u8`, `pub const adapter_head: []const u8`, `pub const adapter_tail: []const u8`: the mixed-signal runner

/// The testbench's first lines: its imports and `n_u`.
pub const head = @embedFile("text/head.zig.txt");
/// The directive-independent runner: host answers, the solver and the gates.
pub const body = @embedFile("text/body.zig.txt");
/// The analog and mixed runners' `main` runs `run` on a big-stack thread
/// when the device needs one. Not in `body`: the VPI library has no `main`.
pub const big_stack = @embedFile("text/big_stack.zig.txt");
/// The mixed-signal runner's fixed text: its digital half's names and
/// `runMixed`, then `pwl`. Only this runner imports `std_sim`.
pub const mixed_body = @embedFile("text/mixed_head.zig.txt") ++ @embedFile("text/pwl.zig.txt");
/// `std_sim.mixed.run`'s `A` up to the body of `solveAt`, where the waves go.
pub const adapter_head = @embedFile("text/adapter_head.zig.txt");
/// The rest of `solveAt` and of the adapter.
pub const adapter_tail = @embedFile("text/adapter_tail.zig.txt");
