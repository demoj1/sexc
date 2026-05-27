open Core
open Common

let resolve_import ~from_file rel =
  let base = Filename.dirname from_file in
  Filename.concat base rel

let extract_import_target = function
  | Raw.List [ Raw.Atom "%import"; Raw.Str p ] -> Some p
  | Raw.List [ Raw.Atom "%import"; Raw.Atom p ] -> Some p
  | _ -> None

let rec load_forms_from_file ~visited path =
  let abs = path in
  if Set.mem visited abs then failf "Cyclic %%import detected: %s" abs;
  let visited = Set.add visited abs in
  let source = In_channel.read_all abs in
  let forms = Reader.parse_many ~file:abs source in
  List.concat_map forms ~f:(fun form ->
      match extract_import_target form with
      | Some rel ->
          let imported = resolve_import ~from_file:abs rel in
          load_forms_from_file ~visited imported
      | None -> [ form ])

let compile_forms forms =
  let rec flatten_top_forms xs = List.concat_map xs ~f:flatten_top_form
  and flatten_top_form = function
    | Raw.List (Raw.Atom "%top-level-splice" :: inner) -> flatten_top_forms inner
    | other -> [ other ]
  in
  let mctx, non_macro = Macro.collect forms in
  let expanded = Macro.expand_program mctx non_macro in
  expanded
  |> flatten_top_forms
  |> List.map ~f:Frontend.parse_top
  |> List.map ~f:Codegen_c.emit_top
  |> String.concat ~sep:"\n\n"

let compile_source source =
  let forms = Reader.parse_many ~file:"<memory>" source in
  compile_forms forms

let compile_file path =
  let forms = load_forms_from_file ~visited:String.Set.empty path in
  compile_forms forms
