//! §3.3 string storage and §9.5.4.2 scanning: a call site's text in, bytes
//! that outlive the expression that made them, or a scanned item, out.
//! Per-site scratch rows (`zSBuf`, `zSRow`), held string values
//! (`ZStrHeldN`), run-time concatenation and replication, NUL compaction,
//! the E1011 overrun, §9.4.1's `$monitor` latch, and `$sscanf`/`$fscanf`
//! (`zScan*`, pure: no state, no allocation).
//! Cites: VAMS §2.6.1, §2.6.2 (Table 2-1), §2.7, §3.3 (Table 3-3), §4.2.1.1,
//! §5.10, §9.4.1, §9.5.2, §9.5.3, §9.5.4.2; C11 7.21.6.2.
//!
//! Storage that has to outlive an expression is file scope, one instance per
//! comptime `site`: a distinct site instantiates a distinct struct and so a
//! distinct array, which keeps two `$sformat` calls in one module from
//! writing over each other (§9.5.3 has each name its own string variable).
//! The rows are thread-local on a CPU, so two threads evaluating the same
//! call site on different instances each format into their own row. A
//! `$monitor` latch is state of the instance (`ZMon`, `Instance.zm__`), so
//! two instances of one model each compare against their own last report.
//!
//! A unit body is an SSA expression tree, so a scan that assigns two
//! variables and returns a count has no out-parameter to write through:
//! lowering turns one source call into one `zScanN` (the count) plus one
//! `zScan{I,R,S}` per output argument, each naming its item by index, and
//! every one re-runs the same pure scan over the same two strings. Scope:
//! §9.5.4.2's own list, %d %o %h %x %b %c %f %e %g %s %r %m, with the
//! suppression `*` and the maximum field width; `%v`/`%z`/`%t`, `%n` and
//! `%p` are refused at the call (E0813).
//!
//! Contents:
//! - `pub const ZMon = struct { armed: bool, seen: bool, h: u64 }`
//! - `pub const ZStrHeld = ZStrHeldN(4096)`
//! - `pub const ZScan = struct { n: i64, i: i64, r: f64, s: []const u8, used: usize }`
//! - `pub fn ZStrHeldN(comptime len: usize) type` (`get(h: *const @This()) []const u8`)
//! - `pub fn zSBuf(comptime site: usize) *[4096]u8`
//! - `pub fn zSRow(comptime site: usize, comptime slot: usize, comptime len: usize) *[len]u8`
//! - `pub fn zSTmp(comptime len: usize) *[len]u8`
//! - `pub fn zStringStore(bytes: []u8) []const u8`
//! - `pub fn zStrHeldN(comptime len: usize, s: []const u8) ZStrHeldN(len)`
//! - `pub fn zStrHeld(s: []const u8) ZStrHeld`
//! - `pub fn zStrCat(buf: anytype, parts: []const []const u8) []const u8`
//! - `pub fn zStrRepeat(buf: anytype, count: i64, s: []const u8) []const u8`
//! - `pub fn zSOver() noreturn`
//! - `pub fn zMonitor(m: *const ZMon, vals: []const u64, text: []const u8) ?[]const u8`
//! - `pub fn zMonitorArm(m: *const ZMon) f64`
//! - `pub fn zScan(src: []const u8, fmt: []const u8, want: i64) ZScan`
//! - `pub fn zScanNul(src: []const u8, fmt: []const u8, want: i64) ZScan`
//! - `pub fn zScanN(src: []const u8, fmt: []const u8) i64`
//! - `pub fn zScanI(src: []const u8, fmt: []const u8, k: i64) i64`
//! - `pub fn zScanR(src: []const u8, fmt: []const u8, k: i64) f64`
//! - `pub fn zScanS(src: []const u8, fmt: []const u8, k: i64) []const u8`
//! - `pub fn zScanNulN`, `zScanNulI`, `zScanNulR`, `zScanNulS`: the same four under `zScanNul`

const std = @import("std");

/// One §9.4.1 `$monitor`/`$fmonitor` site's latch in one instance
/// (`Instance.zm__`, one per `Lower.armMonitor` key): whether the statement
/// ran (`armed`), whether a step was reported (`seen`), and the hash of the
/// values it reported (`h`). A plain value, so a host copies it with the
/// instance.
// ponytail: one Wyhash of the watched values, not the values: a change is
// missed with probability 2^-64, as a string operand's own hash already is.
// Keep the values the day a site's operand count reaches the instance field.
pub const ZMon = struct {
    armed: bool = false,
    seen: bool = false,
    h: u64 = 0,
};

