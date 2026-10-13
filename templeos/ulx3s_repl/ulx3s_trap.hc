// trap.hc -- HolyC TrapVec + TrapDispatch (G2). Asm = GPR frame + mret only.
// Policy: HolyC TrapDispatch publishes MEM_TRAP_SNAP, runs SetTrap handler,
// fault-dumps, Ctrl-C Break. Legacy: if slot MEM_FIXED+0x10 holds C trapvec, defer.
// Do NOT call SetTrap/TrapInit at file load time (mtvec swap mid-boot is unsafe).
//
// Remaining asm:
//   TrapVec / TrapCtxSave / TrapCtxRestore — frame + call TrapDispatch + mret
//   ReplSetJmp / ReplLongJmp — soft abort to prompt
//   CSR helpers — mtvec / mie / mstatus / mepc / mcause / mtval
// hc_repl: include trap_vec_off.hc before this file. Legacy boot blob: 0 + C fallback vec.
#ifndef TRAP_VEC_OFF
#define TRAP_VEC_OFF 0
#endif
#define TRAP_DISPATCH_SLOT (MEM_FIXED+0x10)
// Canonical x0..x31 view of the fault freeze: TRAP_SNAP_X + N*8 == xN, the same convention
// MEM_REGS_SNAP uses for the live snap. It sits ABOVE the live snap, not at MEM_TRAP_SNAP+0x100:
// MEM_FIXED+0x200/MEM_FIXED+0x208 are the live-Bt ra/s0 scratch in BOTH images (debug.hc BtLive,
// Kernel/RVWinSerial.HC:1023), so an array there would have x0/x1 clobbered by any `bt`.
// MEM_FIXED+0x400..MEM_FIXED+0x500 is unreferenced; MEM_HOST_SLOTS starts at MEM_HOST_SLOTS+0x0.
#define TRAP_SNAP_X (MEM_FIXED+0x400)
#define TRAP_NAME_BUF_SLOT (MEM_HOST_SLOTS+0x58)
#define TRAP_DISP_FN_SLOT (MEM_HOST_SLOTS+0x60)
#define TRAP_FALLBACK_VEC_SLOT (MEM_HOST_SLOTS+0x68)
#define TRAP_NAME_FIXED (MEM_HOST_SLOTS+0x90)
#define REPL_JB_FIXED (MEM_HOST_SLOTS+0x1000)
#define TRAP_UART_IRQ 10
#define TRAP_EXCEPT_BREAK 0x6B61657242
#define TRAP_CH_CTRLC 3
U8 g_trap_name[32];
I64 g_trap_fn;
I64 g_break_armed;
I64 g_break_pending;
I64 g_break_interactive;
I64 g_repl_jb[16];
I64 g_repl_jb_ok;
I64 g_repl_setjmp_rc;
I64 g_trap_installed;
I64 g_trap_vec;
// Recursion guard: a fault raised while TrapDispatch is already handling one
// (e.g. the crash monitor's own backtrace hitting RV64-only asm on rv32)
// must NOT re-enter the crash monitor — report minimally and recover.
I64 g_in_trap;
I64 pc;
#define _RIP pc
// Optional: hc_repl sets this to resolve JIT names (JitFind). Legacy C path uses HashFind.
I64 (*TrapResolveHook)(U8 *name);
// Optional: product path (no host RX slots) — soft-ring drain + Ctrl-C take.
U0 (*TrapUartSoftDrain)();
I64 FnAddr(U8 *name);
// OnTrap must be defined before TrapResolve's `&OnTrap` (same-unit forward
// decls have no exe_addr/entry_label yet → "Function declared but not defined").
I64 OnTrap(I64 cause, I64 epc, I64 tval)
{
  pc = epc;
  return 0;
}

