#!/bin/bash
# sim/apu_ut/mutants.sh: each mutant of src/Apu.v must FAIL the bench (it checks the bench sees
# every feature).  Prints caught / MISSED per mutant.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; cd "$HERE"; mkdir -p mut
m() {   # name, python regex, replacement
  python3 - "$ROOT/src/Apu.v" "mut/$1.v" "$2" "$3" <<'PY'
import sys,re
s=open(sys.argv[1]).read(); n=re.subn(sys.argv[3],sys.argv[4],s,count=1)
if n[1]!=1: sys.exit('no match: '+sys.argv[3])
open(sys.argv[2],'w').write(n[0])
PY
  [ $? -eq 0 ] || { echo "$1: BAD MUTANT"; return; }
  rm -rf mut/obj_$1
  verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH --top-module apu -Mdir mut/obj_$1 \
     mut/$1.v tb.cpp "$ROOT/sw/apu/apu_ref.c" -CFLAGS "-O2 -I$ROOT/sw/apu" > mut/$1.build 2>&1 || { echo "$1: BUILD FAIL"; return; }
  if ./mut/obj_$1/Vapu > mut/$1.out 2>&1; then echo "$1: MISSED"; else echo "$1: caught ($(grep -c '^FAIL' mut/$1.out) failing lines)"; fi
}
m duty      "c_step < 5'd4\)"                          "c_step < 5'd5)"
m tri       "4'd15 - c_step\[3:0\]"                    "c_step[3:0]"
m noisefb   "l\[0\] \^ \(sh \? l\[6\] : l\[1\]\)"       "l[0] ^ l[1]"
m noisen    "\(t_n == 3'd3\) \? t_l3 : t_l4"            "t_l3"
m sstart    "wv_ra = r_start \+ c_p\[26:12\];"          "wv_ra = c_p[26:12];"
# equivalent: the saved position of a voice that stops is never seen again (KEYON clears it)
# m sloop     "\(s_past && r_mode\[9\]\)"                  "(s_past)"
m sstop     "wire        s_stop = \(c_m == 3'd4\) && s_past && !r_mode\[9\];" "wire        s_stop = 1'b0;"
m sendcmp   "s_a >= \{ 1'b0, r_end \}"                  "s_a > { 1'b0, r_end }"
m attack    "e_up >= 17'h0FFFF"                         "e_up >= 17'h0FF00"
m decay     "<= \{ e_S, 8'b0 \}\) begin"                "< { e_S, 8'b0 }) begin"
m release   "c_e <= \{ 8'b0, e_R \}"                    "c_e < { 8'b0, e_R }"
m dzero     "if \(e_D == 0\) n_s = ST_SUSTAIN;"         "if (e_D == 0) n_s = ST_DECAY;"
m level     "c_e\[15:8\]\}\);"                           "c_e[14:7]});"
m volr      "r_vol\[15:8\]\}\);"                         "r_vol[7:0]});"
m stopzero  "ve\[v\] <= 16'd0; end"                     "end"
m sat       "sat16 = \(x > 28'sd32767\) \? 16'sh7FFF : \(x < -28'sd32768\) \? 16'sh8000 : x\[15:0\];" "sat16 = x[15:0];"
m mshift    "sat16 \(mix_l >>> 6\)"                      "sat16 (mix_l >>> 7)"
m ctrlgate  "out_l <= ctrl \?"                           "out_l <= 1'b1 ?"
# equivalent: KEYOFF of a stopped voice sends it to release with E = 0, which outputs 0 and stops
# it in that tick; the phase and LFSR it moves are reset by the next KEYON (only an ENV read inside
# that tick's busy clocks could see stage 4: sw/apu/apu.h does not order ENV reads within a tick)
# m keyoff    "if \(d_d\[i\] && vs\[i\] != ST_OFF\) vs\[i\] <= ST_RELEASE;" "if (d_d[i]) vs[i] <= ST_RELEASE;"
m keyonlf   "vs\[i\] <= ST_ATTACK; vl\[i\] <= 15'd1;"   "vs[i] <= ST_ATTACK;"
m wavelane  "if \(deq && d_wave && d_s\[1\]\) wv1"        "if (deq && d_wave && d_s[0]) wv1"
m drain1    "if \(dn == 11'd1\) st <= S_VOICE;"         "if (dn == 11'd2) st <= S_VOICE;"
m snapshot  "dn <= level; dph <= 1'b0;"                 "dn <= level + (enq ? 11'd1 : 11'd0); dph <= 1'b0;"
m shmask    "rb_rdata <= sh_q & 32'h0000_0337;"         "rb_rdata <= sh_q;"
m master    "master_sh <= rb_wdata\[7:0\];"             "master_sh <= rb_wdata[8:1];"
