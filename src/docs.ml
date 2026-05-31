open Core
open Common

(*
   Documentation metadata extraction and markdown rendering.

   Responsibilities:
   - read %doc forms from project files and stdlib files
   - enrich docs with %defmacro signatures when :sig is omitted
   - render docs for CLI commands: show-doc, dump-docs, dump-stdlib-docs

   Data flow:
   - [load_project_graph]/[load_std_graph] collect (file, forms) pairs.
   - [entries_from_file] converts forms -> doc entries for one file.
   - [collect_entries] merges entries across files.
   - [show_doc]/[dump_docs_for_input]/[dump_stdlib_docs] format and emit outputs.
*)

type kind =
  | Surface
  | Intrinsic
  | Meta

type entry = {
  name : string;
  kind : kind;
  signature : string option;
  docs : string list;
  examples : string list;
  internal : bool;
  since : string option;
  deprecated : string option;
  see : string list;
  source_file : string;
}

type partial_doc = {
  p_name : string;
  p_sig : string option;
  p_docs : string list;
  p_examples : string list;
  p_internal : bool;
  p_since : string option;
  p_deprecated : string option;
  p_see : string list;
}

let default_stdlib_dir = "/usr/local/include/sexc/std"

let stdlib_env_var = "SEXC_STDLIB_DIR"

let kind_of_name name =
  if String.equal name "%" then Surface
  else if String.is_prefix name ~prefix:"%" then Intrinsic
  else if String.is_prefix name ~prefix:"$" then Meta
  else Surface

let kind_to_string = function
  | Surface -> "surface"
  | Intrinsic -> "intrinsic"
  | Meta -> "meta"

let is_doc_form = function
  | Raw.List ((Raw.Atom ("%doc", _) :: _), _) -> true
  | _ -> false

let is_keyword_atom = function
  | Raw.Atom (a, _) -> String.is_prefix a ~prefix:":"
  | _ -> false

let rec render_raw = function
  | Raw.Atom (a, _) -> a
  | Raw.Str (s, _) -> "\"" ^ String.escaped s ^ "\""
  | Raw.List (xs, _) -> "(" ^ String.concat ~sep:" " (List.map xs ~f:render_raw) ^ ")"

let render_value = function
  | Raw.Atom (a, _) -> a
  | Raw.Str (s, _) -> s
  | other -> render_raw other

let parse_bool name key = function
  | Raw.Atom ("t", _) | Raw.Atom ("true", _) | Raw.Atom ("1", _) -> true
  | Raw.Atom ("nil", _) | Raw.Atom ("false", _) | Raw.Atom ("0", _) -> false
  | _ -> failf "%%doc key %s for %s expects boolean atom (t/nil)" key name

let parse_doc_props name props =
  let rec consume_see acc = function
    | x :: tl when not (is_keyword_atom x) -> consume_see (render_value x :: acc) tl
    | rest -> (List.rev acc, rest)
  in
  let rec loop sig_opt docs examples internal since deprecated see = function
    | [] ->
        {
          p_name = name;
          p_sig = sig_opt;
          p_docs = List.rev docs;
          p_examples = List.rev examples;
          p_internal = internal;
          p_since = since;
          p_deprecated = deprecated;
          p_see = List.rev see;
        }
    | Raw.Atom (":sig", _) :: value :: tl ->
        loop (Some (render_raw value)) docs examples internal since deprecated see tl
    | Raw.Atom (":doc", _) :: value :: tl ->
        loop sig_opt (render_value value :: docs) examples internal since deprecated see tl
    | Raw.Atom (":example", _) :: value :: tl ->
        loop sig_opt docs (render_value value :: examples) internal since deprecated see tl
    | Raw.Atom (":internal", _) :: value :: tl ->
        loop sig_opt docs examples (parse_bool name ":internal" value) since deprecated see tl
    | Raw.Atom (":since", _) :: value :: tl ->
        loop sig_opt docs examples internal (Some (render_value value)) deprecated see tl
    | Raw.Atom (":deprecated", _) :: value :: tl ->
        loop sig_opt docs examples internal since (Some (render_value value)) see tl
    | Raw.Atom (":see", _) :: tl ->
        let seen, rest = consume_see [] tl in
        loop sig_opt docs examples internal since deprecated (List.rev_append seen see) rest
    | Raw.Atom (key, _) :: _ when String.is_prefix key ~prefix:":" ->
        failf "Unknown %%doc key '%s' for %s" key name
    | _ -> failf "Invalid %%doc payload for %s" name
  in
  loop None [] [] false None None [] props

