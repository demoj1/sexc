open Core
open Common

(*
   Reader: source text -> Raw.t forms (with embedded spans).

   Responsibilities:
   - tokenization/parsing of atoms, strings, lists
   - reader sugars: quote/quasiquote/unquote/splice
   - precise reader diagnostics (file/line/col)
   - attach Common.span to every produced Raw.t node so later phases can
     report errors with deep granularity

   Data flow:
   text buffer
     -> cursor state ([state])
     -> token-level parsers (parse_atom/parse_string/parse_list)
     -> Raw.t tree where every node carries its source span

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

(* Legacy type kept for callers that want offsets without going through Raw.t.
   Internally the reader works on Raw.t directly with spans baked in. *)
type located =
  | LAtom of string * int
  | LStr of string * int
  | LList of located list * int

let create ~file src = { file; src; len = String.length src; i = 0 }

let at_end st = st.i >= st.len

let peek st = if at_end st then None else Some st.src.[st.i]

let bump st =
  if not (at_end st) then st.i <- st.i + 1

let error st msg =
  fail_diag ~phase:"reader" ~file:st.file ~source:st.src ~start_off:st.i msg

let mk_span st ~start_off : Common.span =
  { file = st.file; source = st.src; start_off; end_off = st.i }

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

(* Парсит содержимое строкового литерала. start — offset открывающей кавычки. *)
let parse_string st ~start =
  let buf = Buffer.create 32 in
  let rec loop () =
    match peek st with
    | None -> error st "unterminated string literal"
    | Some '"' ->
        bump st;
        Raw.Str (Buffer.contents buf, Some (mk_span st ~start_off:start))
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
  let name = String.sub st.src ~pos:start ~len:(st.i - start) in
  Raw.Atom (name, Some (mk_span st ~start_off:start))

let rec parse_one st =
  skip_ws_and_comments st;
  let start = st.i in
  match peek st with
  | None -> error st "unexpected end of input"
  | Some '\'' ->
      bump st;
      let body = parse_one st in
      let sp = Some (mk_span st ~start_off:start) in
      Raw.List ([ Raw.Atom ("quote", sp); body ], sp)
  | Some '`' ->
      bump st;
      let body = parse_one st in
      let sp = Some (mk_span st ~start_off:start) in
      Raw.List ([ Raw.Atom ("quasiquote", sp); body ], sp)
  | Some ',' ->
      bump st;
      let tag =
        match peek st with
        | Some '@' ->
            bump st;
            "splice"
        | _ -> "unquote"
      in
      let body = parse_one st in
      let sp = Some (mk_span st ~start_off:start) in
      Raw.List ([ Raw.Atom (tag, sp); body ], sp)
  | Some '(' ->
      bump st;
      parse_list st ~start
  | Some ')' -> error st "unexpected ')'"
  | Some '"' ->
      bump st;
      parse_string st ~start
  (* Char literal, emacs-style: `?c`, `?.`, `?\n`, `?\\`, `?\'`, `?\s` (space).
     Desugars to (%raw "'c'") — an inline C char literal — so no frontend/codegen
     changes are needed. `?` only leads a token here; a trailing `?` (predicates
     like nil?) is consumed by parse_atom, never reaching this case. *)
  | Some '?' ->
      bump st;
      let c_literal =
        match peek st with
        | None -> error st "unfinished char literal after '?'"
        | Some '\\' ->
            bump st;
            (match peek st with
             | None -> error st "unfinished char escape after '?\\'"
             | Some 's' -> bump st; "' '"                       (* emacs \s = space *)
             | Some e -> bump st; Printf.sprintf "'\\%c'" e)    (* \n \t \\ \' ... → '\X' *)
        | Some '\'' -> bump st; "'\\''"                         (* ?' → apostrophe char *)
        | Some c -> bump st; Printf.sprintf "'%c'" c
      in
      let sp = Some (mk_span st ~start_off:start) in
      Raw.List ([ Raw.Atom ("%raw", sp); Raw.Str (c_literal, sp) ], sp)
  | Some _ -> parse_atom st

and parse_list st ~start =
  let rec loop acc =
    skip_ws_and_comments st;
    match peek st with
    | None -> error st "unterminated list"
    | Some ')' ->
        bump st;
        Raw.List (List.rev acc, Some (mk_span st ~start_off:start))
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

(* Совместимость: legacy callers (например cache/index.ml для xref) хотят
   offset на каждый узел БЕЗ полного span. Просто конвертим Raw.t → located,
   беря start_off из span'а. *)
let loc_of = function
  | LAtom (_, off) | LStr (_, off) | LList (_, off) -> off

let span_off (sp : Common.span option) =
  match sp with Some s -> s.start_off | None -> 0

let rec raw_to_located : Raw.t -> located = function
  | Raw.Atom (a, sp) -> LAtom (a, span_off sp)
  | Raw.Str (s, sp) -> LStr (s, span_off sp)
  | Raw.List (xs, sp) -> LList (List.map xs ~f:raw_to_located, span_off sp)

let parse_many_loc ~file src =
  parse_many ~file src |> List.map ~f:raw_to_located

let to_raw (l : located) : Raw.t =
  let rec convert = function
    | LAtom (a, off) ->
        let sp : Common.span =
          { file = ""; source = ""; start_off = off; end_off = off }
        in
        Raw.Atom (a, Some sp)
    | LStr (s, off) ->
        let sp : Common.span =
          { file = ""; source = ""; start_off = off; end_off = off }
        in
        Raw.Str (s, Some sp)
    | LList (xs, off) ->
        let sp : Common.span =
          { file = ""; source = ""; start_off = off; end_off = off }
        in
        Raw.List (List.map xs ~f:convert, Some sp)
  in
  convert l
