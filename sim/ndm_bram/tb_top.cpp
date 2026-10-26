#include <ctime>
// ================================================================
// tb_top.cpp — Verilator C++ bench for the F1 strict-BRAM sim, J1
// phase-1 wiring: the scenario FSM stays HERE (clock, reset pin,
// deadlines, image framing, boot->load->hello flow), but the UART
// bit-level plumbing moved into the SV agents through the DPI bridge
// (see sv_tb_top.sv):
//
//   send_byte()/rx_bits            -> sv_inject_byte()  (SV driver)
//   tx_sample()/tx_log/tx_stream   -> sv_tx_avail()/sv_tx_byte()
//                                     (SV monitor, polled per cycle)
//
// The polling point is the negedge half of each cycle (right after
// top->eval() with clk=0), which reproduces the exact cycle indices
// of the original post-posedge tx_sample() call, so the observable
// milestone cycles are unchanged.  At end of run, sv_final_checks()
// runs the scoreboard verdict and samples coverage; the coverage
// database is written with VerilatedCov::write() to the file named by
// the +verilator+coverage+file+<path> plusarg (run.sh sets it under
// the build dir, never to stdout).
//
// Scenario (unchanged from F1):
//   1. power-on reset (src/Top.v counts 256 clocks, BTN1 held low)
//   2. wait for the boot ROM banner on the FPGA TX pin
//   3. send the loader header <dst,len> then the image in 256-byte
//      framed chunks, ACK(0x06)/NAK(0x15)-paced
//   4. wait for the head/tail readback line, then the repair window,
//      then the jump to SDRAM
//   5. PASS when hello.bin's first banner + first "tick 00000000"
//      line have been received, the SV scoreboard's golden checks
//      pass, and no strict-BRAM violation fired
//
// UART: 25 MHz sys_clk, 625000 baud -> 40 cycles/bit.  The SV driver
// holds each bit for the exact cadence the original C++ bench used.
//
// STRICT_BRAM mode: env STRICT_BRAM forwarded as a +STRICT_BRAM=
// plusarg unless already on the command line.  +verilator+seed+N is
// accepted (F2 sweep).  +dump_tx=1 prints the received TX transcript
// as hex (diagnostic; off by default so the F2 sweep stdout filter
// is unaffected).
// ================================================================

#include "Vsv_tb_top.h"
#include "Vsv_tb_top__Dpi.h"
#include "verilated.h"
#include "verilated_cov.h"
#if VM_TRACE_VCD
#include "verilated_vcd_c.h"
#endif
#include "svdpi.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

// ----------------------------------------------------------------
// DUT + board state

static Vsv_tb_top* top = nullptr;
static vluint64_t  g_cycle = 0;

// ----------------------------------------------------------------
// UART TX view (FPGA -> host): bytes assembled by the SV monitor,
// polled once per cycle through the DPI bridge.

static std::string     tx_log;    // every received byte, in order
static std::deque<int> tx_stream; // byte queue for ACK/NAK scanning
static size_t          tx_polled = 0;
static int             dump_tx   = 0;

static int tx_trace = 0;             // TB_TX_TRACE=1: print every TX byte with its cycle
static int tx_echo = 0;              // TB_ECHO=1: copy TX bytes to stdout as they arrive (Linux console)
static const char* isa_pass_str = nullptr;   // TB_PASS_STR: in TB_ISA mode, pass when TX contains this
static unsigned long long progress_every = 0; // TB_PROGRESS=N: print cycle + wall time every N cycles
static int perf_on = 0;              // TB_PERF=1 (trace builds): per-phase I/D-side cycle accounting at each progress tick
static void poll_tx() {
    int avail = sv_tx_avail();
    while ((int)tx_polled < avail) {
        int b = sv_tx_byte((int)tx_polled);
        if (b < 0) break;
        tx_log += (char)(b & 0xFF);
        if (tx_trace) printf("[tb] tx 0x%02x at cycle %llu\n", b & 0xFF, (unsigned long long)g_cycle);
        if (tx_echo) { fputc(b & 0xFF, stdout); if ((b & 0xFF) == '\n') fflush(stdout); }
        tx_stream.push_back(b & 0xFF);
        tx_polled++;
    }
}

// ----------------------------------------------------------------
// UART RX stimulus (host -> FPGA): bytes handed to the SV driver.

static void send_byte(uint8_t b) {
    sv_inject_byte((int)b);
}
static void send_bytes(const std::vector<uint8_t>& v) {
    for (uint8_t b : v) send_byte(b);
}

// ----------------------------------------------------------------
// Scenario

enum Stage {
    ST_BANNER = 0,   // wait for the boot ROM banner
    ST_CHUNKS,       // send framed chunks, ACK-paced
    ST_READBACK,     // wait for ']' of the head/tail readback
    ST_HELLO,        // wait for hello banner + first tick line
    ST_ISA,          // TB_ISA: image preloaded, jumped; wait for tohost
    ST_NDM,          // TB_NDM: debug-module ndmreset over the UART DMI bridge, wait for the ROM rerun
    ST_PASS,
    ST_FAIL
};

static Stage stage = ST_BANNER;
static vluint64_t stage_start = 0;
static std::vector<uint8_t> image;
static size_t chunk_idx = 0;
static int    n_retries = 0;
static size_t tx_scan = 0;           // tx_stream scan position
static bool   saw_hello_banner = false;
static bool   saw_tick0 = false;

