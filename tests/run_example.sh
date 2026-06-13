#!/usr/bin/env bash
# Compile a SexC example end-to-end through gcc AND clang, and — if an expected
# output sidecar exists — run it and diff stdout.
#
# Args: $1 = relative path to example .sexc (from repo root)
# Env:  SEXC, ROOT, RESULTS_DIR, UPDATE
#
# Per-example knobs (first line of the .sexc):
#   ;; sexc-test-flags: -lm -lpthread
#
# Expected stdout sidecar (optional): <example>.expected next to the .sexc.
#   - present  -> the example is also run (gcc build) and its stdout diffed.
#   - absent   -> compilation-only (both compilers must build it).
#   - UPDATE=1 -> the sidecar is (re)generated from the actual run.
# Sidecars live in tests/expected/ (not next to the .sexc), named after the
# example's path with '/' flattened to '__': examples/foo/bar.sexc ->
# tests/expected/examples__foo__bar.expected.
#
# clang is used only if installed; gcc is always required.

set -uo pipefail

src="$1"
abs="${ROOT}/${src}"
name="$(basename "${src%.sexc}")"
slug="example-$(printf '%s' "${src}" | tr -c 'a-zA-Z0-9' '_')"
results="${RESULTS_DIR:-/tmp}"
# Sidecar lives in tests/expected/, named after the example path with '/' -> '__'.
flat="${src%.sexc}"; flat="${flat//\//__}"
expected="${ROOT}/tests/expected/${flat}.expected"

if [[ ! -f "${abs}" ]]; then
    printf '\033[31mFAIL\033[0m compile %s (file not found)\n' "${src}" \
        | tee "${results}/${slug}.fail"
    exit 0
fi

extra_flags=()
first_line="$(head -n1 "${abs}" 2>/dev/null || true)"
if [[ "${first_line}" =~ sexc-test-flags:[[:space:]]*(.+)$ ]]; then
    # shellcheck disable=SC2206
    extra_flags=(${BASH_REMATCH[1]})
fi

# gcc is required; add clang to the matrix when available (portability check —
# the examples lean on GNU extensions that both compilers must accept).
compilers=(gcc)
command -v clang >/dev/null 2>&1 && compilers+=(clang)

gcc_bin=""
for cc in "${compilers[@]}"; do
    bin="$(mktemp -t "sexc_${name}_${cc}.XXXXXX")"
    log="${results}/${slug}.${cc}.log"
    if "${SEXC}" --quiet "${abs}" -C "${cc}" % -O0 -w "${extra_flags[@]}" -lm -o "${bin}" \
            > "${log}" 2>&1; then
        if [[ "${cc}" == gcc ]]; then gcc_bin="${bin}"; else rm -f "${bin}"; fi
    else
        rm -f "${bin}"
        {
            printf '\033[31mFAIL\033[0m compile %s (%s)\n' "${src}" "${cc}"
            sed 's/^/    /' "${log}" | head -30
        } | tee "${results}/${slug}.fail"
        exit 0
    fi
done

# Compilation-only when there's no expected sidecar and we're not creating one.
if [[ ! -f "${expected}" && -z "${UPDATE:-}" ]]; then
    rm -f "${gcc_bin}"
    printf '\033[32mPASS\033[0m compile %s\n' "${src}"
    touch "${results}/${slug}.pass"
    exit 0
fi

# Run the gcc-built binary and capture stdout.
actual="${results}/${slug}.out"
"${gcc_bin}" > "${actual}" 2>/dev/null
rm -f "${gcc_bin}"

if [[ -n "${UPDATE:-}" ]]; then
    mkdir -p "$(dirname "${expected}")"
    cp "${actual}" "${expected}"
    printf '\033[36mUPDATE\033[0m run %s\n' "${src}"
    touch "${results}/${slug}.pass"
    exit 0
fi

if diff -q "${actual}" "${expected}" > /dev/null 2>&1; then
    printf '\033[32mPASS\033[0m run %s\n' "${src}"
    touch "${results}/${slug}.pass"
    exit 0
fi
{
    printf '\033[31mFAIL\033[0m run %s (output mismatch)\n' "${src}"
    diff -u "${expected}" "${actual}" | sed 's/^/    /' | head -40
} | tee "${results}/${slug}.fail"
exit 0
