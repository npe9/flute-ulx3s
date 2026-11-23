#!/bin/bash
# sim/vdp_ut/mutants.sh: each mutant of src/Vdp.v must FAIL the bench (it checks the bench sees
# every feature).  Prints caught / MISSED per mutant.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; cd "$HERE"
m() {   # name, python regex, replacement
  python3 - "$ROOT/src/Vdp.v" "mut/$1.v" "$2" "$3" <<'PY'
import sys,re
s=open(sys.argv[1]).read(); n=re.subn(sys.argv[3],sys.argv[4],s,count=1)
if n[1]!=1: sys.exit('no match: '+sys.argv[3])
open(sys.argv[2],'w').write(n[0])
PY
  [ $? -eq 0 ] || { echo "$1: BAD MUTANT"; return; }
  rm -rf mut/obj_$1
  verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH --top-module vdp_tb -Mdir mut/obj_$1 \
     mut/$1.v vdp_tb.v tb.cpp "$ROOT/sw/vdp/vdp_ref.c" -CFLAGS "-O2 -I$ROOT/sw/vdp" > mut/$1.build 2>&1 || { echo "$1: BUILD FAIL"; return; }
  if ./mut/obj_$1/Vvdp_tb > mut/$1.out 2>&1; then echo "$1: MISSED"; else echo "$1: caught ($(grep -c '^FAIL' mut/$1.out) failing checks)"; fi
}
m bg_vflip2   "b_e\[15\] \? 3'd7 - bpy1 : bpy1"            "bpy1"
m bg_hflip    "bcol2  <= b_e\[14\] \? 3'd7 - bpx1 : bpx1"  "bcol2  <= bpx1"
m bg_half     "bhalf1 <= b_px\[3\]"                         "bhalf1 <= 1'b0"
m scroll_y    "wire \[7:0\] b_py = ln \+ c_sy"              "wire [7:0] b_py = ln"
m bg_enable   "if \(!c_ctrl\[0\]\) n = 4'd0;"               ""
m bank        "\{ 1'b1, bbank2, n \}"                       "{ 1'b1, 4'd0, n }"
m spr_hflip   "nb = d_a\[14\] \? 3'd7 - d_i2\[2:0\] : d_i2\[2:0\]" "nb = d_i2[2:0]"
m spr_vflip   "d_a\[15\] \? 4'd15 - d_j : d_j"              "d_j"
m spr_behind  "if \(!\(pbehind1 && q\[8\]\)\) begin"        "if (1) begin"
m spr_limit   "if \(ln_n < 5'd16\)"                         "if (ln_n < 5'd15)"
m spr_order   "d_x <= l_x\[ln_n - 1\]; d_j <= l_j\[ln_n - 1\]; d_a <= l_a\[ln_n - 1\];" "d_x <= l_x[0]; d_j <= l_j[0]; d_a <= l_a[0];"
# equivalent: columns 320-511 of the line buffer are never shown
# m spr_xclip   "\(rd_x < 9'd320\)"                           "1'b1"
m spr_enable  "if \(e_w1\[16\] && j < 9'd16\)"              "if (j < 9'd16)"
m backdrop    "idx <= \(q\[7:0\] == 8'd0\) \? bd1 : q\[7:0\]" "idx <= q[7:0]"
m ovf_flag    "if \(ovf_line\) ov_t <= ~ov_t;"              ""
m snap_late   "scan_hc == 10'd784"                          "scan_hc == 10'd2"
m rd_byte     "if \(win_map && be\[0\]\) map0"              "if (win_map && be[1]) map0"
