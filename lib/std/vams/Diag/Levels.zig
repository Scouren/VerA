//! Levels: `--allow=`/`--warn=`/`--deny=`/`--forbid=` flags in, the `Level`
//! of every code out. A fixed table, one byte a code, so setting a level
//! never allocates and a copy owns nothing. aro's `Diagnostics.set`
//! (lib/compiler/aro/aro/Diagnostics.zig:359), one code per option.
//!
//! Cites no LRM clause: the flags are VerA's own, after rustc's lint levels.
//!
//! Contents:
//! - `pub const Level = enum(u8) { allow, warn, deny, forbid }`
//! - `pub const SetError = error{ CannotAllowError, Forbidden }`
//! - `slots`, `pub const empty`, `pub fn set`, `pub fn get`, `pub fn parseFlag`

const std = @import("std");
const assert = std.debug.assert;
const Diag = @import("../Diag.zig");
const Code = Diag.Code;
const severityOf = Diag.severityOf;

/// Each code's override, or `.default`.
slots: std.enums.EnumArray(Code, Slot),

/// What the user asked to do with a code.
pub const Level = enum(u8) {
    /// Do not collect it at all.
    allow,
    /// Collect and report, but do not fail the compilation.
    warn,
    /// Report and fail the compilation.
    deny,
    /// Like `deny`, and any later level but `forbid` for the same code is
    /// refused (`error.Forbidden`) rather than silently honoured.
    forbid,
};

/// Every way `set` and `parseFlag` fail. On any error the levels are
/// unchanged.
pub const SetError = error{
    /// An `E` code was asked for below `deny`: an error cannot be allowed or
    /// warned away.
    CannotAllowError,
    /// The code is already `forbid`, and the new level is not.
    Forbidden,
};

/// Every code at its default: `deny` for an error, `warn` for a warning.
pub const empty: Levels = .{ .slots = .initFill(.default) };

const Levels = @This();

/// A slot: a `Level`, or no override yet.
const Slot = enum(u8) { default, allow, warn, deny, forbid };

comptime {
    assert(@sizeOf(Levels) == @typeInfo(Code).@"enum".field_names.len); // One byte a code.
}

/// Records `level` for `c`. A later call for the same code overrides an
/// earlier one, except over `forbid`.
pub fn set(self: *Levels, c: Code, level: Level) SetError!void {
    if (severityOf(c) == .err and (level == .allow or level == .warn)) return error.CannotAllowError;
    if (self.slots.get(c) == .forbid and level != .forbid) return error.Forbidden;
    self.slots.set(c, switch (level) {
        .allow => .allow,
        .warn => .warn,
        .deny => .deny,
        .forbid => .forbid,
    });
    assert(self.get(c) == level);
    if (severityOf(c) == .err) assert(level == .deny or level == .forbid);
}

/// Returns the level of `c`: its override, else `deny` for an error and
/// `warn` for a warning. An error is never below `deny` (`set` refuses).
pub fn get(self: Levels, c: Code) Level {
    const level: Level = switch (self.slots.get(c)) {
        .default => switch (severityOf(c)) {
            .err => .deny,
            .warning => .warn,
        },
        .allow => .allow,
        .warn => .warn,
        .deny => .deny,
        .forbid => .forbid,
    };
    if (severityOf(c) == .err) assert(level == .deny or level == .forbid);
    return level;
}

/// Parses and applies `allow=W0650`-style text. Returns false when the text
/// is not a level directive or names no known level or code (both
/// case-sensitive), so a caller can fall through to other flags. Fails as
/// `set` does.
pub fn parseFlag(self: *Levels, text: []const u8) SetError!bool {
    const eq = std.mem.findScalar(u8, text, '=') orelse return false;
    const level = std.meta.stringToEnum(Level, text[0..eq]) orelse return false;
    const c = std.meta.stringToEnum(Code, text[eq + 1 ..]) orelse return false;
    try self.set(c, level);
    assert(self.get(c) == level);
    return true;
}
