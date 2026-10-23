# FPU unit test: Berkeley TestFloat against the FBox

`run.sh` drives the FPU through the **FBox_Top request/response interface** (`req(opcode, f7, rm, rs2,
v1, v2, v3)` -> `valid`, `word = (value, fflags)`). It feeds `testfloat_gen` vectors (SoftFloat 3e,
RISCV specialization, tininess after rounding) and checks **result and fflags exactly**. Vectors are
streamed through a pipe, so nothing large is written to disk. Any module with the same ports can be
dropped in with `DUT_SRC=... DUT=...`, including the planned area-trimmed FPU.

This is item 1 of "F and D -> Verification" in `notes/linux-isa-plan.md`. The pattern follows
`test/zkr/run.sh`: bsc -verilog, then Verilator, then a C++ driver (`tb_fpu.cpp`).

## Setup

```
git clone https://github.com/ucb-bar/berkeley-softfloat-3 ~/src/berkeley-softfloat-3
git clone https://github.com/ucb-bar/berkeley-testfloat-3 ~/src/berkeley-testfloat-3
make -C ~/src/berkeley-softfloat-3/build/Linux-x86_64-GCC SPECIALIZE_TYPE=RISCV
make -C ~/src/berkeley-testfloat-3/build/Linux-x86_64-GCC SPECIALIZE_TYPE=RISCV \
     SOFTFLOAT_DIR=$HOME/src/berkeley-softfloat-3
```

On macOS arm64, the Linux-x86_64-GCC configs build as-is with clang (they only use
`__builtin_clz` and `__int128`).

## Usage

```
test/fpu/run.sh                 # build + directed + level-1 matrix + level-2 for 1-operand ops
test/fpu/run.sh one f32_add 3   # one op x rm (0..4 = RNE RTZ RDN RUP RMM); LEVEL=2 / STRIDE=k
test/fpu/run.sh directed        # min/max/sgnj/class/fmv/NaN-boxing directed checks
L2DIV=1 F64DIV_STRIDE=5 test/fpu/run.sh matrix   # + level-2 div (f32 all rm, f64 RNE 1/5)
python3 test/fpu/table.py build/fpu-tf/summary.txt 1   # markdown op x rm table
```

Environment variables: `JOBS` (default 8) and `FPU_TF_BUILD` (default `build/fpu-tf`). Each op x rm
log is capped at 20 kB, with the first 10 mismatches as `in=<a> [b] [c] exp=<value>/<flags>
got=<value>/<flags>`.

Conventions follow CPU_Stage2:
- f32 operands are NaN-boxed, and f32 results must come back boxed.
- Integer sources are zero-extended from 32 bits.
- Integer results (FCVT.W*, FEQ/FLT/FLE, FCLASS, FMV.X.W) are checked on [31:0] only, because Stage2
  truncates them.

How each TestFloat function maps onto the FBox:
- FMADD, FMSUB, FNMSUB and FNMADD all use the `mulAdd` vectors, with operands pre-negated:
  FMSUB gets (a, b, -c), FNMSUB gets (-a, b, c) and FNMADD gets (-a, b, -c). Each must equal
  `mulAdd(a, b, c)` exactly.
- FEQ/FLT/FLE use `eq`/`lt`/`le`. `lt` and `le` are signaling in TestFloat; rm is funct3 here.
- FCVT to integer uses `-exact`, because RISC-V raises NX.

Level 2 for FMA is not run. It is 14.5 G (f32) and 181 G (f64) cases, and `testfloat_gen -n` cannot
go below the level count. Level 1 gives 6.1 M FMA cases per op x rm.

## Results

Totals for the full matrix (6 jobs, under 30 min on this machine):

| Flute | pass | fail |
|---|---|---|
| fp-ext 7c7f68e (before) | 180,328,474 | 68,181,830 |
| 22d2689 (after the three FBox fixes below; adds level-2 div) | 261,069,677 | 32,978,444 |

Cells are `fails/total (v = value mismatches, f = flag mismatches)`. Raw RESULT lines for both runs:
`summary-7c7f68e.txt` and `summary-22d2689.txt`.

The directed min/max/sgnj/class/fmv/NaN-box checks pass in both runs: **4523/4523**.

### Level 1, Flute 22d2689 (current)

