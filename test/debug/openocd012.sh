#!/bin/sh
# The riscv-tests debug suite passes the newer OpenOCD's `gdb port 0` / `tcl port 0` /
# `telnet port disabled`; OpenOCD 0.12 (Homebrew) spells them gdb_port / tcl_port / telnet_port.
for a in "$@"; do
  case "$a" in
    "gdb port "*) a="gdb_port ${a#gdb port }" ;;
    "tcl port "*) a="tcl_port ${a#tcl port }" ;;
    "telnet port "*) a="telnet_port ${a#telnet port }" ;;
  esac
  set -- "$@" "$a"; shift
done
exec openocd "$@"
