//! The digital runtime (docs/rewrite/sim.md): one fixed `Program` table in,
//! an IEEE 1364-2005 run of it out. `vera --run`'s interpreter, the
//! per-process fallback of a native executable, and the digital half of a
//! mixed run all read the same table. Imports `kernels` (four-state values,
//! §17 text) and `contract`; never the frontend: the runtime never parses.
//!
//! Contents:
//! - `pub const Program`, `pub const Builder`, `pub const State`, `pub const Interp`
//! - `pub const eval`, `pub const display`, `pub const logic`, `pub const net`, `pub const resolve`, `pub const calls`, `pub const readmem`, `pub const holds`, `pub const files`, `pub const tchk`
//! - `pub const scheduler`, `pub const time`

pub const Program = @import("sim/Program.zig");
pub const Builder = @import("sim/Builder.zig");
pub const State = @import("sim/State.zig");
pub const Interp = @import("sim/Interp.zig");
pub const eval = @import("sim/eval.zig");
pub const display = @import("sim/display.zig");
pub const logic = @import("sim/logic.zig");
pub const net = @import("sim/net.zig");
pub const resolve = @import("sim/resolve.zig");
pub const calls = @import("sim/calls.zig");
pub const readmem = @import("sim/readmem.zig");
pub const holds = @import("sim/holds.zig");
pub const files = @import("sim/files.zig");
pub const tchk = @import("sim/tchk.zig");
pub const scheduler = @import("sim/scheduler.zig");
pub const time = @import("sim/time.zig");

test {
    _ = Program;
    _ = Builder;
    _ = State;
    _ = Interp;
    _ = eval;
    _ = display;
    _ = logic;
    _ = net;
    _ = resolve;
    _ = calls;
    _ = readmem;
    _ = holds;
    _ = files;
    _ = tchk;
    _ = scheduler;
    _ = time;
    _ = @import("sim/test.zig");
}
