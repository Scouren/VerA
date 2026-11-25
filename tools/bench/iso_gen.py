"""iso_gen.py N OUT.va: a module of N independent, isomorphic branches (smoothing, an exp diode, a resistor).
The friendliest input a superword vectorizer could ask for; iso_asm.py reports what the backend made of it."""
import sys
n = int(sys.argv[1]); out = sys.argv[2]
ports = ", ".join(f"a{i}, c{i}" for i in range(1, n + 1))
L = ['`include "disciplines.vams"', '`include "constants.vams"', f"module iso{n}({ports});", f"  inout {ports};", f"  electrical {ports};"]
for i in range(1, n + 1):
    L.append(f"  parameter real is{i} = {i}e-14 from (0:inf);")
for i in range(1, n + 1):
    L.append(f"  parameter real n{i} = {1 + 0.001 * i:.3f} from (0:inf);")
for i in range(1, n + 1):
    L.append(f"  parameter real r{i} = {1000 + i} from (0:inf);")
L.append("  real " + ", ".join(f"v{i}, s{i}, i{i}" for i in range(1, n + 1)) + ";")
L.append("  analog begin")
for i in range(1, n + 1): L.append(f"    v{i} = V(a{i}, c{i});")
for i in range(1, n + 1): L.append(f"    s{i} = 0.5 * (v{i} + sqrt(v{i} * v{i} + 1e-4));")
for i in range(1, n + 1): L.append(f"    i{i} = is{i} * (exp(s{i} / (n{i} * 0.0259)) - 1.0) + v{i} / r{i} + s{i} * s{i} / (r{i} * (1.0 + s{i}));")
for i in range(1, n + 1): L.append(f"    I(a{i}, c{i}) <+ i{i};")
L += ["  end", "endmodule", ""]
open(out, "w").write("\n".join(L))