asm {
	TrapVec::
	j	TrapCtxSave

	TrapCtxSave::
	addi	sp, sp, -256
	sw	x1, 8(sp)
	sw	x3, 24(sp)
	sw	x4, 32(sp)
	sw	x5, 40(sp)
	sw	x6, 48(sp)
	sw	x7, 56(sp)
	sw	x8, 64(sp)
	sw	x9, 72(sp)
	sw	x10, 80(sp)
	sw	x11, 88(sp)
	sw	x12, 96(sp)
	sw	x13, 104(sp)
	sw	x14, 112(sp)
	sw	x15, 120(sp)
	sw	x16, 128(sp)
	sw	x17, 136(sp)
	sw	x18, 144(sp)
	sw	x19, 152(sp)
	sw	x20, 160(sp)
	sw	x21, 168(sp)
	sw	x22, 176(sp)
	sw	x23, 184(sp)
	sw	x24, 192(sp)
	sw	x25, 200(sp)
	sw	x26, 208(sp)
	sw	x27, 216(sp)
	sw	x28, 224(sp)
	sw	x29, 232(sp)
	sw	x30, 240(sp)
	sw	x31, 248(sp)
	mv	a0, sp
	// RV32: load 32-bit function pointer from TRAP_DISP_FN_SLOT and dispatch.
	lui	t6, 0x81801
	addi	t6, t6, 0x60
	lw	t6, 0(t6)
	jalr	ra, 0(t6)
	j	TrapCtxRestore

	TrapCtxRestore::
	lw	x1, 8(sp)
	lw	x3, 24(sp)
	lw	x4, 32(sp)
	lw	x5, 40(sp)
	lw	x6, 48(sp)
	lw	x7, 56(sp)
	lw	x8, 64(sp)
	lw	x9, 72(sp)
	lw	x10, 80(sp)
	lw	x11, 88(sp)
	lw	x12, 96(sp)
	lw	x13, 104(sp)
	lw	x14, 112(sp)
	lw	x15, 120(sp)
	lw	x16, 128(sp)
	lw	x17, 136(sp)
	lw	x18, 144(sp)
	lw	x19, 152(sp)
	lw	x20, 160(sp)
	lw	x21, 168(sp)
	lw	x22, 176(sp)
	lw	x23, 184(sp)
	lw	x24, 192(sp)
	lw	x25, 200(sp)
	lw	x26, 208(sp)
	lw	x27, 216(sp)
	lw	x28, 224(sp)
	lw	x29, 232(sp)
	lw	x30, 240(sp)
	lw	x31, 248(sp)
	addi	sp, sp, 256
	mret
}

asm {
	HcEcall::
	ecall
	ret
	HcCsrrMtvec::
	csrr	a0, 0x305
	ret
	HcCsrrMie::
	csrr	a0, 0x304
	ret
	HcCsrrMip::
	csrr	a0, 0x344
	ret
	HcCsrrMisa::
	csrr	a0, 0x301
	ret
	HcCsrrMscratch::
	csrr	a0, 0x340
	ret
	HcCsrrMhartid::
	csrr	a0, 0xF14
	ret
	HcCsrrSatp::
	csrr	a0, 0x180
	ret
	HcCsrrMcounteren::
	csrr	a0, 0x306
	ret
	HcCsrrMedeleg::
	csrr	a0, 0x302
	ret
	HcCsrrMideleg::
	csrr	a0, 0x303
	ret
	HcCsrsMieTimer::
	li	t0, 128
	csrs	0x304, t0
	ret
	HcCsrsMieExt::
	li	t0, 2048
	csrs	0x304, t0
	ret
	HcCsrsMstatusMie::
	li	t0, 8
	csrs	0x300, t0
	ret
	HcCsrrwMtvec::
	csrw	0x305, a0
	fencei
	ret
	HcCsrrMcause::
	csrr	a0, 0x342
	ret
	HcCsrrMstatus::
	csrr	a0, 0x300
	ret
	HcCsrrMepc::
	csrr	a0, 0x341
	ret
	HcCsrrMtval::
	csrr	a0, 0x343
	ret
	HcCsrwMepc::
	csrw	0x341, a0
	ret
	TrapBareMtvec::
	li	t0, 8
	csrc	0x300, t0
	csrw	0x304, zero
	csrw	0x305, a0
	fencei
	ret
	ReplSetJmp::
	sw	ra, 0(a0)
	sw	sp, 4(a0)
	sw	s0, 8(a0)
	sw	s1, 12(a0)
	sw	s2, 16(a0)
	sw	s3, 20(a0)
	sw	s4, 24(a0)
	sw	s5, 28(a0)
	sw	s6, 32(a0)
	sw	s7, 36(a0)
	sw	s8, 40(a0)
	sw	s9, 44(a0)
	sw	s10, 48(a0)
	sw	s11, 52(a0)
	li	a0, 0
	ret
	ReplLongJmp::
	lw	ra, 0(a0)
	lw	sp, 4(a0)
	lw	s0, 8(a0)
	lw	s1, 12(a0)
	lw	s2, 16(a0)
	lw	s3, 20(a0)
	lw	s4, 24(a0)
	lw	s5, 28(a0)
	lw	s6, 32(a0)
	lw	s7, 36(a0)
	lw	s8, 40(a0)
	lw	s9, 44(a0)
	lw	s10, 48(a0)
	lw	s11, 52(a0)
	li	a0, 1
	ret
	ReplDoSetJmpHc::
	lui	a0, 0x81802
	sw	ra, 0(a0)
	sw	sp, 4(a0)
	sw	s0, 8(a0)
	sw	s1, 12(a0)
	sw	s2, 16(a0)
	sw	s3, 20(a0)
	sw	s4, 24(a0)
	sw	s5, 28(a0)
	sw	s6, 32(a0)
	sw	s7, 36(a0)
	sw	s8, 40(a0)
	sw	s9, 44(a0)
	sw	s10, 48(a0)
	sw	s11, 52(a0)
	li	a0, 0
	ret
	ReplDoLongJmpHc::
	lui	a0, 0x81802
	lw	ra, 0(a0)
	lw	sp, 4(a0)
	lw	s0, 8(a0)
	lw	s1, 12(a0)
	lw	s2, 16(a0)
	lw	s3, 20(a0)
	lw	s4, 24(a0)
	lw	s5, 28(a0)
	lw	s6, 32(a0)
	lw	s7, 36(a0)
	lw	s8, 40(a0)
	lw	s9, 44(a0)
	lw	s10, 48(a0)
	lw	s11, 52(a0)
	li	a0, 1
	ret
	FaultDo::
	unimp
	ret
}

