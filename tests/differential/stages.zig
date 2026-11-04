//! The stage-ownership table of the differential oracles
//! (docs/rewrite/README.md rule 3): which stage raises each code the old
//! compiler's elaboration raised, so an oracle compares only the codes its
//! stage owns and the end-to-end oracle demands the rest. `elab` is
//! Sema's elaboration (diff-elab compares these); `analysis` is Sema's
//! per-instance expression, access and statement analysis (stage 5), which
//! the old compiler ran inside its flatten and diff-lower demands.
//! No LRM clause: this checks VerA's rewrite against VerA.
//!
//! Contents:
//! - `pub const elab_codes`, `pub const analysis_codes`
//! - `pub fn isElab(code: []const u8) bool`, `pub fn isAnalysis(code: []const u8) bool`

const std = @import("std");

/// The codes elaboration owns.
pub const elab_codes = [_][]const u8{ "E0235", "E0239", "E0247", "E0347", "E0355", "E0358", "E0371", "E0375", "E0376", "E0816", "E0890", "E0902", "E0903", "E0904", "E0905", "E0906", "E0908", "E0909", "E0911", "E0914", "E0915", "E0916", "E0917", "E0921", "E0922", "E0923", "E0927", "E0929", "E0952", "E0982", "E0997", "W0950", "W0951", "W1152" };

/// The codes the old elaboration raised that stage 5 owns: an
/// aliasparam read (E0373), a hierarchical name (E0901), an out-of-module
/// reference (E0907), a paramset statement (E0237), an access on a net
/// with no discipline (E0337) or not of its discipline (E0501), a §9.18
/// override reading state (E0363), a digital instance in an analog device
/// (W0252).
pub const analysis_codes = [_][]const u8{ "E0237", "E0337", "E0363", "E0373", "E0501", "E0901", "E0907", "W0252" };

/// Whether elaboration owns `code`.
pub fn isElab(code: []const u8) bool {
    for (elab_codes) |c| if (std.mem.eql(u8, c, code)) return true;
    return false;
}

/// Whether stage 5 owns `code` (diff-elab leaves it to diff-lower).
pub fn isAnalysis(code: []const u8) bool {
    for (analysis_codes) |c| if (std.mem.eql(u8, c, code)) return true;
    return false;
}

comptime {
    @setEvalBranchQuota(elab_codes.len * analysis_codes.len * 16);
    // The two lists share no code.
    for (elab_codes) |e| for (analysis_codes) |a| std.debug.assert(!std.mem.eql(u8, e, a));
}