| op (level 1) | RNE | RTZ | RDN | RUP | RMM |
|---|---|---|---|---|---|
| f32_add | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18192**/46464 (v18192 f145) |
| f32_div | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **17589**/46464 (v17589 f0) |
| f32_eq | 0/46464 | n/a | n/a | n/a | n/a |
| f32_fmadd | **6473**/6133248 (v1623 f4854) | **2178**/6133248 (v0 f2178) | **2525**/6133248 (v0 f2525) | **2562**/6133248 (v0 f2562) | **2488324**/6133248 (v2485611 f15999) |
| f32_fmsub | **6473**/6133248 (v1623 f4854) | **2178**/6133248 (v0 f2178) | **2525**/6133248 (v0 f2525) | **2562**/6133248 (v0 f2562) | **2488324**/6133248 (v2485611 f15999) |
| f32_fnmadd | **6473**/6133248 (v1623 f4854) | **2178**/6133248 (v0 f2178) | **2525**/6133248 (v0 f2525) | **2562**/6133248 (v0 f2562) | **2488324**/6133248 (v2485611 f15999) |
| f32_fnmsub | **6473**/6133248 (v1623 f4854) | **2178**/6133248 (v0 f2178) | **2525**/6133248 (v0 f2525) | **2562**/6133248 (v0 f2562) | **2488324**/6133248 (v2485611 f15999) |
| f32_le | 0/46464 | n/a | n/a | n/a | n/a |
| f32_lt | 0/46464 | n/a | n/a | n/a | n/a |
| f32_mul | **25**/46464 (v0 f25) | 0/46464 | **12**/46464 (v0 f12) | **13**/46464 (v0 f13) | **19972**/46464 (v19947 f25) |
| f32_sqrt | 0/600 | 0/600 | 0/600 | 0/600 | **143**/600 (v143 f0) |
| f32_sub | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18243**/46464 (v18243 f162) |
| f32_to_f64 | 0/600 | 0/600 | 0/600 | 0/600 | 0/600 |
| f32_to_i32 | 0/600 | 0/600 | **91**/600 (v91 f0) | **81**/600 (v81 f0) | **90**/600 (v90 f0) |
| f32_to_ui32 | 0/600 | 0/600 | 0/600 | **97**/600 (v97 f0) | **48**/600 (v48 f0) |
| f64_add | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18917**/46464 (v18917 f317) |
| f64_div | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18396**/46464 (v18396 f0) |
| f64_eq | 0/46464 | n/a | n/a | n/a | n/a |
| f64_fmadd | **517097**/6133248 (v82296 f447559) | **537792**/6133248 (v110765 f446768) | **538274**/6133248 (v111644 f447250) | **538258**/6133248 (v111720 f447234) | **2790290**/6133248 (v2563405 f470616) |
| f64_fmsub | **517097**/6133248 (v82296 f447559) | **537792**/6133248 (v110765 f446768) | **538274**/6133248 (v111644 f447250) | **538258**/6133248 (v111720 f447234) | **2790290**/6133248 (v2563405 f470616) |
| f64_fnmadd | **517097**/6133248 (v82296 f447559) | **537792**/6133248 (v110765 f446768) | **538274**/6133248 (v111644 f447250) | **538258**/6133248 (v111720 f447234) | **2790290**/6133248 (v2563405 f470616) |
| f64_fnmsub | **517097**/6133248 (v82296 f447559) | **537792**/6133248 (v110765 f446768) | **538274**/6133248 (v111644 f447250) | **538258**/6133248 (v111720 f447234) | **2790290**/6133248 (v2563405 f470616) |
| f64_le | 0/46464 | n/a | n/a | n/a | n/a |
| f64_lt | 0/46464 | n/a | n/a | n/a | n/a |
| f64_mul | **24**/46464 (v0 f24) | 0/46464 | **12**/46464 (v0 f12) | **12**/46464 (v0 f12) | **20671**/46464 (v20647 f24) |
| f64_sqrt | 0/768 | 0/768 | 0/768 | 0/768 | **189**/768 (v189 f0) |
| f64_sub | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18865**/46464 (v18865 f302) |
| f64_to_f32 | **4**/768 (v0 f4) | 0/768 | **2**/768 (v0 f2) | **2**/768 (v0 f2) | **301**/768 (v297 f4) |
| f64_to_i32 | 0/768 | 0/768 | **145**/768 (v145 f0) | **126**/768 (v126 f0) | **113**/768 (v110 f3) |
| f64_to_ui32 | 0/768 | 0/768 | 0/768 | **134**/768 (v134 f0) | **65**/768 (v63 f2) |
| i32_to_f32 | 0/372 | 0/372 | 0/372 | 0/372 | **35**/372 (v35 f0) |
| i32_to_f64 | 0/372 | 0/372 | 0/372 | 0/372 | 0/372 |
| ui32_to_f32 | 0/372 | 0/372 | 0/372 | 0/372 | **33**/372 (v33 f0) |
| ui32_to_f64 | 0/372 | 0/372 | 0/372 | 0/372 | 0/372 |