/// The held string of the 4096-byte row.
pub const ZStrHeld = ZStrHeldN(4096);

/// One scan. `n` is §9.5.4.2's return, the number of items "successfully
/// matched and assigned", -1 (EOF) when the input ends before any
/// conversion; `i`, `r` and `s` carry the one requested item's value in all
/// three types, because the destination's type is the caller's business (a
/// `%d` may land in a `real`, §4.2.1.1). `used` is the bytes of `src`
/// consumed, fixed per directive: "if conversion terminates on a conflicting
/// input character, the offending input character is left unread in the
/// input stream", and "trailing white space (including newline characters)
/// is left unread unless matched by a directive". `$fscanf` advances its
/// descriptor by exactly this, which is what makes `$ftell` (§9.5.5) answer
/// the clause's number. `s` is a slice of `src`, valid while `src` is.
pub const ZScan = struct { n: i64 = 0, i: i64 = 0, r: f64 = 0.0, s: []const u8 = "", used: usize = 0 };

/// Whether the scratch rows are thread-local: on every CPU target, not on a
/// GPU, which has no thread-local storage (one GPU thread formats nothing).
const zs_tls = switch (@import("builtin").target.cpu.arch) {
    .nvptx64, .amdgcn => false,
    else => true,
};

/// Returns the type of a held string variable's own bytes, an `Instance`
/// field (§5.10/§3.3, #19), `len` bytes: the longest text the model can put
/// there (`cg_strcap.heldCap`). Not a slice: a `$sformat` result lives in its
/// site's row, which the site rewrites the next time it runs (a Newton
/// iterate, a rejected step, a second instance), so a held slice of it
/// changed under the device's feet. `stateCtl` copies the whole value, so a
/// revert restores the text. Invariant: `n <= len`.
// ponytail: `stateCtl` copies all `len` bytes per commit and revert; copy
// `n` there if a model holds many strings and it measures hot.
pub fn ZStrHeldN(comptime len: usize) type {
    return struct {
        n: std.math.IntFittingRange(0, len) = 0,
        b: [len]u8 = @splat(0),

        /// Returns the held text, a view of `h`'s own bytes.
        pub fn get(h: *const @This()) []const u8 {
            std.debug.assert(h.n <= len);
            return h.b[0..h.n];
        }
    };
}

/// Returns call site `site`'s 4096-byte scratch row, keyed by the site's MIR
/// instruction id: the formatted bytes outlive the expression that produced
/// them (a string slot is a `[]const u8` and the writer a subexpression). A
/// site whose text can be longer gets a row of its own size (`zSRow`, sized
/// by `cg_strcap`).
pub fn zSBuf(comptime site: usize) *[4096]u8 {
    const Buf = if (zs_tls) struct {
        const n = site;
        threadlocal var b: [4096]u8 = undefined;
    } else struct {
        const n = site;
        var b: [4096]u8 = undefined;
    };
    return &Buf.b;
}

/// Returns call site `site`'s row `slot` of `len` bytes: slot 0 is its text,
/// slot k + 1 the scratch of its operand k's composed field when that is too
/// wide for the stack (`cg_display.Spec.max_stack`). `zSBuf`'s terms
/// otherwise.
pub fn zSRow(comptime site: usize, comptime slot: usize, comptime len: usize) *[len]u8 {
    const Row = if (zs_tls) struct {
        const n = site;
        const k = slot;
        threadlocal var b: [len]u8 = undefined;
    } else struct {
        const n = site;
        const k = slot;
        var b: [len]u8 = undefined;
    };
    return &Row.b;
}

/// Returns `len` bytes of scratch that live for one kernel call (`zStrCat`,
/// `zStrRepeat`, `zSFormatRt`): static, so a long row makes no long frame.
/// For this group's kernels only; the next call of any of them with the same
/// `len` reuses the bytes.
pub fn zSTmp(comptime len: usize) *[len]u8 {
    const Tmp = if (zs_tls) struct {
        threadlocal var b: [len]u8 = undefined;
    } else struct {
        var b: [len]u8 = undefined;
    };
    return &Tmp.b;
}

