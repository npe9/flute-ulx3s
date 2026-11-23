(* formal/sw/rocq/Palette.v: tier 3, the first binary-level theorem (notes/sw-verification-plan.md).

   hw_palette (sw/game2d/board.c: REG (0xC0010400 + 4 * index) = rgb), as compiled into
   lantern.elf (Code.v, generated from the ELF's bytes):
       lui a5,0x30004 ; addi a5,a5,256 ; c.add a0,a5 ; c.slli a0,2 ; c.sw a1,0(a0) ; c.jr ra
   The address is 4 * (index + 0x30004100), which reaches 0xC0010400 + 4 * index only modulo
   2^32 -- a fact about the binary that the C-level proof (tier 2) cannot see.

   Theorem: for EVERY index 0..255, in ANY machine state (every register the code does not
   depend on is arbitrary: s0), in ANY device / memory environment, the six instructions
   retire on the Sail RV32 model without a trap, make exactly one memory write -- 4 bytes at
   0xC0010400 + 4 * index, of a1's value -- and return to ra.

   Fixed in the statement (not yet general): privilege M with mstatus = 0x1800 (MPRV clear: the
   title runs in M-mode and never sets it); the 8 PMP entries off (their reset value: the title
   never writes them); the data a1 = 0x00ABCDEF and ra = 0x80001000.  The model's configuration
   (support/riscv_extras.v) is Flute's: RV32IMAC+F, 8 PMP entries of grain 10.  The
   proof is by computation (vm_compute); with a1 or ra symbolic the model's store and jump
   paths branch on them (alignment checks, byte packing) and vm_compute's normal form blows
   up, so generalising them needs symbolic execution (stepwise rewriting, or coq-sail's Hoare
   logic) -- the next step, recorded in the plan. *)

From stdpp Require Import base list.
From stdpp.bitvector Require Import definitions.
Require Import SailStdpp.Base SailStdpp.ConcurrencyInterface.
Require Import RV32.riscv_types RV32.riscv.
Require Import Swfv.Run Swfv.Code.
Import Defs.

Definition code_of (l : list (Z * mword 16)) : code_t := fun a =>
  match list_find (fun p => p.1 = a) l with Some (_, (_, h)) => Some h | None => None end.

Definition D : mword 32 := Ox"00ABCDEF".
Definition RA : mword 32 := Ox"80001000".

(* the state at the call: pc at hw_palette, a0 = index, a1 = data, ra; everything else s0 *)
Definition at_call (s0 : regs) (i : Z) : regs :=
  upd (upd (upd (upd (upd (upd (upd (upd s0 (R_bitvector_32 PC) (Ox"80000030"))
     (R_bitvector_32 x10) (Z_to_bv 32 i)) (R_bitvector_32 x11) D)
     (R_bitvector_32 x1) RA) (R_Privilege cur_privilege) Machine)
     (R_bitvector_32 mstatus) (Ox"00001800"))
     (R_vector_64_bitvector_8 pmpcfg_n) inhabitant)          (* every PMP entry off (reset) *)
     (R_vector_64_bitvector_32 pmpaddr_n) inhabitant.

Definition the_write (i : Z) : wr := {| w_pa := 0xC0010400 + 4 * i; w_n := 4; w_v := bv_unsigned D |}.

Definition wr_eqb (a b : wr) : bool :=
  Z.eqb (w_pa a) (w_pa b) && N.eqb (w_n a) (w_n b) && Z.eqb (w_v a) (w_v b).

Definition ok (s0 : regs) (env : env_t) (i : Z) : bool :=
  match steps 6 (code_of code_hw_palette) env (at_call s0 i) [] with
  | Some (s, [w]) => wr_eqb w (the_write i) && Z.eqb (bv_unsigned (s (R_bitvector_32 PC))) (bv_unsigned RA)
  | _ => false
  end.

Lemma hw_palette_all_indices : forall (s0 : regs) (env : env_t),
  forallb (ok s0 env) (map Z.of_nat (seq 0 256)) = true.
Proof. intros s0 env. vm_compute. reflexivity. Qed.

(* the statement in the usual form *)
Theorem hw_palette_spec : forall (s0 : regs) (env : env_t) (i : Z), 0 <= i < 256 ->
  exists s, steps 6 (code_of code_hw_palette) env (at_call s0 i) [] = Some (s, [the_write i])
            /\ bv_unsigned (s (R_bitvector_32 PC)) = bv_unsigned RA.
Proof.
  intros s0 env i Hi.
  pose proof (hw_palette_all_indices s0 env) as H.
  rewrite forallb_forall in H.
  assert (Hin : In i (map Z.of_nat (seq 0 256))).
  { apply in_map_iff. exists (Z.to_nat i). split; [lia |]. apply in_seq. lia. }
  specialize (H i Hin). unfold ok in H.
  destruct (steps 6 _ _ _ _) as [[s ws]|]; [|discriminate].
  destruct ws as [|w [|]]; try discriminate.
  apply andb_prop in H as [Hw Hpc].
  unfold wr_eqb in Hw. apply andb_prop in Hw as [Hw Hv]. apply andb_prop in Hw as [Hpa Hn].
  apply Z.eqb_eq in Hpa, Hv. apply N.eqb_eq in Hn. apply Z.eqb_eq in Hpc.
  exists s. split; [|exact Hpc].
  destruct w as [pa n v]; unfold the_write in *; simpl in *; subst; reflexivity.
Qed.

Print Assumptions hw_palette_spec.
