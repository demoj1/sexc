open Core

(*
   Symbol index builder/query layer used by docs, completion, and xref.

   Responsibilities:
   - parse files (with reader locations) and extract symbol metadata
   - merge %doc metadata into concrete symbol definitions
   - serve query APIs: [find_by_name], [complete], JSON serialization
   - cooperate with [Cache] for incremental per-file indexing

   Data flow:
   - [files_for_input]/[files_for_stdlib] choose files for current command.
   - [symbols_for_files] gets fresh entries from [Cache] or rebuilds via [index_file].
   - [index_file] walks reader forms and emits [Cache.symbol] values.
   - query functions filter/sort these symbols for CLI consumers.
*)

type symbol = Cache.symbol

let id_counter = ref 0

let fresh_id () =
  let id = !id_counter in
  id_counter := id + 1;
  id

let qualify module_name name =
  match module_name with
  | None -> name
  | Some m ->
      if String.is_prefix name ~prefix:(m ^ "/") then name else m ^ "/" ^ name

let short_name name =
  match String.rsplit2 name ~on:'/' with
  | Some (_, tail) -> tail
  | None -> name

let line_col source off = Common.line_col source off

let rec render_raw = function
  | Raw.Atom (a, _) -> a
  | Raw.Str (s, _) -> "\"" ^ String.escaped s ^ "\""
  | Raw.List (xs, _) -> "(" ^ String.concat ~sep:" " (List.map xs ~f:render_raw) ^ ")"

type doc_meta = {
  signature : string option;
  doc : string option;
  example : string option;
  internal : bool;
}

let parse_doc_meta props =
  let rec loop signature doc example internal = function
    | [] -> { signature; doc; example; internal }
    | Raw.Atom (":sig", _) :: v :: tl -> loop (Some (render_raw v)) doc example internal tl
    | Raw.Atom (":doc", _) :: v :: tl ->
        let d = Option.first_some doc (Some (match v with Raw.Str (s, _) | Raw.Atom (s, _) -> s | _ -> render_raw v)) in
        loop signature d example internal tl
    | Raw.Atom (":example", _) :: v :: tl ->
        let e = Option.first_some example (Some (match v with Raw.Str (s, _) | Raw.Atom (s, _) -> s | _ -> render_raw v)) in
        loop signature doc e internal tl
    | Raw.Atom (":internal", _) :: Raw.Atom (v, _) :: tl ->
        loop signature doc example
          (internal || List.mem [ "t"; "true"; "1" ] v ~equal:String.equal)
          tl
    | _ :: tl -> loop signature doc example internal tl
  in
  loop None None None false props

let module_name_of_loc_forms forms =
  List.find_map forms ~f:(function
      | Reader.LList ([ Reader.LAtom ("%module", _); Reader.LAtom (m, _) ], _) -> Some m
      | _ -> None)

let symbol_kind_of_name name =
  if String.is_prefix name ~prefix:"%" then "intr"
  else if String.is_prefix name ~prefix:"$" then "macro"
  else "surface"

let make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind ~name ?signature ?doc ?example ?(internal = false)
    ?scope ?ty () =
  let line, col = line_col source off in
  {
    Cache.id = fresh_id ();
    name;
    short_name = short_name name;
    module_name;
    kind;
    file;
    line;
    col;
    signature;
    doc;
    example;
    internal;
    scope;
    ty;
    file_md5;
  }

