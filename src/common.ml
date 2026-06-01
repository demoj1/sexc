open Core

(*
   Shared errors/diagnostics utilities used across all phases.

   Extension point:
   - Add new diagnostic helpers here when introducing a new compiler phase.
   - Keep phase names stable because they are user-visible in error output.

   Data flow:
   phase code
     -> [fail]/[failf] for plain errors OR [fail_diag] for rich diagnostics
     -> exception value
     -> caught in CLI
     -> [render_diagnostic] converts span offsets to line/column + caret output
*)

(* Глобальный quiet-флаг. По умолчанию компилятор логирует стадии пайплайна
   на stderr — длительные сборки (большие %import-графы или тяжёлый gcc -O2)
   иначе выглядят зависшими. Включается через --quiet или SEXC_QUIET=1, когда
   логи не нужны (например в редакторских интеграциях). *)
let quiet : bool ref = ref false

(* Эмитить ли `#line N "file"` директивы в генерируемый C, чтобы ошибки gcc
   указывали на исходный .sexc, а не на временный .c. По умолчанию вкл;
   отключается флагом --no-line (например в snapshot-тестах, где golden-вывод
   не должен зависеть от номеров строк). *)
let emit_line_directives : bool ref = ref true

let logf fmt =
  if !quiet then Printf.ksprintf (fun _ -> ()) fmt
  else Printf.ksprintf (fun s -> prerr_endline ("[sexc] " ^ s)) fmt

(* Human-readable длительность: ns → "850µs" / "12.4ms" / "1.23s" / "1m 32s".
   Используется для тайминга стадий пайплайна. *)
let format_span (span : Time_ns.Span.t) : string =
  let ns = Time_ns.Span.to_int_ns span in
  if ns < 1_000 then Printf.sprintf "%dns" ns
  else if ns < 1_000_000 then Printf.sprintf "%.0fµs" (Float.of_int ns /. 1_000.0)
  else if ns < 1_000_000_000 then Printf.sprintf "%.1fms" (Float.of_int ns /. 1_000_000.0)
  else if ns < 60 * 1_000_000_000 then Printf.sprintf "%.2fs" (Float.of_int ns /. 1_000_000_000.0)
  else
    let total_s = ns / 1_000_000_000 in
    Printf.sprintf "%dm %ds" (total_s / 60) (total_s mod 60)

let now_ns () = Time_ns.now ()

let since (t0 : Time_ns.t) : string = format_span (Time_ns.diff (now_ns ()) t0)

(* Время стадии-обёртки: лог пишется после завершения с тэгом и elapsed. *)
let with_stage (name : string) (f : unit -> 'a) : 'a =
  let t0 = now_ns () in
  let result = f () in
  logf "%s — %s" name (since t0);
  result

(* Три категории ошибок:
   - Sexc_cli_error  — невалидный argv / неизвестная команда. Усложная для пользователя
                       только в этой ветке имеет смысл показывать usage().
   - Sexc_error      — компиляционная ошибка без локации (legacy). Печатается как
                       одна строка "error: msg" без портянки usage'а.
   - Sexc_diagnostic — компиляционная ошибка с file:line:col + caret-сниппетом. *)
exception Sexc_cli_error of string

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

(* Несколько накопленных ошибок компиляции (multi-error). Каждый элемент несёт
   опц. macro-chain head, захваченный в момент ошибки — чтобы CLI мог показать
   doc-hint для нужной формы (глобальный current_macro_chain отражает только
   последнюю ошибку, поэтому фиксируем per-item). *)
type error_item = {
  err_diag : diagnostic option;  (* None → locationless (см. err_message) *)
  err_message : string;          (* для locationless Sexc_error *)
  err_hint : string option;      (* имя активной формы для doc-hint *)
}

exception Sexc_errors of error_item list

let fail msg = raise (Sexc_error msg)

let failf fmt = Printf.ksprintf (fun s -> raise (Sexc_error s)) fmt

let cli_fail msg = raise (Sexc_cli_error msg)

let cli_failf fmt = Printf.ksprintf (fun s -> raise (Sexc_cli_error s)) fmt

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

(* Бросает Sexc_diagnostic с готовым span'ом. Если span = None — fall back на
   обычный Sexc_error, который потом будет promoted до top-form контекста. *)
let fail_at ~phase (span : span option) (message : string) =
  match span with
  | Some sp -> raise (Sexc_diagnostic { phase; message; span = sp })
  | None -> raise (Sexc_error message)

let failf_at ~phase span fmt =
  Printf.ksprintf (fun s -> fail_at ~phase span s) fmt

(* Span текущей top-level формы. Устанавливается компилятором перед per-form
   обработкой (macro expand → frontend → codegen) и используется, чтобы
   "promote" любую bare Sexc_error из глубоких фаз в Sexc_diagnostic с
   привязкой к месту вызова в исходнике. *)
let current_top_span : span option ref = ref None

(* Span формы, которую СЕЙЧАС вычисляет $-evaluator (macro.eval_expr).
   Обновляется на каждом рекурсивном шаге, поэтому в момент ошибки содержит
   span самой глубокой обрабатываемой подформы. На нормальном возврате
   восстанавливается; на исключении остаётся "грязным", что нам и нужно —
   promote подхватит самую точную локацию. Имеет приоритет над
   current_top_span. *)
let current_eval_span : span option ref = ref None

let with_top_span (sp : span) (f : unit -> 'a) : 'a =
  let prev = !current_top_span in
  current_top_span := Some sp;
  current_eval_span := None;
  Exn.protect ~f ~finally:(fun () -> current_top_span := prev)

(* Конвертирует bare Sexc_error в Sexc_diagnostic. Приоритет локации:
   current_eval_span (самая глубокая вычисляемая форма) → current_top_span
   (top-level форма). Без span'а — пробрасывает исходное исключение. *)
let promote_error_to_diagnostic ~phase f =
  try f () with
  | Sexc_error msg as e ->
      let span =
        match !current_eval_span with
        | Some _ as s -> s
        | None -> !current_top_span
      in
      (match span with
       | None -> raise e
       | Some sp -> raise (Sexc_diagnostic { phase; message = msg; span = sp }))

(* Стек активных surface-форм (макросы из %defmacro, известные intrinsics).
   Используется CLI-обработчиком чтобы вывести hint с docs+example при ошибке.
   Голова списка — самый глубокий (вложенный) контекст. *)
let current_macro_chain : string list ref = ref []

(* Push/pop стек чейна, но на ИСКЛЮЧЕНИИ оставляем чейн "грязным" — это нужно
   чтобы catch-handler в CLI увидел самую глубокую активную форму и смог
   распечатать hint с её документацией. Process всё равно exit'ится после
   ошибки, так что leak не проблема. *)
let with_macro_context (name : string) (f : unit -> 'a) : 'a =
  current_macro_chain := name :: !current_macro_chain;
  let r = f () in
  current_macro_chain := List.tl !current_macro_chain |> Option.value ~default:[];
  r
