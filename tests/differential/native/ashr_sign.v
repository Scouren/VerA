// A minimal signed `>>>` on a value with its sign bit set, narrower than 64
// bits, assigned (not just a $display argument: a call's argument is the
// interpreter's regardless, so it never reaches a compiled prong): oracle-set
// hole found while verifying the P3 planted fault (the generator's randomly
// mixed-sign operands rarely land a compiled, signed, narrow ashr).
// diff-native's oracle is the interpreter (VERA_INTERPRET=1).
module ashr_sign;
  reg signed [7:0] x;
  reg signed [7:0] y, z;
  initial begin
    x = -8; // 8'sb1111_1000: the sign bit must survive the shift.
    y = x >>> 2;
    z = x >>> 9; // past the width: every bit the sign.
    $display("%b %b", y, z);
    $finish(0);
  end
endmodule
