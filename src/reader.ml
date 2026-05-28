open Core
open Common

(*
   Reader: source text -> Raw.t forms.

   Responsibilities:
   - tokenization/parsing of atoms, strings, lists
   - reader sugars: quote/quasiquote/unquote/splice
   - precise reader diagnostics (file/line/col)

   Extension point:
   - Add new reader sugar in [parse_one] and update [is_atom_delim] when needed.
   - Keep this phase syntax-only; no macro/frontend semantics here.
*)

type state = {
  file : string;
  src : string;
  len : int;
  mutable i : int;
}

let create ~file src = { file; src; len = String.length src; i = 0 }

let at_end st = st.i >= st.len

let peek st = if at_end st then None else Some st.src.[st.i]

let bump st =
  if not (at_end st) then st.i <- st.i + 1

let error st msg =
  fail_diag ~phase:"reader" ~file:st.file ~source:st.src ~start_off:st.i msg

let is_ws = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let rec skip_ws_and_comments st =
  match peek st with
  | None -> ()
  | Some c when is_ws c ->
      bump st;
      skip_ws_and_comments st
  | Some ';' ->
      while not (at_end st) && Char.(st.src.[st.i] <> '\n') do
        bump st
      done;
      skip_ws_and_comments st
  | Some _ -> ()

let parse_escape st =
  match peek st with
  | None -> error st "unfinished escape sequence"
  | Some 'n' ->
      bump st;
      '\n'
  | Some 'r' ->
      bump st;
      '\r'
  | Some 't' ->
      bump st;
      '\t'
  | Some '\\' ->
      bump st;
      '\\'
  | Some '"' ->
      bump st;
      '"'
  | Some '0' ->
      bump st;
      '\000'
  | Some c ->
      bump st;
      c

let parse_string st =
  let buf = Buffer.create 32 in
  let rec loop () =
    match peek st with
    | None -> error st "unterminated string literal"
    | Some '"' ->
        bump st;
        Raw.Str (Buffer.contents buf)
    | Some '\\' ->
        bump st;
        Buffer.add_char buf (parse_escape st);
        loop ()
    | Some c ->
        bump st;
        Buffer.add_char buf c;
        loop ()
  in
  loop ()

let is_atom_delim = function
  | '(' | ')' | '"' | ';' | '\'' | '`' | ',' | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let parse_atom st =
  let start = st.i in
  while not (at_end st) && not (is_atom_delim st.src.[st.i]) do
    bump st
  done;
  if st.i = start then error st "expected atom";
  Raw.Atom (String.sub st.src ~pos:start ~len:(st.i - start))

let rec parse_one st =
  skip_ws_and_comments st;
  match peek st with
  | None -> error st "unexpected end of input"
  | Some '\'' ->
      bump st;
      Raw.List [ Raw.Atom "quote"; parse_one st ]
  | Some '`' ->
      bump st;
      Raw.List [ Raw.Atom "quasiquote"; parse_one st ]
  | Some ',' ->
      bump st;
      let tag =
        match peek st with
        | Some '@' ->
            bump st;
            "splice"
        | _ -> "unquote"
      in
      Raw.List [ Raw.Atom tag; parse_one st ]
  | Some '(' ->
      bump st;
      parse_list st
  | Some ')' -> error st "unexpected ')'"
  | Some '"' ->
      bump st;
      parse_string st
  | Some _ -> parse_atom st

and parse_list st =
  let rec loop acc =
    skip_ws_and_comments st;
    match peek st with
    | None -> error st "unterminated list"
    | Some ')' ->
        bump st;
        Raw.List (List.rev acc)
    | Some _ ->
        let item = parse_one st in
        loop (item :: acc)
  in
  loop []

let parse_many ~file src =
  let st = create ~file src in
  let rec loop acc =
    skip_ws_and_comments st;
    if at_end st then List.rev acc
    else
      let item = parse_one st in
      loop (item :: acc)
  in
  loop []
