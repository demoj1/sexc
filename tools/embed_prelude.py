#!/usr/bin/env python3
import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: embed_prelude.py <input.sexc> <output.ml>", file=sys.stderr)
        return 1

    src_path = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
    source = src_path.read_text(encoding="utf-8")

    rendered = (
        "(* Auto-generated from std/core.sexc. Do not edit manually. *)\n"
        f"let core_source = {json.dumps(source)}\n"
    )
    out_path.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
