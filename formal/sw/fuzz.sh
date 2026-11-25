#!/bin/sh
# formal/sw/fuzz.sh: tier 1 of notes/sw-verification-plan.md.  Runs the game2d title's RISC-V
# binary on the Sail RISC-V model with the SoC's devices as an environment
# (formal/sw/sail/socdev.c: S1, no trap and only real device registers) under random button
# scripts, and compares its device-write trace with the host build of the same C code
# (formal/sw/host_trace.c: S2).  Odd runs also randomise the UART-ready bit and the frame
# counter's timing (SOC_CHAOS), which the trace must not depend on.  Tested, not proved.
#   formal/sw/fuzz.sh [runs] [frames] [seed]       (defaults 20 2000 1)
#   ROOT=<a copy of the tree> formal/sw/fuzz.sh ...  (formal/sw/mutants.sh: planted bugs)
#   TITLE=proof formal/sw/fuzz.sh ...                (Proof Obligation instead of Lantern Drift)
# Exit 0: every run passed.  1: a run failed (its files stay in build/swfv/fail-<run>/).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ROOT=${ROOT:-$REPO}
RUNS=${1:-20}; FRAMES=${2:-2000}; SEED=${3:-1}
OUT=${OUT:-$REPO/build/swfv}
SAIL=$REPO/build/sail-soc/c_emulator/riscv_sim_RV32
mkdir -p "$OUT"

# the Sail model: a shared clone of ~/src/sail-riscv at testrig's commit, plus the SoC patch
if [ ! -x "$SAIL" ] || [ "$HERE/sail/soc-mmio.patch" -nt "$SAIL" ] || [ "$HERE/sail/socdev.c" -nt "$SAIL" ]; then
   if [ ! -d "$REPO/build/sail-soc" ]; then
      git clone -q --shared ~/src/sail-riscv "$REPO/build/sail-soc"
      git -C "$REPO/build/sail-soc" checkout -q af5c2f2
      git -C "$REPO/build/sail-soc" apply "$HERE/sail/soc-mmio.patch"
   fi
   eval "$(opam env --switch=4.14.2 --set-switch)"
   ( cd "$REPO/build/sail-soc" && ARCH=RV32 SOCDEV="$HERE/sail/socdev.c" make c_emulator/riscv_sim_RV32 ) > "$OUT/sail-build.log" 2>&1 \
      || { echo "fuzz: Sail build failed ($OUT/sail-build.log)"; exit 2; }
fi

# the binary under test: the board's own lantern.elf (formal/sw/rocq proves about the same file),
# stopped after FRAMES frames by socdev (SOC_FRAMES); and the host spec
"$ROOT/sw/game2d/build.sh" > "$OUT/build.log" 2>&1 || { echo "fuzz: build failed ($OUT/build.log)"; exit 2; }
TITLE=${TITLE:-lantern}
ELF=$ROOT/sw/game2d/$TITLE.elf
echo "fuzz: $(md5 -q "$ELF") $ELF"
export SOC_FRAMES=$FRAMES
if [ "$TITLE" = proof ]; then SRCS="-DTITLE_PROOF $ROOT/sw/game2d/proof.c $ROOT/sw/game2d/proof_boss.c $ROOT/sw/game2d/proof_sound.c $ROOT/sw/game2d/proof_portraits.c $ROOT/sw/game2d/proof_spec.c"
else SRCS="$ROOT/sw/game2d/lantern.c $ROOT/sw/game2d/sound.c"; fi
cc -O2 -Wall -o "$OUT/host_trace" "$ROOT/formal/sw/host_trace.c" $SRCS \
   || { echo "fuzz: host build failed"; exit 2; }

fail=0; r=0
while [ $r -lt "$RUNS" ]; do
   # a button script: held combinations of random length, sometimes long idle stretches (the
   # attract mode starts after 600 idle frames), FIRE2 to restart after a game over
   python3 - "$FRAMES" $((SEED * 100003 + r)) > "$OUT/btn.txt" <<'EOF'
import random, sys
n, seed = int(sys.argv[1]), int(sys.argv[2]); R = random.Random(seed); out = []
L, Rt, U, D, F = 0x20, 0x40, 0x08, 0x10, 0x04
while len(out) < n:
    k = R.random()
    if k < 0.08: v, m = 0, R.randint(300, 900)                        # idle: attract mode
    elif k < 0.15: v, m = F, R.randint(1, 4)                          # restart
    else:
        v = R.choice([0, L, Rt, U, D, L|U, L|D, Rt|U, Rt|D, L|Rt, U|D, R.randint(0, 127)])
        m = R.randint(1, 60)
    out += [v] * m
print("\n".join("%x" % v for v in out[:n]))
EOF
   chaos=""; [ $((r % 2)) -eq 1 ] && chaos=$((SEED * 7919 + r))
   "$OUT/host_trace" "$FRAMES" "$OUT/btn.txt" "$OUT/host.txt" 2> "$OUT/spec.txt"
   set +e
   if [ -n "$chaos" ]; then
      SOC_CHAOS=$chaos SOC_TRACE="$OUT/sail.txt" SOC_BUTTONS="$OUT/btn.txt" "$SAIL" --no-trace --ram-size=32 "$ELF" > /dev/null 2> "$OUT/sail.err"
   else
      SOC_TRACE="$OUT/sail.txt" SOC_BUTTONS="$OUT/btn.txt" "$SAIL" --no-trace --ram-size=32 "$ELF" > /dev/null 2> "$OUT/sail.err"
   fi
   rc=$?
   set -e
   what=""
   if [ $rc -ne 0 ]; then what="S1 ($(grep -a 'S1 VIOLATION' "$OUT/sail.err" | head -1 || echo "Sail rc $rc"))"
   elif ! cmp -s "$OUT/sail.txt" "$OUT/host.txt"; then what="S2 (trace differs: $(diff "$OUT/sail.txt" "$OUT/host.txt" | head -1))"
   elif [ -s "$OUT/spec.txt" ]; then what="SPEC ($(head -1 "$OUT/spec.txt"))"   # Proof Obligation's spec clauses
   fi
   if [ -n "$what" ]; then
      echo "run $r${chaos:+ chaos}: FAIL $what"
      mkdir -p "$OUT/fail-$r"; cp "$OUT/btn.txt" "$OUT/sail.txt" "$OUT/host.txt" "$OUT/sail.err" "$OUT/spec.txt" "$OUT/fail-$r/"
      fail=1
      [ -n "$STOP_ON_FAIL" ] && break
   else
      echo "run $r${chaos:+ chaos}: ok ($(grep -c '^W' "$OUT/host.txt") writes)"
   fi
   r=$((r + 1))
done
[ $fail -eq 0 ] && echo "FUZZ PASS: $RUNS runs x $FRAMES frames" || echo "FUZZ FAIL"
exit $fail
