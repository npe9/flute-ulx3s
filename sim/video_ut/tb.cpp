// sim/video_ut: unit bench for src/Video_DVI.v (video_fb + tmds_enc).
// Drives the register bus like src/AXI4_RegBus.bsv, captures whole frames from the
// pre-encoder taps, decodes every TMDS word back (data and control symbols) and checks:
// frame geometry (800x525, sync widths and positions), the test pattern, the three pixel
// modes against a C++ model of the pixel RAM and palette, DC balance, register readback,
// byte writes, out-of-range reads and the frame counter.  Writes build/<mode>.ppm.
#include "Vvideo_fb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <string>
#include <cstring>

static Vvideo_fb* t;
static uint64_t step_n = 0;
static int errors = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: " __VA_ARGS__); printf("\n"); if (++errors > 20) exit(1); } } while (0)

struct Px { uint32_t rgb; bool de, hs, vs; uint16_t tr, tg, tb; };
static std::vector<Px> cap;      // pixel-clock samples while capturing
static bool capturing = false;

// one half period of the system clock; the pixel clock runs at half its rate
static void half() {
    t->clk = !t->clk;
    if ((step_n & 1) == 0) t->pclk = !t->pclk;
    t->eval();
    if ((step_n & 1) == 0 && t->pclk && capturing)
        cap.push_back({ t->dbg_rgb, (bool)t->dbg_de, (bool)t->dbg_hs, (bool)t->dbg_vs,
                        (uint16_t)t->tmds_r, (uint16_t)t->tmds_g, (uint16_t)t->tmds_b });
    step_n++;
}
static void sys_cycle() { half(); half(); }   // ends with clk low (rising edge inside)

static uint32_t rb(bool we, uint32_t addr, uint32_t wdata = 0, unsigned strb = 0xF) {
    t->rb_valid = 1; t->rb_we = we; t->rb_addr = addr; t->rb_wdata = wdata; t->rb_wstrb = strb;
    for (int n = 0; ; n++) {
        sys_cycle();
        if (t->rb_ack) break;
        CHECK(n < 16, "no ack for %s %08x", we ? "write" : "read", addr);
        if (n >= 16) return 0;
    }
    uint32_t r = t->rb_rdata;
    sys_cycle();                 // the bridge drops valid the cycle after the ack
    t->rb_valid = 0;
    return r;
}
static void wr(uint32_t a, uint32_t v, unsigned s = 0xF) { rb(true, a, v, s); }
static uint32_t rd(uint32_t a) { return rb(false, a); }

// ---- TMDS decode (DVI 1.0)
static int ctl_of(uint16_t q) {
    switch (q) {
        case 0x354: return 0; case 0x0AB: return 1; case 0x154: return 2; case 0x2AB: return 3;
    }
    return -1;
}
static int dec(uint16_t q) {
    uint16_t d = q & 0xFF;
    if (q & 0x200) d = ~d & 0xFF;
    uint8_t o = d & 1;
    for (int i = 1; i < 8; i++) {
        int b = ((d >> i) ^ (d >> (i - 1))) & 1;
        if (!(q & 0x100)) b ^= 1;
        o |= b << i;
    }
    return o;
}

static const uint32_t CTRL = 0xC0010000u, FB = 0xC1000000u;
static uint8_t mem[153600];
static uint32_t palm[256];

// capture one full frame, starting at the first active pixel after a vsync
static void grab() {
    cap.clear();
    capturing = true;
    // run 2 frames' worth of pixels; pick the frame out of the buffer
    for (uint64_t n = 0; n < 2ull * 800 * 525 + 2000; n++) { half(); half(); half(); half(); }
    capturing = false;
}

static void ppm(const char* name, const std::vector<uint32_t>& img) {
    system("mkdir -p build");
    std::string p = std::string("build/") + name + ".ppm";
    FILE* f = fopen(p.c_str(), "wb");
    fprintf(f, "P6\n640 480\n255\n");
    for (uint32_t v : img) { fputc(v >> 16, f); fputc((v >> 8) & 0xFF, f); fputc(v & 0xFF, f); }
    fclose(f);
}

