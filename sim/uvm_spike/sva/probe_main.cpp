// probe_main.cpp — clock driver for the clocked SVA/vif probes.
#include "Vtb_top.h"
#include "verilated.h"

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_top* top = new Vtb_top;
    top->clk = 0;
    while (main_time < 200 && !Verilated::gotFinish()) {
        top->clk = !top->clk;
        top->eval();
        main_time++;
    }
    top->final();
    delete top;
    return 0;
}
