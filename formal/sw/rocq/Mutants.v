(* formal/sw/rocq/Mutants.v: the tier-3 theorem's checks must reject a wrong binary.  Each mutant
   is hw_palette's code with one halfword changed; the same check (Palette.ok) is false for some
   index -- proved by computation, like the theorem itself. *)
From stdpp Require Import base list.
From stdpp.bitvector Require Import definitions.
Require Import SailStdpp.Base.
Require Import RV32.riscv_types RV32.riscv.
Require Import Swfv.Run Swfv.Code Swfv.Palette.

Definition mutate (l : list (Z * mword 16)) (a : Z) (h : mword 16) :=
  map (fun p => if Z.eqb p.1 a then (a, h) else p) l.

Definition ok_code (c : list (Z * mword 16)) (s0 : regs) (env : env_t) (i : Z) : bool :=
  match steps 6 (code_of c) env (at_call s0 i) [] with
  | Some (s, [w]) => wr_eqb w (the_write i) && Z.eqb (bv_unsigned (s (R_bitvector_32 PC))) (bv_unsigned RA)
  | _ => false
  end.

(* a mutant needs only ONE state where the check fails: a concrete one (every register at its
   type's default, every read answered with the default), which keeps vm_compute away from a
   symbolic trap handler *)
Definition z0 : regs := fun r => inhabitant.
Definition e0 : env_t := fun n _ => inhabitant.

(* the unmutated code passes this formulation too (it is Palette.ok) *)
Lemma ok_code_same : forall s0 env, forallb (ok_code code_hw_palette s0 env) (map Z.of_nat (seq 0 256)) = true.
Proof. intros. vm_compute. reflexivity. Qed.

(* c.slli a0,1 instead of 2: the wrong element (and outside the window for high indices) *)
Lemma shift1 : forallb (ok_code (mutate code_hw_palette 0x8000003A (Ox"0506")) z0 e0) (map Z.of_nat (seq 0 256)) = false.
Proof. vm_compute. reflexivity. Qed.
(* addi a5,a5,0x104 instead of 0x100: one entry off *)
Lemma offby1 : forallb (ok_code (mutate code_hw_palette 0x80000036 (Ox"1047")) z0 e0) (map Z.of_nat (seq 0 256)) = false.
Proof. vm_compute. reflexivity. Qed.
(* c.sh-like: c.sw replaced by c.lw (no write at all) *)
Lemma nowrite : forallb (ok_code (mutate code_hw_palette 0x8000003C (Ox"410C")) z0 e0) (map Z.of_nat (seq 0 256)) = false.
Proof. vm_compute. reflexivity. Qed.
(* an illegal instruction (0x0000) in place of c.add: a trap, so run gives None *)
Lemma illegal : forallb (ok_code (mutate code_hw_palette 0x80000038 (Ox"0000")) z0 e0) (map Z.of_nat (seq 0 256)) = false.
Proof. vm_compute. reflexivity. Qed.
