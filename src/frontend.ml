open Core
open Common

(*
   Frontend: expanded Raw forms -> typed AST for C emission.

   Responsibilities:
   - parse types/declarations/statements/expressions
   - enforce intrinsic arity and shape constraints
   - classify top-level forms for codegen

   Extension point:
   - Add new intrinsic parsing in [parse_intrinsic_expr].
   - Add new top-level intrinsic parsing in [parse_top].
   - When adding new AST constructors, update both parser and codegen.

   Data flow:
   expanded Raw.t
     -> [parse_top]
     -> [parse_stmt]/[parse_expr]/[parse_type]
     -> typed AST nodes ([top], [stmt], [expr], [ty])
     -> consumed by Codegen_c
*)

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
  | TEnum of string * enum_variant list  (* [] = ссылка `enum Name`; иначе определение тела *)
  | TTypeof of expr  (* GNU __typeof__(expr): infer a declaration's type from a value *)

and field = {
  f_ty : ty;
  f_name : string;
  f_span : Common.span option;  (* для per-field #line внутри struct/union *)
}

and enum_variant = {
  ev_name : string;
  (* Константное значение варианта (к codegen-времени уже %-IR, т.к. macro phase
     отработал). None = авто-нумерация (C продолжает от предыдущего). *)
  ev_value : Raw.t option;
}

and decl = {
  d_storage : storage list;
  d_specs : string list;   (* raw C specifiers from :keyword attrs, e.g. ["_Thread_local"] *)
  d_ty : ty;
  d_name : string;
  d_init : expr option;
}

and expr =
  | EAtom of string
  | EString of string
  | ERaw of raw_part list
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

and raw_part =
  | RawText of string
  | RawExpr of expr

and for_init =
  | FNone
  | FExpr of expr
  | FDecl of decl

and switch_clause =
  | Case of expr * stmt list
  | Default of stmt list

and stmt =
  | SNop
  | SAt of Common.span * stmt  (* statement с привязкой к источнику; codegen эмитит #line *)
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
  | SDeclMany of decl list
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
  | TDeclFn of ty * string * param list * bool * string list   (* ...varargs * fn-specifiers *)
  | TDefFn of ty * string * param list * bool * stmt * string list   (* ...varargs * body * fn-specifiers *)
  | TDeclTop of decl
  | TStmtTop of stmt
  | TComment of string
  | TCpp of string

let expect_atom = function
  | Raw.Atom (a, _) -> a
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

(* :keyword declaration specifiers → raw C specifier text. *)
let spec_of_keyword = function
  | ":thread_local" -> Some "_Thread_local"
  | ":static" -> Some "static"
  | ":extern" -> Some "extern"
  | ":register" -> Some "register"
  | ":auto" -> Some "auto"
  | ":inline" -> Some "inline"
  | ":const" -> Some "const"
  | ":volatile" -> Some "volatile"
  | ":atomic" | ":_Atomic" -> Some "_Atomic"
  | _ -> None

let allowed_decl_specifiers =
  ":thread_local :static :extern :register :auto :inline :const :volatile :atomic"

(* Forward reference to parse_expr: parse_type needs it for (%typeof EXPR), but
   parse_expr is defined later (it depends on parse_type). Set just below. *)
let parse_expr_fwd : (Raw.t -> expr) ref = ref (fun _ -> fail "parse_expr not initialized")

let rec parse_type_from_elems elems =
  match elems with
  | [] -> fail "Empty type"
  | [ one ] -> parse_type one
  | many ->
      let atoms =
        List.map many ~f:(function
          | Raw.Atom (a, _) -> a
          | _ -> fail "Multi-word type expects atoms")
      in
      TBuiltin (String.concat ~sep:" " atoms)

and apply_qual q tyv =
  match tyv with
  | TPtr (qs, inner) -> TPtr (q :: qs, inner)
  | _ -> TQual (q, tyv)

and parse_field = function
  | Raw.List ([ ty_s; Raw.Atom (name, _) ], sp) -> { f_ty = parse_type ty_s; f_name = name; f_span = sp }
  | _ -> fail "Struct/union field must be (type name)"

and parse_enum_variant = function
  | Raw.Atom (v, _) -> { ev_name = v; ev_value = None }
  | Raw.List ([ Raw.Atom (v, _); value ], _) -> { ev_name = v; ev_value = Some value }
  | _ -> fail "enum variant must be NAME or (NAME value)"

and parse_type = function
  | Raw.Atom (a, _) ->
      if Set.mem builtin_words a then TBuiltin a else TNamed a
  | Raw.Str (_, _) -> fail "String is not a valid type"
  | Raw.List ([], _) -> fail "Empty type list"
  | Raw.List ((Raw.Atom (head, _) :: rest), _) -> (
      match head, rest with
      | "%ptr", [ inner ] -> TPtr ([], parse_type inner)
      | "%array", [ inner ] -> TArray (parse_type inner, None)
      | "%array", [ inner; Raw.Atom (n, _) ] ->
          TArray (parse_type inner, Some (Int.of_string n))
      | "%fn", [ ret; Raw.List (args, _) ] ->
          let args_t, varargs =
            match List.rev args with
            | Raw.Atom ("...", _) :: tl -> List.rev tl, true
            | _ -> args, false
          in
          TFn (parse_type ret, List.map args_t ~f:parse_type, varargs)
      | "%typeof", [ e ] -> TTypeof (!parse_expr_fwd e)
      | "%const", [ inner ] -> apply_qual Const (parse_type inner)
      | "%volatile", [ inner ] -> apply_qual Volatile (parse_type inner)
      | "%restrict", [ inner ] -> apply_qual Restrict (parse_type inner)
      | "%struct", Raw.Atom (name, _) :: fields ->
          let fs = List.map fields ~f:parse_field in
          TStruct (name, if List.is_empty fs then None else Some fs)
      | "%union", Raw.Atom (name, _) :: fields ->
          let fs = List.map fields ~f:parse_field in
          TUnion (name, if List.is_empty fs then None else Some fs)
      | "%enum", Raw.Atom (name, _) :: variants -> TEnum (name, List.map variants ~f:parse_enum_variant)
      | _ -> parse_type_from_elems (Raw.Atom (head, None) :: rest))
  | Raw.List (elems, _) -> parse_type_from_elems elems

let parse_decl_type raw =
  let bare ty = { d_storage = []; d_specs = []; d_ty = ty; d_name = ""; d_init = None } in
  match raw with
  | Raw.List ((Raw.Atom _ :: _) as items, _) ->
      (* Peel leading :keyword specifiers and %storage atoms; the rest is the type.
         A ':'-prefixed atom must be a known specifier, else it is an error. *)
      let rec collect specs stor rem =
        match rem with
        | Raw.Atom (a, _) :: tl when String.is_prefix a ~prefix:":" -> (
            match spec_of_keyword a with
            | Some s -> collect (s :: specs) stor tl
            | None ->
                failf "Unknown decl specifier %s (allowed: %s)" a allowed_decl_specifiers)
        | Raw.Atom (a, _) :: tl -> (
            match storage_of_atom a with
            | Some s -> collect specs (s :: stor) tl
            | None -> (List.rev specs, List.rev stor, rem))
        | _ -> (List.rev specs, List.rev stor, rem)
      in
      let specs, stor, rest = collect [] [] items in
      if List.is_empty specs && List.is_empty stor then
        (* No specifiers peeled: parse the whole form as an intrinsic/named type
           (so (%ptr int), (%array int 4), (%const int) keep working). *)
        bare (parse_type raw)
      else
        let ty =
          match rest with
          | [] -> fail "decl type: specifiers given but no type follows"
          | _ -> parse_type_from_elems rest
        in
        { d_storage = stor; d_specs = specs; d_ty = ty; d_name = ""; d_init = None }
  | _ -> bare (parse_type raw)

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
  | "%&=" -> "&="
  | "%|=" -> "|="
  | "%^=" -> "^="
  | "%<<=" -> "<<="
  | "%>>=" -> ">>="
  | x -> failf "Unknown intrinsic operator: %s" x

let rec parse_expr raw =
  match raw with
  | Raw.Atom (a, _) -> EAtom a
  | Raw.Str (s, _) -> EString s
  | Raw.List ([], _) -> fail "Expression cannot be empty list"
  | Raw.List ((head :: rest), _) -> (
      match head with
      | Raw.Atom (h, _) when is_intrinsic h -> parse_intrinsic_expr h rest
      | Raw.Atom (_, _) -> ECall (parse_expr head, List.map rest ~f:parse_expr)
      | _ -> ECall (parse_expr head, List.map rest ~f:parse_expr))

and parse_intrinsic_expr h args =
  match h with
  | "%top-level-splice" -> fail "%top-level-splice is allowed only at top-level"
  | "%eval" -> fail "%eval should be expanded during macro phase"
  | "%evals" -> fail "%evals should be expanded during macro phase"
  | "%raw" ->
      let parse_raw_part = function
        | Raw.Str (s, _) -> RawText s
        | other -> RawExpr (parse_expr other)
      in
      ERaw (List.map args ~f:parse_raw_part)
  | "%expr" ->
      (* Force the argument to be parsed as an expression. Useful inside %raw,
         where a bare string is raw C text — (%expr "x") makes it the string
         literal "x" instead. Identity for everything else. *)
      ensure_arity h args 1;
      parse_expr (List.hd_exn args)
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
  | ( "%set" | "%+=" | "%-=" | "%*=" | "%/=" | "%%="
    | "%&=" | "%|=" | "%^=" | "%<<=" | "%>>=" ) as op ->
      ensure_arity op args 2;
      EAssign (c_binary_op op, parse_expr (List.nth_exn args 0), parse_expr (List.nth_exn args 1))
  | _ -> failf "Unknown intrinsic expression: %s" h

(* Wire the forward reference now that parse_expr exists (see parse_expr_fwd). *)
let () = parse_expr_fwd := parse_expr

let parse_decl args =
  match args with
  | ty_s :: Raw.Atom (name, _) :: rest ->
      let ty_rec = parse_decl_type ty_s in
      let init =
        match rest with
        | [] -> None
        | [ x ] -> Some (parse_expr x)
        | _ -> fail "%decl accepts at most one initializer"
      in
      { d_storage = ty_rec.d_storage; d_specs = ty_rec.d_specs;
        d_ty = ty_rec.d_ty; d_name = name; d_init = init }
  | _ -> fail "%decl must be (%decl type name [init])"

let rec parse_stmt_or_decl raw =
  let stmt =
    match raw with
    | Raw.List ((Raw.Atom ("%decl", _) :: args), _) -> SDecl (parse_decl args)
    | Raw.List ((Raw.Atom ("%decl-many", _) :: forms), _) ->
        let parse_one = function
          | Raw.List ((Raw.Atom ("%decl", _) :: args), _) -> parse_decl args
          | Raw.List ((Raw.Atom ("%decl-many", _) :: _), _) ->
              fail "%decl-many cannot be nested as a declaration item"
          | Raw.List ((Raw.Atom ("decl", _) :: _), _) -> fail "%decl-many contains unexpanded decl macro"
          | _ -> fail "%decl-many expects only (%decl type name init) forms"
        in
        let rec flatten acc = function
          | [] -> List.rev acc
          | Raw.List ((Raw.Atom ("%decl-many", _) :: inner), _) :: tl -> flatten (List.rev_append (flatten [] inner) acc) tl
          | x :: tl -> flatten (parse_one x :: acc) tl
        in
        if List.is_empty forms then fail "%decl-many requires at least one declaration"
        else SDeclMany (flatten [] forms)
    | _ -> parse_stmt raw
  in
  (* Привязываем стейтмент к источнику для #line. Span берём с самой формы
     (reader проставил), либо None для синтезированных макросом без локации —
     тогда #line не эмитим, остаётся предыдущая привязка. *)
  match Raw.span_of raw with
  | Some sp -> SAt (sp, stmt)
  | None -> stmt

and parse_switch_clause = function
  | Raw.List ((Raw.Atom ("%case", _) :: cond :: body), _) ->
      Case (parse_expr cond, List.map body ~f:parse_stmt_or_decl)
  | Raw.List ((Raw.Atom ("%default", _) :: body), _) ->
      Default (List.map body ~f:parse_stmt_or_decl)
  | _ -> fail "Switch body supports only %case and %default"

and parse_for_init = function
  | Raw.List ([ Raw.Atom ("%nop", _) ], _) -> FNone
  | Raw.List ((Raw.Atom ("%decl", _) :: args), _) -> FDecl (parse_decl args)
  | other -> FExpr (parse_expr other)

and parse_opt_for_expr = function
  | Raw.List ([ Raw.Atom ("%nop", _) ], _) -> None
  | other -> Some (parse_expr other)

and parse_stmt raw =
  match raw with
  | Raw.List ((Raw.Atom ("%nop", _) :: []), _) -> SNop
  | Raw.List ((Raw.Atom ("%block", _) :: body), _) -> SBlock (List.map body ~f:parse_stmt_or_decl)
  | Raw.List ((Raw.Atom ("%if", _) :: args), _) ->
      ensure_arity_between "%if" args 2 3;
      let cond = parse_expr (List.nth_exn args 0) in
      let then_s = parse_stmt_or_decl (List.nth_exn args 1) in
      let else_s = Option.map (List.nth args 2) ~f:parse_stmt_or_decl in
      SIf (cond, then_s, else_s)
  | Raw.List ((Raw.Atom ("%while", _) :: [ cond; body ]), _) -> SWhile (parse_expr cond, parse_stmt_or_decl body)
  | Raw.List ((Raw.Atom ("%do-while", _) :: [ cond; body ]), _) -> SDoWhile (parse_expr cond, parse_stmt_or_decl body)
  | Raw.List ((Raw.Atom ("%for", _) :: [ init; cond; step; body ]), _) ->
      SFor (parse_for_init init, parse_opt_for_expr cond, parse_opt_for_expr step, parse_stmt_or_decl body)
  | Raw.List ((Raw.Atom ("%switch", _) :: cond :: clauses), _) ->
      SSwitch (parse_expr cond, List.map clauses ~f:parse_switch_clause)
  | Raw.List ((Raw.Atom ("%break", _) :: []), _) -> SBreak
  | Raw.List ((Raw.Atom ("%continue", _) :: []), _) -> SContinue
  | Raw.List ((Raw.Atom ("%return", _) :: []), _) -> SReturn None
  | Raw.List ((Raw.Atom ("%return", _) :: [ x ]), _) -> SReturn (Some (parse_expr x))
  | Raw.List ((Raw.Atom ("%goto", _) :: [ Raw.Atom (lbl, _) ]), _) -> SGoto lbl
  | Raw.List ((Raw.Atom ("%label", _) :: [ Raw.Atom (lbl, _) ]), _) -> SLabel lbl
  | _ -> SExpr (parse_expr raw)

let parse_params = function
  | Raw.List (xs, _) ->
      let rec loop acc varargs = function
        | [] -> (List.rev acc, varargs)
        | Raw.Atom ("...", _) :: tl -> loop acc true tl
        | Raw.List ((ty_s :: names), _) :: tl ->
            if List.is_empty names then fail "Function parameter group requires at least one name"
            else
              let ty = parse_type ty_s in
              let group_params =
                List.map names ~f:(function
                  | Raw.Atom (name, _) -> { p_ty = ty; p_name = name }
                  | _ -> fail "Function parameter name must be an atom")
              in
              loop (List.rev_append group_params acc) varargs tl
        | _ -> fail "Invalid function parameter list"
      in
      loop [] false xs
  | _ -> fail "Function params must be a list"

let parse_include_arg = function
  | Raw.Atom (a, _) when String.is_prefix a ~prefix:"<" && String.is_suffix a ~suffix:">" -> IncludeAngle a
  | Raw.Str (s, _) -> IncludeQuote s
  | Raw.Atom (a, _) -> IncludeQuote a
  | _ -> fail "Invalid %include argument"

let rec parse_top raw =
  match raw with
  | Raw.List ((Raw.Atom ("%include", _) :: args), _) ->
      if List.is_empty args then fail "%include requires at least one argument"
      else if List.length args = 1 then TInclude (parse_include_arg (List.hd_exn args))
      else TIncludes (List.map args ~f:parse_include_arg)
  | Raw.List ((Raw.Atom ("%define", _) :: [ Raw.Atom (name, _); body ]), _) -> TDefine (name, parse_expr body)
  | Raw.List ((Raw.Atom ("%define-macro", _) :: [ Raw.List ((Raw.Atom (name, _) :: params), _); body ]), _) ->
      let param_names = List.map params ~f:expect_atom in
      TDefineMacro (name, param_names, parse_expr body)
  | Raw.List ((Raw.Atom ("%ifdef", _) :: [ Raw.Atom (sym, _); body ]), _) -> TIfdef (sym, parse_stmt_or_decl body)
  | Raw.List ((Raw.Atom ("%typedef", _) :: [ ty_s; Raw.Atom (name, _) ]), _) -> TTypedef (parse_type ty_s, name)
  | Raw.List ((Raw.Atom ("%decl-fn", _) :: ret_ty :: Raw.Atom (name, _) :: params :: []), _) ->
      let ps, varargs = parse_params params in
      TDeclFn (parse_type ret_ty, name, ps, varargs, [])
  | Raw.List ((Raw.Atom ("%def-fn", _) :: ret_ty :: Raw.Atom (name, _) :: params :: body :: []), _) ->
      let ps, varargs = parse_params params in
      TDefFn (parse_type ret_ty, name, ps, varargs, parse_stmt_or_decl body, [])
  | Raw.List ((Raw.Atom (("%inline" | "%static" | "%extern") as spec, _) :: [ inner ]), _) ->
      (* Stackable function specifiers: (%static (%inline (%def-fn ...))). Each
         wrapper prepends its keyword, so outer-most ends up left-most in C. *)
      let kw = String.chop_prefix_exn spec ~prefix:"%" in
      (match parse_top inner with
       | TDefFn (r, n, p, v, b, specs) -> TDefFn (r, n, p, v, b, kw :: specs)
       | TDeclFn (r, n, p, v, specs) -> TDeclFn (r, n, p, v, kw :: specs)
       | _ -> failf "%s expects a function definition (%%def-fn) or prototype (%%decl-fn)" spec)
  | Raw.List ((Raw.Atom (("%inline" | "%static" | "%extern") as spec, _) :: _), _) ->
      failf "%s expects exactly one function form" spec
  | Raw.List ((Raw.Atom ("%decl", _) :: args), _) -> TDeclTop (parse_decl args)
  | Raw.List ((Raw.Atom ("%comment", _) :: [ Raw.Str (s, _) ]), _) -> TComment s
  | Raw.List ((Raw.Atom ("%comment", _) :: _), _) -> fail "%comment expects exactly one string argument"
  | Raw.List ((Raw.Atom ("%cpp", _) :: [ Raw.Str (s, _) ]), _) -> TCpp s
  | Raw.List ((Raw.Atom ("%cpp", _) :: _), _) -> fail "%cpp expects exactly one string argument"
  | _ -> TStmtTop (parse_stmt_or_decl raw)
