// probe_main.cpp — C++ side of the J1 risk probe.
#include "Vtb_top.h"
#include "Vtb_top__Dpi.h"
#include "verilated.h"
#include "verilated_cov.h"
#include "svdpi.h"

static vluint64_t t = 0;
double sc_time_stamp() { return (double)t; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_top* top = new Vtb_top;
    top->clk = 0;
    top->eval();
    svSetScope(svGetScopeFromName("TOP.tb_top"));
    for (int i = 0; i < 10; i++) {
        top->clk = !top->clk;
        top->eval();
        t++;
    }
    int rc = sv_probe_final();
    printf("sv_probe_final rc=%d\n", rc);
    top->final();
#ifdef VM_COVERAGE
    VerilatedCov::write();
#endif
    delete top;
    if (rc == 0) { printf("J1RISK: PASS\n"); return 0; }
    printf("J1RISK: FAIL\n");
    return 1;
}