/// Compacts completed formatter output in place, dropping its NUL bytes
/// (§3.3 string storage excludes NUL), and returns the prefix of `bytes`
/// that holds it; padding counted the original bytes. Invalidates `bytes`
/// past the returned prefix.
pub fn zStringStore(bytes: []u8) []const u8 {
    // Text almost never holds a NUL: a vectorized search proves that and
    // copies nothing. Past the first one every byte is stored and only a
    // nonzero one advances the cursor.
    var used = std.mem.findScalar(u8, bytes, 0) orelse return bytes;
    const first = used;
    for (bytes[used + 1 ..]) |byte| {
        bytes[used] = byte;
        used += @intFromBool(byte != 0);
    }
    std.debug.assert(used >= first);
    std.debug.assert(used < bytes.len);
    return bytes[0..used];
}

/// Returns a `ZStrHeldN(len)` holding a copy of `s`: a fresh value, so `s`
/// may be a slice of the field the result is stored into. Text longer than
/// the field is E1011, at compile time for an initializer.
pub fn zStrHeldN(comptime len: usize, s: []const u8) ZStrHeldN(len) {
    var h: ZStrHeldN(len) = .{};
    if (s.len > len) {
        if (@inComptime()) @compileError("error[E1011]: a held string initializer exceeds its field");
        zSOver();
    }
    @memcpy(h.b[0..s.len], s);
    h.n = @intCast(s.len);
    std.debug.assert(h.n == s.len);
    return h;
}

/// Returns `zStrHeldN` for the 4096-byte `ZStrHeld`.
pub fn zStrHeld(s: []const u8) ZStrHeld {
    return zStrHeldN(4096, s);
}

/// Returns §3.3 Table 3-3's "Concatenation of Str1,…,Strn" when a piece is
/// known only at run time, in its call site's row `buf` (a pointer to it). A
/// piece may be this site's previous result (`s = {s, "x"}`), so the bytes
/// are built in scratch first and copied once. An overrun is E1011.
pub fn zStrCat(buf: anytype, parts: []const []const u8) []const u8 {
    const tmp = zSTmp(buf.len);
    var n: usize = 0;
    for (parts) |p| {
        if (p.len > tmp.len - n) zSOver();
        @memcpy(tmp[n..][0..p.len], p);
        n += p.len;
    }
    if (n > buf.len) zSOver();
    @memcpy(buf[0..n], tmp[0..n]);
    std.debug.assert(n <= buf.len);
    return buf[0..n];
}

/// Returns §3.3 Table 3-3's replication with a run-time multiplier: "a
/// string containing N concatenated copies of Str", in `buf`. The row fixes
/// no result for a negative N (§4.2.13's "non-negative" governs a
/// constant), so N <= 0 is the empty string, as zero copies are. `zStrCat`'s
/// scratch and overrun rule.
pub fn zStrRepeat(buf: anytype, count: i64, s: []const u8) []const u8 {
    if (count <= 0 or s.len == 0) return "";
    const tmp = zSTmp(buf.len);
    if (count > tmp.len / s.len) zSOver();
    const k: usize = @intCast(count);
    std.debug.assert(k * s.len <= buf.len);
    for (0..k) |j| @memcpy(tmp[j * s.len ..][0..s.len], s);
    @memcpy(buf[0 .. k * s.len], tmp[0 .. k * s.len]);
    return buf[0 .. k * s.len];
}

/// E1011: run-time text outgrew the row its call site or held string was
/// sized for. Fatal, like `$fatal`: §9.5.3 gives no truncation rule, so
/// neither a cut nor an empty string is an answer the clause allows.
pub fn zSOver() noreturn {
    std.debug.print("error[E1011]: run-time text exceeds the row the compiler sized for it; see `vera --explain E1011`\n", .{});
    std.process.exit(1);
}

