open Core
open Common

let usage () =
  prerr_endline "Usage:";
  prerr_endline "  sexc <input.sexc>";
  prerr_endline "  sexc <input.sexc> -C <command...>";
  prerr_endline "";
  prerr_endline "When -C is used, token '%' is replaced with a temporary generated C file.";
  prerr_endline "Example:";
  prerr_endline "  sexc examples/raylib_std.sexc -C gcc % -lraylib -o raylib-example"

let split_compile_command args =
  match args with
  | [] -> fail "missing input file"
  | input :: rest -> (
      match rest with
      | [] -> (input, None)
      | "-C" :: cmd when not (List.is_empty cmd) -> (input, Some cmd)
      | "-C" :: [] -> fail "-C requires a command"
      | _ -> fail "unsupported arguments; expected optional '-C <command...>'")

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

let () =
  Random.self_init ();
  let argv = Sys.get_argv () in
  let args = Array.to_list argv |> List.tl_exn in
  try
    let input_path, compile_cmd = split_compile_command args in
    let c = Compiler.compile_file input_path in
    match compile_cmd with
    | None ->
        Out_channel.output_string stdout c;
        Out_channel.newline stdout
    | Some cmd ->
        let status = run_with_temp_c c cmd in
        if status <> 0 then exit status
  with
  | Sexc_error msg ->
      prerr_endline ("error: " ^ msg);
      usage ();
      exit 1
  | exn ->
      prerr_endline ("error: " ^ Exn.to_string exn);
      exit 1
