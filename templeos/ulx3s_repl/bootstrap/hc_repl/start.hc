// start.hc -- ULX3S bare-metal entry in HolyC asm{}.
// Loaded by the UART bootloader at 0x80000000; no FPU on the RV32IMAC core.
//
// Far `call main` from asm can become a null GOT. Thin main() + BootContinue live
// here next to _start; ReplMain() is the late body in repl.hc (IC_CALL relocates).
//
// Do NOT use `m=&main; m();` — that codegen imbalances sp / jalr x0 and wedges boot.
I64 ReplMain();
I64 main()
{
  return ReplMain();
}

U0 BootContinue()
{
  main();
}

asm {
	_start::
	lui	sp, 0x82000		// 0x82000000 = MEM_STACK
	call	BootContinue
	halt_spin:
	wfi
	j	halt_spin
}
