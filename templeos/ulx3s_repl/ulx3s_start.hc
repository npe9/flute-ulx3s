// start.hc -- ULX3S bare-metal entry in HolyC asm{}.
// Loaded by the UART bootloader at 0x80000000; no FPU on the RV32IMAC core.
//
// Far `call main` from asm can become a null GOT. Thin main() + BootContinue live
// here next to _start; ReplMain() is the late body in repl.hc (IC_CALL relocates).
//
// Do NOT use `m=&main; m();` — that codegen imbalances sp / jalr x0 and wedges boot.
#include "/bootstrap/seed/MemMapSelected.hc"

I64 ReplMain();
U0 TrapInit();
U0 SoftDbgHostSlotsClear();
I64 main()
{
  // Clear FIRST: the upstream ReplMain also calls this, but it must run
  // before TrapInit installs TRAP_DISP_FN_SLOT / TRAP_FALLBACK_VEC_SLOT
  // and before UartRxInit publishes the RX-ring pointers -- all of which
  // live inside the 4 KiB it zeroes.  (The upstream call is removed; this
  // is the single clear.)
  SoftDbgHostSlotsClear();
  TrapInit;
  return ReplMain();
}

U0 BootContinue()
{
  main();
}

// The upstream seed expects the first qword of the fixed and host-slot pages to
// be a self-pointer (the hosted C runtime installs it). On bare metal we have to
// do it ourselves, and we clear the pages first so stale SDRAM values are not
// mistaken for valid pointers.
U0 ULX3SInit()
{
  I64 *p, *end;
  p = MEM_FIXED;
  end = p + 0x1000 / sizeof(I64);
  while (p < end)
    *p++ = 0;
  p = MEM_HOST_SLOTS;
  end = p + 0x200 / sizeof(I64);
  while (p < end)
    *p++ = 0;
  *(I64 *)MEM_FIXED = MEM_FIXED;
  *(I64 *)MEM_HOST_SLOTS = MEM_HOST_SLOTS;
}

asm {
	_start::
	lui	sp, 0x82000		// 0x82000000 = MEM_STACK
	call	ULX3SInit
	call	BootContinue
	halt_spin:
	wfi
	j	halt_spin
}
