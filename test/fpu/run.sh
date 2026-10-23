#!/bin/bash
# Berkeley TestFloat unit test of the FPU behind the FBox_Top request/response interface.
#   test/fpu/run.sh                 build + directed + full level-1 matrix (+ level-2 for 1-operand ops)
#   test/fpu/run.sh build           build only
#   test/fpu/run.sh one f32_add 0   one op x rm (level 1); LEVEL=2 / N=<cases> / STRIDE=<k> apply
#   test/fpu/run.sh directed        min/max/sgnj/class/fmv/NaN-boxing directed checks
# Env: DUT_SRC / DUT (default Flute/src_Core/CPU/FBox_Top.bsv / mkFBox_Top) -- any module with the
#      FBox_Top_IFC ports works; FPU_TF_BUILD (build/log dir, default build/fpu-tf); JOBS (parallel jobs, default 8); TF (testfloat_gen path);
#      L2 (default 1: level 2 for sqrt/cvt; div level 2 with L2DIV=1); FMA_STRIDE (subsample of the
#      FMSUB/FNMSUB/FNMADD sign variants, default 1 = all vectors).
# Vectors are streamed from testfloat_gen into the testbench: nothing is written to disk but logs.
set -e
cd "$(dirname "$0")"
R=$(cd ../.. && pwd); B=${FPU_TF_BUILD:-$R/build/fpu-tf}; mkdir -p $B/bsc $B/logs
BSC=${BSC:-$HOME/src/bsc/inst/bin/bsc}
TF=${TF:-$HOME/src/berkeley-testfloat-3/build/Linux-x86_64-GCC/testfloat_gen}
DUT_SRC=${DUT_SRC:-$R/Flute/src_Core/CPU/FBox_Top.bsv}
DUT=${DUT:-mkFBox_Top}
JOBS=${JOBS:-8}
C=$R/Flute/src_Core
DEFS="-D RV32 -D ISA_I -D ISA_M -D ISA_A -D ISA_C -D ISA_B -D ISA_ZKN -D ISA_ZKR -D ISA_F -D ISA_D \
      -D INCLUDE_FDIV -D INCLUDE_FSQRT -D ISA_PRIV_M -D ISA_PRIV_U -D ISA_PRIV_S -D SV32"

build() {
    $BSC -u -verilog -g $DUT -aggressive-conditions -no-warn-action-shadowing $DEFS -bdir $B/bsc -vdir $B/bsc \
        -p $C/CPU:$C/ISA:$C/BSV_Additional_Libs:+ $DUT_SRC > $B/bsc.log 2>&1 || { tail -40 $B/bsc.log; exit 1; }
    verilator --cc --exe --build --no-timing -O3 -Wno-fatal -Wno-lint -Wno-style -Mdir $B/obj --top-module $DUT \
        -y $B/bsc -y $(dirname $BSC)/../lib/Verilog -MAKEFLAGS "OPT_FAST=-O2 OPT_SLOW=-O1" -CFLAGS "-DVDUT=V$DUT" \
        $B/bsc/$DUT.v tb_fpu.cpp -o tb > $B/vl.log 2>&1 || { tail -30 $B/vl.log; exit 1; }
}

# op -> testfloat_gen function (+ flags)
tfargs() {
    case $1 in
        f32_fmadd|f32_fmsub|f32_fnmsub|f32_fnmadd) echo f32_mulAdd ;;
        f64_fmadd|f64_fmsub|f64_fnmsub|f64_fnmadd) echo f64_mulAdd ;;
        *_to_i32|*_to_ui32) echo "-exact $1" ;;      # RISC-V FCVT to integer raises NX
        *) echo $1 ;;
    esac
}
RMFLAG=(-rnear_even -rminMag -rmin -rmax -rnear_maxMag)   # rm 0..4 = RNE RTZ RDN RUP RMM

one() {   # op rm [level]
    local op=$1 rm=$2 lvl=${3:-${LEVEL:-1}} stride=${STRIDE:-1} n=""
    [ -n "$N" ] && n="-n $N"
    $TF -tininessafter ${RMFLAG[$rm]} -level $lvl $n $(tfargs $op) | awk -v k=$stride 'NR%k==0' | $B/obj/tb $op $rm 10
}
export -f one tfargs; export TF B RMFLAG_STR="${RMFLAG[*]}"

matrix() {
    local list=$B/jobs.txt; : > $list
    local FS=${FMA_STRIDE:-1}
    for p in f32 f64; do
        for op in add sub mul div sqrt fmadd fmsub fnmsub fnmadd to_i32 to_ui32; do
            for rm in 0 1 2 3 4; do
                s=1; case $op in fmsub|fnmsub|fnmadd) s=$FS ;; esac
                echo "${p}_$op $rm 1 $s" >> $list
            done
        done
        for op in eq lt le; do echo "${p}_$op 0 1 1" >> $list; done
        for rm in 0 1 2 3 4; do
            echo "i32_to_$p $rm 1 1" >> $list; echo "ui32_to_$p $rm 1 1" >> $list
        done
    done
    for rm in 0 1 2 3 4; do echo "f32_to_f64 $rm 1 1" >> $list; echo "f64_to_f32 $rm 1 1" >> $list; done
    if [ "${L2:-1}" = 1 ]; then
        for p in f32 f64; do for rm in 0 1 2 3 4; do
            for op in sqrt to_i32 to_ui32; do echo "${p}_$op $rm 2 1" >> $list; done
            echo "i32_to_$p $rm 2 1" >> $list; echo "ui32_to_$p $rm 2 1" >> $list
        done; done
        for rm in 0 1 2 3 4; do echo "f32_to_f64 $rm 2 1" >> $list; echo "f64_to_f32 $rm 2 1" >> $list; done
    fi
    if [ "${L2DIV:-0}" = 1 ]; then
        for rm in 0 1 2 3 4; do echo "f32_div $rm 2 1" >> $list; done
        echo "f64_div 0 2 ${F64DIV_STRIDE:-5}" >> $list
    fi
    # each job: one log line block, size-capped
    cat $list | xargs -P $JOBS -L 1 bash -c '
        RMF=($RMFLAG_STR); op=$0 rm=$1 lvl=$2 s=$3
        $TF -tininessafter ${RMF[$rm]} -level $lvl $(tfargs $op) | awk -v k=$s "NR%k==0" \
          | $B/obj/tb $op $rm 10 2>&1 | head -c 20000 | sed "s/^RESULT/RESULT L$lvl s$s/" > $B/logs/$op.$rm.L$lvl.log; true'
    cat $B/logs/*.log | grep -h "^RESULT" | sort > $B/summary.txt
    grep -h "MISMATCH\|TIMEOUT" $B/logs/*.log | head -c 200000 > $B/mismatches.txt || true
    cat $B/summary.txt
    echo "total: $(awk '{for(i=1;i<=NF;i++){if($i~/^pass=/){split($i,a,"=");p+=a[2]} if($i~/^fail=/){split($i,b,"=");f+=b[2]}}} END{print p" pass, "f" fail"}' $B/summary.txt)"
}

case ${1:-all} in
    build) build ;;
    one) [ -x $B/obj/tb ] || build; one $2 $3 $4 ;;
    directed) [ -x $B/obj/tb ] || build; $B/obj/tb directed ;;
    all) build; $B/obj/tb directed | tee $B/directed.log | head -c 20000; matrix ;;
    matrix) [ -x $B/obj/tb ] || build; matrix ;;
esac
