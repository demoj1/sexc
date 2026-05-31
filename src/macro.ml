open Core
open Common

(*
   Macro phase / compile-time evaluator.

   Responsibilities:
   - collect %defmacro declarations
   - expand macro calls recursively
   - evaluate meta builtins ($...) for %defmacro, %eval, %evals
   - support list-context splicing for %evals

   Extension point:
   - Add new compile-time builtins in [eval_expr] (prefer $-prefixed API only).
   - Add new special compile-time forms in [expand_one] only when they affect expansion control.

   Data flow:
   - [collect] splits top-level forms into macro definitions + normal forms.
   - [expand_program] expands normal forms recursively with [expand_one].
   - [expand_one] calls [apply] for %defmacro and [eval_expr] for %eval/%evals.
   - [eval_expr] is a small Lisp evaluator used only during compile-time expansion.
*)

type def = {
  name : string;
  params : string list;
  rest_param : string option;
  body : Raw.t;
}

type ctx = {
  defs : def String.Map.t;
  ct_fns : def String.Map.t;
  max_depth : int;
  mutable gensym_counter : int;
  mutable sym_meta : Raw.t String.Map.t String.Map.t;
}

let evals_splice_tag = "__sexc_internal_evals_splice__"

let bool_raw b = if b then Raw.Atom "t" else Raw.Atom "nil"

let is_falsey = function
  | Raw.Atom "nil" -> true
  | Raw.List [] -> true
  | _ -> false

let rec raw_equal a b =
  match a, b with
  | Raw.Atom x, Raw.Atom y -> String.equal x y
  | Raw.Str x, Raw.Str y -> String.equal x y
  | Raw.List xs, Raw.List ys ->
      List.length xs = List.length ys && List.for_all2_exn xs ys ~f:raw_equal
  | _ -> false

let expect_atom = function
  | Raw.Atom s -> s
  | _ -> fail "macro expected atom"

let expect_list = function
  | Raw.List xs -> xs
  | _ -> fail "macro expected list"

let expect_atom_or_string = function
  | Raw.Atom s | Raw.Str s -> s
  | _ -> fail "macro expected atom or string"

let is_evals_splice = function
  | Raw.List [ Raw.Atom tag; Raw.List xs ] when String.equal tag evals_splice_tag -> Some xs
  | _ -> None

let with_bound env names values =
  List.fold2_exn names values ~init:env ~f:(fun acc n v -> Map.set acc ~key:n ~data:v)

let gensym ctx prefix =
  let n = ctx.gensym_counter in
  ctx.gensym_counter <- ctx.gensym_counter + 1;
  Raw.Atom (prefix ^ Int.to_string n)

let is_self_evaluating_atom a =
  String.equal a "nil"
  || String.equal a "t"
  || (not (String.is_empty a) && Char.equal a.[0] ':')
  || Option.is_some (Int.of_string_opt a)
  || Option.is_some (Float.of_string_opt a)

