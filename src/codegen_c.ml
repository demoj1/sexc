open Core
open Common
open Frontend

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
  | TNamed s -> s
  | TStruct (name, None) -> "struct " ^ name
  | TUnion (name, None) -> "union " ^ name
  | TEnum name -> "enum " ^ name
  | TStruct (name, Some fields) ->
      let body =
        List.map fields ~f:(fun f -> "  " ^ emit_decl_of_type f.f_ty f.f_name ^ ";")
        |> String.concat ~sep:"\n"
      in
      "struct " ^ name ^ " {\n" ^ body ^ "\n}"
  | TUnion (name, Some fields) ->
      let body =
        List.map fields ~f:(fun f -> "  " ^ emit_decl_of_type f.f_ty f.f_name ^ ";")
        |> String.concat ~sep:"\n"
      in
      "union " ^ name ^ " {\n" ^ body ^ "\n}"
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
  stor ^ emit_decl_of_type d.d_ty d.d_name

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
  | EPostfix _ | ECall _ | EIndex _ | EMember _ | EPtrMember _ -> 15
  | EAtom _ | EString _ -> 16

let rec emit_expr ?(ctx = 0) e =
  let p = precedence_of_expr e in
  let body =
    match e with
    | EAtom a -> a
    | EString s -> "\"" ^ c_escape_string s ^ "\""
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
    | EMember (x, f) -> emit_expr ~ctx:p x ^ "." ^ f
    | EPtrMember (x, f) -> emit_expr ~ctx:p x ^ "->" ^ f
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
  | SGoto lbl -> i ^ "goto " ^ lbl ^ ";"
  | SLabel lbl -> i ^ lbl ^ ":"
  | SDecl d -> i ^ emit_decl_stmt d
  | SExpr e -> i ^ emit_expr e ^ ";"

let emit_param p = emit_decl_of_type p.p_ty p.p_name

let emit_fn_sig ret name params varargs =
  let args =
    let ps = List.map params ~f:emit_param in
    let ps = if List.is_empty ps then [ "void" ] else ps in
    if varargs then ps @ [ "..." ] else ps
  in
  emit_decl_of_type ret (name ^ "(" ^ String.concat ~sep:", " args ^ ")")

let emit_top = function
  | TInclude (IncludeAngle a) -> "#include " ^ a
  | TInclude (IncludeQuote s) -> "#include \"" ^ s ^ "\""
  | TIncludes xs ->
      List.map xs ~f:(function
          | IncludeAngle a -> "#include " ^ a
          | IncludeQuote s -> "#include \"" ^ s ^ "\"")
      |> String.concat ~sep:"\n"
  | TDefine (name, body) -> "#define " ^ name ^ " " ^ emit_expr body
  | TDefineMacro (name, params, body) ->
      "#define " ^ name ^ "(" ^ String.concat ~sep:"," params ^ ") " ^ emit_expr body
  | TIfdef (sym, body) -> "#ifdef " ^ sym ^ "\n" ^ emit_stmt body ^ "\n#endif"
  | TTypedef (tyv, name) -> "typedef " ^ emit_decl_of_type tyv name ^ ";"
  | TDeclFn (ret, name, params, varargs) -> emit_fn_sig ret name params varargs ^ ";"
  | TDefFn (ret, name, params, varargs, body) -> emit_fn_sig ret name params varargs ^ "\n" ^ emit_stmt body
  | TDeclTop d -> emit_decl_stmt d
  | TStmtTop s -> emit_stmt s
