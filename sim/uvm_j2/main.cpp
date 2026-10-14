// ================================================================
// main.cpp — J2 UVM bench main.  The clock and all stimulus live in
// SV (uvm_tb_top, --timing build); this loop only advances the model
// until $finish, then writes the coverage database to the file named
// by the +verilator+coverage+file+ plusarg.
// ================================================================

#include "Vuvm_tb_top.h"
#include "verilated.h"
#include "verilated_cov.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vuvm_tb_top* top = new Vuvm_tb_top;
    while (!Verilated::gotFinish()) {
        top->eval();
    }
    top->final();
#if VM_COVERAGE
    VerilatedCov::write();
#endif
    delete top;
    return 0;
}
