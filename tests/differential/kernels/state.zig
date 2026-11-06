//! `diff-kernels` part 3, the kernels with state or text: the §4.5.7
//! history ring (old and new rings driven by one seeded sequence of reads,
//! pushes, thinnings and reverts, compared after every operation), §9.21
//! tables, §9.5.4.2 scanning and §9.5.3 run-time formats, §3.3 string
//! storage, the §9.5 descriptor table (one seeded script over two
//! directories, every return and the files' bytes compared), and the
//! four-state `Integer` literals with their `fmt` text.
//! Cites: none (test tooling; the kernels' own clauses are theirs).
//!
//! Contents:
//! - `pub fn run(rep: *g.Report, gpa: std.mem.Allocator) !void`

const std = @import("std");
const g = @import("gen.zig");
const scalar = @import("scalar.zig");
const sk = @import("std_kernels");
const ok = @import("kernels");
const old = @import("old_text");

const K = scalar.K;
const R = g.AnyReal;

const scan_fmts = [_][]const u8{
    "%d",  "%d %d", "%f",     "%e",    "%g",    "%s",      "%c",      "%x",       "%o",  "%b",  "%h",
    "%r",  "%m",    "%*d %d", "%5s",   "%3d%s", "a%db",    "%d,%f",   "%%%d",     " %d", "%2c", "%s %s %s",
    "%5f", "%*s%d", "%h%d",   "%b %o", "%e%e",  "x%c%c%c", "%10d%2d", "%g %s %d",
};
const scan_chars = "0123456789 -+.eExXabcfzZ?\t\n%,_'";

pub fn run(rep: *g.Report, gpa: std.mem.Allocator) !void {
    hist(rep);
    table(rep);
    strings(rep);
    try files(rep);
    try integers(rep, gpa);
}

// ---- private ----

fn kOf(r: g.Rng, i: usize) K {
    return .{ .v = .{ .v = R.gen(r, i), .d = .{ r.float(f64), -r.float(f64) } } };
}

/// One ring, old and new, through one sequence: after each push or revert
/// the two rings and heads must be equal, and every read of them too.
fn hist(rep: *g.Report) void {
    const r = rep.random();
    const OH = ok.hist_kernels;
    const NH = sk.ops;
    inline for (.{ 1, 2, 3, 8, 16 }) |n| {
        var ts = [2][n]f64{ @splat(0), @splat(0) };
        var vs = [2][n]f64{ @splat(0), @splat(0) };
        var head = [2]u64{ 0, 0 };
        var t: f64 = 0;
        for (0..g.random_per_fn / 5) |i| {
            // Reads at a random lookback.
            const td = switch (r.uintLessThan(u8, 4)) {
                0 => 0,
                1 => r.float(f64) * 1e-3,
                2 => r.float(f64) * 10,
                else => R.gen(r, i),
            };
            const dt: f64 = if (r.uintLessThan(u8, 8) == 0) 0 else 1e-4;
            const vin = kOf(r, i);
            rep.record("hist.zAbsdelay", g.dist(OH.zAbsdelay(K, vin, &ts[0], &vs[0], head[0], t, dt, td), NH.zAbsdelay(K, vin, &ts[1], &vs[1], head[1], t, dt, td)), .{ n, i });
            rep.record("hist.zHistAt", g.dist(OH.zHistAt(&ts[0], &vs[0], head[0], t - td), NH.zHistAt(&ts[1], &vs[1], head[1], t - td)), .{ n, i });
            rep.record("storage.zAbsdelayQ", g.dist(old.zAbsdelayQ(K, vin, &ts[0], &vs[0], head[0], t, dt, td), sk.storage.zAbsdelayQ(K, vin, &ts[1], &vs[1], head[1], t, dt, td)), .{ n, i });
            rep.record("storage.zHistAtQ", g.dist(old.zHistAtQ(&ts[0], &vs[0], head[0], t - td), sk.storage.zHistAtQ(&ts[1], &vs[1], head[1], t - td)), .{ n, i });
            // An accepted step: thin, push, and now and then revert it.
            t += if (r.boolean()) r.float(f64) * 1e-3 else 0;
            const v = R.gen(r, i +% 1);
            const w = r.float(f64) * 5e-3;
            var saved: [2][5]f64 = undefined;
            var heads: [2][2]u64 = undefined;
            inline for (0..2) |s| {
                const committed = head[s];
                const slot: usize = @intCast(committed % n);
                saved[s][0] = ts[s][slot];
                saved[s][1] = vs[s][slot];
                if (s == 0) OH.zHistThin("diff", &ts[s], &vs[s], &head[s], t, w) else NH.zHistThin("diff", &ts[s], &vs[s], &head[s], t, w);
                const dropped: usize = @intCast(head[s] % n);
                saved[s][2] = ts[s][dropped];
                saved[s][3] = vs[s][dropped];
                if (s == 0) OH.zHistPush(&ts[s], &vs[s], &head[s], t, v) else NH.zHistPush(&ts[s], &vs[s], &head[s], t, v);
                heads[s] = .{ committed, head[s] };
            }
            rep.record("hist.zHistPush", g.dist(.{ ts[0], vs[0], head[0] }, .{ ts[1], vs[1], head[1] }), .{ n, i });
            if (r.uintLessThan(u8, 4) == 0) {
                OH.zHistRevert(&ts[0], &vs[0], heads[0][0], heads[0][1], saved[0][0], saved[0][1], saved[0][2], saved[0][3]);
                NH.zHistRevert(&ts[1], &vs[1], heads[1][0], heads[1][1], saved[1][0], saved[1][1], saved[1][2], saved[1][3]);
                head = .{ heads[0][0], heads[1][0] };
                rep.record("hist.zHistRevert", g.dist(.{ ts[0], vs[0], head[0] }, .{ ts[1], vs[1], head[1] }), .{ n, i });
            }
        }
    }
    g.cmp(rep, "hist.zhKept", OH.zhKept, NH.zhKept, .{}, .{g.Int(usize, 0, 1 << 20)});
}

