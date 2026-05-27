.PHONY: build run clean

build:
	opam exec -- dune build

run:
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make run FILE=path/to/input.sexc"; \
		exit 1; \
	fi
	opam exec -- dune exec ./sexc.exe -- "$(FILE)"

clean:
	opam exec -- dune clean
