open Core
open Common
open Frontend

(*
   Code generator: frontend AST -> C source text.

   Responsibilities:
   - emit C declarations/types/statements/expressions
   - apply identifier mangling for non-C-safe symbols
   - preserve expression precedence with minimal parentheses

   Extension point:
   - Add emission for new AST constructors here.
   - Keep mangling and literal handling centralized in this module.

   Data flow:
   Frontend AST [top]
     -> [emit_top]
     -> [emit_stmt]/[emit_expr]/[emit_decl_of_type]
     -> final C text

   Invariant:
   - all user-facing identifiers pass through [mangle_ident] before output.
*)

let is_ascii_letter c =
  Char.(c >= 'a' && c <= 'z') || Char.(c >= 'A' && c <= 'Z')

let is_digit c = Char.(c >= '0' && c <= '9')

let is_ident_start c = is_ascii_letter c || Char.equal c '_'

let is_ident_continue c = is_ident_start c || is_digit c

let is_c_number_char = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | 'x' | 'X' | 'p' | 'P' | '.' | '+' | '-' | 'u' | 'U'
  | 'l' | 'L' -> true
  | _ -> false

let is_number_literal s =
  let n = String.length s in
  if n = 0 then false
  else
    let start =
      if n > 1 && (Char.equal s.[0] '+' || Char.equal s.[0] '-') then 1 else 0
    in
    if start >= n then false
    else
      let has_digit = ref false in
      let ok =
        String.for_alli s ~f:(fun i c ->
            if i < start then true
            else (
              if Char.(c >= '0' && c <= '9') then has_digit := true;
              is_c_number_char c))
      in
      ok && !has_digit

let mangle_ident raw =
  if String.is_empty raw then raw
  else
    let b = Buffer.create (String.length raw + 16) in
    String.iter raw ~f:(fun c ->
        if is_ident_continue c then Buffer.add_char b c
        else Buffer.add_string b (Printf.sprintf "_u%04X_" (Char.to_int c)));
    let out = Buffer.contents b in
    if String.is_empty out then "sx_"
    else
      let first = out.[0] in
      if is_ident_start first then out else "sx_" ^ out

let atom_to_c_token a = if is_number_literal a then a else mangle_ident a

let storage_to_c = function
  | Extern -> "extern"
  | Static -> "static"
  | Register -> "register"
  | Auto -> "auto"
  | Typedef -> "typedef"

let qual_to_c = function
  | Const -> "const"
  | Volatile -> "volatile"
  | Restrict -> "restrict"

let rec emit_type_base = function
  | TBuiltin s -> s
  | TNamed s -> mangle_ident s
  | TStruct (name, None) -> "struct " ^ mangle_ident name
  | TUnion (name, None) -> "union " ^ mangle_ident name
  | TEnum name -> "enum " ^ mangle_ident name
  | TStruct (name, Some fields) ->
      let body =
        List.map fields ~f:(fun f -> "  " ^ emit_decl_of_type f.f_ty (mangle_ident f.f_name) ^ ";")
        |> String.concat ~sep:"\n"
      in
      "struct " ^ mangle_ident name ^ " {\n" ^ body ^ "\n}"
  | TUnion (name, Some fields) ->
      let body =
        List.map fields ~f:(fun f -> "  " ^ emit_decl_of_type f.f_ty (mangle_ident f.f_name) ^ ";")
        |> String.concat ~sep:"\n"
      in
      "union " ^ mangle_ident name ^ " {\n" ^ body ^ "\n}"
  | _ -> fail "emit_type_base received non-base type"

and emit_decl_of_type tyv name =
  match tyv with
  | TPtr (quals, inner) ->
      let q =
        if List.is_empty quals then ""
        else " " ^ (List.map quals ~f:qual_to_c |> String.concat ~sep:" ") ^ " "
      in
      let raw_name = "*" ^ q ^ name in
      let wrapped_name =
        match inner with
        | TArray _ | TFn _ -> "(" ^ raw_name ^ ")"
        | _ -> raw_name
      in
      emit_decl_of_type inner wrapped_name
  | TArray (inner, n) ->
      let suffix =
        match n with
        | None -> "[]"
        | Some k -> "[" ^ Int.to_string k ^ "]"
      in
      emit_decl_of_type inner (name ^ suffix)
  | TFn (ret, args, varargs) ->
      let params =
        let arg_s = List.map args ~f:(fun t -> emit_decl_of_type t "") in
        let arg_s = if List.is_empty arg_s then [ "void" ] else arg_s in
        if varargs then arg_s @ [ "..." ] else arg_s
      in
      emit_decl_of_type ret (name ^ "(" ^ String.concat ~sep:", " params ^ ")")
  | TQual (q, inner) -> qual_to_c q ^ " " ^ emit_decl_of_type inner name
  | _ ->
      let b = emit_type_base tyv in
      if String.is_empty name then b else b ^ " " ^ name