// TB_NDM=K (sim/ndm_bram): K debug-module SoC resets (dmcontrol.ndmreset) while the boot ROM
// loops on its banner (every fetch is a boot-ROM device read through the I-side).  Reset k is
// sent TB_NDM_DELAY0 + k * TB_NDM_STEP cycles after the banner, so the resets land at different
// phases of the I$ device-read / ROM-response pipeline.  After each, the hart must leave reset
// and rerun the ROM (its "T12345678" SDRAM self-test line) within the stage deadline.  Then the
// image is loaded and must run as usual.
static int        ndm_total = 0, ndm_done = 0;
static vluint64_t ndm_delay0 = 1000, ndm_step = 37, ndm_send_at = 0;
static bool       ndm_sent = false;
// TB_NDM_AT=<cycle> (TB_ISA / linux_run.py runs): the first reset fires at that cycle while the
// preloaded program (e.g. Linux booting: I$ and D$ refills, write-backs in flight) runs; after
// the resets the ROM loads TB_NDM_RELOAD (default sw/hello.bin) and it must run as usual.
static vluint64_t ndm_at = 0;
static std::string ndm_reload = "../../sw/hello.bin";
static size_t     banner_mark = 0, ndm_mark = 0;
// The bridge's 6-byte responses ([0xDB, status, data x4]) interleave with console output and
// can split the banner: match console text with them removed (the ROM prints ASCII only).
static std::string strip_dmi(const std::string& t) {
    std::string o;
    for (size_t i = 0; i < t.size(); i++) {
        if ((unsigned char)t[i] == 0xDB) { i += 5; continue; }
        o += t[i];
    }
    return o;
}
static void send_ndm_reset() {
    static const uint8_t magic[] = { 0xDB, 'S', 'D', 'M', 1, 2, 3, 4 };
    std::vector<uint8_t> v(magic, magic + sizeof magic);
    const uint8_t w3[] = { 'w', 0x10, 0, 0, 0, 3 };    // dmcontrol <- dmactive | ndmreset
    const uint8_t w1[] = { 'w', 0x10, 0, 0, 0, 1 };    // release
    const uint8_t q[]  = { 'q', 0, 0, 0, 0, 0 };       // disarm
    v.insert(v.end(), w3, w3 + 6);
    v.insert(v.end(), w1, w1 + 6);
    v.insert(v.end(), q, q + 6);
    send_bytes(v);
}

// TB_ISA (sim/isa_bram): sdram_model reports the first nonzero tohost write
static bool   isa_mode = false;
static int    g_tohost = 0;
extern "C" void tb_tohost(int v) { if (!g_tohost) g_tohost = v; }

static void fail(const char* what) {
    printf("[tb] FAIL at cycle %llu: %s (stage %d, %llu cycles in stage)\n",
           (unsigned long long)g_cycle, what, (int)stage,
           (unsigned long long)(g_cycle - stage_start));
    // dump the tail of what the SoC said for debugging
    std::string tail = tx_log.substr(tx_log.size() > 400 ? tx_log.size() - 400 : 0);
    printf("[tb] ----- TX tail -----\n%s\n[tb] -------------------\n", tail.c_str());
    stage = ST_FAIL;
}

static size_t stage_mark = 0;        // tx_log position at stage entry
static void new_stage(Stage s) {
    stage = s;
    stage_start = g_cycle;
    stage_mark = tx_log.size();
    tx_scan = tx_stream.size();    // ignore bytes from before the stage
}

// deadline check for the current stage; returns true on timeout
static bool deadline(vluint64_t cycles) {
    return (g_cycle - stage_start) > cycles;
}

#if VM_TRACE_VCD
#include "Vsv_tb_top___024root.h"
// TB_STALL_WATCH=<cycles>: in the post-jump stage, fail with a state snapshot when
// minstret has not advanced for that many cycles (locates a hang without a VCD).
#define TOP_SIG(x) (top->rootp->sv_tb_top__DOT__board__DOT__top__DOT__top__DOT__##x)
#define CPU_SIG(x) (top->rootp->sv_tb_top__DOT__board__DOT__top__DOT__top__DOT__soc_top__DOT__core__DOT__cpu__DOT__##x)
// TB_PERF: ICache_Pipe IState (10) and MMU_Cache Module_State (RV32, 19) histograms, event counts.
struct Perf {
    unsigned long long cyc, ist[16], dst[32], priv[4], s1_empty;
    unsigned long long i_refill, i_walk, d_refill, d_walk, i_lat, i_beat;
    unsigned last_ist, last_dst;
    // Memory side: Mem_Controller (1 raw-word cache) and Sdram_Controller state accounting.
    unsigned long long mc_reload, mc_reload_busy, mc_wb, mc_reloading, sd_st[32], sd_rd, sd_wr, sd_busy_rd, sd_busy_wr;
    unsigned last_mc, last_mc_clean, last_sd;
    // Reload cause (head of Mem_Controller f_reqs = last merged request) and I-refill timeline:
    // t0 REFILL_REQ entry -> AR at Mem_Controller -> reload start -> reload end -> first beat at I$.
    unsigned long long mc_rl_rd, mc_rl_wr, mc_ar, mc_aw, ir_n, ir_arr, ir_rl, ir_rld, ir_b1, ir_hit;
    unsigned last_merge_wr, ir_phase, last_ibeat; unsigned long long ir_t0, ir_t1, ir_t2, ir_t3;
};
static Perf perf_cur, perf_tot;
static const char* sd_name[] = {"PWR_WAIT","PRE_ALL","PRE_ALL_WAIT","INIT_REF1","INIT_REF1_WAIT","INIT_REF2","INIT_REF2_WAIT",
    "MRS","MRS_WAIT","IDLE","ACT","RCD_WAIT","RD","RD_CAP","WR","WR_DATA","WR_END","REF","REF_WAIT"};
static const char* ist_name[] = {"RUN","REFILL_REQ","REFILL","IO_REQ","IO_RSP","FLUSH","PTW1_REQ","PTW1_RSP","PTW0_REQ","PTW0_RSP"};
static const char* dst_name[] = {"PRERESET","RESETTING","READY","RUNNING","EXC_RSP","UDTLB_FILL","PTW_START","PTW_L1","PTW_L0","START_REFILL",
    "SNAPSHOT","REFILL","REREQ","AMO_EXEC","ST_AMO_RSP","IO_REQ","IO_AWAIT_W","IO_AWAIT_R","IO_READ_RSP","IO_AWAIT_AMO"};