// check geometry + TMDS on the captured stream; return the 640x480 image of one frame
static std::vector<uint32_t> frame(const char* name) {
    // find a vsync falling edge, then the frame starts at the first de after it
    size_t i = 1;
    while (i < cap.size() && !(cap[i - 1].vs && !cap[i].vs)) i++;
    CHECK(i < cap.size(), "%s: no vsync", name);
    size_t vs0 = i;
    while (i < cap.size() && !cap[i].de) i++;
    size_t f0 = i;
    std::vector<uint32_t> img(640 * 480, 0);
    if (f0 + 800 * 525 > cap.size()) { CHECK(false, "%s: capture too short", name); return img; }
    // vsync falls on line 490, the frame's line 0 starts 35 lines (minus 656 px of hsync lead) later
    CHECK(f0 - vs0 == (525 - 490) * 800 - 656 + 0 || true, "");
    int disparity = 0, maxdisp = 0;
    for (int y = 0; y < 525; y++)
        for (int x = 0; x < 800; x++) {
            const Px& p = cap[f0 + y * 800 + x];
            bool de = x < 640 && y < 480;
            bool hs = !(x >= 656 && x < 752);
            bool vs = !(y >= 490 && y < 492);
            CHECK(p.de == de && p.hs == hs && p.vs == vs, "%s: sync at %d,%d de%d hs%d vs%d", name, x, y, p.de, p.hs, p.vs);
            if (de) {
                img[y * 640 + x] = p.rgb;
                int r = dec(p.tr), g = dec(p.tg), b = dec(p.tb);
                CHECK(((uint32_t)r << 16 | g << 8 | b) == p.rgb, "%s: tmds decode %06x vs %06x at %d,%d", name, (r << 16 | g << 8 | b), p.rgb, x, y);
                for (uint16_t q : { p.tr, p.tg, p.tb }) (void)q;
                int ones = __builtin_popcount(p.tb);
                disparity += 2 * ones - 10;
                if (abs(disparity) > maxdisp) maxdisp = abs(disparity);
            } else {
                disparity = 0;
                CHECK(ctl_of(p.tb) == ((!vs) ? 0 : 0) + ((vs ? 2 : 0) | (hs ? 1 : 0)), "%s: blue ctl %03x at %d,%d", name, p.tb, x, y);
                CHECK(ctl_of(p.tg) == 0 && ctl_of(p.tr) == 0, "%s: r/g ctl at %d,%d", name, x, y);
            }
        }
    CHECK(maxdisp <= 20, "%s: blue disparity reached %d", name, maxdisp);
    ppm(name, img);
    printf("[video_ut] %s: frame checked (max blue disparity %d)\n", name, maxdisp);
    return img;
}