let emit_decl_signature d =
  let stor =
    if List.is_empty d.d_storage then ""
    else (List.map d.d_storage ~f:storage_to_c |> String.concat ~sep:" ") ^ " "
  in
  stor ^ emit_decl_of_type d.d_ty (mangle_ident d.d_name)

let c_escape_string s =
  let b = Buffer.create (String.length s + 8) in
  String.iter s ~f:(function
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c -> Buffer.add_char b c);
  Buffer.contents b

let precedence_of_expr = function
  | EComma _ -> 1
  | EAssign _ -> 2
  | ETernary _ -> 3
  | ENary ("||", _) -> 4
  | ENary ("&&", _) -> 5
  | ENary ("|", _) -> 6
  | ENary ("^", _) -> 7
  | ENary ("&", _) -> 8
  | ENary (("==" | "!="), _) -> 9
  | ENary (("<" | "<=" | ">" | ">="), _) -> 10
  | ENary (("<<" | ">>"), _) -> 11
  | ENary (("+" | "-"), _) -> 12
  | ENary (("*" | "/" | "%"), _) -> 13
  | ENary _ -> 12
  | EUnary _ | ECast _ | ESizeofType _ | ESizeofExpr _ -> 14
  | EPostfix _ | ECall _ | EIndex _ | EMember _ | EPtrMember _ | ECompoundLiteral _ -> 15
  | EAtom _ | EString _ | ERaw _ -> 16

let rec emit_expr ?(ctx = 0) e =
  let p = precedence_of_expr e in
  let body =
    match e with
    | EAtom a -> atom_to_c_token a
    | EString s -> "\"" ^ c_escape_string s ^ "\""
    | ERaw parts ->
        let emit_part = function
          | RawText s -> s
          | RawExpr x -> emit_expr x
        in
        List.map parts ~f:emit_part |> String.concat ~sep:""
    | EUnary (op, x) -> op ^ emit_expr ~ctx:p x
    | EPostfix (op, x) -> emit_expr ~ctx:p x ^ op
    | ENary (op, xs) ->
        List.map xs ~f:(emit_expr ~ctx:p)
        |> String.concat ~sep:(" " ^ op ^ " ")
    | EAssign (op, l, r) -> emit_expr ~ctx:p l ^ " " ^ op ^ " " ^ emit_expr ~ctx:p r
    | ECast (t, x) -> "(" ^ emit_decl_of_type t "" ^ ")" ^ emit_expr ~ctx:p x
    | ESizeofType t -> "sizeof(" ^ emit_decl_of_type t "" ^ ")"
    | ESizeofExpr x -> "sizeof(" ^ emit_expr x ^ ")"
    | ETernary (c, t, f) ->
        emit_expr ~ctx:p c ^ " ? " ^ emit_expr ~ctx:p t ^ " : " ^ emit_expr ~ctx:p f
    | EComma xs -> List.map xs ~f:(emit_expr ~ctx:p) |> String.concat ~sep:", "
    | EIndex (a, i) -> emit_expr ~ctx:p a ^ "[" ^ emit_expr i ^ "]"
    | EMember (x, f) -> emit_expr ~ctx:p x ^ "." ^ mangle_ident f
    | EPtrMember (x, f) -> emit_expr ~ctx:p x ^ "->" ^ mangle_ident f
    | ECompoundLiteral (tyv, inits) ->
        let emit_init = function
          | InitExpr x -> emit_expr x
          | InitField (field, value) -> "." ^ mangle_ident field ^ " = " ^ emit_expr value
        in
        "(" ^ emit_decl_of_type tyv "" ^ "){ "
        ^ (List.map inits ~f:emit_init |> String.concat ~sep:", ")
        ^ " }"
    | ECall (callee, args) ->
        emit_expr ~ctx:p callee ^ "(" ^ (List.map args ~f:emit_expr |> String.concat ~sep:", ") ^ ")"
  in
  if p < ctx then "(" ^ body ^ ")" else body

let indent n = String.make n ' '

let emit_decl_stmt d =
  let sig_s = emit_decl_signature d in
  match d.d_init with
  | None -> sig_s ^ ";"
  | Some init -> sig_s ^ " = " ^ emit_expr init ^ ";"

let emit_for_init = function
  | FNone -> ""
  | FExpr e -> emit_expr e
  | FDecl d ->
      let sig_s = emit_decl_signature d in
      (match d.d_init with
      | None -> sig_s
      | Some init -> sig_s ^ " = " ^ emit_expr init)

