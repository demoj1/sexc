open Core
open Common

(*
   CLI entrypoint.

   Responsibilities:
   - parse CLI flags/arguments
   - invoke compiler pipeline
   - implement optional -C command execution over generated C

   Extension point:
   - Add user-facing flags here (and wire them into Compiler options).
   - Keep usage/help text synchronized with parser behavior.

   Data flow:
   argv
     -> [parse_command]
     -> command variant
     -> dispatcher in [let ()]
     -> Compiler/Docs/Index call
     -> stdout/stderr + exit code
*)

let usage () =
  prerr_endline "Usage:";
  prerr_endline "  sexc [--no-prelude] [--quiet] <input.sexc>";
  prerr_endline "  sexc [--no-prelude] [--quiet] <input.sexc> -C <command...>";
  prerr_endline "  sexc [--no-prelude] -";
  prerr_endline "  sexc [--no-prelude] dump-docs <input.sexc> <out-dir>";
  prerr_endline "  sexc dump-stdlib-docs <out-dir>";
  prerr_endline "  sexc [--no-prelude] show-doc <name> [input.sexc]";
  prerr_endline "  sexc [--no-prelude] complete [--json] <prefix> [input.sexc|-]";
  prerr_endline "  sexc [--no-prelude] xref --json <symbol> <input.sexc>";
  prerr_endline "  sexc print-cache-dump";
  prerr_endline "  sexc [--no-prelude] m-dump [--json] <input.sexc>";
  prerr_endline "";
  prerr_endline "By default, std/core.sexc is auto-loaded from stdlib path (implicit prelude).";
  prerr_endline "Use --no-prelude to disable auto prelude.";
  prerr_endline "Compile/build stages are logged to stderr by default;";
  prerr_endline "use --quiet (or SEXC_QUIET=1) to suppress them.";
  prerr_endline "Set SEXC_STDLIB_DIR to override stdlib lookup directory.";
  prerr_endline "Use '-' as input to read source from stdin.";
  prerr_endline "";
  prerr_endline "When -C is used, token '%' is replaced with a temporary generated C file.";
  prerr_endline "Example:";
  prerr_endline "  sexc examples/raylib_std.sexc -C gcc % -lraylib -o raylib-example"

type command =
  | Compile of {
      use_prelude : bool;
      input_path : string;
      compile_cmd : string list option;
    }
  | Dump_docs of {
      use_prelude : bool;
      input_path : string;
      out_dir : string;
    }
  | Dump_stdlib_docs of { out_dir : string }
  | Show_doc of {
      use_prelude : bool;
      name : string;
      input_path : string option;
    }
  | Complete of {
      use_prelude : bool;
      json : bool;
      prefix : string;
      input_path : string;
    }
  | Xref of {
      use_prelude : bool;
      json : bool;
      symbol : string;
      input_path : string;
    }
  | Print_cache_dump
  | M_dump of {
      use_prelude : bool;
      input_path : string;
      json : bool;
    }

let parse_complete_args use_prelude args =
  let json, rest =
    match args with
    | "--json" :: tl -> (true, tl)
    | tl -> (false, tl)
  in
  match rest with
  | prefix :: [] -> Complete { use_prelude; json; prefix; input_path = "-" }
  | prefix :: input :: [] -> Complete { use_prelude; json; prefix; input_path = input }
  | _ -> cli_fail "complete expects: sexc [--no-prelude] complete [--json] <prefix> [input.sexc|-]"

let parse_xref_args use_prelude args =
  let json, rest =
    match args with
    | "--json" :: tl -> (true, tl)
    | tl -> (false, tl)
  in
  match rest with
  | symbol :: input :: [] -> Xref { use_prelude; json; symbol; input_path = input }
  | _ -> cli_fail "xref expects: sexc [--no-prelude] xref --json <symbol> <input.sexc>"