let rec eval_expr ctx env expr =
  match expr with
  | Raw.Atom a -> (
      match Map.find env a with
      | Some v -> v
      | None when is_self_evaluating_atom a -> expr
      | None -> failf "Unbound variable in macro eval: %s" a)
  | Raw.Str _ -> expr
  | Raw.List [] -> Raw.List []
  | Raw.List (Raw.Atom "quote" :: [ body ]) -> body
  | Raw.List (Raw.Atom "quote" :: _) -> fail "quote expects exactly one argument"
  | Raw.List (Raw.Atom "$quote" :: [ body ]) -> body
  | Raw.List (Raw.Atom "$quote" :: _) -> fail "$quote expects exactly one argument"
  | Raw.List (Raw.Atom "quasiquote" :: [ body ]) -> eval_quasiquote ctx env ~depth:1 body
  | Raw.List (Raw.Atom "$if" :: [ cond; yes; no ]) ->
      if is_falsey (eval_expr ctx env cond) then eval_expr ctx env no else eval_expr ctx env yes
  | Raw.List (Raw.Atom "$if" :: [ cond; yes ]) ->
      if is_falsey (eval_expr ctx env cond) then Raw.Atom "nil" else eval_expr ctx env yes
  | Raw.List (Raw.Atom "$cond" :: clauses) -> eval_cond ctx env clauses
  | Raw.List (Raw.Atom "$case" :: scrut :: clauses) ->
      let v = eval_expr ctx env scrut in
      eval_case ctx env v clauses
  | Raw.List (Raw.Atom "$case" :: _) -> fail "$case expects: ($case scrutinee clause...)"
  | Raw.List (Raw.Atom "$cons" :: [ hd; tl ]) ->
      let h = eval_expr ctx env hd in
      let t = expect_list (eval_expr ctx env tl) in
      Raw.List (h :: t)
  | Raw.List (Raw.Atom "$car" :: [ x ]) -> (
      match expect_list (eval_expr ctx env x) with
      | h :: _ -> h
      | [] -> Raw.Atom "nil")
  | Raw.List (Raw.Atom "$cdr" :: [ x ]) -> (
      match expect_list (eval_expr ctx env x) with
      | _ :: tl -> Raw.List tl
      | [] -> Raw.List [])
  | Raw.List (Raw.Atom "$null?" :: [ x ]) -> bool_raw (is_falsey (eval_expr ctx env x))
  | Raw.List (Raw.Atom "$atom?" :: [ x ]) -> (
      match eval_expr ctx env x with
      | Raw.Atom _ | Raw.Str _ -> bool_raw true
      | Raw.List _ -> bool_raw false)
  | Raw.List (Raw.Atom "$eq?" :: [ a; b ]) ->
      bool_raw (raw_equal (eval_expr ctx env a) (eval_expr ctx env b))
  | Raw.List (Raw.Atom "$symcat" :: parts) ->
      let text =
        List.map parts ~f:(fun p -> eval_expr ctx env p |> expect_atom_or_string)
        |> String.concat ~sep:""
      in
      Raw.Atom text
  | Raw.List (Raw.Atom "$str" :: parts) ->
      let text =
        List.map parts ~f:(fun p -> eval_expr ctx env p |> expect_atom_or_string)
        |> String.concat ~sep:""
      in
      Raw.Str text
  | Raw.List (Raw.Atom "$namespace-of" :: [ x ]) ->
      (* "a/b/c" → "a/b"; "x" → nil. Split on LAST '/' — каждое имя
         попадает в свой непосредственный родительский namespace. *)
      let s = expect_atom_or_string (eval_expr ctx env x) in
      (match String.rsplit2 s ~on:'/' with
       | Some (prefix, _) -> Raw.Atom prefix
       | None -> Raw.Atom "nil")
  | Raw.List (Raw.Atom "$namespace-of" :: _) ->
      fail "$namespace-of expects exactly one argument"
  | Raw.List (Raw.Atom "$let" :: Raw.List binds :: body) ->
      let rec bind env = function
        | [] -> env
        | Raw.List [ Raw.Atom name; value_expr ] :: tl ->
            let value = eval_expr ctx env value_expr in
            bind (Map.set env ~key:name ~data:value) tl
        | _ -> fail "$let bindings must be pairs: ((name expr) ...)"
      in
      let env = bind env binds in
      let rec eval_last = function
        | [] -> Raw.Atom "nil"
        | [ x ] -> eval_expr ctx env x
        | x :: tl ->
            ignore (eval_expr ctx env x);
            eval_last tl
      in
      eval_last body
  | Raw.List (Raw.Atom "$for" :: [ Raw.List [ Raw.Atom var; xs ]; body ]) ->
      let values = expect_list (eval_expr ctx env xs) in
      Raw.List
        (List.map values ~f:(fun v ->
             let env = Map.set env ~key:var ~data:v |> Map.set ~key:"it" ~data:v in
             eval_expr ctx env body))
  | Raw.List (Raw.Atom "$for" :: _) ->
      fail "$for expects ($for (var list-expr) body)"
  | Raw.List (Raw.Atom "$map" :: args) -> eval_expr ctx env (Raw.List (Raw.Atom "$--map" :: args))
  | Raw.List (Raw.Atom "$filter" :: args) ->
      eval_expr ctx env (Raw.List (Raw.Atom "$--filter" :: args))
  | Raw.List (Raw.Atom "$reduce" :: args) ->
      eval_expr ctx env (Raw.List (Raw.Atom "$--reduce" :: args))
  | Raw.List (Raw.Atom "$--map" :: [ mapper; xs ]) ->
      let values = expect_list (eval_expr ctx env xs) in
      Raw.List
        (List.map values ~f:(fun v ->
             let env = Map.set env ~key:"it" ~data:v in
             eval_expr ctx env mapper))
  | Raw.List (Raw.Atom "$--filter" :: [ pred; xs ]) ->
      let values = expect_list (eval_expr ctx env xs) in
      Raw.List
        (List.filter values ~f:(fun v ->
             let env = Map.set env ~key:"it" ~data:v in
             not (is_falsey (eval_expr ctx env pred))))
  | Raw.List (Raw.Atom "$--reduce" :: [ reducer; init; xs ]) ->
      let values = expect_list (eval_expr ctx env xs) in
      let acc0 = eval_expr ctx env init in
      List.fold values ~init:acc0 ~f:(fun acc v ->
          let env = Map.set env ~key:"it" ~data:v |> Map.set ~key:"acc" ~data:acc in
          eval_expr ctx env reducer)
  | Raw.List (Raw.Atom "$dolist" :: [ Raw.List [ Raw.Atom var; xs ]; body ]) ->
      let values = expect_list (eval_expr ctx env xs) in
      Raw.List
        (List.map values ~f:(fun v ->
             let env = Map.set env ~key:var ~data:v in
             eval_expr ctx env body))
  | Raw.List (Raw.Atom "$dolist" :: _) ->
      fail "$dolist expects ($dolist (var list-expr) body)"
  | Raw.List (Raw.Atom "$error" :: [ msg ]) ->
      let text =
        match eval_expr ctx env msg with
        | Raw.Atom s | Raw.Str s -> s
        | _ -> "macro error"
      in
      fail text
  | Raw.List (Raw.Atom "$gensym" :: []) -> gensym ctx "__g"
  | Raw.List (Raw.Atom "$gensym" :: [ prefix ]) ->
      let p =
        match eval_expr ctx env prefix with
        | Raw.Atom s | Raw.Str s -> s
        | _ -> fail "gensym prefix must evaluate to atom or string"
      in
      gensym ctx p
  | Raw.List (Raw.Atom "$not" :: [ x ]) ->
      bool_raw (is_falsey (eval_expr ctx env x))
  | Raw.List (Raw.Atom "$not" :: _) -> fail "$not expects exactly one argument"
  | Raw.List (Raw.Atom "$do" :: exprs) ->
      List.fold exprs ~init:(Raw.Atom "nil") ~f:(fun _ e -> eval_expr ctx env e)
  | Raw.List (Raw.Atom "$assert" :: [ cond; msg ]) ->
      if is_falsey (eval_expr ctx env cond) then
        let text =
          match eval_expr ctx env msg with
          | Raw.Atom s | Raw.Str s -> s
          | _ -> "assertion failed"
        in
        fail text
      else Raw.Atom "nil"
  | Raw.List (Raw.Atom "$assert" :: _) ->
      fail "$assert expects exactly two arguments: ($assert cond message)"
  | Raw.List (Raw.Atom arith :: [ a; b ])
    when List.mem [ "$+"; "$-"; "$*"; "$/" ] arith ~equal:String.equal ->
      let to_int e =
        match eval_expr ctx env e with
        | Raw.Atom s -> (
            match Int.of_string_opt s with
            | Some n -> n
            | None -> failf "%s: argument is not an integer: %s" arith s)
        | _ -> failf "%s: argument must be an integer atom" arith
      in
      let result =
        match arith with
        | "$+" -> to_int a + to_int b
        | "$-" -> to_int a - to_int b
        | "$*" -> to_int a * to_int b
        | "$/" ->
            let divisor = to_int b in
            if Int.equal divisor 0 then fail "$/ division by zero";
            to_int a / divisor
        | _ -> assert false
      in
      Raw.Atom (Int.to_string result)
  | Raw.List (Raw.Atom arith :: _)
    when List.mem [ "$+"; "$-"; "$*"; "$/" ] arith ~equal:String.equal ->
      failf "%s expects exactly two arguments" arith
  | Raw.List (Raw.Atom "$|>" :: init :: forms) ->
      let thread acc form =
        match form with
        | Raw.Atom _ -> Raw.List [ form; acc ]
        | Raw.List (f :: args) -> Raw.List (f :: acc :: args)
        | _ -> fail "$|> each step must be a symbol or (f arg...) list"
      in
      eval_expr ctx env (List.fold forms ~init ~f:thread)
  | Raw.List (Raw.Atom "$|>" :: _) -> fail "$|> expects at least one argument"
  | Raw.List (Raw.Atom "$||>" :: init :: forms) ->
      let thread acc form =
        match form with
        | Raw.Atom _ -> Raw.List [ form; acc ]
        | Raw.List fs -> Raw.List (fs @ [ acc ])
        | _ -> fail "$||> each step must be a symbol or list"
      in
      eval_expr ctx env (List.fold forms ~init ~f:thread)
  | Raw.List (Raw.Atom "$||>" :: _) -> fail "$||> expects at least one argument"
  | Raw.List (Raw.Atom "$|as>" :: init :: Raw.Atom binding :: forms) ->
      let rec loop v = function
        | [] -> v
        | form :: tl ->
            let env' = Map.set env ~key:binding ~data:v in
            loop (eval_expr ctx env' form) tl
      in
      loop (eval_expr ctx env init) forms
  | Raw.List (Raw.Atom "$|as>" :: _) ->
      fail "$|as> expects: ($|as> init binding-name form...)"
  | Raw.List (Raw.Atom legacy :: _)
    when List.mem
           [
             "if";
             "list";
             "cons";
             "append";
             "car";
             "cdr";
             "length";
             "reverse";
             "nth";
             "null?";
             "atom?";
             "eq?";
             "symcat";
             "let";
             "for";
             "map";
             "filter";
             "reduce";
             "error";
             "gensym";
           ]
           legacy ~equal:String.equal ->
      failf "Legacy meta builtin '%s' is not allowed; use '$%s'" legacy legacy
  | Raw.List (Raw.Atom "$m-put" :: sym_expr :: rest) ->
      let sym_name = expect_atom (eval_expr ctx env sym_expr) in
      let rec pair_up = function
        | [] -> []
        | [ _ ] -> fail "$m-put expects an even number of key/value forms after the symbol"
        | k :: v :: tl ->
            let key = expect_atom_or_string (eval_expr ctx env k) in
            let value = eval_expr ctx env v in
            (key, value) :: pair_up tl
      in
      let pairs = pair_up rest in
      let cur_meta =
        Option.value (Map.find ctx.sym_meta sym_name) ~default:String.Map.empty
      in
      let new_meta =
        List.fold pairs ~init:cur_meta ~f:(fun m (k, v) -> Map.set m ~key:k ~data:v)
      in
      ctx.sym_meta <- Map.set ctx.sym_meta ~key:sym_name ~data:new_meta;
      Raw.Atom "nil"
  | Raw.List (Raw.Atom "$m-put" :: _) ->
      fail "$m-put expects: ($m-put sym key1 val1 key2 val2 ...)"
  | Raw.List (Raw.Atom "$m-get" :: [ sym_expr; key_expr ]) -> (
      let sym_name = expect_atom (eval_expr ctx env sym_expr) in
      let key = expect_atom_or_string (eval_expr ctx env key_expr) in
      match Map.find ctx.sym_meta sym_name with
      | None -> Raw.Atom "nil"
      | Some m -> Option.value (Map.find m key) ~default:(Raw.Atom "nil"))
  | Raw.List (Raw.Atom "$m-get" :: _) ->
      fail "$m-get expects exactly two arguments: ($m-get sym key)"
  | Raw.List (Raw.Atom fn_name :: args) when Map.mem ctx.ct_fns fn_name ->
      let f = Map.find_exn ctx.ct_fns fn_name in
      let evaled_args = List.map args ~f:(eval_expr ctx env) in
      let fixed_len = List.length f.params in
      let call_env =
        match f.rest_param with
        | None ->
            if List.length evaled_args <> fixed_len then
              failf "Compile-time function %s expects %d arguments, got %d"
                fn_name fixed_len (List.length evaled_args);
            with_bound String.Map.empty f.params evaled_args
        | Some rest_name ->
            if List.length evaled_args < fixed_len then
              failf "Compile-time function %s expects at least %d arguments, got %d"
                fn_name fixed_len (List.length evaled_args);
            let fixed_args = List.take evaled_args fixed_len in
            let rest_args = List.drop evaled_args fixed_len in
            Map.set (with_bound String.Map.empty f.params fixed_args)
              ~key:rest_name ~data:(Raw.List rest_args)
      in
      eval_expr ctx call_env f.body
  | Raw.List xs -> Raw.List (List.map xs ~f:(eval_expr ctx env))

and eval_body_last ctx env = function
  | [] -> Raw.Atom "nil"
  | [ x ] -> eval_expr ctx env x
  | x :: tl ->
      ignore (eval_expr ctx env x);
      eval_body_last ctx env tl

and eval_cond ctx env = function
  | [] -> Raw.Atom "nil"
  | Raw.List (Raw.Atom "else" :: body) :: rest ->
      if not (List.is_empty rest) then fail "$cond: else must be the last clause";
      if List.is_empty body then fail "$cond: else clause must have a body";
      eval_body_last ctx env body
  | Raw.List (test :: body) :: rest ->
      if List.is_empty body then fail "$cond: clause must have a body";
      if is_falsey (eval_expr ctx env test) then eval_cond ctx env rest
      else eval_body_last ctx env body
  | Raw.List [] :: _ -> fail "$cond: clause must be (test body...) or (else body...)"
  | _ -> fail "$cond: each clause must be a list"

and eval_case ctx env scrutinee = function
  | [] -> Raw.Atom "nil"
  | Raw.List (Raw.Atom "else" :: body) :: rest ->
      if not (List.is_empty rest) then fail "$case: else must be the last clause";
      if List.is_empty body then fail "$case: else clause must have a body";
      eval_body_last ctx env body
  | Raw.List (pattern :: body) :: rest ->
      if List.is_empty body then fail "$case: clause must have a body";
      let pv = eval_expr ctx env pattern in
      if raw_equal scrutinee pv then eval_body_last ctx env body
      else eval_case ctx env scrutinee rest
  | Raw.List [] :: _ -> fail "$case: clause must be (pattern body...) or (else body...)"
  | _ -> fail "$case: each clause must be a list"

and eval_quasiquote ctx env ~depth expr =
  match expr with
  | Raw.List [ Raw.Atom "unquote"; x ] ->
      if depth = 1 then eval_expr ctx env x
      else Raw.List [ Raw.Atom "unquote"; eval_quasiquote ctx env ~depth:(depth - 1) x ]
  | Raw.List [ Raw.Atom "splice"; x ] ->
      if depth = 1 then fail "splice is only valid inside list in quasiquote"
      else Raw.List [ Raw.Atom "splice"; eval_quasiquote ctx env ~depth:(depth - 1) x ]
  | Raw.List [ Raw.Atom "quasiquote"; x ] ->
      Raw.List [ Raw.Atom "quasiquote"; eval_quasiquote ctx env ~depth:(depth + 1) x ]
  | Raw.List xs -> Raw.List (eval_qq_list ctx env ~depth xs)
  | Raw.Atom _ | Raw.Str _ -> expr

and eval_qq_list ctx env ~depth xs =
  List.concat_map xs ~f:(fun item ->
      match item with
      | Raw.List [ Raw.Atom "splice"; x ] when depth = 1 ->
          let v = eval_expr ctx env x in
          expect_list v
      | _ -> [ eval_quasiquote ctx env ~depth item ])

let parse_params params =
  let rec loop fixed = function
    | [] -> (List.rev fixed, None)
    | "&rest" :: [ rest_name ] -> (List.rev fixed, Some rest_name)
    | "&rest" :: _ -> fail "&rest must be followed by exactly one parameter name"
    | p :: tl -> loop (p :: fixed) tl
  in
  loop [] params

let parse_macro_def raw =
  match raw with
  | Raw.List (Raw.Atom "%defmacro" :: Raw.Atom name :: Raw.List params :: [ body ]) ->
      let params = List.map params ~f:expect_atom in
      let params, rest_param = parse_params params in
      { name; params; rest_param; body }
  | _ -> fail "Invalid %defmacro form; expected (%defmacro name (args...) body)"

let parse_ct_fn_def raw =
  match raw with
  | Raw.List (Raw.Atom "$defun" :: Raw.Atom name :: Raw.List params :: body) ->
      let params = List.map params ~f:expect_atom in
      let params, rest_param = parse_params params in
      let body =
        match body with
        | [ single ] -> single
        | _ -> Raw.List (Raw.Atom "$do" :: body)
      in
      { name; params; rest_param; body }
  | _ -> fail "Invalid $defun form; expected ($defun name (params...) body...)"

let rec raw_to_sexp = function
  | Raw.Atom s -> s
  | Raw.Str s -> "\"" ^ s ^ "\""
  | Raw.List xs ->
      "(" ^ String.concat ~sep:" " (List.map xs ~f:raw_to_sexp) ^ ")"

let escape_for_c_comment s =
  String.substr_replace_all s ~pattern:"*/" ~with_:"* /"

let format_meta_dump sym_meta =
  let buf = Buffer.create 512 in
  Buffer.add_string buf "\n * SexC Symbol Metadata Dump";
  if Map.is_empty sym_meta then
    Buffer.add_string buf "\n *   (no symbols recorded)"
  else
    Map.iteri sym_meta ~f:(fun ~key:sym ~data:meta ->
        Buffer.add_string buf (Printf.sprintf "\n *\n *   %s:" sym);
        Map.iteri meta ~f:(fun ~key ~data ->
            Buffer.add_string buf
              (Printf.sprintf "\n *     %s = %s" key (raw_to_sexp data))));
  Buffer.add_string buf "\n ";
  escape_for_c_comment (Buffer.contents buf)

(* Plain текстовый дамп без C-комментарной обёртки — для CLI. *)
let format_meta_text sym_meta =
  if Map.is_empty sym_meta then "(no symbols recorded)\n"
  else
    let buf = Buffer.create 512 in
    Map.iteri sym_meta ~f:(fun ~key:sym ~data:meta ->
        Buffer.add_string buf (Printf.sprintf "%s:\n" sym);
        Map.iteri meta ~f:(fun ~key ~data ->
            Buffer.add_string buf
              (Printf.sprintf "  %s = %s\n" key (raw_to_sexp data))));
    Buffer.contents buf

(* JSON-сериализация. Атомы → строка; Raw.Str → строка с маркером (чтобы
   tooling мог отличить "foo" от foo); списки → массивы. *)
let json_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter s ~f:(fun c ->
      match c with
      | '\"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.to_int c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.to_int c))
      | c -> Buffer.add_char buf c);
  Buffer.contents buf

let rec raw_to_json = function
  | Raw.Atom s -> Printf.sprintf "\"%s\"" (json_escape s)
  | Raw.Str s -> Printf.sprintf "{\"str\":\"%s\"}" (json_escape s)
  | Raw.List xs ->
      "[" ^ String.concat ~sep:"," (List.map xs ~f:raw_to_json) ^ "]"

let format_meta_json sym_meta =
  let entries =
    Map.to_alist sym_meta
    |> List.map ~f:(fun (sym, kv) ->
           let pairs =
             Map.to_alist kv
             |> List.map ~f:(fun (k, v) ->
                    Printf.sprintf "\"%s\":%s" (json_escape k) (raw_to_json v))
             |> String.concat ~sep:","
           in
           Printf.sprintf "\"%s\":{%s}" (json_escape sym) pairs)
  in
  "{" ^ String.concat ~sep:"," entries ^ "}"

let collect forms =
  let rec loop defs ct_fns normal = function
    | [] ->
        ( { defs; ct_fns; max_depth = 200; gensym_counter = 0; sym_meta = String.Map.empty },
          List.rev normal )
    | raw :: tl -> (
        match raw with
        | Raw.List (Raw.Atom "%defmacro" :: _) ->
            let m = parse_macro_def raw in
            if Map.mem defs m.name then failf "Duplicate %%defmacro: %s" m.name;
            loop (Map.set defs ~key:m.name ~data:m) ct_fns normal tl
        | Raw.List (Raw.Atom "$defun" :: _) ->
            let f = parse_ct_fn_def raw in
            if Map.mem ct_fns f.name then failf "Duplicate $defun: %s" f.name;
            loop defs (Map.set ct_fns ~key:f.name ~data:f) normal tl
        | _ -> loop defs ct_fns (raw :: normal) tl)
  in
  loop String.Map.empty String.Map.empty [] forms

let apply ctx depth m args =
  let fixed_len = List.length m.params in
  let env =
    match m.rest_param with
    | None ->
        if List.length args <> fixed_len then
          failf "Macro %s expects %d arguments, got %d" m.name fixed_len (List.length args);
        with_bound String.Map.empty m.params args
    | Some rest_name ->
        if List.length args < fixed_len then
          failf "Macro %s expects at least %d arguments, got %d" m.name fixed_len (List.length args);
        let fixed_args = List.take args fixed_len in
        let rest_args = List.drop args fixed_len in
        Map.set (with_bound String.Map.empty m.params fixed_args) ~key:rest_name ~data:(Raw.List rest_args)
  in
  let expanded = eval_expr ctx env m.body in
  if depth > ctx.max_depth then
    failf "Macro expansion exceeded max depth (%d)" ctx.max_depth;
  expanded

let rec expand_eval_form_for_arg ctx ~depth = function
  | Raw.List (Raw.Atom "%eval" :: [ expr ]) ->
      let out = eval_expr ctx String.Map.empty expr in
      [ expand_one ctx ~depth:(depth + 1) out ]
  | Raw.List (Raw.Atom "%eval" :: _) -> fail "%eval expects exactly one argument"
  | Raw.List (Raw.Atom "%evals" :: [ expr ]) ->
      let out = eval_expr ctx String.Map.empty expr in
      let items = expect_list out in
      List.map items ~f:(fun item -> expand_one ctx ~depth:(depth + 1) item)
  | Raw.List (Raw.Atom "%evals" :: _) -> fail "%evals expects exactly one argument"
  | other -> [ other ]

and expand_eval_args_for_macro ctx ~depth xs =
  List.concat_map xs ~f:(fun x -> expand_eval_form_for_arg ctx ~depth x)

and expand_one ctx ~depth raw =
  if depth > ctx.max_depth then failf "Macro expansion exceeded max depth (%d)" ctx.max_depth;
  match raw with
  | Raw.Atom _ | Raw.Str _ -> raw
  | Raw.List [] -> raw
  | Raw.List (Raw.Atom "quote" :: _) -> raw
  | Raw.List (Raw.Atom "quasiquote" :: _) -> raw
  | Raw.List (Raw.Atom "%eval" :: [ expr ]) ->
      let out = eval_expr ctx String.Map.empty expr in
      expand_one ctx ~depth:(depth + 1) out
  | Raw.List (Raw.Atom "%eval" :: _) ->
      fail "%eval expects exactly one argument"
  | Raw.List (Raw.Atom "%evals" :: [ expr ]) ->
      let out = eval_expr ctx String.Map.empty expr in
      let items = expect_list out in
      let items = List.map items ~f:(fun item -> expand_one ctx ~depth:(depth + 1) item) in
      Raw.List [ Raw.Atom evals_splice_tag; Raw.List items ]
  | Raw.List (Raw.Atom "%evals" :: _) ->
      fail "%evals expects exactly one argument"
  | Raw.List [ Raw.Atom "%m-dump" ] ->
      Raw.List
        [ Raw.Atom "%comment"; Raw.Str (format_meta_dump ctx.sym_meta) ]
  | Raw.List (Raw.Atom "%m-dump" :: _) ->
      fail "%m-dump takes no arguments"
  | Raw.List (Raw.Atom head :: args) -> (
      match Map.find ctx.defs head with
      | Some m ->
          let args = expand_eval_args_for_macro ctx ~depth args in
          let out = apply ctx (depth + 1) m args in
          expand_one ctx ~depth:(depth + 1) out
      | None -> Raw.List (Raw.Atom head :: expand_list_items ctx ~depth args))
  | Raw.List xs -> Raw.List (expand_list_items ctx ~depth xs)

and expand_list_items ctx ~depth xs =
  List.concat_map xs ~f:(fun x ->
      let expanded = expand_one ctx ~depth:(depth + 1) x in
      match is_evals_splice expanded with
      | Some items -> items
      | None -> [ expanded ])

let expand_program ctx forms =
  List.concat_map forms ~f:(fun x ->
      let out = expand_one ctx ~depth:0 x in
      match is_evals_splice out with
      | Some items -> items
      | None -> [ out ])
