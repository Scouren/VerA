"""Synthetic Verilog-A models for scaling measurements.

wide N:  one module, N parameters and N intermediate reals in MOSFET-like
         chains (exp, log, sqrt, conditionals) over V(g,s) and V(d,s), with
         a drain current and a gate charge: the shape of a compact model.
inst K:  a top module instantiating K copies of a 12-line child, to see how
         elaboration and lowering scale with instance count.
"""
import sys, os

HEAD = '`include "disciplines.vams"\n`include "constants.vams"\n'


def wide(n):
    out = [HEAD, "module wide(d, g, s);", "  inout d, g, s;", "  electrical d, g, s;"]
    for i in range(n):
        out.append(f"  parameter real p{i} = {1.0 + (i % 7) * 0.125:.3f} from (0:inf);")
    out.append("  real vgs, vds, " + ", ".join(f"t{i}" for i in range(n)) + ";")
    out.append("  real id, qg;")
    out.append("  analog begin")
    out.append("    vgs = V(g, s);")
    out.append("    vds = V(d, s);")
    for i in range(n):
        prev = f"t{i - 1}" if i else "vgs"
        k = i % 6
        if k == 0:
            e = f"p{i} * ln(1.0 + exp(({prev} - 0.4) / (p{i} * 0.0259)))"
        elif k == 1:
            e = f"{prev} * p{i} / (1.0 + abs(vds) * 0.1)"
        elif k == 2:
            e = f"sqrt({prev} * {prev} + p{i} * 1e-3)"
        elif k == 3:
            e = f"({prev} > p{i} * 0.1) ? ({prev} - p{i} * 0.1) : (p{i} * 1e-3 * exp({prev}))"
        elif k == 4:
            e = f"{prev} * (1.0 + p{i} * 1e-2 * vds) / (1.0 + p{i} * 1e-2 * {prev})"
        else:
            e = f"tanh({prev} * p{i} * 0.5) + 1e-6 * {prev}"
        out.append(f"    t{i} = {e};")
    out.append(f"    id = t{n - 1} * vds / (1.0 + abs(vds));")
    out.append(f"    qg = 1e-15 * (vgs + t{n // 2});")
    out.append("    I(d, s) <+ id;")
    out.append("    I(g, s) <+ ddt(qg);")
    out.append("  end")
    out.append("endmodule")
    return "\n".join(out) + "\n"


def inst(k):
    out = [HEAD, "module ucell(a, b);", "  inout a, b;", "  electrical a, b;",
           "  parameter real r = 1k from (0:inf);", "  parameter real is = 1e-14 from (0:inf);",
           "  real v, i1, i2, i3;", "  analog begin", "    v = V(a, b);"]
    out.append("    i1 = is * (limexp(v / 0.0259) - 1.0);")
    out.append("    i2 = (v > 0.7) ? (v - 0.7) / r : 0.0;")
    out.append("    i3 = v / r + 1e-12 * v * v * v;")
    out.append("    I(a, b) <+ i1 + i2 + i3;")
    out.append("    I(a, b) <+ ddt(1e-15 * v);")
    out.append("  end")
    out.append("endmodule")
    out.append("module top(n0, gnd);")
    out.append("  inout n0, gnd;")
    out.append("  electrical gnd;")
    out.append("  electrical " + ", ".join(f"n{i}" for i in range(k + 1)) + ";")
    for i in range(k):
        out.append(f"  ucell #(.r({1000 + i})) c{i}(n{i}, n{i + 1});")
    out.append(f"  ucell #(.r(50)) cend(n{k}, gnd);")
    out.append("endmodule")
    return "\n".join(x for x in out if x is not None) + "\n"


if __name__ == "__main__":
    kind, n, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    open(path, "w").write(wide(n) if kind == "wide" else inst(n))