static void perf_sample(Vsv_tb_top* top) {
    Perf& p = perf_cur;
    unsigned ist = CPU_SIG(near_mem__DOT__icache__DOT__rg_st) & 15;
    unsigned dst = CPU_SIG(near_mem__DOT__dcache__DOT__rg_state) & 31;
    p.cyc++; p.ist[ist]++; p.dst[dst]++; p.priv[CPU_SIG(rg_cur_priv) & 3]++;
    if (!CPU_SIG(stage1_rg_full)) p.s1_empty++;
    if (ist == 2) { if (CPU_SIG(near_mem__DOT__icache__DOT__rg_beat) == 0) p.i_lat++; else p.i_beat++; }
    if (ist == 1 && p.last_ist != 1) p.i_refill++;
    if (ist == 6 && p.last_ist != 6) p.i_walk++;
    if (dst == 9 && p.last_dst != 9) p.d_refill++;   // START_REFILL
    if (dst == 6 && p.last_dst != 6) p.d_walk++;     // PTW_START
    unsigned prev_ist = p.last_ist;
    p.last_ist = ist; p.last_dst = dst;
    // Streaming Mem_Controller: mc 2 = a read is outstanding (f_rd_pend non-empty), 3 = none
    unsigned mc = TOP_SIG(soc_top__DOT__mem0_controller__DOT__f_rd_pend__DOT__empty_reg) & 1 ? 2 : 3;
    unsigned clean = TOP_SIG(soc_top__DOT__mem0_controller__DOT__rg_buf_dirty) == 0;   // write-buffer dirty mask
    unsigned sd = TOP_SIG(mem_rg_state) & 31, sdw = (TOP_SIG(mem_rg_req)[9] >> 23) & 1;   // Raw_Mem_Req.write = bit 311 (312-bit struct)
    unsigned chunk_v = TOP_SIG(soc_top__DOT__mem0_controller__DOT__slave_xactor_f_rd_data__DOT__ENQ) & 1;  // an R beat leaves Mem_Controller
    static unsigned last_chunk_v = 0;
    p.sd_st[sd]++;
    if (sd >= 10 && sd <= 16) { if (sdw) p.sd_busy_wr++; else p.sd_busy_rd++; }
    bool sd_start = (sd == 12 || sd == 14) && p.last_sd == 9;   // IDLE -> RD / WR (ACT goes out with the IDLE cycle)
    if (sd_start) { if (sdw) p.sd_wr++; else p.sd_rd++; }
    if (mc == 2) p.mc_reloading++;
    if (mc == 2 && p.last_mc != 2) { p.mc_reload++; if (p.last_sd != 9) p.mc_reload_busy++; }
    if (clean && !p.last_mc_clean && p.last_mc != 2) p.mc_wb++;
    unsigned ar_enq = TOP_SIG(soc_top__DOT__mem0_controller__DOT__slave_xactor_f_rd_addr__DOT__ENQ) & 1;
    unsigned aw_enq = TOP_SIG(soc_top__DOT__mem0_controller__DOT__slave_xactor_f_wr_addr__DOT__ENQ) & 1;
    unsigned ar_deq = TOP_SIG(soc_top__DOT__mem0_controller__DOT__slave_xactor_f_rd_addr__DOT__DEQ) & 1;
    unsigned aw_deq = TOP_SIG(soc_top__DOT__mem0_controller__DOT__slave_xactor_f_wr_addr__DOT__DEQ) & 1;
    p.mc_ar += ar_enq; p.mc_aw += aw_enq;
    if (mc == 2 && p.last_mc != 2) { if (p.last_merge_wr) p.mc_rl_wr++; else p.mc_rl_rd++; }
    if (ar_deq) p.last_merge_wr = 0; else if (aw_deq) p.last_merge_wr = 1;   // rd has priority at merge
    // I-refill timeline (only while the D side is not refilling or walking, so the path is the I side's)
    unsigned ibeat = CPU_SIG(near_mem__DOT__icache__DOT__rg_beat);
    bool d_quiet = !(dst >= 5 && dst <= 12);   // UDTLB_FILL .. REREQ
    if (ist == 1 && prev_ist != 1) { p.ir_phase = d_quiet ? 1 : 0; p.ir_t0 = p.cyc; }
    if (p.ir_phase && !d_quiet) p.ir_phase = 0;
    if (p.ir_phase == 1 && ar_enq) { p.ir_t1 = p.cyc; p.ir_phase = 2; }
    if (p.ir_phase == 2 && sd_start && !sdw) { p.ir_t2 = p.cyc; p.ir_phase = 3; }   // SDRAM request start (ACT) for the read
    if (p.ir_phase == 2 && ist == 2 && ibeat != 0 && p.last_ibeat == 0) { p.ir_hit++; p.ir_phase = 0; }  // (no ACT seen: should not happen)
    if (p.ir_phase == 3 && chunk_v) { p.ir_t3 = p.cyc; p.ir_phase = 4; }                                 // first R beat out of Mem_Controller
    if (p.ir_phase == 4 && ist == 2 && ibeat != 0 && p.last_ibeat == 0) {
        p.ir_n++; p.ir_arr += p.ir_t1 - p.ir_t0; p.ir_rl += p.ir_t2 - p.ir_t1; p.ir_rld += p.ir_t3 - p.ir_t2; p.ir_b1 += p.cyc - p.ir_t3;
        p.ir_phase = 0;
    }
    static int dbg_n = getenv("TB_PERF_DBG") ? atoi(getenv("TB_PERF_DBG")) : 0;
    static unsigned dbg_last_phase = 0;
    if (dbg_n > 0 && (p.ir_phase != dbg_last_phase || (ist == 1 && prev_ist != 1))) {
        printf("[irdbg] cyc %llu ist %u prev %u dst %u mc %u ar_enq %u ibeat %u phase %u->%u\n", p.cyc, ist, prev_ist, dst, mc, ar_enq, ibeat, dbg_last_phase, p.ir_phase);
        dbg_n--;
    }
    dbg_last_phase = p.ir_phase;
    p.last_ibeat = ibeat;
    p.last_mc = mc; p.last_mc_clean = clean; p.last_sd = sd; last_chunk_v = chunk_v;
}
static void perf_print(const char* tag, const Perf& p, unsigned long long inst) {
    if (!p.cyc) return;
    double c = (double)p.cyc;
    printf("[perf] %s cycles %llu instret %llu IPC %.3f | priv M %.1f%% S %.1f%% U %.1f%% | stage1 empty %.1f%%\n", tag, p.cyc, inst,
           inst / c, 100 * p.priv[3] / c, 100 * p.priv[1] / c, 100 * p.priv[0] / c, 100 * p.s1_empty / c);
    printf("[perf]   I: refills %llu (%.1f cyc each: lat %.1f beats %.1f) walks %llu |", p.i_refill,
           p.i_refill ? (double)(p.ist[1] + p.ist[2]) / p.i_refill : 0.0, p.i_refill ? (double)p.i_lat / p.i_refill : 0.0,
           p.i_refill ? (double)p.i_beat / p.i_refill : 0.0, p.i_walk);
    for (int i = 0; i < 10; i++) if (p.ist[i]) printf(" %s %.1f%%", ist_name[i], 100 * p.ist[i] / c);
    printf("\n[perf]   D: refills %llu walks %llu |", p.d_refill, p.d_walk);
    for (int i = 0; i < 20; i++) if (p.dst[i] && i != 3) printf(" %s %.1f%%", dst_name[i], 100 * p.dst[i] / c);
    printf("\n[perf]   M: read bursts %llu (%.1f cyc outstanding each, %.1f%% started while SDRAM busy) writebacks %llu | SDRAM rd %llu wr %llu busy rd %.1f%% wr %.1f%% |",
           p.mc_reload, p.mc_reload ? (double)p.mc_reloading / p.mc_reload : 0.0, p.mc_reload ? 100.0 * p.mc_reload_busy / p.mc_reload : 0.0,
           p.mc_wb, p.sd_rd, p.sd_wr, 100 * p.sd_busy_rd / c, 100 * p.sd_busy_wr / c);
    for (int i = 9; i < 19; i++) if (p.sd_st[i]) printf(" %s %.1f%%", sd_name[i], 100 * p.sd_st[i] / c);
    printf("\n[perf]   M: AR %llu AW %llu", p.mc_ar, p.mc_aw);
    if (p.ir_n || p.ir_hit) printf(" | I-refill timeline (%llu clean samples, %llu no-ACT): req->AR@MC %.1f AR->ACT %.1f ACT->R1@MC %.1f R1->beat1 %.1f",
                       p.ir_n, p.ir_hit, p.ir_n ? (double)p.ir_arr / p.ir_n : 0.0, p.ir_n ? (double)p.ir_rl / p.ir_n : 0.0, p.ir_n ? (double)p.ir_rld / p.ir_n : 0.0, p.ir_n ? (double)p.ir_b1 / p.ir_n : 0.0);
    printf("\n");
}
static void perf_roll(unsigned long long minstret) {
    static unsigned long long last_inst = 0;
    perf_print("window", perf_cur, minstret - last_inst);
    Perf& t = perf_tot; const Perf& p = perf_cur;
    t.cyc += p.cyc; t.s1_empty += p.s1_empty; t.i_refill += p.i_refill; t.i_walk += p.i_walk; t.d_refill += p.d_refill;
    t.d_walk += p.d_walk; t.i_lat += p.i_lat; t.i_beat += p.i_beat;
    t.mc_reload += p.mc_reload; t.mc_reload_busy += p.mc_reload_busy; t.mc_wb += p.mc_wb; t.mc_reloading += p.mc_reloading;
    t.sd_rd += p.sd_rd; t.sd_wr += p.sd_wr; t.sd_busy_rd += p.sd_busy_rd; t.sd_busy_wr += p.sd_busy_wr;
    for (int i = 0; i < 32; i++) t.sd_st[i] += p.sd_st[i];
    t.mc_rl_rd += p.mc_rl_rd; t.mc_rl_wr += p.mc_rl_wr; t.mc_ar += p.mc_ar; t.mc_aw += p.mc_aw; t.ir_n += p.ir_n; t.ir_hit += p.ir_hit;
    t.ir_arr += p.ir_arr; t.ir_rl += p.ir_rl; t.ir_rld += p.ir_rld; t.ir_b1 += p.ir_b1;
    for (int i = 0; i < 16; i++) t.ist[i] += p.ist[i];
    for (int i = 0; i < 32; i++) t.dst[i] += p.dst[i];
    for (int i = 0; i < 4; i++) t.priv[i] += p.priv[i];
    unsigned li = p.last_ist, ld = p.last_dst, lm = p.last_mc, lc = p.last_mc_clean, ls = p.last_sd;
    perf_cur = Perf(); perf_cur.last_ist = li; perf_cur.last_dst = ld;
    perf_cur.last_mc = lm; perf_cur.last_mc_clean = lc; perf_cur.last_sd = ls;
    perf_cur.last_merge_wr = p.last_merge_wr; perf_cur.last_ibeat = p.last_ibeat;   // timeline phase restarts per window
    last_inst = minstret;
}
static void stall_snapshot(Vsv_tb_top* top, vluint64_t g_cycle) {
    printf("[tb] STALL SNAPSHOT at cycle %llu: minstret=%llu cpu.rg_state=%u next_pc=%08x full F/D/1/2/3=%u%u%u%u%u dreq_pending empty=%u full=%u near_mem.rg_state=%u\n",
           (unsigned long long)g_cycle, (unsigned long long)CPU_SIG(csr_regfile__DOT__rg_minstret), CPU_SIG(rg_state), CPU_SIG(rg_next_pc),
           CPU_SIG(stageF_rg_full), !CPU_SIG(stageD_f_data__DOT__empty_reg), CPU_SIG(stage1_rg_full), CPU_SIG(stage2_rg_full), CPU_SIG(stage3_rg_full),
           CPU_SIG(stage2_f_dreq_pending__DOT__empty_reg), CPU_SIG(stage2_f_dreq_pending__DOT__full_reg), CPU_SIG(near_mem__DOT__rg_state));
    printf("[tb]   dcache: state=%u busy=%u kill_echo=%u op=%u addr=%08x req_seq=%u age_seen=%u\n",
           CPU_SIG(near_mem__DOT__dcache__DOT__rg_state), CPU_SIG(near_mem__DOT__dcache__DOT__rg_busy_mirror), CPU_SIG(near_mem__DOT__dcache__DOT__rg_kill_echo),
           CPU_SIG(near_mem__DOT__dcache__DOT__rg_op), CPU_SIG(near_mem__DOT__dcache__DOT__rg_addr), CPU_SIG(near_mem__DOT__dcache__DOT__rg_req_seq), CPU_SIG(near_mem__DOT__dcache__DOT__rg_age_seen));
    // E20: I-side is ICache_Pipe (the I MMU_Cache and the Imem_Decoup shim are retired)
    printf("[tb]   icache: st=%u want=%u pc=%08x pf=%08x halt_io=%u halt_exc=%u s1=%u s2=%u stale=%u miss=%08x\n",
           CPU_SIG(near_mem__DOT__icache__DOT__rg_st), CPU_SIG(near_mem__DOT__icache__DOT__rg_want), CPU_SIG(near_mem__DOT__icache__DOT__rg_pc),
           CPU_SIG(near_mem__DOT__icache__DOT__rg_pf) << 3, CPU_SIG(near_mem__DOT__icache__DOT__rg_halt_io), CPU_SIG(near_mem__DOT__icache__DOT__rg_halt_exc),
           CPU_SIG(near_mem__DOT__icache__DOT__rg_s1_v), CPU_SIG(near_mem__DOT__icache__DOT__rg_s2_v), CPU_SIG(near_mem__DOT__icache__DOT__rg_stale),
           CPU_SIG(near_mem__DOT__icache__DOT__rg_miss_a) << 3);
}
#endif