let extract_import_target = function
  | Raw.List ([ Raw.Atom ("%import", _); Raw.Str (p, _) ], _) -> Some p
  | Raw.List ([ Raw.Atom ("%import", _); Raw.Atom (p, _) ], _) -> Some p
  | _ -> None

let resolve_import ~from_file rel =
  let base = Filename.dirname from_file in
  Filename.concat base rel

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
  let from_defaults = [ Filename.concat (Stdlib.Sys.getcwd ()) "std"; default_stdlib_dir ] in
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

let rec load_graph_from_file ~visited path =
  if Set.mem visited path then (visited, [])
  else
    let visited = Set.add visited path in
    let source = In_channel.read_all path in
    let forms = Reader.parse_many ~file:path source in
    let visited, imported =
      List.fold forms ~init:(visited, []) ~f:(fun (v, acc) form ->
          match extract_import_target form with
          | None -> (v, acc)
          | Some rel ->
              let imported_path = resolve_import ~from_file:path rel in
              let v, docs = load_graph_from_file ~visited:v imported_path in
              (v, acc @ docs))
    in
    (visited, (path, forms) :: imported)

let load_std_graph () =
  let stdlib_dir = resolve_stdlib_dir () in
  let core = Filename.concat stdlib_dir "core.sexc" in
  let visited, graph = load_graph_from_file ~visited:String.Set.empty core in
  let ocaml_api = Filename.concat stdlib_dir "ocaml-api.sexc" in
  if file_exists ocaml_api then
    let _, extra = load_graph_from_file ~visited ocaml_api in
    graph @ extra
  else graph

let load_project_graph ~use_prelude input_path =
  let _, user_graph = load_graph_from_file ~visited:String.Set.empty input_path in
  if use_prelude then
    let std_graph = load_std_graph () in
    let seen =
      List.fold user_graph ~init:String.Set.empty ~f:(fun acc (path, _) -> Set.add acc path)
    in
    user_graph
    @ List.filter std_graph ~f:(fun (path, _) -> not (Set.mem seen path))
  else user_graph

let defmacro_signature = function
  | Raw.List ((Raw.Atom ("%defmacro", _) :: Raw.Atom (name, _) :: Raw.List (params, _) :: _body), _) ->
      Some (name, render_raw (Raw.List ((Raw.Atom (name, None) :: params), None)))
  | _ -> None

let parse_doc_form = function
  | Raw.List ((Raw.Atom ("%doc", _) :: Raw.Atom (name, _) :: props), _) -> Some (parse_doc_props name props)
  | _ -> None

let entries_from_file ~source_file forms =
  let macro_sigs =
    List.filter_map forms ~f:defmacro_signature
    |> String.Map.of_alist_reduce ~f:(fun first _ -> first)
  in
  let docs = List.filter_map forms ~f:parse_doc_form in
  List.map docs ~f:(fun d ->
      let signature =
        match d.p_sig with
        | Some s -> Some s
        | None -> Map.find macro_sigs d.p_name
      in
      if List.is_empty d.p_docs then failf "%%doc for %s must include at least one :doc" d.p_name;
      { name = d.p_name;
        kind = kind_of_name d.p_name;
        signature;
        docs = d.p_docs;
        examples = d.p_examples;
        internal = d.p_internal;
        since = d.p_since;
        deprecated = d.p_deprecated;
        see = d.p_see;
        source_file;
      })

let collect_entries graph =
  List.concat_map graph ~f:(fun (path, forms) -> entries_from_file ~source_file:path forms)

let show_doc ?input_path ~use_prelude name =
  let graph =
    match input_path with
    | Some path -> load_project_graph ~use_prelude path
    | None -> load_std_graph ()
  in
  collect_entries graph |> List.filter ~f:(fun e -> String.equal e.name name && not e.internal)

