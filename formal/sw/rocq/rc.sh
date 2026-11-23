#!/bin/sh
# formal/sw/rocq/rc.sh FILE.v...: rocq compile with the generated model's load paths (build.sh first)
HERE=$(cd "$(dirname "$0")" && pwd)
B=$HERE/../../../build/sail-coq
eval "$(opam env --switch=omp-rocq-9.0 --set-switch)"
exec rocq compile -R "$B/generated_definitions/coq/RV32" RV32 -R "$B/handwritten_support" Riscv_common -R "$HERE" Swfv "$@"