int main(int argc, char** argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);   // line-buffered: progress under load

    // STRICT_BRAM env -> plusarg forwarding (run.sh sets it; a direct
    // +STRICT_BRAM=... plusarg on the command line wins).
    const char* env_strict = getenv("STRICT_BRAM");
    bool plusarg_from_cmdline = false;

    const char* image_path = "../../sw/hello.bin";
    for (int i = 1; i < argc; i++) {
        if (strstr(argv[i], "+STRICT_BRAM=") == argv[i]) plusarg_from_cmdline = true;
        else if (strstr(argv[i], "+dump_tx=") == argv[i]) dump_tx = atoi(argv[i] + 9);
        else if (argv[i][0] != '+') image_path = argv[i];
    }

    // one shot: original args (+ synthesized STRICT_BRAM plusarg)
    std::vector<const char*> args;
    for (int i = 0; i < argc; i++) args.push_back(argv[i]);
    static std::string synthesized;
    if (env_strict && *env_strict && !plusarg_from_cmdline) {
        synthesized = std::string("+STRICT_BRAM=") + env_strict;
        args.push_back(synthesized.c_str());
    }
    if (getenv("TB_NDM")) args.push_back("+SB_OFF");
    Verilated::commandArgs((int)args.size(), (char**)&args[0]);
    tx_trace = getenv("TB_TX_TRACE") != nullptr;
    tx_echo = getenv("TB_ECHO") != nullptr;
    isa_pass_str = getenv("TB_PASS_STR");
    if (const char* pe = getenv("TB_PROGRESS")) progress_every = strtoull(pe, nullptr, 10);
    if (const char* pf = getenv("TB_PERF")) perf_on = atoi(pf);
    if (const char* n = getenv("TB_NDM")) ndm_total = atoi(n);
    if (const char* n = getenv("TB_NDM_DELAY0")) ndm_delay0 = strtoull(n, nullptr, 10);
    if (const char* n = getenv("TB_NDM_STEP")) ndm_step = strtoull(n, nullptr, 10);
    if (const char* n = getenv("TB_NDM_AT")) ndm_at = strtoull(n, nullptr, 10);
    if (const char* n = getenv("TB_NDM_RELOAD")) ndm_reload = n;

    printf("[tb] image: %s\n", image_path);
    if (env_strict) printf("[tb] STRICT_BRAM=%s\n", env_strict);
    printf("[tb] scenario: boot (J1 phase 1: boot only)\n");

    {   // read the payload
        std::ifstream f(image_path, std::ios::binary);
        if (!f) { fprintf(stderr, "[tb] cannot open %s\n", image_path); return 2; }
        image.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    }
    printf("[tb] payload: %zu bytes (%zu chunks of 256)\n",
           image.size(), (image.size() + 255) / 256);

    top = new Vsv_tb_top;
