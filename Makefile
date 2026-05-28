.PHONY: all build run install clean

PREFIX ?= /usr/local
DESTDIR ?=
BINDIR := $(DESTDIR)$(PREFIX)/bin
STDLIBDIR := $(DESTDIR)$(PREFIX)/include/sexc/std
DOCDIR := $(DESTDIR)$(PREFIX)/share/sexc/docs

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

install:
	@if [ ! -x "./sexc" ]; then \
		echo "Missing ./sexc binary. Run 'make build' as your regular user first."; \
		exit 1; \
	fi
	@mkdir -p "$(BINDIR)"
	@mkdir -p "$(STDLIBDIR)"
	@mkdir -p "$(DOCDIR)"
	cp ./sexc "$(BINDIR)/sexc"
	@chmod 755 "$(BINDIR)/sexc"
	cp ./std/*.sexc "$(STDLIBDIR)/"
	SEXC_STDLIB_DIR="$(PWD)/std" ./sexc dump-stdlib-docs "$(DOCDIR)"
	@echo "Installed sexc to $(BINDIR)/sexc"
	@echo "Installed stdlib to $(STDLIBDIR)"
	@echo "Installed docs to $(DOCDIR)"

clean:
	opam exec -- dune clean
	rm -f ./sexc