let parse_command args =
  let rec parse_flags use_prelude = function
    | "--no-prelude" :: tl -> parse_flags false tl
    | "--quiet" :: tl | "-q" :: tl ->
        quiet := true;
        parse_flags use_prelude tl
    | rest -> (use_prelude, rest)
  in
  (* SEXC_QUIET=1 env var отключает stage-логи без флага (для редакторских
     интеграций, которые парсят stdout/stderr). *)
  (match Sys.getenv "SEXC_QUIET" with
   | Some s when not (String.is_empty s) && not (String.equal s "0") -> quiet := true
   | _ -> ());
  let use_prelude, rest = parse_flags true args in
  match rest with
  | "dump-docs" :: input :: out_dir :: [] -> Dump_docs { use_prelude; input_path = input; out_dir }
  | "dump-docs" :: _ -> cli_fail "dump-docs expects: sexc [--no-prelude] dump-docs <input.sexc> <out-dir>"
  | "dump-stdlib-docs" :: out_dir :: [] -> Dump_stdlib_docs { out_dir }
  | "dump-stdlib-docs" :: _ -> cli_fail "dump-stdlib-docs expects: sexc dump-stdlib-docs <out-dir>"
  | "show-doc" :: name :: [] -> Show_doc { use_prelude; name; input_path = None }
  | "show-doc" :: name :: input :: [] -> Show_doc { use_prelude; name; input_path = Some input }
  | "show-doc" :: _ -> cli_fail "show-doc expects: sexc [--no-prelude] show-doc <name> [input.sexc]"
  | "complete" :: tl -> parse_complete_args use_prelude tl
  | "xref" :: tl -> parse_xref_args use_prelude tl
  | "print-cache-dump" :: [] -> Print_cache_dump
  | "print-cache-dump" :: _ -> cli_fail "print-cache-dump expects no arguments"
  | "m-dump" :: "--json" :: input :: [] -> M_dump { use_prelude; input_path = input; json = true }
  | "m-dump" :: input :: [] -> M_dump { use_prelude; input_path = input; json = false }
  | "m-dump" :: _ -> cli_fail "m-dump expects: sexc [--no-prelude] m-dump [--json] <input.sexc>"
  | [] -> cli_fail "missing input file"
  | input :: tail -> (
      match tail with
      | [] -> Compile { use_prelude; input_path = input; compile_cmd = None }
      | "-C" :: cmd when not (List.is_empty cmd) ->
          Compile { use_prelude; input_path = input; compile_cmd = Some cmd }
      | "-C" :: [] -> cli_fail "-C requires a command"
      | _ -> cli_fail "unsupported arguments; expected optional '--no-prelude' and '-C <command...>'")

let replace_placeholder cmd tmp_c_path =
  let replaced =
    List.map cmd ~f:(fun arg -> if String.equal arg "%" then tmp_c_path else arg)
  in
  if List.exists cmd ~f:(String.equal "%") then replaced
  else cli_fail "-C command must include '%' placeholder for the generated C file"

let run_shell_command argv =
  let command_line =
    List.map argv ~f:Filename.quote
    |> String.concat ~sep:" "
  in
  Stdlib.Sys.command command_line

let make_temp_c_path () =
  let tmp_dir = Stdlib.Filename.get_temp_dir_name () in
  let nonce = Int.to_string (Random.int 1_000_000_000) in
  Stdlib.Filename.concat tmp_dir ("sexc_" ^ nonce ^ ".c")

let run_with_temp_c compiled_c cmd =
  let tmp_c = make_temp_c_path () in
  Exn.protect
    ~f:(fun () ->
      Out_channel.write_all tmp_c ~data:compiled_c;
      let cmd = replace_placeholder cmd tmp_c in
      let head = Option.value (List.hd cmd) ~default:"<cmd>" in
      logf "running: %s" (String.concat ~sep:" " cmd);
      let t = now_ns () in
      let status = run_shell_command cmd in
      logf "%s exit %d — %s" (Stdlib.Filename.basename head) status (since t);
      status)
    ~finally:(fun () ->
      try Stdlib.Sys.remove tmp_c with
      | _ -> ())

let compile_input ~use_prelude input_path =
  if String.equal input_path "-" then
    let source = In_channel.input_all In_channel.stdin in
    Compiler.compile_source ~use_prelude source
  else Compiler.compile_file ~use_prelude input_path

