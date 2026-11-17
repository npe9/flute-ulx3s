#!/bin/bash
# Equivalence: dvi_ser (src/Video_DVI.v) == dvi_ser_ref.v (the pre-lx49 serializer with one shared
# load decode), cycle for cycle from the power-up values, for every ptog / tmds_* sequence.
# ODDRX1F is replaced by Q = SCLK ? D1 : D0 with SCLK left free each step, so both DDR bits of every
# lane are compared.  k-induction (sat -tempinduct); prints PASS or FAIL.
D=$(cd "$(dirname "$0")" && pwd); R=$(cd "$D/../.." && pwd); T=$(mktemp -d)
awk '/^module dvi_ser \(/{f=1} f{print} f&&/^endmodule/{exit}' "$R/src/Video_DVI.v" > "$T/impl.v"
cat > "$T/oddr.v" <<'V'
module ODDRX1F (input wire D0, input wire D1, input wire SCLK, input wire RST, output wire Q);
    assign Q = SCLK ? D1 : D0;
endmodule
V
yosys -q -l "$T/y.log" -p "
read_verilog $T/oddr.v; read_verilog $D/dvi_ser_ref.v; read_verilog $T/impl.v
prep; flatten; opt_clean
miter -equiv -flatten -make_outputs dvi_ser_ref dvi_ser miter
hierarchy -top miter; opt_clean
sat -verify -tempinduct -prove trigger 0 -set-init-zero -maxsteps 16 miter" > /dev/null 2>&1
rc=$?; grep -E "Induction step proven|SUCCESS|failed|FAIL" "$T/y.log" | tail -2
[ $rc = 0 ] && echo "dvi_ser equiv: PASS" || echo "dvi_ser equiv: FAIL (log $T/y.log)"
exit $rc
