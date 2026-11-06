#!/bin/bash
# formal/regbus/mutate.sh: the prove task must FAIL on each injected bug (guards against a
# vacuous proof).  Each mutant is a bsc build of src/AXI4_RegBus.bsv (~15 s).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
bad=0
for m in lostack wdog zerostb; do
    mkdir -p "$W/$m/src"; cp "$ROOT/src/AXI4_RegBus.bsv" "$W/$m/src/"
    f="$W/$m/src/AXI4_RegBus.bsv"
    case $m in
        lostack) perl -0pi -e 's/ && slave_xactor\.i_(wr_resp|rd_data)\.notFull//g' "$f" ;;   # the bug formal found
        wdog)    perl -0pi -e "s/\(rg_wdog == '1\)/(rg_wdog == 8'd7)/" "$f" ;;                    # request dropped early
        zerostb) perl -0pi -e 's/if \(stb == 0\)/if (False)/' "$f" ;;                              # zero-strobe write on the bus
    esac
    if cmp -s "$f" "$ROOT/src/AXI4_RegBus.bsv"; then echo "$m: mutation did not apply"; bad=1; continue; fi
    make -C "$ROOT" -s formal-regbus-verilog BUILD="$W/$m/build" REGBUS_SRC="$f" >/dev/null 2>&1 \
        || { echo "$m: build failed"; bad=1; continue; }
    sed -e "s#../../build/formal-regbus/v/mkAXI4_RegBus.v#$W/$m/build/formal-regbus/v/mkAXI4_RegBus.v#" \
        -e "s#../../build/formal-regbus-short/#$W/$m/build/formal-regbus-short/#" \
        "$HERE/regbus.sby" > "$W/$m/m.sby"
    cp "$HERE/regbus_fv.sv" "$W/$m/"
    (cd "$W/$m" && sby -f m.sby prove > /dev/null 2>&1)
    r=$(grep -o 'DONE ([A-Z]*' "$W/$m/m_prove/logfile.txt" | tr -d '(' | awk '{print $2}')
    echo "$m: prove $r (want FAIL)"; [ "$r" = FAIL ] || bad=1
done
exit $bad
