//! The bound on `zig` children: command lines in, each child's reply out, at
//! most `slots.len` children alive at once. The caller owns the queue and
//! its slots (later `Compilation`, sized by its thread limit) and hands it
//! to every build; a build never spawns on its own. As
//! `src/link/Queue.zig` in the Zig compiler, but its tasks are processes:
//! each child holds the whole device's analysis in memory, so a split of 3
//! parts and 64 setup chunks spawned at once could exhaust a machine's RAM.
//! Cites no LRM clause.
//!
//! Contents:
//! - `pub fn init(slots: []Server) Queue`
//! - `pub fn run(q: *Queue, gpa: Allocator, io: Io, arena: Allocator, argvs: []const []const []const u8, done: []Server.Done) Server.Error!?std.zig.ErrorBundle`

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Server = @import("Server.zig");

/// One per child that may be alive at once; `slots.len` is the job count.
/// Caller-owned, undefined between runs.
slots: []Server,

const Queue = @This();

/// Returns a queue that keeps at most `slots.len` children alive. Asserts
/// that there is a slot.
pub fn init(slots: []Server) Queue {
    assert(slots.len > 0);
    const q: Queue = .{ .slots = slots };
    assert(q.slots.len == slots.len);
    return q;
}

/// Runs one child per entry of `argvs`, at most `slots.len` alive, each
/// sent one update as it starts. Replies are read in `argvs` order, and a
/// finished child's slot takes the next command, so the outputs are the same
/// at any job count. On success every `done[i]` is child `i`'s reply and
/// null is returned. A failed child's report is returned instead, the first
/// in `argvs` order; no command after it is started, and the children still
/// alive are killed. Caller owns the report and frees it with `gpa`;
/// `done[i].inputs` and every argv live in `arena`. Fails as `Server.Error`
/// says, every child reaped. Asserts that `done` has one entry per command.
pub fn run(
    q: *Queue,
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    argvs: []const []const []const u8,
    done: []Server.Done,
) Server.Error!?std.zig.ErrorBundle {
    assert(done.len == argvs.len);
    const jobs = q.slots.len;
    // `slots[i % jobs]` for `i` in `waited..started` are the live children.
    var started: usize = 0;
    var waited: usize = 0;
    defer for (waited..started) |i| q.slots[i % jobs].kill(io);
    while (waited < argvs.len) {
        while (started < argvs.len and started - waited < jobs) {
            const s = &q.slots[started % jobs];
            try s.spawn(io, arena, argvs[started]);
            started += 1;
            try s.update(io);
        }
        assert(started > waited);
        assert(started - waited <= jobs);
        const s = &q.slots[waited % jobs];
        const reply = try s.wait(gpa, arena);
        s.close(io);
        waited += 1;
        switch (reply) {
            .failed => |bundle| return bundle,
            .ok => |d| done[waited - 1] = d,
        }
    }
    assert(started == argvs.len);
    assert(waited == started);
    return null;
}

// The oracle is the window bound counted by hand: `run` over `zig version`
// stand-ins would need a protocol speaker, so the library tests (link.zig,
// test.zig) drive real `zig` children at 1 job and N and compare the bytes.

test init {
    var slots: [2]Server = undefined;
    const q: Queue = .init(&slots);
    try std.testing.expectEqual(@as(usize, 2), q.slots.len);
}