### Level 2, Flute 22d2689 (1-operand ops; div)

| op (level 2) | RNE | RTZ | RDN | RUP | RMM |
|---|---|---|---|---|---|
| f32_div | 0/7496192 | 0/7496192 | 0/7496192 | 0/7496192 | **3083087**/7496192 (v3083087 f0) |
| f32_sqrt | 0/8800 | 0/8800 | 0/8800 | 0/8800 | **2113**/8800 (v2113 f0) |
| f32_to_f64 | 0/8800 | 0/8800 | 0/8800 | 0/8800 | 0/8800 |
| f32_to_i32 | 0/8800 | 0/8800 | **1223**/8800 (v1223 f0) | **1214**/8800 (v1214 f0) | **1326**/8800 (v1326 f0) |
| f32_to_ui32 | 0/8800 | 0/8800 | 0/8800 | **1380**/8800 (v1380 f0) | **686**/8800 (v686 f0) |
| f64_div | 0/8056857 (1/5) | - | - | - | - |
| f64_sqrt | 0/26112 | 0/26112 | 0/26112 | 0/26112 | **6350**/26112 (v6350 f0) |
| f64_to_f32 | **135**/26112 (v0 f135) | 0/26112 | **71**/26112 (v0 f71) | **67**/26112 (v0 f67) | **9767**/26112 (v9632 f140) |
| f64_to_i32 | 0/26112 | 0/26112 | **4468**/26112 (v4468 f0) | **4411**/26112 (v4411 f0) | **3690**/26112 (v3600 f90) |
| f64_to_ui32 | 0/26112 | 0/26112 | 0/26112 | **4802**/26112 (v4802 f0) | **2085**/26112 (v2035 f50) |
| i32_to_f32 | 0/15500 | 0/15500 | 0/15500 | 0/15500 | **2001**/15500 (v2001 f0) |
| i32_to_f64 | 0/15500 | 0/15500 | 0/15500 | 0/15500 | 0/15500 |
| ui32_to_f32 | 0/15500 | 0/15500 | 0/15500 | 0/15500 | **1834**/15500 (v1834 f0) |
| ui32_to_f64 | 0/15500 | 0/15500 | 0/15500 | 0/15500 | 0/15500 |

### Level 1, Flute fp-ext 7c7f68e (before the fixes)

