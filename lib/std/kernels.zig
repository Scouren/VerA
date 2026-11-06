//! The `std_kernels` module: the run-time numerics a generated device calls
//! and the compiler folds with, shipped once and imported, as Zig ships
//! `compiler_rt` (lib/TODO.md §7): real, type-checked Zig, one file per data
//! domain, instead of the text the old codegen splices into every device.
//! `fold` calls the same `math` a device runs, so a folded constant is the
//! bits the device computes; `math`'s transcendentals are Gompute's
//! (§11.8), one fma-free body on the host, NVPTX and AMDGCN.
//! Cites: VAMS §2.6.1, §2.7, §2.9, §3.2, §3.3, §4.2, §4.3, §4.5, §4.5.7,
//! §4.5.11, §4.5.12, §4.5.15, §5.10.3.3, §7.3.1, §9.4.1, §9.4.3, §9.5, §9.13,
//! §9.21; IEEE 1364-2005 §5, §17.1, §17.2, §17.9.3.
//!
//! The rules every file keeps, because a device compiles them for NVPTX and
//! AMDGCN too: no libm call (`math` instead), no `@mulAdd` in a value a fold
//! must reproduce, and state only in what the caller passes (an `Instance`
//! field), except `str`'s per-site rows and `file`'s allocator. The names a
//! device calls keep the old text's `z` + uppercase spelling, so codegen's
//! call sites do not change with the switch-over.
//!
//! Contents:
//! - `pub const math`, `family`, `ac`, `storage`, `ops`, `limit`, `filter`, `table`, `rng`, `wide`, `str`, `printf`, `file`: what a device calls
//! - `pub const Integer`, `fmt`, `fold`: what the compiler and the digital engine call
//! - `pub const Options = math.Options`
//! - `pub const Family = family.Family`
//! - `pub const fopen_types: std.StaticStringMap(void)`

const std = @import("std");

/// §4.3 Tables 4-14/4-15: the `f64` transcendentals (Gompute's) and their
/// value form over a family.
pub const math = @import("kernels/math.zig");
/// The scalar-family helpers (`Family(n_u, deriv_reads)`, `Device(D)`).
pub const family = @import("kernels/family.zig");
/// The small-signal side of `absdelay`, `laplace_*` and `zi_*`, and `Ac`.
pub const ac = @import("kernels/ac.zig");
/// `vera_timepoint` caches, §3.2.2 arrays, the quadratic `absdelay` reading.
pub const storage = @import("kernels/storage.zig");
/// §4.5 operators, §5.10.3.3 timers, the §4.5.7 history ring.
pub const ops = @import("kernels/ops.zig");
/// §4.5.15 SPICE limiting functions, branchless.
pub const limit = @import("kernels/limit.zig");
/// §4.5.11/§4.5.12 filter numerics.
pub const filter = @import("kernels/filter.zig");
/// §9.21 `$table_model` interpolation.
pub const table = @import("kernels/table.zig");
/// §9.13 / IEEE 1364 §17.9.3 distributions, bit-exact with the listing;
/// also elaboration's literal folds.
pub const rng = @import("kernels/rng.zig");
/// IEEE 1364 §5.4 integers of any width.
pub const wide = @import("kernels/wide.zig");
/// §3.3 string storage and §9.5.4.2 scanning.
pub const str = @import("kernels/str.zig");
/// §9.5.3 run-time format strings; the contract's §9.4.3 real conversions.
pub const printf = @import("kernels/printf.zig");
/// §9.5 the descriptor table and its `zF*` ABI. The table is process-global
/// only through its allocator: every caller passes its own table.
pub const file = @import("kernels/file.zig");
/// §2.6.1 integer literals and IEEE 1364-2005 §5's four-state operations on
/// them: the reference every engine's operators are judged by.
pub const Integer = @import("kernels/Integer.zig");
/// IEEE 1364-2005 §17.1 value and time text over `Integer` literals.
pub const fmt = @import("kernels/fmt.zig");
/// The §4.2 value folds and the A.8.6 operator enums they take.
pub const fold = @import("kernels/fold.zig");

/// What a program's root may set (`pub const vera_kernels: Options`).
pub const Options = math.Options;
/// The family helpers of a device with `n_u` unknowns.
pub const Family = family.Family;

/// §9.5.1 Table 9-24's `$fopen` type strings, the fifteen of IEEE 1364-2005
/// §17.2.1 Table 17-7: one list for lowering's E0889 and the digital engine.
pub const fopen_types = std.StaticStringMap(void).initComptime(.{
    .{"r"},   .{"rb"}, .{"w"},   .{"wb"},  .{"a"},  .{"ab"},  .{"r+"},  .{"r+b"},
    .{"rb+"}, .{"w+"}, .{"w+b"}, .{"wb+"}, .{"a+"}, .{"a+b"}, .{"ab+"},
});

test {
    std.testing.refAllDecls(@This());
    _ = Integer;
    _ = fmt;
    _ = fold;
    _ = math;
    // The four-state reference `Integer` is judged by.
    _ = @import("kernels/Integer/ref4.zig");
}
