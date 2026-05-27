open Core
open Common

type storage = Extern | Static | Register | Auto | Typedef

type qualifier = Const | Volatile | Restrict

type ty =
  | TBuiltin of string
  | TNamed of string
  | TPtr of qualifier list * ty
  | TArray of ty * int option
  | TFn of ty * ty list * bool
  | TQual of qualifier * ty
  | TStruct of string * field list option
  | TUnion of string * field list option
  | TEnum of string

and field = {
  f_ty : ty;
  f_name : string;
}

type decl = {
  d_storage : storage list;
  d_ty : ty;
  d_name : string;
  d_init : expr option;
}

and expr =
  | EAtom of string
  | EString of string
  | ECall of expr * expr list
  | EUnary of string * expr
  | EPostfix of string * expr
  | ENary of string * expr list
  | EAssign of string * expr * expr
  | ECast of ty * expr
  | ESizeofType of ty
  | ESizeofExpr of expr
  | ETernary of expr * expr * expr
  | EComma of expr list
  | EIndex of expr * expr
  | EMember of expr * string
  | EPtrMember of expr * string

and for_init =
  | FNone
  | FExpr of expr
  | FDecl of decl

and switch_clause =
  | Case of expr * stmt list
  | Default of stmt list

and stmt =
  | SNop
  | SBlock of stmt list
  | SIf of expr * stmt * stmt option
  | SWhile of expr * stmt
  | SDoWhile of expr * stmt
  | SFor of for_init * expr option * expr option * stmt
  | SSwitch of expr * switch_clause list
  | SBreak
  | SContinue
  | SReturn of expr option
  | SGoto of string
  | SLabel of string
  | SDecl of decl
  | SExpr of expr

type param = {
  p_ty : ty;
  p_name : string;
}

type include_arg =
  | IncludeAngle of string
  | IncludeQuote of string

type top =
  | TInclude of include_arg
  | TIncludes of include_arg list
  | TDefine of string * expr
  | TDefineMacro of string * string list * expr
  | TIfdef of string * stmt
  | TTypedef of ty * string
  | TDeclFn of ty * string * param list * bool
  | TDefFn of ty * string * param list * bool * stmt
  | TDeclTop of decl
  | TStmtTop of stmt

let expect_atom = function
  | Raw.Atom a -> a
  | _ -> fail "Expected atom"

let builtin_words =
  String.Set.of_list
    [ "void"; "char"; "short"; "int"; "long"; "float"; "double"; "signed"; "unsigned" ]

let storage_of_atom = function
  | "%extern" -> Some Extern
  | "%static" -> Some Static
  | "%register" -> Some Register
  | "%auto" -> Some Auto
  | "%typedef" -> Some Typedef
  | _ -> None

let rec parse_type_from_elems elems =
  match elems with
  | [] -> fail "Empty type"
  | [ one ] -> parse_type one
  | many ->
      let atoms =
        List.map many ~f:(function
          | Raw.Atom a -> a
          | _ -> fail "Multi-word type expects atoms")
      in
      TBuiltin (String.concat ~sep:" " atoms)

and apply_qual q tyv =
  match tyv with
  | TPtr (qs, inner) -> TPtr (q :: qs, inner)
  | _ -> TQual (q, tyv)

and parse_field = function
  | Raw.List [ ty_s; Raw.Atom name ] -> { f_ty = parse_type ty_s; f_name = name }
  | _ -> fail "Struct/union field must be (type name)"

