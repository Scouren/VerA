#!/usr/bin/env bash
# tools/bench_exe.sh N [BEFORE]: a `.v --emit-exe` binary's run time, old
# `vera` (its native codegen) against this tree's `vera-next` (std_sim's
# interpreter), and BEFORE, another `vera-next`, when given. Each binary is
# built ReleaseFast; the time is the median of N wall-clock runs. Every
# binary's stdout must equal old vera's, or the row says so.
# The designs: zig-out/bench/{lfsr,cpu}.v (written below), and four from the
# corpus with their test loops lengthened and their dumps and per-step
# prints removed: ivtest's pic.v (a PIC16C5x CPU running TEST9.ROM), the
# iverilog example des.v (a 16-round DES pipeline), ivtest's mult16.v and
# div16.v (sequential multiplier and divider).
# Run inside `nix develop`, from the repository root, after
# `zig build install vera-next`.
set -u
N=${1:-5}
BEFORE=${2:-}
R=$(pwd)
B=$R/zig-out/bench
C=$R/tests/conformance/external/iverilog
mkdir -p "$B/contrib" "$B/w"
cat > "$B/lfsr.v" <<'EOF'
// A clocked 64-bit LFSR, a 32-bit counter and an accumulator, 2,000,000
// cycles; one line at the end.
`timescale 1ns/1ps
module lfsr_bench;
  reg clk = 0;
  reg [63:0] lfsr = 64'h1;
  reg [31:0] count = 0;
  reg [63:0] acc = 0;
  always #1 clk = ~clk;
  always @(posedge clk) begin
    lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};
    count <= count + 1;
    acc <= acc + (lfsr ^ {32'b0, count});
  end
  initial begin
    #4000000;
    $display("%h %h %0d", lfsr, acc, count);
    $finish(0);
  end
endmodule
EOF
cat > "$B/cpu.v" <<'EOF'
// A small accumulator CPU (case decode, a 256-word memory, a combinational
// ALU through continuous assigns) running a loop program, 1,000,000 clock
// cycles; one line at the end.
`timescale 1ns/1ps
module alu(input [7:0] op, input [31:0] a, input [31:0] b, output [31:0] y);
  assign y = op == 0 ? a + b : op == 1 ? a - b : op == 2 ? a ^ b : op == 3 ? (a << 1) | (a >> 31) : a & b;
endmodule

module cpu_bench;
  reg clk = 0;
  reg [31:0] mem [0:255];
  reg [7:0] pc = 0;
  reg [31:0] acc = 1, x = 7;
  reg [31:0] ir;
  wire [31:0] y;
  integer i, cycles = 0;
  alu u(.op(ir[31:24]), .a(acc), .b(x), .y(y));
  always #1 clk = ~clk;
  initial for (i = 0; i < 256; i = i + 1) mem[i] = {i[7:0] % 8'd5, 16'b0, i[7:0]};
  always @(posedge clk) begin
    ir <= mem[pc];
    case (ir[31:24])
      0, 1, 2, 3: acc <= y;
      default: x <= x + acc;
    endcase
    mem[pc] <= mem[pc] + acc;
    pc <= pc + 1;
    cycles <= cycles + 1;
  end
  initial begin
    #2000000;
    $display("%h %h %0d", acc, x, cycles);
    $finish(0);
  end
endmodule
EOF
cp "$C/ivtest/contrib/TEST9.ROM" "$B/contrib/"
sed -e 's/dbg_maxcycles = 2000;/dbg_maxcycles = 200000;/' -e 's/dbg_showport\([bc]\) = 1;/dbg_showport\1 = 0;/' \
  "$C/ivtest/contrib/pic.v" > "$B/pic.v"
sed -e 's/i<16;/i<4000;/' -e '/\$dump/d' "$C/examples/des.v" > "$B/des.v"
sed -e 's/MAX_TRIALS = 10;/MAX_TRIALS = 20000;/' -e 's/\$display ("%0d \* %0d/if (0) $display ("%0d * %0d/' \
  "$C/ivtest/contrib/mult16.v" > "$B/mult16.v"
sed -e 's/repeat (25)/repeat (4000)/' "$C/ivtest/contrib/div16.v" > "$B/div16.v"

med() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
build() { "$1" --emit-exe --optimize=ReleaseFast --work-dir "$B/w/$2" "$3" 2>/dev/null | tail -1; }
# stdout without the `$finish at` line, whose byte offset old vera counts differently.
out() { grep -v "^\$finish at" | md5sum; }
timeit() { for _ in $(seq "$N"); do /usr/bin/env time -f %e "$1" 2>&1 >/dev/null | tail -1; done | med; }
cd "$B"
for s in lfsr cpu pic des mult16 div16; do
  old=$(build "$R/zig-out/bin/vera" old "$s.v")
  new=$(build "$R/zig-out/bin/vera-next" new "$s.v")
  [ -x "$old" ] && [ -x "$new" ] || { echo "$s: build failed (old '$old', new '$new')"; continue; }
  o=$("$old" 2>/dev/null | out)
  [ "$o" = "$("$new" 2>/dev/null | out)" ] || echo "$s: new stdout differs from old"
  line="$s: old native $(timeit "$old")s, interpreted $(timeit "$new")s"
  if [ -n "$BEFORE" ]; then
    before=$(build "$BEFORE" before "$s.v")
    [ "$o" = "$("$before" 2>/dev/null | out)" ] || echo "$s: before stdout differs from old"
    line="$line, before $(timeit "$before")s"
  fi
  echo "$line (median of $N)"
done