I64 TrapNameEq(U8 *a, U8 *b)
{
  if (!a || !b)
    return 0;
  while (*a && *a == *b) {
    a++;
    b++;
  }
  return !*a && !*b;
}

I64 TrapCall0(I64 fn)
{
  I64 (*f)();
  if (!fn)
    return 0;
  f = fn;
  return f();
}

I64 TrapCall3(I64 fn, I64 a, I64 b, I64 c)
{
  I64 (*f)(I64, I64, I64);
  if (!fn)
    return 0;
  f = fn;
  return f(a, b, c);
}

U0 TrapPutHex(I64 v)
{
  I64 i, d;
  U8 c;
  UartStr("0x");
  i = 60;
  while (i >= 0) {
    d = (v >> i) & 15;
    if (d < 10)
      c = '0' + d;
    else
      c = 'a' + d - 10;
    PutCh(c);
    i = i - 4;
  }
}

U8 *TrapCauseName(I64 cause)
{
  // Shared table with CsrDecodeMcause / McausePrint (csr.hc).
  return McauseCauseName(cause);
}

I64 TrapResolve(U8 *name)
{
  I64 a;
  if (!name || !*name)
    return 0;
  if (TrapResolveHook) {
    a = TrapResolveHook(name);
    if (a)
      return a;
  }
  a = FnAddr(name);
  if (a)
    return a;
  if (TrapNameEq(name, "OnTrap"))
    return &OnTrap;
  return 0;
}

