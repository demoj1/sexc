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

let resolve_import ~from_file rel =
  let base = Filename.dirname from_file in
  Filename.concat base rel

let extract_import_target = function
  | Raw.List [ Raw.Atom "%import"; Raw.Str p ] -> Some p
  | Raw.List [ Raw.Atom "%import"; Raw.Atom p ] -> Some p
  | _ -> None

let extract_module_name = function
  | Raw.List [ Raw.Atom "%module"; Raw.Atom name ] -> Some name
  | Raw.List (Raw.Atom "%module" :: _) -> fail "%module expects exactly one atom argument"
  | _ -> None

let strip_module_decl forms =
  let rec loop module_name acc = function
    | [] -> (module_name, List.rev acc)
    | form :: tl -> (
        match extract_module_name form with
        | None -> loop module_name (form :: acc) tl
        | Some name -> (
            match module_name with
            | None -> loop (Some name) acc tl
            | Some prev when String.equal prev name -> loop module_name acc tl
            | Some _ -> fail "Only one %module declaration is allowed per file"))
  in
  loop None [] forms

let qualify_name module_name name =
  if String.is_substring name ~substring:"/" || String.is_prefix name ~prefix:"%"
     || String.is_prefix name ~prefix:"$"
  then name
  else module_name ^ "/" ^ name

let rewrite_atom name_map atom =
  let map_name n = Option.value (Map.find name_map n) ~default:n in
  match Map.find name_map atom with
  | Some mapped -> mapped
  | None -> (
      if String.is_suffix atom ~suffix:"#" then
        let base = String.drop_suffix atom 1 in
        if Map.mem name_map base then map_name base ^ "#" else atom
      else
        match String.lsplit2 atom ~on:'/' with
        | Some (base, rest) when Map.mem name_map base -> map_name base ^ "/" ^ rest
        | _ -> atom)

let rec rewrite_type_like name_map raw =
  match raw with
  | Raw.Atom a -> Raw.Atom (rewrite_atom name_map a)
  | Raw.Str _ -> raw
  | Raw.List xs -> Raw.List (List.map xs ~f:(rewrite_type_like name_map))

let rewrite_params name_map = function
  | Raw.List groups ->
      let rewrite_group = function
        | Raw.List [] -> Raw.List []
        | Raw.List (ty :: names) -> Raw.List (rewrite_type_like name_map ty :: names)
        | other -> other
      in
      Raw.List (List.map groups ~f:rewrite_group)
  | other -> other

let rewrite_fields name_map fields =
  let rewrite_field = function
    | Raw.List [ ty; Raw.Atom name ] -> Raw.List [ rewrite_type_like name_map ty; Raw.Atom name ]
    | other -> rewrite_type_like name_map other
  in
  List.map fields ~f:rewrite_field