/// Returns `text` when latch `m`'s watched values differ from those it last
/// reported, else null (§9.4.1): "for each accepted step, if the variable or
/// an expression in the argument list changes value compared with the last
/// accepted step ... the entire argument list is displayed", once however
/// many changed (§9.5.2 carries it to `$fmonitor`). The emitter hands one u64
/// per watched argument (a real's or integer's bits, a string's hash) with
/// the exempt `$abstime`/`$realtime` operands left out: a rendered-line
/// comparison could not honour that exemption. The first accepted step
/// reports, and nothing reports before the statement ran (`zMonitorArm`).
/// `m` is the site's latch in the instance the display unit runs for,
/// written through the `*const Instance` the contract hands `display`, as
/// `file.zFCtx` writes the table: only the display phase writes it,
/// one call per instance at a time.
pub fn zMonitor(m: *const ZMon, vals: []const u64, text: []const u8) ?[]const u8 {
    const l: *ZMon = @constCast(m);
    if (!l.armed) return null;
    const h = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(vals));
    if (l.seen and l.h == h) return null;
    l.h = h;
    l.seen = true;
    std.debug.assert(l.seen);
    return text;
}

/// §9.4.1 "sets up a mechanism": the statement ran, so latch `m` reports at
/// the end of this accepted step and every one after it. Returns 0: the call
/// is a void task riding the display chain. Writes through `*const` as
/// `zMonitor` does.
pub fn zMonitorArm(m: *const ZMon) f64 {
    const l: *ZMon = @constCast(m);
    l.armed = true;
    std.debug.assert(m.armed);
    return 0.0;
}

/// Returns the `$fscanf` scan of `src` under `fmt`, reporting assigned item
/// `want` (-1: the count alone). "An input field is defined as a string of
/// nonspace characters; it extends to the next inappropriate character or
/// until the maximum field width, if one is specified, is exhausted", and
/// "for all descriptors except the character c, white space leading an input
/// field is ignored".
pub fn zScan(src: []const u8, fmt: []const u8, want: i64) ZScan {
    var out: ZScan = .{};
    zsScanRun(src, fmt, want, &out, false);
    return out;
}

/// Returns `zScan` under `$sscanf`'s white space: "For $sscanf, null
/// characters shall also be considered white space." `$fscanf` keeps C's set.
pub fn zScanNul(src: []const u8, fmt: []const u8, want: i64) ZScan {
    var out: ZScan = .{};
    zsScanRun(src, fmt, want, &out, true);
    return out;
}

/// Returns §9.5.4.2's count on its own.
pub fn zScanN(src: []const u8, fmt: []const u8) i64 {
    return zScan(src, fmt, -1).n;
}

/// Returns item `k` as an integer. An item the scan never reached is 0;
/// lowering guards the destination write with the count, so its prior value
/// survives.
pub fn zScanI(src: []const u8, fmt: []const u8, k: i64) i64 {
    return zScan(src, fmt, k).i;
}

/// Returns item `k` as a real; `zScanI`'s terms.
pub fn zScanR(src: []const u8, fmt: []const u8, k: i64) f64 {
    return zScan(src, fmt, k).r;
}

/// Returns item `k` as a string: a slice of `src`, valid while `src` is;
/// `zScanI`'s terms.
pub fn zScanS(src: []const u8, fmt: []const u8, k: i64) []const u8 {
    return zScan(src, fmt, k).s;
}

/// Returns `zScanN` under `$sscanf`'s white space (`zScanNul`).
pub fn zScanNulN(src: []const u8, fmt: []const u8) i64 {
    return zScanNul(src, fmt, -1).n;
}

/// Returns `zScanI` under `$sscanf`'s white space (`zScanNul`).
pub fn zScanNulI(src: []const u8, fmt: []const u8, k: i64) i64 {
    return zScanNul(src, fmt, k).i;
}

/// Returns `zScanR` under `$sscanf`'s white space (`zScanNul`).
pub fn zScanNulR(src: []const u8, fmt: []const u8, k: i64) f64 {
    return zScanNul(src, fmt, k).r;
}

/// Returns `zScanS` under `$sscanf`'s white space (`zScanNul`).
pub fn zScanNulS(src: []const u8, fmt: []const u8, k: i64) []const u8 {
    return zScanNul(src, fmt, k).s;
}

// ---- private ----

fn zsSpace(ch: u8, nul: bool) bool {
    return std.ascii.isWhitespace(ch) or (nul and ch == 0);
}