U0 TrapNameStore(U8 *name)
{
  I64 i, buf;
  i = 0;
  if (name) {
    while (i < 31 && *(U8 *)(name + i)) {
      g_trap_name[i] = *(U8 *)(name + i);
      i++;
    }
  }
  g_trap_name[i] = 0;
  buf = *(I64 *)TRAP_NAME_BUF_SLOT;
  if (!buf || buf < 0x80000000 || buf >= 0x88000000)
    buf = TRAP_NAME_FIXED;
  i = 0;
  while (i < 32) {
    *(U8 *)(buf + i) = g_trap_name[i];
    i++;
  }
}
// TrapCtxSave's frame is indexed by register number (xN at N*8, 256 bytes; x2/sp implicit).
// Two views are published, both readable while frozen (see debug.hc's index map):
//   legacy slots 0..21  — ra,t0..t6,a0..a7,sp,fp,mcause,mepc,mtval,mstatus (existing readers)
//   canonical x array   — MEM_TRAP_SNAP+0x100 + N*8 = xN, matching MEM_REGS_SNAP's convention
//                         so one formatter serves the fault freeze and the live snap.
// The array ends exactly at MEM_REGS_SNAP (MEM_FIXED+0x300): 32 slots, no room for a 33rd.
// mstatus is the value AFTER the trap (MIE cleared, MPP/MPIE hold the trapped state).
I64 g_trap_snap_live;
U0 TrapSnapPublish(I64 *frame, I64 cause, I64 epc, I64 tval)
{
  I64 k, sp_at_trap;
  sp_at_trap = (I64)frame + 256;
  *(I64 *)TRAP_SNAP_X = 0;
  // x0
  for (k = 1; k < 32; k++) {
    if (k == 2)
      *(I64 *)(TRAP_SNAP_X + k * 8) = sp_at_trap;
    else
      *(I64 *)(TRAP_SNAP_X + k * 8) = frame[k];
  }
  *(I64 *)(MEM_TRAP_SNAP + 0 * 8) = frame[1];
  // ra = x1
  for (k = 0; k < 3; k++)
    *(I64 *)(MEM_TRAP_SNAP + (1 + k) * 8) = frame[5 + k];
  // t0..t2 = x5..x7
  for (k = 0; k < 4; k++)
    *(I64 *)(MEM_TRAP_SNAP + (4 + k) * 8) = frame[28 + k];
  // t3..t6 = x28..x31
  for (k = 0; k < 8; k++)
    *(I64 *)(MEM_TRAP_SNAP + (8 + k) * 8) = frame[10 + k];
  // a0..a7 = x10..x17
  *(I64 *)(MEM_TRAP_SNAP + 16 * 8) = sp_at_trap;
  *(I64 *)(MEM_TRAP_SNAP + 17 * 8) = frame[8];
  // fp = s0 = x8
  *(I64 *)(MEM_TRAP_SNAP + 18 * 8) = cause;
  *(I64 *)(MEM_TRAP_SNAP + 19 * 8) = epc;
  *(I64 *)(MEM_TRAP_SNAP + 20 * 8) = tval;
  *(I64 *)(MEM_TRAP_SNAP + 21 * 8) = HcCsrrMstatus();
  // Slots 22..31: the rest of the stopped machine. Same list, same order as the C runtime's
  // HolyTrapSnapPublish — two publishers of one layout, so they have to agree.
  *(I64 *)(MEM_TRAP_SNAP + 22 * 8) = HcCsrrMtvec();
  *(I64 *)(MEM_TRAP_SNAP + 23 * 8) = HcCsrrMie();
  *(I64 *)(MEM_TRAP_SNAP + 24 * 8) = HcCsrrMip();
  *(I64 *)(MEM_TRAP_SNAP + 25 * 8) = HcCsrrMisa();
  *(I64 *)(MEM_TRAP_SNAP + 26 * 8) = HcCsrrMscratch();
  *(I64 *)(MEM_TRAP_SNAP + 27 * 8) = HcCsrrMhartid();
  // satp/medeleg/mideleg do not exist on this M/U-only core (no S-mode in
  // the Flute build): reading them raises an illegal-instruction fault
  // INSIDE TrapSnapPublish, which re-enters the trap path and loops
  // forever.  Publish 0 for the S-only CSRs.
  *(I64 *)(MEM_TRAP_SNAP + 28 * 8) = 0;
  // satp: not implemented
  *(I64 *)(MEM_TRAP_SNAP + 29 * 8) = HcCsrrMcounteren();
  *(I64 *)(MEM_TRAP_SNAP + 30 * 8) = 0;
  // medeleg: not implemented
  *(I64 *)(MEM_TRAP_SNAP + 31 * 8) = 0;
  // mideleg: not implemented
  // No float freeze in THIS image, and the flag says so rather than leaving a stale 1 from
  // whoever ran before. The C runtime's trap path does save f0..f31 (holy_rt.h), but here a
  // single fsd in the trap path breaks the image even with the mstatus.FS guard that works
  // there — an empty stub in the same place is fine, so it is the store, not the call. Whatever
  // this image does with the FPU at trap time needs understanding before trying again; until
  // then a reader sees flag=0 and knows these floats belong to nobody.
  *(I64 *)(MEM_FIXED + 0xF00) = 0;
  g_trap_snap_live = 1;
  pc = epc;
}
// Copy the canonical array back into the frame before TrapCtxRestore reloads it, so a register
// EDITED while stopped is live on resume — stock TempleOS lets you assign _RAX/_RIP in the
// debugger (Doc/DbgOverview.DD), and the labels planted by RVExePubsWireDbgRegs write here.
// x0 and x2 are skipped: x0 is hardwired and sp is the frame's own address, not a slot in it.
// Only runs when this trap published a freeze (interrupt paths return before this).
U0 TrapSnapApply(I64 *frame)
{
  I64 k;
  if (!g_trap_snap_live || !frame)
    return;
  g_trap_snap_live = 0;
  for (k = 1; k < 32; k++) {
    if (k == 2)
      continue;
    frame[k] = *(I64 *)(TRAP_SNAP_X + k * 8);
  }
}

U0 TrapUartHwDrain()
{
  I64 ch, n, rx, rhp, rtp, cap, rh, rt, skip;
  PUSHFD;
  CLI;
  rx = *(I64 *)MEM_HOST_SLOTS + 0x20;
  rhp = *(I64 *)MEM_HOST_SLOTS + 0x28;
  rtp = *(I64 *)MEM_HOST_SLOTS + 0x30;
  cap = *(I64 *)MEM_HOST_SLOTS + 0x38;
  if (rx && rhp && rtp && cap >= 2) {
    // LSR is register index 5: word stride 4 -> +20 (byte offset +5 faults
    // on the SoC 16550, which decodes aligned word registers only).
    while (*(U8 *)(MEM_UART + 20) & 1) {
      ch = *(U8 *)MEM_UART;
      if (UartFcIsCtrl(ch)) {
        UartFcNote(ch);
      } else {
        skip = 0;
        if (ch == TRAP_CH_CTRLC) {
          g_break_pending = 1;
          if (g_break_armed)
            skip = 1;
        }
        if (!skip) {
          rh = *(I64 *)rhp;
          rt = *(I64 *)rtp;
          n = (rh + 1) & (cap - 1);
          if (n == rt)
            break;
          *(U8 *)(rx + rh) = ch;
          *(I64 *)rhp = n;
        }
      }
    }
  } else if (TrapUartSoftDrain) {
    TrapUartSoftDrain();
  } else {
    while (*(U8 *)(MEM_UART + 20) & 1) {
      ch = *(U8 *)MEM_UART;
      if (UartFcIsCtrl(ch))
        UartFcNote(ch);
      else if (ch == TRAP_CH_CTRLC)
        g_break_pending = 1;
    }
  }
  POPFD;
}

