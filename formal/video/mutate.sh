#!/bin/bash
# formal/video/mutate.sh: the prove task must FAIL on each injected bug (guards against a
# vacuous proof).  Usage: bash formal/video/mutate.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp "$HERE/video_fb_fv.sv" "$W/"
sed "s#../../src/Video_DVI.v#$W/Video_DVI.v#" "$HERE/video_fb.sby" > "$W/m.sby"
bad=0
for m in lane pal ack; do
    cp "$HERE/../../src/Video_DVI.v" "$W/Video_DVI.v"
    case $m in
        lane) perl -0pi -e 's/<= wd_r\[8\*gl \+: 8\]/<= wd_r[8*(3-gl) +: 8]/' "$W/Video_DVI.v" ;;    # byte lanes swapped
        pal)  perl -0pi -e 's/pal\[pal_idx\] <= rb_wdata\[23:0\];/pal[pal_idx] <= rb_wdata[23:0] ^ rb_wdata[24];/' "$W/Video_DVI.v" ;;
        ack)  perl -0pi -e "s/if \(rd_st == 2'd3\) begin/if (rd_st == 2'd2) begin/" "$W/Video_DVI.v" ;;  # read acked early
    esac
    if cmp -s "$W/Video_DVI.v" "$HERE/../../src/Video_DVI.v"; then echo "$m: mutation did not apply"; bad=1; continue; fi
    (cd "$W" && rm -rf m_prove && sby -f m.sby prove > /dev/null 2>&1)
    r=$(grep -o 'DONE ([A-Z]*' "$W/m_prove/logfile.txt" | tr -d '(' | awk '{print $2}')
    echo "$m: prove $r (want FAIL)"; [ "$r" = FAIL ] || bad=1
done
exit $bad