/// §9.21: 1-D and 2-D tables of distinct samples in shuffled order, each
/// extrapolation and degree, looked up anywhere (an `E` end is left out:
/// past it the lookup exits, E0814).
fn table(rep: *g.Report) void {
    const r = rep.random();
    const exts1 = .{ "1LL", "2LL", "3LL", "1CC", "3CL", "DLL", "2CC" };
    for (0..g.random_per_fn / 10) |i| {
        var rows: [12]f64 = undefined;
        var xs: [6]f64 = undefined;
        // Moderate, so `x + step` never rounds back onto `x`.
        var x: f64 = r.float(f64) * 200 - 100;
        for (&xs) |*e| {
            e.* = x;
            x += 0.01 + r.float(f64) * 3;
        }
        r.shuffle(f64, &xs);
        for (0..6) |k| {
            rows[2 * k] = xs[k];
            rows[2 * k + 1] = g.Real(-1e3, 1e3).gen(r, i +% k);
        }
        const pt = [1]K{kOf(r, i +% 9)};
        inline for (exts1) |e|
            rep.record("table.zTable.1d." ++ e, g.dist(ok.table_kernels.zTable(K, 6, 2, 1, 1, e, rows, pt), sk.table.zTable(K, 6, 2, 1, 1, e, rows, pt)), .{ rows, pt[0].v.v });
        // A 3x4 grid, rows shuffled.
        var grid: [36]f64 = undefined;
        var order = [12]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
        r.shuffle(usize, &order);
        for (order, 0..) |k, row| {
            grid[3 * row] = @floatFromInt(k / 4);
            grid[3 * row + 1] = @as(f64, @floatFromInt(k % 4)) * 0.5;
            grid[3 * row + 2] = r.float(f64) * 10 - 5;
        }
        const p2 = [2]K{ kOf(r, i +% 11), kOf(r, i +% 12) };
        inline for (.{ "1LL1LL", "3CC3CC", "2LL1CL", "DLL1LL" }) |e|
            rep.record("table.zTable.2d." ++ e, g.dist(ok.table_kernels.zTable(K, 12, 3, 2, 2, e, grid, p2), sk.table.zTable(K, 12, 3, 2, 2, e, grid, p2)), .{ p2[0].v.v, p2[1].v.v });
    }
}