I64 TrapPlicServiceUart()
{
  I64 claim, irq;
  claim = MEM_PLIC + MEM_PLIC_CLAIM_OFF;
  irq = *(U32 *)claim;
  if (irq == TRAP_UART_IRQ)
    TrapUartHwDrain();
  if (irq)
    *(U32 *)claim = irq;
  return irq;
}

U0 UartBreakIrqInit()
{
  // IER is register index 1: word stride 4 -> +4 (byte offset +1 faults).
  *(U32 *)(MEM_UART + 4) = 1;
  *(U32 *)(MEM_PLIC + TRAP_UART_IRQ * 4) = 1;
  *(U32 *)(MEM_PLIC + MEM_PLIC_ENABLE_OFF) = *(U32 *)(MEM_PLIC + MEM_PLIC_ENABLE_OFF) | (1 << TRAP_UART_IRQ);
  *(U32 *)(MEM_PLIC + MEM_PLIC_THRESHOLD_OFF) = 0;
  HcCsrsMieExt();
}

U0 BreakArm()
{
  TrapInitOnce();
  g_break_pending = 0;
  TrapUartHwDrain();
  g_break_armed = 1;
  UartBreakIrqInit();
  HcCsrsMstatusMie();
  *(I64 *)MEM_MTIMECMP = *(I64 *)MEM_MTIME + 100000;
  HcCsrsMieTimer();
}

U0 BreakDisarm()
{
  g_break_armed = 0;
  g_break_pending = 0;
  *(I64 *)MEM_MTIMECMP = -1;
}

U0 TrapFaultRecover()
{
  BreakDisarm();
  UartStr("-- eval aborted, back to the REPL --\n");
  if (g_repl_jb_ok)
    ReplDoLongJmpHc();
  while (TRUE)
    HLT;
}

