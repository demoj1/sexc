open Core
open Common

let () =
  let argv = Sys.get_argv () in
  if Array.length argv <> 2 then (
    prerr_endline "Usage: sexc <input.sexc>";
    exit 1);
  let input_path = argv.(1) in
  try
    let c = Compiler.compile_file input_path in
    Out_channel.output_string stdout c;
    Out_channel.newline stdout
  with
  | Sexc_error msg ->
      prerr_endline ("error: " ^ msg);
      exit 1