#if VM_TRACE_VCD
    VerilatedVcdC* tfp = nullptr;            // TB_TRACE=<file.vcd> [TB_TRACE_FROM/TO=<cycle>]
    vluint64_t tr_from = 0, tr_to = ~0ULL;
    if (const char* tf = getenv("TB_TRACE")) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC; top->trace(tfp, 99); tfp->open(tf);
        if (const char* a = getenv("TB_TRACE_FROM")) tr_from = strtoull(a, nullptr, 10);
        if (const char* b = getenv("TB_TRACE_TO"))   tr_to   = strtoull(b, nullptr, 10);
        printf("[tb] VCD trace %s cycles %llu..%llu\n", tf, (unsigned long long)tr_from, (unsigned long long)tr_to);
    }
#define TB_DUMP(t) do { if (tfp && g_cycle >= tr_from) { if (g_cycle <= tr_to) tfp->dump((vluint64_t)(t)); else { tfp->close(); tfp = nullptr; } } } while (0)
#else
#define TB_DUMP(t) do {} while (0)
#endif

    top->clk = 0;
    top->btn1 = 0;          // FIRE1 not pressed: power-on reset only
    top->jtag_tck = 0;      // JTAG TAP tied off
    top->jtag_tms = 0;
    top->jtag_tdi = 0;

    // NOTE: no eval() here — the first eval below is posedge #1, exactly
    // like the original C++ bench (initial blocks run inside it).  The
    // DPI scope is set right after that first eval, before any agent
    // interaction can occur.

    // src/Top.v: power_on_reset is an 8-bit counter -> 256 clocks of
    // reset; give it a little margin, the banner needs SDRAM init
    // (~200 us power-up wait = 5000 clocks) on top.
    vluint64_t banner_deadline   = 50000000;   // 2 s
    if (const char* bd = getenv("TB_BANNER_DEADLINE")) banner_deadline = strtoull(bd, nullptr, 10);
    vluint64_t chunk_deadline    = 200000000;  // 8 s per ACK
    vluint64_t readback_deadline = 200000000;
    vluint64_t hello_deadline    = 600000000;  // repair window is ~10 s+
    if (const char* hd = getenv("TB_HELLO_DEADLINE")) hello_deadline = strtoull(hd, nullptr, 10);  // override for short diagnostic runs
    if (const char* ia = getenv("TB_ISA")) isa_mode = (atoi(ia) != 0);
    vluint64_t overall_deadline  = 900000000;

    int dpi_ready = 0;