fn strings(rep: *g.Report) void {
    const r = rep.random();
    const OS = ok.str_scan;
    const NS = sk.str;
    var src_buf: [40]u8 = undefined;
    for (0..g.random_per_fn) |i| {
        const len = r.uintLessThan(usize, src_buf.len);
        for (src_buf[0..len]) |*c| c.* = scan_chars[r.uintLessThan(usize, scan_chars.len)];
        if (len > 0 and r.uintLessThan(u8, 8) == 0) src_buf[r.uintLessThan(usize, len)] = 0;
        const src = src_buf[0..len];
        const fmt = scan_fmts[r.uintLessThan(usize, scan_fmts.len)];
        const want = r.intRangeAtMost(i64, -1, 3);
        rep.record("str.zScan", g.dist(OS.zScan(src, fmt, want), NS.zScan(src, fmt, want)), .{ src, fmt, want });
        rep.record("str.zScanNul", g.dist(OS.zScanNul(src, fmt, want), NS.zScanNul(src, fmt, want)), .{ src, fmt, want });
        rep.record("str.zScanN", g.dist(OS.zScanN(src, fmt), NS.zScanN(src, fmt)), .{ src, fmt });
        rep.record("str.zScanI", g.dist(OS.zScanI(src, fmt, want), NS.zScanI(src, fmt, want)), .{ src, fmt });
        rep.record("str.zScanR", g.dist(OS.zScanR(src, fmt, want), NS.zScanR(src, fmt, want)), .{ src, fmt });
        rep.record("str.zScanS", g.dist(OS.zScanS(src, fmt, want), NS.zScanS(src, fmt, want)), .{ src, fmt });
        rep.record("str.zScanNulN", g.dist(OS.zScanNulN(src, fmt), NS.zScanNulN(src, fmt)), .{ src, fmt });
        rep.record("str.zScanNulI", g.dist(OS.zScanNulI(src, fmt, want), NS.zScanNulI(src, fmt, want)), .{ src, fmt });
        rep.record("str.zScanNulR", g.dist(OS.zScanNulR(src, fmt, want), NS.zScanNulR(src, fmt, want)), .{ src, fmt });
        rep.record("str.zScanNulS", g.dist(OS.zScanNulS(src, fmt, want), NS.zScanNulS(src, fmt, want)), .{ src, fmt });
        // §3.3 storage over the same text.
        var ob: [64]u8 = undefined;
        var nb: [64]u8 = undefined;
        const half = src[0 .. len / 2];
        const parts = [_][]const u8{ half, "|", src[len / 2 ..] };
        rep.record("str.zStrCat", g.dist(ok.str_store.zStrCat(&ob, &parts), NS.zStrCat(&nb, &parts)), .{src});
        const count = r.intRangeAtMost(i64, -2, if (half.len == 0) 5 else @intCast(64 / half.len));
        rep.record("str.zStrRepeat", g.dist(ok.str_store.zStrRepeat(&ob, count, half), NS.zStrRepeat(&nb, count, half)), .{ half, count });
        var os: [40]u8 = undefined;
        var ns: [40]u8 = undefined;
        @memcpy(os[0..len], src);
        @memcpy(ns[0..len], src);
        if (len > 0) rep.record("str.zStringStore", g.dist(ok.str_store.zStringStore(os[0..len]), NS.zStringStore(ns[0..len])), .{src});
        const oh = ok.str_store.zStrHeldN(48, src);
        const nh = NS.zStrHeldN(48, src);
        rep.record("str.zStrHeldN", g.dist(oh.get(), nh.get()), .{src});
        // §9.5.3, three conversions over three arguments (a short or long
        // list is a warning per call, which 10^5 calls would flood).
        var fb: [160]u8 = undefined;
        const f = runFormat(r, &fb);
        const args = .{ g.Of(i64).gen(r, i), R.gen(r, i), src };
        var o4: [4096]u8 = undefined;
        var n4: [4096]u8 = undefined;
        rep.record("printf.zSFormatRt", g.dist(ok.str_format.zSFormatRt(&o4, f, "top.dev", args), sk.printf.zSFormatRt(&n4, f, "top.dev", args)), .{f});
    }
    // §9.4.1 the `$monitor` latch, armed and fed the same values.
    var om: ok.str_store.ZMon = .{};
    var nm: NS.ZMon = .{};
    for (0..g.random_per_fn / 10) |i| {
        if (r.uintLessThan(u8, 8) == 0) rep.record("str.zMonitorArm", g.dist(ok.str_store.zMonitorArm(&om), NS.zMonitorArm(&nm)), .{i});
        const vals = [_]u64{ r.uintLessThan(u64, 3), r.uintLessThan(u64, 2) };
        rep.record("str.zMonitor", g.dist(ok.str_store.zMonitor(&om, &vals, "t"), NS.zMonitor(&nm, &vals, "t")), .{ vals, i });
        rep.record("str.ZMon", g.dist(om, nm), .{i});
    }
}