let rewrite_form name_map =
  let rec rw = function
    | Raw.Atom a -> Raw.Atom (rewrite_atom name_map a)
    | Raw.Str _ as s -> s
    | Raw.List (Raw.Atom "quote" :: _) as q -> q
    | Raw.List (Raw.Atom "quasiquote" :: _) as q -> q
    | Raw.List (Raw.Atom "%import" :: _ as xs) -> Raw.List xs
    | Raw.List (Raw.Atom "%module" :: _ as xs) -> Raw.List xs
    | Raw.List (Raw.Atom "%doc" :: Raw.Atom name :: props) ->
        Raw.List (Raw.Atom "%doc" :: Raw.Atom (rewrite_atom name_map name) :: List.map props ~f:rw)
    | Raw.List (Raw.Atom "defn" :: ret :: Raw.Atom name :: params :: body) ->
        Raw.List
          (Raw.Atom "defn" :: rewrite_type_like name_map ret
          :: Raw.Atom (rewrite_atom name_map name)
          :: rewrite_params name_map params
          :: List.map body ~f:rw)
    | Raw.List (Raw.Atom "%def-fn" :: ret :: Raw.Atom name :: params :: body :: []) ->
        Raw.List
          [ Raw.Atom "%def-fn";
            rewrite_type_like name_map ret;
            Raw.Atom (rewrite_atom name_map name);
            rewrite_params name_map params;
            rw body;
          ]
    | Raw.List (Raw.Atom "%decl-fn" :: ret :: Raw.Atom name :: params :: []) ->
        Raw.List
          [ Raw.Atom "%decl-fn";
            rewrite_type_like name_map ret;
            Raw.Atom (rewrite_atom name_map name);
            rewrite_params name_map params;
          ]
    | Raw.List (Raw.Atom "define" :: Raw.Atom name :: value :: []) ->
        Raw.List [ Raw.Atom "define"; Raw.Atom (rewrite_atom name_map name); rw value ]
    | Raw.List (Raw.Atom "%define" :: Raw.Atom name :: value :: []) ->
        Raw.List [ Raw.Atom "%define"; Raw.Atom (rewrite_atom name_map name); rw value ]
    | Raw.List (Raw.Atom "struct" :: Raw.Atom name :: items) ->
        let rec rewrite_struct_items phase acc = function
          | [] -> List.rev acc
          | Raw.Atom ":fields" :: tl -> rewrite_struct_items `Fields (Raw.Atom ":fields" :: acc) tl
          | Raw.Atom ":methods" :: tl -> rewrite_struct_items `Methods (Raw.Atom ":methods" :: acc) tl
          | item :: tl ->
              let item =
                match phase with
                | `Fields -> (
                    match item with
                    | Raw.List [ ty; Raw.Atom field ] -> Raw.List [ rewrite_type_like name_map ty; Raw.Atom field ]
                    | _ -> rw item)
                | `Methods -> rw item
                | `Unknown -> rw item
              in
              rewrite_struct_items phase (item :: acc) tl
        in
        Raw.List (Raw.Atom "struct" :: Raw.Atom (rewrite_atom name_map name) :: rewrite_struct_items `Unknown [] items)
    | Raw.List (Raw.Atom "union" :: Raw.Atom name :: fields) ->
        Raw.List (Raw.Atom "union" :: Raw.Atom (rewrite_atom name_map name) :: rewrite_fields name_map fields)
    | Raw.List (Raw.Atom "%typedef" :: ty :: Raw.Atom name :: []) ->
        Raw.List [ Raw.Atom "%typedef"; rewrite_type_like name_map ty; Raw.Atom (rewrite_atom name_map name) ]
    | Raw.List (Raw.Atom ("arrow" | "->" | "dot" | "." | "%arrow" | "%dot" as head) :: first :: fields) ->
        (* Field-access форма: рерайтим только первый аргумент (объект/указатель);
           остальные позиции — это имена полей, их трогать нельзя. *)
        Raw.List (Raw.Atom head :: rw first :: fields)
    | Raw.List xs -> Raw.List (List.map xs ~f:rw)
  in
  rw

let collect_module_defined_names forms =
  let add_name set name =
    if String.is_substring name ~substring:"/" then set else Set.add set name
  in
  let from_typedef_type = function
    | Raw.List (Raw.Atom "%enum" :: Raw.Atom enum_name :: []) -> Some enum_name
    | _ -> None
  in
  List.fold forms ~init:String.Set.empty ~f:(fun acc form ->
      match form with
      | Raw.List (Raw.Atom "defn" :: _ :: Raw.Atom name :: _) -> add_name acc name
      | Raw.List (Raw.Atom "%def-fn" :: _ :: Raw.Atom name :: _) -> add_name acc name
      | Raw.List (Raw.Atom "%decl-fn" :: _ :: Raw.Atom name :: _) -> add_name acc name
      | Raw.List (Raw.Atom "define" :: Raw.Atom name :: _) -> add_name acc name
      | Raw.List (Raw.Atom "%define" :: Raw.Atom name :: _) -> add_name acc name
      | Raw.List (Raw.Atom "struct" :: Raw.Atom name :: _) -> add_name acc name
      | Raw.List (Raw.Atom "union" :: Raw.Atom name :: _) -> add_name acc name
      | Raw.List (Raw.Atom "%typedef" :: ty :: Raw.Atom name :: []) ->
          let acc = add_name acc name in
          Option.value_map (from_typedef_type ty) ~default:acc ~f:(fun n -> add_name acc n)
      | _ -> acc)