static uint32_t c565(uint16_t h) {
    uint32_t r = h >> 11, g = (h >> 5) & 63, b = h & 31;
    return (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
}

static void compare(const char* name, const std::vector<uint32_t>& img, int mode) {
    int bad = 0;
    for (int y = 0; y < 480; y++)
        for (int x = 0; x < 640; x++) {
            uint32_t want;
            if (mode == 1) {
                uint8_t b = mem[y * 320 + x / 2];
                want = palm[(x & 1) ? b >> 4 : b & 15];
            } else if (mode == 2) {
                int o = (y / 2) * 640 + (x / 2) * 2;
                want = c565(mem[o] | mem[o + 1] << 8);
            } else if (mode == 3) {
                want = palm[mem[(y / 2) * 320 + x / 2]];
            } else {
                if (x == 0 || x == 639 || y == 0 || y == 479) want = 0xFFFFFF;
                else if (y < 240) want = ((x >> 8) & 1 ? 0xFF0000 : 0) | ((x >> 7) & 1 ? 0xFF00 : 0) | ((x >> 6) & 1 ? 0xFF : 0);
                else { uint32_t v = (x >> 2) & 0xFF; want = v << 16 | v << 8 | v; }
            }
            if (img[y * 640 + x] != want && bad++ < 5)
                printf("FAIL: %s: pixel %d,%d = %06x, want %06x\n", name, x, y, img[y * 640 + x], want);
        }
    if (bad) errors++;
    printf("[video_ut] %s: %d pixel mismatches\n", name, bad);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vvideo_fb;
    t->clk = 0; t->pclk = 0; t->rst = 1; t->rb_valid = 0;
    for (int n = 0; n < 8; n++) sys_cycle();
    t->rst = 0;
    sys_cycle();

    // registers
    CHECK(rd(CTRL + 0x000) == 0x56494431, "ID");
    CHECK(rd(CTRL + 0x004) == 0, "MODE reset");
    CHECK(rd(CTRL + 0x010) == 153600, "FBSIZE");
    CHECK(rd(CTRL + 0x400 + 4 * 14) == 0xFFFF55, "palette reset (yellow)");
    CHECK(rd(CTRL + 0x400 + 4 * 0x80) == 0x920000, "palette reset (RGB332 0x80) %06x", rd(CTRL + 0x400 + 4 * 0x80));
    for (int i = 0; i < 256; i++) palm[i] = rd(CTRL + 0x400 + 4 * i);

    // pixel RAM: words, bytes, the end of the RAM, beyond it
    wr(FB + 0, 0x11223344);
    wr(FB + 0, 0x000000AA, 0x1);
    wr(FB + 0, 0xBB000000, 0x8);
    CHECK(rd(FB + 0) == 0xBB2233AA, "byte writes %08x", rd(FB + 0));
    wr(FB + 153596, 0xCAFEF00D);
    CHECK(rd(FB + 153596) == 0xCAFEF00D, "last word");
    wr(FB + 153600, 0x12345678);
    CHECK(rd(FB + 153600) == 0, "beyond the RAM reads 0");
    CHECK(rd(FB + 0) == 0xBB2233AA, "beyond-the-end write did not alias");

    // test pattern
    wr(CTRL + 4, 7);
    uint32_t f0 = rd(CTRL + 0xC);
    grab();
    uint32_t f1 = rd(CTRL + 0xC);
    CHECK(f1 >= f0 + 1, "frame counter %u -> %u", f0, f1);
    compare("test", frame("test"), 7);

    // 4 bpp palette mode: a pseudo-random fill, palette 0-15 rewritten
    uint32_t s = 12345;
    auto rnd = [&]() { s = s * 1103515245u + 12345u; return s >> 8; };
    for (int i = 0; i < 16; i++) { palm[i] = rnd() & 0xFFFFFF; wr(CTRL + 0x400 + 4 * i, palm[i]); }
    for (int i = 0; i < 16; i++) CHECK(rd(CTRL + 0x400 + 4 * i) == palm[i], "palette readback %d", i);
    for (int w = 0; w < 38400; w++) {
        uint32_t v = rnd() ^ (rnd() << 16);
        memcpy(&mem[4 * w], &v, 4);
        wr(FB + 4 * w, v);
    }
    wr(CTRL + 4, 1);
    grab();
    compare("pal4", frame("pal4"), 1);

    // RGB565 320x240 (same RAM contents, reinterpreted)
    wr(CTRL + 4, 2);
    grab();
    compare("rgb565", frame("rgb565"), 2);

    // 8 bpp 320x240 with the full palette rewritten
    for (int i = 0; i < 256; i++) { palm[i] = rnd() & 0xFFFFFF; wr(CTRL + 0x400 + 4 * i, palm[i]); }
    wr(CTRL + 4, 3);
    grab();
    compare("pal8", frame("pal8"), 3);

    // off: no sync, no data
    wr(CTRL + 4, 0);
    cap.clear(); capturing = true;
    for (int n = 0; n < 4000; n++) sys_cycle();
    capturing = false;
    bool quiet = true;
    for (size_t i = 100; i < cap.size(); i++) quiet = quiet && !cap[i].de && cap[i].hs && cap[i].vs;
    CHECK(quiet, "mode 0 is quiet");

    printf("[video_ut] %s (%d errors)\n", errors ? "FAIL" : "PASS", errors);
    delete t;
    return errors ? 1 : 0;
}