/// The walk, split out so `out.used` is written on every exit: one per
/// matching failure the clause names, each reporting where the offending
/// character was left. The control string is walked once.
fn zsScanRun(src: []const u8, fmt: []const u8, want: i64, out: *ZScan, nul: bool) void {
    var si: usize = 0;
    defer out.used = si;
    defer std.debug.assert(si <= src.len);
    var fi: usize = 0;
    var tried = false; // has any conversion started with input still available?
    var directives: usize = 0;
    while (fi < fmt.len) : (directives += 1) {
        // Each directive consumes at least one control byte.
        std.debug.assert(directives < fmt.len);
        const fc = fmt[fi];
        // White space in the control string matches any run of it, or none.
        if (zsSpace(fc, nul)) {
            fi += 1;
            while (si < src.len and zsSpace(src[si], nul)) si += 1;
            continue;
        }
        if (fc != '%') { // an ordinary character must be there
            if (si >= src.len) return zsScanEof(out, tried);
            if (src[si] != fc) return;
            si += 1;
            fi += 1;
            continue;
        }
        fi += 1;
        if (fi >= fmt.len) return;
        if (fmt[fi] == '%') { // a literal percent, matched not converted
            if (si >= src.len) return zsScanEof(out, tried);
            if (src[si] != '%') return;
            si += 1;
            fi += 1;
            continue;
        }
        const suppress = fmt[fi] == '*';
        if (suppress) fi += 1;
        // Saturating: a width past the input is the whole input, and digits
        // no usize holds must not overflow.
        var width: usize = 0;
        while (fi < fmt.len and fmt[fi] >= '0' and fmt[fi] <= '9') : (fi += 1)
            width = width *| 10 +| (fmt[fi] - '0');
        if (fi >= fmt.len) return;
        const conv = fmt[fi];
        fi += 1;
        // "%m Returns the current hierarchical path as a string. Does not
        // read data from the input file or str argument": before the white
        // space skip and the EOF test, which are properties of reading.
        if (conv == 'm') {
            if (suppress) continue;
            // ponytail: the path answers empty. A scan control string is a
            // run-time value, so the kernel has no name to reach for (the
            // display-side `%m` is the emitter's), and §9.5.4.2 fixes no
            // spelling of "the current hierarchical path". The upgrade is
            // threading the module name into the scan call.
            if (out.n == want) out.s = "";
            out.n += 1;
            continue;
        }
        if (conv != 'c') {
            while (si < src.len and zsSpace(src[si], nul)) si += 1;
        }
        if (si >= src.len) return zsScanEof(out, tried);
        tried = true;
        const lim = if (width == 0) src.len else si + @min(width, src.len - si);
        const item = zsConvert(src, si, lim, conv, width, nul) orelse return;
        std.debug.assert(item.used > si);
        std.debug.assert(item.used <= lim);
        si = item.used;
        if (suppress) continue; // "matched and assigned": consumed, not counted
        if (out.n == want) {
            out.i = item.i;
            out.r = item.r;
            out.s = item.s;
        }
        out.n += 1;
    }
}