(* Если в момент ошибки активен macro_chain — печатаем краткую справку по
   самой глубокой surface-форме. Только Signature/Doc/Example, без шапки и
   meta-полей. Тихо игнорируем ошибки индекса (например когда stdlib не
   находится). *)
let render_macro_hint () =
  match !Common.current_macro_chain with
  | [] -> ()
  | name :: _ ->
      let entries =
        try Index.find_by_name ~use_prelude:true name with _ -> []
      in
      (match entries with
       | [] -> ()
       | (first : Index.symbol) :: _ ->
           let lines =
             [ Option.map first.signature ~f:(fun s -> "Signature: " ^ s);
               Option.map first.doc ~f:(fun d -> "Doc: " ^ d);
               Option.map first.example ~f:(fun e -> "Example: " ^ e);
             ]
             |> List.filter_opt
           in
           if not (List.is_empty lines) then begin
             prerr_endline "";
             List.iter lines ~f:prerr_endline
           end)

let () =
  Random.self_init ();
  let argv = Sys.get_argv () in
  let args = Array.to_list argv |> List.tl_exn in
  try
    match parse_command args with
    | Compile { use_prelude; input_path; compile_cmd } ->
        let t0 = now_ns () in
        let c = compile_input ~use_prelude input_path in
        (match compile_cmd with
        | None ->
            Out_channel.output_string stdout c;
            Out_channel.newline stdout;
            logf "total — %s" (since t0)
        | Some cmd ->
            let status = run_with_temp_c c cmd in
            logf "total — %s" (since t0);
            if status <> 0 then exit status)
    | Dump_docs { use_prelude; input_path; out_dir } ->
        if String.equal input_path "-" then cli_fail "dump-docs does not support stdin input ('-')";
        Docs.dump_docs_for_input ~use_prelude ~input_path ~out_dir
    | Dump_stdlib_docs { out_dir } -> Docs.dump_stdlib_docs ~out_dir
    | Show_doc { use_prelude; name; input_path } ->
        let entries = Index.find_by_name ~use_prelude ?input_path name in
        if List.is_empty entries then failf "No documentation found for symbol: %s" name;
        Out_channel.output_string stdout (Index.render_show_doc entries);
        Out_channel.newline stdout
    | Complete { use_prelude; json; prefix; input_path } ->
        let items = Index.complete ~use_prelude ~input_path ~prefix in
        if json then Out_channel.output_string stdout (Index.symbols_to_json items ^ "\n")
        else List.iter items ~f:(fun item -> Out_channel.output_string stdout (item.name ^ "\n"))
    | Xref { use_prelude; json; symbol; input_path } ->
        let defs = Index.find_by_name ~use_prelude ?input_path:(Some input_path) symbol in
        if json then Out_channel.output_string stdout (Index.symbols_to_json defs ^ "\n")
        else
          List.iter defs ~f:(fun d ->
              Out_channel.output_string stdout (Printf.sprintf "%s:%d:%d %s\n" d.file d.line d.col d.name))
    | Print_cache_dump ->
        Out_channel.output_string stdout (Index.render_cache_dump ());
        Out_channel.newline stdout
    | M_dump { use_prelude; input_path; json } ->
        if String.equal input_path "-" then cli_fail "m-dump does not support stdin input ('-')";
        let meta = Compiler.metadata_of_file ~use_prelude input_path in
        let out =
          if json then Macro.format_meta_json meta
          else Macro.format_meta_text meta
        in
        Out_channel.output_string stdout out;
        if not json then ()
        else Out_channel.newline stdout
  with
  | Sexc_diagnostic d ->
      prerr_endline (render_diagnostic d);
      render_macro_hint ();
      exit 1
  | Sexc_cli_error msg ->
      prerr_endline ("error: " ^ msg);
      usage ();
      exit 1
  | Sexc_error msg ->
      prerr_endline ("error: " ^ msg);
      render_macro_hint ();
      exit 1
  | exn ->
      prerr_endline ("error: " ^ Exn.to_string exn);
      exit 1