let rec parse_decl_bindings module_name current_scope = function
  | [] -> []
  | Reader.LList ([ ty; Reader.LAtom (name, noff) ], boff) :: _ :: tl ->
      let fq = qualify module_name name in
      let ty_s = render_raw (Reader.to_raw ty) in
      let line_off = (if noff >= 0 then noff else boff) in
      let one = (`Decl (fq, ty_s, line_off, current_scope)) in
      one :: parse_decl_bindings module_name current_scope tl
  | _ :: tl -> parse_decl_bindings module_name current_scope tl

let index_file file =
  (* One-file indexing pipeline:
     source -> located reader forms -> symbol/doc maps -> merged symbol list. *)
  let source = In_channel.read_all file in
  let file_md5 = Cache.file_md5 file in
  let forms = Reader.parse_many_loc ~file source in
  let module_name = module_name_of_loc_forms forms in
  let docs = ref String.Map.empty in
  let add_doc name d = docs := Map.update !docs name ~f:(function Some old -> old | None -> d) in
  let symbols = ref [] in
  let add_symbol s = symbols := s :: !symbols in
  let rec walk ?current_scope ?owner_type lraw =
    match lraw with
    | Reader.LAtom _ | Reader.LStr _ -> ()
    | Reader.LList (items, off) -> (
        match items with
        | Reader.LAtom ("%doc", _) :: Reader.LAtom (name, _) :: props ->
            let fq = qualify module_name name in
            let d = parse_doc_meta (List.map props ~f:Reader.to_raw) in
            add_doc fq d
        | Reader.LAtom ("defn", _) :: ret :: Reader.LAtom (name, _) :: params :: _body ->
            let fq =
              match owner_type with
              | Some t -> qualify module_name (t ^ "/" ^ name)
              | None -> qualify module_name name
            in
            let ret_s = render_raw (Reader.to_raw ret) in
            let params_s = render_raw (Reader.to_raw params) in
            let sig_s = Printf.sprintf "(%s %s) -> %s" fq params_s ret_s in
            add_symbol
              (make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind:"function" ~name:fq ~signature:sig_s ?scope:current_scope ())
        | Reader.LAtom ("%def-fn", _) :: ret :: Reader.LAtom (name, _) :: params :: _ ->
            let fq = qualify module_name name in
            let ret_s = render_raw (Reader.to_raw ret) in
            let params_s = render_raw (Reader.to_raw params) in
            let sig_s = Printf.sprintf "(%s %s) -> %s" fq params_s ret_s in
            add_symbol
              (make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind:"function" ~name:fq ~signature:sig_s ?scope:current_scope ())
        | Reader.LAtom ("%decl-fn", _) :: ret :: Reader.LAtom (name, _) :: params :: _ ->
            let fq = qualify module_name name in
            let ret_s = render_raw (Reader.to_raw ret) in
            let params_s = render_raw (Reader.to_raw params) in
            let sig_s = Printf.sprintf "(%s %s) -> %s" fq params_s ret_s in
            add_symbol
              (make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind:"function" ~name:fq ~signature:sig_s ?scope:current_scope ())
        | Reader.LAtom ("%defmacro", _) :: Reader.LAtom (name, _) :: Reader.LList (params, _) :: _ ->
            let fq = qualify module_name name in
            let sig_s = render_raw (Raw.List ((Raw.Atom (fq, None) :: List.map params ~f:Reader.to_raw), None)) in
            add_symbol (make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind:"macro" ~name:fq ~signature:sig_s ?scope:current_scope ())
        | Reader.LAtom ("define", _) :: Reader.LAtom (name, _) :: _
        | Reader.LAtom ("%define", _) :: Reader.LAtom (name, _) :: _ ->
            let fq = qualify module_name name in
            add_symbol (make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind:"define" ~name:fq ?scope:current_scope ())
        | Reader.LAtom ("struct", _) :: Reader.LAtom (name, _) :: tail ->
            let fq = qualify module_name name in
            add_symbol (make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind:"type.struct" ~name:fq ());
            let rec walk_struct in_methods = function
              | [] -> ()
              | Reader.LAtom (":fields", _) :: tl -> walk_struct false tl
              | Reader.LAtom (":methods", _) :: tl -> walk_struct true tl
              | x :: tl ->
                  if in_methods then walk ~owner_type:name x else walk x;
                  walk_struct in_methods tl
            in
            walk_struct false tail
        | Reader.LAtom ("union", _) :: Reader.LAtom (name, _) :: _ ->
            let fq = qualify module_name name in
            add_symbol (make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind:"type.union" ~name:fq ())
        | Reader.LAtom ("%typedef", _) :: ty :: Reader.LAtom (name, _) :: [] ->
            let fq = qualify module_name name in
            let kind =
              match Reader.to_raw ty with
              | Raw.List ((Raw.Atom ("%enum", _) :: _), _) -> "type.enum"
              | _ -> "type.alias"
            in
            add_symbol (make_symbol ~file_md5 ~file ~source ~off ~module_name ~kind ~name:fq ())
        | Reader.LAtom ("decl", _) :: rest ->
            let scope =
              Option.value current_scope ~default:(
                  match owner_type with
                  | Some t -> qualify module_name (t ^ "/<scope>")
                  | None -> "<scope>")
            in
            parse_decl_bindings module_name scope rest
            |> List.iter ~f:(function
                 | `Decl (name, ty, noff, sc) ->
                     add_symbol
                       (make_symbol ~file_md5 ~file ~source ~off:noff ~module_name ~kind:"var.local" ~name ~scope:sc ~ty ()));
            List.iter items ~f:(walk ?current_scope ?owner_type)
        | _ -> List.iter items ~f:(walk ?current_scope ?owner_type))
  in
  List.iter forms ~f:walk;
  let symbols = List.rev !symbols in
  let symbols =
    List.map symbols ~f:(fun s ->
        match Map.find !docs s.name with
        | None -> s
        | Some d ->
            {
              s with
              signature = Option.first_some d.signature s.signature;
              doc = d.doc;
              example = d.example;
              internal = d.internal;
            })
  in
  let docs_only =
    Map.to_alist !docs
    |> List.filter_map ~f:(fun (name, d) ->
           if List.exists symbols ~f:(fun s -> String.equal s.name name) then None
           else
             Some
               (make_symbol ~file_md5 ~file ~source ~off:0 ~module_name ~kind:(symbol_kind_of_name name) ~name
                  ?signature:d.signature ?doc:d.doc ?example:d.example ~internal:d.internal ()))
  in
  symbols @ docs_only