U0 TrapBreakRaise()
{
  BreakDisarm();
  UartStr("\nInterrupted\n");
  if (g_repl_jb_ok)
    ReplDoLongJmpHc();
  while (TRUE)
    HLT;
}
// ULX3S console fault policy: print the full crash dump, then go STRAIGHT
// back to the REPL — no interactive crash> stop.  The interactive monitor
// stays available on demand via the CrashMon; command, and a fault inside it
// is caught by TrapDispatch's g_in_trap guard.  (The upstream default,
// CrashOnTrap = CrashDump + interactive CrashMon, wedges on this port:
// its backtrace runs RV64-only sd/ld asm on rv32.)
U0 CrashDump();
I64 DbgTrap(I64 cause, I64 epc, I64 tval);
I64 CrashAutoRecover(I64 cause, I64 epc, I64 tval)
{
  if (cause & 0x80000000)
    return epc;
  if (cause == 8 || cause == 9 || cause == 11)
    return epc + 4;
  if (cause == 3) {
    I64 r;
    r = DbgTrap(cause, epc, tval);
    if (r)
      return r;
    return &TrapFaultRecover;
  }
  pc = epc;
  CrashDump();
  return &TrapFaultRecover;
}
// Ulx3sMemMap -- the MemMap; command for the ULX3S Flute SoC.
// Published through MemMap's legacy host-slot hook (see TrapInit).
// Every value shown is DERIVED, not hand-maintained:
//   - SoC regions / irq / clock / baud / chip / ISA: generated into
//     /bootstrap/seed/ulx3s_board.hc by scripts/gen_board_hc.py, which parses
//     SoC_Map.bsv / SoC_Fabric.bsv / ULX3S_Top.bsv / Top.v / Makefile and
//     FAILS THE BUILD if the guest map drifts from the SoC map.
//   - Guest arenas: MEM_* macros of ulx3s_memmap.hc, JIT_* of jit.hc (both
//     included before this file).
//   - Image extent: previous build's blob size (advisory; may lag one build).
#include "/bootstrap/seed/ulx3s_board.hc"
U0 Ulx3sMemMap()
{
  UartStr("Memory map -- ULX3S Flute SoC (");
  UartStr(ULX3S_CORE);
  UartStr(" @ ");
  Print("%d.%d MHz on ", ULX3S_SYS_CLK_HZ / 1000000, (ULX3S_SYS_CLK_HZ / 100000) % 10);
  UartStr(ULX3S_FPGA);
  UartStr("):\n");
  // Live self-description: what the hardware itself reports, straight from
  // the SoC Info block (guarded by the magic so old bitstreams don't fault).
  
  {
    U32 *si = (U32 *)MEM_SOC_INFO;
    if (si[0] == 0x464C5331)
      Print("  SoC info (live @ %X): ver=%d build=%d features=0x%X devices=%d buserr=%d\n", MEM_SOC_INFO, si[1], si[2], si[3], si[7], si[11]);
    else
      UartStr("  SoC info: not present (old bitstream)\n");
  }
  Print("  %X  Boot ROM (BRAM)   first-stage UART boot loader (boot/boot_loader.c)\n", ULX3S_BOOTROM_BASE);
  Print("  %X  SDRAM %d MB       %s, CL2 BL8 + refresh\n", MEM_RAM, ULX3S_SDRAM_MB, ULX3S_SDRAM_CHIP);
  Print("  %X    REPL image      AOT blob, to 0x%X (%d KB, previous build)\n", MEM_RAM, ULX3S_IMAGE_END, ULX3S_IMAGE_KB);
  Print("  %X    MEM_HEAP        HolyC MAlloc arena (mem.hc)\n", MEM_HEAP);
  Print("  %X    MEM_FS          HolyC memfs (fs.hc)\n", MEM_FS);
  Print("  %X    MEM_FIXED       trap/regs page (%d KiB)\n", MEM_FIXED, (MEM_HOST_SLOTS - MEM_FIXED) / 1024);
  Print("  %X    MEM_TRAP_SNAP   trap GPR/cause snapshot\n", MEM_TRAP_SNAP);
  Print("  %X    MEM_REGS_SNAP   Regs() snapshot\n", MEM_REGS_SNAP);
  Print("  %X    MEM_HOST_SLOTS  soft-debug / host slots\n", MEM_HOST_SLOTS);
  Print("  %X  JIT_GLOBB       JIT typed globals (64 slots)\n", JIT_GLOBB);
  Print("  %X  JIT arena       JIT code + strings, to 0x%X\n", JIT_BASE, JIT_END);
  if (jit_at)
    Print("    JIT used: %d KB of %d KB (next free 0x%X)\n", (jit_at - JIT_BASE) / 1024, (JIT_END - JIT_BASE) / 1024, jit_at);
  Print("  %X  CLINT             mtime @ %X, mtimecmp @ %X (near-mem port)\n", ULX3S_CLINT_BASE, MEM_MTIME, MEM_MTIMECMP);
  if (ULX3S_PLIC_ROUTED)
    Print("  %X  PLIC              external IRQs, UART0 = source %d\n", ULX3S_PLIC_BASE, ULX3S_UART0_IRQ);
  else
    Print("  %X  PLIC              RESERVED VOID -- no fabric slave; UART0 irq = core ext source %d\n", ULX3S_PLIC_BASE, ULX3S_UART0_IRQ);
  Print("  %X  UART0             16550, %d baud (FTDI console)\n", ULX3S_UART0_BASE, ULX3S_BAUD);
  if (ULX3S_GPIO_PRESENT)
    Print("  %X  GPIO              LEDs 0x01-0xFF @ +0 (active high), FIRE buttons\n", ULX3S_GPIO_BASE);
  UartStr("  absent on Flute: ");
  UartStr(ULX3S_ABSENT_LIST);
  UartStr("\n");
  UartStr("Dig-down: MemMapDrv; Regs; Reg(\"mstatus\"); Print(\"%X\\n\", MEM_HEAP);\n");
}

U0 TrapFaultDump(I64 *frame, I64 cause, I64 epc, I64 tval)
{
  UartStr("\n*** FAULT: ");
  UartStr(TrapCauseName(cause));
  UartStr("\n");
  McausePrint(cause);
  UartStr("  tval=");
  TrapPutHex(tval);
  UartStr("\n  pc  = ");
  TrapPutHex(epc);
  UartStr("\n  ra  = ");
  // frame[1], not frame[0]: TrapCtxSave stores x1 at 8(sp) and never writes slot 0, so this
  // line printed uninitialised stack in every fault dump. TrapSnapPublish has always used
  // frame[1] — the two disagreed and the dump was the one that was wrong.
  TrapPutHex(frame[1]);
  UartStr("\n  (TrapDump; U(pc-16); for dig-down)\n");
}

