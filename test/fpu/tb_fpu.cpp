// FPU unit test: drives the FBox_Top request/response interface (mkFBox_Top, or any module with the
// same ports) with Berkeley TestFloat vectors read from stdin, and checks result AND fflags exactly.
//
//   testfloat_gen -rnear_even f32_add | tb f32_add 0          (TestFloat mode)
//   tb directed                                                 (min/max/sgnj/class/fmv/nanbox)
//
// Operand/result conventions are those of CPU_Stage2: f32 operands NaN-boxed in 64 bits, f32 results
// must come back NaN-boxed; integer operands zero-extended from 32 bits; integer results (FCVT.W*,
// FEQ/FLT/FLE, FCLASS, FMV.X.W) are truncated to 32 bits by the pipeline, so only [31:0] is checked.
#ifndef VDUT
#define VDUT VmkFBox_Top
#endif
#define STR2_(x) #x
#define STR_(x) STR2_(x)
#define HDR_(x) STR_(x.h)
#include HDR_(VDUT)
#include <verilated.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

typedef uint64_t u64;
typedef uint32_t u32;
static VDUT* t;
static u64 cycles = 0;
static void clk() { t->CLK = 0; t->eval(); t->CLK = 1; t->eval(); cycles++; }

static const unsigned OP_FP = 0x53, OP_FMADD = 0x43, OP_FMSUB = 0x47, OP_FNMSUB = 0x4B, OP_FNMADD = 0x4F;
static const u64 BOX = 0xFFFFFFFF00000000ULL;

static void reset() {
    t->verbosity = 0; t->EN_req = 0; t->EN_server_reset_request_put = 0; t->EN_server_reset_response_get = 0;
    t->RST_N = 0; clk(); clk(); t->RST_N = 1; clk();
    while (!t->RDY_server_reset_request_put) clk();
    t->EN_server_reset_request_put = 1; clk(); t->EN_server_reset_request_put = 0;
    int n = 0;
    while (!t->RDY_server_reset_response_get) { clk(); if (++n > 10000) { fprintf(stderr, "reset timeout\n"); exit(2); } }
    t->EN_server_reset_response_get = 1; clk(); t->EN_server_reset_response_get = 0; clk();
}

// one request; returns false on timeout
static bool run1(unsigned opc, unsigned f7, unsigned rm, unsigned rs2, u64 v1, u64 v2, u64 v3, u64& res, unsigned& fl) {
    t->req_opcode = opc; t->req_f7 = f7; t->req_rm = rm; t->req_rs2 = rs2;
    t->req_v1 = v1; t->req_v2 = v2; t->req_v3 = v3; t->EN_req = 1;
    clk(); t->EN_req = 0; t->eval();
    for (int n = 0; n < 5000; n++) {
        if (t->valid) { res = t->word_fst; fl = t->word_snd; clk(); return true; }
        clk();
    }
    return false;
}

