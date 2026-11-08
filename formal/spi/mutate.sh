#!/bin/bash
# formal/spi/mutate.sh: each injected bug must give a real bmc counterexample (FAIL), and the
# unbounded proof that covers it must stop passing (guards against vacuous proofs; a k-induction
# failure with no base-case counterexample reports UNKNOWN, which also counts).
# Each mutant is a bsc build of src/AXI4_SPI.bsv.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
bad=0
for m in hold flashcs txfull pha1bit rxbit txslot rxptr; do
    mkdir -p "$W/$m/src"; cp "$ROOT/src/AXI4_SPI.bsv" "$W/$m/src/"
    f="$W/$m/src/AXI4_SPI.bsv"
    case $m in
        hold)    perl -0pi -e 's/if \(w != rg_csid\)/if (True)/' "$f" ;;                         # same-value CSID releases HOLD
        flashcs) perl -0pi -e 's/\(active && cs_sel1\) \? 0 : 1/active ? 0 : 1/' "$f" ;;          # flash selected during SD traffic
        pha1bit) perl -0pi -e 's/(else begin\n\s*mosi = rg_sh_tx) \[7\]/$1 [6]/' "$f" ;;          # CPHA=1 sends the wrong bit
        rxbit)   perl -0pi -e 's/if \(capture\) sh_rx = \{ sh_rx \[6:0\], miso_q \}/if (capture) sh_rx = { sh_rx [6:0], ~ miso_q }/' "$f" ;;   # RX capture wrong
        txslot)  perl -0pi -e 's/v_tx \[rg_tx_wp \[2:0\]\] <= w/v_tx [rg_tx_wp [2:0] + 1] <= w/' "$f" ;;        # TX byte in the wrong slot
        rxptr)   perl -0pi -e 's/rg_rx_rp <= rg_rx_rp \+ 1/rg_rx_rp <= rg_rx_rp + 2/' "$f" ;;                  # RXDATA skips an entry
        txfull)  perl -0pi -e "s/'h48: if \(tx_level != 8\)/'h48: if (True)/" "$f" ;;             # TX FIFO overfill
    esac
    if cmp -s "$f" "$ROOT/src/AXI4_SPI.bsv"; then echo "$m: mutation did not apply"; bad=1; continue; fi
    make -C "$ROOT" -s formal-spi-verilog BUILD="$W/$m/build" SPI_SRC="$f" >/dev/null 2>&1 \
        || { echo "$m: build failed"; bad=1; continue; }
    sed -e "s#../../build/formal-spi/v/mkAXI4_SPI.v#$W/$m/build/formal-spi/v/mkAXI4_SPI.v#" \
        "$HERE/spi.sby" > "$W/$m/m.sby"
    cp "$HERE/spi_fv.sv" "$W/$m/"
    (cd "$W/$m" && sby -f m.sby bmc > /dev/null 2>&1)
    r=$(grep -o 'DONE ([A-Z]*' "$W/$m/m_bmc/logfile.txt" | tr -d '(' | awk '{print $2}')
    echo "$m: bmc $r (want FAIL)"; [ "$r" = FAIL ] || bad=1
    case $m in hold|flashcs|txfull) t=prove_ctl ;; *) t=prove_k ;; esac
    (cd "$W/$m" && sby -f m.sby $t > /dev/null 2>&1)
    r=$(grep -o 'DONE ([A-Z]*' "$W/$m/m_$t/logfile.txt" | tr -d '(' | awk '{print $2}')
    echo "$m: $t $r (want not PASS)"; [ "$r" != PASS ] || bad=1
done
exit $bad
