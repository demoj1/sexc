open Core

type item_kind =
  | Macro
  | Function
  | Type

type item = {
  name : string;
  kind : item_kind;
  signature : string option;
  doc : string option;
  example : string option;
}

type doc_meta = {
  signature : string option;
  doc : string option;
  example : string option;
  internal : bool;
}

let kind_to_string = function
  | Macro -> "macro"
  | Function -> "function"
  | Type -> "type"

let flatten_top_forms forms =
  let rec flatten_one = function
    | Raw.List (Raw.Atom "%top-level-splice" :: inner) -> List.concat_map inner ~f:flatten_one
    | other -> [ other ]
  in
  List.concat_map forms ~f:flatten_one

let collect_function_names forms =
  List.fold forms ~init:String.Set.empty ~f:(fun acc form ->
      match form with
      | Raw.List (Raw.Atom "%def-fn" :: _ret :: Raw.Atom name :: _)
      | Raw.List (Raw.Atom "%decl-fn" :: _ret :: Raw.Atom name :: _) -> Set.add acc name
      | _ -> acc)

let collect_type_names forms =
  List.fold forms ~init:String.Set.empty ~f:(fun acc form ->
      match form with
      | Raw.List (Raw.Atom "%typedef" :: _ty :: Raw.Atom name :: []) -> Set.add acc name
      | _ -> acc)

let collect_function_signatures forms =
  let rec render = function
    | Raw.Atom a -> a
    | Raw.Str s -> "\"" ^ String.escaped s ^ "\""
    | Raw.List xs -> "(" ^ String.concat ~sep:" " (List.map xs ~f:render) ^ ")"
  in
  let render_fn_sig ret name params =
    Printf.sprintf "(%s %s) -> %s" name (render params) (render ret)
  in
  List.fold forms ~init:String.Map.empty ~f:(fun acc form ->
      match form with
      | Raw.List (Raw.Atom "%def-fn" :: ret :: Raw.Atom name :: params :: _ :: []) ->
          let sig_text = render_fn_sig ret name params in
          Map.update acc name ~f:(function
            | Some existing -> existing
            | None -> sig_text)
      | Raw.List (Raw.Atom "%decl-fn" :: ret :: Raw.Atom name :: params :: []) ->
          let sig_text = render_fn_sig ret name params in
          Map.update acc name ~f:(function
            | Some existing -> existing
            | None -> sig_text)
      | _ -> acc)

let extract_module_name = function
  | Raw.List [ Raw.Atom "%module"; Raw.Atom name ] -> Some name
  | _ -> None

let current_file_module_name forms =
  List.find_map forms ~f:extract_module_name

let rec render_raw = function
  | Raw.Atom a -> a
  | Raw.Str s -> "\"" ^ String.escaped s ^ "\""
  | Raw.List xs -> "(" ^ String.concat ~sep:" " (List.map xs ~f:render_raw) ^ ")"

let render_value = function
  | Raw.Atom a -> a
  | Raw.Str s -> s
  | other -> render_raw other

let is_truthy_atom = function
  | "t" | "true" | "1" -> true
  | _ -> false

let collect_defmacro_signatures forms =
  List.fold forms ~init:String.Map.empty ~f:(fun acc form ->
      match form with
      | Raw.List (Raw.Atom "%defmacro" :: Raw.Atom name :: Raw.List params :: _body) ->
          let sig_text = render_raw (Raw.List (Raw.Atom name :: params)) in
          Map.update acc name ~f:(function
            | Some existing -> existing
            | None -> sig_text)
      | _ -> acc)

let collect_doc_meta forms =
  let macro_sigs = collect_defmacro_signatures forms in
  let rec parse_props sig_opt doc example internal = function
    | [] -> { signature = sig_opt; doc; example; internal }
    | Raw.Atom ":sig" :: value :: tl -> parse_props (Some (render_raw value)) doc example internal tl
    | Raw.Atom ":doc" :: value :: tl ->
        let doc = Option.first_some doc (Some (render_value value)) in
        parse_props sig_opt doc example internal tl
    | Raw.Atom ":example" :: value :: tl ->
        let example = Option.first_some example (Some (render_value value)) in
        parse_props sig_opt doc example internal tl
    | Raw.Atom ":internal" :: Raw.Atom flag :: tl ->
        parse_props sig_opt doc example (is_truthy_atom flag || internal) tl
    | _ :: tl -> parse_props sig_opt doc example internal tl
  in
  List.fold forms ~init:String.Map.empty ~f:(fun acc form ->
      match form with
      | Raw.List (Raw.Atom "%doc" :: Raw.Atom name :: props) ->
          let parsed = parse_props None None None false props in
          let parsed =
            match parsed.signature with
            | Some _ -> parsed
            | None -> { parsed with signature = Map.find macro_sigs name }
          in
          Map.update acc name ~f:(function
            | Some existing -> existing
            | None -> parsed)
      | _ -> acc)