// ---------------------------------------------------------------- TestFloat mode
enum Kind { F32, F64, I32, BOOL };
struct Op {
    const char* name; unsigned opc, f7, rs2; int fixrm;   // fixrm >= 0: funct3 is fixed (compares)
    int nin; Kind in, out;
    int negmask;                                           // FMA variants: bit0 negate a, bit2 negate c
};
static const Op ops[] = {
    {"f32_add", OP_FP, 0x00, 0, -1, 2, F32, F32, 0}, {"f64_add", OP_FP, 0x01, 0, -1, 2, F64, F64, 0},
    {"f32_sub", OP_FP, 0x04, 0, -1, 2, F32, F32, 0}, {"f64_sub", OP_FP, 0x05, 0, -1, 2, F64, F64, 0},
    {"f32_mul", OP_FP, 0x08, 0, -1, 2, F32, F32, 0}, {"f64_mul", OP_FP, 0x09, 0, -1, 2, F64, F64, 0},
    {"f32_div", OP_FP, 0x0C, 0, -1, 2, F32, F32, 0}, {"f64_div", OP_FP, 0x0D, 0, -1, 2, F64, F64, 0},
    {"f32_sqrt", OP_FP, 0x2C, 0, -1, 1, F32, F32, 0}, {"f64_sqrt", OP_FP, 0x2D, 0, -1, 1, F64, F64, 0},
    // mulAdd vectors (a,b,c -> a*b+c) driven through each FMA opcode with the operand signs pre-flipped
    {"f32_fmadd", OP_FMADD, 0x00, 0, -1, 3, F32, F32, 0}, {"f64_fmadd", OP_FMADD, 0x01, 0, -1, 3, F64, F64, 0},
    {"f32_fmsub", OP_FMSUB, 0x00, 0, -1, 3, F32, F32, 4}, {"f64_fmsub", OP_FMSUB, 0x01, 0, -1, 3, F64, F64, 4},
    {"f32_fnmsub", OP_FNMSUB, 0x00, 0, -1, 3, F32, F32, 1}, {"f64_fnmsub", OP_FNMSUB, 0x01, 0, -1, 3, F64, F64, 1},
    {"f32_fnmadd", OP_FNMADD, 0x00, 0, -1, 3, F32, F32, 5}, {"f64_fnmadd", OP_FNMADD, 0x01, 0, -1, 3, F64, F64, 5},
    {"f32_eq", OP_FP, 0x50, 0, 2, 2, F32, BOOL, 0}, {"f64_eq", OP_FP, 0x51, 0, 2, 2, F64, BOOL, 0},
    {"f32_lt", OP_FP, 0x50, 0, 1, 2, F32, BOOL, 0}, {"f64_lt", OP_FP, 0x51, 0, 1, 2, F64, BOOL, 0},
    {"f32_le", OP_FP, 0x50, 0, 0, 2, F32, BOOL, 0}, {"f64_le", OP_FP, 0x51, 0, 0, 2, F64, BOOL, 0},
    {"f32_to_i32", OP_FP, 0x60, 0, -1, 1, F32, I32, 0}, {"f32_to_ui32", OP_FP, 0x60, 1, -1, 1, F32, I32, 0},
    {"f64_to_i32", OP_FP, 0x61, 0, -1, 1, F64, I32, 0}, {"f64_to_ui32", OP_FP, 0x61, 1, -1, 1, F64, I32, 0},
    {"i32_to_f32", OP_FP, 0x68, 0, -1, 1, I32, F32, 0}, {"ui32_to_f32", OP_FP, 0x68, 1, -1, 1, I32, F32, 0},
    {"i32_to_f64", OP_FP, 0x69, 0, -1, 1, I32, F64, 0}, {"ui32_to_f64", OP_FP, 0x69, 1, -1, 1, I32, F64, 0},
    {"f32_to_f64", OP_FP, 0x21, 0, -1, 1, F32, F64, 0}, {"f64_to_f32", OP_FP, 0x20, 1, -1, 1, F64, F32, 0},
};

static u64 drive(Kind k, u64 x) { return k == F32 ? (BOX | (x & 0xFFFFFFFFULL)) : k == I32 ? (x & 0xFFFFFFFFULL) : x; }
static int width(Kind k) { return k == F64 ? 16 : k == BOOL ? 1 : 8; }

static int testfloat(const char* name, unsigned rm, long maxprint) {
    const Op* op = nullptr;
    for (auto& o : ops) if (!strcmp(o.name, name)) op = &o;
    if (!op) { fprintf(stderr, "unknown op %s\n", name); return 2; }
    unsigned frm = op->fixrm >= 0 ? (unsigned)op->fixrm : rm;
    u64 sgn = op->in == F64 ? (1ULL << 63) : (1ULL << 31);
    long pass = 0, fail = 0, fail_val = 0, fail_flags = 0, tmo = 0, printed = 0;
    char line[512];
    while (fgets(line, sizeof line, stdin)) {
        u64 v[5]; int nv = 0; char* p = line;
        while (nv < 5) { char* e; u64 x = strtoull(p, &e, 16); if (e == p) break; v[nv++] = x; p = e; }
        if (nv != op->nin + 2) continue;
        u64 a = v[0], b = op->nin > 1 ? v[1] : 0, c = op->nin > 2 ? v[2] : 0;
        u64 z = v[op->nin]; unsigned zf = (unsigned)v[op->nin + 1];
        if (op->negmask & 1) a ^= sgn;
        if (op->negmask & 4) c ^= sgn;
        u64 res = 0; unsigned fl = 0;
        if (!run1(op->opc, op->f7, frm, op->rs2, drive(op->in, a), drive(op->in, b), drive(op->in, c), res, fl)) {
            tmo++; fail++; reset();
            if (printed++ < maxprint) printf("  TIMEOUT %s rm=%u in=%s", name, frm, line);
            continue;
        }
        u64 exp;
        bool ok_val;
        switch (op->out) {
            case F32: exp = BOX | z; ok_val = res == exp; break;
            case F64: exp = z; ok_val = res == exp; break;
            default:  exp = z; ok_val = (res & 0xFFFFFFFFULL) == z; break;
        }
        bool ok_fl = fl == zf;
        if (ok_val && ok_fl) { pass++; continue; }
        fail++; if (!ok_val) fail_val++; if (!ok_fl) fail_flags++;
        if (printed++ < maxprint) {
            int w = width(op->in);
            printf("  MISMATCH %s rm=%u in=", name, frm);
            printf("%0*llx", w, (unsigned long long)v[0]);
            if (op->nin > 1) printf(" %0*llx", w, (unsigned long long)v[1]);
            if (op->nin > 2) printf(" %0*llx", w, (unsigned long long)v[2]);
            printf(" exp=%016llx/%02x got=%016llx/%02x\n", (unsigned long long)exp, zf, (unsigned long long)res, fl);
        }
    }
    printf("RESULT %-12s rm=%u pass=%ld fail=%ld (value=%ld flags=%ld timeout=%ld) cycles=%llu\n",
           name, frm, pass, fail, fail_val, fail_flags, tmo, (unsigned long long)cycles);
    return fail ? 1 : 0;
}