/// A §9.4.3 format of exactly three argument conversions, with flags,
/// widths, precisions and the argument-free `%m`, `%l` and `%%` between.
fn runFormat(r: g.Rng, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const convs = "dhxobcsefgrDHXOBCSEFGR";
    const glue = [_][]const u8{ "", " ", "=", "%%", "%m", "%l", "x%-8m|", "\\n" };
    for (0..3) |_| {
        w.writeAll(glue[r.uintLessThan(usize, glue.len)]) catch unreachable;
        const conv = convs[r.uintLessThan(usize, convs.len)];
        w.writeByte('%') catch unreachable;
        for ("-+ 0") |fl| if (r.uintLessThan(u8, 6) == 0) w.writeByte(fl) catch unreachable;
        if ((conv | 0x20) == 'e' or (conv | 0x20) == 'f' or (conv | 0x20) == 'g') {
            if (r.uintLessThan(u8, 6) == 0) w.writeByte('#') catch unreachable;
        }
        if (r.boolean()) w.print("{d}", .{r.uintLessThan(u8, 30)}) catch unreachable;
        if (r.boolean()) w.print(".{d}", .{r.uintLessThan(u8, 20)}) catch unreachable;
        w.writeByte(conv) catch unreachable;
    }
    return w.buffered();
}

