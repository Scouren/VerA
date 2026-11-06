//! The link stage (Zig's `src/link.zig` + `src/link/Queue.zig`, for a
//! compiler whose backends emit Zig source): generated Zig text in, a
//! library, an object, an executable or a `--check` verdict out, each from
//! `zig` children run through one caller-owned, bounded `Queue`, a library
//! keyed in `std.Build.Cache`. Re-exports only; the files import each other
//! directly, never this root. Imports no compiler module: the caller hands
//! it bytes. `contract`: `DevicePart`, the pieces of a split build.
//! `dynlib`: only the tests that load what they built. No LRM clause beyond
//! §8.3's device-side ABI: the argv and the protocol are Zig's.
//!
//! ```zig
//! var slots: [4]link.Server = undefined;
//! var q: link.Queue = .init(&slots); // at most 4 `zig` children alive
//! const f: link.File = .{ .kind = .so, .work_dir = "w", .name = "dev", .optimize = .fast, .modules = &mods };
//! var built = try f.flush(gpa, io, &q, device, 1);
//! defer built.deinit(gpa);
//! ```
//!
//! Contents:
//! - `pub const File`, `Kind`, `Artifact`, `Error`, `Task`, `split_min_bytes`, `plan` (from `link/File.zig`)
//! - `pub const Queue`, `pub const Server` (the children)
//! - `pub const Backend`, `Module`, `Split`, `Piece`, `Command`, `argv`, `strip` (from `link/Zig.zig`)
//! - `pub const Output`, `Tree`, `TreeError`, `writeTree`, `fileStem` (from `link/tree.zig`)
//! - `pub const runtime_modules`, `treeOf`, `batch_argv0`, `Staged`, `StageError`, `buildExe`, `stage`, `buildBatch` (from `link/exe.zig`)
//! - `pub const Verdict`, `CheckError`, `typeCheck` (from `link/check.zig`)

const Zig = @import("link/Zig.zig");
const tree = @import("link/tree.zig");
const exe = @import("link/exe.zig");
const check = @import("link/check.zig");
/// One artifact's build; `flush` makes a library.
pub const File = @import("link/File.zig");
/// The bound on `zig` children; caller-owned.
pub const Queue = @import("link/Queue.zig");
/// One `zig --listen=-` child.
pub const Server = @import("link/Server.zig");

/// What a `File` becomes.
pub const Kind = File.Kind;
/// A build's outcome: the built file's path, or the compiler's report.
pub const Artifact = File.Artifact;
/// Every way a build fails short of a compiler report.
pub const Error = File.Error;
/// One step of a library flush.
pub const Task = File.Task;
/// Device text from which `Split.by_size` splits an LLVM build.
pub const split_min_bytes = File.split_min_bytes;
/// A library flush's tasks, in order.
pub const plan = File.plan;
/// Which Zig code generator builds an artifact.
pub const Backend = Zig.Backend;
/// One module on a compiler command line.
pub const Module = Zig.Module;
/// How a library build is cut into compiler processes.
pub const Split = Zig.Split;
/// One object of a split build.
pub const Piece = Zig.Piece;
/// One `zig` child's command line, before `argv` writes it.
pub const Command = Zig.Command;
/// The one argv builder.
pub const argv = Zig.argv;
/// Whether a build passes `-fstrip` by default.
pub const strip = Zig.strip;
/// The generated device text and its per-unit columns.
pub const Output = tree.Output;
/// Where `writeTree` writes and what its shim declares.
pub const Tree = tree.Tree;
/// Every way `writeTree` fails.
pub const TreeError = tree.TreeError;
/// Writes the device tree a library build compiles, touching only changed files.
pub const writeTree = tree.writeTree;
/// A module name as a file-name stem: kept when short and plain, else a
/// plain prefix and a hash, so any §2.8.1 escaped name is a legal file name.
pub const fileStem = tree.fileStem;
/// The `sim` runtime's module rows, roots relative to the VerA tree; must
/// match build.zig's `module_specs` for `sim` and what it imports.
pub const runtime_modules = exe.runtime_modules;
/// The VerA tree a `contract` root sits in (`<tree>/lib/contract.zig`).
pub const treeOf = exe.treeOf;
/// The `argv[0]` prefix a batch binary dispatches on.
pub const batch_argv0 = exe.batch_argv0;
/// A testbench's module files on disk.
pub const Staged = exe.Staged;
/// Every way `stage` fails.
pub const StageError = exe.StageError;
/// Builds a device and a runner into one binary, or a runner library.
pub const buildExe = exe.buildExe;
/// Writes a testbench's module files without building.
pub const stage = exe.stage;
/// Builds several staged testbenches into one binary.
pub const buildBatch = exe.buildBatch;
/// Whether a device type-checks against the contract.
pub const Verdict = check.Verdict;
/// Every way `typeCheck` fails short of a verdict.
pub const CheckError = check.CheckError;
/// `--check`: type-checks device text against the contract.
pub const typeCheck = check.typeCheck;

test {
    @import("std").testing.refAllDecls(@This());
    _ = File;
    _ = Queue;
    _ = Server;
    _ = Zig;
    _ = tree;
    _ = exe;
    _ = check;
    _ = @import("link/test.zig");
}
