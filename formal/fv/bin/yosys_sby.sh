#!/bin/sh
# yosys_sby.sh: the sv-yosys binary for sby's model steps.  sby (0.5x) writes `abc -g AND -fast`
# into its AIGER model script; the newer abc pass has no -fast (a mapping speed option, no effect
# on the AIG's meaning), so it is dropped before yosys runs.  Everything else passes through.
# YOSYS: the real binary (set by bin/fvgen.py).
for a in "$@"; do
    case $a in
        *.ys) [ -f "$a" ] && grep -q 'abc -g AND -fast' "$a" && sed -i.bak 's/abc -g AND -fast/abc -g AND/' "$a" ;;
    esac
done
exec "$YOSYS" "$@"
