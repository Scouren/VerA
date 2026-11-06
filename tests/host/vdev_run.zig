//! Any `.v` contract device (`vera-next --emit-zig design.v`), run the way
//! a transient host runs it with every pin at 0 V: born, then stepped to
//! each `pendingBreakpoint` and committed, until it stops or has no event
//! left. The device's transcript reaches stderr as each step is committed;
//! for a design with no pins it is the design's own run, so diff-digital-
//! device's tiebreak compares it with `vera-next --run`'s stdout.
//! Cites: VAMS §7.3.6 (the synchronization a host performs).
//!
//! Contents: `pub fn main() u8`.

const std = @import("std");
const device = @import("device");

/// Steps before the run is cut: a design that never stops is no tiebreak.
const steps_max: u32 = 1 << 20;

/// Runs the device; 0 when it stopped or ran out of events, 1 when it was
/// cut at `steps_max`.
pub fn main() u8 {
    const m: device.Model = .{};
    var inst: device.Instance = .{};
    var st = device.initState(&m, &inst);
    const x: [device.num_ports]f64 = @splat(0);
    var t: f64 = 0;
    for (0..steps_max) |_| {
        if (inst.stopped) return 0;
        t = device.pendingBreakpoint(&inst, t) orelse return 0;
        _ = device.updateState(void, &m, &inst, x, &st, .{ .kind = .tran, .t = t });
        _ = device.stateCtl(&m, &inst, &st, .commit);
    }
    return 1;
}
