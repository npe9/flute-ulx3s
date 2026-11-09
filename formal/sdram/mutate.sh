#!/bin/bash
# formal/sdram/mutate.sh: each injected bug must stop the proof of its group passing (guards against
# vacuous checks): FAIL (pdr counterexample), or UNKNOWN (k-induction failed, no base-case
# counterexample).  Also checks the mutated source is what was compiled.
# (No burst+1 mutant of fn_next_set: fn_burst_mask only sets adjacent bits, so it would be equivalent.)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
bad=0
# UNKNOWN means nothing unless the same task passes unmutated
for t in prove_init prove_timing prove_credit prove_refresh prove_decode prove_k; do
    (cd "$HERE" && timeout "${MUT_LIMIT:-900}" sby -f sdram.sby $t >/dev/null 2>&1)
    r=$(LC_ALL=C grep -o 'DONE ([A-Z]*' "$HERE/sdram_$t/logfile.txt" | tr -d '(' | awk '{print $2}')
    [ "$r" = PASS ] || { echo "baseline $t: ${r:-TIMEOUT}, mutants would prove nothing"; exit 1; }
done
for m in ${MUT_ONLY:-refresh initshort credit tdal noap casoff wridx wrdqm rdswap rdfirst rdgap rdap wrlast actbank}; do
    mkdir -p "$W/$m/src"; cp "$ROOT/src/Sdram_Controller.bsv" "$W/$m/src/"
    f="$W/$m/src/Sdram_Controller.bsv"
    case $m in
        refresh)   perl -0pi -e 's/if \(rg_ref_cnt <= 1\)\n         rg_state <= ST_REF;/if (rg_ref_cnt == 0)\n         rg_state <= ST_REF;/' "$f" ;;   # a due refresh is never served
        initshort) perl -0pi -e 's/if \(rg_init_pairs == 3\)/if (rg_init_pairs == 2)/' "$f" ;;                  # 6 init REFs, not 8
        credit)    perl -0pi -e "s/<= 5'd8\) begin/<= 5'd12) begin/" "$f" ;;                                     # read started without FIFO room
        tdal)      perl -0pi -e 's/\(rg_wr_bank != tagged Valid fn_bank \(f_reqs\.first\.line\)\)/True/' "$f" ;; # ACT to the bank just written: tDAL
        noap)      perl -0pi -e 's/\(rg_burst == rg_burst_last\) \? 13.h0400 : 13.h0\);\n      rg_ba       <= fn_bank \(rg_req\.line\);\n      rg_dq_oe/13\x27h0);\n      rg_ba       <= fn_bank (rg_req.line);\n      rg_dq_oe/' "$f" ;;   # write leaves the row open
        casoff)    perl -0pi -e 's/t_cas_first   = 3/t_cas_first   = 2/' "$f" ;;                                # data captured a beat early
        wridx)     perl -0pi -e 's/idx    = \{ b \[0\], beat \}/idx    = { beat, b [0] }/' "$f" ;;               # wrong write word
        wrdqm)     perl -0pi -e 's/\{ ~ rg_req\.wbe \[be_idx \+ 1\], ~ rg_req\.wbe \[be_idx\] \}/{ ~ rg_req.wbe [be_idx], ~ rg_req.wbe [be_idx + 1] }/' "$f" ;;   # byte enables swapped
        rdswap)    perl -0pi -e 's/\{ rg_dq_in, rg_hw \[2\], rg_hw \[1\], rg_hw \[0\] \}/{ rg_dq_in, rg_hw [2], rg_hw [0], rg_hw [1] }/' "$f" ;;   # halfwords out of order
        rdfirst)   perl -0pi -e 's/rg_burst         <= req\.b_first;/rg_burst         <= req.b_last;/' "$f" ;;                 # reads from the wrong burst
        rdgap)     perl -0pi -e 's/\(rg_beat == 4\) && \(rg_burst != rg_burst_last\)/(rg_beat == 3) \&\& (rg_burst != rg_burst_last)/' "$f" ;;   # truncates the running burst
        rdap)      perl -0pi -e 's/\(b == rg_burst_last\) \? 13.h0400 : 13.h0/13\x27h0400/' "$f" ;;                 # auto-precharge on every read burst
        wrlast)    perl -0pi -e 's/rg_burst_last <= fn_last_set \(bm\);/rg_burst_last <= fn_first_set (bm);/' "$f" ;;   # drops the upper half of a two-burst write
        actbank)   perl -0pi -e 's/fa_act \(req\.line\);\n            rg_state         <= ST_RD;/fa_act (req.line + 1);\n            rg_state         <= ST_RD;/' "$f" ;;   # activates the wrong row or bank
    esac
    if cmp -s "$f" "$ROOT/src/Sdram_Controller.bsv"; then echo "$m: mutation did not apply"; bad=1; continue; fi
    rm -rf "$W/$m/build"; make -C "$ROOT" -s formal-sdram-verilog BUILD="$W/$m/build" SDRAM_SRC="$f" >/dev/null 2>&1 \
        || { echo "$m: build failed"; bad=1; continue; }
    sed -e "s#../../build/formal-sdram/v/mkSdramFormal.v#$W/$m/build/formal-sdram/v/mkSdramFormal.v#" "$HERE/sdram.sby" > "$W/$m/m.sby"
    cp "$HERE/sdram_fv.sv" "$W/$m/"
    case $m in
        refresh)     t=prove_refresh ;;
        initshort)   t=prove_init ;;
        credit|casoff) t=prove_credit ;;
        rdfirst|rdgap|rdap|wrlast|actbank) t=prove_decode ;;
        tdal|noap)   t=prove_timing ;;
        *)           t=prove_k ;;
    esac; lim=${MUT_LIMIT:-900}
    (cd "$W/$m" && timeout $lim sby -f m.sby $t > /dev/null 2>&1)
    r=$(LC_ALL=C grep -o 'DONE ([A-Z]*' "$W/$m/m_$t/logfile.txt" | tr -d '(' | awk '{print $2}'); r=${r:-TIMEOUT}
    s=$(LC_ALL=C grep -E 'failed assertion' "$W/$m/m_$t/logfile.txt" | head -1 | LC_ALL=C grep -o 'sdram_fv.sv:[0-9]*.*in step [0-9]*' | cut -c1-60)
    echo "$m: $t $r $s"; case "$r" in FAIL|UNKNOWN) ;; *) bad=1 ;; esac
done
exit $bad
