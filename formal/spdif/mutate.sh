#!/bin/bash
# formal/spdif/mutate.sh: each injected bug must stop the proof (FAIL, or UNKNOWN: induction fails
# with no base-case counterexample), and the unmutated proof must pass first.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; bad=0
run() { d=$1; (cd "$d" && timeout "${MUT_LIMIT:-600}" sby -f spdif.sby prove >/dev/null 2>&1)
        LC_ALL=C grep -o 'DONE ([A-Z]*' "$d/spdif_prove/logfile.txt" | tr -d '(' | awk '{print $2}'; }
mkdir -p "$W/base"; cp "$HERE/../../src/Spdif_Tx.v" "$HERE/spdif_fv.sv" "$W/base/"
sed 's#\.\./\.\./src/Spdif_Tx.v#Spdif_Tx.v#' "$HERE/spdif.sby" > "$W/base/spdif.sby"
r=$(run "$W/base"); echo "baseline: ${r:-TIMEOUT}"; [ "$r" = PASS ] || exit 1
for m in ${MUT_ONLY:-nomid noslot parodd prebm prenoinv msbfirst cells127 block193 cstat vbit nolatch}; do
    d="$W/$m"; mkdir -p "$d"; cp "$W/base/Spdif_Tx.v" "$W/base/spdif_fv.sv" "$W/base/spdif.sby" "$d/"; f="$d/Spdif_Tx.v"
    case $m in
        nomid)    perl -pi -e 's/else               lvl = bt \? !o : o;/else               lvl = o;/' "$f" ;;   # a 1 has no mid-slot change
        noslot)   perl -pi -e 's/else if \(!n\[0\]\)    lvl = !o;/else if (!n[0])    lvl = o;/' "$f" ;;   # no change at slot start
        parodd)   perl -pi -e 's/bt = \(s == 5.d31\) \? pr :/bt = (s == 5\x27d31) ? !pr :/' "$f" ;;   # odd parity
        prebm)    perl -pi -e "s/\(first \? 8'b11101000 : 8'b11100010\)/(first ? 8'b11100010 : 8'b11101000)/" "$f" ;;   # B and M swapped
        prenoinv) perl -pi -e 's/lvl = pre \(n\[2:0\], n\[6\], fr == 8.d0\) \^ b;/lvl = pre (n[2:0], n[6], fr == 8\x27d0);/' "$f" ;;   # preamble ignores the level before it
        msbfirst) perl -pi -e "s/v\[s - 5'd12\]/v[5'd27 - s]/" "$f" ;;   # audio MSB first
        cells127) perl -pi -e "s/18'd128;/18'd127;/" "$f" ;;   # 127 cells per period
        block193) perl -pi -e "s/\(frame == 8'd191\) \? 8'd0/(frame == 8'd192) ? 8'd0/" "$f" ;;   # 193-frame block
        cstat)    perl -pi -e "s/frame <= 8'd27\) \? sfreq/frame <= 8'd26) ? sfreq/" "$f" ;;   # SFREQ bit 3 lost
        vbit)     perl -pi -e "s/\(s == 5'd30\)               \? c : 1'b0;/(s == 5'd30) ? c : (s == 5'd28);/" "$f" ;;   # V = 1 (invalid)
        nolatch)  perl -pi -e 's/l_q   <= left;/l_q   <= l_q;/' "$f" ;;   # left sample never latched
    esac
    if cmp -s "$f" "$W/base/Spdif_Tx.v"; then echo "$m: mutation did not apply"; bad=1; continue; fi
    r=$(run "$d"); s=$(LC_ALL=C grep -m1 -E 'failed assertion' "$d/spdif_prove/logfile.txt" | LC_ALL=C grep -o 'spdif_fv.sv:[0-9]*' | head -1)
    echo "$m: ${r:-TIMEOUT} $s"; case "$r" in FAIL|UNKNOWN) ;; *) bad=1 ;; esac
done
exit $bad
