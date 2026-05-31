(*
   Raw syntax tree produced by the reader.

   Extension point:
   - Add constructors here only when a new reader-level surface syntax is needed.
   - Most language features should be implemented after this stage (macro/frontend).

   Data flow:
   Reader output -> [Raw.t]
   Macro expansion transforms [Raw.t] -> [Raw.t]
   Frontend consumes final expanded [Raw.t] -> typed AST

   Each constructor carries an optional [Common.span] — set by the reader for
   forms parsed from a real file, set by the macro phase to the call-site of
   the enclosing macro for synthesized forms, and [None] for forms generated
   without any meaningful source location. Pattern matches that don't care
   about positions match the tuple shape `Atom (x, _)` etc.
*)

type t =
  | Atom of string * Common.span option
  | Str of string * Common.span option
  | List of t list * Common.span option

(* Smart constructors — default span = None. Pass ?span explicitly when the
   producer knows where the synthesized node lives. *)
let atom ?span s = Atom (s, span)

let str ?span s = Str (s, span)

let list_ ?span xs = List (xs, span)

let span_of = function
  | Atom (_, s) | Str (_, s) | List (_, s) -> s

(* Заменяет span этого узла. Используется когда производитель уже знает место
   (например macro.apply наследует call-site span на синтезированные узлы). *)
let with_span sp = function
  | Atom (s, _) -> Atom (s, sp)
  | Str (s, _) -> Str (s, sp)
  | List (xs, _) -> List (xs, sp)
