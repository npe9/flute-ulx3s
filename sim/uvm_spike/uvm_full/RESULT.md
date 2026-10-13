# uvm_full — SUPERSEDED 2026-10-10: full UVM IS available

The original J0 probe documented infeasibility ("no --uvm flag, no
uvm_pkg").  That conclusion was WRONG in one respect: no Verilator
5.0xx has a `--uvm` switch (verified: empty in V3Options.cpp), but
upstream's supported path is compiling the VENDORED UVM library sources
directly.  Verilator 5.052's headline feature is literally "supports UVM
2020-3.2"; the Homebrew formula just doesn't install the UVM tree.

This directory now holds the WORKING probe (from /tmp/uvm_check, saved
before /tmp wipe):

- Build: `~/src/verilator-uvm` (source build of tag v5.052, prefix
  self-contained; the Homebrew /opt/homebrew binary is untouched and
  remains the gate binary for F1/F2).  One Darwin fix: the source tree's
  flexfix int->size_t rewrite disabled (Homebrew formula's own inreplace).
- Recipe (no --uvm flag): `verilator --binary --timing -Wno-lint
  -Wno-style --top-module tb_top
  +incdir+$HOME/src/verilator-uvm/share/verilator/uvm
  $HOME/src/verilator-uvm/share/verilator/uvm/uvm_pkg_all_v2020_3_2_nodpi.svh
  <your_tb>.sv` — end-to-end via run.sh (env knobs TB, VARIANT, VERILATOR,
  UVM_DIR).  DPI variant needs --vpi + a malloc/malloc.h shim (see dpishim/).
- Feature checklist (tb_uvm_full.sv): uvm_pkg compiles (all 6 vendored
  variants); factory type_id::create; build/connect/run/report phases;
  run_test; config_db virtual-if set/get; objections; uvm_sequence +
  sequencer + driver handshake; sequence_item.randomize(); report server;
  UVM 1.2 (v2017_1_0) and UVM 2020-3.2 DPI variants; --timing event
  control inside phases.  ALL PASS (rc=0, 0 errors/0 fatal).
- Drop-in check: PATH=~/src/verilator-uvm/bin:$PATH
  ./sim/strict_bram/run.sh --lint-only -> LINT OK (105 files).

See HANDOFF.md "Track J status" for the migration decision this enables.
