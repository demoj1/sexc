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
  (* Имя %module текущей раскрываемой top-формы (или None). Ставится
     извне (compile_forms/metadata_of_file) ПЕРЕД раскрытием каждой формы,
     чтобы compile-time builtin [$qualify] мог квалифицировать метадату
     именем модуля. IR-имена квалифицирует отдельный пост-expand проход в
     compiler.ml — это разделение убирает зависимость макросов от
     пред-квалифицированных surface-имён. *)
  mutable current_module : string option;
  (* name_map (голое-имя → квалифицированное) текущего модуля. Ставится извне
     вместе с [current_module]; нужен builtin'у [$qualify-type], чтобы
     квалифицировать атомы-типы в ЗНАЧЕНИЯХ метадаты (:c-type/:fields/…) — IR
     квалифицируется отдельно проходом, но meta пишется на этапе раскрытия,
     поэтому типы в ней доквалифицируем здесь, по той же карте. *)
  mutable current_name_map : string String.Map.t;
  (* Span формы-вызова текущего раскрываемого макроса. Устанавливается
     [apply] перед выполнением тела макроса; используется
     [eval_quasiquote] чтобы помечать синтезированные узлы (которые иначе
     не имеют source-локации) call-site span'ом — ошибки во вложенных
     формах указывают на сам макровызов, а не на stdlib. *)
  mutable expand_site_span : Common.span option;
}

let evals_splice_tag = "__sexc_internal_evals_splice__"

let bool_raw b = if b then Raw.Atom ("t", None) else Raw.Atom ("nil", None)

let is_falsey = function
  | Raw.Atom ("nil", _) -> true
  | Raw.List ([], _) -> true
  | _ -> false

let rec raw_equal a b =
  match a, b with
  | Raw.Atom (x, _), Raw.Atom (y, _) -> String.equal x y
  | Raw.Str (x, _), Raw.Str (y, _) -> String.equal x y
  | Raw.List (xs, _), Raw.List (ys, _) ->
      List.length xs = List.length ys && List.for_all2_exn xs ys ~f:raw_equal
  | _ -> false

let expect_atom = function
  | Raw.Atom (s, _) -> s
  | _ -> fail "macro expected atom"

let expect_list = function
  | Raw.List (xs, _) -> xs
  | _ -> fail "macro expected list"

let expect_atom_or_string = function
  | Raw.Atom (s, _) | Raw.Str (s, _) -> s
  | _ -> fail "macro expected atom or string"

let is_evals_splice = function
  | Raw.List ([ Raw.Atom (tag, _); Raw.List (xs, _) ], _) when String.equal tag evals_splice_tag -> Some xs
  | _ -> None

let with_bound env names values =
  List.fold2_exn names values ~init:env ~f:(fun acc n v -> Map.set acc ~key:n ~data:v)

let gensym ctx prefix =
  let n = ctx.gensym_counter in
  ctx.gensym_counter <- ctx.gensym_counter + 1;
  Raw.Atom ((prefix ^ Int.to_string n), None)

let is_self_evaluating_atom a =
  String.equal a "nil"
  || String.equal a "t"
  || (not (String.is_empty a) && Char.equal a.[0] ':')
  || Option.is_some (Int.of_string_opt a)
  || Option.is_some (Float.of_string_opt a)

(* Квалификация имени текущим модулем: "Buffer" → "ring/Buffer". Идемпотентна
   (уже-"ring/…" не трогает), пропускает %/$-имена, вне модуля — no-op. Общая
   для builtin [$qualify] и для sum-конструкторного диспатча в [expand_one]. *)
let qualify_in_module module_opt s =
  match module_opt with
  | None -> s
  | Some _ when String.is_prefix s ~prefix:"%" || String.is_prefix s ~prefix:"$" -> s
  | Some m -> if String.is_prefix s ~prefix:(m ^ "/") then s else m ^ "/" ^ s

(* Обёртка: запоминает span текущей вычисляемой формы в Common.current_eval_span,
   чтобы bare Sexc_error из любого места eval_expr_inner promote'ился до точной
   локации подформы (а не до top-level формы). На исключении ref остаётся
   грязным намеренно — это самая глубокая форма на момент падения. *)
let rec eval_expr ctx env expr =
  let prev = !Common.current_eval_span in
  (match Raw.span_of expr with
   | Some _ as s -> Common.current_eval_span := s
   | None -> ());
  let r = eval_expr_inner ctx env expr in
  Common.current_eval_span := prev;
  r