and parse_type = function
  | Raw.Atom a ->
      if Set.mem builtin_words a then TBuiltin a else TNamed a
  | Raw.Str _ -> fail "String is not a valid type"
  | Raw.List [] -> fail "Empty type list"
  | Raw.List (Raw.Atom head :: rest) -> (
      match head, rest with
      | "%ptr", [ inner ] -> TPtr ([], parse_type inner)
      | "%array", [ inner ] -> TArray (parse_type inner, None)
      | "%array", [ inner; Raw.Atom n ] ->
          TArray (parse_type inner, Some (Int.of_string n))
      | "%fn", [ ret; Raw.List args ] ->
          let args_t, varargs =
            match List.rev args with
            | Raw.Atom "..." :: tl -> List.rev tl, true
            | _ -> args, false
          in
          TFn (parse_type ret, List.map args_t ~f:parse_type, varargs)
      | "%const", [ inner ] -> apply_qual Const (parse_type inner)
      | "%volatile", [ inner ] -> apply_qual Volatile (parse_type inner)
      | "%restrict", [ inner ] -> apply_qual Restrict (parse_type inner)
      | "%struct", Raw.Atom name :: fields ->
          let fs = List.map fields ~f:parse_field in
          TStruct (name, if List.is_empty fs then None else Some fs)
      | "%union", Raw.Atom name :: fields ->
          let fs = List.map fields ~f:parse_field in
          TUnion (name, if List.is_empty fs then None else Some fs)
      | "%enum", [ Raw.Atom name ] -> TEnum name
      | _ -> parse_type_from_elems (Raw.Atom head :: rest))
  | Raw.List elems -> parse_type_from_elems elems

let parse_decl_type raw =
  match raw with
  | Raw.List (Raw.Atom h :: tail) -> (
      match storage_of_atom h with
      | None -> { d_storage = []; d_ty = parse_type raw; d_name = ""; d_init = None }
      | Some _ ->
          let rec collect stor rem =
            match rem with
            | Raw.Atom a :: tl -> (
                match storage_of_atom a with
                | Some s -> collect (s :: stor) tl
                | None -> (List.rev stor, rem))
            | _ -> (List.rev stor, rem)
          in
          let stor, rest = collect [] (Raw.Atom h :: tail) in
          { d_storage = stor; d_ty = parse_type_from_elems rest; d_name = ""; d_init = None })
  | _ -> { d_storage = []; d_ty = parse_type raw; d_name = ""; d_init = None }

let ensure_arity name args expected =
  if List.length args <> expected then
    failf "%s expects %d arguments, got %d" name expected (List.length args)

let ensure_arity_between name args low high =
  let n = List.length args in
  if n < low || n > high then
    failf "%s expects %d..%d arguments, got %d" name low high n

let is_intrinsic name = String.is_prefix name ~prefix:"%"

let c_binary_op = function
  | "%+" -> "+"
  | "%-" -> "-"
  | "%*" -> "*"
  | "%/" -> "/"
  | "%%" -> "%"
  | "%&" -> "&"
  | "%|" -> "|"
  | "%^" -> "^"
  | "%<<" -> "<<"
  | "%>>" -> ">>"
  | "%==" -> "=="
  | "%!=" -> "!="
  | "%<" -> "<"
  | "%<=" -> "<="
  | "%>" -> ">"
  | "%>=" -> ">="
  | "%&&" -> "&&"
  | "%||" -> "||"
  | "%set" -> "="
  | "%+=" -> "+="
  | "%-=" -> "-="
  | "%*=" -> "*="
  | "%/=" -> "/="
  | "%%=" -> "%="
  | x -> failf "Unknown intrinsic operator: %s" x

let rec parse_expr raw =
  match raw with
  | Raw.Atom a -> EAtom a
  | Raw.Str s -> EString s
  | Raw.List [] -> fail "Expression cannot be empty list"
  | Raw.List (head :: rest) -> (
      match head with
      | Raw.Atom h when is_intrinsic h -> parse_intrinsic_expr h rest
      | _ -> ECall (parse_expr head, List.map rest ~f:parse_expr))

