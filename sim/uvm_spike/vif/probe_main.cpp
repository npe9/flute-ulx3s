// probe_main.cpp — C++ bench for the vif probe: owns the clock,
// injects bytes via the SV DPI bridge, checks agent state.
#include "Vtb_top.h"
#include "Vtb_top__Dpi.h"
#include "verilated.h"
#include "svdpi.h"

#include <cstdio>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void run_cycles(Vtb_top* top, int n) {
    for (int i = 0; i < n * 2; i++) {   // n full clock periods
        top->clk = !top->clk;
        top->eval();
        main_time++;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_top* top = new Vtb_top;
    top->clk = 0;
    top->eval();           // run initial blocks (agents get the vif)

    // DPI exports operate on module scope — set it once (IEEE 35.5.3)
    svSetScope(svGetScopeFromName("TOP.tb_top"));

    run_cycles(top, 5);

    sv_inject_byte(0xA5);
    run_cycles(top, 20);
    int pend_after_first = sv_drv_pending();
    printf("[cpp] driver bits pending after 1st byte + 20 cy: %d\n", pend_after_first);

    sv_inject_byte(0x3C);
    run_cycles(top, 40);
    printf("[cpp] injected=%d pending=%d mon_sample=0x%02x\n",
           sv_injected_count(), sv_drv_pending(), sv_mon_sample() & 0xFF);

    int ok = 1;
    if (sv_injected_count() != 2) ok = 0;
    if (pend_after_first >= 10) ok = 0;          // bits shifted out
    if ((sv_mon_sample() & 0xFF) == 0) ok = 0;   // monitor saw toggling

    top->final();
    delete top;
    if (ok) { printf("VIF+DPI: PASS\n"); return 0; }
    printf("VIF+DPI: FAIL\n");
    return 1;
}
