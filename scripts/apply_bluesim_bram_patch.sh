#!/bin/sh
# apply_bluesim_bram_patch.sh -- idempotent apply/restore of the Track B strict-BRAM patch to
# the INSTALLED Bluesim header.
#
# The patched header is vendored at scripts/bluesim/bs_prim_mod_bram.h (from bsc branch
# `ulx3s-strict-bram`, commit 4b7264f6; see its comment block and HANDOFF.md "Bluesim
# remediation roadmap", Track B).  It is copied over <bsc>/lib/Bluesim/bs_prim_mod_bram.h.
# No bsc rebuild is needed: MOD_BRAM is a C++ template instantiated into the generated sim C++,
# and libbsprim.a's prim_mod_bram.o is an empty stub.
#
# Strict mode is OFF unless BSV_BRAM_STRICT=warn|corrupt|error is set in the environment of a
# sim run, so applying this patch does not change any default sim behavior.
#
# Usage:
#   scripts/apply_bluesim_bram_patch.sh          # apply (idempotent; backs up the stock header)
#   scripts/apply_bluesim_bram_patch.sh restore  # restore the stock header from the backup
# The bsc install is found by scripts/bsc_lib.sh ($BSC_LIB / $BSC / ~/src/bsc/inst / PATH).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$("$HERE/bsc_lib.sh")
INST=$(dirname "$LIB")/Bluesim/bs_prim_mod_bram.h
BACKUP=${INST}.stock-bak

case "${1:-apply}" in
  apply)
    [ -f "$BACKUP" ] || cp "$INST" "$BACKUP"
    cp "$HERE/bluesim/bs_prim_mod_bram.h" "$INST"
    echo "applied strict-BRAM header -> $INST"
    ;;
  restore)
    if [ -f "$BACKUP" ]; then cp "$BACKUP" "$INST"; echo "restored stock header from $BACKUP"
    else echo "no backup at $BACKUP; reinstall bsc to restore" >&2; exit 1; fi
    ;;
  *)
    echo "usage: $0 [apply|restore]" >&2
    exit 2
    ;;
esac