| op (level 1) | RNE | RTZ | RDN | RUP | RMM |
|---|---|---|---|---|---|
| f32_add | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18192**/46464 (v18192 f145) |
| f32_div | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **17589**/46464 (v17589 f0) |
| f32_eq | 0/46464 | n/a | n/a | n/a | n/a |
| f32_fmadd | **6512**/6133248 (v1623 f4893) | **2217**/6133248 (v0 f2217) | **2564**/6133248 (v0 f2564) | **2601**/6133248 (v0 f2601) | **2488363**/6133248 (v2485611 f16038) |
| f32_fmsub | **6512**/6133248 (v1623 f4893) | **2217**/6133248 (v0 f2217) | **2564**/6133248 (v0 f2564) | **2601**/6133248 (v0 f2601) | **2488363**/6133248 (v2485611 f16038) |
| f32_fnmadd | **8106**/6133248 (v3217 f4893) | **3811**/6133248 (v1594 f2217) | **5039597**/6133248 (v5039558 f19690) | **5039597**/6133248 (v5039558 f19603) | **2489957**/6133248 (v2487205 f16038) |
| f32_fnmsub | **8106**/6133248 (v3217 f4893) | **3811**/6133248 (v1594 f2217) | **5039597**/6133248 (v5039558 f19690) | **5039597**/6133248 (v5039558 f19603) | **2489957**/6133248 (v2487205 f16038) |
| f32_le | 0/46464 | n/a | n/a | n/a | n/a |
| f32_lt | 0/46464 | n/a | n/a | n/a | n/a |
| f32_mul | **25**/46464 (v0 f25) | 0/46464 | **12**/46464 (v0 f12) | **13**/46464 (v0 f13) | **19972**/46464 (v19947 f25) |
| f32_sqrt | 0/600 | 0/600 | 0/600 | 0/600 | **143**/600 (v143 f0) |
| f32_sub | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18243**/46464 (v18243 f162) |
| f32_to_f64 | 0/600 | 0/600 | 0/600 | 0/600 | 0/600 |
| f32_to_i32 | 0/600 | 0/600 | **91**/600 (v91 f0) | **81**/600 (v81 f0) | **90**/600 (v90 f0) |
| f32_to_ui32 | **79**/600 (v0 f79) | **70**/600 (v0 f70) | **179**/600 (v0 f179) | **167**/600 (v97 f70) | **128**/600 (v48 f80) |
| f64_add | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18917**/46464 (v18917 f317) |
| f64_div | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18396**/46464 (v18396 f0) |
| f64_eq | 0/46464 | n/a | n/a | n/a | n/a |
| f64_fmadd | **517133**/6133248 (v82296 f447595) | **537828**/6133248 (v110765 f446804) | **538310**/6133248 (v111644 f447286) | **538294**/6133248 (v111720 f447270) | **2790326**/6133248 (v2563405 f470652) |
| f64_fmsub | **517133**/6133248 (v82296 f447595) | **537828**/6133248 (v110765 f446804) | **538310**/6133248 (v111644 f447286) | **538294**/6133248 (v111720 f447270) | **2790326**/6133248 (v2563405 f470652) |
| f64_fnmadd | **518740**/6133248 (v83903 f447595) | **539435**/6133248 (v112372 f446804) | **5060206**/6133248 (v5049615 f473058) | **5060167**/6133248 (v5049647 f473040) | **2791933**/6133248 (v2565012 f470652) |
| f64_fnmsub | **518740**/6133248 (v83903 f447595) | **539435**/6133248 (v112372 f446804) | **5060206**/6133248 (v5049615 f473058) | **5060167**/6133248 (v5049647 f473040) | **2791933**/6133248 (v2565012 f470652) |
| f64_le | 0/46464 | n/a | n/a | n/a | n/a |
| f64_lt | 0/46464 | n/a | n/a | n/a | n/a |
| f64_mul | **24**/46464 (v0 f24) | 0/46464 | **12**/46464 (v0 f12) | **12**/46464 (v0 f12) | **20671**/46464 (v20647 f24) |
| f64_sqrt | 0/768 | 0/768 | 0/768 | 0/768 | **189**/768 (v189 f0) |
| f64_sub | 0/46464 | 0/46464 | 0/46464 | 0/46464 | **18865**/46464 (v18865 f302) |
| f64_to_f32 | **4**/768 (v0 f4) | 0/768 | **2**/768 (v0 f2) | **2**/768 (v0 f2) | **301**/768 (v297 f4) |
| f64_to_i32 | **2**/768 (v0 f2) | 0/768 | **145**/768 (v145 f0) | **128**/768 (v126 f2) | **113**/768 (v110 f3) |
| f64_to_ui32 | **98**/768 (v0 f98) | **88**/768 (v0 f88) | **258**/768 (v0 f258) | **224**/768 (v134 f90) | **162**/768 (v63 f99) |
| i32_to_f32 | 0/372 | 0/372 | 0/372 | 0/372 | **35**/372 (v35 f0) |
| i32_to_f64 | 0/372 | 0/372 | 0/372 | 0/372 | 0/372 |
| ui32_to_f32 | 0/372 | 0/372 | 0/372 | 0/372 | **33**/372 (v33 f0) |
| ui32_to_f64 | 0/372 | 0/372 | 0/372 | 0/372 | 0/372 |

## Findings

Every mismatch above falls into one of the classes below. Classes 1 to 3 were in the FBox itself and
are fixed in Flute fp-ext. The rest are in the **bsc `FloatingPoint` library**
(`bsc/src/Libraries/Base3-Math/FloatingPoint.bsv`) or in how `FPU.bsv` uses it. Fixing those means
forking the library, so they are left for the replacement FPU, and this harness is its acceptance
test.

1. **FCVT.WU of negatives** (fixed, Flute 05cb6f7). FBox_Core kept the NX flag from converting |x|.
   Repros: `FCVT.WU.S RNE bffffe00` expects `0/NV`, got `0/NX`. `RDN bc27ffff` expects `0/NV`, got
   `0/NX`. The library also raised NX together with NV when rounding overflowed:
   `FCVT.WU.D RNE 41effffffffffffe` expects `ffffffff/NV`, got `NV|NX`.
