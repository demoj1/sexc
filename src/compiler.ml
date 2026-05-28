open Core
open Common

(*
   High-level compile pipeline orchestration.

   Responsibilities:
   - load source file + %import graph
   - prepend embedded prelude (unless disabled)
   - run macro expansion
   - parse frontend AST
   - run C code generation

   Extension point:
   - Add/insert new compiler passes in [compile_forms] between expansion and codegen.
   - Keep import/prelude behavior centralized here.
*)

let default_stdlib_dir = "/usr/local/include/sexc/std"

let stdlib_env_var = "SEXC_STDLIB_DIR"

let is_prelude_import_target rel =
  match Stdlib.Filename.basename rel with
  | "core.sexc" | "c-interop.sexc" | "meta.sexc" -> true
  | _ -> false

let file_exists path =
  try Stdlib.Sys.file_exists path with
  | _ -> false

let stdlib_core_exists dir = file_exists (Filename.concat dir "core.sexc")

let candidate_stdlib_dirs () =
  let from_env = Option.to_list (Sys.getenv stdlib_env_var) in
  let from_exe =
    let exe = Stdlib.Sys.executable_name in
    let bin_dir = Filename.dirname exe in
    let prefix_dir = Filename.dirname bin_dir in
    [ Filename.concat prefix_dir "include/sexc/std" ]
  in
  let from_defaults = [ default_stdlib_dir; Filename.concat (Stdlib.Sys.getcwd ()) "std" ] in
  from_env @ from_exe @ from_defaults

let resolve_stdlib_dir () =
  let rec find = function
    | [] ->
        failf
          "Could not locate SexC stdlib (missing core.sexc). Tried SEXC_STDLIB_DIR, %s, and ./std. Set %s to your stdlib directory."
          default_stdlib_dir stdlib_env_var
    | dir :: tl -> if stdlib_core_exists dir then dir else find tl
  in
  find (candidate_stdlib_dirs ())

let resolve_import ~from_file rel =
  let base = Filename.dirname from_file in
  Filename.concat base rel

let extract_import_target = function
  | Raw.List [ Raw.Atom "%import"; Raw.Str p ] -> Some p
  | Raw.List [ Raw.Atom "%import"; Raw.Atom p ] -> Some p
  | _ -> None

let rec load_forms_from_file ~visited ~use_prelude path =
  let abs = path in
  if Set.mem visited abs then failf "Cyclic %%import detected: %s" abs;
  let visited = Set.add visited abs in
  let source = In_channel.read_all abs in
  let forms = Reader.parse_many ~file:abs source in
  List.concat_map forms ~f:(fun form ->
      match extract_import_target form with
      | Some rel ->
          if use_prelude && is_prelude_import_target rel then []
          else
            let imported = resolve_import ~from_file:abs rel in
            load_forms_from_file ~visited ~use_prelude imported
      | None -> [ form ])

let load_prelude_forms () =
  let stdlib_dir = resolve_stdlib_dir () in
  let core_path = Filename.concat stdlib_dir "core.sexc" in
  load_forms_from_file ~visited:String.Set.empty ~use_prelude:false core_path

let compile_forms ?(use_prelude = true) forms =
  let is_doc_form = function
    | Raw.List (Raw.Atom "%doc" :: _) -> true
    | _ -> false
  in
  let rec flatten_top_forms xs = List.concat_map xs ~f:flatten_top_form
  and flatten_top_form = function
    | Raw.List (Raw.Atom "%top-level-splice" :: inner) -> flatten_top_forms inner
    | other -> [ other ]
  in
  let prelude_forms = if use_prelude then load_prelude_forms () else [] in
  let non_doc = List.filter (prelude_forms @ forms) ~f:(fun f -> not (is_doc_form f)) in
  let mctx, non_macro = Macro.collect non_doc in
  let expanded = Macro.expand_program mctx non_macro in
  expanded
  |> flatten_top_forms
  |> List.map ~f:Frontend.parse_top
  |> List.map ~f:Codegen_c.emit_top
  |> String.concat ~sep:"\n\n"

let compile_source ?(use_prelude = true) source =
  let forms = Reader.parse_many ~file:"<memory>" source in
  compile_forms ~use_prelude forms

let compile_file ?(use_prelude = true) path =
  let forms = load_forms_from_file ~visited:String.Set.empty ~use_prelude path in
  compile_forms ~use_prelude forms
