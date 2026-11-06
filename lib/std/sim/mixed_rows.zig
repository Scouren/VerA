//! The VAMS mixed-signal rows of a `Program`, re-exported there: what a
//! mixed host reads beside the rows every digital process runs (the
//! analog events a digital event control waits on, potential probes) and
//! the §9.22 driver access rows connect modules read.
//! Cites: VAMS-2023 §7.3.3, §7.3.5, §7.3.6.3, §9.22, §9.22.5, §9.23.
//!
//! Contents:
//! - `pub const Probe = struct`, `pub const A2d = struct` (`A2d.Kind`)
//! - `pub const DriverAccess = struct` (`DriverAccess.Op`), `pub const DriverUpdate = struct`

const List = @import("Program.zig").List;

/// VAMS §7.3.3 a potential probe's terminals as the source names them
/// (a hierarchical name's parts joined by `.`), in `string_bytes`; `b` is
/// empty for `V(a)`.
pub const Probe = struct { a: List, b: List };

/// VAMS §9.22.3/§9.22.4/§9.23 one driver access call: what it reads, its
/// driver_index row, the net's ordinary drivers (`drivers` rows in
/// §9.22.1's numbering, a `List` in `extra`) and the calling scope's
/// `times` row (`$driver_delay`'s units).
pub const DriverAccess = struct {
    op: Op,
    index: u32,
    drivers: List,
    time: u32,

    pub const Op = enum(u32) { state, strength, delay, next_state, next_strength, type };
};

/// VAMS §9.22.5 one net a `driver_update` term watches: the event slot its
/// waiters wait on, and the slots whose writes update an ordinary driver of
/// it as pairs (slot, 1 for a port window's variable, every assignment of
/// which is an update; 0 for an operand, which updates by changing), a
/// `List` in `extra`.
pub const DriverUpdate = struct { event: u32, sources: List };

/// VAMS §7.3.5 one analog event a digital event control waits on: its
/// arguments as real rows in the LRM's order (a `List` in `extra`, `none`
/// for an omitted one), and the event slot the mixed host triggers at each
/// occurrence.
pub const A2d = struct {
    kind: Kind,
    args: List,
    event: u32,

    pub const Kind = enum(u8) { cross, above, timer, absdelta };
};