U0 TrapDispatch(I64 *frame)
{
  I64 cause, epc, tval, resume, slot, ext_irq, skip_hc, fn;
  I64 (*cpol)(I64 *);
  cause = HcCsrrMcause();
  epc = HcCsrrMepc();
  tval = HcCsrrMtval();
  if (g_in_trap) {
    // Fault inside the fault handler (classic case: CrashOnTrap -> Bt ->
    // RV64-only sd/ld asm on rv32).  Re-entering the crash monitor would
    // recurse forever; report one line and recover to the REPL.
    UartStr("*** FAULT-IN-FAULT ***\n  mcause=");
    TrapPutHex(cause);
    UartStr(" mepc=");
    TrapPutHex(epc);
    UartStr(" mtval=");
    TrapPutHex(tval);
    UartStr("\n");
    if (g_repl_jb_ok) {
      g_in_trap = 0;
      HcCsrwMepc(&TrapFaultRecover);
      return;
    }
    while (TRUE)
      HLT;
  }
  g_in_trap = 1;
  if (!g_break_interactive && cause & 0x80000000) {
    if ((cause & 0xFF) == 7)
      *(I64 *)MEM_MTIMECMP = -1;
    else if ((cause & 0xFF) == 11)
      TrapPlicServiceUart();
    g_in_trap = 0;
    HcCsrwMepc(epc);
    return;
  }
  slot = *(I64 *)TRAP_DISPATCH_SLOT;
  if (slot && slot != &TrapDispatch && slot >= 0x80000000 && slot < 0x88000000) {
    cpol = slot;
    cpol(frame);
    g_in_trap = 0;
    return;
  }
  TrapSnapPublish(frame, cause, epc, tval);
  ext_irq = -1;
  if (cause & 0x80000000 && (cause & 0xFF) == 11)
    ext_irq = TrapPlicServiceUart();
  if (!g_break_armed && cause & 0x80000000 && (cause & 0xFF) == 7) {
    *(I64 *)MEM_MTIMECMP = -1;
    g_in_trap = 0;
    HcCsrwMepc(epc);
    return;
  }
  if (g_break_armed && cause & 0x80000000 && (cause & 0xFF) == 7) {
    TrapUartHwDrain();
    *(I64 *)MEM_MTIMECMP = *(I64 *)MEM_MTIME + 100000;
    if (g_break_pending) {
      g_in_trap = 0;
      HcCsrwMepc(&TrapBreakRaise);
      return;
    }
    g_in_trap = 0;
    HcCsrwMepc(epc);
    return;
  }
  if (g_break_armed)
    TrapUartHwDrain();
  resume = 0;
  skip_hc = ext_irq == TRAP_UART_IRQ;
  fn = 0;
  if (!skip_hc) {
    fn = g_trap_fn;
    if (!fn && g_trap_name[0])
      fn = TrapResolve(g_trap_name);
  }
  if (fn)
    resume = TrapCall3(fn, cause, epc, tval);
  if (g_break_armed && g_break_pending) {
    g_in_trap = 0;
    HcCsrwMepc(&TrapBreakRaise);
    return;
  }
  if (!resume) {
    if (cause & 0x80000000)
      resume = epc;
    else if (cause == 8 || cause == 9 || cause == 11)
      resume = epc + 4;
    else {
      TrapFaultDump(frame, cause, epc, tval);
      if (g_repl_jb_ok)
        resume = &TrapFaultRecover;
      else
        resume = epc + 4;
    }
  }
  TrapSnapApply(frame);
  g_in_trap = 0;
  HcCsrwMepc(resume);
}

U0 SetTrap(U8 *name)
{
  // Legacy boot blob (TRAP_VEC_OFF 0): C already owns mtvec + TRAP_DISP_FN_SLOT.
  // TrapInitOnce→TrapInit rewrites slots / can instruction-access-fault; name-only is enough.
  if (!TRAP_VEC_OFF) {
    TrapNameStore(name);
    g_trap_fn = 0;
    g_break_interactive = 1;
    return;
  }
  TrapInitOnce();
  TrapNameStore(name);
  g_trap_fn = 0;
}

U0 SetTrapFn(I64 fn)
{
  g_trap_fn = fn;
  g_trap_name[0] = 0;
}

U0 TrapInitOnce()
{
  if (g_trap_installed)
    return;
  g_trap_installed = 1;
  TrapInit();
}

U0 TrapVecAddrFix()
{
  I64 off;
  off = TRAP_VEC_OFF;
  if (off)
    g_trap_vec = 0x80000000 + off;
}

U0 TrapInit()
{
  I64 vec, disp;
  *(I64 *)TRAP_NAME_BUF_SLOT = TRAP_NAME_FIXED;
  *(I64 *)MEM_MTIMECMP = -1;
  // Publish the Flute-specific memory map for the MemMap; command through
  // the legacy host-slot hook: SoftDbgSlotFnOk wants the "TOLS" magic at
  // +0xFF8 and a handler pointer in RAM at +0x128.  Only these two slots are
  // touched — slot 0 stays zero so Regs/Reg keep their HolyC paths.
  *(I64 *)(MEM_HOST_SLOTS + 0xFF8) = 0x534C4F54;
  *(I64 *)(MEM_HOST_SLOTS + 0x128) = &Ulx3sMemMap;
  disp = *(I64 *)TRAP_DISP_FN_SLOT;
  if (disp && disp != &TrapDispatch && disp >= 0x80000000 && disp < 0x88000000)
    *(I64 *)TRAP_DISPATCH_SLOT = disp;
  else {
    *(I64 *)TRAP_DISPATCH_SLOT = 0;
    *(I64 *)TRAP_DISP_FN_SLOT = &TrapDispatch;
  }
  if (!g_trap_vec)
    TrapVecAddrFix();
  vec = g_trap_vec;
  if (!vec || vec < 0x80000000 || vec >= 0x88000000)
    vec = *(I64 *)TRAP_FALLBACK_VEC_SLOT;
  if (!vec)
    return;
  // Rewrite mtvec only when AOT published a real TrapVec offset (hc_repl).
  // Legacy boot blob keeps TRAP_VEC_OFF 0; C already installed mtvec.
  // Do NOT gate on FnAddr("TrapBareMtvec") — asm labels are not in the JIT
  // table, so that check skipped the install and Fault hung on default mtvec=0.
  if (TRAP_VEC_OFF) {
    CLI;
    TrapBareMtvec(vec);
  }
  if (!g_trap_name[0] && !g_trap_fn)
    SetTrap("CrashAutoRecover");
  g_break_interactive = 1;
}