/// One conversion `conv` of the field `src[si..lim]`, `si < lim`: the
/// item's three views and, in `used`, where it ended; null on a matching
/// failure (nothing matched, or an invalid conversion letter).
fn zsConvert(src: []const u8, si: usize, lim: usize, conv: u8, width: usize, nul: bool) ?ZScan {
    std.debug.assert(si < lim);
    std.debug.assert(lim <= src.len);
    var item: ZScan = .{};
    var end = si;
    switch (conv) {
        // "%c Matches a single character. The normal skip over white space
        // is suppressed"; a width takes that many characters.
        'c' => {
            end = if (width == 0) si + 1 else lim;
            item.i = src[si];
            item.r = @floatFromInt(item.i);
            item.s = src[si..end];
        },
        // "%s Matches a string, which is a sequence of nonwhite space
        // characters"; the int/real views are §2.7's base-256 reading.
        's' => {
            while (end < lim and !zsSpace(src[end], nul)) end += 1;
            item.s = src[si..end];
            for (item.s) |ch| item.i = item.i *% 256 +% ch;
            item.r = @floatFromInt(item.i);
        },
        // "%f, %e, or %g Matches a floating point number": sign, digits,
        // fraction, exponent, parsed by std on the matched slice so the
        // rounding is every other real literal's. "%r Matches a 'real' number
        // in engineering notation, using the scale factors defined in 2.6.2":
        // the same number and one optional Table 2-1 symbol right after it
        // ("no space is permitted between the number and the symbol").
        'f', 'e', 'g', 'r' => {
            var digits: usize = 0;
            if (end < lim and (src[end] == '+' or src[end] == '-')) end += 1;
            while (end < lim and zsDigit(src[end], 10) != null) : (end += 1) digits += 1;
            if (end < lim and src[end] == '.') {
                end += 1;
                while (end < lim and zsDigit(src[end], 10) != null) : (end += 1) digits += 1;
            }
            if (digits == 0) return null; // a sign or a dot alone
            if (end < lim and (src[end] == 'e' or src[end] == 'E')) {
                var k = end + 1;
                if (k < lim and (src[k] == '+' or src[k] == '-')) k += 1;
                if (k < lim and zsDigit(src[k], 10) != null) {
                    while (k < lim and zsDigit(src[k], 10) != null) k += 1;
                    end = k;
                }
            }
            item.r = std.fmt.parseFloat(f64, src[si..end]) catch return null;
            if (conv == 'r' and end < lim) {
                if (zsScaleOf(src[end])) |f| {
                    item.r *= f;
                    end += 1;
                }
            }
            item.s = src[si..end];
            // Saturating, like every real-to-int cast the device performs:
            // this text ships in ReleaseFast artifacts, where an unguarded
            // `@intFromFloat` of "1e300" is UB.
            item.i = std.math.lossyCast(i64, @trunc(item.r));
        },
        // "%d Matches an optionally signed decimal number, consisting of the
        // optional sign from the set + or -, followed by a sequence of
        // characters from the set 0,1,2,3,4,5,6,7,8,9, and _": the
        // underscore is §2.6.1's separator, skipped in every radix.
        'd', 'o', 'b', 'h', 'x' => {
            const radix: u8 = switch (conv) {
                'b' => 2,
                'o' => 8,
                'h', 'x' => 16,
                else => 10,
            };
            var neg = false;
            if (end < lim and (src[end] == '+' or src[end] == '-')) {
                neg = src[end] == '-';
                end += 1;
            }
            var digits: usize = 0;
            var acc: i64 = 0;
            while (end < lim) : (end += 1) {
                if (src[end] == '_') continue;
                const d = zsDigit(src[end], radix) orelse break;
                acc = acc *% radix +% d;
                digits += 1;
            }
            if (digits == 0) return null; // e.g. "%d" on "hello"
            // Wrapping, as the accumulation is: "-9223372036854775808" wraps
            // to minInt, whose plain negation overflows.
            item.i = if (neg) -%acc else acc;
            item.r = @floatFromInt(item.i);
            item.s = src[si..end];
        },
        // Not unreachable: lowering checks a format only when it folds to a
        // constant, so a run-time format arrives unchecked. §9.5.4.2 makes an
        // invalid conversion character "implementation dependent"; this
        // stops the scan, reporting the items assigned so far.
        else => return null,
    }
    if (end == si) return null; // nothing matched
    item.used = end;
    return item;
}

/// "This number can be EOF if the input ends before the first matching
/// failure or conversion": input that ran out before any conversion was
/// tried and any item assigned (whether a conversion or a literal found it
/// gone, C11 7.21.6.2p16's input failure); input that ran out after an
/// assignment reports the assignments.
fn zsScanEof(out: *ZScan, tried: bool) void {
    std.debug.assert(out.n >= 0);
    if (!tried and out.n == 0) out.n = -1;
}

/// §2.6.2 Table 2-1's scale factor for one symbol, or null. The 1e3 row is
/// spelled "K, k", so a scanner takes both, which is why no fixture may pin
/// which of the two an output prints.
fn zsScaleOf(c: u8) ?f64 {
    return switch (c) {
        'T' => 1e12,
        'G' => 1e9,
        'M' => 1e6,
        'K', 'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        'a' => 1e-18,
        else => null,
    };
}

/// The value of `c` as a digit in `radix`, or null when it is not one.
fn zsDigit(c: u8, radix: u8) ?u8 {
    // ponytail: keep the existing hex-digit ceiling even for a larger radix.
    const d = std.fmt.charToDigit(c, @min(radix, 16)) catch return null;
    std.debug.assert(d < radix);
    return d;
}