/// §9.5: one seeded script of opens, writes, reads, seeks and closes run
/// on an old table in one directory and a new table in another; every
/// return is compared, and the files' bytes at the end.
fn files(rep: *g.Report) !void {
    const OF = ok.file_kernels;
    const NF = sk.file;
    var ot: ok.file_table.ZfTable = .{};
    var nt: NF.ZfTable = .{};
    defer OF.zFFreeAll(&ot);
    defer NF.zFFreeAll(&nt);
    const oc: *anyopaque = &ot;
    const nc: *anyopaque = &nt;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = rep.random();
    const names = [_][]const u8{ "a.dat", "b.dat", "c.dat" };
    const types = [_][]const u8{ "r", "w", "a", "r+", "w+", "a+", "rb", "wb+" };
    var od: [8]i64 = @splat(0);
    var nd: [8]i64 = @splat(0);
    var pb: [2][128]u8 = undefined;
    for (0..g.random_per_fn / 10) |i| {
        const k = r.uintLessThan(usize, od.len);
        const op = r.uintLessThan(u8, 12);
        const o = od[k];
        const n = nd[k];
        switch (op) {
            0, 1 => {
                const name = names[r.uintLessThan(usize, names.len)];
                const op_ = std.fmt.bufPrint(&pb[0], ".zig-cache/tmp/{s}/old-{s}", .{ tmp.sub_path, name }) catch unreachable;
                const np_ = std.fmt.bufPrint(&pb[1], ".zig-cache/tmp/{s}/new-{s}", .{ tmp.sub_path, name }) catch unreachable;
                if (o != 0) _ = OF.zFClose(oc, o);
                if (n != 0) _ = NF.zFClose(nc, n);
                const mcd = op == 1 and r.uintLessThan(u8, 4) == 0;
                const ty = if (mcd) "" else types[r.uintLessThan(usize, types.len)];
                od[k] = OF.zFOpen(oc, op_, ty, mcd);
                nd[k] = NF.zFOpen(nc, np_, ty, mcd);
                rep.record("file.zFOpen", g.dist(od[k], nd[k]), .{ name, ty, mcd });
            },
            2 => {
                var text: [24]u8 = undefined;
                const len = r.uintLessThan(usize, text.len);
                for (text[0..len]) |*c| c.* = "ab \n0123"[r.uintLessThan(usize, 8)];
                rep.record("file.zFPut", g.dist(OF.zFPut(oc, o, text[0..len]), NF.zFPut(nc, n, text[0..len])), .{ op, i });
            },
            3 => {
                rep.record("file.zFGets", g.dist(OF.zFGets(oc, o), NF.zFGets(nc, n)), .{ op, i });
                const want = r.intRangeAtMost(i64, 0, 30);
                rep.record("file.zFLine", g.dist(OF.zFLine(oc, want, o), NF.zFLine(nc, want, n)), .{ op, i });
            },
            4 => rep.record("file.zFGetc", g.dist(OF.zFGetc(oc, o), NF.zFGetc(nc, n)), .{ op, i }),
            5 => {
                const c = r.intRangeAtMost(i64, -1, 255);
                rep.record("file.zFUngetc", g.dist(OF.zFUngetc(oc, c, o), NF.zFUngetc(nc, c, n)), .{ op, i });
            },
            6 => rep.record("file.zFTell", g.dist(OF.zFTell(oc, o), NF.zFTell(nc, n)), .{ op, i }),
            7 => {
                const off = r.intRangeAtMost(i64, -5, 40);
                const whence = r.intRangeAtMost(i64, -1, 3);
                rep.record("file.zFSeek", g.dist(OF.zFSeek(oc, o, off, whence), NF.zFSeek(nc, n, off, whence)), .{ off, whence });
            },
            8 => {
                rep.record("file.zFEof", g.dist(OF.zFEof(oc, o), NF.zFEof(nc, n)), .{ op, i });
                rep.record("file.zFError", g.dist(OF.zFError(oc, o), NF.zFError(nc, n)), .{ op, i });
            },
            9 => {
                rep.record("file.zFWindow", g.dist(OF.zFWindow(oc, o), NF.zFWindow(nc, n)), .{ op, i });
                const used = r.intRangeAtMost(i64, 0, 8);
                const take = r.intRangeAtMost(i64, 0, 8);
                rep.record("file.zFTake", g.dist(OF.zFTake(oc, o, take, used), NF.zFTake(nc, n, take, used)), .{ op, i });
            },
            10 => {
                rep.record("file.zFClose", g.dist(OF.zFClose(oc, o), NF.zFClose(nc, n)), .{ op, i });
                od[k] = 0;
                nd[k] = 0;
            },
            else => {
                OF.zFNewAnalysis(oc);
                NF.zFNewAnalysis(nc);
            },
        }
        rep.record("file.zFErrorStr", g.dist(OF.zFErrorStr(OF.zFError(oc, od[k]), 0), NF.zFErrorStr(NF.zFError(nc, nd[k]), 0)), .{i});
    }
    // The bytes each script left behind.
    for (od, nd) |o, n| {
        if (o != 0) _ = OF.zFClose(oc, o);
        if (n != 0) _ = NF.zFClose(nc, n);
    }
    const io = std.testing.io;
    for (names) |name| {
        var ob: [1 << 16]u8 = undefined;
        var nb: [1 << 16]u8 = undefined;
        const ot_ = std.fmt.bufPrint(&pb[0], "old-{s}", .{name}) catch unreachable;
        const a = tmp.dir.readFile(io, ot_, &ob) catch "";
        const nt_ = std.fmt.bufPrint(&pb[1], "new-{s}", .{name}) catch unreachable;
        const b = tmp.dir.readFile(io, nt_, &nb) catch "";
        rep.record("file.bytes", g.dist(a, b), .{name});
    }
}