// ---------------------------------------------------------------- directed mode (ops TestFloat lacks)
static int dpass = 0, dfail = 0;
static void dcheck(const char* what, unsigned opc, unsigned f7, unsigned rm, unsigned rs2, u64 v1, u64 v2,
                   u64 exp, unsigned expfl, u64 mask) {
    u64 res = 0; unsigned fl = 0;
    bool ok = run1(opc, f7, rm, rs2, v1, v2, 0, res, fl) && (res & mask) == (exp & mask) && fl == expfl;
    if (ok) { dpass++; return; }
    dfail++;
    if (dfail <= 60) printf("  MISMATCH %s v1=%016llx v2=%016llx exp=%016llx/%02x got=%016llx/%02x\n", what,
                            (unsigned long long)v1, (unsigned long long)v2, (unsigned long long)exp, expfl,
                            (unsigned long long)res, fl);
}

struct FmtInfo { int bits; u64 signb, expm, fracm, qbit, cnan; };
static const FmtInfo FS = {32, 1ULL << 31, 0x7F800000ULL, 0x7FFFFFULL, 1ULL << 22, 0x7FC00000ULL};
static const FmtInfo FD = {64, 1ULL << 63, 0x7FF0000000000000ULL, 0xFFFFFFFFFFFFFULL, 1ULL << 51, 0x7FF8000000000000ULL};
static bool isnan_(const FmtInfo& f, u64 x) { return (x & f.expm) == f.expm && (x & f.fracm); }
static bool issnan(const FmtInfo& f, u64 x) { return isnan_(f, x) && !(x & f.qbit); }
static bool iszero(const FmtInfo& f, u64 x) { return (x & ~f.signb) == 0; }
// x < y for non-NaN values (total order on magnitudes with sign, -0 < +0)
static bool lt_(const FmtInfo& f, u64 x, u64 y) {
    bool sx = x & f.signb, sy = y & f.signb; u64 mx = x & ~f.signb, my = y & ~f.signb;
    if (sx != sy) return sx;                     // negative < positive (covers -0 < +0)
    return sx ? mx > my : mx < my;
}
static unsigned fclass(const FmtInfo& f, u64 x) {
    bool s = x & f.signb; u64 e = x & f.expm, m = x & f.fracm;
    if (e == f.expm) return m ? ((m & f.qbit) ? 1u << 9 : 1u << 8) : (s ? 1u << 0 : 1u << 7);
    if (e == 0) return m ? (s ? 1u << 2 : 1u << 5) : (s ? 1u << 3 : 1u << 4);
    return s ? 1u << 1 : 1u << 6;
}

