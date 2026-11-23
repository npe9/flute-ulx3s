(* formal/sw/rocq/Run.v: tier 3 of notes/sw-verification-plan.md -- the program logic.

   The Sail RISC-V model, generated as Rocq (formal/sw/rocq/build.sh), gives each instruction
   as a tree of interface events: [execute ast : M Retired] is [Ret r] or [Next e k] with e a
   register read or write, a memory read or write, an announcement, a trap, or a
   nondeterministic choice.  This file gives those trees a meaning:

   - [run]: interprets a tree against a register file (every register: a dependent function)
     and the device / memory environment [env] (what a memory read returns: anything -- a
     theorem quantifies over env), logging every memory write.  A trap, an exception, a failure
     or a nondeterministic choice makes [run] return None: a theorem that [run] gives [Some]
     says the code does not trap (S1).
   - [step]: one instruction from a code map, as sail-riscv's riscv_step.sail does it on the
     path without traps or interrupts: fetch the halfword or word at PC, decode
     (encdec_compressed_backwards / encdec_backwards), set nextPC = PC + length, execute,
     require RETIRE_SUCCESS, PC := nextPC.  This step is the one piece of the semantics written
     here rather than generated from Sail (part of the trusted base; riscv_step.sail is not in
     sail-riscv's Rocq build).  Interrupts are not modelled: the title runs with them off.

   The trusted base of a theorem below: the Sail model (sail-riscv af5c2f2 + soc-coq.patch),
   sail's Rocq backend, coq-sail-stdpp, support/riscv_extras.v (configuration and platform
   values), this file's [run] and [step], the theorem statement, and Rocq. *)

From stdpp Require Import base list.
From stdpp.bitvector Require Import definitions.
Require Import SailStdpp.Base SailStdpp.ConcurrencyInterface.
Require Import RV32.riscv_types RV32.riscv.
Import Defs.

(* ---------------- machine state *)
Definition regs := forall r : register, type_of_register r.

(* A register write.  No transport along a register equality: the generated equality proofs
   are opaque (register_encode_inj), so a cast along one never computes.  Within one value-type
   group the new value already has the right type, and registers are compared by number. *)
Definition upd (s : regs) (r : register) : type_of_register r -> regs :=
  match r return type_of_register r -> regs with
  | R_Privilege a => fun v r' => match r' return type_of_register r' with
      | R_Privilege b => if Z.eqb (num_of_register_Privilege a) (num_of_register_Privilege b) then v else s (R_Privilege b)
      | r'' => s r'' end
  | R_bitvector_1 a => fun v r' => match r' return type_of_register r' with
      | R_bitvector_1 b => if Z.eqb (num_of_register_bitvector_1 a) (num_of_register_bitvector_1 b) then v else s (R_bitvector_1 b)
      | r'' => s r'' end
  | R_bitvector_16 a => fun v r' => match r' return type_of_register r' with
      | R_bitvector_16 b => if Z.eqb (num_of_register_bitvector_16 a) (num_of_register_bitvector_16 b) then v else s (R_bitvector_16 b)
      | r'' => s r'' end
  | R_bitvector_2 a => fun v r' => match r' return type_of_register r' with
      | R_bitvector_2 b => if Z.eqb (num_of_register_bitvector_2 a) (num_of_register_bitvector_2 b) then v else s (R_bitvector_2 b)
      | r'' => s r'' end
  | R_bitvector_3 a => fun v r' => match r' return type_of_register r' with
      | R_bitvector_3 b => if Z.eqb (num_of_register_bitvector_3 a) (num_of_register_bitvector_3 b) then v else s (R_bitvector_3 b)
      | r'' => s r'' end
  | R_bitvector_32 a => fun v r' => match r' return type_of_register r' with
      | R_bitvector_32 b => if Z.eqb (num_of_register_bitvector_32 a) (num_of_register_bitvector_32 b) then v else s (R_bitvector_32 b)
      | r'' => s r'' end
  | R_bitvector_4 a => fun v r' => match r' return type_of_register r' with
      | R_bitvector_4 b => if Z.eqb (num_of_register_bitvector_4 a) (num_of_register_bitvector_4 b) then v else s (R_bitvector_4 b)
      | r'' => s r'' end
  | R_bitvector_64 a => fun v r' => match r' return type_of_register r' with
      | R_bitvector_64 b => if Z.eqb (num_of_register_bitvector_64 a) (num_of_register_bitvector_64 b) then v else s (R_bitvector_64 b)
      | r'' => s r'' end
  | R_bitvector_65536 a => fun v r' => match r' return type_of_register r' with
      | R_bitvector_65536 b => if Z.eqb (num_of_register_bitvector_65536 a) (num_of_register_bitvector_65536 b) then v else s (R_bitvector_65536 b)
      | r'' => s r'' end
  | R_bool a => fun v r' => match r' return type_of_register r' with
      | R_bool b => if Z.eqb (num_of_register_bool a) (num_of_register_bool b) then v else s (R_bool b)
      | r'' => s r'' end
  | R_option_TLB_Entry a => fun v r' => match r' return type_of_register r' with
      | R_option_TLB_Entry b => if Z.eqb (num_of_register_option_TLB_Entry a) (num_of_register_option_TLB_Entry b) then v else s (R_option_TLB_Entry b)
      | r'' => s r'' end
  | R_vector_64_bitvector_32 a => fun v r' => match r' return type_of_register r' with
      | R_vector_64_bitvector_32 b => if Z.eqb (num_of_register_vector_64_bitvector_32 a) (num_of_register_vector_64_bitvector_32 b) then v else s (R_vector_64_bitvector_32 b)
      | r'' => s r'' end
  | R_vector_64_bitvector_8 a => fun v r' => match r' return type_of_register r' with
      | R_vector_64_bitvector_8 b => if Z.eqb (num_of_register_vector_64_bitvector_8 a) (num_of_register_vector_64_bitvector_8 b) then v else s (R_vector_64_bitvector_8 b)
      | r'' => s r'' end
  end.

(* a memory write the code made: physical address, bytes, value *)
Record wr := { w_pa : Z; w_n : N; w_v : Z }.

(* the environment's answer to a memory read of n bytes at a physical address *)
Definition env_t := forall n : N, mword 32 -> bv (8 * n).

(* ---------------- the event semantics *)
Fixpoint run {A} (env : env_t) (s : regs) (ws : list wr) (t : M A) {struct t}
  : option (A * regs * list wr) :=
  match t with
  | Interface.Ret a => Some (a, s, ws)
  | Interface.Next oc k =>
      match oc in @Interface.outcome _ T return (T -> M A) -> option (A * regs * list wr) with
      | Interface.RegRead r _ => fun k => run env s ws (k (s r))
      | Interface.RegWrite r _ v => fun k => run env (upd s r v) ws (k tt)
      | Interface.MemRead n req => fun k =>
          run env s ws (k (inl (env n (Interface.ReadReq.pa req), None)))
      | Interface.MemWrite n req => fun k =>
          run env s (ws ++ [{| w_pa := bv_unsigned (Interface.WriteReq.pa req); w_n := n;
                               w_v := bv_unsigned (Interface.WriteReq.value req) |}])
              (k (inl None))
      | Interface.InstrAnnounce _ => fun k => run env s ws (k tt)
      | Interface.BranchAnnounce _ _ => fun k => run env s ws (k tt)
      | Interface.Barrier _ => fun k => run env s ws (k tt)
      | Interface.CycleCount => fun k => run env s ws (k tt)
      | Interface.Message _ => fun k => run env s ws (k tt)
      | _ => fun _ => None          (* traps, exceptions, failures, choices, ... *)
      end k
  end.

(* ---------------- one instruction *)
(* the code: what a fetch of a halfword at an address returns (the binary's .text) *)
Definition code_t := Z -> option (mword 16).

Definition fetch_insn (code : code_t) (pc : Z) : option (mword 16 + mword 32) :=
  match code pc with
  | None => None
  | Some lo =>
      if bool_decide (bv_unsigned lo `mod` 4 = 3)%Z then
        match code (pc + 2)%Z with
        | None => None
        | Some hi => Some (inr (concat_vec hi lo))
        end
      else Some (inl lo)
  end.

Definition step (code : code_t) (env : env_t) (s : regs) (ws : list wr) : option (regs * list wr) :=
  let pc := s (R_bitvector_32 PC) in
  match fetch_insn code (bv_unsigned pc) with
  | None => None
  | Some insn =>
      let '(len, m) := match insn with
                       | inl h => (2%Z, encdec_compressed_backwards h >>= execute)
                       | inr w => (4%Z, encdec_backwards w >>= execute)
                       end in
      let s1 := upd s (R_bitvector_32 nextPC) (add_vec_int pc len) in
      match run env s1 ws m with
      | Some (RETIRE_SUCCESS, s2, ws2) =>
          Some (upd s2 (R_bitvector_32 PC) (s2 (R_bitvector_32 nextPC)), ws2)
      | _ => None
      end
  end.

Fixpoint steps (n : nat) (code : code_t) (env : env_t) (s : regs) (ws : list wr)
  : option (regs * list wr) :=
  match n with
  | O => Some (s, ws)
  | S n' => match step code env s ws with
            | None => None
            | Some (s', ws') => steps n' code env s' ws'
            end
  end.