let collect_macro_names (ctx : Macro.ctx) =
  Map.keys ctx.defs |> String.Set.of_list

let load_input_forms ~use_prelude input_path =
  if String.equal input_path "-" then
    let source = In_channel.input_all In_channel.stdin in
    Reader.parse_many ~file:"<stdin>" source
  else Compiler.load_forms_from_file ~visited:String.Set.empty ~use_prelude input_path

let load_current_file_raw input_path =
  if String.equal input_path "-" then []
  else
    let source = In_channel.read_all input_path in
    Reader.parse_many ~file:input_path source

let add_module_local_aliases_map map module_name =
  Map.fold map ~init:map ~f:(fun ~key:name ~data:item acc ->
      let prefix = module_name ^ "/" in
      if String.is_prefix name ~prefix then
        let short = String.drop_prefix name (String.length prefix) in
        Map.update acc short ~f:(function
            | Some existing -> existing
            | None -> { item with name = short })
      else acc)

let add_type_hash_aliases_map map =
  Map.fold map ~init:map ~f:(fun ~key:name ~data:item acc ->
      match item.kind with
      | Type ->
          let key = name ^ "#" in
          Map.update acc key ~f:(function
            | Some existing -> existing
            | None -> { item with name = key })
      | Macro | Function -> acc)

let add_items names kind docs_by_name fn_sigs map =
  Set.fold names ~init:map ~f:(fun acc name ->
      Map.update acc name ~f:(function
        | Some existing -> existing
        | None ->
            let meta = Map.find docs_by_name name in
            let signature =
              match Option.bind meta ~f:(fun m -> m.signature) with
              | Some s -> Some s
              | None -> (
                  match kind with
                  | Function -> Map.find fn_sigs name
                  | Type -> None
                  | Macro -> None)
            in
            {
              name;
              kind;
              signature;
              doc = Option.bind meta ~f:(fun m -> m.doc);
              example = Option.bind meta ~f:(fun m -> m.example);
            }))

let json_escape s =
  let b = Buffer.create (String.length s + 8) in
  String.iter s ~f:(fun ch ->
      match ch with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\b' -> Buffer.add_string b "\\b"
      | '\012' -> Buffer.add_string b "\\f"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | ch when Char.to_int ch < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.to_int ch))
      | ch -> Buffer.add_char b ch);
  Buffer.contents b

let items_to_json items =
  let json_field key value = Printf.sprintf "\"%s\":\"%s\"" key (json_escape value) in
  let json_optional key = function
    | Some v -> [ json_field key v ]
    | None -> []
  in
  let render_item { name; kind; signature; doc; example } =
    let fields =
      [ json_field "name" name; json_field "kind" (kind_to_string kind) ]
      @ json_optional "signature" signature
      @ json_optional "doc" doc
      @ json_optional "example" example
    in
    "{" ^ String.concat ~sep:"," fields ^ "}"
  in
  "[" ^ String.concat ~sep:"," (List.map items ~f:render_item) ^ "]"

let sort_items items = List.sort items ~compare:(fun a b -> String.compare a.name b.name)

let names_of_items items = List.map items ~f:(fun x -> x.name)

let complete_items ~use_prelude ~input_path ~prefix =
  let prelude_forms = if use_prelude then Compiler.load_prelude_forms () else [] in
  let input_forms = load_input_forms ~use_prelude input_path in
  let current_file_raw = load_current_file_raw input_path in
  let module_name = current_file_module_name current_file_raw in
  let ctx, non_macro = Macro.collect (prelude_forms @ input_forms) in
  let docs_by_name = collect_doc_meta (prelude_forms @ input_forms) in
  let macro_names = collect_macro_names ctx in
  let internal_names =
    Map.fold docs_by_name ~init:String.Set.empty ~f:(fun ~key:name ~data:meta acc ->
        if meta.internal then Set.add acc name else acc)
  in
  let expanded = Macro.expand_program ctx non_macro |> flatten_top_forms in
  let function_names = collect_function_names expanded in
  let type_names = collect_type_names expanded in
  let function_signatures = collect_function_signatures expanded in
  let names =
    Set.union macro_names function_names
    |> Set.union type_names
    |> fun all -> Set.diff all internal_names
  in
  let macro_names = Set.inter macro_names names in
  let function_names = Set.inter function_names names in
  let type_names = Set.inter type_names names in
  let items =
    String.Map.empty
    |> add_items macro_names Macro docs_by_name function_signatures
    |> add_items function_names Function docs_by_name function_signatures
    |> add_items type_names Type docs_by_name function_signatures
    |> add_type_hash_aliases_map
  in
  let items =
    match module_name with
    | None -> items
    | Some m -> add_module_local_aliases_map items m
  in
  Map.to_alist items
  |> List.filter_map ~f:(fun (name, item) -> if String.is_prefix name ~prefix then Some item else None)
  |> sort_items

let complete ~use_prelude ~input_path ~prefix =
  complete_items ~use_prelude ~input_path ~prefix |> names_of_items
