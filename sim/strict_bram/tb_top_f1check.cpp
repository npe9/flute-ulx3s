// ================================================================
// tb_top.cpp — Verilator C++ bench for the F1 strict-BRAM sim.
//
// Drives sim_board (ulx3s_top + W9825G6 model) through the canonical
// boot scenario of test/SoC_Boot_Tb.bsv, against the REAL synth-bound
// RTL (build/verilog_all.v) with the strict BRAM2 model:
//
//   1. power-on reset (src/Top.v counts 256 clocks, BTN1 held low)
//   2. wait for the boot ROM banner on the FPGA TX pin
//      ("\r\nULX3S Flute SoC: boot loader\r\n")
//   3. send the loader header  <II (0x80000000, len) then the image in
//      256-byte framed chunks: [seq, data..., xor, 0x55], one chunk at
//      a time, ACK(0x06)/NAK(0x15)-paced (the protocol the ACTUAL boot
//      ROM in build/verilog_all.v speaks — see boot/boot_loader.c)
//   4. wait for the head/tail readback line, then the repair window,
//      then the jump to SDRAM
//   5. PASS when hello.bin's first banner + first "tick 00000000"
//      line have been received and no strict-BRAM violation fired
//
// UART: 25 MHz sys_clk, 625000 baud -> 40 cycles/bit (src/Uart_Pins.bsv
// clk_per_bit = clk_hz/baud).  TX is recovered by mid-bit sampling; RX
// bits are driven on exact 40-cycle boundaries (the DUT re-syncs on
// every start bit, so no drift is possible).
//
// STRICT_BRAM mode: taken from the STRICT_BRAM environment variable
// (forwarded by run.sh as a +STRICT_BRAM=<mode> plusarg when not
// already given on the command line).  +verilator+seed+N is accepted
// and ignored for now (F2 will sweep seeds).
// ================================================================

#include "Vsim_board.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

static const int CYCLES_PER_BIT = 40;   // 25 MHz / 625000 baud

// ----------------------------------------------------------------
// DUT + board state

static Vsim_board* top = nullptr;
static vluint64_t  g_cycle = 0;

// ----------------------------------------------------------------
// UART TX recovery (FPGA -> host), mid-bit sampling like the BSV tb.

static int      tx_state  = 0;   // 0 idle, 1 in start, 2 data, 3 stop
static uint64_t tx_cnt    = 0;
static uint8_t  tx_shift  = 0;
static int      tx_nbits  = 0;

static std::string     tx_log;    // every received byte, in order
static std::deque<int> tx_stream; // byte queue for ACK/NAK scanning

static void tx_sample() {
    int bit = top->ftdi_rxd;
    switch (tx_state) {
      case 0:
        if (bit == 0) { tx_state = 1; tx_cnt = 0; tx_nbits = 0; tx_shift = 0; }
        break;
      case 1:  // 1.5 bits after the falling edge: center of bit 0
        if (++tx_cnt >= (CYCLES_PER_BIT + CYCLES_PER_BIT / 2)) {
            tx_cnt = 0;
            // like the BSV tb: this sample IS bit 0 (the start bit is
            // only the falling edge that got us here)
            tx_shift |= (uint8_t)(bit << tx_nbits);
            tx_nbits = 1;
            tx_state = 2;
        }
        break;
      case 2:
        if (++tx_cnt >= CYCLES_PER_BIT) {
            tx_cnt = 0;
            tx_shift |= (uint8_t)(bit << tx_nbits);
            if (++tx_nbits == 8) tx_state = 3;
        }
        break;
      case 3:
        if (++tx_cnt >= CYCLES_PER_BIT) {
            tx_cnt = 0;
            tx_state = 0;
            if (bit == 1) {
                tx_log += (char)tx_shift;
                tx_stream.push_back(tx_shift);
            } else {
                printf("[tb] WARNING: TX framing error at cycle %llu\n",
                       (unsigned long long)g_cycle);
            }
        }
        break;
    }
}

// ----------------------------------------------------------------
// UART RX stimulus (host -> FPGA): shift a bit queue onto ftdi_txd.

static std::deque<int> rx_bits;      // pending wire levels, 1 per bit cell
static int             rx_cur_bit = 1;
static int             rx_timer   = 0;

static void send_byte(uint8_t b) {
    rx_bits.push_back(0);                    // start
    for (int i = 0; i < 8; i++) rx_bits.push_back((b >> i) & 1);
    rx_bits.push_back(1);                    // stop
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
    // STRICT_BRAM env -> plusarg forwarding (run.sh sets it; a direct
    // +STRICT_BRAM=... plusarg on the command line wins).
    const char* env_strict = getenv("STRICT_BRAM");
    bool plusarg_from_cmdline = false;

    const char* image_path = "../../sw/hello.bin";
    for (int i = 1; i < argc; i++) {
        if (strstr(argv[i], "+STRICT_BRAM=") == argv[i]) plusarg_from_cmdline = true;
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

    {   // read the payload
        std::ifstream f(image_path, std::ios::binary);
        if (!f) { fprintf(stderr, "[tb] cannot open %s\n", image_path); return 2; }
        image.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    }
    printf("[tb] payload: %zu bytes (%zu chunks of 256)\n",
           image.size(), (image.size() + 255) / 256);

    top = new Vsim_board;
    top->clk = 0;
    top->btn1 = 0;          // FIRE1 not pressed: power-on reset only
    top->ftdi_txd = 1;      // UART idle
    top->jtag_tck = 0;      // JTAG TAP tied off
    top->jtag_tms = 0;
    top->jtag_tdi = 0;

    // src/Top.v: power_on_reset is an 8-bit counter -> 256 clocks of
    // reset; give it a little margin, the banner needs SDRAM init
    // (~200 us power-up wait = 5000 clocks) on top.
    vluint64_t banner_deadline   = 50000000;   // 2 s
    vluint64_t chunk_deadline    = 200000000;  // 8 s per ACK
    vluint64_t readback_deadline = 200000000;
    vluint64_t hello_deadline    = 600000000;  // repair window is ~10 s+
    vluint64_t overall_deadline  = 900000000;

    while (stage != ST_PASS && stage != ST_FAIL) {
        if (g_cycle > overall_deadline) { fail("overall deadline"); break; }

        // ---- one 25 MHz clock: posedge then negedge ---------------
        top->clk = 1;
        top->eval();
        g_cycle++;
        tx_sample();

        // host TX bit advance (async input: update during the low phase)
        if (rx_timer > 0) {
            rx_timer--;
        } else if (!rx_bits.empty()) {
            rx_cur_bit = rx_bits.front();
            rx_bits.pop_front();
            rx_timer = CYCLES_PER_BIT;
            top->ftdi_txd = rx_cur_bit;
        }

        top->clk = 0;
        top->eval();

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

    // ---- summary ---------------------------------------------------
    if (stage == ST_PASS) {
        printf("\n==================== F1 STRICT-SIM: PASS ====================\n");
        printf("banner received, %zu-byte image loaded in %zu chunk(s) (%d retries),\n",
               image.size(), (image.size() + 255) / 256, n_retries);
        printf("hello banner + first tick received at cycle %llu;\n",
               (unsigned long long)g_cycle);
        printf("no strict-BRAM (a) lost-read or (b1) cache cross-port violation.\n");
        printf("=============================================================\n");
        top->final();
        delete top;
        return 0;
    }

    printf("\n==================== F1 STRICT-SIM: FAIL ====================\n");
    top->final();
    delete top;
    return 1;
}
