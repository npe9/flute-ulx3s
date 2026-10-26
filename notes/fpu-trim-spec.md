# Area-trimmed FPU (F + D) for Flute RV32 on ECP5-85F

Decision (user, 2026-10-23): replace the stock FBox (+23.4K TRELLIS_COMB slots on V13,
unplaceable at 107%) with a new area-trimmed unit. Budget: **<= 9K TRELLIS_COMB slots** for the
whole F/D addition (FBox replacement + pipeline glue) on top of V13 (66,085 slots), i.e. the full
design stays <= 75.3K (90%). Branch: `fpu-trim` (outer + Flute) off `fp-merge`.

## Interface
Drop-in for `FBox_Top_IFC` (Flute/src_Core/CPU/FBox_Top.bsv): `req(opcode, f7, rm, rs2, v1, v2, v3)`,
`valid`, `word = (value[63:0], fflags[4:0])`, `server_reset`. Stage2 already waits (OSTATUS_BUSY)
until `valid`, so the unit may be multi-cycle and iterative. Select with a define (e.g. `FPU_TRIM`)
so the stock FBox remains available as the functional reference. Conventions are those of
CPU_Stage2 / test/fpu/README.md (NaN-boxing of f32 operands and results, integer sources
zero-extended from 32 bits, integer results checked on [31:0], rm = funct3 with DYN resolved by
Stage2 -- check how Stage2 passes rm).

## Must be right (where the bsc FloatingPoint library failed TestFloat)
- FMA fused: one rounding of a*b+c from the exact product (no intermediate rounding).
- RMM (round to nearest, ties away) for every op, including conversions to integer.
- Tininess detected AFTER rounding (RISC-V / SoftFloat RISCV specialization) for UF.
- f32 computed natively: round once to 24 bits from the exact result, never via f64.
- Exact flags (NV, DZ, OF, UF, NX) for every op; canonical NaN 0x7fc00000 / 0x7ff8000000000000;
  FMIN/FMAX per the 2.2 spec (sNaN -> NV; -0 < +0); FCVT to int saturation + NV rules; NX on inexact.

## Architecture (suggested; the agent may refine, with reasons)
- One internal unpacked format for both precisions: sign, wide exponent, significand with
  guard/sticky. f32 operands unpack into it; the final round stage rounds to 24 or 53 bits.
- One shared normalize (LZC + left shift) and one shared round/pack stage for all ops.
- Multiply on DSPs (MULT18X18D; 156 available, V13 uses 10). A 53x53 product may be formed over
  several cycles (e.g. 54x18 per cycle with 3 DSPs, accumulating) to keep LUT adder trees small.
- Add/sub/FMA: one alignment shifter with sticky, one wide adder (CCU2C carry chain), shared.
- Div and sqrt: one iterative digit-recurrence unit (radix 2 or 4), shared between div and sqrt
  and between precisions; f64 latency ~ 55-60 cycles is acceptable.
- int<->float conversions reuse normalize/round. Compare/min/max/sgnj/class/fmv are small
  combinational logic outside the arithmetic datapath.
- Multi-cycle FSM; register between heavy stages so no FPU path is longer than ~25 ns on ECP5
  (design-wide Fmax today ~30-31 MHz; the FPU must not become the critical path).

## Gates (in order)
1. `test/fpu/run.sh` (DUT_SRC/DUT drop-in): full level-1 matrix, every op x every rm, value and
   flags: **0 failures**; directed checks 4523/4523; level-2 for 1-operand ops; L2DIV=1 div.
2. rv32uf/ud 21/21 on sim/isa_bram with FP=1 (see build/fpm/isa_fd2.log for the method).
3. Area: yosys standalone (module) + full-design nextpnr TRELLIS_COMB <= 75.3K; Fmax on full
   design >= V13 (>= 27.5 MHz worst seed, 10% margin over 25 MHz) with the FPU not on the
   critical path.
4. FP formal (riscv-formal-fp, formal/csrs_msu_fd.cfg) -- coordinate: never two formal runs in
   the same RISCV_FORMAL dir.
