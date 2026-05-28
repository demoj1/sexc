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
*)

type def = {
  name : string;
  params : string list;
  rest_param : string option;
  body : Raw.t;
}

type ctx = {
  defs : def String.Map.t;
  max_depth : int;
  mutable gensym_counter : int;
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

let rec eval_expr ctx env expr =
  match expr with
  | Raw.Atom a -> Option.value (Map.find env a) ~default:expr
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
  | Raw.List (Raw.Atom "$list" :: args) -> Raw.List (List.map args ~f:(eval_expr ctx env))
  | Raw.List (Raw.Atom "$cons" :: [ hd; tl ]) ->
      let h = eval_expr ctx env hd in
      let t = expect_list (eval_expr ctx env tl) in
      Raw.List (h :: t)
  | Raw.List (Raw.Atom "$append" :: args) ->
      let elems = List.concat_map args ~f:(fun a -> expect_list (eval_expr ctx env a)) in
      Raw.List elems
  | Raw.List (Raw.Atom "$car" :: [ x ]) -> (
      match expect_list (eval_expr ctx env x) with
      | h :: _ -> h
      | [] -> Raw.Atom "nil")
  | Raw.List (Raw.Atom "$cdr" :: [ x ]) -> (
      match expect_list (eval_expr ctx env x) with
      | _ :: tl -> Raw.List tl
      | [] -> Raw.List [])
  | Raw.List (Raw.Atom "$length" :: [ x ]) ->
      let len = List.length (expect_list (eval_expr ctx env x)) in
      Raw.Atom (Int.to_string len)
  | Raw.List (Raw.Atom "$reverse" :: [ x ]) ->
      Raw.List (List.rev (expect_list (eval_expr ctx env x)))
  | Raw.List (Raw.Atom "$nth" :: [ xs; idx ]) ->
      let arr = expect_list (eval_expr ctx env xs) in
      let i =
        match eval_expr ctx env idx with
        | Raw.Atom s -> Int.of_string s
        | _ -> fail "nth index must evaluate to atom/int"
      in
      (match List.nth arr i with
      | Some v -> v
      | None -> Raw.Atom "nil")
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
  | Raw.List xs -> Raw.List (List.map xs ~f:(eval_expr ctx env))

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

let parse_macro_def raw =
  let parse_params params =
    let rec loop fixed = function
      | [] -> (List.rev fixed, None)
      | "&rest" :: [ rest_name ] -> (List.rev fixed, Some rest_name)
      | "&rest" :: _ -> fail "&rest must be followed by exactly one parameter name"
      | p :: tl -> loop (p :: fixed) tl
    in
    loop [] params
  in
  match raw with
  | Raw.List (Raw.Atom "%defmacro" :: Raw.Atom name :: Raw.List params :: [ body ]) ->
      let params = List.map params ~f:expect_atom in
      let params, rest_param = parse_params params in
      { name; params; rest_param; body }
  | _ -> fail "Invalid %defmacro form; expected (%defmacro name (args...) body)"

let collect forms =
  let rec loop defs normal = function
    | [] ->
        ( { defs; max_depth = 200; gensym_counter = 0 },
          List.rev normal )
    | raw :: tl -> (
        match raw with
        | Raw.List (Raw.Atom "%defmacro" :: _) ->
            let m = parse_macro_def raw in
            if Map.mem defs m.name then failf "Duplicate %%defmacro: %s" m.name;
            loop (Map.set defs ~key:m.name ~data:m) normal tl
        | _ -> loop defs (raw :: normal) tl)
  in
  loop (String.Map.empty) [] forms

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
