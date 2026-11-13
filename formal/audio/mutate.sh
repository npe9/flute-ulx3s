#!/bin/bash
# formal/audio/mutate.sh: each injected bug must stop the proof; the unmutated proof must pass first.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; bad=0
run() { d=$1; (cd "$d" && timeout "${MUT_LIMIT:-300}" sby -f audio.sby prove >/dev/null 2>&1)
        LC_ALL=C grep -o 'DONE ([A-Z]*' "$d/audio_prove/logfile.txt" | tr -d '(' | awk '{print $2}'; }
mkdir -p "$W/base"; cp "$HERE/../../src/Audio.v" "$HERE/../../src/Spdif_Tx.v" "$HERE/audio_fv.sv" "$W/base/"
sed -e 's#\.\./\.\./src/Audio.v#Audio.v#' -e 's#\.\./\.\./src/Spdif_Tx.v#Spdif_Tx.v#' "$HERE/audio.sby" > "$W/base/audio.sby"
r=$(run "$W/base"); echo "baseline: ${r:-TIMEOUT}"; [ "$r" = PASS ] || exit 1
for m in ${MUT_ONLY:-overflow lostpop stale mute carry level volreset spdifreset spdifmask}; do
    d="$W/$m"; mkdir -p "$d"; cp "$W/base/audio_fv.sv" "$W/base/audio.sby" "$W/base/Audio.v" "$W/base/Spdif_Tx.v" "$d/"; f="$d/Audio.v"
    case $m in
        overflow) perl -pi -e 's/wire push    = push_rq && !full;/wire push    = push_rq;/' "$f" ;;       # write to a full FIFO overruns
        lostpop)  perl -pi -e 's/if \(do_pop\) rp <= rp \+ 8.d1;/if (do_pop \&\& !push) rp <= rp + 8\x27d1;/' "$f" ;;   # a pop with a push repeats a sample
        stale)    perl -pi -e 's/if \(pop\) cur <= q;/if (do_pop) cur <= q;/' "$f" ;;                       # takes the RAM a cycle early
        mute)     perl -pi -e 's/\(vol == 0\)  \? 16.d0 :/(vol == 0)  ? v :/' "$f" ;;                        # volume 0 plays
        carry)    perl -pi -e 's/\+ \{3.b0, nx_l\[12\]\}/+ {3\x27b0, 1\x27b0}/' "$f" ;;                       # sigma-delta loses the carry
        level)    perl -pi -e 's/if \(!push && do_pop\) level <= level - 9.d1;//' "$f" ;;                    # level never falls
        spdifreset) perl -pi -e "s/spdif_pins <= 4'h0; spdif_sfreq <= 4'h0;/spdif_sfreq <= 4'h0;/" "$f" ;;   # S/PDIF pins not cleared by reset
        spdifmask) perl -pi -e 's/audio_v <= spdif_pins & \{4\{spdif_out\}\};/audio_v <= {4{spdif_out}};/' "$f" ;;   # drives every ring-2 bit
        volreset) perl -pi -e 's/volume   <= 4.d0;/volume   <= 4\x27d8;/' "$f" ;;                           # starts at full volume
    esac
    if cmp -s "$f" "$W/base/Audio.v"; then echo "$m: mutation did not apply"; bad=1; continue; fi
    r=$(run "$d"); s=$(LC_ALL=C grep -m1 -E 'failed assertion' "$d/audio_prove/logfile.txt" | LC_ALL=C grep -o 'audio_fv.sv:[0-9]*' | head -1)
    echo "$m: ${r:-TIMEOUT} $s"; case "$r" in FAIL|UNKNOWN) ;; *) bad=1 ;; esac
done
exit $bad
