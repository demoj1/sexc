open Core

(*
   Disk cache for symbol index entries.

   Responsibilities:
   - store per-file symbol lists plus file md5
   - return cached entries only when md5 matches current file state
   - persist cache between CLI runs in a temp-file marshal store

   Data flow:
   - [Index.symbols_for_files] calls [load] once per request.
   - [get_fresh_entry] decides cache-hit vs re-index.
   - [put_file] writes refreshed entries into in-memory map.
   - [save] flushes updated map to disk.
*)

type symbol = {
  id : int;
  name : string;
  short_name : string;
  module_name : string option;
  kind : string;
  file : string;
  line : int;
  col : int;
  signature : string option;
  doc : string option;
  example : string option;
  internal : bool;
  scope : string option;
  ty : string option;
  file_md5 : string;
}

type file_entry = {
  md5 : string;
  symbols : symbol list;
}

type t = file_entry String.Map.t

(* Bump when the indexer's output format changes (e.g. a new field in a
   signature) — the cache key is the file md5, which does NOT change when the
   *indexer* changes, so a stale cache would otherwise serve old entries.
   v2: function signatures gained a "requires: …" slots line. *)
let cache_format_version = "v2"

let cache_path () =
  Filename.concat (Stdlib.Filename.get_temp_dir_name ())
    (Printf.sprintf "sexc-symbol-cache-%s.marshal" cache_format_version)

let load () : t =
  let path = cache_path () in
  if not (Stdlib.Sys.file_exists path) then String.Map.empty
  else
    try
      In_channel.with_file path ~f:(fun ic ->
          let pairs : (string * file_entry) list = Stdlib.Marshal.from_channel ic in
          String.Map.of_alist_exn pairs)
    with
    | _ -> String.Map.empty

let save cache =
  Out_channel.with_file (cache_path ()) ~f:(fun oc ->
      Stdlib.Marshal.to_channel oc (Map.to_alist cache) [])

let file_md5 path = Stdlib.Digest.to_hex (Stdlib.Digest.file path)

let get_fresh_entry cache file =
  let md5 = file_md5 file in
  match Map.find cache file with
  | Some e when String.equal e.md5 md5 -> Some e
  | _ -> None

let put_file cache ~file ~symbols =
  let md5 = file_md5 file in
  Map.set cache ~key:file ~data:{ md5; symbols }
