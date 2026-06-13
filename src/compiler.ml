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

(* Top-level форма с привязкой к месту в исходнике. Используется при загрузке
   через [Reader.parse_many_loc] и протаскивается через все bulk-трансформы
   (module rewrite, alias rewrite, splice flatten) до per-form emission, где
   span ставится в [Common.current_top_span] и любая bare [Sexc_error] из
   деепфаз "поднимается" в [Sexc_diagnostic] с привязкой к файлу/строке. *)
type top_form = {
  form : Raw.t;
  span : Common.span option;
  (* Имя %module файла, из которого пришла форма (или None). Тег ставится
     загрузчиком (per-file) ВМЕСТО ранней surface-квалификации: namespace
     теперь применяется к %-IR ПОСЛЕ раскрытия макросов (см. [qualify_ir] и
     [compile_forms]). Хранить модуль per-form нужно для cross-module:
     импортированные файлы со своими %module конкатенируются в один список,
     и каждая форма должна квалифицироваться именем своего модуля. *)
  module_name : string option;
}

let raw_only (tops : top_form list) : Raw.t list = List.map tops ~f:(fun t -> t.form)

let with_form (t : top_form) (form : Raw.t) : top_form = { t with form }

let attach_span (sp : Common.span option) (form : Raw.t) : top_form = { form; span = sp; module_name = None }

(* Конвертирует span-aware Raw.t-список (от Reader.parse_many) в top_form-список.
   Span каждой top-формы берётся прямо из узла. *)
let top_forms_of_raws (forms : Raw.t list) : top_form list =
  List.map forms ~f:(fun form -> { form; span = Raw.span_of form; module_name = None })

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
    (* First look right next to the binary (a self-contained bundle: sexc + std/
       side by side — works from any cwd), then the install layout
       PREFIX/bin/sexc + PREFIX/include/sexc/std. *)
    [ Filename.concat bin_dir "std"; Filename.concat prefix_dir "include/sexc/std" ]
  in
  let from_defaults = [ Filename.concat (Stdlib.Sys.getcwd ()) "std"; default_stdlib_dir ] in
  from_env @ from_exe @ from_defaults

let resolve_stdlib_dir () =
  let rec find = function
    | [] ->
        failf
          "Could not locate SexC stdlib (missing core.sexc). Tried %s, <exe-dir>/std, <exe-dir>/../include/sexc/std, ./std, and %s. Set %s to your stdlib directory."
          stdlib_env_var default_stdlib_dir stdlib_env_var
    | dir :: tl -> if stdlib_core_exists dir then dir else find tl
  in
  find (candidate_stdlib_dirs ())

let resolve_import ~from_file rel =
  let base = Filename.dirname from_file in
  let full = Filename.concat base rel in
  (* Авто-добавляем .sexc если расширение опущено. *)
  if String.is_suffix full ~suffix:".sexc" then full
  else full ^ ".sexc"

(* Возвращает (path, alias-option). Поддерживается:
     (%import "./path")
     (%import "./path" :as alias)
*)
let extract_import = function
  | Raw.List ([ Raw.Atom ("%import", _); Raw.Str (p, _) ], _) -> Some (p, None)
  | Raw.List ([ Raw.Atom ("%import", _); Raw.Atom (p, _) ], _) -> Some (p, None)
  | Raw.List ([ Raw.Atom ("%import", _); Raw.Str (p, _); Raw.Atom (":as", _); Raw.Atom (a, _) ], _) -> Some (p, Some a)
  | Raw.List ([ Raw.Atom ("%import", _); Raw.Atom (p, _); Raw.Atom (":as", _); Raw.Atom (a, _) ], _) -> Some (p, Some a)
  | Raw.List ((Raw.Atom ("%import", _) :: _), _) -> fail "Invalid %import form; expected (%import \"path\" [:as alias])"
  | _ -> None

let extract_import_target form =
  Option.map (extract_import form) ~f:fst

let extract_module_name = function
  | Raw.List ([ Raw.Atom ("%module", _); Raw.Atom (name, _) ], _) -> Some name
  | Raw.List ((Raw.Atom ("%module", _) :: _), _) -> fail "%module expects exactly one atom argument"
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