#if VM_TRACE_VCD
    vluint64_t stall_watch = 0, stall_last_cycle = 0, stall_last_minstret = 0, stall_next_report = 0;
    if (const char* sw = getenv("TB_STALL_WATCH")) stall_watch = strtoull(sw, nullptr, 10);
#endif

    while (stage != ST_PASS && stage != ST_FAIL) {
        if (g_cycle > overall_deadline) { fail("overall deadline"); break; }

        // ---- one 25 MHz clock: posedge then negedge ---------------
        top->clk = 1;
        top->eval();
        g_cycle++;
        TB_DUMP(2 * g_cycle);

        if (!dpi_ready) {
            // initial blocks have now run: agents exist.  One-time DPI
            // setup, before any agent interaction can occur.
            svSetScope(svGetScopeFromName("TOP.sv_tb_top"));
            size_t n_chunks = (image.size() + 255) / 256;
            size_t last_len = image.size() - 256 * (n_chunks - 1);
            sv_sb_set_expected((int)n_chunks, (int)last_len);
            dpi_ready = 1;
        }

        top->clk = 0;
        top->eval();
        TB_DUMP(2 * g_cycle + 1);

        // pull freshly assembled monitor bytes (negedge tick ran above)
        poll_tx();
#if VM_TRACE_VCD
        if (stall_watch && stage == ST_HELLO) {
            vluint64_t m = CPU_SIG(csr_regfile__DOT__rg_minstret);
            if (m != stall_last_minstret) { stall_last_minstret = m; stall_last_cycle = g_cycle; }
            else if (g_cycle - stall_last_cycle > stall_watch) {
                printf("[tb] no retirement since cycle %llu (minstret %llu)\n", (unsigned long long)stall_last_cycle, (unsigned long long)m);
                stall_snapshot(top, g_cycle);
                fail("retirement stalled");
                break;
            }
            if (g_cycle >= stall_next_report) {
                printf("[tb] progress cycle %llu minstret %llu next_pc %08x\n", (unsigned long long)g_cycle, (unsigned long long)m, CPU_SIG(rg_next_pc));
                stall_next_report = g_cycle + 2000000;
            }
        }
#endif

        // ---- scenario state machine -------------------------------
        switch (stage) {
          case ST_BANNER:
            if (strip_dmi(tx_log.substr(banner_mark)).find("ULX3S Flute SoC") != std::string::npos) {
                printf("[tb] banner seen at cycle %llu\n", (unsigned long long)g_cycle);
                if (ndm_done < ndm_total && ! (ndm_at && ndm_done == 0)) {    // TB_NDM_AT: first reset from ST_ISA
                    ndm_send_at = g_cycle + ndm_delay0 + (vluint64_t)ndm_done * ndm_step;
                    ndm_sent = false;
                    new_stage(ST_NDM);
                    break;
                }
                if (isa_mode) {    // jump to the preloaded image (count 0: no load)
                    std::vector<uint8_t> hdr = { 0x00, 0x00, 0x00, 0x80, 0, 0, 0, 0 };
                    send_bytes(hdr);
                    new_stage(ST_ISA);
                    break;
                }
                // loader header: u32le dst, u32le len (chunked path:
                // word-aligned dst, word-aligned nonzero len)
                std::vector<uint8_t> hdr;
                uint32_t dst = 0x80000000u;
                uint32_t len = (uint32_t)image.size();
                for (int i = 0; i < 4; i++) hdr.push_back((dst >> (8 * i)) & 0xFF);
                for (int i = 0; i < 4; i++) hdr.push_back((len >> (8 * i)) & 0xFF);
                send_bytes(hdr);
                // first chunk, framed: seq, data, xor, 0x55
                chunk_idx = 0;
                {
                    size_t off = 0, m = image.size() < 256 ? image.size() : 256;
                    uint8_t x = 0;
                    for (size_t i = 0; i < m; i++) x ^= image[off + i];
                    std::vector<uint8_t> fr;
                    fr.push_back((uint8_t)(chunk_idx & 0xFF));
                    for (size_t i = 0; i < m; i++) fr.push_back(image[off + i]);
                    fr.push_back(x);
                    fr.push_back(0x55);
                    send_bytes(fr);
                    sv_sb_note_chunk_txn();
                }
                new_stage(ST_CHUNKS);
            } else if (deadline(banner_deadline)) {
                fail("no boot banner on TX");
            }
            break;

          case ST_NDM:
            if (!ndm_sent) {
                if (g_cycle >= ndm_send_at) {
                    send_ndm_reset();
                    ndm_sent = true;
                    ndm_mark = tx_log.size();
                    printf("[tb] ndmreset %d/%d: bridge frames queued at cycle %llu\n",
                           ndm_done + 1, ndm_total, (unsigned long long)g_cycle);
                }
                break;
            }
            {
                // The ROM's self-test line "T12345678 9abcdef0".  A reset that lands while the UART
                // is mid-character (Linux printing) desynchronizes the bench's UART monitor for a
                // few bytes, so accept either intact half.
                size_t t = tx_log.find("12345678", ndm_mark);
                if (t == std::string::npos) t = tx_log.find("9abcdef0", ndm_mark);
                if (t != std::string::npos) {
                    ndm_done++;
                    printf("[tb] ndmreset %d/%d: ROM rerun at cycle %llu (%llu cycles after the frames)\n",
                           ndm_done, ndm_total, (unsigned long long)g_cycle,
                           (unsigned long long)(g_cycle - stage_start - (ndm_send_at - stage_start)));
                    banner_mark = t;
                    if (ndm_done < ndm_total) {
                        // next reset right away: the ROM is in its banner loop again (it
                        // reprints only every ~0.1 s, too slow to wait for in sim)
                        ndm_send_at = g_cycle + ndm_delay0 + (vluint64_t)ndm_done * ndm_step;
                        ndm_sent = false;
                        new_stage(ST_NDM);
                    } else
                        new_stage(ST_BANNER);
                } else if (deadline(ndm_send_at - stage_start + 2000000)) {
                    fail("hart did not leave ndmreset (no ROM rerun)");
                }
            }
            break;

          case ST_CHUNKS: {
            if (deadline(chunk_deadline)) { fail("chunk ACK timeout"); break; }
            bool ack = false, nak = false;
            while (tx_scan < tx_stream.size()) {
                int b = tx_stream[tx_scan++];
                if (b == 0x06) { ack = true; break; }
                if (b == 0x15) { nak = true; break; }
            }
            if (nak) {
                n_retries++;
                printf("[tb] NAK on chunk %zu, retry %d\n", chunk_idx, n_retries);
                // resend current chunk
                size_t off = chunk_idx * 256;
                size_t m = image.size() - off < 256 ? image.size() - off : 256;
                uint8_t x = 0;
                for (size_t i = 0; i < m; i++) x ^= image[off + i];
                std::vector<uint8_t> fr;
                fr.push_back((uint8_t)(chunk_idx & 0xFF));
                for (size_t i = 0; i < m; i++) fr.push_back(image[off + i]);
                fr.push_back(x);
                fr.push_back(0x55);
                send_bytes(fr);
                sv_sb_note_chunk_txn();
            } else if (ack) {
                chunk_idx++;
                if (chunk_idx * 256 >= image.size()) {
                    printf("[tb] all %zu chunks ACKed at cycle %llu (retries %d)\n",
                           chunk_idx, (unsigned long long)g_cycle, n_retries);
                    new_stage(ST_READBACK);
                } else {
                    size_t off = chunk_idx * 256;
                    size_t m = image.size() - off < 256 ? image.size() - off : 256;
                    uint8_t x = 0;
                    for (size_t i = 0; i < m; i++) x ^= image[off + i];
                    std::vector<uint8_t> fr;
                    fr.push_back((uint8_t)(chunk_idx & 0xFF));
                    for (size_t i = 0; i < m; i++) fr.push_back(image[off + i]);
                    fr.push_back(x);
                    fr.push_back(0x55);
                    send_bytes(fr);
                    sv_sb_note_chunk_txn();
                }
            }
            break;
          }

          case ST_READBACK:
            if (deadline(readback_deadline)) { fail("no head/tail readback"); break; }
            if (tx_log.find(']', stage_mark) != std::string::npos &&
                tx_log.find('[', stage_mark) != std::string::npos &&
                tx_log.find(']', stage_mark) > tx_log.find('[', stage_mark)) {
                printf("[tb] load readback seen at cycle %llu\n",
                       (unsigned long long)g_cycle);
                if (ndm_total) {
                    // TB_NDM: the readback (8 head + 8 tail words read through the D-side after
                    // the resets) must match the image exactly; stop here (the ROM's ~24 s
                    // repair window before the jump is too long to simulate per run)
                    auto w32 = [](size_t o) { return (uint32_t)image[o] | (uint32_t)image[o + 1] << 8
                                                   | (uint32_t)image[o + 2] << 16 | (uint32_t)image[o + 3] << 24; };
                    std::string exp = "[";
                    char h[16];
                    for (size_t i = 0; i < 8 && i * 4 < image.size(); i++) {
                        snprintf(h, sizeof h, "%s%08x", i ? " " : "", w32(i * 4)); exp += h;
                    }
                    if (image.size() >= 32) {
                        exp += " :";
                        for (size_t i = 0; i < 8; i++) { snprintf(h, sizeof h, " %08x", w32(image.size() - 32 + i * 4)); exp += h; }
                    }
                    exp += "]";
                    if (strip_dmi(tx_log.substr(stage_mark)).find(exp) == std::string::npos) {
                        printf("[tb] expected readback %s\n", exp.c_str());
                        fail("readback after ndmreset does not match the image");
                    } else {
                        printf("[tb] readback matches the image after %d ndmreset(s)\n", ndm_done);
                        new_stage(ST_PASS);
                    }
                    break;
                }
                new_stage(ST_HELLO);
            }
            break;

          case ST_ISA:
            if (ndm_at && ndm_done < ndm_total && g_cycle >= ndm_at) {
                printf("\n[tb] TB_NDM_AT: ndmreset while the preloaded program runs (cycle %llu); reload %s\n",
                       (unsigned long long)g_cycle, ndm_reload.c_str());
                std::ifstream f(ndm_reload, std::ios::binary);
                if (!f) { fail("cannot open TB_NDM_RELOAD"); break; }
                image.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
                isa_mode = false;           // after the resets: a normal load + hello check
                ndm_send_at = g_cycle;
                ndm_sent = false;
                new_stage(ST_NDM);
                break;
            }
#if VM_TRACE_VCD
            if (perf_on) perf_sample(top);
#endif
            if (progress_every && (g_cycle % progress_every) == 0) {
                static time_t t0 = time(nullptr);
                printf("\n[tb] cycle %llu, %ld s wall\n", (unsigned long long)g_cycle, (long)(time(nullptr) - t0));
#if VM_TRACE_VCD
                printf("[tb]   minstret %llu next_pc %08x priv %u | mcause %08x mepc %08x mtval %08x | scause %08x sepc %08x stval %08x satp %08x\n",
                       (unsigned long long)CPU_SIG(csr_regfile__DOT__rg_minstret), CPU_SIG(rg_next_pc), CPU_SIG(rg_cur_priv),
                       CPU_SIG(csr_regfile__DOT__rg_mcause), CPU_SIG(csr_regfile__DOT__rg_mepc), CPU_SIG(csr_regfile__DOT__rg_mtval),
                       CPU_SIG(csr_regfile__DOT__rg_scause), CPU_SIG(csr_regfile__DOT__rg_sepc), CPU_SIG(csr_regfile__DOT__rg_stval),
                       CPU_SIG(csr_regfile__DOT__rg_satp));
                if (perf_on) perf_roll(CPU_SIG(csr_regfile__DOT__rg_minstret));
#endif
                fflush(stdout);
            }
            if (isa_pass_str && tx_log.find(isa_pass_str) != std::string::npos) {
                printf("\n[tb] ISA PASS (TX saw \"%s\") at cycle %llu\n", isa_pass_str, (unsigned long long)g_cycle);
#if VM_TRACE_VCD
                if (perf_on) { perf_roll(CPU_SIG(csr_regfile__DOT__rg_minstret)); perf_print("TOTAL", perf_tot, CPU_SIG(csr_regfile__DOT__rg_minstret)); }
#endif
                new_stage(ST_PASS);
                break;
            }
            if (deadline(hello_deadline)) { fail("no tohost write"); break; }
            if (g_tohost) {
                if (g_tohost == 1) {
                    printf("[tb] ISA PASS at cycle %llu\n", (unsigned long long)g_cycle);
                    new_stage(ST_PASS);
                } else {
                    printf("[tb] ISA FAIL: tohost 0x%x (test %d) at cycle %llu\n",
                           g_tohost, g_tohost >> 1, (unsigned long long)g_cycle);
                    fail("tohost reports failure");
                }
            }
            break;

          case ST_HELLO:
            if (deadline(hello_deadline)) { fail("no hello output after jump"); break; }
            if (!saw_hello_banner &&
                tx_log.find("Hello from Flute", stage_mark) != std::string::npos) {
                saw_hello_banner = true;
                printf("[tb] hello banner at cycle %llu\n", (unsigned long long)g_cycle);
            }
            if (saw_hello_banner &&
                tx_log.find("tick 00000000", stage_mark) != std::string::npos) {
                saw_tick0 = true;
                new_stage(ST_PASS);
            }
            break;

          default: break;
        }
    }

