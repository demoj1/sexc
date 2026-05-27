open Core

exception Sexc_error of string

let fail msg = raise (Sexc_error msg)

let failf fmt = Printf.ksprintf (fun s -> raise (Sexc_error s)) fmt