let rec emit_stmt ?(lvl = 0) s =
  let i = indent lvl in
  match s with
  | SNop -> i ^ ";"
  | SBlock stmts ->
      let body = List.map stmts ~f:(fun st -> emit_stmt ~lvl:(lvl + 2) st) |> String.concat ~sep:"\n" in
      i ^ "{\n" ^ body ^ "\n" ^ i ^ "}"
  | SIf (cond, t, None) ->
      i ^ "if (" ^ emit_expr cond ^ ")\n" ^ emit_stmt ~lvl:(lvl + 2) t
  | SIf (cond, t, Some e) ->
      i ^ "if (" ^ emit_expr cond ^ ")\n" ^ emit_stmt ~lvl:(lvl + 2) t ^ "\n"
      ^ i ^ "else\n" ^ emit_stmt ~lvl:(lvl + 2) e
  | SWhile (cond, body) ->
      i ^ "while (" ^ emit_expr cond ^ ")\n" ^ emit_stmt ~lvl:(lvl + 2) body
  | SDoWhile (cond, body) ->
      i ^ "do\n" ^ emit_stmt ~lvl:(lvl + 2) body ^ "\n" ^ i ^ "while (" ^ emit_expr cond ^ ");"
  | SFor (init, cond, step, body) ->
      let c = Option.value_map cond ~default:"" ~f:emit_expr in
      let st = Option.value_map step ~default:"" ~f:emit_expr in
      i ^ "for (" ^ emit_for_init init ^ "; " ^ c ^ "; " ^ st ^ ")\n" ^ emit_stmt ~lvl:(lvl + 2) body
  | SSwitch (e, clauses) ->
      let clause_to_c = function
        | Case (c, body) ->
            let b = List.map body ~f:(fun st -> emit_stmt ~lvl:(lvl + 4) st) |> String.concat ~sep:"\n" in
            indent (lvl + 2) ^ "case " ^ emit_expr c ^ ":\n" ^ b
        | Default body ->
            let b = List.map body ~f:(fun st -> emit_stmt ~lvl:(lvl + 4) st) |> String.concat ~sep:"\n" in
            indent (lvl + 2) ^ "default:\n" ^ b
      in
      i ^ "switch (" ^ emit_expr e ^ ") {\n"
      ^ (List.map clauses ~f:clause_to_c |> String.concat ~sep:"\n")
      ^ "\n" ^ i ^ "}"
  | SBreak -> i ^ "break;"
  | SContinue -> i ^ "continue;"
  | SReturn None -> i ^ "return;"
  | SReturn (Some e) -> i ^ "return " ^ emit_expr e ^ ";"
  | SGoto lbl -> i ^ "goto " ^ mangle_ident lbl ^ ";"
  | SLabel lbl -> i ^ mangle_ident lbl ^ ":"
  | SDecl d -> i ^ emit_decl_stmt d
  | SDeclMany ds ->
      List.map ds ~f:(fun d -> i ^ emit_decl_stmt d)
      |> String.concat ~sep:"\n"
  | SExpr e -> i ^ emit_expr e ^ ";"

let emit_param p = emit_decl_of_type p.p_ty (mangle_ident p.p_name)

let emit_fn_sig ret name params varargs =
  let args =
    let ps = List.map params ~f:emit_param in
    let ps = if List.is_empty ps then [ "void" ] else ps in
    if varargs then ps @ [ "..." ] else ps
  in
  emit_decl_of_type ret (mangle_ident name ^ "(" ^ String.concat ~sep:", " args ^ ")")

let emit_top = function
  | TInclude (IncludeAngle a) -> "#include " ^ a
  | TInclude (IncludeQuote s) -> "#include \"" ^ s ^ "\""
  | TIncludes xs ->
      List.map xs ~f:(function
          | IncludeAngle a -> "#include " ^ a
          | IncludeQuote s -> "#include \"" ^ s ^ "\"")
      |> String.concat ~sep:"\n"
  | TDefine (name, body) -> "#define " ^ mangle_ident name ^ " " ^ emit_expr body
  | TDefineMacro (name, params, body) ->
      "#define " ^ mangle_ident name ^ "(" ^ String.concat ~sep:"," (List.map params ~f:mangle_ident) ^ ") "
      ^ emit_expr body
  | TIfdef (sym, body) -> "#ifdef " ^ mangle_ident sym ^ "\n" ^ emit_stmt body ^ "\n#endif"
  | TTypedef (tyv, name) -> "typedef " ^ emit_decl_of_type tyv (mangle_ident name) ^ ";"
  | TDeclFn (ret, name, params, varargs) -> emit_fn_sig ret name params varargs ^ ";"
  | TDefFn (ret, name, params, varargs, body) -> emit_fn_sig ret name params varargs ^ "\n" ^ emit_stmt body
  | TDeclTop d -> emit_decl_stmt d
  | TStmtTop s -> emit_stmt s