#if VM_TRACE_VCD
    if (tfp) tfp->close();
#endif
    // ---- SV-side verdict + coverage sampling (the gate) -------------
    int sb_rc = sv_final_checks();
    if (isa_mode || ndm_total) sb_rc = 0;    // TB_NDM: the transcript holds bridge frames and repeated banners    // the scoreboard checks the hello transcript only
    if (sb_rc != 0) {
        printf("[tb] scoreboard FAILED with %d error(s)\n", sb_rc);
        stage = ST_FAIL;
    }

    if (dump_tx) {
        printf("[tb] ----- full TX transcript (%zu bytes, hex) -----\n", tx_log.size());
        for (size_t i = 0; i < tx_log.size(); i++) {
            printf("%02x%s", (unsigned char)tx_log[i],
                   (i % 16 == 15 || i + 1 == tx_log.size()) ? "\n" : " ");
        }
        printf("[tb] --------------------------------------------------\n");
    }

    // ---- summary ---------------------------------------------------
    top->final();
#ifdef VM_COVERAGE
#if VM_COVERAGE
    VerilatedCov::write();   // filename from +verilator+coverage+file+
#endif
#endif
    if (stage == ST_PASS) {
        printf("\n==================== F1 STRICT-SIM: PASS ====================\n");
        printf("banner received, %zu-byte image loaded in %zu chunk(s) (%d retries),\n",
               image.size(), (image.size() + 255) / 256, n_retries);
        printf("hello banner + first tick received at cycle %llu;\n",
               (unsigned long long)g_cycle);
        printf("no strict-BRAM (a) lost-read or (b1) cache cross-port violation.\n");
        printf("=============================================================\n");
        delete top;
        return 0;
    }

    printf("\n==================== F1 STRICT-SIM: FAIL ====================\n");
    delete top;
    return 1;
}
