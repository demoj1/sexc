open Core
open Common

(*
   Whole-program analysis over the EXPANDED %-IR (post macro-expansion, after
   namespace qualification and splice hoisting, before codegen).

   Generic core
   ------------
   [propagate_over_calls] is a reusable fixpoint: each function carries a
   set-valued fact; facts flow along call edges and a fact is discharged where
   a caller "covers" it (here: an enclosing region binds it). Any "property
   that propagates over the call graph" — purity, may-longjmp, required
   capabilities — can reuse the same engine; only the per-function step changes.

   First client
   ------------
   [check_unbound_slots]: dynamic variables (earmuffed [*name*], bound by
   [with] which leaves a [(%dyn-scope *name* …)] marker) must be bound on every
   path that reads them. "Reads [*v*]" is a fact that flows up the call graph
   until a [%dyn-scope] discharges it; if it reaches [main] undischarged, the
   slot can be NULL at runtime — we report it at compile time instead.
*)

(* What makes a variable a "dynamic slot" is NOT its name (names are arbitrary —
   a plain local could be earmuffed yet never bound), but the fact that some
   [with] BINDS it, leaving a [(%dyn-scope VAR TY …)] marker. So slots are derived
   from the markers, not from an earmuff naming convention; an arbitrarily-named
   local that no `with` ever binds is simply not a slot. *)

(* Builtin scalar type names. A dynamic slot of scalar type is SAFE unbound (its
   thread-local default is 0 — a real value, not a crash), so it is exempt from
   the must-bind check; only non-scalar slots (pointers, __typeof__ of a libc
   handle, structs…) can NULL-deref and are checked. *)
let scalar_types =
  String.Set.of_list
    [ "void"; "char"; "short"; "int"; "long"; "float"; "double"; "signed"; "unsigned"
    ; "_Bool"; "bool"; "size_t"; "ssize_t"; "ptrdiff_t"; "intptr_t"; "uintptr_t"
    ; "int8_t"; "int16_t"; "int32_t"; "int64_t"
    ; "uint8_t"; "uint16_t"; "uint32_t"; "uint64_t" ]

let rec is_scalar_type = function
  | Raw.Atom (a, _) -> Set.mem scalar_types a
  | Raw.List ([ Raw.Atom (("%const" | "%volatile" | "%restrict"), _); inner ], _) -> is_scalar_type inner
  (* multi-word builtin like (unsigned long) — all words are scalar keywords *)
  | Raw.List (xs, _) ->
      (not (List.is_empty xs))
      && List.for_all xs ~f:(function Raw.Atom (a, _) -> Set.mem scalar_types a | _ -> false)
  | Raw.Str (_, _) -> false

(* The slots we actually check: variables bound by some [with] (i.e. appearing
   in a [(%dyn-scope VAR TY …)] marker) whose type is non-scalar (a pointer that
   can NULL-deref). Membership is by binding, NOT by name — a plain local called
   [*foo*] that no [with] ever binds is not here, and scalar slots are excluded
   (their unbound default 0 is a value, not a crash). *)
let tracked_slots forms =
  let acc = ref String.Set.empty in
  let add v = acc := Set.add !acc v in
  let rec go raw =
    match raw with
    (* `with` binding: tracked only if non-scalar (scalar default 0 ≠ crash) *)
    | Raw.List ((Raw.Atom ("%dyn-scope", _) :: Raw.Atom (v, _) :: ty :: rest), _) ->
        if not (is_scalar_type ty) then add v;
        List.iter rest ~f:go
    (* explicit `slot*` requirement: tracked unconditionally — the developer
       said "I require it", so we check it regardless of type *)
    | Raw.List ((Raw.Atom ("%dyn-require", _) :: slots), _) ->
        List.iter slots ~f:(function Raw.Atom (v, _) -> add v | _ -> ())
    | Raw.List (xs, _) -> List.iter xs ~f:go
    | _ -> ()
  in
  List.iter forms ~f:go;
  !acc

(* A top-level function definition, unwrapping %static/%inline/%extern. *)
let rec fn_def = function
  | Raw.List ((Raw.Atom (("%static" | "%inline" | "%extern"), _) :: [ inner ]), _) -> fn_def inner
  | Raw.List ([ Raw.Atom ("%def-fn", _); _ret; Raw.Atom (name, _); _params; body ], _) -> Some (name, body)
  | _ -> None

(* ── per-function fact step ────────────────────────────────────────────────
   Walk a body computing the set of dynamic slots it REQUIRES from its caller:
   a read of [*v*] not bound by an enclosing [%dyn-scope], plus the requirements
   of every function it calls (minus what is bound around the call site).
   [needs_of] is the current estimate for callees (closed by the fixpoint).
   When [report] is set (the entry function), each uncovered read/call is
   collected as a diagnostic at its span. *)