and eval_expr_inner ctx env expr =
  match expr with
  | Raw.Atom (a, sp) -> (
      match Map.find env a with
      | Some v -> v
      | None when is_self_evaluating_atom a -> expr
      | None -> Common.failf_at ~phase:"macro-eval" sp "Unbound variable in macro eval: %s" a)
  | Raw.Str (_, _) -> expr
  | Raw.List ([], _) -> Raw.List ([], None)
  | Raw.List ((Raw.Atom ("quote", _) :: [ body ]), _) -> body
  | Raw.List ((Raw.Atom ("quote", _) :: _), _) -> fail "quote expects exactly one argument"
  | Raw.List ((Raw.Atom ("$quote", _) :: [ body ]), _) -> body
  | Raw.List ((Raw.Atom ("$quote", _) :: _), _) -> fail "$quote expects exactly one argument"
  | Raw.List ((Raw.Atom ("quasiquote", _) :: [ body ]), _) -> eval_quasiquote ctx env ~depth:1 body
  | Raw.List ((Raw.Atom ("$if", _) :: [ cond; yes; no ]), _) ->
      if is_falsey (eval_expr ctx env cond) then eval_expr ctx env no else eval_expr ctx env yes
  | Raw.List ((Raw.Atom ("$if", _) :: [ cond; yes ]), _) ->
      if is_falsey (eval_expr ctx env cond) then Raw.Atom ("nil", None) else eval_expr ctx env yes
  | Raw.List ((Raw.Atom ("$cond", _) :: clauses), _) -> eval_cond ctx env clauses
  | Raw.List ((Raw.Atom ("$case", _) :: scrut :: clauses), _) ->
      let v = eval_expr ctx env scrut in
      eval_case ctx env v clauses
  | Raw.List ((Raw.Atom ("$case", _) :: _), _) -> fail "$case expects: ($case scrutinee clause...)"
  | Raw.List ((Raw.Atom ("$cons", _) :: [ hd; tl ]), _) ->
      let h = eval_expr ctx env hd in
      let t = expect_list (eval_expr ctx env tl) in
      Raw.List ((h :: t), None)
  | Raw.List ((Raw.Atom ("$car", _) :: [ x ]), _) -> (
      match expect_list (eval_expr ctx env x) with
      | h :: _ -> h
      | [] -> Raw.Atom ("nil", None))
  | Raw.List ((Raw.Atom ("$cdr", _) :: [ x ]), _) -> (
      match expect_list (eval_expr ctx env x) with
      | _ :: tl -> Raw.List (tl, None)
      | [] -> Raw.List ([], None))
  | Raw.List ((Raw.Atom ("$null?", _) :: [ x ]), _) -> bool_raw (is_falsey (eval_expr ctx env x))
  | Raw.List ((Raw.Atom ("$atom?", _) :: [ x ]), _) -> (
      match eval_expr ctx env x with
      | Raw.Atom (_, _) | Raw.Str (_, _) -> bool_raw true
      | Raw.List (_, _) -> bool_raw false)
  | Raw.List ((Raw.Atom ("$eq?", _) :: [ a; b ]), _) ->
      bool_raw (raw_equal (eval_expr ctx env a) (eval_expr ctx env b))
  | Raw.List ((Raw.Atom ("$symcat", _) :: parts), _) ->
      let text =
        List.map parts ~f:(fun p -> eval_expr ctx env p |> expect_atom_or_string)
        |> String.concat ~sep:""
      in
      Raw.Atom (text, None)
  | Raw.List ((Raw.Atom ("$str", _) :: parts), _) ->
      let text =
        List.map parts ~f:(fun p -> eval_expr ctx env p |> expect_atom_or_string)
        |> String.concat ~sep:""
      in
      Raw.Str (text, None)
  | Raw.List ((Raw.Atom ("$namespace-of", _) :: [ x ]), _) ->
      (* "a/b/c" → "a/b"; "x" → nil. Split on LAST '/' — каждое имя
         попадает в свой непосредственный родительский namespace. *)
      let s = expect_atom_or_string (eval_expr ctx env x) in
      (match String.rsplit2 s ~on:'/' with
       | Some (prefix, _) -> Raw.Atom (prefix, None)
       | None -> Raw.Atom ("nil", None))
  | Raw.List ((Raw.Atom ("$namespace-of", _) :: _), _) ->
      fail "$namespace-of expects exactly one argument"
  | Raw.List ((Raw.Atom ("$current-module", _) :: []), _) ->
      (* Имя текущего %module ("ring") или nil вне модуля. *)
      (match ctx.current_module with
       | Some m -> Raw.Atom (m, None)
       | None -> Raw.Atom ("nil", None))
  | Raw.List ((Raw.Atom ("$current-module", _) :: _), _) ->
      fail "$current-module expects no arguments"
  | Raw.List ((Raw.Atom ("$qualify", _) :: [ x ]), _) ->
      (* Квалифицирует имя текущим модулем: "Buffer" → "ring/Buffer".
         Идемпотентно (уже-"ring/…" не трогает) и пропускает %/$-имена.
         Вне модуля — no-op. Используется макросами для ключей метадаты;
         IR квалифицирует отдельный проход в compiler.ml. *)
      let s = expect_atom_or_string (eval_expr ctx env x) in
      Raw.Atom (qualify_in_module ctx.current_module s, None)
  | Raw.List ((Raw.Atom ("$qualify", _) :: _), _) ->
      fail "$qualify expects exactly one argument"
  | Raw.List ((Raw.Atom ("$qualify-type", _) :: [ x ]), _) ->
      (* Квалифицирует атомы-ТИПЫ в форме именем текущего модуля по name_map:
         "Buffer" → "ring/Buffer", "(%ptr Buffer)" → "(%ptr ring/Buffer)".
         Встроенные/чужие типы (int, othermod/T) не в карте → не трогаются.
         Используется макросами ТОЛЬКО для значений метадаты; IR квалифицирует
         проход в compiler.ml. *)
      let nm = ctx.current_name_map in
      let qatom a =
        match Map.find nm a with
        | Some q -> q
        | None -> (
            match String.lsplit2 a ~on:'/' with
            | Some (base, rest) when Map.mem nm base -> Map.find_exn nm base ^ "/" ^ rest
            | _ -> a)
      in
      let rec go = function
        | Raw.Atom (a, _) -> Raw.Atom (qatom a, None)
        | Raw.Str (_, _) as s -> s
        | Raw.List (xs, _) -> Raw.List (List.map xs ~f:go, None)
      in
      go (eval_expr ctx env x)
  | Raw.List ((Raw.Atom ("$qualify-type", _) :: _), _) ->
      fail "$qualify-type expects exactly one argument"
  | Raw.List ((Raw.Atom ("$keyword?", _) :: [ x ]), _) ->
      (* true iff the value is an atom starting with ':' (a keyword like :x). *)
      (match eval_expr ctx env x with
       | Raw.Atom (a, _) -> bool_raw (String.is_prefix a ~prefix:":")
       | _ -> bool_raw false)
  | Raw.List ((Raw.Atom ("$keyword?", _) :: _), _) ->
      fail "$keyword? expects exactly one argument"
  | Raw.List ((Raw.Atom ("$keyword-name", _) :: [ x ]), _) ->
      (* ':x' → 'x'; drops a single leading ':'. Errors if not a keyword atom. *)
      let s = expect_atom_or_string (eval_expr ctx env x) in
      (match String.chop_prefix s ~prefix:":" with
       | Some name -> Raw.Atom (name, None)
       | None -> failf "$keyword-name expects a :keyword atom, got %s" s)
  | Raw.List ((Raw.Atom ("$keyword-name", _) :: _), _) ->
      fail "$keyword-name expects exactly one argument"
  | Raw.List ((Raw.Atom ("$let", _) :: Raw.List (binds, _) :: body), _) ->
      let rec bind env = function
        | [] -> env
        | Raw.List ([ Raw.Atom (name, _); value_expr ], _) :: tl ->
            let value = eval_expr ctx env value_expr in
            bind (Map.set env ~key:name ~data:value) tl
        | _ -> fail "$let bindings must be pairs: ((name expr) ...)"
      in
      let env = bind env binds in
      let rec eval_last = function
        | [] -> Raw.Atom ("nil", None)
        | [ x ] -> eval_expr ctx env x
        | x :: tl ->
            ignore (eval_expr ctx env x);
            eval_last tl
      in
      eval_last body
  | Raw.List ((Raw.Atom ("$for", _) :: [ Raw.List ([ Raw.Atom (var, _); xs ], _); body ]), _) ->
      let values = expect_list (eval_expr ctx env xs) in
      Raw.List
        ((List.map values ~f:(fun v ->
             let env = Map.set env ~key:var ~data:v |> Map.set ~key:"it" ~data:v in
             eval_expr ctx env body)), None)
  | Raw.List ((Raw.Atom ("$for", _) :: _), _) ->
      fail "$for expects ($for (var list-expr) body)"
  | Raw.List ((Raw.Atom ("$map", _) :: args), _) -> eval_expr ctx env (Raw.List ((Raw.Atom ("$--map", None) :: args), None))
  | Raw.List ((Raw.Atom ("$filter", _) :: args), _) ->
      eval_expr ctx env (Raw.List ((Raw.Atom ("$--filter", None) :: args), None))
  | Raw.List ((Raw.Atom ("$reduce", _) :: args), _) ->
      eval_expr ctx env (Raw.List ((Raw.Atom ("$--reduce", None) :: args), None))
  | Raw.List ((Raw.Atom ("$--map", _) :: [ mapper; xs ]), _) ->
      let values = expect_list (eval_expr ctx env xs) in
      Raw.List
        ((List.map values ~f:(fun v ->
             let env = Map.set env ~key:"it" ~data:v in
             eval_expr ctx env mapper)), None)
  | Raw.List ((Raw.Atom ("$--filter", _) :: [ pred; xs ]), _) ->
      let values = expect_list (eval_expr ctx env xs) in
      Raw.List
        ((List.filter values ~f:(fun v ->
             let env = Map.set env ~key:"it" ~data:v in
             not (is_falsey (eval_expr ctx env pred)))), None)
  | Raw.List ((Raw.Atom ("$--reduce", _) :: [ reducer; init; xs ]), _) ->
      let values = expect_list (eval_expr ctx env xs) in
      let acc0 = eval_expr ctx env init in
      List.fold values ~init:acc0 ~f:(fun acc v ->
          let env = Map.set env ~key:"it" ~data:v |> Map.set ~key:"acc" ~data:acc in
          eval_expr ctx env reducer)
  | Raw.List ((Raw.Atom ("$dolist", _) :: [ Raw.List ([ Raw.Atom (var, _); xs ], _); body ]), _) ->
      let values = expect_list (eval_expr ctx env xs) in
      Raw.List
        ((List.map values ~f:(fun v ->
             let env = Map.set env ~key:var ~data:v in
             eval_expr ctx env body)), None)
  | Raw.List ((Raw.Atom ("$dolist", _) :: _), _) ->
      fail "$dolist expects ($dolist (var list-expr) body)"
  | Raw.List ((Raw.Atom ("$error", _) :: [ msg ]), _) ->
      let text =
        match eval_expr ctx env msg with
        | Raw.Atom (s, _) | Raw.Str (s, _) -> s
        | _ -> "macro error"
      in
      fail text
  | Raw.List ((Raw.Atom ("$gensym", _) :: []), _) -> gensym ctx "__g"
  | Raw.List ((Raw.Atom ("$gensym", _) :: [ prefix ]), _) ->
      let p =
        match eval_expr ctx env prefix with
        | Raw.Atom (s, _) | Raw.Str (s, _) -> s
        | _ -> fail "gensym prefix must evaluate to atom or string"
      in
      gensym ctx p
  | Raw.List ((Raw.Atom ("$not", _) :: [ x ]), _) ->
      bool_raw (is_falsey (eval_expr ctx env x))
  | Raw.List ((Raw.Atom ("$not", _) :: _), _) -> fail "$not expects exactly one argument"
  | Raw.List ((Raw.Atom ("$do", _) :: exprs), _) ->
      List.fold exprs ~init:(Raw.Atom ("nil", None)) ~f:(fun _ e -> eval_expr ctx env e)
  | Raw.List ((Raw.Atom ("$assert", _) :: [ cond; msg ]), _) ->
      if is_falsey (eval_expr ctx env cond) then
        let text =
          match eval_expr ctx env msg with
          | Raw.Atom (s, _) | Raw.Str (s, _) -> s
          | _ -> "assertion failed"
        in
        fail text
      else Raw.Atom ("nil", None)
  | Raw.List ((Raw.Atom ("$assert", _) :: _), _) ->
      fail "$assert expects exactly two arguments: ($assert cond message)"
  | Raw.List ((Raw.Atom (arith, _) :: [ a; b ]), _)
    when List.mem [ "$+"; "$-"; "$*"; "$/" ] arith ~equal:String.equal ->
      let to_int e =
        match eval_expr ctx env e with
        | Raw.Atom (s, _) -> (
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
      Raw.Atom ((Int.to_string result), None)
  | Raw.List ((Raw.Atom (arith, _) :: _), _)
    when List.mem [ "$+"; "$-"; "$*"; "$/" ] arith ~equal:String.equal ->
      failf "%s expects exactly two arguments" arith
  (* Числовые предикаты на compile-time целых — мета-зеркала surface-предикатов
     zero?/ltz?/letz?/gtz?/getz?/pos?/neg?/nonzero?/even?/odd?. Аргумент должен
     вычисляться в целочисленный атом. *)
  | Raw.List ((Raw.Atom (pred, _) :: [ x ]), _)
    when List.mem
           [ "$zero?"; "$nonzero?"; "$pos?"; "$neg?"; "$ltz?"; "$letz?";
             "$gtz?"; "$getz?"; "$even?"; "$odd?" ] pred ~equal:String.equal ->
      let n =
        match eval_expr ctx env x with
        | Raw.Atom (s, _) -> (
            match Int.of_string_opt s with
            | Some n -> n
            | None -> failf "%s: argument is not an integer: %s" pred s)
        | _ -> failf "%s: argument must be an integer atom" pred
      in
      let b =
        match pred with
        | "$zero?" -> Int.equal n 0
        | "$nonzero?" -> not (Int.equal n 0)
        | "$pos?" | "$gtz?" -> n > 0
        | "$neg?" | "$ltz?" -> n < 0
        | "$letz?" -> n <= 0
        | "$getz?" -> n >= 0
        | "$even?" -> Int.equal (Int.rem n 2) 0
        | "$odd?" -> not (Int.equal (Int.rem n 2) 0)
        | _ -> assert false
      in
      bool_raw b
  | Raw.List ((Raw.Atom (pred, _) :: _), _)
    when List.mem
           [ "$zero?"; "$nonzero?"; "$pos?"; "$neg?"; "$ltz?"; "$letz?";
             "$gtz?"; "$getz?"; "$even?"; "$odd?" ] pred ~equal:String.equal ->
      failf "%s expects exactly one argument" pred
  (* nil-предикаты на мета-значениях (falsey = nil/пустой список), зеркала
     surface nil?/not-nil?. $null? — исходное имя, $nil? — алиас. *)
  | Raw.List ((Raw.Atom ("$nil?", _) :: [ x ]), _) -> bool_raw (is_falsey (eval_expr ctx env x))
  | Raw.List ((Raw.Atom ("$nil?", _) :: _), _) -> fail "$nil? expects exactly one argument"
  | Raw.List ((Raw.Atom ("$not-nil?", _) :: [ x ]), _) ->
      bool_raw (not (is_falsey (eval_expr ctx env x)))
  | Raw.List ((Raw.Atom ("$not-nil?", _) :: _), _) -> fail "$not-nil? expects exactly one argument"
  | Raw.List ((Raw.Atom ("$|>", _) :: init :: forms), _) ->
      let thread acc form =
        match form with
        | Raw.Atom (_, _) -> Raw.List ([ form; acc ], None)
        | Raw.List ((f :: args), _) -> Raw.List ((f :: acc :: args), None)
        | _ -> fail "$|> each step must be a symbol or (f arg...) list"
      in
      eval_expr ctx env (List.fold forms ~init ~f:thread)
  | Raw.List ((Raw.Atom ("$|>", _) :: _), _) -> fail "$|> expects at least one argument"
  | Raw.List ((Raw.Atom ("$||>", _) :: init :: forms), _) ->
      let thread acc form =
        match form with
        | Raw.Atom (_, _) -> Raw.List ([ form; acc ], None)
        | Raw.List (fs, _) -> Raw.List ((fs @ [ acc ]), None)
        | _ -> fail "$||> each step must be a symbol or list"
      in
      eval_expr ctx env (List.fold forms ~init ~f:thread)
  | Raw.List ((Raw.Atom ("$||>", _) :: _), _) -> fail "$||> expects at least one argument"
  | Raw.List ((Raw.Atom ("$|as>", _) :: init :: Raw.Atom (binding, _) :: forms), _) ->
      let rec loop v = function
        | [] -> v
        | form :: tl ->
            let env' = Map.set env ~key:binding ~data:v in
            loop (eval_expr ctx env' form) tl
      in
      loop (eval_expr ctx env init) forms
  | Raw.List ((Raw.Atom ("$|as>", _) :: _), _) ->
      fail "$|as> expects: ($|as> init binding-name form...)"
  | Raw.List ((Raw.Atom (legacy, _) :: _), _)
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
  | Raw.List ((Raw.Atom ("$m-put", _) :: sym_expr :: rest), _) ->
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
      Raw.Atom ("nil", None)
  | Raw.List ((Raw.Atom ("$m-put", _) :: _), _) ->
      fail "$m-put expects: ($m-put sym key1 val1 key2 val2 ...)"
  | Raw.List ((Raw.Atom ("$m-get", _) :: [ sym_expr; key_expr ]), _) -> (
      let sym_name = expect_atom (eval_expr ctx env sym_expr) in
      let key = expect_atom_or_string (eval_expr ctx env key_expr) in
      match Map.find ctx.sym_meta sym_name with
      | None -> Raw.Atom ("nil", None)
      | Some m -> Option.value (Map.find m key) ~default:(Raw.Atom ("nil", None)))
  | Raw.List ((Raw.Atom ("$m-get", _) :: _), _) ->
      fail "$m-get expects exactly two arguments: ($m-get sym key)"
  | Raw.List ((Raw.Atom (fn_name, _) :: args), _) when Map.mem ctx.ct_fns fn_name ->
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
              ~key:rest_name ~data:(Raw.List (rest_args, None))
      in
      eval_expr ctx call_env f.body
  | Raw.List (xs, _) -> Raw.List ((List.map xs ~f:(eval_expr ctx env)), None)

and eval_body_last ctx env = function
  | [] -> Raw.Atom ("nil", None)
  | [ x ] -> eval_expr ctx env x
  | x :: tl ->
      ignore (eval_expr ctx env x);
      eval_body_last ctx env tl

and eval_cond ctx env = function
  | [] -> Raw.Atom ("nil", None)
  | Raw.List ((Raw.Atom ("else", _) :: body), _) :: rest ->
      if not (List.is_empty rest) then fail "$cond: else must be the last clause";
      if List.is_empty body then fail "$cond: else clause must have a body";
      eval_body_last ctx env body
  | Raw.List ((test :: body), _) :: rest ->
      if List.is_empty body then fail "$cond: clause must have a body";
      if is_falsey (eval_expr ctx env test) then eval_cond ctx env rest
      else eval_body_last ctx env body
  | Raw.List ([], _) :: _ -> fail "$cond: clause must be (test body...) or (else body...)"
  | _ -> fail "$cond: each clause must be a list"

and eval_case ctx env scrutinee = function
  | [] -> Raw.Atom ("nil", None)
  | Raw.List ((Raw.Atom ("else", _) :: body), _) :: rest ->
      if not (List.is_empty rest) then fail "$case: else must be the last clause";
      if List.is_empty body then fail "$case: else clause must have a body";
      eval_body_last ctx env body
  | Raw.List ((pattern :: body), _) :: rest ->
      if List.is_empty body then fail "$case: clause must have a body";
      let pv = eval_expr ctx env pattern in
      if raw_equal scrutinee pv then eval_body_last ctx env body
      else eval_case ctx env scrutinee rest
  | Raw.List ([], _) :: _ -> fail "$case: clause must be (pattern body...) or (else body...)"
  | _ -> fail "$case: each clause must be a list"

and eval_quasiquote ctx env ~depth expr =
  let sp = ctx.expand_site_span in
  match expr with
  | Raw.List ([ Raw.Atom ("unquote", _); x ], _) ->
      if depth = 1 then eval_expr ctx env x
      else Raw.List ([ Raw.Atom ("unquote", sp); eval_quasiquote ctx env ~depth:(depth - 1) x ], sp)
  | Raw.List ([ Raw.Atom ("splice", _); x ], _) ->
      if depth = 1 then fail "splice is only valid inside list in quasiquote"
      else Raw.List ([ Raw.Atom ("splice", sp); eval_quasiquote ctx env ~depth:(depth - 1) x ], sp)
  | Raw.List ([ Raw.Atom ("quasiquote", _); x ], _) ->
      Raw.List ([ Raw.Atom ("quasiquote", sp); eval_quasiquote ctx env ~depth:(depth + 1) x ], sp)
  | Raw.List (xs, _) -> Raw.List ((eval_qq_list ctx env ~depth xs), sp)
  | Raw.Atom _ | Raw.Str _ ->
      (* Атомы/строки внутри quasiquote — это литералы из тела макроса
         (stdlib). Привязываем их к call-site, чтобы ошибки указывали
         на пользовательский код, а не на stdlib. *)
      Raw.with_span sp expr

and eval_qq_list ctx env ~depth xs =
  List.concat_map xs ~f:(fun item ->
      match item with
      | Raw.List ([ Raw.Atom ("splice", _); x ], _) when depth = 1 ->
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
  | Raw.List ((Raw.Atom ("%defmacro", _) :: Raw.Atom (name, _) :: Raw.List (params, _) :: [ body ]), _) ->
      let params = List.map params ~f:expect_atom in
      let params, rest_param = parse_params params in
      { name; params; rest_param; body }
  | _ -> fail "Invalid %defmacro form; expected (%defmacro name (args...) body)"

let parse_ct_fn_def raw =
  match raw with
  | Raw.List ((Raw.Atom ("$defun", _) :: Raw.Atom (name, _) :: Raw.List (params, _) :: body), _) ->
      let params = List.map params ~f:expect_atom in
      let params, rest_param = parse_params params in
      let body =
        match body with
        | [ single ] -> single
        | _ -> Raw.List ((Raw.Atom ("$do", None) :: body), None)
      in
      { name; params; rest_param; body }
  | _ -> fail "Invalid $defun form; expected ($defun name (params...) body...)"

let rec raw_to_sexp = function
  | Raw.Atom (s, _) -> s
  | Raw.Str (s, _) -> "\"" ^ s ^ "\""
  | Raw.List (xs, _) ->
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
  | Raw.Atom (s, _) -> Printf.sprintf "\"%s\"" (json_escape s)
  | Raw.Str (s, _) -> Printf.sprintf "{\"str\":\"%s\"}" (json_escape s)
  | Raw.List (xs, _) ->
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
        ( { defs; ct_fns; max_depth = 200; gensym_counter = 0; sym_meta = String.Map.empty; current_module = None; current_name_map = String.Map.empty; expand_site_span = None },
          List.rev normal )
    | raw :: tl -> (
        match raw with
        | Raw.List ((Raw.Atom ("%defmacro", _) :: _), _) ->
            let m = parse_macro_def raw in
            if Map.mem defs m.name then failf "Duplicate %%defmacro: %s" m.name;
            loop (Map.set defs ~key:m.name ~data:m) ct_fns normal tl
        | Raw.List ((Raw.Atom ("$defun", _) :: _), _) ->
            let f = parse_ct_fn_def raw in
            if Map.mem ct_fns f.name then failf "Duplicate $defun: %s" f.name;
            loop defs (Map.set ct_fns ~key:f.name ~data:f) normal tl
        | _ -> loop defs ct_fns (raw :: normal) tl)
  in
  loop String.Map.empty String.Map.empty [] forms

let apply ctx depth m ~call_span args =
  Common.with_macro_context m.name (fun () ->
    let prev_site = ctx.expand_site_span in
    ctx.expand_site_span <- (match call_span with Some _ -> call_span | None -> prev_site);
    let fixed_len = List.length m.params in
    let env =
      match m.rest_param with
      | None ->
          if List.length args <> fixed_len then
            Common.failf_at ~phase:"macro" ctx.expand_site_span
              "Macro %s expects %d arguments, got %d" m.name fixed_len (List.length args);
          with_bound String.Map.empty m.params args
      | Some rest_name ->
          if List.length args < fixed_len then
            Common.failf_at ~phase:"macro" ctx.expand_site_span
              "Macro %s expects at least %d arguments, got %d" m.name fixed_len (List.length args);
          let fixed_args = List.take args fixed_len in
          let rest_args = List.drop args fixed_len in
          Map.set (with_bound String.Map.empty m.params fixed_args) ~key:rest_name ~data:(Raw.List (rest_args, ctx.expand_site_span))
    in
    let expanded = eval_expr ctx env m.body in
    if depth > ctx.max_depth then
      Common.failf_at ~phase:"macro" ctx.expand_site_span
        "Macro expansion exceeded max depth (%d)" ctx.max_depth;
    ctx.expand_site_span <- prev_site;
    expanded)

(* `obj::method` — инфиксный сахар метод-вызова. Атом, содержащий `::` (не в
   начале и не в конце), режется на объект и метод. `::` нигде больше в атомах не
   используется (namespace через `/`, keywords через одиночный `:`), поэтому
   трактовка однозначна. *)
let split_method_atom s =
  match String.substr_index s ~pattern:"::" with
  | Some i when i > 0 && i + 2 < String.length s ->
      Some (String.sub s ~pos:0 ~len:i, String.sub s ~pos:(i + 2) ~len:(String.length s - i - 2))
  | _ -> None

(* Собрать форму примитива `(%send obj method args...)`. Резолв типа объекта в
   `Type/method` делает stdlib-макрос `%send`; ядро только разбирает синтаксис. *)
let make_send obj meth args sp =
  Raw.List (Raw.Atom ("%send", None) :: Raw.Atom (obj, None) :: Raw.Atom (meth, None) :: args, sp)

let rec expand_eval_form_for_arg ctx ~depth = function
  | Raw.List ((Raw.Atom ("%eval", _) :: [ expr ]), _) ->
      let out = eval_expr ctx String.Map.empty expr in
      [ expand_one ctx ~depth:(depth + 1) out ]
  | Raw.List ((Raw.Atom ("%eval", _) :: _), _) -> fail "%eval expects exactly one argument"
  | Raw.List ((Raw.Atom ("%evals", _) :: [ expr ]), _) ->
      let out = eval_expr ctx String.Map.empty expr in
      let items = expect_list out in
      List.map items ~f:(fun item -> expand_one ctx ~depth:(depth + 1) item)
  | Raw.List ((Raw.Atom ("%evals", _) :: _), _) -> fail "%evals expects exactly one argument"
  (* `obj::method`-атом как аргумент макроса раскрываем в СЫРОЙ `(%send ...)` (без
     резолва) — чтобы макрос (напр. defer1) мог его распознать и обработать особо.
     Макросы, просто сплайсящие аргумент в выхлоп, до-раскроют `%send` потом. *)
  | Raw.Atom (a, sp) when Option.is_some (split_method_atom a) ->
      (match split_method_atom a with
       | Some (obj, meth) -> [ make_send obj meth [] sp ]
       | None -> assert false)
  | other -> [ other ]

and expand_eval_args_for_macro ctx ~depth xs =
  List.concat_map xs ~f:(fun x -> expand_eval_form_for_arg ctx ~depth x)

and expand_one ctx ~depth raw =
  if depth > ctx.max_depth then failf "Macro expansion exceeded max depth (%d)" ctx.max_depth;
  match raw with
  | Raw.Atom (a, sp) -> (
      (* одиночный `obj::method` (как стейтмент или подвыражение) → метод-вызов *)
      match split_method_atom a with
      | Some (obj, meth) -> expand_one ctx ~depth:(depth + 1) (make_send obj meth [] sp)
      | None -> raw)
  | Raw.Str (_, _) -> raw
  | Raw.List ([], _) -> raw
  | Raw.List ((Raw.Atom ("quote", _) :: _), _) -> raw
  | Raw.List ((Raw.Atom ("quasiquote", _) :: _), _) -> raw
  | Raw.List ((Raw.Atom ("%eval", _) :: [ expr ]), _) ->
      let out = eval_expr ctx String.Map.empty expr in
      expand_one ctx ~depth:(depth + 1) out
  | Raw.List ((Raw.Atom ("%eval", _) :: _), _) ->
      fail "%eval expects exactly one argument"
  | Raw.List ((Raw.Atom ("%evals", _) :: [ expr ]), _) ->
      let out = eval_expr ctx String.Map.empty expr in
      let items = expect_list out in
      let items = List.map items ~f:(fun item -> expand_one ctx ~depth:(depth + 1) item) in
      Raw.List ([ Raw.Atom (evals_splice_tag, None); Raw.List (items, None) ], None)
  | Raw.List ((Raw.Atom ("%evals", _) :: _), _) ->
      fail "%evals expects exactly one argument"
  | Raw.List ([ Raw.Atom ("%m-dump", _) ], _) ->
      Raw.List
        ([ Raw.Atom ("%comment", None); Raw.Str ((format_meta_dump ctx.sym_meta), None) ], None)
  | Raw.List ((Raw.Atom ("%m-dump", _) :: _), _) ->
      fail "%m-dump takes no arguments"
  | Raw.List ((Raw.Atom (head, _) :: args), list_sp)
    when String.length head > 1 && String.is_suffix head ~suffix:"#" ->
      (* `#` — конвенция конструктора. Два режима, разводятся по compile-time
         метадате базы (имени без #):
         - sum-вариант (есть :sum-of) → делегируем sexc-макросу `sum-construct`,
           который читает :sum-of/:member и собирает тегированный литерал;
         - иначе generic Type#: (Foo# args...) → (cast Foo (init args...)).
         База квалифицируется текущим модулем (как defsum писал ключи метадаты);
         %-IR проход доквалифицирует bare-имена в выхлопе. *)
      let base = String.drop_suffix head 1 in
      let qbase = qualify_in_module ctx.current_module base in
      let is_sum key =
        match Map.find ctx.sym_meta key with
        | Some m -> Map.mem m ":sum-of"
        | None -> false
      in
      let out =
        if is_sum qbase then
          Raw.List (Raw.Atom ("sum-construct", None) :: Raw.Atom (qbase, None) :: args, list_sp)
        else if is_sum base then
          Raw.List (Raw.Atom ("sum-construct", None) :: Raw.Atom (base, None) :: args, list_sp)
        else
          Raw.List
            ([ Raw.Atom ("cast", None);
               Raw.Atom (base, None);
               Raw.List (Raw.Atom ("init", None) :: args, None) ], list_sp)
      in
      expand_one ctx ~depth:(depth + 1) out
  | Raw.List ((Raw.Atom (head, head_sp) :: args), list_sp) -> (
      match Map.find ctx.defs head with
      | Some m ->
          let args = expand_eval_args_for_macro ctx ~depth args in
          (* call-site span: предпочитаем span самого списка-вызова (он покрывает
             всю форму (macro arg1 arg2 ...)), иначе span head-атома. *)
          let call_span = match list_sp with Some _ -> list_sp | None -> head_sp in
          let out = apply ctx (depth + 1) m ~call_span args in
          expand_one ctx ~depth:(depth + 1) out
      | None when Option.is_some (split_method_atom head) ->
          (* `(obj::method args...)` — инфиксный метод-вызов в голове формы. *)
          let obj, meth = Option.value_exn (split_method_atom head) in
          expand_one ctx ~depth:(depth + 1) (make_send obj meth args list_sp)
      | None when String.is_prefix head ~prefix:"$" ->
          (* `$`-форма в обычной (рантайм) позиции — это compile-time мета:
             builtin ($assert, $symcat, ...) или пользовательская $defun. Авто-
             вычисляем как неявный %eval и раскрываем результат. Раньше такие
             формы молча утекали в codegen мэнглеными вызовами (_u0024_...) и
             падали в gcc; теперь либо вычисляются, либо дают внятную мета-
             ошибку (напр. Unbound variable на рантайм-переменной). *)
          let out = eval_expr ctx String.Map.empty raw in
          expand_one ctx ~depth:(depth + 1) out
      | None -> Raw.List ((Raw.Atom (head, head_sp) :: expand_list_items ctx ~depth args), list_sp))
  (* Список, голова которого не атом (напр. ((%ptr char) name) — поле struct).
     Сохраняем span — это форма из исходника, её локация нужна для #line. *)
  | Raw.List (xs, sp) -> Raw.List ((expand_list_items ctx ~depth xs), sp)

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