U0 Ecall()
{
  TrapInitOnce();
  HcEcall();
}

U0 TimerArm(I64 interval)
{
  I64 *mtime, *mtimecmp;
  mtime = MEM_MTIME;
  mtimecmp = MEM_MTIMECMP;
  *mtimecmp = *mtime + interval;
  HcCsrsMieTimer();
}

U0 Reset()
{
  I64 boot;
  boot = TrapResolve("Boot");
  if (!boot)
    boot = FnAddr("Boot");
  if (!boot) {
    UartStr("Reset: no Boot()\n");
    return;
  }
  *(I64 *)MEM_FIXED + 0x0 = *(I64 *)MEM_HOST_SLOTS + 0x80;
  TrapCall0(boot);
}
// SiFive test finisher @ MEM_TEST (QEMU virt sifive_test @ 0x100000).
// U32 stores only: PASS=0x5555 → QEMU exit 0; FAIL=0x3333|(code<<16); RESET=0x7777.
#ifndef TEST_FINISHER_FAIL
#define TEST_FINISHER_FAIL  0x3333
#define TEST_FINISHER_PASS  0x5555
#define TEST_FINISHER_RESET 0x7777
#endif
// TestFinisher -- TestFinisher(code)
// NAME
//   TestFinisher - poke SiFive test MMIO (QEMU virt harness)
// SYNOPSIS
//   U0 TestFinisher(U32 code);
// DESCRIPTION
//   Writes `code` to MEM_TEST then parks in wfi. On QEMU -M virt this is the
//   sifive_test device: 0x5555 pass/shutdown, 0x3333 fail, 0x7777 reset.
//   No-op message if MEM_TEST is 0 (board without finisher).
// EXAMPLES
//   Quit;       // PASS
//   Fail;       // FAIL code 0
//   HardReset;  // guest reset request
// SEE ALSO
//   Quit  Exit  Fail  HardReset  Halt  MEM_TEST
U0 TestFinisher(U32 code)
{
  U32 *t;
  if (!MEM_TEST) {
    UartStr("TestFinisher: MEM_TEST not mapped\n");
    return;
  }
  t = MEM_TEST;
  *t = code;
  while (TRUE)
    HLT;
}
// Quit -- Quit()
// NAME
//   Quit - shut down QEMU via SiFive test PASS (0x5555)
// SYNOPSIS
//   Quit;  Exit;  PowerOff;
// DESCRIPTION
//   Writes TEST_FINISHER_PASS to MEM_TEST. On QEMU virt this ends the emulator
//   with success (exit 0). Soft Reset; only re-enters Boot — use Quit to leave.
// EXAMPLES
//   Quit;
// SEE ALSO
//   Exit  PowerOff  Fail  HardReset  Reset  Halt
U0 Quit()
{
  TestFinisher(TEST_FINISHER_PASS);
}

U0 Exit()
{
  Quit;
}

U0 PowerOff()
{
  Quit;
}
// Fail -- Fail()
// NAME
//   Fail - shut down QEMU via SiFive test FAIL (0x3333 | 1<<16)
// SYNOPSIS
//   Fail;
// DESCRIPTION
//   Writes FAIL with panic code 1 in bits 31:16 so the host process typically
//   exits non-zero. Custom codes: TestFinisher(0x3333 | (n << 16));
// EXAMPLES
//   Fail;
// SEE ALSO
//   Quit  HardReset  TestFinisher
U0 Fail()
{
  TestFinisher(TEST_FINISHER_FAIL | (1 << 16));
}

U0 HardReset()
{
  TestFinisher(TEST_FINISHER_RESET);
}

U0 Halt()
{
  while (TRUE)
    HLT;
}

U0 Fault()
{
  TrapInitOnce();
  FaultDo();
}

U0 Break()
{
  TrapInitOnce();
  if (__try_top)
    throw(TRAP_EXCEPT_BREAK);
  BreakDisarm();
  UartStr("\nInterrupted\n");
  if (g_repl_jb_ok)
    ReplDoLongJmpHc();
  throw(TRAP_EXCEPT_BREAK);
}
