// Health-test unit test for mkEntropy_Source_RO (SP 800-90B RCT 41 / APT 793 of 1024, 8:1 decimation).
#include "VmkTb_Entropy.h"
#include "VmkTb_Entropy___024root.h"
#include <verilated.h>
#include <cstdio>
#include <cstdlib>
#include <functional>
static VmkTb_Entropy* t;
static int fails = 0;
static void clk() { t->CLK = 0; t->eval(); t->CLK = 1; t->eval(); }
static unsigned opst() { return t->seed >> 30; }
static void reset() { t->RST_N = 0; t->EN_consume = 0; clk(); clk(); t->RST_N = 1; }
static void set_noise(int b) { t->rootp->mkTb_Entropy__DOT__m_ro__DOT__noise = b; }
// run n decimated samples where sample k's 8 raw bits XOR to f(k)
static void run(long n, std::function<int(long)> f, bool consume = false) {
    for (long k = 0; k < n; k++) {
        int s = f(k);
        for (int i = 0; i < 8; i++) { set_noise(i == 7 ? s : 0); t->EN_consume = consume && opst() == 2; clk(); t->EN_consume = 0; }
    }
}
static void expect(const char* what, bool ok) { printf("%-60s %s\n", what, ok ? "ok" : "FAIL"); if (!ok) fails++; }
static unsigned long long rng = 88172645463325252ULL;
static int rbit(long) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng & 1; }
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new VmkTb_Entropy;
    // 1. good noise: BIST for the first 1024-sample window, then ES16, never DEAD
    reset();
    expect("reset -> BIST", opst() == 0);
    run(1000, rbit);
    expect("still BIST before 1024 samples", opst() == 0);
    run(30, rbit);
    expect("startup window passed -> WAIT/ES16", opst() == 1 || opst() == 2);
    run(16, rbit);
    expect("16 samples later -> ES16", opst() == 2);
    unsigned w1 = t->seed;
    expect("ES16 reserved bits [29:16] zero", (w1 & 0x3FFF0000) == 0);
    // consume as one whole 8-clock group (noise 0), so sample groups stay aligned with the decimator
    t->EN_consume = 1; set_noise(0); clk(); t->EN_consume = 0;
    expect("consume -> WAIT", opst() == 1);
    for (int i = 0; i < 7; i++) clk();
    run(16, rbit);
    expect("next word ES16 and different", opst() == 2 && t->seed != w1);
    int n_es16 = 0, bad = 0;
    for (int i = 0; i < 2000; i++) { run(16, rbit, true); if (opst() == 2) n_es16++; if (opst() == 0 || opst() == 3) bad++; }
    expect("2000 words of good noise: no BIST/DEAD", bad == 0);
    // 2. stuck-at-0 noise: RCT fires within 41 samples -> BIST
    run(1, [](long) { return 1; });                     // break any run left by the random noise
    run(40, [](long) { return 0; });
    expect("40 identical samples: no RCT failure yet", opst() == 1 || opst() == 2);
    run(1, [](long) { return 0; });
    expect("41st identical sample -> BIST (RCT)", opst() == 0);
    // 3. stuck noise keeps failing: 4 failures without an ES16 -> DEAD (sticky)
    run(41 * 4, [](long) { return 1; });
    expect("4 consecutive failures -> DEAD", opst() == 3);
    run(5000, rbit);
    expect("DEAD is sticky", opst() == 3);
    // 4. biased noise (no long runs): APT fires; 80% ones in a 1024 window, runs <= 4
    reset();
    run(1100, rbit);
    expect("fresh start passes", opst() == 1 || opst() == 2);
    // APT compares each window against its FIRST sample, so a window opened by a 0 cannot trip;
    // 1024 % 5 = 4 shifts the alignment every window, so within 5 windows one opens on a 1
    bool tripped = false;
    for (int w = 0; w < 6 && !tripped; w++) { run(1024, [](long k) { return (k % 5) != 4; }); tripped = (opst() == 0); }
    expect("80% ones (no runs > 4) -> BIST (APT) within 6 windows", tripped);
    // 5. 75% ones (below the 793/1024 cutoff) passes
    reset();
    run(1100, rbit);
    bad = 0;
    for (int i = 0; i < 20; i++) { run(1024, [](long k) { return (k % 4) != 3; }, true); if (opst() == 0 || opst() == 3) bad++; }
    expect("75% ones (768/1024 < 793) passes APT", bad == 0);
    printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
    delete t;
    return fails ? 1 : 0;
}