let files_for_input ~use_prelude input_path =
  let user_files = Compiler.load_graph ~use_prelude input_path |> List.map ~f:fst in
  let std_files = if use_prelude then Compiler.load_std_graph () |> List.map ~f:fst else [] in
  List.dedup_and_sort (user_files @ std_files) ~compare:String.compare

let files_for_stdlib () =
  Compiler.load_std_graph () |> List.map ~f:fst |> List.dedup_and_sort ~compare:String.compare

let symbols_for_files files =
  (* Incremental flow:
     cache load -> per-file hit/miss -> optional re-index -> cache save -> merged symbols. *)
  let cache = Cache.load () in
  let cache, symbols =
    List.fold files ~init:(cache, []) ~f:(fun (cache, acc) file ->
        match Cache.get_fresh_entry cache file with
        | Some e -> (cache, e.symbols @ acc)
        | None ->
            let syms = index_file file in
            let cache = Cache.put_file cache ~file ~symbols:syms in
            (cache, syms @ acc))
  in
  Cache.save cache;
  List.rev symbols

let symbols_for_input ~use_prelude input_path = symbols_for_files (files_for_input ~use_prelude input_path)

let symbols_for_stdlib () = symbols_for_files (files_for_stdlib ())

let name_variants name =
  match String.rsplit2 name ~on:'/' with
  | Some (_, tail) -> String.Set.of_list [ name; tail ]
  | None -> String.Set.of_list [ name ]

let find_by_name ~use_prelude ?input_path name =
  let symbols =
    match input_path with
    | Some input -> symbols_for_input ~use_prelude input
    | None -> symbols_for_stdlib ()
  in
  let variants = name_variants name in
  symbols
  |> List.filter ~f:(fun (s : symbol) -> (Set.mem variants s.name || Set.mem variants s.short_name) && not s.internal)
  |> List.dedup_and_sort ~compare:(fun (a : symbol) (b : symbol) ->
         match String.compare a.file b.file with
         | 0 -> Int.compare a.line b.line
         | c -> c)

let complete ~use_prelude ~input_path ~prefix =
  let symbols = symbols_for_input ~use_prelude input_path in
  symbols
  |> List.filter ~f:(fun (s : symbol) -> not s.internal)
  |> List.concat_map ~f:(fun (s : symbol) ->
         let direct = if String.is_prefix s.name ~prefix then [ s ] else [] in
         let hash_variant =
           if String.equal s.kind "type.struct" || String.equal s.kind "type.union" || String.equal s.kind "type.enum"
           then
             let hash_name = s.name ^ "#" in
             if String.is_prefix hash_name ~prefix then [ { s with name = hash_name; short_name = short_name hash_name } ] else []
           else []
         in
         direct @ hash_variant)
  |> List.dedup_and_sort ~compare:(fun (a : symbol) (b : symbol) -> String.compare a.name b.name)

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