(* То же, но над top_form-списком — сохраняет span каждой не-%module формы. *)
let strip_module_decl_top (tops : top_form list) : string option * top_form list =
  let rec loop module_name acc = function
    | [] -> (module_name, List.rev acc)
    | t :: tl -> (
        match extract_module_name t.form with
        | None -> loop module_name (t :: acc) tl
        | Some name -> (
            match module_name with
            | None -> loop (Some name) acc tl
            | Some prev when String.equal prev name -> loop module_name acc tl
            | Some _ -> fail "Only one %module declaration is allowed per file"))
  in
  loop None [] tops

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
  | Raw.Atom (a, _) -> Raw.Atom ((rewrite_atom name_map a), None)
  | Raw.Str (_, _) -> raw
  | Raw.List (xs, _) -> Raw.List ((List.map xs ~f:(rewrite_type_like name_map)), None)

(* Legacy surface-level qualification (used now only by [apply_module_namespace]
   for the docs/index graph path — [load_graph_from_file]). The compile path
   qualifies the %-IR post-expansion instead (see [qualify_ir]), so the flat /
   bundled type sugar no longer needs to be understood here — by the time it
   would matter it has already expanded to plain %ptr/%const/atom type forms.
   A bundled group's base type is left unqualified on this legacy path (purely
   cosmetic: it only affects how a module-local type renders in generated docs). *)
let rewrite_params name_map = function
  | Raw.List (groups, _) ->
      let rewrite_group g =
        match g with
        | Raw.List ([], _) -> Raw.List ([], None)
        | Raw.List ((ty :: names), _) -> Raw.List ((rewrite_type_like name_map ty :: names), None)
        | other -> other
      in
      Raw.List ((List.map groups ~f:rewrite_group), None)
  | other -> other

let rewrite_fields name_map fields =
  let rewrite_field f =
    match f with
    | Raw.List ([ ty; Raw.Atom (name, _) ], _) -> Raw.List ([ rewrite_type_like name_map ty; Raw.Atom (name, None) ], None)
    | other -> rewrite_type_like name_map other
  in
  List.map fields ~f:rewrite_field

let rewrite_form name_map =
  let rec rw = function
    | Raw.Atom (a, _) -> Raw.Atom ((rewrite_atom name_map a), None)
    | Raw.Str (_, _) as s -> s
    | Raw.List ((Raw.Atom ("quote", _) :: _), _) as q -> q
    | Raw.List ((Raw.Atom ("quasiquote", _) :: _), _) as q -> q
    | Raw.List ((Raw.Atom ("%import", _) :: _ as xs), _) -> Raw.List (xs, None)
    | Raw.List ((Raw.Atom ("%module", _) :: _ as xs), _) -> Raw.List (xs, None)
    | Raw.List ((Raw.Atom ("%doc", _) :: Raw.Atom (name, _) :: props), _) ->
        Raw.List ((Raw.Atom ("%doc", None) :: Raw.Atom ((rewrite_atom name_map name), None) :: List.map props ~f:rw), None)
    | Raw.List ((Raw.Atom ("defn", _) :: ret :: Raw.Atom (name, _) :: params :: body), _) ->
        Raw.List
          ((Raw.Atom ("defn", None) :: rewrite_type_like name_map ret
          :: Raw.Atom ((rewrite_atom name_map name), None)
          :: rewrite_params name_map params
          :: List.map body ~f:rw), None)
    | Raw.List ((Raw.Atom ("%def-fn", _) :: ret :: Raw.Atom (name, _) :: params :: body :: []), _) ->
        Raw.List
          ([ Raw.Atom ("%def-fn", None);
            rewrite_type_like name_map ret;
            Raw.Atom ((rewrite_atom name_map name), None);
            rewrite_params name_map params;
            rw body;
          ], None)
    | Raw.List ((Raw.Atom ("%decl-fn", _) :: ret :: Raw.Atom (name, _) :: params :: []), _) ->
        Raw.List
          ([ Raw.Atom ("%decl-fn", None);
            rewrite_type_like name_map ret;
            Raw.Atom ((rewrite_atom name_map name), None);
            rewrite_params name_map params;
          ], None)
    | Raw.List ((Raw.Atom ("define", _) :: Raw.Atom (name, _) :: value :: []), _) ->
        Raw.List ([ Raw.Atom ("define", None); Raw.Atom ((rewrite_atom name_map name), None); rw value ], None)
    | Raw.List ((Raw.Atom ("%define", _) :: Raw.Atom (name, _) :: value :: []), _) ->
        Raw.List ([ Raw.Atom ("%define", None); Raw.Atom ((rewrite_atom name_map name), None); rw value ], None)
    | Raw.List ((Raw.Atom ("struct", _) :: Raw.Atom (name, _) :: items), _) ->
        let rec rewrite_struct_items phase acc = function
          | [] -> List.rev acc
          | Raw.Atom (":fields", _) :: tl -> rewrite_struct_items `Fields (Raw.Atom (":fields", None) :: acc) tl
          | Raw.Atom (":methods", _) :: tl -> rewrite_struct_items `Methods (Raw.Atom (":methods", None) :: acc) tl
          | item :: tl ->
              let item =
                match phase with
                | `Fields -> (
                    match item with
                    | Raw.List ([ ty; Raw.Atom (field, _) ], _) -> Raw.List ([ rewrite_type_like name_map ty; Raw.Atom (field, None) ], None)
                    | _ -> rw item)
                | `Methods -> rw item
                | `Unknown -> rw item
              in
              rewrite_struct_items phase (item :: acc) tl
        in
        Raw.List ((Raw.Atom ("struct", None) :: Raw.Atom ((rewrite_atom name_map name), None) :: rewrite_struct_items `Unknown [] items), None)
    | Raw.List ((Raw.Atom ("union", _) :: Raw.Atom (name, _) :: fields), _) ->
        Raw.List ((Raw.Atom ("union", None) :: Raw.Atom ((rewrite_atom name_map name), None) :: rewrite_fields name_map fields), None)
    | Raw.List ((Raw.Atom ("%typedef", _) :: ty :: Raw.Atom (name, _) :: []), _) ->
        Raw.List ([ Raw.Atom ("%typedef", None); rewrite_type_like name_map ty; Raw.Atom ((rewrite_atom name_map name), None) ], None)
    | Raw.List ((Raw.Atom (("arrow" | "->" | "dot" | "." | "%arrow" | "%dot" as head), _) :: first :: fields), _) ->
        (* Field-access форма: рерайтим только первый аргумент (объект/указатель);
           остальные позиции — это имена полей, их трогать нельзя. *)
        Raw.List ((Raw.Atom (head, None) :: rw first :: fields), None)
    | Raw.List (xs, _) -> Raw.List ((List.map xs ~f:rw), None)
  in
  rw