2. **FNMADD/FNMSUB negated the rounded result** (fixed, Flute ac9811a, FPU.bsv). This gave the wrong
   rounding direction under RDN/RUP and the wrong sign for an exact zero.
   Repro: `FNMADD.S RDN rs1=5e7f8006 rs2=bc27ffff rs3=80000000` expects `5b27ac02`, got `5b27ac03`.
   Before the fix this was 5.0 M of the 6.1 M RDN/RUP cases.
3. **FMA inf*0 + qNaN raised no NV** (fixed, Flute 22d2689). The library checks for a qNaN addend
   first. Repro: `FMADD.S 00000000 7f800000 7fffffff` expects `7fc00000/NV`, got no flags.
4. **RMM rounds the wrong way: every op, about 40% of RMM cases.** In the library's `round()`,
   `Rnd_Nearest_Away_Zero` maps guard `'b01` (below half) to `din_inc`. It should keep `din`.
   Repro: `FADD.S RMM 4688003f 00000001` expects `4688003f`, got `46880040`. The FBox code itself
   says "XXX Is this RMM?".
5. **vFloatToFixed (FCVT to integer)** has no RMM case, so it truncates. It also returns 0 for
   |x| < 0.5 regardless of rm.
   Repros: `FCVT.W.S RUP 00000001` expects `1`, got `0`. `RDN bc27ffff` expects `-1`, got `0`.
   `RMM 409de3fd` (4.93) expects `5`, got `4`.
6. **Tininess is detected before rounding.** `normalize()` sets UF when the pre-rounding exponent
   is 0, even if the result rounds up to the smallest normal. RISC-V requires after-rounding.
   This affects mul, f64->f32 and FMA (the f-only fails under RNE/RDN/RUP).
   Repro: `FMUL.S RNE 007fffff 3f800001` expects `00800000/NX`, got `NX|UF`.
   It cannot be patched after the fact in the FBox: correct detection needs a third rounding bit,
   and the library's 2-bit guard folds it into the sticky bit.
7. **The FMA is not fused.** `mkFloatingPointFusedMultiplyAccumulate` s4_stage normalizes a*b to
   `FloatingPoint#(e,m)` plus 2 guard bits before the add. Precision is lost on cancellation, and the
   product stage's UF/OF/NX leak into the result. For f64 that is about 8% of cases (1.3% wrong
   values).
   Repro: `FMADD.D RNE c0000004003ffffe 406ffffc00000007 401a2cb8d0ba93b9` expects
   `c07f97511d3c15a4`, got `...a5`.
8. **With ISA_D, single precision is computed in double and rounded twice.** `FPU.bsv` widens f32
   operands to f64, runs the op, then `convert`s back. This is exact for add/sub/mul/div/sqrt
   (53 >= 2*24+2), but f32 FMA double-rounds: 1623 RNE value errors. Repro:
   `FMADD.S RNE 007fffff 33800001 007fffff` expects `007fffff/NX|UF`, got `00800000`.

Compares, f32<->f64 except as above, int->fp except RMM, and div/sqrt except RMM pass completely,
including level-2 div (7.5 M per rm for f32; 8 M for f64 RNE).

## ISA tests (item 2)

`sim/isa_bram/isa_run.py` works for FP builds. Build the netlist with `make FP=1` into a separate
`BUILD`, then pass `VERILATOR_EXTRA=-Wno-MULTIDRIVEN`, which `run.sh` now honours: the FPU's FIFOL1
reset block trips MULTIDRIVEN.

```
make BUILD=build/fpu-isa FP=1 -o $PWD/Flute/src_Testbench/SoC/fn_read_ROM_RV32.bsvi build/fpu-isa/verilog_all.v
VERILATOR_EXTRA=-Wno-MULTIDRIVEN VERILOG_ALL=$PWD/build/fpu-isa/verilog_all.v BUILD_DIR=obj_dir_fpisa \
    python3 sim/isa_bram/isa_run.py --build --jobs 4 Flute/Tests/isa/rv32u{f,d}-p-*[a-z]
```

Every rv32uf/rv32ud test in `Flute/Tests/isa` passes, both on Flute fp-ext 7c7f68e and on 22d2689 with the fixes:
- rv32uf: fadd, fclass, fcmp, fcvt, fcvt_w, fdiv, fmadd, fmin, ldst, move, recoding
- rv32ud: fadd, fclass, fcmp, fcvt, fcvt_w, fdiv, fmadd, fmin, ldst, recoding

The reference, Sail `riscv_sim_RV32` (`~/src/sail-riscv/c_emulator`), reports SUCCESS on the same
21 ELFs. The riscv-tests do not exercise RMM, tininess or FMA cancellation, so they cannot see
classes 4 to 8.
