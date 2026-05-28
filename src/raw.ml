(*
   Raw syntax tree produced by the reader.

   Extension point:
   - Add constructors here only when a new reader-level surface syntax is needed.
   - Most language features should be implemented after this stage (macro/frontend).
*)

type t =
  | Atom of string
  | Str of string
  | List of t list