let apply_module_namespace module_name forms =
  let names = collect_module_defined_names forms in
  if Set.is_empty names then forms
  else
    let name_map =
      Set.fold names ~init:String.Map.empty ~f:(fun acc name ->
          Map.set acc ~key:name ~data:(qualify_name module_name name))
    in
    List.map forms ~f:(rewrite_form name_map)

(* Загружает forms из path, гарантируя что каждый файл попадёт в результат
   ровно один раз — даже если он импортируется из нескольких мест. visited
   глобально аккумулирует уже загруженные пути; sibling-ветки видят
   друг друга через возвращаемый visited. *)
let rec load_forms_from_file ~visited ~use_prelude path =
  let abs = path in
  if Set.mem visited abs then (visited, [])
  else
    let visited = Set.add visited abs in
    let source = In_channel.read_all abs in
    let forms = Reader.parse_many ~file:abs source in
    let module_name, forms = strip_module_decl forms in
    let forms =
      match module_name with
      | None -> forms
      | Some name -> apply_module_namespace name forms
    in
    let visited, collected =
      List.fold forms ~init:(visited, []) ~f:(fun (v, acc) form ->
          match extract_import_target form with
          | Some rel ->
              if use_prelude && is_prelude_import_target rel then (v, acc)
              else
                let imported = resolve_import ~from_file:abs rel in
                let v, more = load_forms_from_file ~visited:v ~use_prelude imported in
                (v, acc @ more)
          | None -> (v, acc @ [ form ]))
    in
    (visited, collected)

let rec load_graph_from_file ~visited ~use_prelude path =
  (* Import graph flow:
     current file -> split imports/non-imports -> recursively load imports -> return (self + imported). *)
  let abs = path in
  if Set.mem visited abs then failf "Cyclic %%import detected: %s" abs;
  let visited = Set.add visited abs in
  let source = In_channel.read_all abs in
  let forms = Reader.parse_many ~file:abs source in
  let module_name, forms = strip_module_decl forms in
  let forms =
    match module_name with
    | None -> forms
    | Some name -> apply_module_namespace name forms
  in
  let imports, own_forms =
    List.partition_map forms ~f:(fun form ->
        match extract_import_target form with
        | Some rel ->
            if use_prelude && is_prelude_import_target rel then First ""
            else First rel
        | None -> Second form)
  in
  let visited, imported_graph =
    List.fold imports ~init:(visited, []) ~f:(fun (v, acc) rel ->
        if String.is_empty rel then (v, acc)
        else
          let imported = resolve_import ~from_file:abs rel in
          let v, g = load_graph_from_file ~visited:v ~use_prelude imported in
          (v, acc @ g))
  in
  (visited, (abs, own_forms) :: imported_graph)

let load_graph ~use_prelude path =
  let _, graph = load_graph_from_file ~visited:String.Set.empty ~use_prelude path in
  graph

let load_std_graph () =
  let stdlib_dir = resolve_stdlib_dir () in
  let core_path = Filename.concat stdlib_dir "core.sexc" in
  load_graph ~use_prelude:false core_path

let load_prelude_forms () =
  let stdlib_dir = resolve_stdlib_dir () in
  let core_path = Filename.concat stdlib_dir "core.sexc" in
  let _, forms = load_forms_from_file ~visited:String.Set.empty ~use_prelude:false core_path in
  forms

let compile_forms ?(use_prelude = true) forms =
  (* Core compile pipeline (in order):
     1) normalize %module names
     2) prepend prelude (optional)
     3) drop %doc metadata (docs are handled out-of-band)
     4) collect+expand macros
     5) flatten top-level splice forms
     6) parse frontend AST
     7) emit C text. *)
  let module_name, forms = strip_module_decl forms in
  let forms =
    match module_name with
    | None -> forms
    | Some name -> apply_module_namespace name forms
  in
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
  let _, forms = load_forms_from_file ~visited:String.Set.empty ~use_prelude path in
  compile_forms ~use_prelude forms
