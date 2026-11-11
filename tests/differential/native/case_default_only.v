// A.6.7: a `case` with only a bare `default` (no other arms) compiles the
// scrutinee but never compares it (zero labels), which once left `v`
// unused in the generated Zig and refused to compile (grammar_nullable_
// statement.v, IEEE/AMS A.6.3/.6/.7, exit status old 0 new 1). Both the
// unadorned and the colon-qualified `default:` forms, each alone.
module case_default_only;
  integer value;
  initial begin
    value = 3;
    case (1) default ; endcase
    case (1) default: ; endcase
    $display("%0d", value);
    $finish(0);
  end
endmodule
