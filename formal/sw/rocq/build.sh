#!/bin/sh
# formal/sw/rocq/build.sh: tier 3 of notes/sw-verification-plan.md, the model.  Generates the
# Sail RISC-V RV32 model as Rocq definitions and compiles it, then the proofs in this directory.
#   needs (opam switch omp-rocq-9.0): rocq 9.0, sail 0.20.2, coq-sail-stdpp 0.20.2, coq-stdpp 1.12
#   formal/sw/rocq/build.sh            -> build/sail-coq/generated_definitions/coq/RV32/riscv.vo
# sail-riscv af5c2f2 (testrig's commit, also formal/sw/sail's) in a shared clone, plus
#   - soc-coq.patch: model/riscv_termination_rv32.sail named walk32, renamed pt_walk upstream
#     (the Coq build had rotted at this commit); the platform functions bound for Rocq (defined
#     in support/riscv_extras.v from the SoC map); the SoC device window in within_phys_mem;
#   - handwritten_support/{riscv_extras,mem_metadata}.v replaced by support/ here (the originals
#     target the older bbv prompt monad; these add the SoC's configuration switches).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
B=$REPO/build/sail-coq
eval "$(opam env --switch=omp-rocq-9.0 --set-switch)"
mkdir -p "$REPO/build/swfv"
"$REPO/sw/game2d/build.sh" > "$REPO/build/swfv/rocq-sw-build.log" 2>&1    # lantern.elf, the binary proved about
if [ ! -d "$B" ]; then
   git clone -q --shared ~/src/sail-riscv "$B"
   git -C "$B" checkout -q af5c2f2
fi
git -C "$B" diff --quiet -- model || git -C "$B" checkout -q -- model
git -C "$B" apply "$HERE/soc-coq.patch"
cp "$HERE"/support/*.v "$B/handwritten_support/"
( cd "$B" && make ARCH=RV32 riscv_coq riscv_coq_build ) > "$REPO/build/swfv/coq-build.log" 2>&1 \
   || { grep -B3 -A10 "^Error" "$REPO/build/swfv/coq-build.log" | head -30; exit 1; }
echo "model: $B/generated_definitions/coq/RV32/riscv.vo"
# the proofs (Code.v regenerated from the ELF first, so the theorem is about this binary)
python3 "$HERE/gen_code.py" "$REPO/sw/game2d/lantern.elf" "$HERE/Code.v" hw_palette hw_vdp_write hw_apu_write hw_buttons
for v in Run Code Palette Mutants; do       # in dependency order
   "$HERE/rc.sh" "$HERE/$v.v" > "$REPO/build/swfv/rocq-$v.log" 2>&1 \
      || { grep -v "^Warning\|^\[\|^File" "$REPO/build/swfv/rocq-$v.log" | head -20; exit 1; }
   echo "checked: $v.v"
done
grep -A8 "^Axioms" "$REPO/build/swfv/rocq-Palette.log"