let collect_module_defined_names forms =
  let add_name set name =
    if String.is_substring name ~substring:"/" then set else Set.add set name
  in
  let from_typedef_type = function
    | Raw.List ((Raw.Atom ("%enum", _) :: Raw.Atom (enum_name, _) :: _), _) -> Some enum_name
    | _ -> None
  in
  List.fold forms ~init:String.Set.empty ~f:(fun acc form ->
      match form with
      | Raw.List ((Raw.Atom ("defn", _) :: _ :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("%def-fn", _) :: _ :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("%decl-fn", _) :: _ :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("define", _) :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("%define", _) :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("struct", _) :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("union", _) :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("enum", _) :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("defsum", _) :: Raw.Atom (name, _) :: _), _) -> add_name acc name
      | Raw.List ((Raw.Atom ("%typedef", _) :: ty :: Raw.Atom (name, _) :: []), _) ->
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

let name_map_for_module module_name forms =
  let names = collect_module_defined_names forms in
  Set.fold names ~init:String.Map.empty ~f:(fun acc name ->
      Map.set acc ~key:name ~data:(qualify_name module_name name))

(* Группирует tops по %module и строит одну name_map на модуль (голое →
   квалифицированное). Используется и для [qualify_ir] (IR), и для проброса в
   [ctx.current_name_map] (типы в метадате). *)
let build_module_maps (tops : top_form list) : string String.Map.t String.Map.t =
  let module_forms =
    List.fold tops ~init:String.Map.empty ~f:(fun acc t ->
        match t.module_name with
        | None -> acc
        | Some m -> Map.add_multi acc ~key:m ~data:t.form)
  in
  Map.mapi module_forms ~f:(fun ~key:m ~data:forms -> name_map_for_module m forms)

let name_map_for_top module_maps (top : top_form) : string String.Map.t =
  match top.module_name with
  | None -> String.Map.empty
  | Some m -> Option.value (Map.find module_maps m) ~default:String.Map.empty

(* Namespace-квалификация на РАСКРЫТОМ %-IR (после макрофазы). Весь surface-сахар
   (flat/bundled-типы, defn/struct/...) к этому моменту уже разложен в фиксированный
   набор %-форм с известными позициями типов и имён, поэтому проход НЕ угадывает
   «где тип, где имя» по форме — он просто матчит этот набор. Имена ОПРЕДЕЛЕНИЙ,
   которые макросы уже квалифицировали через [$qualify] ("ring/Buffer"), проход не
   ломает: [rewrite_atom] идемпотентен (модульный префикс не ключ name_map). Так что
   фактическая работа здесь — доквалифицировать оставшиеся ГОЛЫЕ ссылки (вызовы,
   атомы-типы) и при этом НЕ трогать name-позиции (имена параметров/полей/вариантов,
   поле в %arrow/%dot). [name_map] строится по голым именам модуля, поэтому ссылка
   `Buffer` → `ring/Buffer`, а уже-`ring/Buffer` остаётся как есть. *)
let qualify_ir name_map =
  let rw_type = rewrite_type_like name_map in
  let rw_params = function
    | Raw.List (groups, _) ->
        Raw.List
          ((List.map groups ~f:(function
             | Raw.List ((ty :: names), _) -> Raw.List ((rw_type ty :: names), None)
             | other -> other)), None)
    | other -> other
  in
  let rw_variant rw = function
    | Raw.List ([ (Raw.Atom _ as v); value ], _) -> Raw.List ([ v; rw value ], None)
    | other -> other
  in
  let rw_field = function
    | Raw.List ([ ty; (Raw.Atom _ as fname) ], _) -> Raw.List ([ rw_type ty; fname ], None)
    | other -> rw_type other
  in
  let rec rw raw =
    match raw with
    | Raw.Atom (a, _) -> Raw.Atom ((rewrite_atom name_map a), None)
    | Raw.Str (_, _) -> raw
    | Raw.List ((Raw.Atom (("quote" | "quasiquote"), _) :: _), _) -> raw
    | Raw.List ([ Raw.Atom ("%def-fn", _); ret; name; params; body ], _) ->
        Raw.List ([ Raw.Atom ("%def-fn", None); rw_type ret; rw name; rw_params params; rw body ], None)
    | Raw.List ([ Raw.Atom ("%decl-fn", _); ret; name; params ], _) ->
        Raw.List ([ Raw.Atom ("%decl-fn", None); rw_type ret; rw name; rw_params params ], None)
    | Raw.List ([ Raw.Atom ("%typedef", _); ty; name ], _) ->
        (* ty может быть (%struct ...)/(%union ...)/(%enum ...) — гоним через rw,
           чтобы их name-позиции защитились нижними кейсами; либо простой тип. *)
        Raw.List ([ Raw.Atom ("%typedef", None); rw ty; rw name ], None)
    | Raw.List ((Raw.Atom ("%struct", _) :: name :: fields), _) ->
        Raw.List ((Raw.Atom ("%struct", None) :: rw name :: List.map fields ~f:rw_field), None)
    | Raw.List ((Raw.Atom ("%union", _) :: name :: fields), _) ->
        Raw.List ((Raw.Atom ("%union", None) :: rw name :: List.map fields ~f:rw_field), None)
    | Raw.List ((Raw.Atom ("%enum", _) :: name :: variants), _) ->
        Raw.List ((Raw.Atom ("%enum", None) :: rw name :: List.map variants ~f:(rw_variant rw)), None)
    | Raw.List ([ Raw.Atom (("%arrow" | "%dot") as head, _); obj; field ], _) ->
        (* Поле — это имя члена, не квалифицируем; квалифицируем только объект. *)
        Raw.List ([ Raw.Atom (head, None); rw obj; field ], None)
    | Raw.List (xs, _) -> Raw.List ((List.map xs ~f:rw), None)
  in
  rw

(* Replace each atom `alias/X[/Y/...]` with `real-module-name/X[/Y/...]`.
   Tree-walks everything (incl. quoted contents) since aliases are pure
   compile-time shorthand with no runtime semantics. *)
let rewrite_alias_atom aliases a =
  match String.lsplit2 a ~on:'/' with
  | Some (prefix, rest) -> (
      match Map.find aliases prefix with
      | Some real -> real ^ "/" ^ rest
      | None -> a)
  | None -> a

let rec rewrite_alias_form aliases = function
  | Raw.Atom (a, _) -> Raw.Atom ((rewrite_alias_atom aliases a), None)
  | Raw.Str (_, _) as s -> s
  | Raw.List (xs, _) -> Raw.List ((List.map xs ~f:(rewrite_alias_form aliases)), None)

let rewrite_alias_top aliases (tops : top_form list) : top_form list =
  List.map tops ~f:(fun t -> with_form t (rewrite_alias_form aliases t.form))

(* Top-level %top-level-splice flattening: дочерние формы наследуют span
   родителя — это разумный fallback, т.к. сами они синтезированы макросом
   и не имеют собственного offset'а в исходнике. *)
let flatten_top_splice (tops : top_form list) : top_form list =
  let rec flat (raw : Raw.t) : Raw.t list =
    match raw with
    | Raw.List ((Raw.Atom ("%top-level-splice", _) :: inner), _) ->
        List.concat_map inner ~f:flat
    | other -> [ other ]
  in
  List.concat_map tops ~f:(fun t ->
    List.map (flat t.form) ~f:(fun form -> with_form t form))

(* Загружает forms из path, гарантируя что каждый файл попадёт в результат
   ровно один раз — даже если он импортируется из нескольких мест. visited
   глобально аккумулирует уже загруженные пути; sibling-ветки видят
   друг друга через возвращаемый visited.

   module_names — мапа path → module name (если есть %module). Нужна для
   разрешения :as-алиасов: импортирующий файл должен знать имя модуля
   того, кого импортирует, даже если файл уже загружен другой веткой. *)
let rec load_forms_from_file ~visited ~module_names ~use_prelude path
    : String.Set.t * string option Map.M(String).t * top_form list =
  let abs = path in
  if Set.mem visited abs then (visited, module_names, [])
  else
    let visited = Set.add visited abs in
    let t = now_ns () in
    let source = In_channel.read_all abs in
    let forms = Reader.parse_many ~file:abs source in
    let tops = top_forms_of_raws forms in
    logf "load %s (%d forms) — %s" abs (List.length tops) (since t);
    let module_name, tops = strip_module_decl_top tops in
    let module_names = Map.set module_names ~key:abs ~data:module_name in

    (* 1. Резолвим импорты рекурсивно, попутно собирая alias-map. *)
    let visited, module_names, imported_tops, aliases =
      List.fold tops
        ~init:(visited, module_names, [], String.Map.empty)
        ~f:(fun (v, m, acc, aliases) top ->
          match extract_import top.form with
          | Some (rel, alias_opt) ->
              if use_prelude && is_prelude_import_target rel then (v, m, acc, aliases)
              else
                let imported = resolve_import ~from_file:abs rel in
                let v, m, more =
                  load_forms_from_file ~visited:v ~module_names:m ~use_prelude imported
                in
                let aliases =
                  match alias_opt, Map.find m imported |> Option.bind ~f:Fn.id with
                  | Some a, Some real -> Map.set aliases ~key:a ~data:real
                  | Some a, None ->
                      failf ":as alias '%s' targets file without %%module declaration: %s" a imported
                  | None, _ -> aliases
                in
                (v, m, acc @ more, aliases)
          | None -> (v, m, acc, aliases))
    in

    (* 2. Свои not-import формы. *)
    let own_tops =
      List.filter tops ~f:(fun t -> Option.is_none (extract_import t.form))
    in

    (* 3. Раскрываем алиасы ДО %module namespace, чтобы наши `alias/X` стали `real/X`. *)
    let own_tops =
      if Map.is_empty aliases then own_tops
      else rewrite_alias_top aliases own_tops
    in

    (* 4. Тегаем свои формы именем модуля. Сама namespace-квалификация
       применяется позже, к %-IR после раскрытия макросов (см. [qualify_ir]
       в [compile_forms]); per-form тег нужен, чтобы импортированные файлы со
       своими %module квалифицировались корректно после конкатенации. *)
    let own_tops =
      match module_name with
      | None -> own_tops
      | Some name -> List.map own_tops ~f:(fun t -> { t with module_name = Some name })
    in

    (visited, module_names, imported_tops @ own_tops)

let rec load_graph_from_file ~visited ~use_prelude path =
  (* Import graph flow:
     current file -> split imports/non-imports -> recursively load imports -> return (self + imported).
     Если файл уже посещён через другую ветку — возвращаем пустой узел
     (он уже есть в графе), это нормальный sibling re-import, не цикл. *)
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

let load_prelude_forms () : top_form list =
  let stdlib_dir = resolve_stdlib_dir () in
  let core_path = Filename.concat stdlib_dir "core.sexc" in
  let _, _, tops =
    load_forms_from_file
      ~visited:String.Set.empty
      ~module_names:String.Map.empty
      ~use_prelude:false core_path
  in
  tops

let is_macro_decl = function
  | Raw.List ((Raw.Atom ("%defmacro", _) :: _), _) -> true
  | Raw.List ((Raw.Atom ("$defun", _) :: _), _) -> true
  | _ -> false

let is_doc_decl = function
  | Raw.List ((Raw.Atom ("%doc", _) :: _), _) -> true
  | _ -> false

(* Pull every %top-level-splice up to the top level, from ANY nesting depth.
   A splice node is removed from its position and its inner forms are emitted as
   sibling top-level forms (before the form that contained them). This lets a
   macro used deep inside a function body (e.g. `with`/`defer1`) hoist a shared
   helper typedef/function to file scope; dedup is the macro's concern (e.g. via
   an #ifndef guard). quote/quasiquote subtrees are left untouched.

   %file-head-splice is similar but its inner forms go to the FILE HEAD (before
   the first function), not next to the containing form — used by `with` to emit
   the dynamic variable's declaration where every reader can see it. Collected
   into [file_head]; deduped/placed by the caller.
   Returns (hoisted_top_forms, cleaned_node_option). *)
let rec hoist_splices ~file_head raw : Raw.t list * Raw.t option =
  match raw with
  | Raw.List ((Raw.Atom ("%file-head-splice", _) :: inner), _) ->
      file_head := !file_head @ inner;
      ([], None)
  | Raw.List ((Raw.Atom ("%top-level-splice", _) :: inner), _) ->
      let hoisted =
        List.concat_map inner ~f:(fun f ->
            let h, c = hoist_splices ~file_head f in
            h @ Option.to_list c)
      in
      (hoisted, None)
  | Raw.List ((Raw.Atom (("quote" | "quasiquote"), _) :: _), _) -> ([], Some raw)
  | Raw.List (elems, sp) ->
      let hoisted, cleaned =
        List.fold elems ~init:([], []) ~f:(fun (hacc, cacc) el ->
            let h, c = hoist_splices ~file_head el in
            (hacc @ h, cacc @ Option.to_list c))
      in
      (hoisted, Some (Raw.List (cleaned, sp)))
  | other -> ([], Some other)

(* A function definition (possibly wrapped in %static/%inline/%extern). The
   collected file-head declarations are injected right before the first one. *)
let rec is_fn_def_form = function
  | Raw.List ((Raw.Atom (("defn" | "%def-fn"), _) :: _), _) -> true
  | Raw.List ((Raw.Atom (("%static" | "%inline" | "%extern" | "%constructor"), _) :: [ inner ]), _) ->
      is_fn_def_form inner
  | _ -> false

(* Name of a (%decl TYPE NAME [INIT]) head-splice declaration, for deduping a
   dynamic variable declared at several `with` sites. *)
let decl_var_name = function
  | Raw.List ((Raw.Atom ("%decl", _) :: _ :: Raw.Atom (name, _) :: _), _) -> Some name
  | _ -> None

let dedup_file_head forms =
  let seen = String.Hash_set.create () in
  List.filter forms ~f:(fun f ->
      match decl_var_name f with
      | Some n -> if Hash_set.mem seen n then false else (Hash_set.add seen n; true)
      | None -> true)

(* [(%dyn-scope *v* INNER)] is an analysis-only marker emitted by [with] to mark
   the region where a dynamic variable is bound (see [Analysis]). It is fully
   transparent to codegen — strip it (keeping INNER) right before parsing, after
   the whole-program analysis has read it. *)
let rec strip_dyn_scope raw =
  match raw with
  (* (%dyn-scope VAR TY INNER) → INNER *)
  | Raw.List ((Raw.Atom ("%dyn-scope", _) :: _ :: _ :: [ inner ]), _) -> strip_dyn_scope inner
  (* (%dyn-require …) — analysis-only requirement declaration → nothing emitted *)
  | Raw.List ((Raw.Atom ("%dyn-require", _) :: _), _) -> Raw.List ([ Raw.Atom ("%nop", None) ], None)
  | Raw.List (xs, sp) -> Raw.List (List.map xs ~f:strip_dyn_scope, sp)
  | other -> other

let compile_forms ?(use_prelude = true) (tops : top_form list) : string =
  (* Core compile pipeline (in order):
     1) normalize %module names
     2) prepend prelude (optional)
     3) drop %doc metadata (docs are handled out-of-band)
     4) collect macros (builds mctx; macro-decl top_forms отбрасываем для emit)
     5) per top_form: install span, expand, flatten splice, parse, emit C.
        Любая bare Sexc_error внутри per-form секции автоматически
        "поднимается" в Sexc_diagnostic с привязкой к файлу/строке. *)
  let module_name, tops = strip_module_decl_top tops in
  (* Стдин-путь (compile_source) даёт нетегированные формы + %module здесь;
     тегаем их. Файловый путь (load_forms_from_file) уже протегал и снял
     %module, так что [module_name] тут None и теги сохраняются. *)
  let tops =
    match module_name with
    | None -> tops
    | Some name ->
        List.map tops ~f:(fun t ->
            match t.module_name with Some _ -> t | None -> { t with module_name = Some name })
  in
  (* Per-module name_map'ы (голое-имя → квалифицированное), по которым
     [qualify_ir] доквалифицирует ссылки в %-IR, а [$qualify-type] — типы в
     метадате. *)
  let module_maps = build_module_maps tops in
  let prelude_tops =
    if use_prelude then with_stage "prelude" (fun () -> load_prelude_forms ()) else []
  in
  let all_tops = prelude_tops @ tops in
  let non_doc_tops = List.filter all_tops ~f:(fun t -> not (is_doc_decl t.form)) in
  let t = now_ns () in
  (* mctx собираем из всех raw-форм (включая prelude). Macro.collect одновременно
     фильтрует %defmacro/$defun из списка, но нам нужен версия с tops — поэтому
     повторяем фильтр здесь, чтобы сохранить span. *)
  let mctx, _ = Macro.collect (raw_only non_doc_tops) in
  let non_macro_tops = List.filter non_doc_tops ~f:(fun t -> not (is_macro_decl t.form)) in
  logf "macro collect: %d forms — %s" (List.length non_doc_tops) (since t);
  (* Declarations destined for the file head (dynamic variables from `with`),
     accumulated across all forms and injected before the first function. *)
  let file_head = ref [] in
  (* Вся раскрытая программа в одном месте (после expand+qualify+hoist, ДО
     codegen) — фундамент для whole-program анализов ([Analysis]). Копим тут
     flattened-формы каждой top-формы (с маркерами %dyn-scope, до их стрипа). *)
  let program_forms = ref [] in
  let emit_one (top : top_form) : string =
    let run () =
      (* Модуль текущей формы → макросы квалифицируют свою метадату через
         [$qualify] (ключи) и [$qualify-type] (типы в значениях, по name_map);
         IR доквалифицируем сами ниже. *)
      let nm = name_map_for_top module_maps top in
      mctx.current_module <- top.module_name;
      mctx.current_name_map <- nm;
      let expanded = Macro.expand_program mctx [ top.form ] in
      (* Namespace на %-IR ДО hoist'а: так квалифицируются и формы, всплывающие
         через %top-level-splice / %file-head-splice (методы, file-head decl'ы). *)
      let expanded =
        if Map.is_empty nm then expanded
        else List.map expanded ~f:(qualify_ir nm)
      in
      let flattened_raws =
        List.concat_map expanded ~f:(fun raw ->
          let hoisted, cleaned = hoist_splices ~file_head raw in
          hoisted @ Option.to_list cleaned)
      in
      (* Тап для whole-program анализа (формы с маркерами %dyn-scope/%dyn-slot). *)
      program_forms := List.rev_append flattened_raws !program_forms;
      (* %dyn-slot — top-level analysis-only маркер (от defslot), для codegen не
         форма → выкидываем; %dyn-scope/%dyn-require внутри форм стрипаются. *)
      let codegen_raws =
        List.filter flattened_raws ~f:(function
          | Raw.List ((Raw.Atom ("%dyn-slot", _) :: _), _) -> false
          | _ -> true)
      in
      let parsed = List.map codegen_raws ~f:(fun r -> Frontend.parse_top (strip_dyn_scope r)) in
      let body = List.map parsed ~f:Codegen_c.emit_top |> String.concat ~sep:"\n\n" in
      (* Top-level #line — покрывает строку сигнатуры функции / определения
         struct (сами стейтменты тела получают свои #line через SAt). *)
      if String.is_empty body then body
      else
        match top.span with
        | Some sp -> Codegen_c.line_directive sp ^ body
        | None -> body
    in
    let run_with_promotion () =
      Common.promote_error_to_diagnostic ~phase:"compile" run
    in
    match top.span with
    | None -> run_with_promotion ()
    | Some sp -> Common.with_top_span sp run_with_promotion
  in
  (* Multi-error: ловим ошибку каждой top-формы, копим и продолжаем — так
     пользователь видит все проблемы за один прогон, а не по одной. Hint-имя
     (голову macro-chain) фиксируем в момент ошибки, т.к. глобальный ref потом
     перезатрётся следующей формой. *)
  let errors = ref [] in
  let hint_head () = List.hd !Common.current_macro_chain in
  let emit_safe (top : top_form) : string =
    try emit_one top with
    | Common.Sexc_diagnostic d ->
        errors := { Common.err_diag = Some d; err_message = d.message; err_hint = hint_head () } :: !errors;
        ""
    | Common.Sexc_error msg ->
        errors := { Common.err_diag = None; err_message = msg; err_hint = hint_head () } :: !errors;
        ""
  in
  let t = now_ns () in
  let chunks = List.map non_macro_tops ~f:emit_safe in
  (* Whole-program анализ по всей раскрытой программе. Ошибки копим в общий errors
     (вместе с per-form — всё за прогон); warnings печатаем сразу в stderr,
     компиляцию они не фейлят. *)
  let analysis_errors, analysis_warnings = Analysis.check_program (List.rev !program_forms) in
  errors := List.rev_append analysis_errors !errors;
  List.iter analysis_warnings ~f:(fun d ->
      Stdlib.prerr_endline (Common.render_diagnostic ~severity:"warning" d));
  (match List.rev !errors with
   | [] -> ()
   | items -> raise (Common.Sexc_errors items));
  (* Render file-head declarations (deduped) and splice them in just before the
     first function definition — after includes/type defs, before any reader. *)
  let chunks =
    match dedup_file_head !file_head with
    | [] -> chunks
    | decls ->
        let head =
          List.map decls ~f:Frontend.parse_top
          |> List.map ~f:Codegen_c.emit_top
          |> String.concat ~sep:"\n\n"
        in
        let idx =
          List.findi non_macro_tops ~f:(fun _ t -> is_fn_def_form t.form)
          |> Option.map ~f:fst
        in
        (match idx with
         | Some i -> List.concat [ List.take chunks i; [ head ]; List.drop chunks i ]
         | None -> chunks @ [ head ])
  in
  let c = String.concat ~sep:"\n\n" (List.filter chunks ~f:(fun s -> not (String.is_empty s))) in
  logf "compile per-form (%d tops) — %s" (List.length non_macro_tops) (since t);
  logf "codegen C: %d bytes" (String.length c);
  c

let compile_source ?(use_prelude = true) source =
  let forms = Reader.parse_many ~file:"<stdin>" source in
  let tops = top_forms_of_raws forms in
  compile_forms ~use_prelude tops

let compile_file ?(use_prelude = true) path =
  let _, _, tops =
    load_forms_from_file
      ~visited:String.Set.empty
      ~module_names:String.Map.empty
      ~use_prelude path
  in
  compile_forms ~use_prelude tops

(* Прогоняет тот же пайплайн что compile_forms, но останавливается после
   macro expansion и возвращает накопленную compile-time metadata
   (ctx.sym_meta). Используется CLI-командой m-dump. *)
let metadata_of_file ?(use_prelude = true) path =
  let _, _, tops =
    load_forms_from_file
      ~visited:String.Set.empty
      ~module_names:String.Map.empty
      ~use_prelude path
  in
  (* tops уже протегированы модулем загрузчиком; %module-форм в них нет. *)
  let module_maps = build_module_maps tops in
  let prelude_tops = if use_prelude then load_prelude_forms () else [] in
  let all_tops = prelude_tops @ tops in
  let non_doc_tops = List.filter all_tops ~f:(fun t -> not (is_doc_decl t.form)) in
  let mctx, _ = Macro.collect (raw_only non_doc_tops) in
  let non_macro_tops = List.filter non_doc_tops ~f:(fun t -> not (is_macro_decl t.form)) in
  (* Раскрываем по одной форме, выставляя модуль и его name_map — чтобы
     [$qualify]/[$qualify-type] в макросах дали квалифицированные ключи И типы
     метадаты (как в compile_forms). *)
  List.iter non_macro_tops ~f:(fun t ->
      mctx.current_module <- t.module_name;
      mctx.current_name_map <- name_map_for_top module_maps t;
      ignore (Macro.expand_program mctx [ t.form ]));
  mctx.sym_meta
