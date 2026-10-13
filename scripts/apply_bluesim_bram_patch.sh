#!/bin/sh
# apply_bluesim_bram_patch.sh — idempotent apply/restore of the Track B
# strict-BRAM patch to the INSTALLED Bluesim header.
#
# The patch itself lives on the ~/src/bsc git branch `ulx3s-strict-bram`
# (commit 4b7264f6, file src/bluesim/bs_prim_mod_bram.h; see the header's
# comment block and ulx3s-experiments/HANDOFF.md "Bluesim remediation
# roadmap", Track B).  bsc's install tree (inst/) is git-ignored, so the
# patch reaches the sim flows by copying the committed header over
# inst/lib/Bluesim/bs_prim_mod_bram.h.  No bsc binary/library rebuild is
# needed: MOD_BRAM is a C++ template instantiated into the generated sim
# C++, and libbsprim.a's prim_mod_bram.o is an empty stub.
#
# Strict mode is OFF unless BSV_BRAM_STRICT=warn|corrupt|error is set in
# the environment of a sim run, so applying this patch does not change any
# default sim behavior.
#
# Usage:
#   scripts/apply_bluesim_bram_patch.sh          # apply (idempotent)
#   scripts/apply_bluesim_bram_patch.sh restore  # restore the stock header
#
# Restore reconstructs the stock header from the branch's parent commit
# (git show main:src/bluesim/bs_prim_mod_bram.h), so it works even if no
# .orig backup exists.
set -e

BSC_SRC=${BSC_SRC:-$HOME/src/bsc}
HEADER=src/bluesim/bs_prim_mod_bram.h
INST=${BSC_SRC}/inst/lib/Bluesim/bs_prim_mod_bram.h
BRANCH=ulx3s-strict-bram
BACKUP=${INST}.stock-bak

case "${1:-apply}" in
  apply)
    (cd "$BSC_SRC" && git show "$BRANCH:$HEADER" > "$INST")
    echo "applied $BRANCH:$HEADER -> $INST"
    ;;
  restore)
    if [ -f "$BACKUP" ]; then
      cp "$BACKUP" "$INST"
      echo "restored stock header from $BACKUP"
    else
      (cd "$BSC_SRC" && git show "main:$HEADER" > "$INST")
      echo "restored stock header from main:$HEADER"
    fi
    ;;
  *)
    echo "usage: $0 [apply|restore]" >&2
    exit 2
    ;;
esac
