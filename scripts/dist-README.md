# sexc — prebuilt bundle

A self-contained build of the **sexc** compiler (Lisp-syntax → C).
Tagged by commit hash — no versions yet.

> ⚠️ Heavy WIP. The language and toolchain change without notice and using it
> for real work is risky. See the project README for the full disclaimer.

## Contents

```
sexc          the compiler binary
std/          the standard library (*.sexc) — REQUIRED at runtime
install.sh    installer
LICENSE
```

## Run without installing

The binary looks for `std/` **right next to itself**, so you can run it
straight from this folder, from any working directory:

```sh
/path/to/this/folder/sexc examples.sexc -C gcc % -o out
```

Or point at the stdlib explicitly (overrides everything):

```sh
SEXC_STDLIB_DIR=/path/to/this/folder/std sexc file.sexc
```

## Install (puts `sexc` on your PATH)

System-wide (needs sudo):

```sh
sudo ./install.sh
```

User-local, no sudo (make sure `~/.local/bin` is on your PATH):

```sh
PREFIX="$HOME/.local" ./install.sh
```

`install.sh` copies the binary to `$PREFIX/bin/sexc` and the stdlib to
`$PREFIX/include/sexc/std/` — a layout the binary recognises automatically,
so no environment variable is needed afterwards.

## Where sexc looks for the stdlib (first match wins)

The first directory that contains `core.sexc` is used, checked in this order:

1. `$SEXC_STDLIB_DIR` — explicit override
2. `<dir-of-binary>/std` — this bundle
3. `<dir-of-binary>/../include/sexc/std` — installed layout
4. `./std` — relative to the current directory
5. `/usr/local/include/sexc/std` — compiled-in default
