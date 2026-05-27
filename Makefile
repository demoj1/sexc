.PHONY: all build run clean

all: build

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
	opam exec -- dune build ./src/sexc.exe
	rm -f ./sexc
	cp _build/default/src/sexc.exe ./sexc
	chmod 755 ./sexc

run: build
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make run FILE=path/to/input.sexc"; \
		exit 1; \
	fi
	./sexc "$(FILE)"

clean:
	opam exec -- dune clean
	rm -f ./sexc
