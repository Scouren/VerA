//! The analog SSA IR Sema writes and every later stage reads (Zig's
//! `src/Air.zig`), structured: blocks with results, `cond_br`, `loop`.
//! Placeholder of the rewrite scaffold: docs/rewrite/core-ir.md specifies
//! it.
//!
//! Contents: none yet.

const InternPool = @import("intern_pool");

test {
    _ = InternPool;
}
