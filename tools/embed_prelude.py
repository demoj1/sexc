#!/usr/bin/env python3
import json
import pathlib
import re
import sys


IMPORT_RE = re.compile(r'^\s*\(%import\s+"([^"]+)"\s*\)\s*$')


def flatten_source(path: pathlib.Path, visited: set[pathlib.Path]) -> str:
    path = path.resolve()
    if path in visited:
        return ""
    visited.add(path)

    out_parts: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines(keepends=True):
        m = IMPORT_RE.match(line)
        if m:
            rel = m.group(1)
            target = (path.parent / rel).resolve()
            out_parts.append(flatten_source(target, visited))
        else:
            out_parts.append(line)
    return "".join(out_parts)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: embed_prelude.py <input.sexc> <output.ml>", file=sys.stderr)
        return 1

    src_path = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
    source = flatten_source(src_path, set())

    rendered = (
        "(* Auto-generated from std/core.sexc. Do not edit manually. *)\n"
        f"let core_source = {json.dumps(source)}\n"
    )
    out_path.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
