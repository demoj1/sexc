open Core

exception Sexc_error of string

type span = {
  file : string;
  source : string;
  start_off : int;
  end_off : int;
}

type diagnostic = {
  phase : string;
  message : string;
  span : span;
}

exception Sexc_diagnostic of diagnostic

let fail msg = raise (Sexc_error msg)

let failf fmt = Printf.ksprintf (fun s -> raise (Sexc_error s)) fmt

let clamp x ~min_v ~max_v = Int.max min_v (Int.min max_v x)

let line_bounds source off =
  let len = String.length source in
  let off = clamp off ~min_v:0 ~max_v:len in
  let rec find_start i =
    if i <= 0 then 0
    else if Char.equal source.[i - 1] '\n' then i
    else find_start (i - 1)
  in
  let rec find_end i =
    if i >= len then len
    else if Char.equal source.[i] '\n' then i
    else find_end (i + 1)
  in
  let line_start = find_start off in
  let line_end = find_end off in
  (line_start, line_end)

let line_col source off =
  let len = String.length source in
  let off = clamp off ~min_v:0 ~max_v:len in
  let rec loop idx line col =
    if idx >= off then (line, col)
    else if Char.equal source.[idx] '\n' then loop (idx + 1) (line + 1) 1
    else loop (idx + 1) line (col + 1)
  in
  loop 0 1 1

let render_diagnostic d =
  let len = String.length d.span.source in
  let off =
    if d.span.start_off >= len && len > 0 then len - 1
    else d.span.start_off
  in
  let line, col = line_col d.span.source off in
  let line_start, line_end = line_bounds d.span.source off in
  let line_text =
    if line_start >= line_end then ""
    else String.sub d.span.source ~pos:line_start ~len:(line_end - line_start)
  in
  let caret_col = Int.max 1 col in
  let caret = String.make (caret_col - 1) ' ' ^ "^" in
  String.concat
    ~sep:"\n"
    [
      Printf.sprintf "%s:%d:%d: error[%s]: %s" d.span.file line col d.phase d.message;
      line_text;
      caret;
    ]

let fail_diag ~phase ~file ~source ~start_off ?(end_off = start_off) message =
  raise (Sexc_diagnostic { phase; message; span = { file; source; start_off; end_off } })