let walk_requirements ~fnset ~tracked ~needs_of ~report body =
  let needs = ref String.Set.empty in
  let errors = ref [] in
  let flag ?from v span =
    needs := Set.add !needs v;
    if report then begin
      let msg =
        match from with
        | Some callee ->
            Printf.sprintf
              "%s requires the dynamic slot %s, which is unbound here — provide it before the call with (with %s <value> ...)"
              callee v v
        | None ->
            Printf.sprintf
              "dynamic slot %s is unbound here (NULL at runtime) — bind it with (with %s <value> ...) or assign it first"
              v v
      in
      let item =
        match span with
        | Some sp -> { err_diag = Some { phase = "analysis"; message = msg; span = sp }; err_message = msg; err_hint = None }
        | None -> { err_diag = None; err_message = msg; err_hint = None }
      in
      errors := item :: !errors
    end
  in
  let rec go ~bound raw =
    match raw with
    | Raw.Atom (a, sp) -> if Set.mem tracked a && not (Set.mem bound a) then flag a sp
    | Raw.Str (_, _) -> ()
    (* a `with` region: its variable is bound for the wrapped form (skip the
       leading TY element of the marker) *)
    | Raw.List ((Raw.Atom ("%dyn-scope", _) :: Raw.Atom (v, _) :: _ty :: inner), _) ->
        List.iter inner ~f:(go ~bound:(Set.add bound v))
    (* explicit `slot*` declaration: each listed slot not already bound here is a
       requirement of this function (propagated to callers like a read) *)
    | Raw.List ((Raw.Atom ("%dyn-require", _) :: slots), _) ->
        List.iter slots ~f:(function
          | Raw.Atom (v, sp) -> if not (Set.mem bound v) then flag v sp
          | _ -> ())
    (* a statement sequence: walk left-to-right so that assigning a slot
       ([%set V …], V an atom) BINDS it for the rest of the block — filling a
       slot by hand is a valid way to provide it, just like `with`. *)
    | Raw.List ((Raw.Atom ("%block", _) :: stmts), _) ->
        ignore
          (List.fold stmts ~init:bound ~f:(fun bnd stmt ->
               match stmt with
               | Raw.List ([ Raw.Atom ("%set", _); Raw.Atom (v, _); value ], _) ->
                   go ~bound:bnd value;
                   Set.add bnd v
               | _ ->
                   go ~bound:bnd stmt;
                   bnd))
    (* a call to a user function: propagate its requirements not bound here *)
    | Raw.List ((Raw.Atom (callee, csp) :: args), _) when Set.mem fnset callee ->
        Set.iter (needs_of callee) ~f:(fun v -> if not (Set.mem bound v) then flag ~from:callee v csp);
        List.iter args ~f:(go ~bound)
    | Raw.List (xs, _) -> List.iter xs ~f:(go ~bound)
  in
  go ~bound:String.Set.empty body;
  (!needs, List.rev !errors)

(* ── generic fixpoint over the call graph ──────────────────────────────────
   Closes a set-valued per-function fact under call-edge propagation. [step]
   recomputes one function's fact given the current estimate for all others;
   monotone growth + finite universe ⇒ termination (handles recursion/cycles). *)
let propagate_over_calls (defs : (string * Raw.t) list) ~step : string -> String.Set.t =
  let tbl = Hashtbl.create (module String) in
  List.iter defs ~f:(fun (n, _) -> Hashtbl.set tbl ~key:n ~data:String.Set.empty);
  let get n = Option.value (Hashtbl.find tbl n) ~default:String.Set.empty in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter defs ~f:(fun (name, body) ->
        let next = step ~needs_of:get name body in
        if not (Set.equal next (get name)) then begin
          Hashtbl.set tbl ~key:name ~data:next;
          changed := true
        end)
  done;
  get

(* ── client: unbound dynamic-slot check ────────────────────────────────────
   Returns diagnostics for slots that can reach `main` unbound. No `main`
   (a library TU) ⇒ requirements are the external caller's responsibility,
   so nothing is reported. *)
let check_unbound_slots (forms : Raw.t list) : error_item list =
  let defs = List.filter_map forms ~f:fn_def in
  let fnset = String.Set.of_list (List.map defs ~f:fst) in
  let tracked = tracked_slots forms in
  if Set.is_empty tracked then []
  else begin
    let needs_of =
      propagate_over_calls defs ~step:(fun ~needs_of _name body ->
          fst (walk_requirements ~fnset ~tracked ~needs_of ~report:false body))
    in
    match List.Assoc.find defs ~equal:String.equal "main" with
    | None -> []
    | Some body -> snd (walk_requirements ~fnset ~tracked ~needs_of ~report:true body)
  end

(* Run all whole-program checks; returns accumulated diagnostics (possibly
   empty). Wired into [compile_forms] after expansion, before codegen. *)
let check_program (forms : Raw.t list) : error_item list =
  check_unbound_slots forms