static int directed() {
    const u64 M32 = 0xFFFFFFFFULL, ALL = ~0ULL;
    std::vector<u64> vs = {0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x7F800000, 0xFF800000,
                           0x7FC00000, 0xFFC00000, 0x7FC12345, 0x7F800001, 0xFF812345, 0x7FA00000,
                           0x00000001, 0x80000001, 0x007FFFFF, 0x00800000, 0x7F7FFFFF, 0xFF7FFFFF,
                           0x40490FDB, 0xC0490FDB, 0x3F800001};
    std::vector<u64> vd = {0x0ULL, 0x8000000000000000ULL, 0x3FF0000000000000ULL, 0xBFF0000000000000ULL,
                           0x7FF0000000000000ULL, 0xFFF0000000000000ULL, 0x7FF8000000000000ULL,
                           0xFFF8000000000000ULL, 0x7FF8000012345678ULL, 0x7FF0000000000001ULL,
                           0xFFF0000012345678ULL, 0x7FF4000000000000ULL, 0x1ULL, 0x8000000000000001ULL,
                           0x000FFFFFFFFFFFFFULL, 0x0010000000000000ULL, 0x7FEFFFFFFFFFFFFFULL,
                           0xFFEFFFFFFFFFFFFFULL, 0x400921FB54442D18ULL, 0xC00921FB54442D18ULL,
                           0x3FF0000000000001ULL};
    for (int d = 0; d < 2; d++) {
        const FmtInfo& f = d ? FD : FS;
        auto& vals = d ? vd : vs;
        unsigned fs = d;                         // f7 fmt bit
        auto box = [&](u64 x) { return d ? x : (BOX | x); };
        const char* sfx = d ? ".D" : ".S";
        char nm[32];
        for (u64 x : vals) {
            for (u64 y : vals) {
                // FMIN/FMAX: minimumNumber/maximumNumber (F/D 2.2), NV on any sNaN
                unsigned nv = (issnan(f, x) || issnan(f, y)) ? 0x10 : 0;
                u64 mn, mx;
                if (isnan_(f, x) && isnan_(f, y)) mn = mx = f.cnan;
                else if (isnan_(f, x)) mn = mx = y;
                else if (isnan_(f, y)) mn = mx = x;
                else { mn = lt_(f, x, y) ? x : y; mx = lt_(f, x, y) ? y : x; }
                snprintf(nm, sizeof nm, "FMIN%s", sfx); dcheck(nm, OP_FP, 0x14 | fs, 0, 0, box(x), box(y), box(mn), nv, ALL);
                snprintf(nm, sizeof nm, "FMAX%s", sfx); dcheck(nm, OP_FP, 0x14 | fs, 1, 0, box(x), box(y), box(mx), nv, ALL);
                // FSGNJ*: pure sign manipulation, no canonicalization, no flags
                u64 mag = x & ~f.signb;
                snprintf(nm, sizeof nm, "FSGNJ%s", sfx);  dcheck(nm, OP_FP, 0x10 | fs, 0, 0, box(x), box(y), box(mag | (y & f.signb)), 0, ALL);
                snprintf(nm, sizeof nm, "FSGNJN%s", sfx); dcheck(nm, OP_FP, 0x10 | fs, 1, 0, box(x), box(y), box(mag | (~y & f.signb)), 0, ALL);
                snprintf(nm, sizeof nm, "FSGNJX%s", sfx); dcheck(nm, OP_FP, 0x10 | fs, 2, 0, box(x), box(y), box(x ^ (y & f.signb)), 0, ALL);
            }
            snprintf(nm, sizeof nm, "FCLASS%s", sfx); dcheck(nm, OP_FP, 0x70 | fs, 1, 0, box(x), 0, fclass(f, x), 0, M32);
            if (!d) {
                // FMV.X.W returns the raw low 32 bits (no unboxing); FMV.W.X NaN-boxes
                dcheck("FMV.X.W", OP_FP, 0x70, 0, 0, box(x), 0, x, 0, M32);
                dcheck("FMV.X.W(unboxed)", OP_FP, 0x70, 0, 0, 0x12345678ULL << 32 | x, 0, x, 0, M32);
                dcheck("FMV.W.X", OP_FP, 0x78, 0, 0, x, 0, BOX | x, 0, ALL);
            } else {
                // FMV.X.D / FMV.D.X exist in the FBox but RV32 has no such instruction; they are not checked
            }
        }
    }
    // Improperly NaN-boxed f32 operands are the canonical NaN (ISA_D builds)
    const u64 unboxed = 0x000000003F800000ULL, cn = BOX | 0x7FC00000ULL;
    dcheck("unboxed FADD.S", OP_FP, 0x00, 0, 0, unboxed, BOX | 0x3F800000, cn, 0, ALL);
    dcheck("unboxed FMIN.S (rs1)", OP_FP, 0x14, 0, 0, unboxed, BOX | 0x3F800000, BOX | 0x3F800000, 0, ALL);
    dcheck("unboxed FMIN.S (both)", OP_FP, 0x14, 0, 0, unboxed, unboxed, cn, 0, ALL);
    dcheck("unboxed FSGNJ.S", OP_FP, 0x10, 0, 0, unboxed, BOX | 0x80000000, BOX | 0xFFC00000, 0, ALL);
    dcheck("unboxed FCLASS.S", OP_FP, 0x70, 1, 0, unboxed, 0, 1u << 9, 0, M32);
    dcheck("unboxed FEQ.S", OP_FP, 0x50, 2, 0, unboxed, unboxed, 0, 0, M32);
    dcheck("unboxed FCVT.D.S", OP_FP, 0x21, 0, 0, unboxed, 0, 0x7FF8000000000000ULL, 0, ALL);
    dcheck("partially boxed FADD.S", OP_FP, 0x00, 0, 0, 0xFFFFFFFE3F800000ULL, BOX | 0x3F800000, cn, 0, ALL);
    printf("RESULT %-12s rm=- pass=%d fail=%d\n", "directed", dpass, dfail);
    return dfail ? 1 : 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new VDUT;
    reset();
    if (argc >= 2 && !strcmp(argv[1], "directed")) return directed();
    if (argc < 3) { fprintf(stderr, "usage: tb <op> <rm 0-4> [maxprint] < testfloat_gen output | tb directed\n"); return 2; }
    return testfloat(argv[1], (unsigned)atoi(argv[2]), argc > 3 ? atol(argv[3]) : 10);
}