and parse_intrinsic_expr h args =
  match h with
  | "%!" | "%~" ->
      ensure_arity h args 1;
      EUnary (String.drop_prefix h 1, parse_expr (List.hd_exn args))
  | "%pre-inc" ->
      ensure_arity h args 1;
      EUnary ("++", parse_expr (List.hd_exn args))
  | "%pre-dec" ->
      ensure_arity h args 1;
      EUnary ("--", parse_expr (List.hd_exn args))
  | "%post-inc" ->
      ensure_arity h args 1;
      EPostfix ("++", parse_expr (List.hd_exn args))
  | "%post-dec" ->
      ensure_arity h args 1;
      EPostfix ("--", parse_expr (List.hd_exn args))
  | "%addr" ->
      ensure_arity h args 1;
      EUnary ("&", parse_expr (List.hd_exn args))
  | "%deref" ->
      ensure_arity h args 1;
      EUnary ("*", parse_expr (List.hd_exn args))
  | "%cast" ->
      ensure_arity h args 2;
      ECast (parse_type (List.nth_exn args 0), parse_expr (List.nth_exn args 1))
  | "%sizeof-type" ->
      ensure_arity h args 1;
      ESizeofType (parse_type (List.hd_exn args))
  | "%sizeof-expr" ->
      ensure_arity h args 1;
      ESizeofExpr (parse_expr (List.hd_exn args))
  | "%ternary" ->
      ensure_arity h args 3;
      ETernary
        ( parse_expr (List.nth_exn args 0),
          parse_expr (List.nth_exn args 1),
          parse_expr (List.nth_exn args 2) )
  | "%comma" ->
      if List.is_empty args then fail "%comma expects at least 1 argument";
      EComma (List.map args ~f:parse_expr)
  | "%aref" ->
      ensure_arity h args 2;
      EIndex (parse_expr (List.nth_exn args 0), parse_expr (List.nth_exn args 1))
  | "%dot" ->
      ensure_arity h args 2;
      EMember (parse_expr (List.nth_exn args 0), expect_atom (List.nth_exn args 1))
  | "%arrow" ->
      ensure_arity h args 2;
      EPtrMember (parse_expr (List.nth_exn args 0), expect_atom (List.nth_exn args 1))
  | "%call" -> (
      match args with
      | [] -> fail "%call expects at least one argument"
      | callee :: rest -> ECall (parse_expr callee, List.map rest ~f:parse_expr))
  | ( "%+" | "%-" | "%*" | "%/" | "%%" | "%&" | "%|" | "%^" | "%<<" | "%>>"
    | "%==" | "%!=" | "%<" | "%<=" | "%>" | "%>=" | "%&&" | "%||" ) as op ->
      if List.length args < 2 then failf "%s expects at least 2 arguments" op;
      ENary (c_binary_op op, List.map args ~f:parse_expr)
  | ("%set" | "%+=" | "%-=" | "%*=" | "%/=" | "%%=") as op ->
      ensure_arity op args 2;
      EAssign (c_binary_op op, parse_expr (List.nth_exn args 0), parse_expr (List.nth_exn args 1))
  | _ -> failf "Unknown intrinsic expression: %s" h

let parse_decl args =
  match args with
  | ty_s :: Raw.Atom name :: rest ->
      let ty_rec = parse_decl_type ty_s in
      let init =
        match rest with
        | [] -> None
        | [ x ] -> Some (parse_expr x)
        | _ -> fail "%decl accepts at most one initializer"
      in
      { d_storage = ty_rec.d_storage; d_ty = ty_rec.d_ty; d_name = name; d_init = init }
  | _ -> fail "%decl must be (%decl type name [init])"

let rec parse_stmt_or_decl raw =
  match raw with
  | Raw.List (Raw.Atom "%decl" :: args) -> SDecl (parse_decl args)
  | _ -> parse_stmt raw

and parse_switch_clause = function
  | Raw.List (Raw.Atom "%case" :: cond :: body) ->
      Case (parse_expr cond, List.map body ~f:parse_stmt_or_decl)
  | Raw.List (Raw.Atom "%default" :: body) ->
      Default (List.map body ~f:parse_stmt_or_decl)
  | _ -> fail "Switch body supports only %case and %default"

and parse_for_init = function
  | Raw.List [ Raw.Atom "%nop" ] -> FNone
  | Raw.List (Raw.Atom "%decl" :: args) -> FDecl (parse_decl args)
  | other -> FExpr (parse_expr other)

and parse_opt_for_expr = function
  | Raw.List [ Raw.Atom "%nop" ] -> None
  | other -> Some (parse_expr other)

