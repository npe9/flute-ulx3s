#!/bin/bash
# formal/board_io/mutate.sh: each injected bug must stop the proof (FAIL, or UNKNOWN: induction fails
# with no base-case counterexample), and the unmutated proof must pass first.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; bad=0
run() { d=$1; (cd "$d" && timeout "${MUT_LIMIT:-300}" sby -f board_io.sby prove >/dev/null 2>&1)
        LC_ALL=C grep -o 'DONE ([A-Z]*' "$d/board_io_prove/logfile.txt" | tr -d '(' | awk '{print $2}'; }
mkdir -p "$W/base/s"; cp "$HERE/../../src/Board_IO.v" "$HERE/board_io_fv.sv" "$W/base/"
sed 's#\.\./\.\./src/Board_IO.v#Board_IO.v#' "$HERE/board_io.sby" > "$W/base/board_io.sby"
r=$(run "$W/base"); echo "baseline: ${r:-TIMEOUT}"; [ "$r" = PASS ] || exit 1
for m in ${MUT_ONLY:-msbfirst sdachange stopslow ackstuck noreset rxlost pwrpol done enreset enaddr anypoff partpoff reconfaddr etxsync strapreset strapbit}; do
    d="$W/$m"; mkdir -p "$d"; cp "$W/base/board_io_fv.sv" "$W/base/board_io.sby" "$W/base/Board_IO.v" "$d/"; f="$d/Board_IO.v"
    case $m in
        msbfirst)  perl -pi -e 's/\(c_wr \? shift\[7\] : 1.b1\)/(c_wr ? shift[0] : 1\x27b1)/' "$f" ;;   # LSB first
        sdachange) perl -0pi -e "s/3'd0: scl_low <= 1'b1;\n                        3'd1: sda_low <= !tx_bit;/3'd0: begin scl_low <= 1'b1; sda_low <= !tx_bit; end\n                        3'd3: sda_low <= !tx_bit;/" "$f" ;;   # data moves with SCL high
        stopslow)  perl -0pi -e "s/sda_low <= 1'b0;        \/\/ the STOP: data rises with SCL high\n                            finish;/finish;/" "$f" ;;   # never releases SDA after STOP
        ackstuck)  perl -pi -e 's/if \(c_rd\) rxr <= \{shift\[6:0\], sda_s\};/if (c_rd) rxr <= shift;/' "$f" ;;   # read byte off by one
        noreset)   perl -pi -e "s/if \(rst \|\| !en\) begin/if (rst) begin/" "$f" ;;   # EN=0 no longer abandons
        rxlost)    perl -0pi -e "s/\(ph == 3'd3 && !scl_s\)/(ph == 3'd3 \&\& !scl_s \&\& 1'b0)/" "$f" ;;   # ignores stretching: samples early
        pwrpol)    perl -pi -e 's/\{btn_m\[6:1\], ~btn_m\[0\]\}/btn_m/' "$f" ;;   # power button polarity
        enreset)   perl -0pi -e "s/            esp32_en <= 1'b0;\n//" "$f" ;;   # ESP32 EN not cleared by reset
        enaddr)    perl -pi -e "s/sel_gpio && rb_addr\[4:2\] == 3'd3 && rb_wstrb\[0\]\)/sel_gpio \&\& rb_wstrb[0])/" "$f" ;;   # any gpio1 write moves EN
        anypoff)   perl -pi -e "s/ && rb_wdata == 32'h504F4646\)/)/" "$f" ;;   # any POWER write shuts down
        partpoff)  perl -pi -e "s/rb_addr\[4:2\] == 3'd4 && rb_wstrb == 4'hF/rb_addr[4:2] == 3'd4 \&\& rb_wstrb[0]/" "$f" ;;   # one byte lane enough
        reconfaddr) perl -pi -e "s/rb_addr\[4:2\] == 3'd5 && rb_wstrb == 4'hF/rb_wstrb == 4'hF/" "$f" ;;   # RECF at any gpio1 address
        etxsync)   perl -pi -e "s/esp32_strap, etx_m\[1\], esp32_en/esp32_strap, etx_m[0], esp32_en/" "$f" ;;   # TX level through one flop
        strapreset) perl -0pi -e "s/            esp32_strap <= 1'b0;\n//" "$f" ;;   # STRAP not cleared by reset
        strapbit)  perl -pi -e "s/esp32_strap <= rb_wdata\[2\]/esp32_strap <= rb_wdata[1]/" "$f" ;;   # STRAP from the wrong bit
        done)      perl -0pi -e "s/tip      <= 1'b0;\n            irq_flag <= 1'b1;/irq_flag <= 1'b1;/" "$f" ;;   # TIP never clears
    esac
    if cmp -s "$f" "$W/base/Board_IO.v"; then echo "$m: mutation did not apply"; bad=1; continue; fi
    r=$(run "$d"); s=$(LC_ALL=C grep -m1 -E 'failed assertion' "$d/board_io_prove/logfile.txt" | LC_ALL=C grep -o 'board_io_fv.sv:[0-9]*' | head -1)
    echo "$m: ${r:-TIMEOUT} $s"; case "$r" in FAIL|UNKNOWN) ;; *) bad=1 ;; esac
done
exit $bad
