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

static void poll_tx() {
    int avail = sv_tx_avail();
    while ((int)tx_polled < avail) {
        int b = sv_tx_byte((int)tx_polled);
        if (b < 0) break;
        tx_log += (char)(b & 0xFF);
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

static void fail(const char* what) {
    printf("[tb] FAIL at cycle %llu: %s (stage %d, %llu cycles in stage)\n",
           (unsigned long long)g_cycle, what, (int)stage,
           (unsigned long long)(g_cycle - stage_start));
    // dump the tail of what the SoC said for debugging
    std::string tail = tx_log.substr(tx_log.size() > 400 ? tx_log.size() - 400 : 0);
    printf("[tb] ----- TX tail -----\n%s\n[tb] -------------------\n", tail.c_str());
    stage = ST_FAIL;
}

static void new_stage(Stage s) {
    stage = s;
    stage_start = g_cycle;
    tx_scan = tx_stream.size();    // ignore bytes from before the stage
}

// deadline check for the current stage; returns true on timeout
static bool deadline(vluint64_t cycles) {
    return (g_cycle - stage_start) > cycles;
}

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
    Verilated::commandArgs((int)args.size(), (char**)&args[0]);

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
    vluint64_t chunk_deadline    = 200000000;  // 8 s per ACK
    vluint64_t readback_deadline = 200000000;
    vluint64_t hello_deadline    = 600000000;  // repair window is ~10 s+
    vluint64_t overall_deadline  = 900000000;

    int dpi_ready = 0;

    while (stage != ST_PASS && stage != ST_FAIL) {
        if (g_cycle > overall_deadline) { fail("overall deadline"); break; }

        // ---- one 25 MHz clock: posedge then negedge ---------------
        top->clk = 1;
        top->eval();
        g_cycle++;

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

        // pull freshly assembled monitor bytes (negedge tick ran above)
        poll_tx();

        // ---- scenario state machine -------------------------------
        switch (stage) {
          case ST_BANNER:
            if (tx_log.find("ULX3S Flute SoC") != std::string::npos) {
                printf("[tb] banner seen at cycle %llu\n", (unsigned long long)g_cycle);
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
            if (tx_log.find(']') != std::string::npos &&
                tx_log.find('[') != std::string::npos &&
                tx_log.find(']') > tx_log.find('[')) {
                printf("[tb] load readback seen at cycle %llu\n",
                       (unsigned long long)g_cycle);
                new_stage(ST_HELLO);
            }
            break;

          case ST_HELLO:
            if (deadline(hello_deadline)) { fail("no hello output after jump"); break; }
            if (!saw_hello_banner &&
                tx_log.find("Hello from Flute") != std::string::npos) {
                saw_hello_banner = true;
                printf("[tb] hello banner at cycle %llu\n", (unsigned long long)g_cycle);
            }
            if (saw_hello_banner &&
                tx_log.find("tick 00000000") != std::string::npos) {
                saw_tick0 = true;
                new_stage(ST_PASS);
            }
            break;

          default: break;
        }
    }

    // ---- SV-side verdict + coverage sampling (the gate) -------------
    int sb_rc = sv_final_checks();
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
    VerilatedCov::write();   // filename from +verilator+coverage+file+
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
