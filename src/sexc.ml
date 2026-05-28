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
*)

let usage () =
  prerr_endline "Usage:";
  prerr_endline "  sexc [--no-prelude] <input.sexc>";
  prerr_endline "  sexc [--no-prelude] <input.sexc> -C <command...>";
  prerr_endline "  sexc [--no-prelude] -";
  prerr_endline "  sexc [--no-prelude] dump-docs <input.sexc> <out-dir>";
  prerr_endline "  sexc dump-stdlib-docs <out-dir>";
  prerr_endline "  sexc [--no-prelude] show-doc <name> [input.sexc]";
  prerr_endline "  sexc [--no-prelude] complete [--json] <prefix> [input.sexc|-]";
  prerr_endline "";
  prerr_endline "By default, std/core.sexc is auto-loaded from stdlib path (implicit prelude).";
  prerr_endline "Use --no-prelude to disable auto prelude.";
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

let parse_complete_args use_prelude args =
  let json, rest =
    match args with
    | "--json" :: tl -> (true, tl)
    | tl -> (false, tl)
  in
  match rest with
  | prefix :: [] -> Complete { use_prelude; json; prefix; input_path = "-" }
  | prefix :: input :: [] -> Complete { use_prelude; json; prefix; input_path = input }
  | _ -> fail "complete expects: sexc [--no-prelude] complete [--json] <prefix> [input.sexc|-]"

let parse_command args =
  let rec parse_flags use_prelude = function
    | "--no-prelude" :: tl -> parse_flags false tl
    | rest -> (use_prelude, rest)
  in
  let use_prelude, rest = parse_flags true args in
  match rest with
  | "dump-docs" :: input :: out_dir :: [] -> Dump_docs { use_prelude; input_path = input; out_dir }
  | "dump-docs" :: _ -> fail "dump-docs expects: sexc [--no-prelude] dump-docs <input.sexc> <out-dir>"
  | "dump-stdlib-docs" :: out_dir :: [] -> Dump_stdlib_docs { out_dir }
  | "dump-stdlib-docs" :: _ -> fail "dump-stdlib-docs expects: sexc dump-stdlib-docs <out-dir>"
  | "show-doc" :: name :: [] -> Show_doc { use_prelude; name; input_path = None }
  | "show-doc" :: name :: input :: [] -> Show_doc { use_prelude; name; input_path = Some input }
  | "show-doc" :: _ -> fail "show-doc expects: sexc [--no-prelude] show-doc <name> [input.sexc]"
  | "complete" :: tl -> parse_complete_args use_prelude tl
  | [] -> fail "missing input file"
  | input :: tail -> (
      match tail with
      | [] -> Compile { use_prelude; input_path = input; compile_cmd = None }
      | "-C" :: cmd when not (List.is_empty cmd) ->
          Compile { use_prelude; input_path = input; compile_cmd = Some cmd }
      | "-C" :: [] -> fail "-C requires a command"
      | _ -> fail "unsupported arguments; expected optional '--no-prelude' and '-C <command...>'")

let replace_placeholder cmd tmp_c_path =
  let replaced =
    List.map cmd ~f:(fun arg -> if String.equal arg "%" then tmp_c_path else arg)
  in
  if List.exists cmd ~f:(String.equal "%") then replaced
  else fail "-C command must include '%' placeholder for the generated C file"

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
      run_shell_command cmd)
    ~finally:(fun () ->
      try Stdlib.Sys.remove tmp_c with
      | _ -> ())

let compile_input ~use_prelude input_path =
  if String.equal input_path "-" then
    let source = In_channel.input_all In_channel.stdin in
    Compiler.compile_source ~use_prelude source
  else Compiler.compile_file ~use_prelude input_path

let () =
  Random.self_init ();
  let argv = Sys.get_argv () in
  let args = Array.to_list argv |> List.tl_exn in
  try
    match parse_command args with
    | Compile { use_prelude; input_path; compile_cmd } ->
        let c = compile_input ~use_prelude input_path in
        (match compile_cmd with
        | None ->
            Out_channel.output_string stdout c;
            Out_channel.newline stdout
        | Some cmd ->
            let status = run_with_temp_c c cmd in
            if status <> 0 then exit status)
    | Dump_docs { use_prelude; input_path; out_dir } ->
        if String.equal input_path "-" then fail "dump-docs does not support stdin input ('-')";
        Docs.dump_docs_for_input ~use_prelude ~input_path ~out_dir
    | Dump_stdlib_docs { out_dir } -> Docs.dump_stdlib_docs ~out_dir
    | Show_doc { use_prelude; name; input_path } ->
        let entries = Docs.show_doc ?input_path ~use_prelude name in
        if List.is_empty entries then failf "No documentation found for symbol: %s" name;
        Out_channel.output_string stdout (Docs.render_entries_text entries);
        Out_channel.newline stdout
    | Complete { use_prelude; json; prefix; input_path } ->
        let items = Completion.complete_items ~use_prelude ~input_path ~prefix in
        if json then Out_channel.output_string stdout (Completion.items_to_json items ^ "\n")
        else List.iter (Completion.names_of_items items) ~f:(fun item -> Out_channel.output_string stdout (item ^ "\n"))
  with
  | Sexc_diagnostic d ->
      prerr_endline (render_diagnostic d);
      exit 1
  | Sexc_error msg ->
      prerr_endline ("error: " ^ msg);
      usage ();
      exit 1
  | exn ->
      prerr_endline ("error: " ^ Exn.to_string exn);
      exit 1