/// Four-state literals: random literal text parsed by both (the result and
/// the error), then every operator over pairs of them, compared plane for
/// plane, and each value's §17.1 text in every radix.
fn integers(rep: *g.Report, gpa: std.mem.Allocator) !void {
    const OI = ok.Integer;
    const NI = sk.Integer;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const r = rep.random();
    for (0..g.random_per_fn / 2) |i| {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var tb: [2][96]u8 = undefined;
        const ta = literalText(r, &tb[0]);
        const tbx = literalText(r, &tb[1]);
        const oa = OI.parse(arena, ta);
        const na = NI.parse(arena, ta);
        rep.record("Integer.parse", errDist(oa, na), .{ta});
        const ob = OI.parse(arena, tbx) catch continue;
        const nb = NI.parse(arena, tbx) catch continue;
        const ol = oa catch continue;
        const nl = na catch continue;
        inline for (comptime std.enums.values(OI.Arithmetic)) |op|
            rep.record("Integer.arithmetic." ++ @tagName(op), errDist(ol.arithmetic(arena, op, ob), nl.arithmetic(arena, @field(NI.Arithmetic, @tagName(op)), nb)), .{ ta, tbx });
        inline for (comptime std.enums.values(OI.Bitwise)) |op|
            rep.record("Integer.bitwise." ++ @tagName(op), errDist(ol.bitwise(arena, op, ob), nl.bitwise(arena, @field(NI.Bitwise, @tagName(op)), nb)), .{ ta, tbx });
        inline for (comptime std.enums.values(OI.Relational)) |op|
            rep.record("Integer.relational." ++ @tagName(op), g.dist(ol.relational(op, ob), nl.relational(@field(NI.Relational, @tagName(op)), nb)), .{ ta, tbx });
        inline for (comptime std.enums.values(OI.Equality)) |op|
            rep.record("Integer.equality." ++ @tagName(op), g.dist(ol.equality(op, ob), nl.equality(@field(NI.Equality, @tagName(op)), nb)), .{ ta, tbx });
        inline for (comptime std.enums.values(OI.Reduction)) |op|
            rep.record("Integer.reduce." ++ @tagName(op), g.dist(ol.reduce(op), nl.reduce(@field(NI.Reduction, @tagName(op)))), .{ta});
        rep.record("Integer.negate", errDist(ol.negate(arena), nl.negate(arena)), .{ta});
        rep.record("Integer.bitwiseNot", errDist(ol.bitwiseNot(arena), nl.bitwiseNot(arena)), .{ta});
        // A shift or power by a small amount: their cost is the amount's.
        const small = std.fmt.bufPrint(&tb[1], "{d}", .{r.uintLessThan(u8, 70)}) catch unreachable;
        const os = try OI.parse(arena, small);
        const ns = try NI.parse(arena, small);
        inline for (comptime std.enums.values(OI.Shift)) |op|
            rep.record("Integer.shift." ++ @tagName(op), errDist(ol.shift(arena, op, os), nl.shift(arena, @field(NI.Shift, @tagName(op)), ns)), .{ ta, small });
        rep.record("Integer.power", errDist(ol.power(arena, os), nl.power(arena, ns)), .{ ta, small });
        // §17.1 text of the value, every radix.
        inline for (comptime std.enums.values(ok.fmt.Radix)) |radix| {
            var ow: std.Io.Writer.Allocating = .init(arena);
            var nw: std.Io.Writer.Allocating = .init(arena);
            const width: ?u64 = if (r.boolean()) null else r.uintLessThan(u64, 40);
            ok.fmt.value(&ow.writer, arena, ol, radix, width) catch {};
            sk.fmt.value(&nw.writer, arena, nl, @field(sk.fmt.Radix, @tagName(radix)), width) catch {};
            rep.record("fmt.value." ++ @tagName(radix), g.dist(ow.written(), nw.written()), .{ ta, i });
        }
    }
}

/// The distance of two error unions: their error names, or their values.
fn errDist(a: anytype, b: anytype) u64 {
    const va = a catch |ea| {
        const eb = if (b) |_| return std.math.maxInt(u64) else |e| e;
        return if (std.mem.eql(u8, @errorName(ea), @errorName(eb))) 0 else std.math.maxInt(u64);
    };
    const vb = b catch return std.math.maxInt(u64);
    return g.dist(va, vb);
}

/// A §2.6.1 literal: sized or not, any base, signed or not, with x, z, ?
/// and `_` among the digits, now and then malformed.
fn literalText(r: g.Rng, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const bases = "bodhBODH";
    const base = bases[r.uintLessThan(usize, bases.len)];
    const digits: []const u8 = switch (base | 0x20) {
        'b' => "01xz?_",
        'o' => "01234567xz_",
        'd' => "0123456789",
        else => "0123456789abcdefABCDEFxz?_",
    };
    const plain = r.uintLessThan(u8, 5) == 0;
    if (!plain) {
        if (r.uintLessThan(u8, 4) != 0) w.print("{d}", .{r.intRangeAtMost(u32, 1, 130)}) catch unreachable;
        w.writeByte('\'') catch unreachable;
        if (r.boolean()) w.writeByte('s') catch unreachable;
        w.writeByte(base) catch unreachable;
    }
    const nd = r.intRangeAtMost(usize, if (r.uintLessThan(u8, 16) == 0) 0 else 1, 30);
    for (0..nd) |_| w.writeByte(if (plain) "0123456789"[r.uintLessThan(usize, 10)] else digits[r.uintLessThan(usize, digits.len)]) catch unreachable;
    return w.buffered();
}
