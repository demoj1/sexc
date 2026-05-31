(*
   Raw syntax tree produced by the reader.

   Extension point:
   - Add constructors here only when a new reader-level surface syntax is needed.
   - Most language features should be implemented after this stage (macro/frontend).

   Data flow:
   Reader output -> [Raw.t]
   Macro expansion transforms [Raw.t] -> [Raw.t]
   Frontend consumes final expanded [Raw.t] -> typed AST
*)

type t =
  | Atom of string
  | Str of string
  | List of t list