let render_entry_text e =
  let lines =
    [ Some ("Name: " ^ e.name);
      Some ("Kind: " ^ kind_to_string e.kind);
      Option.map e.signature ~f:(fun s -> "Signature: " ^ s);
      Some ("Source: " ^ e.source_file);
      Option.map e.since ~f:(fun s -> "Since: " ^ s);
      Option.map e.deprecated ~f:(fun s -> "Deprecated: " ^ s);
      if List.is_empty e.see then None else Some ("See: " ^ String.concat ~sep:", " e.see);
    ]
    |> List.filter_opt
  in
  let docs = List.map e.docs ~f:(fun d -> "- " ^ d) in
  let examples = List.map e.examples ~f:(fun x -> "- `" ^ x ^ "`") in
  let parts =
    lines
    @ [ "Doc:" ]
    @ docs
    @ (if List.is_empty examples then [] else [ "Examples:" ] @ examples)
  in
  String.concat ~sep:"\n" parts

let render_entries_text entries = String.concat ~sep:"\n\n" (List.map entries ~f:render_entry_text)

let rec ensure_dir path =
  if String.is_empty path || String.equal path "." || String.equal path "/" then ()
  else if file_exists path then ()
  else (
    ensure_dir (Filename.dirname path);
    let status = Stdlib.Sys.command ("mkdir -p " ^ Filename.quote path) in
    if status <> 0 then failf "Failed to create directory: %s" path)

let relative_doc_path ~stdlib_dir source_file =
  let cwd = Stdlib.Sys.getcwd () in
  let with_ext_md rel =
    Option.value_map (String.chop_suffix rel ~suffix:".sexc") ~default:(rel ^ ".md") ~f:(fun base -> base ^ ".md")
  in
  let normalize s = String.substr_replace_all s ~pattern:"//" ~with_:"/" in
  let std_prefix = normalize (stdlib_dir ^ "/") in
  let cwd_prefix = normalize (cwd ^ "/") in
  let source_norm = normalize source_file in
  if String.is_prefix source_norm ~prefix:std_prefix then
    with_ext_md ("std/" ^ String.drop_prefix source_norm (String.length std_prefix))
  else if String.is_prefix source_norm ~prefix:cwd_prefix then
    with_ext_md (String.drop_prefix source_norm (String.length cwd_prefix))
  else with_ext_md (Filename.basename source_norm)

let write_file_docs ~out_dir ~stdlib_dir (source_file, forms) =
  let entries = entries_from_file ~source_file forms |> List.filter ~f:(fun e -> not e.internal) in
  let rel = relative_doc_path ~stdlib_dir source_file in
  let out_path = Filename.concat out_dir rel in
  ensure_dir (Filename.dirname out_path);
  let title = "# " ^ source_file in
  let body =
    if List.is_empty entries then "\n_No documented symbols found._\n"
    else "\n" ^ String.concat ~sep:"\n\n---\n\n" (List.map entries ~f:render_entry_text) ^ "\n"
  in
  Out_channel.write_all out_path ~data:(title ^ body);
  (rel, List.map entries ~f:(fun e -> e.name))

let dump_graph_docs ~out_dir graph =
  let stdlib_dir = resolve_stdlib_dir () in
  ensure_dir out_dir;
  let per_file = List.map graph ~f:(write_file_docs ~out_dir ~stdlib_dir) in
  let index_lines =
    "# SexC documentation index"
    :: List.concat_map per_file ~f:(fun (rel, names) ->
           let header = "- " ^ rel in
           if List.is_empty names then [ header ^ " (no docs)" ]
           else [ header ^ " => " ^ String.concat ~sep:", " names ])
  in
  Out_channel.write_all (Filename.concat out_dir "index.md") ~data:(String.concat ~sep:"\n" index_lines ^ "\n")

let dump_docs_for_input ~use_prelude ~input_path ~out_dir =
  let graph = load_project_graph ~use_prelude input_path in
  dump_graph_docs ~out_dir graph

let dump_stdlib_docs ~out_dir =
  let graph = load_std_graph () in
  dump_graph_docs ~out_dir graph