let symbols_to_json symbols =
  let one (s : symbol) =
    let base =
      [ Printf.sprintf "\"id\":%d" s.id;
        Printf.sprintf "\"name\":\"%s\"" (json_escape s.name);
        Printf.sprintf "\"kind\":\"%s\"" (json_escape s.kind);
        Printf.sprintf "\"file\":\"%s\"" (json_escape s.file);
        Printf.sprintf "\"line\":%d" s.line;
        Printf.sprintf "\"col\":%d" s.col;
      ]
    in
    let opt key = function
      | None -> []
      | Some v -> [ Printf.sprintf "\"%s\":\"%s\"" key (json_escape v) ]
    in
    let bool key v = [ Printf.sprintf "\"%s\":%s" key (if v then "true" else "false") ] in
    let fields =
      base
      @ opt "module" s.module_name
      @ opt "signature" s.signature
      @ opt "doc" s.doc
      @ opt "example" s.example
      @ opt "scope" s.scope
      @ opt "type" s.ty
      @ bool "internal" s.internal
      @ [ Printf.sprintf "\"file_md5\":\"%s\"" (json_escape s.file_md5) ]
    in
    "{" ^ String.concat ~sep:"," fields ^ "}"
  in
  "[" ^ String.concat ~sep:"," (List.map symbols ~f:one) ^ "]"

let render_show_doc symbols =
  let render_one (s : symbol) =
    let lines =
      [ Some ("Name: " ^ s.name);
        Some ("Kind: " ^ s.kind);
        Option.map s.signature ~f:(fun x -> "Signature: " ^ x);
        Some (Printf.sprintf "Source: %s:%d:%d" s.file s.line s.col);
        Option.map s.module_name ~f:(fun m -> "Module: " ^ m);
      ]
      |> List.filter_opt
    in
    let lines =
      match s.doc with
      | None -> lines
      | Some d -> lines @ [ "Doc:"; "- " ^ d ]
    in
    let lines =
      match s.example with
      | None -> lines
      | Some e -> lines @ [ "Examples:"; "- `" ^ e ^ "`" ]
    in
    String.concat ~sep:"\n" lines
  in
  String.concat ~sep:"\n\n" (List.map symbols ~f:render_one)

let render_cache_dump () =
  let cache = Cache.load () in
  let files = Map.to_alist cache |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b) in
  if List.is_empty files then "Cache is empty."
  else
    let render_symbol (s : symbol) =
      let module_part = Option.value_map s.module_name ~default:"" ~f:(fun m -> " module=" ^ m) in
      let type_part = Option.value_map s.ty ~default:"" ~f:(fun t -> " type=" ^ t) in
      let sig_part = Option.value_map s.signature ~default:"" ~f:(fun x -> " sig=" ^ x) in
      let doc_part = Option.value_map s.doc ~default:"" ~f:(fun d -> " doc=" ^ d) in
      let ex_part = Option.value_map s.example ~default:"" ~f:(fun e -> " example=" ^ e) in
      let scope_part = Option.value_map s.scope ~default:"" ~f:(fun sc -> " scope=" ^ sc) in
      let internal_part = if s.internal then " internal=true" else "" in
      Printf.sprintf
        "  - #%d %s:%d:%d %s [%s]%s%s%s%s%s%s"
        s.id
        s.file
        s.line
        s.col
        s.name
        s.kind
        module_part
        scope_part
        type_part
        sig_part
        doc_part
        (ex_part ^ internal_part)
    in
    let render_file (file, (entry : Cache.file_entry)) =
      let header = Printf.sprintf "File: %s\n  md5=%s\n  symbols=%d" file entry.md5 (List.length entry.symbols) in
      let symbols =
        entry.symbols
        |> List.sort ~compare:(fun (a : symbol) (b : symbol) ->
               match Int.compare a.line b.line with
               | 0 -> Int.compare a.col b.col
               | x -> x)
        |> List.map ~f:render_symbol
      in
      String.concat ~sep:"\n" (header :: symbols)
    in
    String.concat ~sep:"\n\n" (List.map files ~f:render_file)