and parse_stmt raw =
  match raw with
  | Raw.List (Raw.Atom "%nop" :: []) -> SNop
  | Raw.List (Raw.Atom "%block" :: body) -> SBlock (List.map body ~f:parse_stmt_or_decl)
  | Raw.List (Raw.Atom "%if" :: args) ->
      ensure_arity_between "%if" args 2 3;
      let cond = parse_expr (List.nth_exn args 0) in
      let then_s = parse_stmt_or_decl (List.nth_exn args 1) in
      let else_s = Option.map (List.nth args 2) ~f:parse_stmt_or_decl in
      SIf (cond, then_s, else_s)
  | Raw.List (Raw.Atom "%while" :: [ cond; body ]) -> SWhile (parse_expr cond, parse_stmt_or_decl body)
  | Raw.List (Raw.Atom "%do-while" :: [ cond; body ]) -> SDoWhile (parse_expr cond, parse_stmt_or_decl body)
  | Raw.List (Raw.Atom "%for" :: [ init; cond; step; body ]) ->
      SFor (parse_for_init init, parse_opt_for_expr cond, parse_opt_for_expr step, parse_stmt_or_decl body)
  | Raw.List (Raw.Atom "%switch" :: cond :: clauses) ->
      SSwitch (parse_expr cond, List.map clauses ~f:parse_switch_clause)
  | Raw.List (Raw.Atom "%break" :: []) -> SBreak
  | Raw.List (Raw.Atom "%continue" :: []) -> SContinue
  | Raw.List (Raw.Atom "%return" :: []) -> SReturn None
  | Raw.List (Raw.Atom "%return" :: [ x ]) -> SReturn (Some (parse_expr x))
  | Raw.List (Raw.Atom "%goto" :: [ Raw.Atom lbl ]) -> SGoto lbl
  | Raw.List (Raw.Atom "%label" :: [ Raw.Atom lbl ]) -> SLabel lbl
  | _ -> SExpr (parse_expr raw)

let parse_params = function
  | Raw.List xs ->
      let rec loop acc varargs = function
        | [] -> (List.rev acc, varargs)
        | Raw.Atom "..." :: tl -> loop acc true tl
        | Raw.List [ ty_s; Raw.Atom name ] :: tl ->
            loop ({ p_ty = parse_type ty_s; p_name = name } :: acc) varargs tl
        | _ -> fail "Invalid function parameter list"
      in
      loop [] false xs
  | _ -> fail "Function params must be a list"

let parse_include_arg = function
  | Raw.Atom a when String.is_prefix a ~prefix:"<" && String.is_suffix a ~suffix:">" -> IncludeAngle a
  | Raw.Str s -> IncludeQuote s
  | Raw.Atom a -> IncludeQuote a
  | _ -> fail "Invalid %include argument"

let parse_top raw =
  match raw with
  | Raw.List (Raw.Atom "%include" :: args) ->
      if List.is_empty args then fail "%include requires at least one argument"
      else if List.length args = 1 then TInclude (parse_include_arg (List.hd_exn args))
      else TIncludes (List.map args ~f:parse_include_arg)
  | Raw.List (Raw.Atom "%define" :: [ Raw.Atom name; body ]) -> TDefine (name, parse_expr body)
  | Raw.List (Raw.Atom "%define-macro" :: [ Raw.List (Raw.Atom name :: params); body ]) ->
      let param_names = List.map params ~f:expect_atom in
      TDefineMacro (name, param_names, parse_expr body)
  | Raw.List (Raw.Atom "%ifdef" :: [ Raw.Atom sym; body ]) -> TIfdef (sym, parse_stmt_or_decl body)
  | Raw.List (Raw.Atom "%typedef" :: [ ty_s; Raw.Atom name ]) -> TTypedef (parse_type ty_s, name)
  | Raw.List (Raw.Atom "%decl-fn" :: ret_ty :: Raw.Atom name :: params :: []) ->
      let ps, varargs = parse_params params in
      TDeclFn (parse_type ret_ty, name, ps, varargs)
  | Raw.List (Raw.Atom "%def-fn" :: ret_ty :: Raw.Atom name :: params :: body :: []) ->
      let ps, varargs = parse_params params in
      TDefFn (parse_type ret_ty, name, ps, varargs, parse_stmt_or_decl body)
  | Raw.List (Raw.Atom "%decl" :: args) -> TDeclTop (parse_decl args)
  | _ -> TStmtTop (parse_stmt_or_decl raw)
