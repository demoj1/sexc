.PHONY: build run clean

_dune_lock_fix:
	@if [ -f _build/.lock ]; then \
		pid=$$(cat _build/.lock 2>/dev/null || true); \
		if ! printf "%s" "$$pid" | grep -Eq '^[0-9]+$$'; then \
			echo "Removing invalid dune lock"; \
			rm -f _build/.lock; \
		elif ! kill -0 "$$pid" 2>/dev/null; then \
			echo "Removing stale dune lock (pid $$pid)"; \
			rm -f _build/.lock; \
		fi; \
	fi

build: _dune_lock_fix
	opam exec -- dune build

run: _dune_lock_fix
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make run FILE=path/to/input.sexc"; \
		exit 1; \
	fi
	opam exec -- dune exec ./sexc.exe -- "$(FILE)"

clean:
	opam exec -- dune clean
